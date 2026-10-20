import XCTest
@testable import RFCore

final class BatchCurveTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rf-curve-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 每張 RAW 各自一份 XML，存檔讀回完全相同；同名不同副檔名的 RAW 不共用。
    func testRoundTripPerRawFile() throws {
        let nef = tempDir.appendingPathComponent("A.NEF")
        let cr2 = tempDir.appendingPathComponent("A.CR2")
        var curve = BatchCurve()
        curve.mode = .rgb
        curve.luma = [0, 0.3, 0.5, 0.7, 1]
        curve.red = [0.05, 0.25, 0.5, 0.75, 0.95]
        curve.blue = [0, 0.2, 0.45, 0.72, 1]
        try curve.save(forRaw: nef)

        XCTAssertEqual(BatchCurve.url(forRaw: nef).lastPathComponent, "A.NEF.rfcurve.xml")
        XCTAssertEqual(try BatchCurve.load(forRaw: nef), curve)
        XCTAssertNil(try BatchCurve.load(forRaw: cr2))
        let xml = try String(contentsOf: BatchCurve.url(forRaw: nef), encoding: .utf8)
        XCTAssertTrue(xml.contains("<renderfilm-curve"))
    }

    /// 曲線重置成直線時刪掉 XML，資料夾不留空檔。
    func testNeutralCurveRemovesFile() throws {
        let raw = tempDir.appendingPathComponent("B.ARW")
        var curve = BatchCurve()
        curve.luma = [0, 0.3, 0.5, 0.7, 1]
        try curve.save(forRaw: raw)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BatchCurve.url(forRaw: raw).path))

        curve.luma = []
        try curve.save(forRaw: raw)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BatchCurve.url(forRaw: raw).path))
        XCTAssertNil(try BatchCurve.load(forRaw: raw))
    }

    /// 一般模式只套合併曲線，RGB 模式只套三個通道。
    func testRenderCurveFollowsMode() {
        var curve = BatchCurve()
        curve.luma = [0, 0.3, 0.5, 0.7, 1]
        curve.green = [0, 0.2, 0.5, 0.8, 1]
        XCTAssertEqual(curve.finalCurve.rgb, curve.luma)
        XCTAssertEqual(curve.finalCurve.green, [])
        curve.mode = .rgb
        XCTAssertEqual(curve.finalCurve.rgb, [])
        XCTAssertEqual(curve.finalCurve.green, curve.green)
    }

    func testCorruptFileThrows() throws {
        let raw = tempDir.appendingPathComponent("C.ARW")
        try Data("not xml".utf8).write(to: BatchCurve.url(forRaw: raw))
        XCTAssertThrowsError(try BatchCurve.load(forRaw: raw))
    }
}
