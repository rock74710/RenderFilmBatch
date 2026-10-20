import Foundation

/// 座標以校正後影像左下角為原點，0…1；不依賴預覽解析度。
public struct MaskPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct MaskStroke: Codable, Equatable, Sendable {
    public var points: [MaskPoint]
    /// 半徑相對於影像短邊。
    public var radius: Double
    public var erasing: Bool
    public init(points: [MaskPoint], radius: Double, erasing: Bool = false) {
        self.points = points; self.radius = radius; self.erasing = erasing
    }
}

public struct LocalMask: Codable, Equatable, Identifiable, Sendable {
    /// 局部色彩調整；nil 代表舊 sidecar 的原有曝光專用遮罩。
    public struct ColorAdjustment: Codable, Equatable, Sendable {
        /// 相對於 5000 K／tint 0 的色溫（K）與相機 tint 刻度偏移；正 tint 偏洋紅。
        public var temperature: Double = 0
        public var tint: Double = 0
        /// 彩度倍率；1 為原樣。
        public var chroma: Double = 1
        /// 繞灰軸旋轉的色相角（度）；`hue` 已是色彩範圍遮罩的選色欄位。
        public var hueShift: Double = 0
        public init(temperature: Double = 0, tint: Double = 0, chroma: Double = 1, hueShift: Double = 0) {
            self.temperature = temperature; self.tint = tint; self.chroma = chroma; self.hueShift = hueShift
        }
        private enum CodingKeys: String, CodingKey { case temperature, tint, chroma, hueShift }
        /// 介面以 JSON pointer 只寫入單一欄位，缺的欄位取預設值。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
            tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
            chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 1
            hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? 0
        }
        var isNeutral: Bool { temperature == 0 && tint == 0 && chroma == 1 && hueShift == 0 }
    }
    /// 局部明暗；各項 −1…1，0 為原樣。
    public struct ToneAdjustment: Codable, Equatable, Sendable {
        public var contrast: Double = 0
        public var highlights: Double = 0
        public var shadows: Double = 0
        public var whites: Double = 0
        public var blacks: Double = 0
        public init(contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
                    whites: Double = 0, blacks: Double = 0) {
            self.contrast = contrast; self.highlights = highlights; self.shadows = shadows
            self.whites = whites; self.blacks = blacks
        }
        private enum CodingKeys: String, CodingKey { case contrast, highlights, shadows, whites, blacks }
        /// 介面只寫入有動到的欄位，缺的欄位當 0。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
            highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
            shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
            whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
            blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        }
        var isNeutral: Bool { contrast == 0 && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0 }
    }
    /// 局部空間效果；各項 −1…1，0 為原樣。
    public struct EffectAdjustment: Codable, Equatable, Sendable {
        public var texture: Double = 0
        public var clarity: Double = 0
        public var dehaze: Double = 0
        public init(texture: Double = 0, clarity: Double = 0, dehaze: Double = 0) {
            self.texture = texture; self.clarity = clarity; self.dehaze = dehaze
        }
        private enum CodingKeys: String, CodingKey { case texture, clarity, dehaze }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
            clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
            dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        }
        var isNeutral: Bool { texture == 0 && clarity == 0 && dehaze == 0 }
    }
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case gradient, brush, luminance, colorRange
        public var displayName: String {
            switch self {
            case .gradient: return String(localized: "漸層", bundle: .module)
            case .brush: return String(localized: "筆刷", bundle: .module)
            case .luminance: return String(localized: "亮度範圍", bundle: .module)
            case .colorRange: return String(localized: "色彩範圍", bundle: .module)
            }
        }
    }
    public var id = UUID()
    public var name: String
    public var kind: Kind
    public var enabled = true
    public var inverted = false
    public var opacity: Double = 1
    public var feather: Double = 0.2
    public var exposureEV: Double = 0
    public var colorAdjustment: ColorAdjustment? = nil
    /// 舊 sidecar 沒有以下兩欄，nil 等同全部為 0。
    public var toneAdjustment: ToneAdjustment? = nil
    public var effectAdjustment: EffectAdjustment? = nil
    public var start = MaskPoint(x: 0.5, y: 0.25)
    public var end = MaskPoint(x: 0.5, y: 0.75)
    public var strokes: [MaskStroke] = []
    /// AI 選區的灰階 PNG；筆畫依序疊在此底圖上，舊 sidecar 沒有此欄位。
    public var aiSelection: Data? = nil
    /// 以 scene-linear Rec.2020 的 18% 灰為 0 EV。
    public var lowerEV: Double = -2
    public var upperEV: Double = 2
    /// working RGB 的 HSV 色相角；以圓周距離處理紅色跨越 0°。
    public var hue: Double = 0
    public var hueWidth: Double = 30
    public var minimumSaturation: Double = 0.1

    public var hasActiveAdjustment: Bool {
        guard enabled && opacity > 0 else { return false }
        return exposureEV != 0 || hasColor || hasTone || hasEffect
    }
    var hasColor: Bool { colorAdjustment.map { !$0.isNeutral } ?? false }
    var hasTone: Bool { toneAdjustment.map { !$0.isNeutral } ?? false }
    var hasEffect: Bool { effectAdjustment.map { !$0.isNeutral } ?? false }

    public init(kind: Kind) { self.kind = kind; self.name = kind.displayName }
}
