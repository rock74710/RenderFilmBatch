import XCTest
@testable import RFCore

/// A-047：§15 History / Snapshot / Preset 的核心資料模型。
final class EditHistoryStepTests: XCTestCase {

    /// 驗收條件 1：歷史清單列得出來，而且可以跳來跳去（INV-3）。
    func testStepsAreListedAndJumpable() {
        let history = EditHistory()
        history.apply { $0.layerA.exposureEV = 1 }
        history.apply { $0.finishing.finalContrast = 0.4 }
        history.apply { $0.spatial.grain.amount = 0.2 }

        // 第一步是開檔狀態，後面三步各一次修改。
        XCTAssertEqual(history.steps.count, 4)
        XCTAssertEqual(history.steps.first?.label, EditHistory.openLabel)
        XCTAssertEqual(history.index, 3)

        XCTAssertEqual(history.jump(to: 1)?.layerA.exposureEV, 1)
        XCTAssertEqual(history.current.finishing.finalContrast, 0)
        // 跳回去沒有弄丟任何一步。
        XCTAssertEqual(history.steps.count, 4)
        XCTAssertEqual(history.jump(to: 3)?.spatial.grain.amount, 0.2)
        XCTAssertEqual(history.current.finishing.finalContrast, 0.4)
    }

    func testJumpOutOfRangeIsIgnored() {
        let history = EditHistory()
        history.apply { $0.layerA.exposureEV = 1 }
        XCTAssertNil(history.jump(to: 5))
        XCTAssertNil(history.jump(to: -1))
        XCTAssertEqual(history.index, 1)
    }

    /// 跳回去之後再修改，會蓋掉游標後面那幾步（undo 後再編輯的慣例）。
    func testEditingAfterJumpTruncatesForwardSteps() {
        let history = EditHistory()
        history.apply { $0.layerA.exposureEV = 1 }
        history.apply { $0.layerA.exposureEV = 2 }
        _ = history.jump(to: 1)
        history.apply { $0.layerA.chroma = 1.2 }

        XCTAssertEqual(history.steps.count, 3)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.current.layerA.exposureEV, 1)
    }

    /// 標籤要看得出改了哪一區，面板才有意義。
    func testLabelNamesChangedSections() {
        let history = EditHistory()
        history.apply { $0.finishing.finalContrast = 0.3 }
        XCTAssertEqual(history.steps.last?.label, EditSection.finishing.displayName)

        history.apply {
            $0.layerA.exposureEV = 1
            $0.spatial.grain.amount = 0.1
        }
        XCTAssertEqual(history.steps.last?.label,
                       "\(EditSection.layerA.displayName)、\(EditSection.spatial.displayName)")
    }

    /// 超過上限時淘汰的是中間最舊的步驟，開檔那一步要留著才回得去。
    func testLimitKeepsTheOpeningStep() {
        let history = EditHistory(limit: 3)
        for i in 1...10 { history.apply { $0.layerA.exposureEV = Double(i) } }
        XCTAssertEqual(history.steps.count, 4)
        XCTAssertEqual(history.steps.first?.label, EditHistory.openLabel)
        XCTAssertEqual(history.jump(to: 0)?.layerA.exposureEV, 0)
    }

    func testMaskChangeGetsItsOwnLabel() {
        let history = EditHistory()
        history.apply { $0.localMasks = [LocalMask(kind: .gradient)] }
        XCTAssertEqual(history.steps.last?.label, "遮罩與筆刷")
    }

    /// A-058：拖曳一次滑桿（按下到放開）只記一步，一次 Undo 回到拖曳前。
    func testOneInteractionIsOneStep() {
        let history = EditHistory()
        history.beginInteraction()
        for ev in stride(from: 0.1, through: 1.5, by: 0.1) {
            history.apply { $0.layerA.exposureEV = ev }
        }
        history.endInteraction()

        XCTAssertEqual(history.steps.count, 2)
        XCTAssertEqual(history.current.layerA.exposureEV, 1.5, accuracy: 1e-9)
        XCTAssertEqual(history.undo()?.layerA.exposureEV, 0)
    }

    /// 放開之後的下一個修改是新的一步；拖回原值則不留下空步驟。
    func testInteractionEndsAndRevertIsDropped() {
        let history = EditHistory()
        history.beginInteraction()
        history.apply { $0.layerA.exposureEV = 1 }
        history.endInteraction()
        history.apply { $0.finishing.finalContrast = 0.4 }
        XCTAssertEqual(history.steps.count, 3)

        history.beginInteraction()
        history.apply { $0.spatial.clarity = 0.3 }
        history.apply { $0.spatial.clarity = 0 }
        history.endInteraction()
        XCTAssertEqual(history.steps.count, 3)
        XCTAssertEqual(history.steps.last?.label, EditSection.finishing.displayName)
    }
}

final class EditSnapshotTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rf-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 驗收條件 2：快照隨 sidecar 存檔、讀回後內容相同。
    func testSnapshotsSurviveSidecarRoundTrip() throws {
        let raw = tempDir.appendingPathComponent("IMG_0100.ARW")
        try Data("raw".utf8).write(to: raw)

        var warm = EditParameters()
        warm.layerA.temperature = 7200
        warm.finishing.curve.red = [0, 0.3, 0.55, 0.8, 1]

        let sidecar = Sidecar(rawFileName: raw.lastPathComponent,
                              snapshots: [EditSnapshot(name: "暖調版本", parameters: warm)])
        try sidecar.save(forRaw: raw)

        let loaded = try XCTUnwrap(Sidecar.load(forRaw: raw))
        XCTAssertEqual(loaded.snapshots.count, 1)
        XCTAssertEqual(loaded.snapshots.first?.name, "暖調版本")
        XCTAssertEqual(loaded.snapshots.first?.parameters, warm)
    }

    /// 驗收條件 3（INV-1）：A-047 之前寫出的 sidecar 沒有 snapshots 欄位，仍要能載入。
    func testLegacySidecarWithoutSnapshotsDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: encoder.encode(Sidecar(rawFileName: "IMG_0101.ARW"))
        ) as! [String: Any]
        object.removeValue(forKey: "snapshots")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(
            Sidecar.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(legacy.snapshots.isEmpty)
        XCTAssertEqual(legacy.rawFileName, "IMG_0101.ARW")
        XCTAssertEqual(legacy.parameters, EditParameters())
    }
}

final class PresetTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rf-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 驗收條件 4（INV-2）：預設集只換勾選的區塊，遮罩與光學校正原封不動。
    func testPresetOnlyReplacesSelectedSections() {
        var source = EditParameters()
        source.finishing.finalContrast = 0.6
        source.layerA.exposureEV = -2
        source.optical.enabled = false

        var target = EditParameters()
        target.layerA.exposureEV = 0.5
        target.localMasks = [LocalMask(kind: .brush)]

        let preset = EditPreset(name: "只換 Finishing",
                                sections: [.finishing], parameters: source)
        let result = preset.applied(to: target)

        XCTAssertEqual(result.finishing.finalContrast, 0.6)
        XCTAssertEqual(result.layerA.exposureEV, 0.5)
        XCTAssertEqual(result.localMasks, target.localMasks)
        XCTAssertEqual(result.optical, target.optical)
    }

    /// 光學校正綁定鏡頭，就算硬塞進 sections 也要被擋掉（INV-2）。
    func testOpticalIsNeverCarriedByAPreset() {
        var source = EditParameters()
        source.optical.enabled = false
        let preset = EditPreset(name: "全部", sections: Set(EditSection.allCases),
                                parameters: source)
        XCTAssertFalse(preset.sections.contains(.optical))

        let target = EditParameters()
        XCTAssertTrue(preset.applied(to: target).optical.enabled)
    }

    /// INV-2：遮罩與光學校正連「存進預設集檔案」都不該發生，不是只有套用時不採用。
    func testPresetFileNeverContainsMasksOrOptical() throws {
        var source = EditParameters()
        source.localMasks = [LocalMask(kind: .brush)]
        source.optical.enabled = false
        source.finishing.finalContrast = 0.6

        let preset = EditPreset(name: "全部", sections: EditPreset.defaultSections,
                                parameters: source)
        XCTAssertTrue(preset.parameters.localMasks.isEmpty)
        XCTAssertEqual(preset.parameters.optical, EditParameters.defaults.optical)
        XCTAssertEqual(preset.parameters.finishing.finalContrast, 0.6)

        // 直接解析實際寫出的 JSON：這兩個鍵必須根本不存在，不是「值被重設」。
        let url = tempDir.appendingPathComponent("Presets.json")
        try PresetLibrary(presets: [preset]).write(to: url)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let saved = (root["presets"] as! [[String: Any]])[0]
        let payload = saved["parameters"] as! [String: Any]
        XCTAssertNil(payload["localMasks"])
        XCTAssertNil(payload["optical"])
        XCTAssertNotNil(payload["finishing"])
    }

    /// 沒有勾選的區塊也不該出現在檔案裡。
    func testUnselectedSectionsAreNotWritten() throws {
        let preset = EditPreset(name: "只有 Finishing", sections: [.finishing],
                                parameters: EditParameters())
        let url = tempDir.appendingPathComponent("Presets.json")
        try PresetLibrary(presets: [preset]).write(to: url)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let payload = (root["presets"] as! [[String: Any]])[0]["parameters"] as! [String: Any]
        XCTAssertEqual(Set(payload.keys), ["finishing"])
    }

    /// 手改過、把禁止資料塞回去的檔案，載入時也要被忽略。
    func testDecodingDiscardsForbiddenData() throws {
        var dirty = EditParameters()
        dirty.localMasks = [LocalMask(kind: .gradient)]
        dirty.optical.enabled = false

        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(
            with: encoder.encode(EditPreset(name: "手改", parameters: EditParameters()))
        ) as! [String: Any]
        var payload = object["parameters"] as! [String: Any]
        let dirtyAll = try JSONSerialization.jsonObject(with: encoder.encode(dirty)) as! [String: Any]
        payload["localMasks"] = dirtyAll["localMasks"]
        payload["optical"] = dirtyAll["optical"]
        object["parameters"] = payload
        object["sections"] = EditSection.allCases.map(\.rawValue)

        let loaded = try JSONDecoder().decode(
            EditPreset.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(loaded.sections.contains(.optical))
        XCTAssertTrue(loaded.parameters.localMasks.isEmpty)
        XCTAssertEqual(loaded.parameters.optical, EditParameters.defaults.optical)
    }

    /// 縮小勾選範圍之後，被移除的區塊也要一起從內容裡消失。
    func testNarrowingSectionsDropsTheirValues() {
        var source = EditParameters()
        source.layerA.exposureEV = -2
        source.finishing.finalContrast = 0.6

        var preset = EditPreset(name: "兩區", sections: [.layerA, .finishing], parameters: source)
        preset.select([.finishing])
        XCTAssertEqual(preset.parameters.layerA, EditParameters.defaults.layerA)
        XCTAssertEqual(preset.parameters.finishing.finalContrast, 0.6)
    }

    func testDefaultSectionsCoverEverythingExceptOptical() {
        XCTAssertEqual(EditPreset.defaultSections,
                       Set(EditSection.allCases).subtracting([.optical]))
    }

    /// 驗收條件 5：預設集庫可存可讀，同名覆蓋而不是重複一筆。
    func testLibraryRoundTripAndSameNameReplaces() throws {
        let url = tempDir.appendingPathComponent("nested/Presets.json")
        XCTAssertTrue(try PresetLibrary.load(from: url).presets.isEmpty)

        var warm = EditParameters()
        warm.finishing.highlights.amount = 0.08
        var cool = EditParameters()
        cool.finishing.shadows.amount = 0.05

        var library = PresetLibrary()
        library.save(EditPreset(name: "暖", parameters: warm))
        library.save(EditPreset(name: "冷", parameters: cool))
        library.save(EditPreset(name: "暖", parameters: cool))   // 同名覆蓋
        try library.write(to: url)

        let loaded = try PresetLibrary.load(from: url)
        XCTAssertEqual(loaded.presets.count, 2)
        XCTAssertEqual(loaded.presets.map(\.name), ["暖", "冷"])
        XCTAssertEqual(loaded.presets[0].parameters, cool)
        XCTAssertEqual(loaded.formatVersion, PresetLibrary.currentFormatVersion)
    }

    func testRemoveByID() {
        var library = PresetLibrary()
        let preset = EditPreset(name: "暖", parameters: EditParameters())
        library.save(preset)
        library.remove(id: preset.id)
        XCTAssertTrue(library.presets.isEmpty)
    }
}

final class EditHistoryDefaultLimitTests: XCTestCase {
    /// A-048：預設保留 10 步編輯，另加永遠保留的「開啟」那一步。
    func testDefaultLimitIsTenSteps() {
        let history = EditHistory()
        for i in 1...15 { history.apply { $0.layerA.exposureEV = Double(i) } }
        XCTAssertEqual(history.steps.count, 11)
        XCTAssertEqual(history.steps.first?.label, EditHistory.openLabel)
        XCTAssertEqual(history.jump(to: 10)?.layerA.exposureEV, 15)
    }
}
