import XCTest
import CoreImage
@testable import RFCore

final class SuperResolutionTests: XCTestCase {
    func testReturnedImageOwnsPixelStorageAfterUpscaleReturns() throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let image = try autoreleasepool {
            let source = Self.p2Fixture()
            XCTAssertEqual(source.extent, CGRect(x: 31, y: -17, width: 225, height: 225))
            return try SuperResolution.shared().upscale2x(source, context: gpu.ciContext)
        }
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 450, height: 450))

        var first = [Float16](repeating: 0, count: 450 * 450 * 4)
        gpu.ciContext.render(image, toBitmap: &first, rowBytes: 450 * 8,
                             bounds: CGRect(x: 0, y: 0, width: 450, height: 450),
                             format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var second = [Float16](repeating: 0, count: first.count)
        gpu.ciContext.render(image, toBitmap: &second, rowBytes: 450 * 8,
                             bounds: CGRect(x: 0, y: 0, width: 450, height: 450),
                             format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        XCTAssertEqual(first, second)
        XCTAssertTrue(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 1 })
    }

    private static func p2Fixture() -> CIImage {
        let width = 225, height = 225
        var values = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                values[offset] = Float16((x * 7 + y * 3) % 251) / 250
                values[offset + 1] = Float16((x * 5 + y * 11) % 241) / 240
                values[offset + 2] = Float16((x * 13 + y * 2) % 239) / 238
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 8, size: CGSize(width: width, height: height),
                       format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            .transformed(by: CGAffineTransform(translationX: 31, y: -17))
    }

    /// AC-4: a 1000 px image with long edge 2000 goes through the model; HDR or shrinking stays on Lanczos.
    func testEnlargingUsesModelAndHitsExactTarget() throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: ["inputWidth": 3])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 667))
        var settings = BatchExportSettings()
        settings.outputSize = .longEdge(2000)
        settings.superResolution = true
        let (image, superResolved) = try BatchExporter.finalImage(stripes, settings: settings, context: gpu.ciContext)
        XCTAssertTrue(superResolved)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 2000, height: 1334))
        let model = try SuperResolution.shared().upscale2x(stripes, context: gpu.ciContext)
        XCTAssertEqual(model.extent, CGRect(x: 0, y: 0, width: 2000, height: 1334))
        let difference = model.applyingFilter("CIDifferenceBlendMode",
                                              parameters: [kCIInputBackgroundImageKey: BatchExporter.resize(stripes, to: .percent(200))])
        XCTAssertGreaterThan(Self.mean(difference, context: gpu.ciContext), 0.001)

        settings.hdr = true
        XCTAssertFalse(try BatchExporter.finalImage(stripes, settings: settings, context: gpu.ciContext).superResolved)
        settings.hdr = false
        settings.outputSize = .percent(50)
        XCTAssertFalse(try BatchExporter.finalImage(stripes, settings: settings, context: gpu.ciContext).superResolved)
    }

    /// 超解析度一張要跑很久，取消時逐塊檢查，不等整張放大完。
    func testCancelledUpscaleStops() async throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: ["inputWidth": 3])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SuperResolution.shared().upscale2x(stripes, context: gpu.ciContext)
        }
        do {
            _ = try await task.value
            XCTFail("取消後不應完成放大")
        } catch is CancellationError {
        }
    }

    /// INV-1: with super-resolution off, the size step is exactly the earlier Lanczos resize.
    func testDefaultSettingsKeepLanczosPixels() throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: ["inputWidth": 3])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        for size in [BatchExportSettings.OutputSize.original, .longEdge(600), .percent(50)] {
            var settings = BatchExportSettings()
            settings.outputSize = size
            let (image, superResolved) = try BatchExporter.finalImage(stripes, settings: settings, context: gpu.ciContext)
            XCTAssertFalse(superResolved)
            let difference = image.applyingFilter("CIDifferenceBlendMode",
                                                  parameters: [kCIInputBackgroundImageKey: BatchExporter.resize(stripes, to: size)])
            XCTAssertEqual(Self.mean(difference, context: gpu.ciContext), 0, "\(size)")
        }
    }

    static func mean(_ image: CIImage, context: CIContext) -> Double {
        var out = [Float](repeating: 0, count: 4)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        context.render(average, toBitmap: &out, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return Double(out[0])
    }
}
