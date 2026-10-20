import XCTest
@testable import RFCore

final class HistogramTests: XCTestCase {
    func testRGBExposureHistogramPlacesPrimaryChannelsAndLuminance() {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        let h = HistogramCalculator.calculate(
            rgba: pixels, width: 2, height: 1, bytesPerRow: 8,
            mode: .rgbExposure, bins: 16
        )
        XCTAssertEqual(h.channels.count, 4)
        XCTAssertEqual(h.channels[0][15], 1)
        XCTAssertEqual(h.channels[1][15], 1)
        XCTAssertEqual(h.channels[2][0], 1)
        XCTAssertEqual(h.channels[3][3], 1)
        XCTAssertEqual(h.channels[3][11], 1)
    }

    func testExtendedLinearHistogramSeparatesSDRWhiteFromHeadroom() {
        // 一個 SDR white 像素、一個打到 headroom 上限的像素。
        let pixels: [Float] = [1, 1, 1, 1, 2, 2, 2, 1]
        let h = HistogramCalculator.calculateExtendedLinear(
            rgba: pixels, width: 2, height: 1, componentsPerRow: 8,
            mode: .rgbExposure, headroom: 2, bins: 16
        )
        guard let white = h.sdrWhitePosition else {
            return XCTFail("EDR 直方圖應提供 SDR white 標記")
        }
        XCTAssertGreaterThan(white, 0)
        XCTAssertLessThan(white, 1)

        let whiteBin = Int(white * 16)
        XCTAssertEqual(h.channels[0][whiteBin], 1)   // SDR white 落在標記上
        XCTAssertEqual(h.channels[0][15], 1)         // headroom 上限落在最右端
    }

    func testSDRHeadroomHistogramHasNoWhiteMarker() {
        let pixels: [Float] = [1, 1, 1, 1]
        let h = HistogramCalculator.calculateExtendedLinear(
            rgba: pixels, width: 1, height: 1, componentsPerRow: 4,
            mode: .rgbExposure, headroom: 1, bins: 16
        )
        XCTAssertNil(h.sdrWhitePosition)
        XCTAssertEqual(h.channels[0][15], 1)
    }

    func testLabHistogramKeepsNeutralGreyNearCenteredAB() {
        let grey: [UInt8] = [128, 128, 128, 255]
        let h = HistogramCalculator.calculate(
            rgba: grey, width: 1, height: 1, bytesPerRow: 4,
            mode: .lab, bins: 32
        )
        XCTAssertEqual(h.channels[1][16], 1)
        XCTAssertEqual(h.channels[2][16], 1)
        XCTAssertEqual(h.channels[3].reduce(0, +), 0)
    }
}
