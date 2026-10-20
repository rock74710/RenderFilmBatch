import XCTest
@testable import RFCore

final class SidecarTests: XCTestCase {
    func testLegacyRenderingTargetDefaultsRemainSDRDisplayP3() throws {
        let data = Data(#"{"dynamicRange":"sdr","gamut":"displayP3"}"#.utf8)
        let target = try JSONDecoder().decode(RenderingTarget.self, from: data)
        XCTAssertEqual(target.dynamicRange, .sdr)
        XCTAssertEqual(target.gamut, .displayP3)
        XCTAssertEqual(target.contentHeadroom, 1)
        XCTAssertEqual(target.referenceWhiteNits, 203)
        XCTAssertEqual(target.transferFunction, .sRGB)
        XCTAssertEqual(target.intent, .appleSDR)
    }
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 驗收條件 7：sidecar 存檔／讀回後參數完全相同。
    func testRoundTrip() throws {
        let raw = tempDir.appendingPathComponent("IMG_0001.ARW")
        try Data("not a real raw".utf8).write(to: raw)

        var params = EditParameters()
        params.layerA.exposureEV = -0.75
        params.layerA.temperature = 4800
        params.colorEngine.illuminant = .tungsten
        params.colorEngine.hueShifts[2] = -3.5
        params.target.gamut = .sRGB

        var versions = PipelineVersions()
        versions.rawDecoder = "8.0.1"
        let sidecar = Sidecar(rawFileName: raw.lastPathComponent,
                              versions: versions, parameters: params)
        try sidecar.save(forRaw: raw)

        let loaded = try XCTUnwrap(Sidecar.load(forRaw: raw))
        XCTAssertEqual(loaded.parameters, params)
        XCTAssertEqual(loaded.versions.rawDecoder, "8.0.1")
        XCTAssertEqual(loaded.formatVersion, Sidecar.currentFormatVersion)
    }

    /// INV-6：寫 sidecar 不會動到 RAW 原檔。
    func testRawFileUntouched() throws {
        let raw = tempDir.appendingPathComponent("IMG_0002.CR2")
        let original = Data("original bytes".utf8)
        try original.write(to: raw)
        try Sidecar(rawFileName: raw.lastPathComponent).save(forRaw: raw)
        XCTAssertEqual(try Data(contentsOf: raw), original)
        XCTAssertEqual(Sidecar.url(forRaw: raw).lastPathComponent, "IMG_0002.rfedit.json")
    }

    func testMissingSidecarReturnsNil() throws {
        let raw = tempDir.appendingPathComponent("none.ARW")
        try Data().write(to: raw)
        XCTAssertNil(try Sidecar.load(forRaw: raw))
    }
}

final class EditHistoryTests: XCTestCase {
    /// 驗收條件 7：undo / redo 可回到前一狀態。
    func testUndoRedo() {
        let history = EditHistory()
        XCTAssertFalse(history.canUndo)

        history.apply { $0.layerA.exposureEV = 1 }
        history.apply { $0.layerA.exposureEV = 2 }
        XCTAssertEqual(history.current.layerA.exposureEV, 2)

        XCTAssertEqual(history.undo()?.layerA.exposureEV, 1)
        XCTAssertEqual(history.undo()?.layerA.exposureEV, 0)
        XCTAssertNil(history.undo())

        XCTAssertEqual(history.redo()?.layerA.exposureEV, 1)
        XCTAssertEqual(history.redo()?.layerA.exposureEV, 2)
        XCTAssertNil(history.redo())
    }

    /// 沒有實際改變的操作不該塞滿 undo stack。
    func testNoOpChangeIsIgnored() {
        let history = EditHistory()
        XCTAssertFalse(history.apply { $0.layerA.exposureEV = 0 })
        XCTAssertFalse(history.canUndo)
    }

    /// 新的修改會清掉 redo 分支。
    func testNewChangeClearsRedo() {
        let history = EditHistory()
        history.apply { $0.layerA.exposureEV = 1 }
        _ = history.undo()
        XCTAssertTrue(history.canRedo)
        history.apply { $0.layerA.chroma = 1.2 }
        XCTAssertFalse(history.canRedo)
    }

    func testLimitKeepsRecentHistory() {
        let history = EditHistory(limit: 3)
        for i in 1...10 { history.apply { $0.layerA.exposureEV = Double(i) } }
        var steps = 0
        while history.undo() != nil { steps += 1 }
        XCTAssertEqual(steps, 3)
    }
}
