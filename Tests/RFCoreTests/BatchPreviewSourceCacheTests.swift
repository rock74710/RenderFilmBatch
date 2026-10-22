import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import RFCore

final class BatchPreviewSourceCacheTests: XCTestCase {
    func testCacheKeyIncludesFileStampAndNoiseReduction() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: url)
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0

        func load() -> BatchPreviewSource {
            loads += 1
            return .processed(processedSource(url: url, red: Double(loads) / 10))
        }

        let first = try cache.source(for: url, noiseReduction: nil, load: load)
        let hit = try cache.source(for: url, noiseReduction: nil, load: load)
        XCTAssertTrue(processedImage(first) === processedImage(hit))
        XCTAssertEqual(loads, 1)

        _ = try cache.source(for: url, noiseReduction: 0.25, load: load)
        XCTAssertEqual(loads, 2, "noise reduction belongs to the cache key")

        try Data([1, 2]).write(to: url)
        _ = try cache.source(for: url, noiseReduction: nil, load: load)
        XCTAssertEqual(loads, 3, "a changed file size invalidates the cached source")
    }

    func testSameSizeModificationTimeChangeInvalidatesCache() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("same-size.jpg")
        try Data([1, 2, 3]).write(to: url)
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0
        let load: () -> BatchPreviewSource = {
            loads += 1
            return .processed(self.processedSource(url: url, red: Double(loads) / 10))
        }

        _ = try cache.source(for: url, noiseReduction: nil, load: load)
        _ = try cache.source(for: url, noiseReduction: nil, load: load)
        XCTAssertEqual(loads, 1)

        let changedDate = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: changedDate], ofItemAtPath: url.path)
        _ = try cache.source(for: url, noiseReduction: nil, load: load)
        XCTAssertEqual(loads, 2, "mtime changes must invalidate a same-size, same-identity file")
    }

    func testAtomicSameSizeReplacementInvalidatesFileIdentity() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("replaced.jpg")
        let replacement = folder.appendingPathComponent("replacement.jpg")
        try Data([1, 2, 3]).write(to: url)
        let oldAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let oldFileNumber = try XCTUnwrap((oldAttributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        let oldDate = try XCTUnwrap(oldAttributes[.modificationDate] as? Date)
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0
        let load: () -> BatchPreviewSource = {
            loads += 1
            return .processed(self.processedSource(url: url, red: Double(loads) / 10))
        }

        _ = try cache.source(for: url, noiseReduction: nil, load: load)
        try Data([4, 5, 6]).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: replacement.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

        let newAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let newFileNumber = try XCTUnwrap((newAttributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        let newDate = try XCTUnwrap(newAttributes[.modificationDate] as? Date)
        XCTAssertNotEqual(oldFileNumber, newFileNumber)
        XCTAssertEqual(newDate.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 1)
        _ = try cache.source(for: url, noiseReduction: nil, load: load)
        XCTAssertEqual(loads, 2, "atomic replacement must invalidate a same-size, same-mtime file")
    }

    func testSourceChangingDuringDecodeIsNotCached() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("changing.jpg")
        try Data([1]).write(to: url)
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0

        let first = try cache.source(for: url, noiseReduction: nil) {
            loads += 1
            try Data([1, 2]).write(to: url)
            return .processed(processedSource(url: url, red: 0.1))
        }
        let second = try cache.source(for: url, noiseReduction: nil) {
            loads += 1
            return .processed(processedSource(url: url, red: 0.2))
        }

        XCTAssertEqual(loads, 2, "a source mutated during decode must not populate the cache")
        XCTAssertFalse(processedImage(first) === processedImage(second))
    }

    func testRemoveAllDropsCachedSources() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cleared.jpg")
        try Data([1]).write(to: url)
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0

        _ = try cache.source(for: url, noiseReduction: nil) {
            loads += 1
            return .processed(processedSource(url: url, red: Double(loads) / 10))
        }
        _ = try cache.source(for: url, noiseReduction: nil) {
            loads += 1
            return .processed(processedSource(url: url, red: Double(loads) / 10))
        }
        XCTAssertEqual(loads, 1)

        cache.removeAll()
        _ = try cache.source(for: url, noiseReduction: nil) {
            loads += 1
            return .processed(processedSource(url: url, red: Double(loads) / 10))
        }
        XCTAssertEqual(loads, 2, "explicit release must drop cached decoded sources")
    }

    func testRemoveAllDuringLoadPreventsInFlightSourceFromRepopulatingCache() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("in-flight-clear.jpg")
        try Data([1]).write(to: url)
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0

        _ = try cache.source(for: url, noiseReduction: nil) {
            loads += 1
            cache.removeAll()
            return .processed(processedSource(url: url, red: Double(loads) / 10))
        }
        _ = try cache.source(for: url, noiseReduction: nil) {
            loads += 1
            return .processed(processedSource(url: url, red: Double(loads) / 10))
        }
        XCTAssertEqual(loads, 2, "a load started before release must not reinsert its decoded source")
    }

    func testCacheUsesResolvedFileIdentityForSymlinks() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.jpg")
        let alias = folder.appendingPathComponent("alias.jpg")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0
        func load() -> BatchPreviewSource {
            loads += 1
            return .processed(processedSource(url: alias, red: Double(loads) / 10))
        }

        _ = try cache.source(for: alias, noiseReduction: nil, load: load)
        _ = try cache.source(for: alias, noiseReduction: nil, load: load)
        XCTAssertEqual(loads, 1)

        try Data([1, 2, 3]).write(to: target)
        _ = try cache.source(for: alias, noiseReduction: nil, load: load)
        XCTAssertEqual(loads, 2, "changing a symlink target invalidates the entry")
    }

    func testCacheHonorsItsDecodedByteBudget() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstURL = folder.appendingPathComponent("first.jpg")
        let secondURL = folder.appendingPathComponent("second.jpg")
        try Data([1]).write(to: firstURL)
        try Data([2]).write(to: secondURL)
        // 2×2 RGBA half-float 加上來源的估計用量，每筆為 48 bytes。
        let cache = BatchPreviewSourceCache(byteLimit: 64, entryLimit: 4)
        var firstLoads = 0

        let first = try cache.source(for: firstURL, noiseReduction: nil) {
            firstLoads += 1
            return .processed(processedSource(url: firstURL))
        }
        _ = try cache.source(for: secondURL, noiseReduction: nil) {
            .processed(processedSource(url: secondURL))
        }
        let reloaded = try cache.source(for: firstURL, noiseReduction: nil) {
            firstLoads += 1
            return .processed(processedSource(url: firstURL, red: 0.8))
        }
        XCTAssertEqual(firstLoads, 2)
        XCTAssertFalse(processedImage(first) === processedImage(reloaded),
                        "the oldest source is evicted when the byte budget is exceeded")
    }

    func testMissingFileFingerprintBypassesCache() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("missing.jpg")
        let cache = BatchPreviewSourceCache(byteLimit: 1024)
        var loads = 0
        for _ in 0..<2 {
            _ = try cache.source(for: url, noiseReduction: nil) {
                loads += 1
                return .processed(processedSource(url: url))
            }
        }
        XCTAssertEqual(loads, 2, "incomplete file metadata must not create a cache entry")
    }

    private func processedImage(_ source: BatchPreviewSource) -> CIImage {
        guard case .processed(let decoded) = source else {
            XCTFail("expected processed source")
            return CIImage(color: .black)
        }
        return decoded.image
    }

    private func processedSource(url: URL, red: Double = 0.2) -> DecodedProcessedImage {
        let image = CIImage(color: CIColor(red: red, green: 0.2, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let info = ProcessedImageInfo(format: .jpeg, width: 2, height: 2, sourceOrientation: 1,
                                      sourceTypeIdentifier: "public.jpeg", colorProfileName: nil,
                                      colorSpaceFallback: true)
        return DecodedProcessedImage(url: url, image: image, metadata: RawMetadata(),
                                     colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
                                     info: info)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
