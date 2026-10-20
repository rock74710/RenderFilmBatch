import Foundation

/// Inspector 上的參數區塊。重置（單一區塊 / 全部）與 UI 分節共用同一份定義，
/// 避免兩邊各自維護一份清單而分叉。
public enum EditSection: String, CaseIterable, Codable, Sendable {
    case layerA, film, colorEngine, colorMixer, toneMapping, gamutMapping, optical, target, finishing, spatial

    public var displayName: String {
        switch self {
        case .layerA: return String(localized: "曝光", bundle: .module)
        case .film: return "Film Style"
        case .colorEngine: return "Perceptual Color Engine"
        case .colorMixer: return "Layer B — Color Mixer"
        case .toneMapping: return "Tone Mapping"
        case .gamutMapping: return "Gamut Mapping"
        case .optical: return String(localized: "光學校正", bundle: .module)
        case .target: return "Rendering Target"
        case .finishing: return "Layer C — Finishing"
        case .spatial: return String(localized: "空間性 Finishing", bundle: .module)
        }
    }
}

extension EditParameters {
    /// 實際拿去渲染的參數：關掉的區塊換成初始值，其他不動。
    /// 色彩引擎與光學校正沿用各自既有的 enabled 處理。
    public var effective: EditParameters {
        var p = self
        let d = EditParameters.defaults
        if !layerA.enabled { p.layerA = d.layerA }
        if !film.enabled { p.film = d.film }
        if !colorMixer.enabled { p.colorMixer = d.colorMixer }
        if !finishing.enabled { p.finishing = d.finishing }
        if !spatial.enabled { p.spatial = d.spatial }
        if !portraitRetouch.enabled {
            p.portraitRetouch = d.portraitRetouch
        } else {
            p.portraitRetouch.skinToneLevel = min(max(portraitRetouch.skinToneLevel, 0), 10)
            p.portraitRetouch.skinSmoothingLevel = min(max(portraitRetouch.skinSmoothingLevel, 0), 10)
        }
        return p
    }

    /// 初始值的唯一來源：各參數 struct 的成員預設值。
    public static let defaults = EditParameters()

    /// 只重置指定區塊，其他區塊完全不動。
    public mutating func reset(_ section: EditSection) {
        let d = EditParameters.defaults
        switch section {
        case .layerA: layerA = d.layerA
        case .film: film = d.film
        case .colorEngine: colorEngine = d.colorEngine
        case .colorMixer: colorMixer = d.colorMixer
        case .toneMapping: toneMapping = d.toneMapping
        case .gamutMapping: gamutMapping = d.gamutMapping
        case .optical: optical = d.optical
        case .target: target = d.target
        case .finishing: finishing = d.finishing
        case .spatial: spatial = d.spatial
        }
    }

    public mutating func resetAll() {
        self = EditParameters.defaults
    }

    /// 該區塊是否仍是初始值，供 UI 停用重置鈕。
    public func isDefault(_ section: EditSection) -> Bool {
        let d = EditParameters.defaults
        switch section {
        case .layerA: return layerA == d.layerA
        case .film: return film == d.film
        case .colorEngine: return colorEngine == d.colorEngine
        case .colorMixer: return colorMixer == d.colorMixer
        case .toneMapping: return toneMapping == d.toneMapping
        case .gamutMapping: return gamutMapping == d.gamutMapping
        case .optical: return optical == d.optical
        case .target: return target == d.target
        case .finishing: return finishing == d.finishing
        case .spatial: return spatial == d.spatial
        }
    }

    public var isDefaultAll: Bool { self == EditParameters.defaults }

    /// 和另一份參數相比，哪些區塊變了。順序固定照 `EditSection.allCases`，
    /// 這樣同一組差異每次都會得到同一個標籤。`localMasks` 不屬於任何區塊，另外比。
    public func changedSections(from other: EditParameters) -> [EditSection] {
        EditSection.allCases.filter { !equals(other, in: $0) }
    }

    /// 兩份參數在指定區塊是否相同。
    public func equals(_ other: EditParameters, in section: EditSection) -> Bool {
        switch section {
        case .layerA: return layerA == other.layerA
        case .film: return film == other.film
        case .colorEngine: return colorEngine == other.colorEngine
        case .colorMixer: return colorMixer == other.colorMixer
        case .toneMapping: return toneMapping == other.toneMapping
        case .gamutMapping: return gamutMapping == other.gamutMapping
        case .optical: return optical == other.optical
        case .target: return target == other.target
        case .finishing: return finishing == other.finishing
        case .spatial: return spatial == other.spatial
        }
    }

    /// 只把 `other` 的指定區塊搬過來，其他區塊與 `localMasks` 完全不動（INV-2）。
    public mutating func adopt(_ sections: Set<EditSection>, from other: EditParameters) {
        for section in EditSection.allCases where sections.contains(section) {
            switch section {
            case .layerA: layerA = other.layerA
            case .film: film = other.film
            case .colorEngine: colorEngine = other.colorEngine
            case .colorMixer: colorMixer = other.colorMixer
            case .toneMapping: toneMapping = other.toneMapping
            case .gamutMapping: gamutMapping = other.gamutMapping
            case .optical: optical = other.optical
            case .target: target = other.target
            case .finishing: finishing = other.finishing
            case .spatial: spatial = other.spatial
            }
        }
    }
}
