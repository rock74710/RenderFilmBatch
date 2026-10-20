import Foundation
import CryptoKit
import simd

/// 底片風格用的創意 3D LUT（.cube）。
///
/// 輸入假設是 sRGB 顯示色（0…1 的 sRGB 編碼值），輸出也是 sRGB 編碼值；
/// 給 Log 灰片用的 LUT 不在支援範圍（A-110 Q4）。
public struct CreativeLUT: Sendable {
    public enum ParseError: Error, Equatable {
        case missingSize
        case invalidSize(Int)
        case invalidLine(Int)
        case entryCount(expected: Int, found: Int)
    }

    public let size: Int
    let domainMin: SIMD3<Double>
    let domainMax: SIMD3<Double>
    /// R 變動最快，與 .cube 的排列相同。
    let table: [SIMD3<Double>]

    public static func parse(_ text: String) throws -> CreativeLUT {
        var size: Int?
        var domainMin = SIMD3<Double>(repeating: 0)
        var domainMax = SIMD3<Double>(repeating: 1)
        var table: [SIMD3<Double>] = []
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            func triple(_ start: Int) throws -> SIMD3<Double> {
                guard fields.count == start + 3,
                      let x = Double(fields[start]), let y = Double(fields[start + 1]),
                      let z = Double(fields[start + 2]) else { throw ParseError.invalidLine(index + 1) }
                return SIMD3(x, y, z)
            }
            switch fields[0].uppercased() {
            case "TITLE", "LUT_1D_SIZE":
                continue
            case "LUT_3D_SIZE":
                guard fields.count == 2, let value = Int(fields[1]) else { throw ParseError.invalidLine(index + 1) }
                guard (2...256).contains(value) else { throw ParseError.invalidSize(value) }
                size = value
            case "DOMAIN_MIN":
                domainMin = try triple(1)
            case "DOMAIN_MAX":
                domainMax = try triple(1)
            default:
                table.append(try triple(0))
            }
        }
        guard let size else { throw ParseError.missingSize }
        guard table.count == size * size * size else {
            throw ParseError.entryCount(expected: size * size * size, found: table.count)
        }
        return CreativeLUT(size: size, domainMin: domainMin, domainMax: domainMax, table: table)
    }

    /// 三線性插值查表；輸入超出 domain 時夾到邊界。
    public func sample(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let span = simd_max(domainMax - domainMin, SIMD3(repeating: 1e-9))
        let unit = simd_clamp((rgb - domainMin) / span, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let x = unit * Double(size - 1)
        let i0 = SIMD3<Int>(Int(floor(x.x)), Int(floor(x.y)), Int(floor(x.z)))
        let i1 = SIMD3<Int>(min(i0.x + 1, size - 1), min(i0.y + 1, size - 1), min(i0.z + 1, size - 1))
        let t = x - SIMD3(Double(i0.x), Double(i0.y), Double(i0.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> { table[(b * size + g) * size + r] }
        func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
        let c00 = mix(at(i0.x, i0.y, i0.z), at(i1.x, i0.y, i0.z), t.x)
        let c10 = mix(at(i0.x, i1.y, i0.z), at(i1.x, i1.y, i0.z), t.x)
        let c01 = mix(at(i0.x, i0.y, i1.z), at(i1.x, i0.y, i1.z), t.x)
        let c11 = mix(at(i0.x, i1.y, i1.z), at(i1.x, i1.y, i1.z), t.x)
        return mix(mix(c00, c10, t.y), mix(c01, c11, t.y), t.z)
    }
}

/// 內建原創 LUT 與使用者匯入 LUT 的讀取入口。
///
/// `lutID` 是 `builtin:<名稱>`（隨 RFCore 發佈）或匯入 .cube 的完整路徑。
public enum CreativeLUTLibrary {
    public struct BuiltIn: Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public static let builtIns: [BuiltIn] = [
        ("warmSlide", "Warm Slide"),
        ("coolSlide", "Cool Slide"),
        ("fadedFilm", "Faded Film"),
        ("tealOrange", "Teal & Orange"),
        ("highContrastMono", "High Contrast B&W"),
        ("softMono", "Soft B&W"),
        ("vividSlide", "Vivid Slide"),
        ("retroWarmFade", "Retro Warm Fade"),
    ].map { BuiltIn(id: "builtin:\($0.0)", name: $0.1) }

    public static func url(for id: String) -> URL? {
        if id.hasPrefix("builtin:") {
            let name = String(id.dropFirst("builtin:".count))
            guard builtIns.contains(where: { $0.id == id }) else { return nil }
            return Bundle.module.url(forResource: name, withExtension: "cube", subdirectory: "FilmLUTs")
        }
        return URL(fileURLWithPath: id)
    }

    private struct Entry {
        let contentFingerprint: String?
        let lut: CreativeLUT?
    }

    private struct Asset {
        let data: Data
        let fingerprint: String
    }

    private static let maximumAssetBytes = 128 * 1024 * 1024
    private static let pendingFingerprintKey = "RFCore.CreativeLUTLibrary.pendingFingerprints"
    private static let missingFingerprintMarker = "\u{0}"

    private struct CachedEntry {
        let id: String
        let entry: Entry
    }

    nonisolated(unsafe) private static var cache: CachedEntry?
    private static let lock = NSLock()

    /// 供 LUT key 使用的內容身份。若同一執行緒剛載入過這個資產，會確認載入時的
    /// fingerprint 仍與目前檔案相同；有競態時呼叫端應略過快取保存。
    static func cacheIdentity(for id: String) -> (fingerprint: String?, matchesLoadedSnapshot: Bool) {
        let loaded = loadedFingerprint(for: id)
        let current = url(for: id).flatMap(readAsset(at:))?.fingerprint
        guard loaded.found else { return (current, true) }
        return (current, loaded.fingerprint == current)
    }

    /// 回傳目前內容的 SHA-256。內建與匯入 LUT 使用同一讀取及雜湊路徑。
    static func contentFingerprint(for id: String) -> String? {
        url(for: id).flatMap(readAsset(at:))?.fingerprint
    }

    /// 讀不到或格式錯誤時回傳 nil，呼叫端略過 LUT 照常渲染（INV-3）。
    public static func load(id: String) -> CreativeLUT? {
        guard let url = url(for: id) else { return nil }
        guard let asset = readAsset(at: url) else {
            rememberLoadedFingerprint(nil, for: id)
            lock.lock()
            cache = CachedEntry(id: id, entry: Entry(contentFingerprint: nil, lut: nil))
            lock.unlock()
            return nil
        }
        rememberLoadedFingerprint(asset.fingerprint, for: id)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache, cached.id == id,
           cached.entry.contentFingerprint == asset.fingerprint {
            return cached.entry.lut
        }
        let lut = String(data: asset.data, encoding: .utf8).flatMap { try? CreativeLUT.parse($0) }
        cache = CachedEntry(id: id, entry: Entry(contentFingerprint: asset.fingerprint, lut: lut))
        return lut
    }

    private static func readAsset(at url: URL) -> Asset? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumAssetBytes + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count <= maximumAssetBytes else { return nil }
        let digest = SHA256.hash(data: data)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return Asset(data: data, fingerprint: fingerprint)
    }

    private static func rememberLoadedFingerprint(_ fingerprint: String?, for id: String) {
        let dictionary: NSMutableDictionary
        if let existing = Thread.current.threadDictionary[pendingFingerprintKey] as? NSMutableDictionary {
            dictionary = existing
        } else {
            dictionary = NSMutableDictionary()
            Thread.current.threadDictionary[pendingFingerprintKey] = dictionary
        }
        dictionary.removeAllObjects()
        dictionary[id] = fingerprint ?? missingFingerprintMarker
    }

    private static func loadedFingerprint(for id: String) -> (found: Bool, fingerprint: String?) {
        guard let dictionary = Thread.current.threadDictionary[pendingFingerprintKey] as? NSMutableDictionary,
              let stored = dictionary.object(forKey: id) as? String else {
            return (false, nil)
        }
        return (true, stored == missingFingerprintMarker ? nil : stored)
    }
}
