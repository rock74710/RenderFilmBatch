import XCTest
import CoreImage
@testable import RFCore

final class RetouchHistoryTests: XCTestCase {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue)
    ])
    private let extent = CGRect(x: 0, y: 0, width: 128, height: 96)

    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIColor {
        CIColor(red: r, green: g, blue: b, alpha: 1,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!
    }

    private func image() -> CIImage {
        var image = CIImage(color: color(0.1, 0.1, 0.1)).cropped(to: extent)
        image = CIImage(color: color(4, 0.2, 0.1)).cropped(to: CGRect(x: 8, y: 32, width: 24, height: 26)).composited(over: image)
        return CIImage(color: color(0.2, 0.4, 3)).cropped(to: CGRect(x: 8, y: 62, width: 24, height: 26)).composited(over: image)
    }

    private func recipe(targetX: Double, sourceX: Double, sourceY: Double = 45) -> RetouchRecipe {
        RetouchRecipe(mode: .clone, outputPoints: [MaskPoint(x: targetX / 128, y: 45.0 / 96)],
            outputRadius: 0.07, source: MaskPoint(x: sourceX / 128, y: sourceY / 96), optical: OpticalParameters())
    }

    private func sample(_ image: CIImage, x: Int, y: Int) -> SIMD4<Float> {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return SIMD4(pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private func withRaw(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("test.arw"))
    }

    func testReeditingEarlierCloneRecalculatesDependentCloneAndRoundTrips() throws {
        try withRaw { raw in
            let base = image()
            let first = try RetouchHistory.makePatch(image: base, recipe: recipe(targetX: 50, sourceX: 20), rawURL: raw, context: context)
            let intermediate = try RetouchAssetStore.applying(RetouchParameters(patches: [first]), to: base, forRaw: raw)
            let second = try RetouchHistory.makePatch(image: intermediate, recipe: recipe(targetX: 85, sourceX: 50), rawURL: raw, context: context)
            let before = [first, second]
            let old = try RetouchAssetStore.applying(RetouchParameters(patches: before), to: base, forRaw: raw)
            XCTAssertGreaterThan(sample(old, x: 85, y: 45).x, 3.9)
            var changed = try XCTUnwrap(first.recipe)
            changed.source = MaskPoint(x: 20.0 / 128, y: 75.0 / 96)
            let after = try RetouchHistory.rebuilding(before, startingAt: 0, replacement: changed,
                image: base, optical: OpticalParameters(), rawURL: raw, context: context)
            XCTAssertEqual(after[0].recipe?.id, first.recipe?.id)
            XCTAssertNotEqual(after[1].assetName, second.assetName)
            let result = try RetouchAssetStore.applying(RetouchParameters(patches: after), to: base, forRaw: raw)
            XCTAssertGreaterThan(sample(result, x: 50, y: 45).z, 2.9)
            XCTAssertGreaterThan(sample(result, x: 85, y: 45).z, 2.9)
            XCTAssertEqual(sample(result, x: 110, y: 10), sample(base, x: 110, y: 10))

            var parameters = EditParameters()
            parameters.retouch.patches = after
            try Sidecar(rawFileName: raw.lastPathComponent, parameters: parameters).save(forRaw: raw)
            let loaded = try XCTUnwrap(Sidecar.load(forRaw: raw)).parameters
            XCTAssertEqual(loaded.retouch.patches, after)
            let reopened = try RetouchAssetStore.applying(loaded.retouch, to: base, forRaw: raw)
            XCTAssertEqual(sample(reopened, x: 85, y: 45), sample(result, x: 85, y: 45))
            let history = EditHistory(initial: parameters)
            history.apply { $0.retouch.patches = before }
            history.undo()
            XCTAssertEqual(history.current.retouch.patches, after)
            history.redo()
            XCTAssertEqual(history.current.retouch.patches, before)
        }
    }

    func testDeletionRebuildsLocalSuccessorsButKeepsGeneratedPixels() throws {
        try withRaw { raw in
            let base = image()
            let first = try RetouchHistory.makePatch(image: base, recipe: recipe(targetX: 50, sourceX: 20), rawURL: raw, context: context)
            let intermediate = try RetouchAssetStore.applying(RetouchParameters(patches: [first]), to: base, forRaw: raw)
            let second = try RetouchHistory.makePatch(image: intermediate, recipe: recipe(targetX: 85, sourceX: 50), rawURL: raw, context: context)
            let aiRecipe = RetouchRecipe(mode: .remove, outputPoints: [MaskPoint(x: 0.8, y: 0.8)],
                outputRadius: 0.04, optical: OpticalParameters(), useAI: true)
            let generated = try RetouchHistory.makePatch(image: intermediate, recipe: aiRecipe, rawURL: raw,
                context: context, aiFill: { image, _ in image })
            let result = try RetouchHistory.rebuilding([first, second, generated], startingAt: 0, deleting: true,
                image: base, optical: OpticalParameters(), rawURL: raw, context: context)
            XCTAssertEqual(result.count, 2)
            let composed = try RetouchAssetStore.applying(RetouchParameters(patches: result), to: base, forRaw: raw)
            XCTAssertEqual(sample(composed, x: 85, y: 45).x, 0.1, accuracy: 0.001)
            XCTAssertEqual(result[1].assetName, generated.assetName)
            XCTAssertEqual(result[1].sha256, generated.sha256)
            XCTAssertEqual(result[1].needsReview, true)
        }
    }

    func testInvalidSourceDoesNotReplaceOriginalHistory() throws {
        try withRaw { raw in
            let first = try RetouchHistory.makePatch(image: image(), recipe: recipe(targetX: 50, sourceX: 20), rawURL: raw, context: context)
            let before = [first]
            var invalid = try XCTUnwrap(first.recipe)
            invalid.source = MaskPoint(x: 0, y: 0)
            XCTAssertThrowsError(try RetouchHistory.rebuilding(before, startingAt: 0, replacement: invalid,
                image: image(), optical: OpticalParameters(), rawURL: raw, context: context))
            XCTAssertEqual(before, [first])
            XCTAssertNoThrow(try RetouchAssetStore.load(first, forRaw: raw))
        }
    }

    func testLegacyPatchDecodesWithoutRecipeAndRemainsFixed() throws {
        let json = "{\"normalizedBounds\":[[0.1,0.1],[0.2,0.2]],\"assetName\":\"legacy.tiff\",\"sha256\":\"abc\",\"sourceSize\":[128,96]}"
        let patch = try JSONDecoder().decode(RetouchPatch.self, from: Data(json.utf8))
        XCTAssertNil(patch.recipe)
        XCTAssertNil(patch.needsReview)
    }

    func testGeometryChangesReprojectButOpticalBaseChangesSuspendPatch() throws {
        let recipe = recipe(targetX: 50, sourceX: 20)
        var optical = OpticalParameters()
        optical.geometry.straighten = 5
        optical.geometry.verticalPerspective = 20
        optical.geometry.cropAspect = .square
        XCTAssertTrue(recipe.matchesOpticalBase(optical))
        let displayed = try XCTUnwrap(recipe.displayedPoints(geometry: optical.geometry, extent: extent).first)
        let mapped = try XCTUnwrap(optical.geometry.inputPoint(forOutput: displayed, extent: extent))
        XCTAssertEqual(mapped.x, 50.0 / 128, accuracy: 0.00001)
        XCTAssertEqual(mapped.y, 45.0 / 96, accuracy: 0.00001)
        let patch = RetouchPatch(normalizedBounds: CGRect(x: 0.3, y: 0.4, width: 0.1, height: 0.1),
            assetName: "x.tiff", sha256: "abc", sourceSize: extent.size, recipe: recipe)
        XCTAssertEqual(RetouchParameters(patches: [patch]).applicable(to: optical).patches.count, 1)
        optical.enabled = false
        XCTAssertFalse(recipe.matchesOpticalBase(optical))
        XCTAssertTrue(RetouchParameters(patches: [patch]).applicable(to: optical).patches.isEmpty)
    }

    func testOpacityAndFeatherUseSameSavedMaskAfterReopen() throws {
        var half = recipe(targetX: 50, sourceX: 20)
        half.opacity = 0.5
        half.feather = 0.4
        let decoded = try JSONDecoder().decode(RetouchRecipe.self, from: JSONEncoder().encode(half))
        let a = try half.brushMask(extent: extent), b = try decoded.brushMask(extent: extent)
        XCTAssertEqual(a.bytes, b.bytes)
        XCTAssertEqual(a.bounds, b.bounds)
        XCTAssertLessThanOrEqual(a.bytes.max() ?? 255, 128)
        XCTAssertThrowsError(try GeometryParameters().inputBrushMask(forOutput: half.outputPoints, radius: half.outputRadius,
            extent: extent, featherOutside: true, feather: -.infinity, opacity: 1))
    }
}
