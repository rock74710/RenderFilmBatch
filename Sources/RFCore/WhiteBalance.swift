import Foundation

/// White Balance selector state. This is intentionally separate from the view so that
/// presets, manual edits, sidecar data, and rendering all share one source of truth.
public enum WhiteBalancePreset: String, Codable, CaseIterable, Sendable {
    case asShot
    case auto
    case daylight
    case cloudy
    case shade
    case tungsten
    case fluorescent
    case flash
    case custom

    public var displayName: String {
        switch self {
        case .asShot: return String(localized: "As Shot（拍攝設定）", bundle: .module)
        case .auto: return "Auto"
        case .daylight: return String(localized: "Daylight（日光）", bundle: .module)
        case .cloudy: return String(localized: "Cloudy（陰天）", bundle: .module)
        case .shade: return String(localized: "Shade（陰影）", bundle: .module)
        case .tungsten: return String(localized: "Tungsten（鎢絲燈）", bundle: .module)
        case .fluorescent: return String(localized: "Fluorescent（螢光燈）", bundle: .module)
        case .flash: return String(localized: "Flash（閃光燈）", bundle: .module)
        case .custom: return String(localized: "Custom（自訂）", bundle: .module)
        }
    }

    /// Fixed mappings are UI starting points, not a replacement for camera metadata.
    /// As Shot and Auto intentionally have no guessed numeric mapping.
    public var defaultValues: WhiteBalanceValues? {
        switch self {
        case .asShot, .auto, .custom:
            return nil
        case .daylight:
            return WhiteBalanceValues(temperature: 5500, tint: 0)
        case .cloudy:
            return WhiteBalanceValues(temperature: 6500, tint: 0.01)
        case .shade:
            return WhiteBalanceValues(temperature: 7500, tint: 0.02)
        case .tungsten:
            return WhiteBalanceValues(temperature: 3200, tint: 0)
        case .fluorescent:
            return WhiteBalanceValues(temperature: 4000, tint: 0)
        case .flash:
            return WhiteBalanceValues(temperature: 5500, tint: 0)
        }
    }
}

/// A complete user-facing WB pair in the existing pipeline's tint units.
public struct WhiteBalanceValues: Equatable, Sendable {
    public let temperature: Double
    public let tint: Double

    public init(temperature: Double, tint: Double) {
        self.temperature = temperature
        self.tint = tint
    }
}

/// A possibly incomplete WB reading. RAW metadata can omit one or both fields.
public struct WhiteBalanceReading: Equatable, Sendable {
    public let temperature: Double?
    public let tint: Double?

    public init(temperature: Double? = nil, tint: Double? = nil) {
        self.temperature = temperature
        self.tint = tint
    }

    public var isComplete: Bool { temperature != nil && tint != nil }
}

/// Codable state owned by Layer A. `nil` values mean that this component follows
/// the camera reading; they do not mean a fabricated numeric default.
public struct WhiteBalanceParameters: Codable, Equatable, Sendable {
    public static let temperatureRange: ClosedRange<Double> = 2000...12000
    /// Existing pipeline range: CIE xy y-offset, not CIRAWFilter's tint scale.
    public static let tintRange: ClosedRange<Double> = -0.1...0.1
    /// 畫面上的 Tint 用整數刻度（算圖值 × 1000），算圖仍用 `tintRange`。
    public static let tintDisplayScale = 1000.0
    public static let tintDisplayRange: ClosedRange<Double> =
        (tintRange.lowerBound * tintDisplayScale)...(tintRange.upperBound * tintDisplayScale)

    public static func tintDisplayValue(_ tint: Double) -> Double {
        tint * tintDisplayScale
    }

    public static func tintFromDisplay(_ value: Double) -> Double {
        clampedTint(value / tintDisplayScale)
    }

    public private(set) var preset: WhiteBalancePreset
    private var storedTemperature: Double?
    private var storedTint: Double?

    public var temperature: Double? {
        get { storedTemperature }
        set { setTemperature(newValue) }
    }

    public var tint: Double? {
        get { storedTint }
        set { setTint(newValue) }
    }

    public init(
        preset: WhiteBalancePreset = .asShot,
        temperature: Double? = nil,
        tint: Double? = nil
    ) {
        self.preset = preset
        self.storedTemperature = temperature.map(Self.clampedTemperature)
        self.storedTint = tint.map(Self.clampedTint)
    }

    /// Select a preset. Fixed presets populate both components together.
    /// As Shot and Auto clear numeric overrides so both components follow the camera reading.
    public mutating func select(_ preset: WhiteBalancePreset) {
        self.preset = preset
        if let values = preset.defaultValues {
            storedTemperature = Self.clampedTemperature(values.temperature)
            storedTint = Self.clampedTint(values.tint)
        } else if preset == .asShot || preset == .auto {
            storedTemperature = nil
            storedTint = nil
        }
    }

    /// Set one component from a slider or text field. Any manual component makes the
    /// selector Custom; the other component may still follow metadata for legacy states.
    public mutating func setTemperature(_ value: Double?) {
        storedTemperature = value.map(Self.clampedTemperature)
        preset = storedTemperature == nil && storedTint == nil ? .asShot : .custom
    }

    public mutating func setTint(_ value: Double?) {
        storedTint = value.map(Self.clampedTint)
        preset = storedTemperature == nil && storedTint == nil ? .asShot : .custom
    }

    /// Seed missing controls from the current display reading before the first manual edit.
    /// This carries an Auto correction into the saved Temperature + Tint pair.
    public mutating func prepareForManualAdjustment(current: WhiteBalanceReading) {
        if storedTemperature == nil, let temperature = current.temperature {
            storedTemperature = Self.clampedTemperature(temperature)
        }
        if storedTint == nil, let tint = current.tint {
            storedTint = Self.clampedTint(tint)
        }
        preset = .custom
    }

    public mutating func setManual(temperature: Double, tint: Double) {
        storedTemperature = Self.clampedTemperature(temperature)
        storedTint = Self.clampedTint(tint)
        preset = .custom
    }

    /// Resolve overrides against one camera WB reading. Auto currently follows the
    /// same camera reading because CIRAWFilter does not expose an independent Auto-WB
    /// result here; this is the integration point for a future decoder-provided value.
    public func resolved(asShot: WhiteBalanceReading) -> WhiteBalanceReading {
        WhiteBalanceReading(
            temperature: storedTemperature ?? asShot.temperature,
            tint: storedTint ?? asShot.tint
        )
    }

    public static func clampedTemperature(_ value: Double) -> Double {
        clamp(value, to: temperatureRange, fallback: 5500)
    }

    public static func clampedTint(_ value: Double) -> Double {
        clamp(value, to: tintRange, fallback: 0)
    }

    private static func clamp(
        _ value: Double, to range: ClosedRange<Double>, fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case preset, temperature, tint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPreset = try c.decodeIfPresent(WhiteBalancePreset.self, forKey: .preset) ?? .asShot
        let decodedTemperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        let decodedTint = try c.decodeIfPresent(Double.self, forKey: .tint)
        preset = decodedPreset
        storedTemperature = decodedTemperature.map(Self.clampedTemperature)
        storedTint = decodedTint.map(Self.clampedTint)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preset, forKey: .preset)
        try c.encodeIfPresent(storedTemperature, forKey: .temperature)
        try c.encodeIfPresent(storedTint, forKey: .tint)
    }
}

public extension RawMetadata {
    /// The camera WB in the existing UI/pipeline tint units. No fallback is invented.
    var asShotWhiteBalance: WhiteBalanceReading {
        WhiteBalanceReading(
            temperature: neutralTemperature,
            tint: neutralTint.map(SceneNormalization.chromaticityTint(filterTint:))
        )
    }
}
