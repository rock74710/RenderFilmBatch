import Foundation
import CoreImage

/// Keeps object identity available for safe cache lookups without retaining a source graph.
final class WeakCIImageReference: @unchecked Sendable {
    weak var value: CIImage?

    init(_ value: CIImage) {
        self.value = value
    }
}

/// Reuses analysis results only while their immutable decoded input is still alive.
/// Source-backed entries also include file metadata, so a path alone never identifies pixels.
final class AnalysisReuseCache: @unchecked Sendable {
    static let autoWhiteBalanceVersion = "awb-v1"
    static let portraitRetouchVersion = "portrait-v1"
    static let portraitRasterBudget = 64 * 1024 * 1024
    private static let autoWhiteBalanceEntryLimit = 8
    private static let portraitEntryLimit = 64

    struct Statistics: Equatable {
        var autoWhiteBalanceAnalyses = 0
        var autoWhiteBalanceHits = 0
        var autoWhiteBalanceEntries = 0
        var portraitAnalyses = 0
        var portraitHits = 0
        var portraitEntries = 0
        var portraitRasterBytes = 0
    }

    private struct PixelSize: Hashable {
        let width: Int
        let height: Int
    }

    private struct SourceStamp: Hashable {
        let standardizedPath: String
        let systemNumber: UInt64?
        let fileNumber: UInt64?
        let fileSize: UInt64
        let modificationTime: UInt64
        let creationTime: UInt64?

        static func read(_ url: URL) -> SourceStamp? {
            guard url.isFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(
                    atPath: url.standardizedFileURL.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date,
                  modified.timeIntervalSince1970.isFinite else { return nil }
            let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970
            return SourceStamp(
                standardizedPath: url.standardizedFileURL.path,
                systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                fileSize: size,
                modificationTime: modified.timeIntervalSince1970.bitPattern,
                creationTime: created.flatMap { $0.isFinite ? $0.bitPattern : nil }
            )
        }
    }

    private struct InputKey: Hashable {
        let imageIdentity: ObjectIdentifier
        let sourceStamp: SourceStamp?
        let decoderVersion: String?
        let size: PixelSize
        let algorithmVersion: String

        static func make(image: CIImage, sourceURL: URL?, decoderVersion: String?,
                         algorithmVersion: String) -> InputKey? {
            let extent = image.extent.integral
            guard extent.width.isFinite, extent.height.isFinite,
                  extent.width > 0, extent.height > 0,
                  extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max) else { return nil }
            let width = Int(extent.width), height = Int(extent.height)
            guard width > 0, height > 0, width <= Int.max / height else { return nil }
            let stamp: SourceStamp?
            if let sourceURL {
                guard let read = SourceStamp.read(sourceURL) else { return nil }
                stamp = read
            } else {
                stamp = nil
            }
            return InputKey(imageIdentity: ObjectIdentifier(image), sourceStamp: stamp,
                            decoderVersion: decoderVersion, size: PixelSize(width: width, height: height),
                            algorithmVersion: algorithmVersion)
        }
    }

    private struct PortraitKey: Hashable {
        let input: InputKey
        let exposureBits: UInt64
    }

    private enum WorkKey: Hashable {
        case autoWhiteBalance(InputKey)
        case portrait(PortraitKey)
    }

    private struct AutoWhiteBalanceEntry {
        let key: InputKey
        let image: WeakCIImageReference
        let result: AutoWhiteBalance.Result
    }

    private struct PortraitEntry {
        let key: PortraitKey
        let image: WeakCIImageReference
        let analysis: PortraitRetouch.Analysis
        let rasterBytes: Int
    }

    private let condition = NSCondition()
    private var autoWhiteBalanceEntries: [AutoWhiteBalanceEntry] = []
    private var portraitEntries: [PortraitEntry] = []
    private var portraitRasterBytes = 0
    private var inFlight: Set<WorkKey> = []
    private var statisticsValue = Statistics()

    var statistics: Statistics {
        condition.lock()
        purgeReleasedImagesLocked()
        defer { condition.unlock() }
        var value = statisticsValue
        value.autoWhiteBalanceEntries = autoWhiteBalanceEntries.count
        value.portraitEntries = portraitEntries.count
        value.portraitRasterBytes = portraitRasterBytes
        return value
    }

    func autoWhiteBalance(
        image: CIImage,
        sourceURL: URL? = nil,
        decoderVersion: String?,
        context: CIContext
    ) -> AutoWhiteBalance.Result {
        autoWhiteBalance(image: image, sourceURL: sourceURL, decoderVersion: decoderVersion) {
            AutoWhiteBalance.analyze($0, context: context)
        }
    }

    func autoWhiteBalance(
        image: CIImage,
        sourceURL: URL? = nil,
        decoderVersion: String?,
        analyze: (CIImage) -> AutoWhiteBalance.Result
    ) -> AutoWhiteBalance.Result {
        guard let key = InputKey.make(image: image, sourceURL: sourceURL,
                                      decoderVersion: decoderVersion,
                                      algorithmVersion: Self.autoWhiteBalanceVersion) else {
            return analyzeAndCountAutoWhiteBalance(image, analyze: analyze)
        }
        let work = WorkKey.autoWhiteBalance(key)

        condition.lock()
        while true {
            purgeReleasedImagesLocked()
            if let index = autoWhiteBalanceEntries.firstIndex(where: { $0.key == key && $0.image.value === image }) {
                let entry = autoWhiteBalanceEntries.remove(at: index)
                autoWhiteBalanceEntries.append(entry)
                statisticsValue.autoWhiteBalanceHits += 1
                condition.unlock()
                return entry.result
            }
            if !inFlight.contains(work) {
                inFlight.insert(work)
                condition.unlock()
                break
            }
            condition.wait()
        }

        let result = analyzeAndCountAutoWhiteBalance(image, analyze: analyze)
        condition.lock()
        purgeReleasedImagesLocked()
        autoWhiteBalanceEntries.removeAll { $0.key == key }
        autoWhiteBalanceEntries.append(AutoWhiteBalanceEntry(key: key, image: WeakCIImageReference(image),
                                                             result: result))
        if autoWhiteBalanceEntries.count > Self.autoWhiteBalanceEntryLimit {
            autoWhiteBalanceEntries.removeFirst(autoWhiteBalanceEntries.count - Self.autoWhiteBalanceEntryLimit)
        }
        inFlight.remove(work)
        condition.broadcast()
        condition.unlock()
        return result
    }

    func portraitAnalysis(
        image: CIImage,
        sourceURL: URL? = nil,
        decoderVersion: String?,
        exposureEV: Double,
        context: CIContext
    ) -> PortraitRetouch.Analysis? {
        portraitAnalysis(image: image, sourceURL: sourceURL, decoderVersion: decoderVersion,
                         exposureEV: exposureEV) {
            PortraitRetouch.analyze($0, exposureEV: $1, context: context)
        }
    }

    func portraitAnalysis(
        image: CIImage,
        sourceURL: URL? = nil,
        decoderVersion: String?,
        exposureEV: Double,
        analyze: (CIImage, Double) -> PortraitRetouch.Analysis?
    ) -> PortraitRetouch.Analysis? {
        guard let input = InputKey.make(image: image, sourceURL: sourceURL,
                                       decoderVersion: decoderVersion,
                                       algorithmVersion: Self.portraitRetouchVersion) else {
            return analyzePortrait(image, exposureEV: exposureEV, analyze: analyze)
        }
        let key = PortraitKey(input: input, exposureBits: exposureEV.bitPattern)
        let work = WorkKey.portrait(key)

        condition.lock()
        while true {
            purgeReleasedImagesLocked()
            if let index = portraitEntries.firstIndex(where: { $0.key == key && $0.image.value === image }) {
                let entry = portraitEntries.remove(at: index)
                portraitEntries.append(entry)
                statisticsValue.portraitHits += 1
                condition.unlock()
                return entry.analysis
            }
            if !inFlight.contains(work) {
                inFlight.insert(work)
                condition.unlock()
                break
            }
            condition.wait()
        }

        let analysis = analyzePortrait(image, exposureEV: exposureEV, analyze: analyze)
        condition.lock()
        purgeReleasedImagesLocked()
        if let analysis, let rasterBytes = Self.retainedRasterBytes(of: analysis),
           rasterBytes <= Self.portraitRasterBudget {
            portraitEntries.removeAll { entry in
                guard entry.key == key else { return false }
                portraitRasterBytes -= entry.rasterBytes
                return true
            }
            portraitEntries.append(PortraitEntry(key: key, image: WeakCIImageReference(image), analysis: analysis,
                                                  rasterBytes: rasterBytes))
            portraitRasterBytes += rasterBytes
            while (portraitRasterBytes > Self.portraitRasterBudget
                   || portraitEntries.count > Self.portraitEntryLimit), !portraitEntries.isEmpty {
                portraitRasterBytes -= portraitEntries.removeFirst().rasterBytes
            }
        }
        inFlight.remove(work)
        condition.broadcast()
        condition.unlock()
        return analysis
    }

    private func analyzeAndCountAutoWhiteBalance(
        _ image: CIImage,
        analyze: (CIImage) -> AutoWhiteBalance.Result
    ) -> AutoWhiteBalance.Result {
        condition.lock()
        statisticsValue.autoWhiteBalanceAnalyses += 1
        condition.unlock()
        return analyze(image)
    }

    private func analyzePortrait(
        _ image: CIImage,
        exposureEV: Double,
        analyze: (CIImage, Double) -> PortraitRetouch.Analysis?
    ) -> PortraitRetouch.Analysis? {
        condition.lock()
        statisticsValue.portraitAnalyses += 1
        condition.unlock()
        return analyze(image, exposureEV)
    }

    /// Called only while `condition` is locked. Results cannot hit after their source identity expires.
    private func purgeReleasedImagesLocked() {
        autoWhiteBalanceEntries.removeAll { $0.image.value == nil }
        var reclaimedBytes = 0
        portraitEntries.removeAll { entry in
            guard entry.image.value == nil else { return false }
            reclaimedBytes += entry.rasterBytes
            return true
        }
        portraitRasterBytes -= reclaimedBytes
    }

    private static func retainedRasterBytes(of analysis: PortraitRetouch.Analysis) -> Int? {
        var total = 0
        let masks = [analysis.mask] + analysis.faces.map(\.mask)
        for mask in masks {
            let extent = mask.extent.integral
            guard extent.width.isFinite, extent.height.isFinite,
                  extent.width > 0, extent.height > 0,
                  extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max) else { return nil }
            let width = Int(extent.width), height = Int(extent.height)
            guard width > 0, height > 0, width <= Int.max / height else { return nil }
            let bytes = width * height
            guard total <= Int.max - bytes else { return nil }
            total += bytes
        }
        return total
    }

}
