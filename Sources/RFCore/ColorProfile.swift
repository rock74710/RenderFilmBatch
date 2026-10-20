import Foundation

/// 統一的基調選取；沿用既有 profile 與底片快照保存，不改舊設定的成像。
public enum ColorBasis: Hashable, CaseIterable, Sendable {
    case profile(ColorProfile)
    case film(FilmStyleID)
    /// 舊設定的混合、部分強度或關閉底片；只顯示並保留，不是新預設。
    case existing

    public static var allCases: [ColorBasis] {
        ColorProfile.allCases.map { .profile($0) }
            + FilmStyleID.allCases.filter { $0 != .none }.map { .film($0) }
    }

    public var displayName: String {
        switch self {
        case .profile(let profile): return profile.displayName
        case .film(let style): return style.displayName
        case .existing: return String(localized: "既有自訂基調", bundle: .module)
        }
    }

    public static func selection(profile: ColorProfile, film: FilmParameters) -> ColorBasis {
        guard film.styleID != .none else { return .profile(profile) }
        guard profile == .natural, film.enabled, film.amount == 1 else { return .existing }
        return .film(film.styleID)
    }
}

/// §5.5 色彩基底 profile 的內容。
///
/// profile 同時攜帶一組 tone 預設，因為量測顯示 CC 的低彩度感有相當部分來自更深的陰影、
/// CN 的濃度感來自更陡的高光；只搬色彩不搬影調會得到不像的結果。
///
/// tone 預設一律是「相對 PROVIA 的差量」，不是原廠的絕對灰階曲線。
/// 直接擬合絕對曲線會把整條原廠 log→display rendering 疊在本專案自己的 tone 之上，
/// 陰影被壓死、對比暴增，色彩引擎的成果也一起看不見。
public struct ColorProfileDefinition: Sendable {
    public let profile: ColorProfile
    /// profile 帶入的色彩曲線。
    public let hueShifts: [Double]
    public let chromaBands: [Double]
    public let hueShiftByLightness: [Double]
    public let chromaByLightness: [Double]
    public let splitTone: SplitToneParameters
    /// profile 配套的 tone mapping 預設。
    public let toneMapping: ToneMappingParameters
    /// 這組數字的來源說明，供 UI 與問題排查使用。
    public let provenance: String
}

extension ColorProfile {
    public var definition: ColorProfileDefinition {
        switch self {
        case .natural: return .natural
        case .chromeLike: return .chromeLike
        case .negLike: return .negLike
        }
    }
}

extension ColorProfileDefinition {
    /// 中性基底：所有曲線為 no-op，tone 為現行預設值。
    /// 切到 natural 等於回到導入 profile 之前的 rendering（INV-1）。
    public static let natural = ColorProfileDefinition(
        profile: .natural,
        hueShifts: Array(repeating: 0, count: ColorEngineParameters.hueControlPoints),
        chromaBands: Array(repeating: 1, count: ColorEngineParameters.hueControlPoints),
        hueShiftByLightness: Array(repeating: 1, count: ColorEngineParameters.lightnessNodes.count),
        chromaByLightness: Array(repeating: 1, count: ColorEngineParameters.lightnessNodes.count),
        splitTone: SplitToneParameters(),
        toneMapping: ToneMappingParameters(),
        provenance: String(localized: "中性起點；HNCS-like 的內容待色卡量測或美學定調後補上。", bundle: .module)
    )

    public static let chromeLike = ColorProfileDefinition(
        profile: .chromeLike,
        hueShifts: [3.41, -0.31, -3.92, -6.38, -5.68, 2.41,
                    2.82, -4.74, -9.11, -10.41, -3.35, 3.76],
        chromaBands: [0.8267, 0.8800, 0.8995, 0.8766, 0.7719, 0.7602,
                      0.9040, 0.9352, 0.8708, 0.7735, 0.6927, 0.7492],
        hueShiftByLightness: [0.5414, 0.6306, 1.0000, 1.1082, 1.0393],
        chromaByLightness: [1.1780, 0.6926, 1.0000, 1.8197, 2.1006],
        splitTone: SplitToneParameters(),
        toneMapping: {
            var t = ToneMappingParameters()
            t.shoulderStart = 0.5933
            t.highlightRollOff = 0.6178
            t.shadowShaping = -0.1711
            t.midtoneContrast = 1.1113
            return t
        }(),
        provenance: String(localized: "擬合 FLog2_to_CLASSIC-CHROME（基準 PROVIA），灰階 RMS 0.0035。", bundle: .module)
    )

    public static let negLike = ColorProfileDefinition(
        profile: .negLike,
        hueShifts: [19.20, 6.26, -5.18, -4.61, 6.64, 17.41,
                    21.08, 10.88, 2.18, -0.18, 17.47, 26.25],
        chromaBands: [1.0019, 1.0500, 0.9547, 0.7808, 0.6782, 0.6823,
                      0.8534, 0.9711, 0.8868, 0.7212, 0.6387, 0.8194],
        hueShiftByLightness: [0.6268, 0.7654, 1.0000, 0.9939, 0.7641],
        chromaByLightness: [1.2101, 1.2812, 1.0000, 1.5770, 2.0670],
        splitTone: {
            var s = SplitToneParameters()
            s.shadowHue = 155.6
            s.shadowAmount = 0.0083
            s.highlightHue = 26.8
            s.highlightAmount = 0.0111
            return s
        }(),
        toneMapping: {
            var t = ToneMappingParameters()
            t.shoulderStart = 0.7138
            t.highlightRollOff = 0.5529
            t.shadowShaping = 0.0135
            t.midtoneContrast = 1.1546
            return t
        }(),
        provenance: String(localized: "擬合 FLog2_to_CLASSIC-Neg.（基準 PROVIA），灰階 RMS 0.0169。", bundle: .module)
    )
}

extension EditParameters {
    public var colorBasis: ColorBasis {
        ColorBasis.selection(profile: colorEngine.profile, film: film)
    }

    /// 每次明確選取只使用一種基調；技術與創作調整仍留在原處。
    public mutating func applyColorBasis(_ basis: ColorBasis) {
        guard basis != .existing else { return }
        film = FilmParameters()
        colorEngine.enabled = true
        switch basis {
        case .profile(let profile):
            applyProfile(profile)
        case .film(let style):
            applyProfile(.natural)
            film.select(style)
        case .existing:
            break
        }
    }

    /// 套用一個色彩基底：換掉 profile 帶來的曲線與 tone 預設。
    ///
    /// 使用者層級的設定（開關、光源、整體彩度、膚色與高光保護、Layer A、色域與輸出）
    /// 一律保留，因為它們是疊在基底之上的偏移，不屬於基底本身。
    public mutating func applyProfile(_ profile: ColorProfile) {
        let d = profile.definition
        colorEngine.profile = profile
        colorEngine.hueShifts = d.hueShifts
        colorEngine.chromaBands = d.chromaBands
        colorEngine.hueShiftByLightness = d.hueShiftByLightness
        colorEngine.chromaByLightness = d.chromaByLightness
        colorEngine.splitTone = d.splitTone
        toneMapping = d.toneMapping
    }

    /// 目前的曲線是否仍與 profile 的預設一致（使用者尚未在基底上做偏移）。
    public var matchesProfileDefaults: Bool {
        let d = colorEngine.profile.definition
        return colorEngine.hueShifts == d.hueShifts
            && colorEngine.chromaBands == d.chromaBands
            && colorEngine.hueShiftByLightness == d.hueShiftByLightness
            && colorEngine.chromaByLightness == d.chromaByLightness
            && colorEngine.splitTone == d.splitTone
            && toneMapping == d.toneMapping
    }
}
