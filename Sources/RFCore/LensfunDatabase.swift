import Foundation

/// §2.2 Lensfun：只解析官方 XML 資料庫，不連結 C 函式庫。
public final class LensfunDatabase: @unchecked Sendable {
    public private(set) var lenses: [LensEntry] = []
    /// 資料庫版本字串，寫進 sidecar 以維持可重現性。
    public private(set) var version: String = "none"

    public init() {}

    /// 從一個目錄載入所有 `*.xml`。Lensfun 官方資料庫就是這種形狀
    /// （Homebrew 預設為 `/opt/homebrew/share/lensfun/version_2`）。
    public convenience init(directory: URL) throws {
        self.init()
        try load(directory: directory)
    }

    /// 隨 App 打包的資料庫優先，其次是常見的系統安裝位置，依序尋找第一個存在的。
    public static var defaultSearchPaths: [URL] {
        let bundled = Bundle.module.url(forResource: "lensfun", withExtension: nil)
        return [bundled].compactMap { $0 } + ["/opt/homebrew/share/lensfun/version_2",
         "/opt/homebrew/share/lensfun",
         "/usr/local/share/lensfun/version_2",
         "/usr/local/share/lensfun",
         "/usr/share/lensfun/version_2"].map { URL(fileURLWithPath: $0) }
    }

    /// 載入系統上找得到的第一份資料庫；找不到時回傳空資料庫而不是報錯，
    /// 讓 pipeline 仍可在 embedded / off 的情況下運作。
    public static func loadDefault() -> LensfunDatabase {
        let db = LensfunDatabase()
        for path in defaultSearchPaths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if (try? db.load(directory: path)) != nil, !db.lenses.isEmpty {
                db.version = "lensfun:\(path.lastPathComponent):\(db.lenses.count)"
                return db
            }
        }
        return db
    }

    public func load(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "xml" }
        for f in files {
            if let data = try? Data(contentsOf: f) {
                lenses.append(contentsOf: LensfunParser.parse(data))
            }
        }
        if version == "none" {
            version = "lensfun:\(directory.lastPathComponent):\(lenses.count)"
        }
    }

    public func load(xml data: Data) {
        lenses.append(contentsOf: LensfunParser.parse(data))
        version = "lensfun:inline:\(lenses.count)"
    }

    /// 以相機與鏡頭名稱找出最接近的一支鏡頭。
    ///
    /// EXIF 的鏡頭名稱與 Lensfun 的 model 欄位經常有空白、縮寫與大小寫差異，
    /// 所以用正規化後的 token 交集分數，而不是要求字串完全相等。
    public func findLens(name: String?, maker: String?) -> LensEntry? {
        guard let name, !name.isEmpty else { return nil }
        let wanted = Self.tokens(name)
        guard !wanted.isEmpty else { return nil }
        let makerTokens = maker.map { Self.tokens($0) } ?? []

        var best: (LensEntry, Double)?
        for lens in lenses {
            let candidate = Self.tokens(lens.model)
            guard !candidate.isEmpty else { continue }
            let shared = wanted.intersection(candidate).count
            guard shared > 0 else { continue }
            var score = Double(shared) / Double(wanted.union(candidate).count)
            if !makerTokens.isEmpty, !makerTokens.isDisjoint(with: Self.tokens(lens.maker)) {
                score += 0.15
            }
            if best == nil || score > best!.1 { best = (lens, score) }
        }
        // 低於門檻視為沒找到，寧可不校正也不要套錯鏡頭。
        guard let (lens, score) = best, score >= 0.35 else { return nil }
        return lens
    }

    static func tokens(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let parts = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." })
        return Set(parts.map(String.init).filter { $0.count > 1 })
    }
}

/// Lensfun XML 的最小解析器，只取本階段需要的 distortion / tca / vignetting。
enum LensfunParser {
    static func parse(_ data: Data) -> [LensEntry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.lenses
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var lenses: [LensEntry] = []
        private var current: LensEntry?
        private var calibrations: [LensCalibration] = []
        private var text = ""
        private var inLens = false

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attrs: [String: String]) {
            text = ""
            switch name {
            case "lens":
                inLens = true
                current = LensEntry(maker: "", model: "")
                calibrations = []
            case "distortion":
                guard inLens else { return }
                let kind: DistortionModel.Kind
                switch attrs["model"] {
                case "poly3": kind = .poly3
                case "poly5": kind = .poly5
                case "ptlens": kind = .ptlens
                default: return
                }
                let m = DistortionModel(
                    kind: kind,
                    a: d(attrs["a"] ?? attrs["k1"]),
                    b: d(attrs["b"] ?? attrs["k2"]),
                    c: d(attrs["c"])
                )
                calibrations.append(LensCalibration(focal: d(attrs["focal"]), distortion: m))
            case "tca":
                guard inLens else { return }
                let kind: TCAModel.Kind
                switch attrs["model"] {
                case "linear": kind = .linear
                case "poly3": kind = .poly3
                default: return
                }
                let m = TCAModel(
                    kind: kind,
                    kr: d(attrs["kr"] ?? attrs["vr"], default: 1),
                    kb: d(attrs["kb"] ?? attrs["vb"], default: 1),
                    br: d(attrs["br"]),
                    bb: d(attrs["bb"])
                )
                calibrations.append(LensCalibration(focal: d(attrs["focal"]), tca: m))
            case "vignetting":
                guard inLens else { return }
                guard attrs["model"] == nil || attrs["model"] == "pa" else { return }
                let m = VignettingModel(
                    kind: .pa, k1: d(attrs["k1"]), k2: d(attrs["k2"]), k3: d(attrs["k3"])
                )
                calibrations.append(LensCalibration(
                    focal: d(attrs["focal"]),
                    aperture: attrs["aperture"].flatMap(Double.init),
                    distance: attrs["distance"].flatMap(Double.init),
                    vignetting: m
                ))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "maker" where inLens:
                if current?.maker.isEmpty ?? false { current?.maker = value }
            case "model" where inLens:
                if current?.model.isEmpty ?? false { current?.model = value }
            case "mount" where inLens:
                current?.mount.append(value)
            case "cropfactor" where inLens:
                current?.cropFactor = Double(value) ?? 1.0
            case "lens":
                if var lens = current, !lens.model.isEmpty {
                    lens.calibrations = calibrations
                    lenses.append(lens)
                }
                current = nil
                calibrations = []
                inLens = false
            default:
                break
            }
            text = ""
        }

        private func d(_ s: String?, default def: Double = 0) -> Double {
            s.flatMap(Double.init) ?? def
        }
    }
}
