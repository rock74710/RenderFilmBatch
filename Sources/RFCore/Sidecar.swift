import Foundation

/// §15 Non-destructive Editing：所有操作都存成 sidecar 參數，RAW 原檔永不改動（INV-6）。
public struct Sidecar: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "rfedit.json"

    public var formatVersion: Int = Sidecar.currentFormatVersion
    /// RAW 原檔的檔名（相對於 sidecar 所在目錄）。
    public var rawFileName: String
    public var versions: PipelineVersions
    public var parameters: EditParameters
    public var metadata: RawMetadata?
    public var modifiedAt: Date
    /// §15 Snapshot：這張照片自己的具名狀態，跟著 sidecar 走（A-047）。
    public var snapshots: [EditSnapshot] = []

    public init(
        rawFileName: String,
        versions: PipelineVersions = PipelineVersions(),
        parameters: EditParameters = EditParameters(),
        metadata: RawMetadata? = nil,
        modifiedAt: Date = Date(),
        snapshots: [EditSnapshot] = []
    ) {
        self.rawFileName = rawFileName
        self.versions = versions
        self.parameters = parameters
        self.metadata = metadata
        self.modifiedAt = modifiedAt
        self.snapshots = snapshots
    }

    /// 舊 sidecar 沒有 `snapshots` 欄位，缺欄位時當成空清單，不能讓整份解碼失敗（INV-1）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? Sidecar.currentFormatVersion
        rawFileName = try c.decode(String.self, forKey: .rawFileName)
        versions = try c.decode(PipelineVersions.self, forKey: .versions)
        parameters = try c.decode(EditParameters.self, forKey: .parameters)
        metadata = try c.decodeIfPresent(RawMetadata.self, forKey: .metadata)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        snapshots = try c.decodeIfPresent([EditSnapshot].self, forKey: .snapshots) ?? []
    }

    /// 某個 RAW 對應的 sidecar 路徑：`IMG_0001.ARW` → `IMG_0001.rfedit.json`。
    public static func url(forRaw raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    public static func load(forRaw raw: URL) throws -> Sidecar? {
        let url = self.url(forRaw: raw)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Sidecar.self, from: data)
    }

    /// 原子寫入，避免中途中斷留下半個檔案。
    public func save(forRaw raw: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: Sidecar.url(forRaw: raw), options: .atomic)
    }
}

/// §15 Undo / Redo 與 History。以整份 `EditParameters` 快照為單位，回復一定正確，
/// 代價是每步記憶體較大 —— 對一份幾百位元組的參數來說完全可以接受。
///
/// A-047 起改成「一條可以列出來的步驟清單＋一個游標」：undo／redo 只是把游標往前後移，
/// 所以面板可以直接顯示每一步在改什麼，也可以一次跳回任何一步。
public final class EditHistory {

    /// 歷史上的一步。`label` 是由參數差異推出來的，給面板顯示用。
    public struct Step: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let label: String
        public let parameters: EditParameters
        public let createdAt: Date

        public init(id: UUID = UUID(), label: String,
                    parameters: EditParameters, createdAt: Date = Date()) {
            self.id = id
            self.label = label
            self.parameters = parameters
            self.createdAt = createdAt
        }
    }

    /// 第一步永遠是開檔當下的狀態，之後每次修改往後接一步。
    public private(set) var steps: [Step]
    /// 目前停在第幾步。
    public private(set) var index: Int
    private let limit: Int

    public init(initial: EditParameters = EditParameters(), limit: Int = 10) {
        self.steps = [Step(label: EditHistory.openLabel, parameters: initial)]
        self.index = 0
        self.limit = max(limit, 1)
    }

    public static let openLabel = String(localized: "開啟", bundle: .module)

    public var current: EditParameters { steps[index].parameters }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < steps.count - 1 }

    /// 套用一次修改。與現值相同時不產生歷史記錄，避免拖曳滑桿塞滿歷史。
    /// 已經往回跳過的話，新的修改會蓋掉游標之後那幾步 —— 這是 undo 後再編輯的慣例。
    @discardableResult
    public func apply(_ change: (inout EditParameters) -> Void) -> Bool {
        var next = current
        change(&next)
        guard next != current else { return false }
        if let open = interactionStep, open == index, open == steps.count - 1, open > 0 {
            // 同一次拖曳：併進這次拖曳開的那一步；拖回原值就把那一步拿掉。
            let base = steps[open - 1].parameters
            if next == base {
                steps.removeLast()
                index -= 1
                interactionStep = nil
            } else {
                steps[open] = Step(id: steps[open].id,
                                   label: EditHistory.label(from: base, to: next),
                                   parameters: next)
            }
            return true
        }
        let label = EditHistory.label(from: current, to: next)
        steps.removeLast(steps.count - index - 1)
        steps.append(Step(label: label, parameters: next))
        // 第一步是開檔狀態，永遠留著（要能回到剛開檔的樣子），淘汰的是它後面最舊的那幾步。
        if steps.count > limit + 1 { steps.removeSubrange(1..<(steps.count - limit)) }
        index = steps.count - 1
        if interacting { interactionStep = index }
        return true
    }

    /// 拖曳中（滑鼠按下到放開）的修改只算一步：第一個修改新增一步，之後都併進那一步。
    private var interacting = false
    private var interactionStep: Int?

    public func beginInteraction() { interacting = true }

    public func endInteraction() {
        interacting = false
        interactionStep = nil
    }

    @discardableResult
    public func undo() -> EditParameters? {
        endInteraction()
        guard canUndo else { return nil }
        index -= 1
        return current
    }

    @discardableResult
    public func redo() -> EditParameters? {
        endInteraction()
        guard canRedo else { return nil }
        index += 1
        return current
    }

    /// 直接跳到第 `index` 步。清單本身不動，所以跳來跳去不會弄丟任何一步（INV-3）。
    @discardableResult
    public func jump(to index: Int) -> EditParameters? {
        endInteraction()
        guard steps.indices.contains(index) else { return nil }
        self.index = index
        return current
    }

    public func reset(to parameters: EditParameters) {
        endInteraction()
        steps = [Step(label: EditHistory.openLabel, parameters: parameters)]
        index = 0
    }

    /// 從前後兩份參數推一個看得懂的標籤。改到多個區塊就全部列出來。
    public static func label(from old: EditParameters, to new: EditParameters) -> String {
        var names = new.changedSections(from: old).map(\.displayName)
        if new.localMasks != old.localMasks { names.append(String(localized: "遮罩與筆刷", bundle: .module)) }
        if new.retouch != old.retouch { names.append(String(localized: "修補", bundle: .module)) }
        return names.isEmpty ? String(localized: "調整", bundle: .module) : names.joined(separator: "、")
    }
}
