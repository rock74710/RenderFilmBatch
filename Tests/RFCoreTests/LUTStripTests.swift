import CoreImage
import Foundation
import XCTest
@testable import RFCore

final class LUTStripTests: XCTestCase {
    func testStrippedPassMatchesFullFrameForOffsetBlurredImageAndPreservesAlpha() throws {
        guard let gpu = GPUContext.shared else {
            throw XCTSkip("This test requires a Metal device")
        }
        let width = 41
        let height = 21
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = Float((x * 13 + y * 7) % 97) / 96
                pixels[index + 1] = Float((x * 3 + y * 17) % 89) / 88
                pixels[index + 2] = Float((x * 11 + y * 5) % 83) / 82
                pixels[index + 3] = Float(20 + (x * 7 + y * 11) % 75) / 100
            }
        }
        let bitmap = pixels.withUnsafeBytes { Data($0) }
        let unshifted = CIImage(
            bitmapData: bitmap,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: gpu.workingColorSpace
        )
        let shifted = unshifted.transformed(by: CGAffineTransform(translationX: 23, y: 37))
        let source = shifted
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.25])
            .cropped(to: shifted.extent)
        let lut = LUT3D.bake(size: 9) { input in
            SIMD3(input.x * 0.65 + input.y * 0.08,
                  input.y * 0.7 + input.z * 0.06,
                  input.z * 0.75 + input.x * 0.04)
        }
        let outputColorSpace = gpu.workingColorSpace

        let fullFrame = try LUTRenderer(gpu: gpu).apply(
            to: source, lut: lut, outputColorSpace: outputColorSpace
        )
        let stripped = try LUTRenderer(gpu: gpu, maximumSourceRows: 3).apply(
            to: source, lut: lut, outputColorSpace: outputColorSpace
        )

        XCTAssertEqual(fullFrame.extent, source.extent)
        XCTAssertEqual(stripped.extent, source.extent)
        let fullPixels = readPixels(fullFrame, width: width, height: height,
                                   origin: source.extent.origin, context: gpu.ciContext,
                                   colorSpace: outputColorSpace)
        let strippedPixels = readPixels(stripped, width: width, height: height,
                                        origin: source.extent.origin, context: gpu.ciContext,
                                        colorSpace: outputColorSpace)
        XCTAssertEqual(fullPixels.count, strippedPixels.count)
        for index in fullPixels.indices {
            XCTAssertEqual(strippedPixels[index], fullPixels[index], accuracy: 1e-6,
                           "Strip output differs at RGBA float component \(index)")
        }
        var distinctAlphaValues = Set<Int>()
        for (index, component) in strippedPixels.enumerated() where index % 4 == 3 {
            distinctAlphaValues.insert(Int((component * 10_000).rounded()))
        }
        XCTAssertGreaterThan(distinctAlphaValues.count, 1,
            "The test source should retain varying alpha through the LUT pass")
    }

    private func readPixels(_ image: CIImage, width: Int, height: Int, origin: CGPoint,
                            context: CIContext, colorSpace: CGColorSpace) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            format: .RGBAf,
            colorSpace: colorSpace
        )
        return pixels
    }
}
