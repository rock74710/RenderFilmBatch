import Foundation
import XCTest
@testable import RFCore

final class LUTCacheIdentityTests: XCTestCase {
    func testGeometryRetouchPortraitMasksSpatialAndUnusedUserTargetDoNotRebake() {
        var parameters = EditParameters()
        let renderTarget = RenderingTarget.preset(.webSDR)
        let metadata = RawMetadata()
        let originalKey = LUTCache.Key(parameters: parameters, target: renderTarget, metadata: metadata)

        let cache = LUTCache()
        var bakeCount = 0
        _ = cache.lut(key: originalKey) {
            bakeCount += 1
            return LUT3D(size: 1, data: [0, 0, 0, 1])
        }

        parameters.optical.geometry.straighten = 4
        parameters.optical.geometry.cropAspect = .square
        parameters.retouch.patches = [RetouchPatch(
            normalizedBounds: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            assetName: "patch.tiff", sha256: "abc", sourceSize: CGSize(width: 20, height: 20)
        )]
        parameters.portraitRetouch = PortraitRetouchParameters(
            enabled: true, skinToneLevel: 3, skinSmoothingLevel: 2
        )
        var mask = LocalMask(kind: .gradient)
        mask.exposureEV = 1
        parameters.localMasks = [mask]
        parameters.spatial.clarity = 0.5
        parameters.spatial.clarityOffsets = ClarityOffsets(midtones: 0.4)
        parameters.target = .preset(.hdrStandard)

        let irrelevantKey = LUTCache.Key(parameters: parameters, target: renderTarget, metadata: metadata)
        XCTAssertEqual(originalKey, irrelevantKey)
        _ = cache.lut(key: irrelevantKey) {
            bakeCount += 1
            return LUT3D(size: 1, data: [1, 1, 1, 1])
        }
        XCTAssertEqual(bakeCount, 1)
    }

    func testColorTransformAndActualTargetAndWhiteBalanceChangesInvalidate() {
        let base = EditParameters()
        let target = RenderingTarget.preset(.webSDR)
        let metadata = RawMetadata()
        let gains = SIMD3<Double>(1, 1, 1)
        let baseKey = LUTCache.Key(parameters: base, target: target, metadata: metadata,
                                   sceneWhiteBalanceGains: gains)
        let repeatedKey = LUTCache.Key(parameters: base, target: target, metadata: metadata,
                                       sceneWhiteBalanceGains: gains)
        XCTAssertEqual(baseKey.parameters, repeatedKey.parameters,
                       "named color inputs must encode deterministically")

        let mutations: [(String, (inout EditParameters) -> Void)] = [
            ("Layer A", { $0.layerA.exposureEV = 0.5 }),
            ("Color Engine", { $0.colorEngine.chromaStrength = 1.2 }),
            ("Color Mixer", { $0.colorMixer.bands[0].hueShift = 12 }),
            ("Film", { $0.applyFilmStyle(.warmGold) }),
            ("Tone", { $0.toneMapping.midtoneContrast = 1.2 }),
            ("Gamut", { $0.gamutMapping.knee = 0.7 }),
            ("Finishing", { $0.finishing.finalContrast = 0.2 }),
        ]
        for (name, mutate) in mutations {
            var changed = base
            mutate(&changed)
            let key = LUTCache.Key(parameters: changed, target: target, metadata: metadata,
                                   sceneWhiteBalanceGains: gains)
            XCTAssertNotEqual(baseKey, key, "\(name) changes must invalidate the LUT")
        }

        let changedTarget = RenderingTarget.preset(.hdrStandard)
        XCTAssertNotEqual(baseKey, LUTCache.Key(parameters: base, target: changedTarget,
                                                metadata: metadata,
                                                sceneWhiteBalanceGains: gains))

        XCTAssertNotEqual(baseKey, LUTCache.Key(parameters: base, target: target, metadata: metadata,
                                                sceneWhiteBalanceGains: SIMD3(1.1, 1, 1)))

        var changedMetadata = metadata
        changedMetadata.neutralTint = 14
        let metadataKey = LUTCache.Key(parameters: base, target: target, metadata: changedMetadata,
                                       sceneWhiteBalanceGains: gains)
        XCTAssertNotEqual(baseKey, metadataKey)
    }

    func testSamePathSameSizeAndModificationDateReloadsChangedCubeAndInvalidatesKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LUTCacheIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("same.cube")
        let first = cube(inverted: false)
        let second = cube(inverted: true)
        XCTAssertEqual(first.count, second.count)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try first.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)

        var parameters = EditParameters()
        parameters.film.lutID = url.path
        let target = RenderingTarget.preset(.webSDR)
        let firstKey = LUTCache.Key(parameters: parameters, target: target, metadata: RawMetadata())
        let firstLUT = try XCTUnwrap(CreativeLUTLibrary.load(id: url.path))
        let firstSample = firstLUT.sample(SIMD3(0, 0, 0))

        try second.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)

        let secondKey = LUTCache.Key(parameters: parameters, target: target, metadata: RawMetadata())
        let secondLUT = try XCTUnwrap(CreativeLUTLibrary.load(id: url.path))
        let secondSample = secondLUT.sample(SIMD3(0, 0, 0))

        XCTAssertNotEqual(firstKey, secondKey, "cube contents are part of LUT identity")
        XCTAssertNotEqual(firstSample, secondSample, "same path and mtime must reload changed content")
    }

    func testAssetChangedBetweenTransformLoadAndKeyDoesNotPopulateCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LUTCacheRaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("racing.cube")
        try cube(inverted: false).write(to: url)
        var parameters = EditParameters()
        parameters.film.lutID = url.path
        let target = RenderingTarget.preset(.webSDR)
        let transform = TargetTransform(target: target, tone: parameters.toneMapping,
                                        gamut: parameters.gamutMapping, film: parameters.film)

        try cube(inverted: true).write(to: url)
        let key = LUTCache.Key(parameters: parameters, target: target, metadata: RawMetadata())
        let cache = LUTCache()
        var bakeCount = 0
        for _ in 0..<2 {
            _ = cache.lut(key: key) {
                bakeCount += 1
                return LUT3D(size: 1, data: [Float(transform.apply(SIMD3(0, 0, 0)).x), 0, 0, 1])
            }
        }
        XCTAssertEqual(bakeCount, 2, "an asset race must not install the old snapshot under the new digest")

        _ = TargetTransform(target: target, tone: parameters.toneMapping,
                            gamut: parameters.gamutMapping, film: parameters.film)
        let stableKey = LUTCache.Key(parameters: parameters, target: target, metadata: RawMetadata())
        _ = cache.lut(key: stableKey) {
            bakeCount += 1
            return LUT3D(size: 1, data: [1, 0, 0, 1])
        }
        _ = cache.lut(key: stableKey) {
            bakeCount += 1
            return LUT3D(size: 1, data: [1, 0, 0, 1])
        }
        XCTAssertEqual(bakeCount, 3, "a stable loaded snapshot can be cached")
    }

    func testBuiltInLUTsHaveContentFingerprints() {
        for item in CreativeLUTLibrary.builtIns {
            XCTAssertNotNil(CreativeLUTLibrary.contentFingerprint(for: item.id), item.id)
        }
    }

    func testAlternatingLUTIDsReloadsChangedContentAfterEviction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LUTCacheAlternatingIDs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.cube")
        let secondURL = directory.appendingPathComponent("second.cube")
        let firstContent = cube(inverted: false)
        let changedContent = cube(inverted: true)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try firstContent.write(to: firstURL)
        try firstContent.write(to: secondURL)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: firstURL.path)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: secondURL.path)

        let firstSample = try XCTUnwrap(CreativeLUTLibrary.load(id: firstURL.path)).sample(SIMD3(0, 0, 0))
        let secondSample = try XCTUnwrap(CreativeLUTLibrary.load(id: secondURL.path)).sample(SIMD3(0, 0, 0))

        try changedContent.write(to: firstURL)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: firstURL.path)
        let changedSample = try XCTUnwrap(CreativeLUTLibrary.load(id: firstURL.path)).sample(SIMD3(0, 0, 0))
        let secondAfterAlternation = try XCTUnwrap(CreativeLUTLibrary.load(id: secondURL.path)).sample(SIMD3(0, 0, 0))
        let firstAfterAlternation = try XCTUnwrap(CreativeLUTLibrary.load(id: firstURL.path)).sample(SIMD3(0, 0, 0))

        XCTAssertNotEqual(firstSample, changedSample, "evicted IDs must reload same-path content changes")
        XCTAssertEqual(secondSample, secondAfterAlternation, "alternating IDs must retain the right LUT")
        XCTAssertEqual(changedSample, firstAfterAlternation, "alternating back must reload the latest content")
    }

    private func cube(inverted: Bool) -> Data {
        let entries = inverted
            ? ["1 1 1", "0 1 1", "1 0 1", "0 0 1", "1 1 0", "0 1 0", "1 0 0", "0 0 0"]
            : ["0 0 0", "1 0 0", "0 1 0", "1 1 0", "0 0 1", "1 0 1", "0 1 1", "1 1 1"]
        return Data(((["TITLE \"identity\"", "LUT_3D_SIZE 2"] + entries).joined(separator: "\n") + "\n").utf8)
    }
}
