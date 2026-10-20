import Foundation

/// §4 Human Adjustment Layer A — Technical / Scene。
/// 這一層只修「現場與曝光」，不建立風格（INV-3）。
public struct LayerATechnical: Codable, Equatable, Sendable {
    /// 區塊開關；關掉時渲染當成初始值，數值保留。
    public var enabled: Bool = true
    /// 曝光補償，單位 EV。
    public var exposureEV: Double = 0
    /// Temperature + Tint 的單一 typed state；As Shot 不以固定數值儲存。
    public var whiteBalance = WhiteBalanceParameters()
    /// 舊 API / 舊 sidecar 的相容 bridge。新的 UI 使用 `whiteBalance`。
    public var temperature: Double? {
        get { whiteBalance.temperature }
        set { whiteBalance.temperature = newValue }
    }
    /// 舊 API / 舊 sidecar 的相容 bridge；單位仍是 CIE xy 的 y 偏移。
    public var tint: Double? {
        get { whiteBalance.tint }
        set { whiteBalance.tint = newValue }
    }
    /// 高光還原強度 0…1。
    public var highlightRecovery: Double = 0
    /// 陰影還原強度 0…1。
    public var shadowRecovery: Double = 0
    /// 線性對比，1 為不變。作用在 scene-referred 線性值上。
    public var linearContrast: Double = 0
    /// 基礎彩度，1 為不變。
    public var chroma: Double = 1

    public init() {}

    public var isNeutral: Bool { self == LayerATechnical() }

    private enum CodingKeys: String, CodingKey {
        case enabled, exposureEV, whiteBalance, temperature, tint
        case highlightRecovery, shadowRecovery, linearContrast, chroma
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        if let state = try c.decodeIfPresent(WhiteBalanceParameters.self, forKey: .whiteBalance) {
            whiteBalance = state
        } else {
            // Legacy sidecars stored independent optional fields. Preserve their values,
            // but represent any override as Custom in the new state model.
            let legacyTemperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
            let legacyTint = try c.decodeIfPresent(Double.self, forKey: .tint)
            whiteBalance = WhiteBalanceParameters(
                preset: legacyTemperature == nil && legacyTint == nil ? .asShot : .custom,
                temperature: legacyTemperature,
                tint: legacyTint
            )
        }
        highlightRecovery = try c.decodeIfPresent(Double.self, forKey: .highlightRecovery) ?? 0
        shadowRecovery = try c.decodeIfPresent(Double.self, forKey: .shadowRecovery) ?? 0
        linearContrast = try c.decodeIfPresent(Double.self, forKey: .linearContrast) ?? 0
        chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(exposureEV, forKey: .exposureEV)
        try c.encode(whiteBalance, forKey: .whiteBalance)
        try c.encode(highlightRecovery, forKey: .highlightRecovery)
        try c.encode(shadowRecovery, forKey: .shadowRecovery)
        try c.encode(linearContrast, forKey: .linearContrast)
        try c.encode(chroma, forKey: .chroma)
    }
}

/// §5.5 色彩基底 profile。profile 只提供一組預設值，使用者滑桿是疊在它上面的偏移。
public enum ColorProfile: String, Codable, CaseIterable, Sendable {
    /// 中性起點：所有曲線為 no-op，rendering 與導入 profile 之前完全相同。
    case natural
    /// 以 Fujifilm Classic Chrome 為參考方向的基底。
    case chromeLike
    /// 以 Fujifilm Classic Neg. 為參考方向的基底。
    case negLike

    public var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .chromeLike: return "Chrome"
        case .negLike: return "Negative"
        }
    }
}

/// 灰階染色（split tone）：陰影與高光各一組色相與強度，只作用在低彩度區。
///
/// 量測顯示這是 Classic Neg. 與其他 profile 唯一的結構性差異（陰影青綠、高光橙），
/// Classic Chrome 與 natural 的 amount 皆為 0。
public struct SplitToneParameters: Codable, Equatable, Sendable {
    /// 陰影染色的 OKLCh 色相（度）。
    public var shadowHue: Double = 0
    /// 陰影染色量，單位為 OKLab chroma。0 表示不染色。
    public var shadowAmount: Double = 0
    /// 高光染色的 OKLCh 色相（度）。
    public var highlightHue: Double = 0
    /// 高光染色量，單位為 OKLab chroma。0 表示不染色。
    public var highlightAmount: Double = 0

    public init() {}

    public var isNeutral: Bool { shadowAmount == 0 && highlightAmount == 0 }
}

/// §5 Perceptual Color Engine 的可調參數。
public struct ColorEngineParameters: Codable, Equatable, Sendable {
    /// §5.4 Illuminant presets。
    public enum Illuminant: String, Codable, CaseIterable, Sendable {
        case asShot, daylight, shade, cloudy, tungsten, led

        public var displayName: String {
            switch self {
            case .asShot: return "As Shot"
            case .daylight: return "Daylight"
            case .shade: return "Shade"
            case .cloudy: return "Cloudy"
            case .tungsten: return "Tungsten"
            case .led: return "LED / Mixed"
            }
        }
    }

    /// 色彩引擎總開關，供 §12.4 的前 / 後對比使用。
    public var enabled: Bool = true
    public var illuminant: Illuminant = .asShot
    /// 整體 chroma 組織強度：<1 收斂、>1 放大。
    public var chromaStrength: Double = 1.0
    /// 高光去飽和的起始亮度（OKLab L）。高於此值開始保護高光色彩。
    public var highlightProtectionStart: Double = 0.75
    /// 高光保護強度 0…1。
    public var highlightProtection: Double = 0.6
    /// 膚色保護強度 0…1：限制膚色帶的 hue 位移與 chroma 壓縮。
    public var skinProtection: Double = 0.8
    /// 色彩基底。變更 profile 會一次帶入下面這幾條曲線與一組 tone 預設，
    /// 見 `EditParameters.applyProfile(_:)`。
    public var profile: ColorProfile = .natural
    /// 色相微調（度），12 個控制點，每 30° 一個，0° 起。量測顯示 CC / CN 的
    /// Δh(hue) 是繞色相環 2–3 個週期的平滑曲線，12 點加平滑內插即足夠。
    public var hueShifts: [Double] = Array(repeating: 0, count: ColorEngineParameters.hueControlPoints)
    /// 各控制點的 chroma 倍率，位置與 `hueShifts` 相同。
    public var chromaBands: [Double] = Array(repeating: 1, count: ColorEngineParameters.hueControlPoints)
    /// `hueShifts` 隨亮度的縮放倍率，節點位置見 `lightnessNodes`。全為 1 時不隨亮度變化。
    public var hueShiftByLightness: [Double] = Array(repeating: 1, count: ColorEngineParameters.lightnessNodes.count)
    /// `chromaBands` 偏離 1 的量隨亮度的縮放倍率。實際倍率為 `1 + (band - 1) * scale`。
    public var chromaByLightness: [Double] = Array(repeating: 1, count: ColorEngineParameters.lightnessNodes.count)
    /// 灰階染色。預設中性。
    public var splitTone = SplitToneParameters()

    /// 色相曲線的控制點數量（每 30°）。
    public static let hueControlPoints = 12
    /// 亮度縮放曲線的節點位置，單位是 scene-referred 的 OKLab L，
    /// 對應 18% 灰的 −3 / −1.5 / 0 / +1.5 / +3 EV。
    public static let lightnessNodes: [Double] = [0.2823, 0.3992, 0.5646, 0.7985, 1.1292]

    public init() {}
}

extension ColorEngineParameters {
    private enum CodingKeys: String, CodingKey {
        case enabled, illuminant, chromaStrength, highlightProtectionStart, highlightProtection
        case skinProtection, hueShifts, chromaBands
        case profile, hueShiftByLightness, chromaByLightness, splitTone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var v = ColorEngineParameters()
        v.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? v.enabled
        v.illuminant = try c.decodeIfPresent(Illuminant.self, forKey: .illuminant) ?? v.illuminant
        v.chromaStrength = try c.decodeIfPresent(Double.self, forKey: .chromaStrength) ?? v.chromaStrength
        v.highlightProtectionStart = try c.decodeIfPresent(Double.self, forKey: .highlightProtectionStart)
            ?? v.highlightProtectionStart
        v.highlightProtection = try c.decodeIfPresent(Double.self, forKey: .highlightProtection) ?? v.highlightProtection
        v.skinProtection = try c.decodeIfPresent(Double.self, forKey: .skinProtection) ?? v.skinProtection
        v.profile = try c.decodeIfPresent(ColorProfile.self, forKey: .profile) ?? v.profile
        v.splitTone = try c.decodeIfPresent(SplitToneParameters.self, forKey: .splitTone) ?? v.splitTone
        if let h = try c.decodeIfPresent([Double].self, forKey: .hueShifts) {
            v.hueShifts = Self.upsampleLegacyBands(h, neutral: 0)
        }
        if let cb = try c.decodeIfPresent([Double].self, forKey: .chromaBands) {
            v.chromaBands = Self.upsampleLegacyBands(cb, neutral: 1)
        }
        v.hueShiftByLightness = try c.decodeIfPresent([Double].self, forKey: .hueShiftByLightness)
            ?? v.hueShiftByLightness
        v.chromaByLightness = try c.decodeIfPresent([Double].self, forKey: .chromaByLightness)
            ?? v.chromaByLightness
        self = v
    }

    /// 舊 sidecar 存的是 6 個色帶（每 60°、線性內插）。升取樣的方式是「用舊的線性規則
    /// 在新的 12 個控制點位置取值」，所以使用者調過的色帶位置與量值都被保留；
    /// 內插改為平滑後，僅在色帶峰值附近有可量測的微小差異（見 ColorProfileTests）。
    static func upsampleLegacyBands(_ values: [Double], neutral: Double) -> [Double] {
        guard values.count != hueControlPoints else { return values }
        guard values.count > 1 else {
            return Array(repeating: values.first ?? neutral, count: hueControlPoints)
        }
        let n = values.count
        return (0..<hueControlPoints).map { i in
            let pos = Double(i) / Double(hueControlPoints) * Double(n)
            let low = Int(pos.rounded(.down)) % n
            let t = pos - pos.rounded(.down)
            return values[low] * (1 - t) + values[(low + 1) % n] * t
        }
    }
}

/// Color Mixer 的八個色帶，順序也決定 `ColorMixerParameters.bands` 的索引。
public enum ColorMixerBand: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var index: Int {
        switch self {
        case .red: return 0
        case .orange: return 1
        case .yellow: return 2
        case .green: return 3
        case .aqua: return 4
        case .blue: return 5
        case .purple: return 6
        case .magenta: return 7
        }
    }

    public var displayName: String {
        switch self {
        case .red: return String(localized: "紅", bundle: .module)
        case .orange: return String(localized: "橙", bundle: .module)
        case .yellow: return String(localized: "黃", bundle: .module)
        case .green: return String(localized: "綠", bundle: .module)
        case .aqua: return String(localized: "青", bundle: .module)
        case .blue: return String(localized: "藍", bundle: .module)
        case .purple: return String(localized: "紫", bundle: .module)
        case .magenta: return String(localized: "洋紅", bundle: .module)
        }
    }
}

/// Color Mixer 的單一色帶調整。S/L 與 C/M/Y/K 為正規化偏移（−1…1）。
public struct ColorMixerBandParameters: Codable, Equatable, Sendable {
    /// 色相偏移，單位度，UI 建議範圍 −45…45。
    public var hueShift: Double = 0
    /// 飽和度偏移。−1 將 chroma 降為 0，+1 加倍 chroma。
    public var saturationShift: Double = 0
    /// 亮度倍率偏移。−1 將感知亮度降為 0，+1 加倍。
    public var lightnessShift: Double = 0
    /// 增加青色染料會減少紅色分量；負值反向調整。
    public var cyan: Double = 0
    /// 增加洋紅染料會減少綠色分量；負值反向調整。
    public var magenta: Double = 0
    /// 增加黃色染料會減少藍色分量；負值反向調整。
    public var yellow: Double = 0
    /// 黑色量控制該色帶的整體亮度；正值壓暗，負值提亮。
    public var black: Double = 0

    public init(
        hueShift: Double = 0,
        saturationShift: Double = 0,
        lightnessShift: Double = 0,
        cyan: Double = 0,
        magenta: Double = 0,
        yellow: Double = 0,
        black: Double = 0
    ) {
        self.hueShift = hueShift
        self.saturationShift = saturationShift
        self.lightnessShift = lightnessShift
        self.cyan = cyan
        self.magenta = magenta
        self.yellow = yellow
        self.black = black
    }

    public var isNeutral: Bool {
        hueShift == 0 && saturationShift == 0 && lightnessShift == 0
            && cyan == 0 && magenta == 0 && yellow == 0 && black == 0
    }

    private enum CodingKeys: String, CodingKey {
        case hueShift, saturationShift, lightnessShift, cyan, magenta, yellow, black
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? 0
        saturationShift = try c.decodeIfPresent(Double.self, forKey: .saturationShift) ?? 0
        lightnessShift = try c.decodeIfPresent(Double.self, forKey: .lightnessShift) ?? 0
        cyan = try c.decodeIfPresent(Double.self, forKey: .cyan) ?? 0
        magenta = try c.decodeIfPresent(Double.self, forKey: .magenta) ?? 0
        yellow = try c.decodeIfPresent(Double.self, forKey: .yellow) ?? 0
        black = try c.decodeIfPresent(Double.self, forKey: .black) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hueShift, forKey: .hueShift)
        try c.encode(saturationShift, forKey: .saturationShift)
        try c.encode(lightnessShift, forKey: .lightnessShift)
        try c.encode(cyan, forKey: .cyan)
        try c.encode(magenta, forKey: .magenta)
        try c.encode(yellow, forKey: .yellow)
        try c.encode(black, forKey: .black)
    }
}

/// 八色帶 HSL / Color Mixer 與 CMYK 式 Selective Color 的共用設定。
public struct ColorMixerParameters: Codable, Equatable, Sendable {
    public static let bandCount = ColorMixerBand.allCases.count

    /// 索引順序固定為 red, orange, yellow, green, aqua, blue, purple, magenta。
    public var bands: [ColorMixerBandParameters]
    /// 區塊開關；關掉時渲染當成初始值，數值保留。
    public var enabled: Bool = true

    public init(bands: [ColorMixerBandParameters] = []) {
        self.bands = Self.normalizedBands(bands)
    }

    public var isNeutral: Bool { bands.allSatisfy(\.isNeutral) }

    private enum CodingKeys: String, CodingKey { case bands, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bands = Self.normalizedBands(
            try c.decodeIfPresent([ColorMixerBandParameters].self, forKey: .bands) ?? []
        )
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bands, forKey: .bands)
        try c.encode(enabled, forKey: .enabled)
    }

    private static func normalizedBands(_ values: [ColorMixerBandParameters]) -> [ColorMixerBandParameters] {
        Array(values.prefix(bandCount)) + Array(
            repeating: ColorMixerBandParameters(),
            count: max(0, bandCount - values.count)
        )
    }
}

/// §9 Tone Mapping 參數。
public struct ToneMappingParameters: Codable, Equatable, Sendable {
    /// Filmic 肩部起點（scene-referred 相對亮度）。
    public var shoulderStart: Double = 0.6
    /// 高光滾降強度 0…1，越大越緩。
    public var highlightRollOff: Double = 0.7
    /// 陰影塑形 -1…1，正值抬起陰影。
    public var shadowShaping: Double = 0.0
    /// 中間調對比，1 為不變。
    public var midtoneContrast: Double = 1.0
    /// Diffuse white 對應的 scene-referred 值，預設 1.0。
    public var diffuseWhite: Double = 1.0

    public init() {}
}

/// §10 Gamut Mapping 參數。
public struct GamutMappingParameters: Codable, Equatable, Sendable {
    /// 壓縮起始點：目標色域邊界的比例，低於此值不動。
    public var knee: Double = 0.85
    /// 允許的 lightness 微調上限。
    public var lightnessAdapt: Double = 0.15
    public var enabled: Bool = true

    public init() {}
}

/// §2 光學校正的使用者設定。
public struct OpticalParameters: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    /// nil 表示自動依優先序決定。
    public var forcedSource: LensProfileSource?
    /// §4「Lens correction override」：手動覆寫係數。
    public var manualProfile: ResolvedLensProfile?
    /// 水平、透視、裁切比例；有自己的開關，不受上面的鏡頭校正開關影響。
    public var geometry = GeometryParameters()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        forcedSource = try c.decodeIfPresent(LensProfileSource.self, forKey: .forcedSource)
        manualProfile = try c.decodeIfPresent(ResolvedLensProfile.self, forKey: .manualProfile)
        geometry = try c.decodeIfPresent(GeometryParameters.self, forKey: .geometry) ?? GeometryParameters()
    }
}

/// §8 Rendering Target。
public struct RenderingTarget: Codable, Hashable, Sendable {
    public enum DynamicRange: String, Codable, CaseIterable, Hashable, Sendable {
        case sdr, constrainedHDR, fullHDR
    }

    public enum Gamut: String, Codable, CaseIterable, Hashable, Sendable {
        case sRGB, displayP3, rec2020

        public var displayName: String {
            switch self {
            case .sRGB: return "sRGB"
            case .displayP3: return "Display P3"
            case .rec2020: return "Rec.2020"
            }
        }

        public var colorSpace: RGBColorSpace {
            switch self {
            case .sRGB: return .sRGB
            case .displayP3: return .displayP3
            case .rec2020: return .rec2020
            }
        }
    }

    public enum TransferFunction: String, Codable, CaseIterable, Hashable, Sendable {
        case sRGB, linear, pq, hlg
    }

    public enum OutputIntent: String, Codable, CaseIterable, Hashable, Sendable {
        case webSDR, appleSDR, appleHDR, hdrStandard, broadcastHDR, archive, custom
    }

    public var dynamicRange: DynamicRange = .sdr
    public var gamut: Gamut = .displayP3
    public var transferFunction: TransferFunction = .sRGB
    public var intent: OutputIntent = .appleSDR
    /// §8.2 Custom／Print ICC。nil 表示直接輸出 `gamut` 本身。只作用於 SDR 輸出。
    public var iccDestination: ICCDestination?
    /// target-linear 1.0 代表的絕對亮度（nit）。HDR still image 標準是 203 nit。
    /// PQ 是絕對 transfer function，沒有這個錨點就無法把相對值換算成 code value。
    public var referenceWhiteNits: Double = 203
    /// 這個 target 允許的最高亮度（nit）。除以 reference white 就是 content headroom。
    public var contentPeakNits: Double = 203

    /// 內容本身的動態範圍倍數（相對 reference white）。**不是**顯示器能力。
    /// 顯示器現況屬於預覽端的事，不放進 target。
    public var contentHeadroom: Double {
        dynamicRange == .sdr ? 1.0 : max(contentPeakNits / max(referenceWhiteNits, 1e-6), 1.0)
    }

    public init(
        dynamicRange: DynamicRange = .sdr,
        gamut: Gamut = .displayP3,
        transferFunction: TransferFunction = .sRGB,
        intent: OutputIntent = .appleSDR,
        referenceWhiteNits: Double = 203,
        contentPeakNits: Double = 203
    ) {
        self.dynamicRange = dynamicRange
        self.gamut = gamut
        self.transferFunction = transferFunction
        self.intent = intent
        self.referenceWhiteNits = max(referenceWhiteNits, 1e-6)
        self.contentPeakNits = max(contentPeakNits, self.referenceWhiteNits)
    }

    /// EDR 預覽用 target：content peak 直接對到目前螢幕給得出的 headroom。
    public static func edrPreview(gamut: Gamut, displayHeadroom: Double) -> RenderingTarget {
        let headroom = max(displayHeadroom, 1.0)
        return RenderingTarget(
            dynamicRange: headroom > 1 ? .fullHDR : .sdr,
            gamut: gamut, transferFunction: .linear, intent: .custom,
            referenceWhiteNits: 203, contentPeakNits: 203 * headroom
        )
    }

    public static func preset(_ intent: OutputIntent) -> RenderingTarget {
        switch intent {
        case .webSDR: return RenderingTarget(gamut: .sRGB, intent: intent)
        case .appleSDR: return RenderingTarget(gamut: .displayP3, intent: intent)
        case .appleHDR:
            return RenderingTarget(dynamicRange: .constrainedHDR, gamut: .displayP3,
                                   transferFunction: .hlg, intent: intent,
                                   contentPeakNits: 1000)
        case .hdrStandard:
            return RenderingTarget(dynamicRange: .fullHDR, gamut: .rec2020,
                                   transferFunction: .pq, intent: intent,
                                   contentPeakNits: 1000)
        case .broadcastHDR:
            return RenderingTarget(dynamicRange: .constrainedHDR, gamut: .rec2020,
                                   transferFunction: .hlg, intent: intent,
                                   contentPeakNits: 1000)
        case .archive:
            return RenderingTarget(dynamicRange: .fullHDR, gamut: .rec2020,
                                   transferFunction: .linear, intent: intent,
                                   contentPeakNits: 10000)
        case .custom: return RenderingTarget(intent: .custom)
        }
    }

    /// GUI「HDR 輸出」用的 target：PQ 或 HLG 的 Rec.2020 預設，再套上使用者選的亮度。
    public static func hdrExport(transfer: TransferFunction, referenceWhiteNits: Double,
                                 contentPeakNits: Double) -> RenderingTarget {
        let base = preset(transfer == .hlg ? .broadcastHDR : .hdrStandard)
        return RenderingTarget(dynamicRange: base.dynamicRange, gamut: base.gamut,
                               transferFunction: base.transferFunction, intent: base.intent,
                               referenceWhiteNits: referenceWhiteNits,
                               contentPeakNits: contentPeakNits)
    }

    private enum CodingKeys: String, CodingKey {
        case dynamicRange, gamut, transferFunction, intent
        case referenceWhiteNits, contentPeakNits, iccDestination
        /// 舊 sidecar 欄位，只讀不寫。
        case displayHeadroom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dynamicRange = try c.decodeIfPresent(DynamicRange.self, forKey: .dynamicRange) ?? .sdr
        gamut = try c.decodeIfPresent(Gamut.self, forKey: .gamut) ?? .displayP3
        transferFunction = try c.decodeIfPresent(TransferFunction.self, forKey: .transferFunction) ?? .sRGB
        intent = try c.decodeIfPresent(OutputIntent.self, forKey: .intent) ?? .appleSDR
        iccDestination = try c.decodeIfPresent(ICCDestination.self, forKey: .iccDestination)
        referenceWhiteNits = max(try c.decodeIfPresent(Double.self, forKey: .referenceWhiteNits) ?? 203, 1e-6)
        if let peak = try c.decodeIfPresent(Double.self, forKey: .contentPeakNits) {
            contentPeakNits = max(peak, referenceWhiteNits)
        } else {
            // 舊 sidecar 只有 displayHeadroom，換算成等值的 content peak。
            let legacy = max(try c.decodeIfPresent(Double.self, forKey: .displayHeadroom) ?? 1, 1)
            contentPeakNits = referenceWhiteNits * legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dynamicRange, forKey: .dynamicRange)
        try c.encode(gamut, forKey: .gamut)
        try c.encode(transferFunction, forKey: .transferFunction)
        try c.encode(intent, forKey: .intent)
        try c.encode(referenceWhiteNits, forKey: .referenceWhiteNits)
        try c.encode(contentPeakNits, forKey: .contentPeakNits)
        try c.encodeIfPresent(iccDestination, forKey: .iccDestination)
    }
}

/// §11 Final Curve：RGB 合併與 R / G / B 各通道各一條。
///
/// 控制點是等距的輸出值陣列（輸入 0…1 均分），空陣列代表不動。
/// 兩點以上才成為曲線；插值用 Catmull-Rom，所以在控制點上精確通過。
public struct FinalCurve: Codable, Equatable, Sendable {
    public var rgb: [Double] = []
    public var red: [Double] = []
    public var green: [Double] = []
    public var blue: [Double] = []

    public init() {}

    public var isNeutral: Bool {
        [rgb, red, green, blue].allSatisfy { Self.isIdentity($0) }
    }

    static func isIdentity(_ points: [Double]) -> Bool {
        guard points.count > 1 else { return true }
        for (i, v) in points.enumerated() {
            if abs(v - Double(i) / Double(points.count - 1)) > 1e-9 { return false }
        }
        return true
    }

    public func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        var out = v
        if !Self.isIdentity(rgb) {
            out = SIMD3(Self.evaluate(rgb, out.x), Self.evaluate(rgb, out.y), Self.evaluate(rgb, out.z))
        }
        if !Self.isIdentity(red) { out.x = Self.evaluate(red, out.x) }
        if !Self.isIdentity(green) { out.y = Self.evaluate(green, out.y) }
        if !Self.isIdentity(blue) { out.z = Self.evaluate(blue, out.z) }
        return out
    }

    /// HDR headroom（>1）的部分不進曲線，原樣加回去，避免高光被曲線夾成 SDR。
    static func evaluate(_ points: [Double], _ x: Double) -> Double {
        guard points.count > 1 else { return x }
        let over = max(x - 1, 0)
        let t = min(max(x, 0), 1) * Double(points.count - 1)
        let i = min(Int(t), points.count - 2)
        let f = t - Double(i)

        func at(_ k: Int) -> Double { points[min(max(k, 0), points.count - 1)] }
        let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
        let value = 0.5 * ((2 * p1)
            + (-p0 + p2) * f
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f
            + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f)
        return min(max(value, 0), 1) + over
    }
}

/// Color Grading 的一個調色輪：色相、色彩量與亮度偏移。
public struct GradeWheel: Codable, Equatable, Sendable {
    /// OKLCh 色相（度）。
    public var hue: Double = 0
    /// 色彩量，單位是 OKLab chroma。0 表示不染色。
    public var amount: Double = 0
    /// 亮度偏移 −1…1，作用範圍與這一輪相同。
    public var luminance: Double = 0

    public init() {}

    public var isNeutral: Bool { amount == 0 && luminance == 0 }
}

/// §11 Layer C — Finishing 的逐像素色彩參數（A-032 M1）。
public struct FinishingParameters: Codable, Equatable, Sendable {
    /// 區塊開關；關掉時渲染當成初始值，數值保留。
    public var enabled: Bool = true
    public var curve = FinalCurve()
    /// Pivot 0.5 的 S 曲線強度，0 為不變。
    public var finalContrast: Double = 0
    public var shadows = GradeWheel()
    public var midtones = GradeWheel()
    public var highlights = GradeWheel()
    /// 三輪分界的整體偏移 −1…1，負值把中間調往陰影挪。
    public var balance: Double = 0

    public init() {}

    public var isNeutral: Bool { self == FinishingParameters() }

    private enum CodingKeys: String, CodingKey {
        case enabled, curve, finalContrast, shadows, midtones, highlights, balance
    }

    /// 舊版 Finishing 的獨立染色欄位，只讀不寫（A-103）。
    private enum LegacyCodingKeys: String, CodingKey { case splitTone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var v = FinishingParameters()
        v.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? v.enabled
        v.curve = try c.decodeIfPresent(FinalCurve.self, forKey: .curve) ?? v.curve
        v.finalContrast = try c.decodeIfPresent(Double.self, forKey: .finalContrast) ?? v.finalContrast
        v.shadows = try c.decodeIfPresent(GradeWheel.self, forKey: .shadows) ?? v.shadows
        v.midtones = try c.decodeIfPresent(GradeWheel.self, forKey: .midtones) ?? v.midtones
        v.highlights = try c.decodeIfPresent(GradeWheel.self, forKey: .highlights) ?? v.highlights
        v.balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? v.balance
        // 舊染色和陰影／高光色輪用同一組亮度權重，在 OKLab a/b 上向量相加後畫面不變。
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let tone = try legacy.decodeIfPresent(SplitToneParameters.self, forKey: .splitTone) {
            v.shadows.addTint(hue: tone.shadowHue, amount: tone.shadowAmount)
            v.highlights.addTint(hue: tone.highlightHue, amount: tone.highlightAmount)
        }
        self = v
    }
}

extension GradeWheel {
    /// 把另一組（色相, 色彩量）以 OKLab a/b 向量相加併進這一輪。
    mutating func addTint(hue addHue: Double, amount addAmount: Double) {
        guard addAmount != 0 else { return }
        func vec(_ h: Double, _ a: Double) -> SIMD2<Double> {
            SIMD2(cos(h * .pi / 180), sin(h * .pi / 180)) * a
        }
        let sum = vec(hue, amount) + vec(addHue, addAmount)
        amount = (sum.x * sum.x + sum.y * sum.y).squareRoot()
        guard amount > 0 else { return }
        let deg = atan2(sum.y, sum.x) * 180 / .pi
        hue = deg < 0 ? deg + 360 : deg
    }
}

/// 顆粒強度預設；數值集中在核心，預覽與輸出共用。
public enum GrainStrength: String, CaseIterable, Sendable {
    case low, medium, strong

    public var amount: Double {
        switch self {
        case .low: 0.25
        case .medium: 0.5
        case .strong: 0.85
        }
    }

    public var displayName: String {
        switch self {
        case .low: String(localized: "低", bundle: .module)
        case .medium: String(localized: "中", bundle: .module)
        case .strong: String(localized: "強", bundle: .module)
        }
    }
}

/// 底片顆粒。強度隨亮度變化，中間調最明顯。
public struct GrainParameters: Codable, Equatable, Sendable {
    /// 顆粒強度 0…1。0 表示不加顆粒。
    public var amount: Double = 0
    /// 平均顆粒大小 0…1，換算成影像短邊的比例。
    public var size: Double = 0.35
    /// 顆粒對比 0…1，越大越硬。
    public var roughness: Double = 0.5
    /// 隨機位置與半徑；舊存檔缺少此欄位時沿用原本格點雜訊。
    public var randomized: Bool = true

    public init() {}

    public var isNeutral: Bool { amount == 0 }

    public var strength: GrainStrength? {
        GrainStrength.allCases.first { $0.amount == amount }
    }

    public mutating func apply(_ strength: GrainStrength) {
        amount = strength.amount
        randomized = true
    }

    private enum CodingKeys: String, CodingKey { case amount, size, roughness, randomized }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.35
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 0.5
        randomized = try c.decodeIfPresent(Bool.self, forKey: .randomized) ?? false
    }
}

/// §11 Output Vignette：正值壓暗四角，負值提亮四角。
public struct VignetteParameters: Codable, Equatable, Sendable {
    /// 強度 −1…1。0 表示不作用。
    public var amount: Double = 0
    /// 開始變化的位置，以「畫面中心到角落」的比例表示。
    public var midpoint: Double = 0.5
    /// 過渡的柔和度 0…1。
    public var feather: Double = 0.6

    public init() {}

    public var isNeutral: Bool { amount == 0 }
}

/// 銳化。半徑以影像短邊比例換算，預覽與輸出才一致。
public struct SharpeningParameters: Codable, Equatable, Sendable {
    /// 強度 0…1。
    public var amount: Double = 0
    /// 半徑 0…1，對應短邊的 0…0.5%。
    public var radius: Double = 0.3

    public init() {}

    public var isNeutral: Bool { amount == 0 }
}

/// 光暈：把超過門檻的高光糊開後疊回畫面。
public struct GlowParameters: Codable, Equatable, Sendable {
    /// 強度 0…1。
    public var amount: Double = 0
    /// 擴散半徑 0…1，對應短邊的 0…6%。
    public var radius: Double = 0.4
    /// 觸發門檻，低於此亮度的像素不產生光暈。
    public var threshold: Double = 0.75

    public init() {}

    public var isNeutral: Bool { amount == 0 }
}

/// 清晰度在暗部、中間調、亮部各自的作用比例 0…1。全為 1 時與不分區相同。
public struct ClarityTonalRange: Codable, Equatable, Sendable {
    public var shadows: Double = 1
    public var midtones: Double = 1
    public var highlights: Double = 1

    public init() {}

    private enum CodingKeys: String, CodingKey { case shadows, midtones, highlights }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var v = ClarityTonalRange()
        v.shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? v.shadows
        v.midtones = try c.decodeIfPresent(Double.self, forKey: .midtones) ?? v.midtones
        v.highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? v.highlights
        self = v
    }
}

/// 清晰度在暗部、中間調、亮部各自加上的量 −1…1。
public struct ClarityOffsets: Codable, Equatable, Sendable {
    public var shadows: Double = 0
    public var midtones: Double = 0
    public var highlights: Double = 0

    public init(shadows: Double = 0, midtones: Double = 0, highlights: Double = 0) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
    }

    public var isNeutral: Bool { shadows == 0 && midtones == 0 && highlights == 0 }

    private enum CodingKeys: String, CodingKey { case shadows, midtones, highlights }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        midtones = try c.decodeIfPresent(Double.self, forKey: .midtones) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
    }
}

/// §11 Layer C — Finishing 的空間性效果（A-033 M2）。
///
/// 這些效果要看鄰近像素或像素座標，同樣的輸入顏色不一定得到同樣的輸出顏色，
/// 所以進不了 3D LUT，必須在 LUT 之後以整張影像為單位處理。
public struct SpatialFinishingParameters: Codable, Equatable, Sendable {
    /// 區塊開關；關掉時渲染當成初始值，數值保留。
    public var enabled: Bool = true
    public var dehaze: Double = 0
    /// 中半徑局部對比 −1…1。
    public var clarity: Double = 0
    /// 清晰度依亮度分區的作用比例。
    public var clarityTones = ClarityTonalRange()
    /// 新版清晰度依亮度分區加減作用量；nil 保留舊倍率公式。
    public var clarityOffsets: ClarityOffsets?
    /// 小半徑細節對比 −1…1。
    public var texture: Double = 0
    public var sharpening = SharpeningParameters()
    public var glow = GlowParameters()
    public var vignette = VignetteParameters()
    public var grain = GrainParameters()

    public init() {}

    public var isNeutral: Bool {
        dehaze == 0 && !hasClarity && texture == 0
            && sharpening.isNeutral && glow.isNeutral
            && vignette.isNeutral && grain.isNeutral
    }

    /// 清晰度總值或分區加減任一有作用時，預覽與局部渲染都必須跑清晰度。
    public var hasClarity: Bool {
        clarity != 0 || (clarityOffsets.map { !$0.isNeutral } ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, dehaze, clarity, clarityTones, clarityOffsets, texture, sharpening, glow, vignette, grain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var v = SpatialFinishingParameters()
        v.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? v.enabled
        v.dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? v.dehaze
        v.clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? v.clarity
        v.clarityTones = try c.decodeIfPresent(ClarityTonalRange.self, forKey: .clarityTones) ?? v.clarityTones
        v.clarityOffsets = try c.decodeIfPresent(ClarityOffsets.self, forKey: .clarityOffsets)
        v.texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? v.texture
        v.sharpening = try c.decodeIfPresent(SharpeningParameters.self, forKey: .sharpening) ?? v.sharpening
        v.glow = try c.decodeIfPresent(GlowParameters.self, forKey: .glow) ?? v.glow
        v.vignette = try c.decodeIfPresent(VignetteParameters.self, forKey: .vignette) ?? v.vignette
        v.grain = try c.decodeIfPresent(GrainParameters.self, forKey: .grain) ?? v.grain
        self = v
    }
}

/// 一張照片的完整編輯狀態。這就是 sidecar 的內容（§15）。
public struct PortraitRetouchParameters: Codable, Equatable, Sendable {
    public var enabled = false
    public var skinToneLevel = 0
    public var skinSmoothingLevel = 0

    public init(enabled: Bool = false, skinToneLevel: Int = 0, skinSmoothingLevel: Int = 0) {
        self.enabled = enabled
        self.skinToneLevel = skinToneLevel
        self.skinSmoothingLevel = skinSmoothingLevel
    }

    private enum CodingKeys: String, CodingKey { case enabled, skinToneLevel, skinSmoothingLevel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        skinToneLevel = try container.decodeIfPresent(Int.self, forKey: .skinToneLevel) ?? 0
        skinSmoothingLevel = try container.decodeIfPresent(Int.self, forKey: .skinSmoothingLevel) ?? 0
    }
}

public struct EditParameters: Codable, Equatable, Sendable {
    public var layerA = LayerATechnical()
    public var colorEngine = ColorEngineParameters()
    public var colorMixer = ColorMixerParameters()
    public var film = FilmParameters()
    public var toneMapping = ToneMappingParameters()
    public var gamutMapping = GamutMappingParameters()
    public var optical = OpticalParameters()
    public var target = RenderingTarget()
    public var localMasks: [LocalMask] = []
    /// 已提交的局部修補資產。每張照片的修補固定在光學校正後、幾何前。
    public var retouch = RetouchParameters()
    public var portraitRetouch = PortraitRetouchParameters()
    public var finishing = FinishingParameters()
    public var spatial = SpatialFinishingParameters()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case layerA, colorEngine, colorMixer, film, toneMapping, gamutMapping, optical, target, localMasks, retouch
        case portraitRetouch
        case finishing, spatial
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layerA = try c.decode(LayerATechnical.self, forKey: .layerA)
        colorEngine = try c.decode(ColorEngineParameters.self, forKey: .colorEngine)
        colorMixer = try c.decodeIfPresent(ColorMixerParameters.self, forKey: .colorMixer)
            ?? ColorMixerParameters()
        film = try c.decodeIfPresent(FilmParameters.self, forKey: .film) ?? FilmParameters()
        toneMapping = try c.decode(ToneMappingParameters.self, forKey: .toneMapping)
        gamutMapping = try c.decode(GamutMappingParameters.self, forKey: .gamutMapping)
        optical = try c.decode(OpticalParameters.self, forKey: .optical)
        target = try c.decode(RenderingTarget.self, forKey: .target)
        localMasks = try c.decodeIfPresent([LocalMask].self, forKey: .localMasks) ?? []
        retouch = try c.decodeIfPresent(RetouchParameters.self, forKey: .retouch) ?? RetouchParameters()
        portraitRetouch = try c.decodeIfPresent(PortraitRetouchParameters.self, forKey: .portraitRetouch)
            ?? PortraitRetouchParameters()
        finishing = try c.decodeIfPresent(FinishingParameters.self, forKey: .finishing) ?? FinishingParameters()
        spatial = try c.decodeIfPresent(SpatialFinishingParameters.self, forKey: .spatial)
            ?? SpatialFinishingParameters()
    }

    /// 選擇原創風格並保存目前的參數快照；風格比例維持獨立控制。
    public mutating func applyFilmStyle(_ id: FilmStyleID) {
        film.select(id)
    }
}
