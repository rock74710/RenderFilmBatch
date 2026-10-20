import XCTest
@testable import RFCore

/// A-105：預覽雙指縮放與點兩下切換的純計算部分。nil 代表「適合視窗」。
final class PreviewZoomTests: XCTestCase {

    func testDetailUsesOriginalPixelZoomThreshold() {
        XCTAssertFalse(PreviewZoom.needsDetail(level: nil, proxyScale: 0.25))
        XCTAssertFalse(PreviewZoom.needsDetail(level: 0.25, proxyScale: 0.25))
        XCTAssertTrue(PreviewZoom.needsDetail(level: 1, proxyScale: 0.25))
        XCTAssertFalse(PreviewZoom.needsDetail(level: 2, proxyScale: 1))
    }

    func testDoubleClickTogglesBetweenFitAndConfiguredLevel() {
        XCTAssertEqual(PreviewZoom.toggled(nil, doubleClickLevel: 2), 2)
        XCTAssertNil(PreviewZoom.toggled(2, doubleClickLevel: 2))
        XCTAssertNil(PreviewZoom.toggled(0.7, doubleClickLevel: 1), "已放大（含捏合後）點兩下一律回適合視窗")
    }

    func testPinchStartsFromFitAndScales() {
        // 適合視窗時相當於 25%，捏合放大 2 倍是 50%。
        XCTAssertEqual(PreviewZoom.pinched(from: nil, magnification: 2, fitLevel: 0.25)!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(PreviewZoom.pinched(from: 1, magnification: 1.5, fitLevel: 0.25)!, 1.5, accuracy: 1e-12)
    }

    func testPinchBelowFitReturnsToFitAndClampsAtMax() {
        XCTAssertNil(PreviewZoom.pinched(from: 0.5, magnification: 0.4, fitLevel: 0.25))
        XCTAssertEqual(PreviewZoom.pinched(from: 2, magnification: 10, fitLevel: 0.25), PreviewZoom.maxLevel)
    }
}
