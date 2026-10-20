import XCTest
import CoreImage
@testable import RFCore

final class AutoExposureTests: XCTestCase {
    func testMiddleGrayStaysNeutral() {
        let result = AutoExposure.analyzeRGBA(Array(repeating: [Float(0.18), 0.18, 0.18, 1], count: 100).flatMap { $0 })
        XCTAssertEqual(result.ev, 0, accuracy: 0.0001)
        XCTAssertEqual(result.validPixelCount, 100)
    }

    func testDarkFrameBrightensWithinLimit() {
        let result = AutoExposure.analyzeRGBA(Array(repeating: [Float(0.045), 0.045, 0.045, 1], count: 100).flatMap { $0 })
        XCTAssertEqual(result.ev, 2, accuracy: 0.0001)
    }

    func testHighlightsLimitBrightening() {
        var pixels = Array(repeating: [Float(0.045), 0.045, 0.045, 1], count: 99)
        pixels.append([1.2, 1.2, 1.2, 1])
        let result = AutoExposure.analyzeRGBA(pixels.flatMap { $0 })
        XCTAssertEqual(result.ev, 0, accuracy: 0.0001)
    }

    func testInvalidFrameFallsBackToZero() {
        let result = AutoExposure.analyzeRGBA([.nan, 1, 1, 1, 0, 0, 0, 1])
        XCTAssertEqual(result.ev, 0)
        XCTAssertTrue(result.usedFallback)
    }

    func testCIImageSamplingUsesBoundedSceneLinearPixels() {
        let image = CIImage(color: CIColor(red: 0.045, green: 0.045, blue: 0.045))
            .cropped(to: CGRect(x: 100, y: 200, width: 16, height: 16))
        let result = AutoExposure.analyze(image, context: CIContext())
        XCTAssertEqual(result.ev, 2, accuracy: 0.01)
        XCTAssertEqual(result.validPixelCount, 256)
    }

    func testWeightsMeterTheWeightedRegion() {
        // Bright background, dark subject: the subject's weight should pull EV up.
        var pixels = Array(repeating: [Float(0.36), 0.36, 0.36, 1], count: 80)
        pixels += Array(repeating: [Float(0.045), 0.045, 0.045, 1], count: 20)
        let weights = Array(repeating: Float(0.25), count: 80) + Array(repeating: Float(4), count: 20)
        let plain = AutoExposure.analyzeRGBA(pixels.flatMap { $0 })
        let weighted = AutoExposure.analyzeRGBA(pixels.flatMap { $0 }, weights: weights)
        XCTAssertEqual(plain.ev, -1, accuracy: 0.0001)
        XCTAssertEqual(weighted.medianLuminance ?? 0, 0.045, accuracy: 0.0001)
    }

    func testZeroWeightsFallBackToPlainMedian() {
        let pixels: [Float] = Array(repeating: [Float(0.09), 0.09, 0.09, 1], count: 10).flatMap { $0 }
        let result = AutoExposure.analyzeRGBA(pixels, weights: [Float](repeating: 0, count: 10))
        XCTAssertEqual(result.ev, 1, accuracy: 0.0001)
    }

    func testSkyIsOnlyDarkened() {
        XCTAssertEqual(AutoExposure.skyEV(skyMedian: 0.1, globalEV: 0), 0)
        XCTAssertEqual(AutoExposure.skyEV(skyMedian: 0.18 * exp2(2.5), globalEV: 0), -1, accuracy: 0.0001)
        XCTAssertEqual(AutoExposure.skyEV(skyMedian: 0.18 * exp2(1.5), globalEV: 1), -1, accuracy: 0.0001)
        XCTAssertEqual(AutoExposure.skyEV(skyMedian: 50, globalEV: 2), -2)
        XCTAssertEqual(AutoExposure.skyEV(skyMedian: .nan, globalEV: 0), 0)
    }

    func testRegionalEVOnlyChangesMaskedArea() {
        let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
        let image = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: extent)
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 200, width: 400, height: 200))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let result = AutoExposure.applyRegionalEV(-1, mask: mask, to: image)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        func sample(_ y: CGFloat) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(result, toBitmap: &pixel, rowBytes: 16,
                           bounds: CGRect(x: 200, y: y, width: 1, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return pixel[0]
        }
        // -1 EV in linear light halves the masked side; the unmasked side is untouched.
        XCTAssertEqual(sample(380) / sample(20), 0.5, accuracy: 0.01)
    }
}
