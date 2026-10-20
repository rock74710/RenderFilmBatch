import XCTest
@testable import RFCore

/// A-046：可拖曳曲線圖背後的純計算部分。
final class CurveEditingTests: XCTestCase {

    func testEmptyCurveReadsAsIdentity() {
        XCTAssertEqual(CurveEditing.points([]), CurveEditing.identity)
        XCTAssertEqual(CurveEditing.points([0.2, 0.4]), CurveEditing.identity,
                       "長度不是 5 的舊資料一律當成直線")
    }

    func testDraggingMidNodeCreatesFivePoints() {
        let moved = CurveEditing.moved([], node: 2, to: 0.7)
        XCTAssertEqual(moved.count, 5)
        XCTAssertEqual(moved[2], 0.7, accuracy: 1e-12)
        XCTAssertEqual(moved[0], 0, accuracy: 1e-12)
        XCTAssertEqual(moved[4], 1, accuracy: 1e-12)
    }

    func testDragBeyondCanvasClampsToRange() {
        XCTAssertEqual(CurveEditing.moved([], node: 2, to: 1.8)[2], 1, accuracy: 1e-12)
        XCTAssertEqual(CurveEditing.moved([], node: 2, to: -0.5)[2], 0, accuracy: 1e-12)
    }

    func testDraggingBackToIdentityCollapsesToEmpty() {
        let lifted = CurveEditing.moved([], node: 1, to: 0.6)
        XCTAssertFalse(lifted.isEmpty)
        XCTAssertTrue(CurveEditing.moved(lifted, node: 1, to: 0.25).isEmpty)
    }

    func testEndpointsAreDraggable() {
        let blackPoint = CurveEditing.moved([], node: 0, to: 0.1)
        XCTAssertEqual(blackPoint[0], 0.1, accuracy: 1e-12)
        let whitePoint = CurveEditing.moved([], node: 4, to: 0.9)
        XCTAssertEqual(whitePoint[4], 0.9, accuracy: 1e-12)
    }

    func testNearestNodePicksClosestByInput() {
        XCTAssertEqual(CurveEditing.nearestNode(at: 0.02), 0)
        XCTAssertEqual(CurveEditing.nearestNode(at: 0.3), 1)
        XCTAssertEqual(CurveEditing.nearestNode(at: 0.51), 2)
        XCTAssertEqual(CurveEditing.nearestNode(at: 0.99), 4)
        XCTAssertEqual(CurveEditing.nearestNode(at: -3), 0, "畫布外也要落在合法索引")
        XCTAssertEqual(CurveEditing.nearestNode(at: 3), 4)
    }

    func testSampledCurveMatchesEvaluate() {
        let points = CurveEditing.moved([], node: 2, to: 0.7)
        let samples = CurveEditing.sampled(points, count: 5)
        XCTAssertEqual(samples.count, 5)
        for (i, value) in samples.enumerated() {
            let x = Double(i) / 4
            XCTAssertEqual(value, FinalCurve.evaluate(points, x), accuracy: 1e-12,
                           "畫出來的線必須就是實際套用的線")
        }
    }

    /// A-047 驗收條件 6（INV-5）：四個分頁各自對應 `FinalCurve` 既有的一個陣列，
    /// 動其中一條不會影響另外三條。
    func testEditingOneChannelLeavesOthersUntouched() {
        var curve = FinalCurve()
        curve.red = CurveEditing.moved(curve.red, node: 3, to: 0.9)

        XCTAssertEqual(curve.red.count, 5)
        XCTAssertTrue(curve.rgb.isEmpty)
        XCTAssertTrue(curve.green.isEmpty)
        XCTAssertTrue(curve.blue.isEmpty)
        XCTAssertFalse(curve.isNeutral)
    }

    /// 只調 R 分頁時，套用後只有紅色通道改變。
    func testRedChannelOnlyAffectsRed() {
        var curve = FinalCurve()
        curve.red = CurveEditing.moved([], node: 3, to: 0.9)
        let out = curve.apply(SIMD3(0.75, 0.75, 0.75))
        XCTAssertEqual(out.x, 0.9, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.75, accuracy: 1e-12)
        XCTAssertEqual(out.z, 0.75, accuracy: 1e-12)
    }
}
