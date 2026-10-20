import XCTest
import CoreImage
import ImageIO
import simd
@testable import RFCore

/// 需要真實 Metal 裝置的測試。沒有 GPU 的環境會明確跳過而不是假裝通過。
final class GPUPipelineTests: XCTestCase {
    private var gpu: GPUContext!

    override func setUpWithError() throws {
        gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
    }

    /// 合成一張水平漸層 + 中心亮斑的 scene-referred 影像。
    private func testImage(size: Int = 256) -> CIImage {
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let dx = Double(x - size / 2) / Double(size / 2)
                let dy = Double(y - size / 2) / Double(size / 2)
                let r = sqrt(dx * dx + dy * dy)
                let base = 0.18 + 0.6 * Double(x) / Double(size)
                let spot = r < 0.15 ? 3.0 : 0.0
                pixels[i + 0] = Float(base + spot)
                pixels[i + 1] = Float(base * 0.9 + spot)
                pixels[i + 2] = Float(base * 0.8 + spot)
                pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: size * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: size, height: size),
            format: .RGBAf,
            colorSpace: gpu.workingColorSpace
        )
    }

    /// 讀回指定位置的像素值（linear working space）。
    private func readPixel(_ image: CIImage, at point: CGPoint,
                           colorSpace: CGColorSpace? = nil) -> SIMD4<Double> {
        var out = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(
            image,
            toBitmap: &out,
            rowBytes: 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: colorSpace ?? gpu.workingColorSpace
        )
        return SIMD4(Double(out[0]), Double(out[1]), Double(out[2]), Double(out[3]))
    }

    // MARK: - 光學校正

    /// Shader 能載入，且 identity profile 不觸發任何 GPU pass。
    func testIdentityProfileIsPassThrough() throws {
        let renderer = try OpticalRenderer(gpu: gpu)
        let image = testImage()
        let out = try renderer.apply(to: image, profile: .off)
        XCTAssertEqual(out.extent, image.extent)
        let a = readPixel(image, at: CGPoint(x: 200, y: 128))
        let b = readPixel(out, at: CGPoint(x: 200, y: 128))
        XCTAssertEqual(a.x, b.x, accuracy: 1e-5)
    }

    /// 驗收條件 2：暗角校正必須把角落補亮，且不動中心。
    func testVignettingCorrectionBrightensCorners() throws {
        let renderer = try OpticalRenderer(gpu: gpu)
        let size = 256
        let image = testImage(size: size)
        var profile = ResolvedLensProfile(source: .manual, identifier: "test")
        profile.vignetting = VignettingModel(kind: .pa, k1: -0.6, k2: 0, k3: 0)

        let out = try renderer.apply(to: image, profile: profile)
        let corner = CGPoint(x: 2, y: 2)
        let center = CGPoint(x: size / 2, y: size / 2 + 60)   // 避開中心亮斑

        let cornerBefore = readPixel(image, at: corner).y
        let cornerAfter = readPixel(out, at: corner).y
        XCTAssertGreaterThan(cornerAfter, cornerBefore * 1.3, "角落應被補亮")

        let centerBefore = readPixel(image, at: center).y
        let centerAfter = readPixel(out, at: center).y
        XCTAssertEqual(centerAfter, centerBefore, accuracy: max(centerBefore * 0.15, 1e-3))
    }

    /// 驗收條件 2：桶狀畸變校正會把邊緣內容往外拉，影像確實改變。
    func testDistortionCorrectionChangesGeometry() throws {
        let renderer = try OpticalRenderer(gpu: gpu)
        let image = testImage()
        var profile = ResolvedLensProfile(source: .manual, identifier: "test")
        profile.distortion = DistortionModel(kind: .poly3, a: -0.08)

        let out = try renderer.apply(to: image, profile: profile)
        // 水平漸層 + 徑向縮放 ⇒ 邊緣位置的亮度必須改變。
        let before = readPixel(image, at: CGPoint(x: 240, y: 128)).y
        let after = readPixel(out, at: CGPoint(x: 240, y: 128)).y
        XCTAssertNotEqual(before, after, accuracy: 0.01)
        // 中心點在徑向變換下不動。
        let cBefore = readPixel(image, at: CGPoint(x: 128, y: 128)).y
        let cAfter = readPixel(out, at: CGPoint(x: 128, y: 128)).y
        XCTAssertEqual(cAfter, cBefore, accuracy: max(cBefore * 0.05, 1e-3))
    }

    /// TCA 校正讓紅藍通道相對綠通道位移，綠通道本身不動。
    func testTCAShiftsRedAndBlueOnly() throws {
        let renderer = try OpticalRenderer(gpu: gpu)
        let image = testImage()
        var profile = ResolvedLensProfile(source: .manual, identifier: "test")
        profile.tca = TCAModel(kind: .linear, kr: 0.97, kb: 1.03)

        let out = try renderer.apply(to: image, profile: profile)
        let before = readPixel(image, at: CGPoint(x: 220, y: 128))
        let after = readPixel(out, at: CGPoint(x: 220, y: 128))
        XCTAssertEqual(after.y, before.y, accuracy: max(before.y * 0.05, 1e-3))
        XCTAssertNotEqual(after.x, before.x, accuracy: 1e-4)
        XCTAssertNotEqual(after.z, before.z, accuracy: 1e-4)
    }

    // MARK: - LUT / 色彩

    /// GPU 套 LUT 的結果必須與 CPU 直接運算一致（預覽與輸出才會相符）。
    func testLUTRendererMatchesCPU() throws {
        let renderer = try LUTRenderer(gpu: gpu)
        var params = EditParameters()
        params.layerA.exposureEV = 0.3
        params.target.gamut = .displayP3

        var meta = RawMetadata()
        meta.neutralTemperature = 5500
        let scene = RenderPipeline.sceneTransform(for: params, metadata: meta)
        let target = TargetTransform(target: params.target, tone: params.toneMapping,
                                     gamut: params.gamutMapping)
        let lut = LUT3D.bake(scene: scene, target: target)

        let image = testImage()
        let out = try renderer.apply(to: image, lut: lut,
                                     outputColorSpace: RenderPipeline.colorSpace(for: params.target))

        let point = CGPoint(x: 200, y: 60)
        let input = readPixel(image, at: point)
        // 輸出已是 P3 編碼值，用同一個色彩空間讀回避免再被轉換。
        let got = readPixel(out, at: point, colorSpace: RenderPipeline.colorSpace(for: params.target))
        let expected = lut.sample(SIMD3(input.x, input.y, input.z))

        XCTAssertEqual(got.x, expected.x, accuracy: 0.03)
        XCTAssertEqual(got.y, expected.y, accuracy: 0.03)
        XCTAssertEqual(got.z, expected.z, accuracy: 0.03)
    }

    /// 高光（scene 值 3.0）經過 tone mapping 後不得超出 1.0。
    func testHighlightsAreToneMappedNotClipped() throws {
        let renderer = try LUTRenderer(gpu: gpu)
        let params = EditParameters()
        var meta = RawMetadata()
        meta.neutralTemperature = 5500
        let lut = LUT3D.bake(
            scene: RenderPipeline.sceneTransform(for: params, metadata: meta),
            target: TargetTransform(target: params.target, tone: params.toneMapping,
                                    gamut: params.gamutMapping)
        )
        let out = try renderer.apply(to: testImage(), lut: lut,
                                     outputColorSpace: RenderPipeline.colorSpace(for: params.target))
        let spot = readPixel(out, at: CGPoint(x: 128, y: 128),
                             colorSpace: RenderPipeline.colorSpace(for: params.target))
        XCTAssertLessThanOrEqual(spot.x, 1.001)
        XCTAssertGreaterThan(spot.x, 0.8, "亮斑應該接近白，而不是被壓暗")
    }

    // MARK: - 輸出

    /// 驗收條件 6：輸出各 target gamut 的 HEIC，檔案可被 Image I/O 讀回且色彩空間正確。
    func testHEICExportForBothGamuts() throws {
        let exporter = Exporter(gpu: gpu)
        let renderer = try LUTRenderer(gpu: gpu)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rf-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for gamut in RenderingTarget.Gamut.allCases {
            var params = EditParameters()
            params.target.gamut = gamut
            var meta = RawMetadata()
            meta.neutralTemperature = 5500
            let lut = LUT3D.bake(
                scene: RenderPipeline.sceneTransform(for: params, metadata: meta),
                target: TargetTransform(target: params.target, tone: params.toneMapping,
                                        gamut: params.gamutMapping)
            )
            let rendered = try renderer.apply(
                to: testImage(), lut: lut,
                outputColorSpace: RenderPipeline.colorSpace(for: params.target)
            )
            let url = dir.appendingPathComponent("out-\(gamut.rawValue).heic")
            try exporter.write(image: rendered, to: url, target: params.target)

            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 256)
            let name = (try XCTUnwrap(image.colorSpace?.name) as String).lowercased()
            let expected: String
            switch gamut {
            case .sRGB: expected = "srgb"
            case .displayP3: expected = "p3"
            case .rec2020: expected = "2020"
            }
            XCTAssertTrue(name.contains(expected),
                          "輸出的色彩空間是 \(name)，預期包含 \(expected)")
        }
    }

    // MARK: - RAW 前端

    /// §1.1：macOS 必須認得第一階段要求的 RAW 格式。
    func testRequiredRawFormatsAreRecognized() {
        let identifiers = RawDecoder.supportedTypeIdentifiers
        XCTAssertFalse(identifiers.isEmpty, "系統未回報任何 RAW 格式")
        for ext in RawDecoder.requiredExtensions {
            XCTAssertTrue(
                RawDecoder.isSupported(URL(fileURLWithPath: "/tmp/sample.\(ext)")),
                "\(ext) 應被視為支援的 RAW"
            )
        }
        XCTAssertFalse(RawDecoder.isSupported(URL(fileURLWithPath: "/tmp/sample.txt")))
    }

    /// 不是 RAW 的檔案要給出明確錯誤，而不是崩潰。
    func testDecodingNonRawThrows() {
        let decoder = RawDecoder()
        XCTAssertThrowsError(try decoder.decode(url: URL(fileURLWithPath: "/tmp/nope.txt")))
    }
}

/// A-003 上下顛倒回歸：每個 GPU pass 都必須保持影像方向。
final class GPUOrientationTests: XCTestCase {
    /// 在 CI 座標的上半部畫一條亮帶，走完各段後亮帶必須還在上半部。
    private func makeBanded(_ cs: CGColorSpace, w: CGFloat = 64, h: CGFloat = 64) -> CIImage {
        let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02, colorSpace: cs)!)
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let band = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8, colorSpace: cs)!)
            .cropped(to: CGRect(x: 0, y: h * 0.75, width: w, height: h * 0.25))
        return band.composited(over: dark)
    }

    private func topMinusBottom(_ gpu: GPUContext, _ img: CIImage, _ cs: CGColorSpace) -> Float {
        func sample(_ fraction: CGFloat) -> Float {
            var b = [Float](repeating: 0, count: 4)
            let y = img.extent.minY + img.extent.height * fraction
            gpu.ciContext.render(img, toBitmap: &b, rowBytes: 16,
                                 bounds: CGRect(x: img.extent.midX, y: y, width: 1, height: 1),
                                 format: .RGBAf, colorSpace: cs)
            return b[1]
        }
        return sample(0.85) - sample(0.15)
    }

    func testOpticalRendererPreservesOrientation() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let cs = gpu.workingColorSpace
        let src = makeBanded(cs)
        var profile = ResolvedLensProfile(source: .embedded, identifier: "orientation-test")
        profile.vignetting = VignettingModel(kind: .pa, k1: 0.2, k2: 0, k3: 0)
        let out = try OpticalRenderer(gpu: gpu).apply(to: src, profile: profile)
        XCTAssertGreaterThan(topMinusBottom(gpu, out, cs), 0.3, "光學校正後影像上下顛倒")
    }

    func testLUTRendererPreservesOrientation() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let p = EditParameters()
        let lut = LUT3D.bake(
            scene: RenderPipeline.sceneTransform(for: p, metadata: RawMetadata()),
            target: TargetTransform(target: p.target, tone: p.toneMapping, gamut: p.gamutMapping)
        )
        let outCS = RenderPipeline.colorSpace(for: p.target)
        let src = makeBanded(gpu.workingColorSpace)
        let out = try LUTRenderer(gpu: gpu).apply(to: src, lut: lut, outputColorSpace: outCS)
        XCTAssertGreaterThan(topMinusBottom(gpu, out, outCS), 0.3, "套 LUT 後影像上下顛倒")
    }

    /// 兩段串起來也不能靠「翻兩次剛好抵銷」蒙混過去。
    func testChainedPassesPreserveOrientation() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let p = EditParameters()
        var profile = ResolvedLensProfile(source: .embedded, identifier: "orientation-test")
        profile.vignetting = VignettingModel(kind: .pa, k1: 0.2, k2: 0, k3: 0)
        let optical = try OpticalRenderer(gpu: gpu).apply(to: makeBanded(gpu.workingColorSpace),
                                                          profile: profile)
        let lut = LUT3D.bake(
            scene: RenderPipeline.sceneTransform(for: p, metadata: RawMetadata()),
            target: TargetTransform(target: p.target, tone: p.toneMapping, gamut: p.gamutMapping)
        )
        let outCS = RenderPipeline.colorSpace(for: p.target)
        let out = try LUTRenderer(gpu: gpu).apply(to: optical, lut: lut, outputColorSpace: outCS)
        XCTAssertGreaterThan(topMinusBottom(gpu, out, outCS), 0.3, "光學 + LUT 串接後影像上下顛倒")
    }
}
