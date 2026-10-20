import XCTest
import CoreImage
@testable import RFCore

final class RetouchBackendTests: XCTestCase {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue),
    ])

    func testLegacyParametersAndSidecarDefaultToEmptyRetouch() throws {
        var parametersJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(EditParameters()))
                                           as? [String: Any])
        parametersJSON.removeValue(forKey: "retouch")
        let parametersData = try JSONSerialization.data(withJSONObject: parametersJSON)
        let parameters = try JSONDecoder().decode(EditParameters.self, from: parametersData)
        XCTAssertEqual(parameters.retouch, RetouchParameters())

        let sidecar = Sidecar(rawFileName: "frame.dng", parameters: EditParameters())
        var sidecarJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sidecar))
                                        as? [String: Any])
        var nested = try XCTUnwrap(sidecarJSON["parameters"] as? [String: Any])
        nested.removeValue(forKey: "retouch")
        sidecarJSON["parameters"] = nested
        let oldData = try JSONSerialization.data(withJSONObject: sidecarJSON)
        XCTAssertEqual(try JSONDecoder().decode(Sidecar.self, from: oldData).parameters.retouch,
                       RetouchParameters())
    }

    func testCloneUsesFixedSourceOffsetAndKeepsOutsideHDRPixelsExact() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let background = CIImage(color: linearColor(2, 1.5, 0.5)).cropped(to: extent)
        let sourceColor = CIImage(color: linearColor(4, 0.15, 0.25))
            .cropped(to: CGRect(x: 12, y: 26, width: 15, height: 14))
        let original = sourceColor.composited(over: background)
        let patch = try RetouchEngine.makePatch(image: original,
            points: [MaskPoint(x: 0.70, y: 0.5), MaskPoint(x: 0.73, y: 0.5)],
            radius: 0.09, source: MaskPoint(x: 0.30, y: 0.5), context: context)
        let result = patch.composited(over: original).cropped(to: extent)

        let copied = sample(result, x: 45, y: 32)
        XCTAssertGreaterThan(copied.x, 3.5)
        XCTAssertLessThan(copied.y, 0.3)

        let before = sample(original, x: 5, y: 5)
        let after = sample(result, x: 5, y: 5)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
        XCTAssertGreaterThan(after.x, 1, "HDR 外側像素應保留大於 1 的亮度")
    }

    func testTraditionalHealFillsBlemishFromBoundaryWithoutSofteningOutside() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let background = CIImage(color: linearColor(0.08, 0.32, 0.82)).cropped(to: extent)
        let blemish = CIImage(color: linearColor(0.95, 0.02, 0.01))
            .cropped(to: CGRect(x: 28, y: 28, width: 8, height: 8))
        let original = blemish.composited(over: background)
        let patch = try RetouchEngine.makePatch(image: original,
            points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.15, context: context)
        let result = patch.composited(over: original).cropped(to: extent)

        let repaired = sample(result, x: 32, y: 32)
        XCTAssertLessThan(repaired.x, 0.4, "紅色污點應被周圍藍色背景取代")
        XCTAssertGreaterThan(repaired.y, 0.2)
        XCTAssertGreaterThan(repaired.z, 0.6)
        XCTAssertEqual(sample(result, x: 5, y: 5), sample(original, x: 5, y: 5))
    }

    func testHealFullyReplacesBrushRadiusAndFeathersOutsideIt() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let background = CIImage(color: linearColor(0.08, 0.32, 0.82)).cropped(to: extent)
        let object = CIImage(color: linearColor(0.95, 0.02, 0.01))
            .cropped(to: CGRect(x: 23, y: 25, width: 18, height: 14))
        let original = object.composited(over: background)
        let patch = try RetouchEngine.makePatch(image: original,
            points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.15, context: context)
        let result = patch.composited(over: original).cropped(to: extent)

        XCTAssertGreaterThan(sample(patch, x: 40, y: 32).w, 0.98,
                             "brush radius inside edge must be fully replaced")
        XCTAssertLessThan(sample(result, x: 40, y: 32).x, 0.4,
                          "object pixels inside the brush radius must not mix back in")
        let featherAlpha = sample(patch, x: 42, y: 32).w
        XCTAssertGreaterThan(featherAlpha, 0.05)
        XCTAssertLessThan(featherAlpha, 0.95, "the small outer ring should soften the join")
        XCTAssertEqual(sample(patch, x: 44, y: 32).w, 0, accuracy: 0.001)
        XCTAssertEqual(sample(result, x: 5, y: 5), sample(original, x: 5, y: 5))
    }

    func testAIFillGetsSurroundingContextAndHardMaskButReturnsSoftPatch() throws {
        let extent = CGRect(x: 13, y: 17, width: 240, height: 180)
        let image = CIImage(color: linearColor(0.3, 0.4, 0.5)).cropped(to: extent)
        let observation = AIObservation()
        let patch = try RetouchEngine.makePatch(image: image,
            points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.04, context: context,
            aiFill: { crop, mask in
                observation.record(image: crop, mask: mask)
                return crop
            })
        let record = observation.read()
        let aiImage = try XCTUnwrap(record.image)
        let mask = try XCTUnwrap(record.mask)
        XCTAssertEqual(mask.extent, aiImage.extent)
        XCTAssertGreaterThan(aiImage.extent.width, patch.extent.width + 100)
        XCTAssertGreaterThan(aiImage.extent.height, patch.extent.height + 100)
        XCTAssertGreaterThan(sample(mask, x: aiImage.extent.midX, y: aiImage.extent.midY).x, 0.95)
        XCTAssertLessThan(sample(mask, x: aiImage.extent.minX + 2, y: aiImage.extent.minY + 2).x, 0.05)
        XCTAssertLessThan(patch.extent.width, aiImage.extent.width)
    }

    /// 斜向筆畫：遮罩必須落在實際畫過的位置，不能上下鏡像到另一側。
    func testSlopedStrokeHealsPaintedPixelsNotVerticalMirror() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
        let background = CIImage(color: linearColor(0.08, 0.32, 0.82)).cropped(to: extent)
        // 污點在左下（y 小），筆畫由左下畫到右上。
        let blemish = CIImage(color: linearColor(0.95, 0.02, 0.01))
            .cropped(to: CGRect(x: 54, y: 54, width: 12, height: 12))
        let original = blemish.composited(over: background)
        let modes: [(String, (@Sendable (CIImage, CIImage) throws -> CIImage)?)] = [
            ("傳統", nil),
            ("AI", { crop, _ in background.cropped(to: crop.extent) }),
        ]
        for (name, aiFill) in modes {
            let patch = try RetouchEngine.makePatch(image: original,
                points: [MaskPoint(x: 0.3, y: 0.3), MaskPoint(x: 0.7, y: 0.7)],
                radius: 0.06, context: context, aiFill: aiFill)
            let result = patch.composited(over: original).cropped(to: extent)
            let repaired = sample(result, x: 60, y: 60)
            XCTAssertLessThan(repaired.x, 0.2, "\(name) 修補沒有蓋到畫過的污點")
            XCTAssertEqual(sample(patch, x: 60, y: 140).w, 0, accuracy: 0.001, "\(name) 修補落到鏡像位置")
        }
    }

    /// 傳統修補要從附近找相似區塊貼上，紋理（條紋）要延續，不能只糊成平均色。
    func testTraditionalHealContinuesNearbyTexture() throws {
        let extent = CGRect(x: 0, y: 0, width: 240, height: 240)
        let dark = linearColor(0.05, 0.10, 0.20), light = linearColor(0.60, 0.70, 0.80)
        var original = CIImage(color: dark).cropped(to: extent)
        for x in stride(from: 0, to: 240, by: 8) {
            original = CIImage(color: light).cropped(to: CGRect(x: x, y: 0, width: 4, height: 240))
                .composited(over: original)
        }
        original = CIImage(color: linearColor(0.95, 0.02, 0.01))
            .cropped(to: CGRect(x: 110, y: 110, width: 20, height: 20)).composited(over: original)
        let patch = try RetouchEngine.makePatch(image: original,
            points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.07, context: context)
        let result = patch.composited(over: original).cropped(to: extent)
        for y in [114, 120, 126] {
            let lightPixel = sample(result, x: 121, y: y), darkPixel = sample(result, x: 125, y: y)
            XCTAssertEqual(lightPixel.x, 0.60, accuracy: 0.08, "亮條紋在 y=\(y) 沒有延續")
            XCTAssertEqual(darkPixel.x, 0.05, accuracy: 0.08, "暗條紋在 y=\(y) 沒有延續")
        }
        XCTAssertEqual(sample(result, x: 5, y: 5), sample(original, x: 5, y: 5))
    }

    func testTraditionalHealRebuildsTextureAcrossCurvedRegionEdge() throws {
        // 條紋背景上有一個橫條紋圓盤，污點正好跨過圓盤邊緣。沒有任何單一位移的來源
        // 能同時接上兩種紋理與彎曲邊界，修補必須逐塊從各處取紋理才會自然。
        let size = 128
        func truth(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let dx = Double(x - 48), dy = Double(y - 64)
            if dx * dx + dy * dy < 900 {
                return (y / 4).isMultiple(of: 2) ? SIMD3(1.6, 0.9, 0.2) : SIMD3(0.3, 0.1, 0.05)
            }
            return (x / 4).isMultiple(of: 2) ? SIMD3(0.1, 0.5, 0.7) : SIMD3(0.02, 0.15, 0.3)
        }
        var clean = [Float](repeating: 1, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value = truth(x, y), offset = ((size - 1 - y) * size + x) * 4
                clean[offset] = value.x; clean[offset + 1] = value.y; clean[offset + 2] = value.z
            }
        }
        var blemished = clean
        for y in 58...70 {
            for x in 72...84 {
                let offset = ((size - 1 - y) * size + x) * 4
                blemished[offset] = 2; blemished[offset + 1] = 0; blemished[offset + 2] = 2
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let original = CIImage(bitmapData: blemished.withUnsafeBytes { Data($0) }, bytesPerRow: size * 16,
                               size: CGSize(width: size, height: size), format: .RGBAf,
                               colorSpace: colorSpace)
        let patch = try RetouchEngine.makePatch(image: original,
            points: [MaskPoint(x: 78.5 / 128, y: 64.5 / 128)], radius: 0.075, context: context)
        let result = patch.composited(over: original).cropped(to: original.extent)
        var rendered = [Float](repeating: 0, count: size * size * 4)
        context.render(result, toBitmap: &rendered, rowBytes: size * 16, bounds: original.extent,
                       format: .RGBAf, colorSpace: colorSpace)

        var totalError: Float = 0, count = 0
        for y in 54...74 {
            for x in 68...88 where (x - 78) * (x - 78) + (y - 64) * (y - 64) <= 81 {
                let offset = ((size - 1 - y) * size + x) * 4
                for channel in 0..<3 { totalError += abs(rendered[offset + channel] - clean[offset + channel]) }
                count += 3
            }
        }
        let meanError = totalError / Float(count)
        XCTAssertLessThan(meanError, 0.12, "修補後應接近原本紋理；平均誤差 \(meanError)")
    }

    func testAssetStoreRoundTripMissingTraversalAndHashValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("frame.dng")
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)
        let source = CIImage(color: linearColor(2.4, 0.2, 0.1)).cropped(to: extent)
        let patch = try RetouchEngine.makePatch(image: source,
            points: [MaskPoint(x: 0.55, y: 0.5)], radius: 0.1, source: MaskPoint(x: 0.25, y: 0.5),
            context: context)
        let reference = try RetouchAssetStore.write(patch: patch, imageExtent: extent,
                                                   forRaw: raw, context: context)
        XCTAssertEqual(reference.sha256.count, 64)
        XCTAssertEqual(reference.sourceSize, extent.size)
        let loaded = try RetouchAssetStore.load(reference, forRaw: raw)
        XCTAssertGreaterThan(sample(loaded, x: loaded.extent.midX, y: loaded.extent.midY).x, 1.5)
        let standardizedRaw = URL(fileURLWithPath: raw.path).standardizedFileURL
        XCTAssertNoThrow(try RetouchAssetStore.load(reference, forRaw: standardizedRaw),
                         "standardizing the source URL must not change its .rfassets directory")

        var missing = reference
        missing.assetName = "missing.tiff"
        XCTAssertThrowsError(try RetouchAssetStore.load(missing, forRaw: raw)) { error in
            XCTAssertEqual(error as? RetouchAssetError, .missingAsset)
        }

        var traversal = reference
        traversal.assetName = "../outside.tiff"
        XCTAssertThrowsError(try RetouchAssetStore.load(traversal, forRaw: raw)) { error in
            XCTAssertEqual(error as? RetouchAssetError, .unsafeAssetName)
        }

        let storedURL = RetouchAssetStore.assetDirectory(forRaw: raw)
            .appendingPathComponent(reference.assetName)
        let originalBytes = try Data(contentsOf: storedURL)
        let outsideURL = directory.appendingPathComponent("outside.tiff")
        try originalBytes.write(to: outsideURL)
        try FileManager.default.removeItem(at: storedURL)
        try FileManager.default.createSymbolicLink(at: storedURL, withDestinationURL: outsideURL)
        XCTAssertThrowsError(try RetouchAssetStore.load(reference, forRaw: raw)) { error in
            XCTAssertEqual(error as? RetouchAssetError, .assetEscapesDirectory)
        }
        try FileManager.default.removeItem(at: storedURL)
        try originalBytes.write(to: storedURL)
        try Data("changed".utf8).write(to: storedURL, options: .atomic)
        XCTAssertThrowsError(try RetouchAssetStore.load(reference, forRaw: raw)) { error in
            XCTAssertEqual(error as? RetouchAssetError, .hashMismatch)
        }
    }

    func testGeometryCoordinateRoundTripsAndTracksRenderedLandmark() throws {
        let extent = CGRect(x: 13, y: 17, width: 200, height: 140)
        var cases = [GeometryParameters()]
        var rotated = GeometryParameters(); rotated.straighten = 5
        cases.append(rotated)
        var perspective = GeometryParameters(); perspective.verticalPerspective = 55; perspective.horizontalPerspective = -30
        cases.append(perspective)
        var cropped = GeometryParameters(); cropped.cropAspect = .square
        cases.append(cropped)

        for geometry in cases {
            for output in [MaskPoint(x: 0.25, y: 0.5), MaskPoint(x: 0.5, y: 0.5),
                           MaskPoint(x: 0.75, y: 0.5)] {
                guard let input = geometry.inputPoint(forOutput: output, extent: extent),
                      let roundTrip = geometry.outputPoint(forInput: input, extent: extent) else {
                    XCTFail("可見輸出點應有幾何前座標")
                    continue
                }
                XCTAssertEqual(roundTrip.x, output.x, accuracy: 1e-6)
                XCTAssertEqual(roundTrip.y, output.y, accuracy: 1e-6)
            }
            XCTAssertNotNil(geometry.inputRadius(forOutput: 0.02,
                                                 at: MaskPoint(x: 0.5, y: 0.5), extent: extent))
        }

        let landmark = MaskPoint(x: 0.24, y: 0.31)
        let markerRect = CGRect(x: extent.minX + CGFloat(landmark.x) * extent.width - 4,
                                y: extent.minY + CGFloat(landmark.y) * extent.height - 4,
                                width: 8, height: 8)
        let image = CIImage(color: .black).cropped(to: extent)
        let marked = CIImage(color: .white).cropped(to: markerRect).composited(over: image)
        let warped = perspective.apply(to: marked)
        let output = try XCTUnwrap(perspective.outputPoint(forInput: landmark, extent: extent))
        let centerX = warped.extent.minX + CGFloat(output.x) * warped.extent.width
        let centerY = warped.extent.minY + CGFloat(output.y) * warped.extent.height
        var maximum: Float = 0
        for y in -5...5 {
            for x in -5...5 {
                maximum = max(maximum, sample(warped, x: centerX + CGFloat(x), y: centerY + CGFloat(y)).x)
            }
        }
        XCTAssertGreaterThan(maximum, 0.8, "座標換算必須落在 Core Image 實際變形後的標記上")
    }

    func testPerspectiveBrushMaskMapsOutputCircleBackToSourcePixels() throws {
        let extent = CGRect(x: 13, y: 17, width: 1_000, height: 700)
        var geometry = GeometryParameters()
        geometry.verticalPerspective = 50
        geometry.horizontalPerspective = -30
        let output = geometry.apply(to: CIImage(color: .black).cropped(to: extent))
        let center = MaskPoint(x: 0.5, y: 0.5)
        let radius = 0.06
        let targetRadius = radius * Double(min(output.extent.width, output.extent.height))
        let mask = try geometry.inputBrushMask(forOutput: [center], radius: radius,
                                               extent: extent, featherOutside: true)
        XCTAssertNotNil(geometry.inputPoint(forOutput: center, extent: extent))
        let localMask = CIImage(bitmapData: mask.bytes, bytesPerRow: Int(mask.bounds.width),
                                size: mask.bounds.size, format: .R8,
                                colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
        let sourceMask = localMask.transformed(by: CGAffineTransform(translationX: mask.bounds.minX,
                                                                     y: mask.bounds.minY))
            .composited(over: CIImage(color: .black).cropped(to: extent)).cropped(to: extent)
        let renderedMask = geometry.apply(to: sourceMask)

        func alpha(at outputPoint: MaskPoint) -> Float {
            let x = renderedMask.extent.minX + CGFloat(outputPoint.x) * renderedMask.extent.width
            let y = renderedMask.extent.minY + CGFloat(outputPoint.y) * renderedMask.extent.height
            return sample(renderedMask, x: x, y: y).x
        }

        let inside = MaskPoint(x: center.x + targetRadius * 0.9 / Double(output.extent.width), y: center.y)
        let feather = MaskPoint(x: center.x + (targetRadius + targetRadius * 0.06)
                                    / Double(output.extent.width), y: center.y)
        let outside = MaskPoint(x: center.x + (targetRadius * 1.25) / Double(output.extent.width), y: center.y)
        XCTAssertGreaterThan(alpha(at: inside), 0.95, "output brush interior must remain opaque after perspective")
        let featherAlpha = alpha(at: feather)
        XCTAssertGreaterThan(featherAlpha, 0.1)
        XCTAssertLessThan(featherAlpha, 0.9, "only the narrow outer ring should feather")
        XCTAssertLessThan(alpha(at: outside), 0.05, "pixels outside the rendered brush must stay untouched")
    }

    func testReconstructResizesTheSavedPatchForProxyWithoutRegenerating() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let pipeline = try RenderPipeline(gpu: gpu)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("proxy.dng")
        let extent = CGRect(x: 0, y: 0, width: 80, height: 64)
        let base = CIImage(color: linearColor(0.05, 0.05, 0.05, colorSpace: gpu.workingColorSpace)).cropped(to: extent)
        let sourceColor = CIImage(color: linearColor(2.5, 0.1, 0.2, colorSpace: gpu.workingColorSpace))
            .cropped(to: CGRect(x: 16, y: 26, width: 14, height: 14))
        let decoded = DecodedRaw(url: raw, image: sourceColor.composited(over: base),
                                 metadata: RawMetadata(), fullSize: extent.size,
                                 colorSpace: gpu.workingColorSpace)
        var parameters = EditParameters()
        parameters.optical.enabled = false
        let patch = try RetouchEngine.makePatch(image: decoded.image,
            points: [MaskPoint(x: 0.72, y: 0.5)], radius: 0.09,
            source: MaskPoint(x: 0.29, y: 0.5), context: gpu.ciContext)
        let stored = try RetouchAssetStore.write(patch: patch, imageExtent: extent,
                                                 forRaw: raw, context: gpu.ciContext)
        parameters.retouch.patches = [stored]

        let full = try pipeline.reconstruct(decoded: decoded, parameters: parameters)
        let preview = try pipeline.reconstruct(decoded: decoded, parameters: parameters, maxDimension: 32)
        XCTAssertEqual(full.scale, 1)
        XCTAssertLessThan(preview.scale, 1)
        let fullCenter = sample(full.image, x: 58, y: 32, context: gpu.ciContext,
                                colorSpace: gpu.workingColorSpace)
        let previewCenter = sample(preview.image, x: 23, y: 12, context: gpu.ciContext,
                                   colorSpace: gpu.workingColorSpace)
        XCTAssertGreaterThan(fullCenter.x, 1.8)
        XCTAssertGreaterThan(previewCenter.x, 1.6)
        XCTAssertEqual(previewCenter.x, fullCenter.x, accuracy: 0.6)
    }

    func testResetAndHistoryRecognizeRetouchState() throws {
        var parameters = EditParameters()
        parameters.retouch.enabled = false
        parameters.retouch.patches = [RetouchPatch(normalizedBounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                                   assetName: "patch.tiff", sha256: String(repeating: "a", count: 64),
                                                   sourceSize: CGSize(width: 100, height: 80))]
        let history = EditHistory()
        XCTAssertTrue(history.apply { $0 = parameters })
        XCTAssertTrue(history.steps.last?.label.contains("修補") ?? false)
        parameters.resetAll()
        XCTAssertEqual(parameters.retouch, RetouchParameters())
    }

    /// 以延伸線性 sRGB 建立顏色；預設 CIColor 會夾在 0–1 並視為非線性 sRGB。
    private func linearColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                             colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) -> CIColor {
        CIColor(red: red, green: green, blue: blue, colorSpace: colorSpace)!
    }

    private func sample(_ image: CIImage, x: Int, y: Int) -> SIMD4<Float> {
        sample(image, x: CGFloat(x) + 0.25, y: CGFloat(y) + 0.25)
    }

    private func sample(_ image: CIImage, x: CGFloat, y: CGFloat) -> SIMD4<Float> {
        Self.pixel(image, x: x, y: y, context: context)
    }

    private func sample(_ image: CIImage, x: CGFloat, y: CGFloat,
                        context: CIContext, colorSpace: CGColorSpace) -> SIMD4<Float> {
        Self.pixel(image, x: x, y: y, context: context, colorSpace: colorSpace)
    }

    private static func pixel(_ image: CIImage, x: CGFloat, y: CGFloat,
                              context: CIContext, colorSpace: CGColorSpace? = nil) -> SIMD4<Float> {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: floor(x), y: floor(y), width: 1, height: 1),
                       format: .RGBAf, colorSpace: colorSpace)
        return SIMD4(pixel[0], pixel[1], pixel[2], pixel[3])
    }
}

private final class AIObservation: @unchecked Sendable {
    struct Value {
        var image: CIImage?
        var mask: CIImage?
    }

    private let lock = NSLock()
    private var value = Value()

    func record(image: CIImage, mask: CIImage) {
        lock.lock(); defer { lock.unlock() }
        value = Value(image: image, mask: mask)
    }

    func read() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
