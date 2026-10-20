import XCTest
import CoreImage
@testable import RFCore

/// 放大預覽只渲染可見區域（A-135 F3）：局部結果必須等於整張渲染後裁出同一塊。
final class RegionRenderTests: XCTestCase {
    private var gpu: GPUContext!
    private var renderer: SpatialRenderer!

    override func setUpWithError() throws {
        gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        renderer = try SpatialRenderer()
    }

    /// 有細節、有亮部的合成影像，讓清晰度、光暈、去霧都真的改變像素。
    private func pattern(width: Int, height: Int) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let wave = 0.5 + 0.3 * sin(Double(x) * 0.21) * cos(Double(y) * 0.17)
                let spot = (x / 37 + y / 29) % 5 == 0 ? 0.45 : 0
                let ramp = Double(x) / Double(width) * 0.2
                pixels[i] = Float(min(wave + spot + ramp, 1.4))
                pixels[i + 1] = Float(min(wave * 0.9 + spot, 1.4))
                pixels[i + 2] = Float(min(wave * 0.7 + ramp, 1.4))
                pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: gpu.workingColorSpace)
    }

    private func pixels(_ image: CIImage, _ rect: CGRect) -> [Float] {
        var out = [Float](repeating: 0, count: Int(rect.width) * Int(rect.height) * 4)
        gpu.ciContext.render(image, toBitmap: &out, rowBytes: Int(rect.width) * 4 * MemoryLayout<Float>.size,
                             bounds: rect, format: .RGBAf, colorSpace: gpu.workingColorSpace)
        return out
    }

    private var everyEffect: SpatialFinishingParameters {
        var p = SpatialFinishingParameters()
        p.dehaze = 0.4
        p.clarity = -0.6
        p.texture = 0.3
        p.sharpening.amount = 0.5
        p.glow.amount = 0.5
        p.vignette.amount = 0.6
        p.grain.amount = 0.5
        return p
    }

    func testRegionWithMarginMatchesCroppedFullRender() throws {
        let source = pattern(width: 512, height: 384)
        let extent = source.extent
        let p = everyEffect
        let full = try renderer.apply(p, to: source)
        let margin = renderer.sampleMargin(p, extent: extent)
        XCTAssertGreaterThan(margin, 0)
        for region in [CGRect(x: 300, y: 140, width: 120, height: 90),
                       CGRect(x: 0, y: 0, width: 100, height: 80),
                       CGRect(x: 412, y: 304, width: 100, height: 80)] {
            let work = region.insetBy(dx: -margin, dy: -margin).intersection(extent).integral
            let partial = try renderer.apply(p, to: source.cropped(to: work), globalExtent: extent)
            let a = pixels(full, region), b = pixels(partial, region)
            var maximum: Float = 0, total: Float = 0, overOne = 0
            for i in a.indices where i % 4 != 3 {
                let d = abs(a[i] - b[i]) * 255
                maximum = max(maximum, d); total += d
                if d > 1 { overOne += 1 }
            }
            let count = Float(a.count / 4 * 3)
            XCTAssertLessThanOrEqual(maximum, 2, "region \(region) max")
            XCTAssertLessThanOrEqual(total / count, 0.1, "region \(region) mean")
            XCTAssertLessThanOrEqual(Float(overOne) / count, 0.001, "region \(region) >1/255 share")
        }
    }

    func testZoneOnlyClarityWithMarginMatchesCroppedFullRender() throws {
        let source = pattern(width: 512, height: 384)
        let extent = source.extent
        var parameters = SpatialFinishingParameters()
        parameters.clarity = 0
        parameters.clarityOffsets = ClarityOffsets(midtones: 0.65)
        XCTAssertTrue(parameters.hasClarity)

        let full = try renderer.apply(parameters, to: source)
        let margin = renderer.sampleMargin(parameters, extent: extent)
        XCTAssertGreaterThan(margin, 0, "offset-only clarity needs the existing blur margin")
        let region = CGRect(x: 190, y: 130, width: 120, height: 90)
        let work = region.insetBy(dx: -margin, dy: -margin).intersection(extent).integral
        let partial = try renderer.apply(parameters, to: source.cropped(to: work), globalExtent: extent)
        let a = pixels(full, region), b = pixels(partial, region)
        var maximum: Float = 0, total: Float = 0
        for i in a.indices where i % 4 != 3 {
            let difference = abs(a[i] - b[i]) * 255
            maximum = max(maximum, difference)
            total += difference
        }
        XCTAssertLessThanOrEqual(maximum, 2, "zone-only clarity region maximum")
        XCTAssertLessThanOrEqual(total / Float(a.count / 4 * 3), 0.1, "zone-only clarity region mean")
    }

    func testPointwiseEffectsNeedNoMarginAndBlurEffectsScaleWithTheImage() {
        var pointwise = SpatialFinishingParameters()
        pointwise.vignette.amount = 0.5
        pointwise.grain.amount = 0.5
        XCTAssertEqual(renderer.sampleMargin(pointwise, extent: CGRect(x: 0, y: 0, width: 6000, height: 4000)), 2)
        XCTAssertEqual(renderer.sampleMargin(SpatialFinishingParameters(), extent: CGRect(x: 0, y: 0, width: 6000, height: 4000)), 0)
        var clarity = SpatialFinishingParameters()
        clarity.clarity = 0.5
        let small = renderer.sampleMargin(clarity, extent: CGRect(x: 0, y: 0, width: 600, height: 400))
        let large = renderer.sampleMargin(clarity, extent: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        XCTAssertGreaterThan(large, small * 5)
        // 只開清晰度時，100% 放大看一塊 1600×1000 的工作範圍遠小於整張 24MP。
        let work = CGRect(x: 2000, y: 1500, width: 1600, height: 1000).insetBy(dx: -large, dy: -large)
        XCTAssertLessThan(work.width * work.height, 6000 * 4000 / 4)
    }
}
