import XCTest
@testable import RFCore

final class FilmWorkflowTests: XCTestCase {
    func testHistoryCanRestoreFilmWithoutChangingExposure() {
        var initial = EditParameters()
        initial.layerA.exposureEV = 0.4
        let history = EditHistory()
        history.reset(to: initial)
        history.apply { $0.applyFilmStyle(.cinema) }
        XCTAssertEqual(history.steps.last?.label, EditSection.film.displayName)
        XCTAssertEqual(history.current.film.styleID, .cinema)
        let restored = history.jump(to: 0)
        XCTAssertEqual(restored?.film, initial.film)
        XCTAssertEqual(restored?.layerA.exposureEV, 0.4)
    }

    func testSelectingFilmPreservesUserEditing() {
        var p = EditParameters()
        p.layerA.exposureEV = 0.7
        p.layerA.chroma = 1.1
        p.colorEngine.chromaStrength = 0.8
        p.colorMixer.bands[0].hueShift = 4
        p.toneMapping.midtoneContrast = 1.2
        p.finishing.finalContrast = 0.2
        p.spatial.grain.amount = 0.3
        let before = p
        p.applyFilmStyle(.cinema)
        XCTAssertEqual(p.changedSections(from: before), [.film])
        p.applyFilmStyle(.monoHard)
        XCTAssertEqual(p.layerA, before.layerA)
        XCTAssertEqual(p.colorEngine, before.colorEngine)
        XCTAssertEqual(p.colorMixer, before.colorMixer)
        XCTAssertEqual(p.toneMapping, before.toneMapping)
        XCTAssertEqual(p.finishing, before.finishing)
        XCTAssertEqual(p.spatial, before.spatial)
    }

    func testFilmResetAndDisableOnlyAffectFilm() {
        var p = EditParameters()
        p.layerA.exposureEV = 1
        p.applyFilmStyle(.everyday100)
        p.film.enabled = false
        XCTAssertEqual(p.effective.film, EditParameters.defaults.film)
        XCTAssertEqual(p.effective.layerA, p.layerA)
        XCTAssertEqual(p.film.styleID, .everyday100)
        p.reset(.film)
        XCTAssertTrue(p.isDefault(.film))
        XCTAssertEqual(p.layerA.exposureEV, 1)
    }

    func testFilmPresetRoundtripAndSelectiveApplication() throws {
        var source = EditParameters()
        source.applyFilmStyle(.warmGold)
        source.film.amount = 0.65
        source.layerA.exposureEV = 2
        let preset = EditPreset(name: "暖色", sections: [.film], parameters: source)
        let decoded = try JSONDecoder().decode(EditPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(decoded.parameters.film, source.film)
        var target = EditParameters()
        target.layerA.exposureEV = -0.4
        target.spatial.grain.amount = 0.2
        target.adopt(decoded.sections, from: decoded.parameters)
        XCTAssertEqual(target.film, source.film)
        XCTAssertEqual(target.layerA.exposureEV, -0.4)
        XCTAssertEqual(target.spatial.grain.amount, 0.2)
        let excluded = EditPreset(name: "曝光", sections: [.layerA], parameters: source)
        XCTAssertEqual(excluded.parameters.film, EditParameters.defaults.film)
    }

    func testFilmSnapshotDoesNotChangeAfterOtherSectionsAreAdopted() throws {
        var target = EditParameters()
        target.applyFilmStyle(.monoSoft)
        let snapshot = target.film
        var source = EditParameters()
        source.layerA.exposureEV = 0.5
        source.applyFilmStyle(.cinema)
        target.adopt([.layerA], from: source)
        XCTAssertEqual(target.film, snapshot)
        let restored = try JSONDecoder().decode(EditParameters.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(restored.film, snapshot)
    }
}
