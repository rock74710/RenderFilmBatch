import XCTest
@testable import RFCore

/// A-069：Layer C 三個色輪背後的純計算部分。
final class GradeWheelEditingTests: XCTestCase {

    func testPointOnRimSetsHueAndMaxAmount() {
        var wheel = GradeWheel()
        wheel.luminance = 0.3
        let up = GradeWheelEditing.dragged(wheel, to: SIMD2(0, 1))
        XCTAssertEqual(up.hue, 90, accuracy: 1e-9)
        XCTAssertEqual(up.amount, GradeWheelEditing.maxAmount, accuracy: 1e-12)
        XCTAssertEqual(up.luminance, 0.3, "拖色輪不能動到亮度")

        let left = GradeWheelEditing.dragged(wheel, to: SIMD2(-0.5, 0))
        XCTAssertEqual(left.hue, 180, accuracy: 1e-9)
        XCTAssertEqual(left.amount, GradeWheelEditing.maxAmount / 2, accuracy: 1e-12)

        let down = GradeWheelEditing.dragged(wheel, to: SIMD2(0, -1))
        XCTAssertEqual(down.hue, 270, accuracy: 1e-9, "色相一律落在 0…360")
    }

    func testDragOutsideWheelClampsAmount() {
        let out = GradeWheelEditing.dragged(GradeWheel(), to: SIMD2(3, 0))
        XCTAssertEqual(out.hue, 0, accuracy: 1e-9)
        XCTAssertEqual(out.amount, GradeWheelEditing.maxAmount, accuracy: 1e-12)
    }

    func testCenterClearsAmountButKeepsHue() {
        var wheel = GradeWheel()
        wheel.hue = 200
        wheel.amount = 0.1
        let centered = GradeWheelEditing.dragged(wheel, to: SIMD2(0, 0))
        XCTAssertEqual(centered.amount, 0)
        XCTAssertEqual(centered.hue, 200, "在正中心沒有方向，保留原本色相")
    }

    func testPointRoundTripsWithDrag() {
        var wheel = GradeWheel()
        wheel.hue = 135
        wheel.amount = 0.06
        let p = GradeWheelEditing.point(wheel)
        let back = GradeWheelEditing.dragged(GradeWheel(), to: p)
        XCTAssertEqual(back.hue, 135, accuracy: 1e-9)
        XCTAssertEqual(back.amount, 0.06, accuracy: 1e-12)
    }

    func testDisplayColorFollowsOKLabHue() {
        // OKLCh 色相 30° 附近是紅、140° 附近是綠、265° 附近是藍。
        let red = GradeWheelEditing.displayColor(hue: 30)
        XCTAssertGreaterThan(red.x, red.y)
        XCTAssertGreaterThan(red.x, red.z)
        let green = GradeWheelEditing.displayColor(hue: 140)
        XCTAssertGreaterThan(green.y, green.x)
        XCTAssertGreaterThan(green.y, green.z)
        let blue = GradeWheelEditing.displayColor(hue: 265)
        XCTAssertGreaterThan(blue.z, blue.x)
        XCTAssertGreaterThan(blue.z, blue.y)
        for c in [red, green, blue] {
            XCTAssertTrue((0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z))
        }
    }
}
