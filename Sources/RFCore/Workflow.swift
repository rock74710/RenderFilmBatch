import Foundation

/// §15 Snapshot：同一張照片底下的具名狀態（A-047）。
///
/// 跟 History 的差別在於「會留下來」：History 只活在這次開檔期間，
/// Snapshot 寫進 sidecar，下次開同一張照片還在。
public struct EditSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var parameters: EditParameters

    public init(id: UUID = UUID(), name: String, parameters: EditParameters) {
        self.id = id
        self.name = name
        self.parameters = parameters
    }
}

/// §15 Preset：可以套到任何一張照片的具名參數（A-047）。
///
/// 只帶被勾選的區塊，其他區塊維持目標照片原本的值。遮罩與光學校正永遠不進預設集：
/// 遮罩的座標綁定這一張構圖，光學校正綁定這一顆鏡頭，套到別張照片一定是錯的（INV-2）。
public struct EditPreset: Codable, Equatable, Identifiable, Sendable {

    /// 不允許放進預設集的區塊。
    public static let excludedSections: Set<EditSection> = [.optical]

    /// 新建預設集時預設勾選的區塊：除了光學校正以外全部。
    public static var defaultSections: Set<EditSection> {
        Set(EditSection.allCases).subtracting(excludedSections)
    }

    /// 預設集實際寫進檔案的內容。每個欄位都是選用的：沒有勾選的區塊連鍵都不會出現，
    /// 而遮罩與光學校正在這個型別裡根本沒有對應欄位，所以不可能被寫出去（INV-2）。
    struct Payload: Codable, Equatable, Sendable {
        var layerA: LayerATechnical?
        var film: FilmParameters?
        var colorEngine: ColorEngineParameters?
        var colorMixer: ColorMixerParameters?
        var toneMapping: ToneMappingParameters?
        var gamutMapping: GamutMappingParameters?
        var target: RenderingTarget?
        var finishing: FinishingParameters?
        var spatial: SpatialFinishingParameters?

        init(_ parameters: EditParameters, sections: Set<EditSection>) {
            if sections.contains(.layerA) { layerA = parameters.layerA }
            if sections.contains(.film) { film = parameters.film }
            if sections.contains(.colorEngine) { colorEngine = parameters.colorEngine }
            if sections.contains(.colorMixer) { colorMixer = parameters.colorMixer }
            if sections.contains(.toneMapping) { toneMapping = parameters.toneMapping }
            if sections.contains(.gamutMapping) { gamutMapping = parameters.gamutMapping }
            if sections.contains(.target) { target = parameters.target }
            if sections.contains(.finishing) { finishing = parameters.finishing }
            if sections.contains(.spatial) { spatial = parameters.spatial }
        }

        /// 從初始值開始，把存下來的區塊填回去。
        var parameters: EditParameters {
            var result = EditParameters.defaults
            if let layerA { result.layerA = layerA }
            if let film { result.film = film }
            if let colorEngine { result.colorEngine = colorEngine }
            if let colorMixer { result.colorMixer = colorMixer }
            if let toneMapping { result.toneMapping = toneMapping }
            if let gamutMapping { result.gamutMapping = gamutMapping }
            if let target { result.target = target }
            if let finishing { result.finishing = finishing }
            if let spatial { result.spatial = spatial }
            return result
        }
    }

    public var id: UUID
    public var name: String
    /// 這個預設集實際會覆蓋哪些區塊。
    public private(set) var sections: Set<EditSection>
    private var payload: Payload

    /// 只保留 `sections` 指到的區塊，其餘一律是初始值。
    public var parameters: EditParameters { payload.parameters }

    enum CodingKeys: String, CodingKey {
        case id, name, sections
        case payload = "parameters"
    }

    public init(id: UUID = UUID(), name: String,
                sections: Set<EditSection> = EditPreset.defaultSections,
                parameters: EditParameters) {
        self.id = id
        self.name = name
        self.sections = sections.subtracting(EditPreset.excludedSections)
        self.payload = Payload(parameters, sections: self.sections)
    }

    /// 手改過的檔案可能塞進被排除的區塊；`Payload` 沒有那些欄位，解碼時會直接被忽略。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent(Set<EditSection>.self, forKey: .sections)
            ?? EditPreset.defaultSections
        sections = raw.subtracting(EditPreset.excludedSections)
        payload = Payload(
            try c.decode(Payload.self, forKey: .payload).parameters,
            sections: sections
        )
    }

    public mutating func select(_ sections: Set<EditSection>) {
        self.sections = sections.subtracting(EditPreset.excludedSections)
        payload = Payload(payload.parameters, sections: self.sections)
    }

    /// 把這個預設集套到 `base` 上，回傳新的參數。`base` 的遮罩與未勾選區塊原封不動。
    public func applied(to base: EditParameters) -> EditParameters {
        var result = base
        result.adopt(sections, from: parameters)
        return result
    }
}

/// 使用者的預設集清單。存成單一 JSON 檔，跟照片無關，所以放在使用者資料夾而不是 sidecar。
public struct PresetLibrary: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = PresetLibrary.currentFormatVersion
    public var presets: [EditPreset] = []

    public init(presets: [EditPreset] = []) {
        self.presets = presets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? PresetLibrary.currentFormatVersion
        presets = try c.decodeIfPresent([EditPreset].self, forKey: .presets) ?? []
    }

    /// 存一個預設集。同名的會被取代而不是重複一筆，避免清單愈存愈長。
    public mutating func save(_ preset: EditPreset) {
        if let i = presets.firstIndex(where: { $0.name == preset.name }) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
    }

    public mutating func remove(id: UUID) {
        presets.removeAll { $0.id == id }
    }

    /// `~/Library/Application Support/RenderFilm/Presets.json`。
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("RenderFilm/Presets.json")
    }

    /// 檔案不存在時回傳空清單 —— 第一次使用不該當成錯誤。
    public static func load(from url: URL) throws -> PresetLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return PresetLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PresetLibrary.self, from: Data(contentsOf: url))
    }

    /// 原子寫入，並補上不存在的資料夾。
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
