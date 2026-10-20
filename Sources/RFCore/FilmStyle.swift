import Foundation
import simd

/// RFCore 內建的少量原創起始風格。
public enum FilmStyleID: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case monoSoft = "mono-soft"
    case monoHard = "mono-hard"
    case cinema
    case classicCinema = "classic-cinema"
    case everyday100 = "everyday-100"
    case warmGold = "warm-gold"

    public var displayName: String { FilmStyleCatalog.profile(for: self).displayName }
}

/// 風格數值帶有版本，選取時會複製進編輯參數；它們是原創詮釋，不是實體底片量測值。
public struct FilmStyleProfile: Codable, Equatable, Sendable {
    public let id: FilmStyleID
    public let version: Int
    public let displayName: String
    public let provenance: String
    /// 只對較高相對彩度啟動的非線性收斂強度。
    public let chromaRollOff: Double
    /// 依色相分布的色相偏移與彩度倍率；各有 12 個等距控制點。
    public let hueShifts: [Double]
    public let chromaBands: [Double]
    /// 各亮度節點的彩度倍率；使用 scene OKLab L，五個節點間線性內插。
    public let chromaByLightness: [Double]
    /// OKLab a/b 偏移量，分別用於陰影與高光。
    public let shadowA: Double
    public let shadowB: Double
    /// 於中間調範圍套用的 OKLab a/b 染色偏移量。
    public let midtoneA: Double
    public let midtoneB: Double
    public let highlightA: Double
    public let highlightB: Double
    /// 與使用者現有 tone 參數相對組合的調整量。
    public let midtoneContrastScale: Double
    public let shadowShapingOffset: Double
    public let highlightRollOffOffset: Double
    /// 膚色區對風格色彩反應的保護量，0 為不保護，1 為完全保護。
    public let skinProtection: Double
    /// 膚色區對陰影、中間調與高光染色的獨立保護量。
    public let skinTintProtection: Double
    /// 黑白風格使用的 Rec.2020 工作色域 RGB 通道權重。
    public let monoWeights: [Double]

    private enum CodingKeys: String, CodingKey {
        case id, version, displayName, provenance, chromaRollOff, hueShifts, chromaBands
        case chromaByLightness
        case shadowA, shadowB, midtoneA, midtoneB, highlightA, highlightB
        case midtoneContrastScale, shadowShapingOffset, highlightRollOffOffset
        case skinProtection, skinTintProtection, monoWeights
    }

    private enum ValidationError: Error {
        case invalid(String)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FilmStyleID.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        displayName = try c.decode(String.self, forKey: .displayName)
        provenance = try c.decode(String.self, forKey: .provenance)
        chromaRollOff = try c.decode(Double.self, forKey: .chromaRollOff)
        hueShifts = try c.decode([Double].self, forKey: .hueShifts)
        chromaBands = try c.decode([Double].self, forKey: .chromaBands)
        chromaByLightness = try c.decodeIfPresent([Double].self, forKey: .chromaByLightness)
            ?? Array(repeating: 1, count: ColorEngineParameters.lightnessNodes.count)
        shadowA = try c.decode(Double.self, forKey: .shadowA)
        shadowB = try c.decode(Double.self, forKey: .shadowB)
        midtoneA = try c.decodeIfPresent(Double.self, forKey: .midtoneA) ?? 0
        midtoneB = try c.decodeIfPresent(Double.self, forKey: .midtoneB) ?? 0
        highlightA = try c.decode(Double.self, forKey: .highlightA)
        highlightB = try c.decode(Double.self, forKey: .highlightB)
        midtoneContrastScale = try c.decode(Double.self, forKey: .midtoneContrastScale)
        shadowShapingOffset = try c.decode(Double.self, forKey: .shadowShapingOffset)
        highlightRollOffOffset = try c.decode(Double.self, forKey: .highlightRollOffOffset)
        skinProtection = try c.decode(Double.self, forKey: .skinProtection)
        skinTintProtection = try c.decodeIfPresent(Double.self, forKey: .skinTintProtection) ?? skinProtection
        monoWeights = try c.decode([Double].self, forKey: .monoWeights)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c, debugDescription: "Invalid film style profile: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(version, forKey: .version)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(provenance, forKey: .provenance)
        try c.encode(chromaRollOff, forKey: .chromaRollOff)
        try c.encode(hueShifts, forKey: .hueShifts)
        try c.encode(chromaBands, forKey: .chromaBands)
        try c.encode(chromaByLightness, forKey: .chromaByLightness)
        try c.encode(shadowA, forKey: .shadowA)
        try c.encode(shadowB, forKey: .shadowB)
        try c.encode(midtoneA, forKey: .midtoneA)
        try c.encode(midtoneB, forKey: .midtoneB)
        try c.encode(highlightA, forKey: .highlightA)
        try c.encode(highlightB, forKey: .highlightB)
        try c.encode(midtoneContrastScale, forKey: .midtoneContrastScale)
        try c.encode(shadowShapingOffset, forKey: .shadowShapingOffset)
        try c.encode(highlightRollOffOffset, forKey: .highlightRollOffOffset)
        try c.encode(skinProtection, forKey: .skinProtection)
        try c.encode(skinTintProtection, forKey: .skinTintProtection)
        try c.encode(monoWeights, forKey: .monoWeights)
    }

    fileprivate var isMonochrome: Bool { id == .monoSoft || id == .monoHard }

    fileprivate var hasColorEffect: Bool {
        !isMonochrome && (chromaRollOff != 0 || hueShifts.contains(where: { $0 != 0 })
            || chromaBands.contains(where: { $0 != 1 })
            || chromaByLightness.contains(where: { $0 != 1 })
            || shadowA != 0 || shadowB != 0 || midtoneA != 0 || midtoneB != 0
            || highlightA != 0 || highlightB != 0)
    }

    fileprivate var hasToneEffect: Bool {
        midtoneContrastScale != 1 || shadowShapingOffset != 0 || highlightRollOffOffset != 0
    }

    fileprivate func validate() throws {
        guard version > 0 else { throw ValidationError.invalid("version must be positive") }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalid("displayName and provenance must not be empty")
        }
        let numbers = [chromaRollOff, shadowA, shadowB, midtoneA, midtoneB, highlightA, highlightB,
                       midtoneContrastScale, shadowShapingOffset, highlightRollOffOffset,
                       skinProtection, skinTintProtection]
            + hueShifts + chromaBands + chromaByLightness + monoWeights
        guard numbers.allSatisfy(\.isFinite) else {
            throw ValidationError.invalid("all numbers must be finite")
        }
        guard (0...1).contains(chromaRollOff) else {
            throw ValidationError.invalid("chromaRollOff must be between 0 and 1")
        }
        guard hueShifts.count == 12, hueShifts.allSatisfy({ (-45...45).contains($0) }) else {
            throw ValidationError.invalid("hueShifts must contain twelve offsets between -45 and 45")
        }
        guard chromaBands.count == 12, chromaBands.allSatisfy({ (0.25...2).contains($0) }) else {
            throw ValidationError.invalid("chromaBands must contain twelve multipliers between 0.25 and 2")
        }
        guard chromaByLightness.count == 5, chromaByLightness.allSatisfy({ (0.5...2).contains($0) }) else {
            throw ValidationError.invalid("chromaByLightness must contain five multipliers between 0.5 and 2")
        }
        guard [shadowA, shadowB, midtoneA, midtoneB, highlightA, highlightB]
            .allSatisfy({ (-0.05...0.05).contains($0) }) else {
            throw ValidationError.invalid("OKLab tint offsets must be between -0.05 and 0.05")
        }
        guard (0.5...2).contains(midtoneContrastScale) else {
            throw ValidationError.invalid("midtoneContrastScale must be between 0.5 and 2")
        }
        guard (-1...1).contains(shadowShapingOffset), (-1...1).contains(highlightRollOffOffset) else {
            throw ValidationError.invalid("tone offsets must be between -1 and 1")
        }
        guard (0...1).contains(skinProtection) else {
            throw ValidationError.invalid("skinProtection must be between 0 and 1")
        }
        guard (0...1).contains(skinTintProtection) else {
            throw ValidationError.invalid("skinTintProtection must be between 0 and 1")
        }
        guard monoWeights.count == 3, monoWeights.allSatisfy({ (0...1).contains($0) }),
              monoWeights.reduce(0, +) > 0 else {
            throw ValidationError.invalid("monoWeights must be three nonnegative responses with a positive sum")
        }
    }
}

/// 讀取並驗證隨 RFCore 發佈的原創 JSON 風格表。
public enum FilmStyleCatalog {
    private struct Document: Decodable {
        let schemaVersion: Int
        let profiles: [FilmStyleProfile]
    }

    private enum CatalogError: Error {
        case unsupportedSchema(Int)
        case missingStyles
        case duplicateStyle(FilmStyleID)
    }

    public static func decode(_ data: Data) throws -> [FilmStyleProfile] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1 else {
            throw CatalogError.unsupportedSchema(document.schemaVersion)
        }
        var indexed: [FilmStyleID: FilmStyleProfile] = [:]
        for profile in document.profiles {
            guard indexed.updateValue(profile, forKey: profile.id) == nil else {
                throw CatalogError.duplicateStyle(profile.id)
            }
        }
        guard Set(indexed.keys) == Set(FilmStyleID.allCases) else {
            throw CatalogError.missingStyles
        }
        return FilmStyleID.allCases.compactMap { indexed[$0] }
    }

    private static let indexedProfiles: [FilmStyleID: FilmStyleProfile] = {
        guard let url = Bundle.module.url(forResource: "FilmStyles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let profiles = try? decode(data) else {
            preconditionFailure("RFCore FilmStyles.json is missing or invalid")
        }
        return Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }()

    public static var profiles: [FilmStyleProfile] {
        FilmStyleID.allCases.compactMap { indexedProfiles[$0] }
    }

    public static func profile(for id: FilmStyleID) -> FilmStyleProfile {
        indexedProfiles[id]!
    }
}

/// 已選風格及其版本快照，與其他編輯控制分開保存。
public struct FilmParameters: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public private(set) var styleID: FilmStyleID = .none
    public var amount: Double = 1 {
        didSet { amount = Self.clampedAmount(amount) }
    }
    public private(set) var profileSnapshot: FilmStyleProfile
    /// 創意 LUT：`builtin:<名稱>` 或匯入 .cube 的路徑；與色彩引擎的風格分開（A-109）。
    public var lutID: String?
    public var lutAmount: Double = 1 {
        didSet { lutAmount = Self.clampedAmount(lutAmount) }
    }

    public var profileVersion: Int { profileSnapshot.version }
    public var isNeutral: Bool { !enabled || styleID == .none || amount == 0 }

    public var hasColorEffect: Bool { !isNeutral && profileSnapshot.hasColorEffect }
    public var hasMonochromeEffect: Bool { !isNeutral && profileSnapshot.isMonochrome }
    public var hasLUT: Bool { enabled && lutID != nil && lutAmount > 0 }

    public init() {
        profileSnapshot = FilmStyleCatalog.profile(for: .none)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, styleID, amount, profileSnapshot, lutID, lutAmount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        styleID = try c.decodeIfPresent(FilmStyleID.self, forKey: .styleID) ?? .none
        amount = Self.clampedAmount(try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1)
        lutID = try c.decodeIfPresent(String.self, forKey: .lutID)
        lutAmount = Self.clampedAmount(try c.decodeIfPresent(Double.self, forKey: .lutAmount) ?? 1)
        if let snapshot = try c.decodeIfPresent(FilmStyleProfile.self, forKey: .profileSnapshot) {
            guard snapshot.id == styleID else {
                throw DecodingError.dataCorruptedError(
                    forKey: .profileSnapshot, in: c,
                    debugDescription: "Film style snapshot ID must match styleID"
                )
            }
            profileSnapshot = snapshot
        } else {
            guard styleID == .none else {
                throw DecodingError.dataCorruptedError(
                    forKey: .profileSnapshot, in: c,
                    debugDescription: "A selected film style requires its saved profile snapshot"
                )
            }
            profileSnapshot = FilmStyleCatalog.profile(for: .none)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(styleID, forKey: .styleID)
        try c.encode(amount, forKey: .amount)
        try c.encode(profileSnapshot, forKey: .profileSnapshot)
        // 未選 LUT 時不寫欄位，舊照片的參數與 LUT 快取鍵保持不變（INV-1）。
        if let lutID {
            try c.encode(lutID, forKey: .lutID)
            try c.encode(lutAmount, forKey: .lutAmount)
        }
    }

    mutating func select(_ id: FilmStyleID) {
        styleID = id
        profileSnapshot = FilmStyleCatalog.profile(for: id)
    }

    func composedTone(from tone: ToneMappingParameters) -> ToneMappingParameters {
        guard !isNeutral, profileSnapshot.hasToneEffect else { return tone }
        var result = tone
        result.midtoneContrast = min(max(
            tone.midtoneContrast * pow(profileSnapshot.midtoneContrastScale, amount), 0.25
        ), 4)
        result.shadowShaping = min(max(
            tone.shadowShaping + profileSnapshot.shadowShapingOffset * amount, -1
        ), 1)
        result.highlightRollOff = min(max(
            tone.highlightRollOff + profileSnapshot.highlightRollOffOffset * amount, 0
        ), 1)
        return result
    }

    func applyingColor(to input: SIMD3<Double>) -> SIMD3<Double> {
        guard hasColorEffect else { return input }
        let profile = profileSnapshot
        var lch = input
        let amount = amount
        let sourceLightness = lch.x
        let sourceHue = lch.z
        let c = max(lch.y, 0)
        let relativeChroma = c / max(lch.x, 0.25)
        let chromaGate = Self.smoothstep(0.01, 0.04, relativeChroma)
        let skinWeight = SceneTransform.skinWeight(hue: sourceHue) * chromaGate
        let colorAllowance = 1 - skinWeight * profile.skinProtection
        let tintAllowance = 1 - skinWeight * profile.skinTintProtection
        let hueShift = SceneTransform.hueCurve(profile.hueShifts, hue: sourceHue)
        let chromaBand = SceneTransform.hueCurve(profile.chromaBands, hue: sourceHue)
        if profile.chromaRollOff != 0, c > 0 {
            // 以相對亮度的彩度量濃色，讓曝光改變時維持相近的反應。
            let saturationWeight = relativeChroma / (relativeChroma + 0.20)
            lch.y *= 1 - amount * profile.chromaRollOff * colorAllowance * saturationWeight
        }
        if hueShift != 0 {
            lch.z = (lch.z + hueShift * amount * colorAllowance).truncatingRemainder(dividingBy: 360)
            if lch.z < 0 { lch.z += 360 }
        }
        if chromaBand != 1 {
            lch.y *= 1 + (chromaBand - 1) * amount * colorAllowance
        }
        let chromaLightnessScale = SceneTransform.lightnessCurve(
            profile.chromaByLightness, lightness: sourceLightness
        )
        lch.y *= 1 + (chromaLightnessScale - 1) * amount * colorAllowance

        let shadowWeight = 1 - Self.smoothstep(0.08, 0.55, lch.x)
        let highlightWeight = Self.smoothstep(0.62, 1.15, lch.x)
        let midtoneWeight = max(0, 1 - shadowWeight - highlightWeight)
        let a = lch.y * cos(lch.z * .pi / 180)
            + amount * tintAllowance * (profile.shadowA * shadowWeight
                + profile.midtoneA * midtoneWeight + profile.highlightA * highlightWeight)
        let b = lch.y * sin(lch.z * .pi / 180)
            + amount * tintAllowance * (profile.shadowB * shadowWeight
                + profile.midtoneB * midtoneWeight + profile.highlightB * highlightWeight)
        lch.y = hypot(a, b)
        if lch.y > 1e-12 {
            lch.z = atan2(b, a) * 180 / .pi
            if lch.z < 0 { lch.z += 360 }
        }
        return lch
    }

    func applyingMonochrome(to rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard hasMonochromeEffect else { return rgb }
        let weights = profileSnapshot.monoWeights
        let weightTotal = weights.reduce(0, +)
        let gray = (rgb.x * weights[0] + rgb.y * weights[1] + rgb.z * weights[2]) / weightTotal
        return rgb + (SIMD3(repeating: gray) - rgb) * amount
    }

    private static func clampedAmount(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
