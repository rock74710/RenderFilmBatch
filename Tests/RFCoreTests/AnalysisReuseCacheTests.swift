import XCTest
import CoreImage
@testable import RFCore

final class AnalysisReuseCacheTests: XCTestCase {
    private final class WeakImageProbe {
        weak var image: CIImage?
    }

    private func image(_ width: Int = 8, _ height: Int = 6) -> CIImage {
        CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func sourceFile(_ name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rf-analysis-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func portraitAnalysis(_ marker: UInt8, extent: CGRect = CGRect(x: 0, y: 0, width: 2, height: 2),
                                  faces: [CIImage] = []) -> PortraitRetouch.Analysis {
        let width = Int(extent.width), height = Int(extent.height)
        let mask: CIImage
        if width * height > 1024 * 1024 {
            mask = CIImage(color: .white).cropped(to: extent)
        } else {
            let bytes = Data(repeating: marker, count: width * height)
            mask = CIImage(bitmapData: bytes, bytesPerRow: width, size: extent.size,
                           format: .L8, colorSpace: nil)
        }
        let faceValues = faces.map { (mask: $0, bounds: $0.extent) }
        return PortraitRetouch.Analysis(mask: mask, faces: faceValues, faceWidthRatio: Double(marker) / 255)
    }

    func testAutoWhiteBalanceReusesFullFallbackResultForSameDecodedImageAcrossExposureChanges() throws {
        let cache = AnalysisReuseCache()
        let image = image()
        let url = try sourceFile()
        let expected = AutoWhiteBalance.Result(gains: SIMD3(1, 1, 1), neutralPixelCount: 23, usedFallback: true)
        var analyses = 0

        let first = cache.autoWhiteBalance(image: image, sourceURL: url, decoderVersion: "8") { _ in
            analyses += 1
            return expected
        }
        // Exposure is intentionally absent from the AWB key: it changes portrait input only.
        let second = cache.autoWhiteBalance(image: image, sourceURL: url, decoderVersion: "8") { _ in
            analyses += 1
            return AutoWhiteBalance.Result(gains: SIMD3(2, 1, 0.5), neutralPixelCount: 1, usedFallback: false)
        }

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected, "fallback and neutral-pixel count must be reused with the gains")
        XCTAssertEqual(analyses, 1)
        XCTAssertEqual(cache.statistics.autoWhiteBalanceAnalyses, 1)
        XCTAssertEqual(cache.statistics.autoWhiteBalanceHits, 1)
    }

    func testAutoWhiteBalanceMissesWhenSourceStatOrActualDecoderChanges() throws {
        let cache = AnalysisReuseCache()
        let image = image()
        let url = try sourceFile()
        var analyses = 0
        let analyze: (CIImage) -> AutoWhiteBalance.Result = { _ in
            analyses += 1
            return AutoWhiteBalance.Result(gains: SIMD3(repeating: 1), neutralPixelCount: analyses,
                                           usedFallback: false)
        }

        _ = cache.autoWhiteBalance(image: image, sourceURL: url, decoderVersion: "8", analyze: analyze)
        try Data(repeating: 9, count: 64).write(to: url)
        _ = cache.autoWhiteBalance(image: image, sourceURL: url, decoderVersion: "8", analyze: analyze)
        _ = cache.autoWhiteBalance(image: image, sourceURL: url, decoderVersion: "9", analyze: analyze)

        XCTAssertEqual(analyses, 3)
        XCTAssertEqual(cache.statistics.autoWhiteBalanceHits, 0)
    }

    func testAutoWhiteBalanceSerializesConcurrentSameKeyAnalysisAndSeparatesDimensions() throws {
        let cache = AnalysisReuseCache()
        let source = try sourceFile()
        let firstImage = image(8, 6), otherDimensions = image(9, 6)
        let analyze: @Sendable (CIImage) -> AutoWhiteBalance.Result = { _ in
            Thread.sleep(forTimeInterval: 0.01)
            return AutoWhiteBalance.Result(gains: SIMD3(repeating: 1), neutralPixelCount: 16,
                                           usedFallback: false)
        }

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = cache.autoWhiteBalance(image: firstImage, sourceURL: source, decoderVersion: "8", analyze: analyze)
        }
        _ = cache.autoWhiteBalance(image: otherDimensions, sourceURL: source, decoderVersion: "8", analyze: analyze)

        XCTAssertEqual(cache.statistics.autoWhiteBalanceAnalyses, 2)
        XCTAssertEqual(cache.statistics.autoWhiteBalanceHits, 7)
    }

    func testAutoWhiteBalanceEntryLimitEvictsLeastRecentlyUsedImage() throws {
        let cache = AnalysisReuseCache()
        let source = try sourceFile()
        let images = (0..<9).map { image(8 + $0, 6) }
        var analyses = 0
        let analyze: (CIImage) -> AutoWhiteBalance.Result = { _ in
            analyses += 1
            return AutoWhiteBalance.Result(gains: SIMD3(repeating: 1), neutralPixelCount: 16,
                                           usedFallback: false)
        }

        for image in images {
            _ = cache.autoWhiteBalance(image: image, sourceURL: source, decoderVersion: "8", analyze: analyze)
        }
        XCTAssertEqual(cache.statistics.autoWhiteBalanceEntries, 8)
        _ = cache.autoWhiteBalance(image: images[0], sourceURL: source, decoderVersion: "8", analyze: analyze)

        XCTAssertEqual(analyses, 10, "the first image was evicted after the ninth distinct input")
        XCTAssertEqual(cache.statistics.autoWhiteBalanceEntries, 8)
    }

    func testPipelineAutoWhiteBalanceHelperReusesFullDecodedResult() throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("此測試需要 Metal 裝置") }
        let pipeline = try RenderPipeline(gpu: gpu)
        let source = try sourceFile()
        let input = image()
        var metadata = RawMetadata()
        metadata.decoderVersion = "8"
        let decoded = DecodedRaw(url: source, image: input, metadata: metadata,
                                 fullSize: input.extent.size, colorSpace: gpu.workingColorSpace)
        let expected = AutoWhiteBalance.Result(gains: SIMD3(0.91, 1, 1.08),
                                               neutralPixelCount: 27, usedFallback: true)
        var analyses = 0

        let first = pipeline.cachedAutoWhiteBalance(decoded: decoded) { _ in
            analyses += 1
            return expected
        }
        let second = pipeline.cachedAutoWhiteBalance(decoded: decoded) { _ in
            analyses += 1
            return AutoWhiteBalance.Result(gains: SIMD3(repeating: 1), neutralPixelCount: 0,
                                           usedFallback: false)
        }

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected, "the source-aware helper must retain the complete fallback result")
        XCTAssertEqual(analyses, 1, "Pipeline callers must share the decoded-image AWB cache")
    }

    func testPortraitAnalysisReusesSameExposureAndMissesWhenExposureChanges() throws {
        let cache = AnalysisReuseCache()
        let image = image()
        let url = try sourceFile()
        var analyses = 0
        let firstValue = cache.portraitAnalysis(image: image, sourceURL: url, decoderVersion: "8", exposureEV: 0.5) { _, _ in
            analyses += 1
            return self.portraitAnalysis(UInt8(analyses))
        }
        let hit = cache.portraitAnalysis(image: image, sourceURL: url, decoderVersion: "8", exposureEV: 0.5) { _, _ in
            analyses += 1
            return self.portraitAnalysis(99)
        }
        let changedExposure = cache.portraitAnalysis(image: image, sourceURL: url, decoderVersion: "8", exposureEV: 1) { _, _ in
            analyses += 1
            return self.portraitAnalysis(UInt8(analyses))
        }

        let first = try XCTUnwrap(firstValue)
        let hitValue = try XCTUnwrap(hit)
        let changedExposureValue = try XCTUnwrap(changedExposure)
        XCTAssertTrue(first.mask === hitValue.mask, "the cached portrait rasters must be the exact analyzed result")
        XCTAssertFalse(first.mask === changedExposureValue.mask, "exposure is part of portrait analysis identity")
        XCTAssertEqual(first.faceWidthRatio, hitValue.faceWidthRatio)
        XCTAssertEqual(analyses, 2)
        XCTAssertEqual(cache.statistics.portraitAnalyses, 2)
        XCTAssertEqual(cache.statistics.portraitHits, 1)
        XCTAssertEqual(cache.statistics.portraitRasterBytes, 8)
    }

    func testPortraitMissesForUnavailableSourceAndDoesNotCacheFailuresOrOversizedRasters() throws {
        let cache = AnalysisReuseCache()
        let image = image()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var analyses = 0
        let analyze: (CIImage, Double) -> PortraitRetouch.Analysis? = { _, _ in
            analyses += 1
            return self.portraitAnalysis(1)
        }
        _ = cache.portraitAnalysis(image: image, sourceURL: missing, decoderVersion: "8", exposureEV: 0, analyze: analyze)
        _ = cache.portraitAnalysis(image: image, sourceURL: missing, decoderVersion: "8", exposureEV: 0, analyze: analyze)

        let failure = { (_: CIImage, _: Double) -> PortraitRetouch.Analysis? in analyses += 1; return nil }
        _ = cache.portraitAnalysis(image: image, decoderVersion: "8", exposureEV: 0, analyze: failure)
        _ = cache.portraitAnalysis(image: image, decoderVersion: "8", exposureEV: 0, analyze: failure)

        let large = portraitAnalysis(2, extent: CGRect(x: 0, y: 0, width: 8193, height: 8193))
        _ = cache.portraitAnalysis(image: image, decoderVersion: "8", exposureEV: 1) { _, _ in analyses += 1; return large }
        _ = cache.portraitAnalysis(image: image, decoderVersion: "8", exposureEV: 1) { _, _ in analyses += 1; return large }

        XCTAssertEqual(analyses, 6)
        XCTAssertEqual(cache.statistics.portraitRasterBytes, 0, "failures and oversized masks are not retained")
    }

    func testPortraitRasterBudgetEvictsOldResultsByRetainedBitmapBytes() {
        let cache = AnalysisReuseCache()
        let image = image()
        var analyses = 0

        for exposure in 0..<5 {
            _ = cache.portraitAnalysis(image: image, decoderVersion: "8", exposureEV: Double(exposure)) { _, _ in
                analyses += 1
                return self.portraitAnalysis(UInt8(exposure), extent: CGRect(x: 0, y: 0, width: 4096, height: 4096))
            }
        }
        XCTAssertEqual(cache.statistics.portraitEntries, 4)
        XCTAssertEqual(cache.statistics.portraitRasterBytes, AnalysisReuseCache.portraitRasterBudget)

        _ = cache.portraitAnalysis(image: image, decoderVersion: "8", exposureEV: 0) { _, _ in
            analyses += 1
            return self.portraitAnalysis(0, extent: CGRect(x: 0, y: 0, width: 4096, height: 4096))
        }
        XCTAssertEqual(analyses, 6, "the oldest 16 MiB analysis was evicted")
        XCTAssertEqual(cache.statistics.portraitEntries, 4)
        XCTAssertLessThanOrEqual(cache.statistics.portraitRasterBytes, AnalysisReuseCache.portraitRasterBudget)
    }

    func testAnalysisCachesDoNotRetainInputsAndDeadIdentityCannotHit() throws {
        let cache = AnalysisReuseCache()
        let source = try sourceFile()
        let probe = WeakImageProbe()
        var autoWhiteBalanceAnalyses = 0

        autoreleasepool {
            var input: CIImage? = image()
            probe.image = input
            _ = cache.autoWhiteBalance(image: input!, sourceURL: source, decoderVersion: "8") { _ in
                autoWhiteBalanceAnalyses += 1
                return AutoWhiteBalance.Result(gains: SIMD3(repeating: 1), neutralPixelCount: 20,
                                               usedFallback: false)
            }
            _ = cache.portraitAnalysis(image: input!, sourceURL: source,
                                      decoderVersion: "8", exposureEV: 0) { _, _ in
                self.portraitAnalysis(7)
            }
            XCTAssertEqual(cache.statistics.autoWhiteBalanceEntries, 1)
            XCTAssertEqual(cache.statistics.portraitEntries, 1)
            input = nil
        }

        XCTAssertNil(probe.image, "cached results must not keep a decoded CIImage alive")
        XCTAssertEqual(cache.statistics.autoWhiteBalanceEntries, 0)
        XCTAssertEqual(cache.statistics.portraitEntries, 0)
        XCTAssertEqual(cache.statistics.portraitRasterBytes, 0)

        let replacement = image()
        _ = cache.autoWhiteBalance(image: replacement, sourceURL: source, decoderVersion: "8") { _ in
            autoWhiteBalanceAnalyses += 1
            return AutoWhiteBalance.Result(gains: SIMD3(repeating: 0.9), neutralPixelCount: 19,
                                           usedFallback: false)
        }
        XCTAssertEqual(autoWhiteBalanceAnalyses, 2)
        XCTAssertEqual(cache.statistics.autoWhiteBalanceHits, 0,
                       "an expired ObjectIdentifier must not match a later CIImage")
    }

    func testSelectionGenerationReusesFacesAndExactClassMaskPixelsOnlyForMatchingInputs() throws {
        let image = image()
        let generation = PersonParts.SelectionGeneration(image: image, rasterBudget: 16)
        let person = UUID()
        let region = CGRect(x: 1, y: 2, width: 4, height: 5)
        let expected = PersonParts.Raster(width: 2, height: 2, pixels: [0, 64, 128, 255])
        let face = PersonParts.FaceRegions(center: CGPoint(x: 3, y: 4), headRegion: region,
                                           eyebrows: [], eyes: [], lips: [], innerLips: [])
        var faceAnalyses = 0, segmentationAnalyses = 0

        _ = generation.faceRegions(for: image) { faceAnalyses += 1; return [face] }
        _ = generation.faceRegions(for: image) { faceAnalyses += 1; return [face] }
        let first = try generation.classMask(for: image, personIdentity: person, modelClass: 1, region: region) {
            segmentationAnalyses += 1
            return expected
        }
        let repeated = try generation.classMask(for: image, personIdentity: person, modelClass: 1, region: region) {
            segmentationAnalyses += 1
            return PersonParts.Raster(width: 2, height: 2, pixels: [255, 255, 255, 255])
        }
        _ = try generation.classMask(for: image, personIdentity: person, modelClass: 2, region: region) {
            segmentationAnalyses += 1; return expected
        }
        _ = try generation.classMask(for: image, personIdentity: person, modelClass: 1,
                                     region: region.offsetBy(dx: 1, dy: 0)) {
            segmentationAnalyses += 1; return expected
        }
        _ = try generation.classMask(for: image, personIdentity: UUID(), modelClass: 1, region: region) {
            segmentationAnalyses += 1; return expected
        }
        let otherImage = self.image()
        _ = try generation.classMask(for: otherImage, personIdentity: person, modelClass: 1, region: region) {
            segmentationAnalyses += 1; return expected
        }

        XCTAssertEqual(faceAnalyses, 1, "face landmarks are shared within one people generation")
        XCTAssertEqual(segmentationAnalyses, 5, "model class, region, person, and image all participate in reuse")
        XCTAssertEqual(first.pixels, repeated.pixels, "reused masks must preserve every pixel")
        XCTAssertEqual(generation.segmentationEntryCount, 4)
        XCTAssertEqual(generation.retainedRasterBytes, 16)
    }

    func testSelectionGenerationEvictsOldMasksToStayWithinRasterBudgetAndRetriesFailures() throws {
        let image = image()
        let generation = PersonParts.SelectionGeneration(image: image, rasterBudget: 4)
        let person = UUID()
        let region = CGRect(x: 0, y: 0, width: 2, height: 2)
        var analyses = 0
        let mask = PersonParts.Raster(width: 2, height: 2, pixels: [8, 16, 32, 64])

        _ = try generation.classMask(for: image, personIdentity: person, modelClass: 1, region: region) {
            analyses += 1; return mask
        }
        _ = try generation.classMask(for: image, personIdentity: person, modelClass: 2, region: region) {
            analyses += 1; return mask
        }
        XCTAssertEqual(generation.segmentationEntryCount, 1)
        XCTAssertEqual(generation.retainedRasterBytes, 4)

        _ = try generation.classMask(for: image, personIdentity: person, modelClass: 1, region: region) {
            analyses += 1; return mask
        }
        XCTAssertEqual(analyses, 3, "the first class result was evicted and must be recomputed")

        enum ExpectedFailure: Error { case failed }
        XCTAssertThrowsError(try generation.classMask(for: image, personIdentity: person,
                                                       modelClass: 3, region: region) { throw ExpectedFailure.failed })
        _ = try generation.classMask(for: image, personIdentity: person, modelClass: 3, region: region) {
            analyses += 1; return mask
        }
        XCTAssertEqual(analyses, 4)
        XCTAssertLessThanOrEqual(generation.retainedRasterBytes, 4)
    }

    func testSelectionGenerationDoesNotRetainItsSourceImage() throws {
        let probe = WeakImageProbe()
        var generation: PersonParts.SelectionGeneration?
        var cachedMask: PersonParts.Raster?
        let mask = PersonParts.Raster(width: 2, height: 2, pixels: [1, 4, 8, 16])
        autoreleasepool {
            let input = image()
            probe.image = input
            let context = PersonParts.SelectionGeneration(image: input, rasterBudget: 4)
            generation = context
            cachedMask = try? context.classMask(for: input, personIdentity: UUID(),
                                                modelClass: 1, region: CGRect(x: 0, y: 0, width: 2, height: 2)) { mask }
        }

        XCTAssertNil(probe.image, "a retained Person generation must not retain its source graph")
        XCTAssertEqual(try XCTUnwrap(cachedMask).pixels, mask.pixels)
        XCTAssertFalse(try XCTUnwrap(generation).matches(image()))
    }
}
