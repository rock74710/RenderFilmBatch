import Foundation
import CoreImage

/// §13 Scene Intelligence Map — AI 只做分析、遮罩、估計，不接管色彩。
///
/// 這裡只定義「遮罩怎麼取得、怎麼快取、怎麼標版本」，
/// 不決定遮罩要如何影響像素；接到編輯參數是後續里程碑的事。

/// 一張 Scene Intelligence Map 裡可能有的遮罩種類（對應 §13 各項）。
public enum SceneMaskKind: String, CaseIterable, Codable, Sendable {
    case subject
    case person
    case background
    case skin
    case sky
    case depth
    case illuminant
    case noise
    case blur
    case highlightSemantic
    case saliency
}

/// 來源影像的識別字串。同一份 RAW 加上同一組 proxy 尺寸就是同一個 identity。
public struct SceneImageIdentity: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 以檔案 URL 與目前解析度組出 identity，proxy 與全解析度不共用遮罩。
    public init(url: URL, pixelSize: CGSize) {
        self.rawValue = "\(url.standardizedFileURL.path)#\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }
}

/// 單通道遮罩，值域 0…1，座標系與來源影像相同。
public struct SceneMask: @unchecked Sendable {
    public let kind: SceneMaskKind
    public let image: CIImage
    /// 產生者識別，例如 `rf.vision.subject`。
    public let source: String
    /// 產生者版本；改變時快取必須失效（INV-2 可重現）。
    public let version: String

    public init(kind: SceneMaskKind, image: CIImage, source: String, version: String) {
        self.kind = kind
        self.image = image
        self.source = source
        self.version = version
    }
}

/// 一張影像的遮罩集合。缺席代表該 kind 沒有可用來源，不是錯誤。
public struct SceneIntelligenceMap: @unchecked Sendable {
    public let identity: SceneImageIdentity
    public let masks: [SceneMaskKind: SceneMask]

    public init(identity: SceneImageIdentity, masks: [SceneMaskKind: SceneMask]) {
        self.identity = identity
        self.masks = masks
    }

    public subscript(kind: SceneMaskKind) -> SceneMask? {
        masks[kind]
    }

    /// 實際取得的 kind，依 `SceneMaskKind` 宣告順序排列，方便測試與顯示。
    public var kinds: [SceneMaskKind] {
        SceneMaskKind.allCases.filter { masks[$0] != nil }
    }
}

/// 遮罩來源。Vision、Core ML 或未來的外掛都實作這個介面。
public protocol SceneIntelligenceProvider: Sendable {
    /// 產生者版本，進入快取 key。
    var version: String { get }

    /// 回 `nil` 表示這個 provider 不支援該 kind，呼叫端據此降級（INV-3）。
    func mask(
        kind: SceneMaskKind,
        for image: CIImage,
        identity: SceneImageIdentity
    ) async throws -> SceneMask?
}

/// 記憶體內的 Scene Intelligence cache（§13 最後一項）。
///
/// 磁碟格式屬 §24 尚待決策，這裡先不落地。
public final class SceneIntelligenceCache: @unchecked Sendable {
    public struct Statistics: Equatable, Sendable {
        public var hits: Int = 0
        public var misses: Int = 0
    }

    private struct Key: Hashable {
        let identity: SceneImageIdentity
        let kind: SceneMaskKind
        let version: String
    }

    private let lock = NSLock()
    private var storage: [Key: SceneMask] = [:]
    private var stats = Statistics()

    public init() {}

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        stats = Statistics()
    }

    /// 取得指定 kind 的遮罩，只對 cache miss 的 kind 呼叫 provider。
    public func map(
        kinds: [SceneMaskKind],
        for image: CIImage,
        identity: SceneImageIdentity,
        provider: SceneIntelligenceProvider
    ) async throws -> SceneIntelligenceMap {
        var masks: [SceneMaskKind: SceneMask] = [:]
        for kind in kinds {
            let key = Key(identity: identity, kind: kind, version: provider.version)
            if let cached = cachedMask(for: key) {
                masks[kind] = cached
                continue
            }
            recordMiss()
            guard let produced = try await provider.mask(kind: kind, for: image, identity: identity) else {
                continue
            }
            store(produced, for: key)
            masks[kind] = produced
        }
        return SceneIntelligenceMap(identity: identity, masks: masks)
    }

    private func cachedMask(for key: Key) -> SceneMask? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = storage[key] else { return nil }
        stats.hits += 1
        return cached
    }

    private func recordMiss() {
        lock.lock()
        defer { lock.unlock() }
        stats.misses += 1
    }

    private func store(_ mask: SceneMask, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = mask
    }
}
