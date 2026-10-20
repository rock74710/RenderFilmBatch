import Foundation

/// 批次 App 每張照片自己的曲線，存在 RAW 旁邊的 XML；沒有 XML 的照片不套曲線。
public struct BatchCurve: Equatable, Sendable {
    public enum Mode: String, Sendable { case luma, rgb }

    public static let fileExtension = "rfcurve.xml"

    /// 一般模式只套 `luma`，RGB 模式只套三個通道；兩組都保留，切換模式不會弄丟。
    public var mode: Mode = .luma
    public var luma: [Double] = []
    public var red: [Double] = []
    public var green: [Double] = []
    public var blue: [Double] = []

    public init() {}

    public var isNeutral: Bool { [luma, red, green, blue].allSatisfy(FinalCurve.isIdentity) }

    /// 算圖用的曲線。
    public var finalCurve: FinalCurve {
        var curve = FinalCurve()
        switch mode {
        case .luma: curve.rgb = luma
        case .rgb:
            curve.red = red
            curve.green = green
            curve.blue = blue
        }
        return curve
    }

    /// `A.NEF` → `A.NEF.rfcurve.xml`：保留原副檔名，同名的 A.NEF 與 A.CR2 各有一份。
    public static func url(forRaw raw: URL) -> URL {
        raw.appendingPathExtension(fileExtension)
    }

    public static func load(forRaw raw: URL) throws -> BatchCurve? {
        let url = self.url(forRaw: raw)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try BatchCurve(xml: Data(contentsOf: url))
    }

    /// 直線（沒調過）時刪掉 XML，否則原子寫入。
    public func save(forRaw raw: URL) throws {
        let url = Self.url(forRaw: raw)
        if isNeutral {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try xmlData().write(to: url, options: .atomic)
        }
    }

    private static var channels: [(name: String, path: WritableKeyPath<BatchCurve, [Double]>)] {
        [("luma", \.luma), ("red", \.red), ("green", \.green), ("blue", \.blue)]
    }

    public init(xml data: Data) throws {
        let root = try XMLDocument(data: data).rootElement()
        guard let root, root.name == "renderfilm-curve",
              let mode = root.attribute(forName: "mode")?.stringValue.flatMap(Mode.init) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.mode = mode
        for element in root.elements(forName: "curve") {
            guard let name = element.attribute(forName: "channel")?.stringValue,
                  let path = Self.channels.first(where: { $0.name == name })?.path else { continue }
            let values = (element.stringValue ?? "").split(separator: " ").map { Double($0) }
            guard values.allSatisfy({ $0 != nil }) else { throw CocoaError(.fileReadCorruptFile) }
            self[keyPath: path] = values.compactMap { $0 }
        }
    }

    public func xmlData() -> Data {
        let root = XMLElement(name: "renderfilm-curve")
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "1") as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "mode", stringValue: mode.rawValue) as! XMLNode)
        for (name, path) in Self.channels where !self[keyPath: path].isEmpty {
            let element = XMLElement(name: "curve", stringValue: self[keyPath: path].map { "\($0)" }.joined(separator: " "))
            element.addAttribute(XMLNode.attribute(withName: "channel", stringValue: name) as! XMLNode)
            root.addChild(element)
        }
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        return document.xmlData(options: .nodePrettyPrint)
    }
}
