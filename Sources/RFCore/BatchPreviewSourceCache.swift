import CoreGraphics
import Foundation

enum BatchPreviewSource: @unchecked Sendable {
    case raw(DecodedRaw)
    case processed(DecodedProcessedImage)

    var fullSize: CGSize {
        switch self {
        case .raw(let decoded): decoded.fullSize
        case .processed(let decoded): decoded.fullSize
        }
    }

    /// 估算線性 RGBA half-float 影像與色彩管理來源的合計用量。
    var estimatedCacheBytes: Int? {
        let width = fullSize.width, height = fullSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width < CGFloat(Int.max), height < CGFloat(Int.max) else { return nil }
        let pixels = width.rounded(.up) * height.rounded(.up)
        guard pixels.isFinite, pixels < CGFloat(Int.max / 12) else { return nil }
        return Int(pixels) * 12
    }
}

/// 批次預覽的有限容量最近使用快取；容量依估算的解碼影像位元組計算，不代表程序或 GPU 總記憶體上限。
/// 檔案資訊不足或解碼時檔案變動就不快取。
final class BatchPreviewSourceCache: @unchecked Sendable {
    static let defaultByteLimit = 384 * 1024 * 1024

    private struct FileStamp: Hashable {
        let requestedPath: String
        let resolvedPath: String
        let volumeNumber: UInt64
        let fileNumber: UInt64
        let fileSize: UInt64
        let modificationNanoseconds: Int64
        let creationNanoseconds: Int64?

        static func read(_ url: URL) -> FileStamp? {
            let requested = url.standardizedFileURL
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard url.isFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(
                    atPath: resolved.path),
                  let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modifiedDate = attributes[.modificationDate] as? Date,
                  let modified = nanoseconds(modifiedDate) else { return nil }
            return FileStamp(
                requestedPath: requested.path,
                resolvedPath: resolved.path,
                volumeNumber: volume,
                fileNumber: file,
                fileSize: size,
                modificationNanoseconds: modified,
                creationNanoseconds: (attributes[.creationDate] as? Date).flatMap(nanoseconds)
            )
        }

        private static func nanoseconds(_ date: Date) -> Int64? {
            let value = date.timeIntervalSince1970 * 1_000_000_000
            guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
            return Int64(value.rounded())
        }
    }

    private struct Key: Hashable {
        let file: FileStamp
        let noiseReductionBits: UInt64?
        let maxPixelSize: Int?
    }

    private struct Entry {
        let key: Key
        let source: BatchPreviewSource
        let cost: Int
    }

    private let condition = NSCondition()
    private let byteLimit: Int
    private let entryLimit: Int
    private var entries: [Entry] = [] // 最久未使用的排在最前面
    private var inFlight: Set<Key> = []
    private var cachedBytes = 0
    private var epoch: UInt64 = 0

    init(byteLimit: Int = BatchPreviewSourceCache.defaultByteLimit, entryLimit: Int = 2) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(1, entryLimit)
    }

    func source(for url: URL, noiseReduction: Double?, maxPixelSize: Int? = nil,
                load: () throws -> BatchPreviewSource) throws -> BatchPreviewSource {
        try Task<Never, Never>.checkCancellation()
        guard let file = FileStamp.read(url) else {
            let decoded = try load()
            try Task<Never, Never>.checkCancellation()
            return decoded
        }
        let key = Key(file: file, noiseReductionBits: noiseReduction?.bitPattern, maxPixelSize: maxPixelSize)

        var loadEpoch: UInt64 = 0
        condition.lock()
        while true {
            if Task<Never, Never>.isCancelled {
                condition.unlock()
                throw CancellationError()
            }
            if let index = entries.firstIndex(where: { $0.key == key }) {
                let entry = entries.remove(at: index)
                entries.append(entry)
                condition.unlock()
                return entry.source
            }
            guard inFlight.contains(key) else {
                inFlight.insert(key)
                loadEpoch = epoch
                condition.unlock()
                break
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }

        do {
            let decoded = try load()
            try Task<Never, Never>.checkCancellation()
            let finalStamp = FileStamp.read(url)
            let cost = decoded.estimatedCacheBytes
            condition.lock()
            inFlight.remove(key)
            if epoch == loadEpoch, finalStamp == file, let cost, cost <= byteLimit, byteLimit > 0 {
                entries.append(Entry(key: key, source: decoded, cost: cost))
                cachedBytes += cost
                while entries.count > entryLimit || cachedBytes > byteLimit {
                    cachedBytes -= entries.removeFirst().cost
                }
            }
            condition.broadcast()
            condition.unlock()
            return decoded
        } catch {
            condition.lock()
            inFlight.remove(key)
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    func removeAll() {
        condition.lock()
        entries.removeAll(keepingCapacity: false)
        cachedBytes = 0
        epoch &+= 1
        condition.broadcast()
        condition.unlock()
    }
}
