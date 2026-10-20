import XCTest
import CoreImage
@testable import RFCore

final class LocalMaskTests: XCTestCase {
    private struct SelectionProvider: SceneIntelligenceProvider {
        let version = "test"
        let empty: Bool
        func mask(kind: SceneMaskKind, for image: CIImage, identity: SceneImageIdentity) async throws -> SceneMask? {
            let base = CIImage(color: .black).cropped(to: image.extent)
            let selection = empty ? base : CIImage(color: .white)
                .cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50)).composited(over: base)
            return SceneMask(kind: kind, image: selection, source: "test", version: version)
        }
    }

    func testAIGenerationSelectsBackgroundAndRejectsEmptyPerson() async throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let src = source(gpu)
        let data = try await AIMaskSelection.generate(target: .background, image: src,
            identity: .init(rawValue: "test"), context: gpu.ciContext, provider: SelectionProvider(empty: false))
        var mask = LocalMask(kind: .brush)
        mask.aiSelection = data
        mask.feather = 0
        mask.exposureEV = 1
        let renderer = try MaskRenderer()
        let result = try renderer.apply([mask], to: src)
        XCTAssertEqual(sample(result, gpu, x: 20, y: 80), 0.18, accuracy: 0.01)
        XCTAssertEqual(sample(result, gpu, x: 20, y: 20), 0.36, accuracy: 0.01)
        do {
            _ = try await AIMaskSelection.generate(target: .person, image: src,
                identity: .init(rawValue: "test"), context: gpu.ciContext, provider: SelectionProvider(empty: true))
            XCTFail("空選區不應建立遮罩")
        } catch AIMaskSelection.Failure.noSelection { }
    }

    func testAISelectionPersistsAndBrushRefinesAtEveryResolution() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        let selected = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)))
        var mask = LocalMask(kind: .brush)
        mask.feather = 0
        mask.aiSelection = try AIMaskSelection.encode(selected, context: gpu.ciContext)
        mask.strokes = [
            .init(points: [.init(x: 0.5, y: 0.8)], radius: 0.08, erasing: true),
            .init(points: [.init(x: 0.5, y: 0.2)], radius: 0.08)
        ]
        let restored = try JSONDecoder().decode(LocalMask.self, from: JSONEncoder().encode(mask))
        XCTAssertEqual(restored, mask)
        for size: CGFloat in [100, 200] {
            let src = source(gpu, size: size).transformed(by: .init(translationX: 31, y: 47))
            let image = try renderer.image(for: restored, source: src)
            XCTAssertEqual(image.extent, src.extent)
            XCTAssertGreaterThan(sample(image, gpu, x: 31 + size * 0.2, y: 47 + size * 0.8), 0.99)
            XCTAssertLessThan(sample(image, gpu, x: 31 + size * 0.5, y: 47 + size * 0.8), 0.01)
            XCTAssertGreaterThan(sample(image, gpu, x: 31 + size * 0.5, y: 47 + size * 0.2), 0.99)
            XCTAssertLessThan(sample(image, gpu, x: 31 + size * 0.2, y: 47 + size * 0.2), 0.01)
        }
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mask)) as? [String: Any])
        legacy.removeValue(forKey: "aiSelection")
        XCTAssertNil(try JSONDecoder().decode(LocalMask.self, from: JSONSerialization.data(withJSONObject: legacy)).aiSelection)
        mask.strokes = []
        mask.inverted = true
        mask.opacity = 0.5
        let inverted = try renderer.image(for: mask, source: source(gpu))
        XCTAssertEqual(sample(inverted, gpu, x: 20, y: 80), 0, accuracy: 0.01)
        XCTAssertEqual(sample(inverted, gpu, x: 20, y: 20), 0.5, accuracy: 0.01)
        var parameters = EditParameters()
        parameters.localMasks = [restored]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("ai.dng")
        try Sidecar(rawFileName: raw.lastPathComponent, parameters: parameters).save(forRaw: raw)
        XCTAssertEqual(try Sidecar.load(forRaw: raw)?.parameters, parameters)
        let history = EditHistory()
        history.apply { $0 = parameters }
        XCTAssertTrue(try XCTUnwrap(history.undo()).localMasks.isEmpty)
        XCTAssertEqual(history.redo(), parameters)
    }

    func testLegacyAndMaskRoundTrip() throws {
        var p = EditParameters()
        var mask = LocalMask(kind: .brush)
        mask.strokes = [MaskStroke(points: [.init(x: 0.2, y: 0.8), .init(x: 0.8, y: 0.8)], radius: 0.05)]
        p.localMasks = [mask]
        XCTAssertEqual(try JSONDecoder().decode(EditParameters.self, from: JSONEncoder().encode(p)), p)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        json.removeValue(forKey: "localMasks")
        XCTAssertTrue(try JSONDecoder().decode(EditParameters.self, from: JSONSerialization.data(withJSONObject: json)).localMasks.isEmpty)
        let history = EditHistory()
        history.apply { $0 = p }
        XCTAssertTrue(try XCTUnwrap(history.undo()).localMasks.isEmpty)
        XCTAssertEqual(history.redo(), p)
        p.resetAll()
        XCTAssertTrue(p.localMasks.isEmpty)
    }

    private func source(_ gpu: GPUContext, size: CGFloat = 100) -> CIImage {
        CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, colorSpace: gpu.workingColorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func sample(_ image: CIImage, _ gpu: GPUContext, x: CGFloat, y: CGFloat, channel: Int = 0) -> Float {
        var p = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(image, toBitmap: &p, rowBytes: 16,
                             bounds: CGRect(x: x, y: y, width: 1, height: 1),
                             format: .RGBAf, colorSpace: gpu.workingColorSpace)
        return p[channel]
    }

    func testGradientOrientationInversionAndDegenerateDrag() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        let src = source(gpu)
        var m = LocalMask(kind: .gradient)
        m.start = .init(x: 0.5, y: 0.25)
        m.end = .init(x: 0.5, y: 0.75)
        let mask = try renderer.image(for: m, source: src)
        XCTAssertLessThan(sample(mask, gpu, x: 50, y: 5), 0.01)
        XCTAssertGreaterThan(sample(mask, gpu, x: 50, y: 95), 0.99)
        m.inverted = true
        XCTAssertGreaterThan(sample(try renderer.image(for: m, source: src), gpu, x: 50, y: 5), 0.99)
        m.end = m.start
        m.inverted = false
        XCTAssertEqual(sample(try renderer.image(for: m, source: src), gpu, x: 50, y: 50), 0, accuracy: 0.001)
    }

    func testBrushConnectsSamplesErasesAndScales() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        var m = LocalMask(kind: .brush)
        m.feather = 0
        m.strokes = [.init(points: [.init(x: 0.1, y: 0.8), .init(x: 0.9, y: 0.8)], radius: 0.05)]
        for size: CGFloat in [100, 200] {
            let mask = try renderer.image(for: m, source: source(gpu, size: size))
            XCTAssertGreaterThan(sample(mask, gpu, x: size * 0.5, y: size * 0.8), 0.99)
            XCTAssertLessThan(sample(mask, gpu, x: size * 0.5, y: size * 0.2), 0.01)
        }
        m.strokes.append(.init(points: [.init(x: 0.5, y: 0.8)], radius: 0.08, erasing: true))
        XCTAssertLessThan(sample(try renderer.image(for: m, source: source(gpu)), gpu, x: 50, y: 80), 0.01)
    }

    func testLuminanceRangeAndLocalExposurePreserveHDR() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        let src = source(gpu)
        var m = LocalMask(kind: .luminance)
        m.lowerEV = -1; m.upperEV = 1; m.feather = 0
        XCTAssertGreaterThan(sample(try renderer.image(for: m, source: src), gpu, x: 50, y: 50), 0.99)
        m.exposureEV = 4
        let adjusted = try renderer.apply([m], to: src)
        XCTAssertEqual(sample(adjusted, gpu, x: 50, y: 50), 2.88, accuracy: 0.01)
        m.enabled = false
        XCTAssertEqual(sample(try renderer.apply([m], to: src), gpu, x: 50, y: 50), 0.18, accuracy: 0.001)
    }

    func testColorRangeWrapsRedAndRejectsNeutral() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        var m = LocalMask(kind: .colorRange)
        m.hue = 359; m.hueWidth = 15; m.feather = 0
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, colorSpace: gpu.workingColorSpace)!)
            .cropped(to: source(gpu).extent)
        XCTAssertGreaterThan(sample(try renderer.image(for: m, source: red), gpu, x: 50, y: 50), 0.99)
        XCTAssertLessThan(sample(try renderer.image(for: m, source: source(gpu)), gpu, x: 50, y: 50), 0.01)
    }

    func testOverlappingMasksUseOriginalSelectionAndOpacity() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        var m = LocalMask(kind: .luminance)
        m.lowerEV = -0.1; m.upperEV = 0.1; m.feather = 0
        m.opacity = 0.5; m.exposureEV = 2
        // 每個選區均來自原圖：兩個半強度 +2EV 合計 +2EV。
        let output = try renderer.apply([m, m], to: source(gpu))
        XCTAssertEqual(sample(output, gpu, x: 50, y: 50), 0.72, accuracy: 0.003)
    }

    func testLocalColorAdjustmentUsesMaskAndPreservesLegacySidecar() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        let src = CIImage(color: CIColor(red: 0.3, green: 0.18, blue: 0.1,
                                         colorSpace: gpu.workingColorSpace)!).cropped(to: source(gpu).extent)
        var mask = LocalMask(kind: .gradient)
        mask.colorAdjustment = .init(temperature: 1000, tint: 10, chroma: 1.5)
        let result = try renderer.apply([mask], to: src)
        XCTAssertEqual(sample(result, gpu, x: 50, y: 5), sample(src, gpu, x: 50, y: 5), accuracy: 0.001)
        XCTAssertNotEqual(sample(result, gpu, x: 50, y: 95), sample(src, gpu, x: 50, y: 95))
        let restored = try JSONDecoder().decode(LocalMask.self, from: JSONEncoder().encode(mask))
        XCTAssertEqual(restored.colorAdjustment, mask.colorAdjustment)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mask)) as? [String: Any])
        legacy.removeValue(forKey: "colorAdjustment")
        XCTAssertNil(try JSONDecoder().decode(LocalMask.self,
            from: JSONSerialization.data(withJSONObject: legacy)).colorAdjustment)
    }

    func testLocalTintUsesCameraScaleAndMagentaDirection() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        let src = source(gpu)
        var mask = LocalMask(kind: .gradient)
        mask.colorAdjustment = .init(tint: 100)
        let magenta = try renderer.apply([mask], to: src)
        let red = sample(magenta, gpu, x: 50, y: 95)
        let green = sample(magenta, gpu, x: 50, y: 95, channel: 1)
        XCTAssertGreaterThan(red, green)
        XCTAssertLessThan(red, 0.5)
        mask.colorAdjustment = .init(tint: -100)
        let greenish = try renderer.apply([mask], to: src)
        XCTAssertLessThan(sample(greenish, gpu, x: 50, y: 95),
                          sample(greenish, gpu, x: 50, y: 95, channel: 1))
    }

    func testPipelineMaskBeforeToneMappingAndNeutralBypass() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let pipeline = try RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.optical.enabled = false
        p.colorEngine.enabled = false
        let decoded = DecodedRaw(url: URL(fileURLWithPath: "/synthetic.dng"), image: source(gpu),
                                 metadata: RawMetadata(), fullSize: CGSize(width: 100, height: 100), colorSpace: gpu.workingColorSpace)
        let master = try pipeline.makeSceneMaster(decoded: decoded, parameters: p)
        let base = try pipeline.render(sceneMaster: master, parameters: p)
        var mask = LocalMask(kind: .gradient)
        p.localMasks = [mask]
        let neutral = try pipeline.render(sceneMaster: master, parameters: p)
        XCTAssertEqual(sample(base, gpu, x: 50, y: 90), sample(neutral, gpu, x: 50, y: 90))
        mask.exposureEV = 1
        p.localMasks = [mask]
        let result = try pipeline.render(sceneMaster: master, parameters: p)
        XCTAssertGreaterThan(sample(result, gpu, x: 50, y: 90), sample(base, gpu, x: 50, y: 90) * 1.2)
        XCTAssertEqual(sample(result, gpu, x: 50, y: 5), sample(base, gpu, x: 50, y: 5), accuracy: 0.003)
        let target = TargetTransform(target: p.target, tone: p.toneMapping, gamut: p.gamutMapping)
        let expected = target.apply(SIMD3(repeating: 0.36))
        var encoded = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(result, toBitmap: &encoded, rowBytes: 16,
            bounds: CGRect(x: 50, y: 90, width: 1, height: 1), format: .RGBAf,
            colorSpace: RenderPipeline.colorSpace(for: p.target))
        XCTAssertEqual(Double(encoded[0]), expected.x, accuracy: 0.015)
        mask.enabled = false
        p.localMasks = [mask]
        XCTAssertEqual(sample(try pipeline.render(sceneMaster: master, parameters: p), gpu, x: 50, y: 90), sample(base, gpu, x: 50, y: 90))
    }

    func testOffsetExtentAndProxyMatch() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let renderer = try MaskRenderer()
        var m = LocalMask(kind: .brush)
        m.feather = 0
        m.strokes = [.init(points: [.init(x: 0.2, y: 0.8)], radius: 0.05)]
        let shifted = source(gpu).transformed(by: CGAffineTransform(translationX: 31, y: 47))
        let output = try renderer.image(for: m, source: shifted)
        XCTAssertEqual(output.extent, shifted.extent)
        XCTAssertGreaterThan(sample(output, gpu, x: 51, y: 127), 0.99)
    }

    func testMaskSidecarSaveLoadLeavesRawUntouched() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("mask.dng")
        let original = Data("original RAW bytes".utf8)
        try original.write(to: raw)
        var p = EditParameters()
        p.localMasks = LocalMask.Kind.allCases.map { LocalMask(kind: $0) }
        p.localMasks[1].strokes = [.init(points: [.init(x: 0.1, y: 0.7)], radius: 0.04)]
        try Sidecar(rawFileName: raw.lastPathComponent, parameters: p).save(forRaw: raw)
        XCTAssertEqual(try Sidecar.load(forRaw: raw)?.parameters, p)
        XCTAssertEqual(try Data(contentsOf: raw), original)
    }
}
