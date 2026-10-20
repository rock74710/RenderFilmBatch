import XCTest
@testable import RFCore

final class ColorBasisTests: XCTestCase {
    func testChoicesContainEachBaseExactlyOnce() {
        XCTAssertEqual(ColorBasis.allCases.count, 9)
        XCTAssertEqual(Set(ColorBasis.allCases).count, 9)
        XCTAssertFalse(ColorBasis.allCases.contains(.film(.none)))
        XCTAssertFalse(ColorBasis.allCases.contains(.existing))
    }

    func testSwitchingBasesIsExclusiveAndUsesFullFilmStrength() {
        var p = EditParameters()
        p.applyProfile(.chromeLike)
        p.applyFilmStyle(.cinema)
        p.film.enabled = false
        p.film.amount = 0.3
        p.colorEngine.enabled = false
        p.applyColorBasis(.film(.warmGold))
        XCTAssertEqual(p.colorBasis, .film(.warmGold))
        XCTAssertEqual(p.colorEngine.profile, .natural)
        XCTAssertTrue(p.matchesProfileDefaults)
        XCTAssertTrue(p.colorEngine.enabled)
        XCTAssertTrue(p.film.enabled)
        XCTAssertEqual(p.film.amount, 1)
        p.applyColorBasis(.profile(.negLike))
        XCTAssertEqual(p.colorBasis, .profile(.negLike))
        XCTAssertTrue(p.film.isNeutral)
        XCTAssertTrue(p.matchesProfileDefaults)
        p.applyColorBasis(.profile(.natural))
        XCTAssertEqual(p.film, FilmParameters())
    }

    func testAllChoicesRoundtripWithoutNewPersistenceFields() throws {
        for basis in ColorBasis.allCases {
            var p = EditParameters()
            p.applyColorBasis(basis)
            let data = try JSONEncoder().encode(p)
            let restored = try JSONDecoder().decode(EditParameters.self, from: data)
            XCTAssertEqual(restored, p)
            XCTAssertEqual(restored.colorBasis, basis)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["colorBasis"])
        }
    }

    func testLegacyMixedOrPartialFilmIsPreservedUntilExplicitSelection() throws {
        var p = EditParameters()
        p.applyProfile(.chromeLike)
        p.applyFilmStyle(.cinema)
        p.film.amount = 0.65
        let restored = try JSONDecoder().decode(EditParameters.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored, p)
        XCTAssertEqual(restored.colorBasis, .existing)
        p.applyColorBasis(.existing)
        XCTAssertEqual(p, restored)
        p.applyProfile(.natural)
        XCTAssertEqual(p.colorBasis, .existing)
        p.film.amount = 1
        XCTAssertEqual(p.colorBasis, .film(.cinema))
        p.film.enabled = false
        XCTAssertEqual(p.colorBasis, .existing)
        p.film.amount = 0
        XCTAssertEqual(p.colorBasis, .existing)
    }

    func testSelectionPreservesTechnicalAndCreativeAdjustments() {
        var p = EditParameters()
        p.layerA.exposureEV = 0.7
        p.layerA.temperature = 5800
        p.colorEngine.chromaStrength = 0.8
        p.colorMixer.bands[0].hueShift = 4
        p.finishing.finalContrast = 0.2
        p.spatial.grain.amount = 0.3
        let before = p
        p.applyColorBasis(.film(.monoHard))
        XCTAssertEqual(p.layerA, before.layerA)
        XCTAssertEqual(p.colorEngine.chromaStrength, before.colorEngine.chromaStrength)
        XCTAssertEqual(p.colorMixer, before.colorMixer)
        XCTAssertEqual(p.finishing, before.finishing)
        XCTAssertEqual(p.spatial, before.spatial)
        XCTAssertEqual(p.optical, before.optical)
        XCTAssertEqual(p.target, before.target)
        XCTAssertEqual(p.localMasks, before.localMasks)
    }

    func testFilmBasesRetainTheExistingSceneAndTargetAlgorithms() {
        for style in FilmStyleID.allCases where style != .none {
            var p = EditParameters()
            p.applyColorBasis(.film(style))
            var reference = EditParameters()
            reference.applyProfile(.natural)
            reference.applyFilmStyle(style)
            let input = SIMD3<Double>(1.8, 0.6, 0.2)
            let scene = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine, film: p.film)
            let referenceScene = SceneTransform(layerA: reference.layerA,
                                                colorEngine: reference.colorEngine, film: reference.film)
            XCTAssertEqual(scene.apply(input), referenceScene.apply(input))
            for target in [RenderingTarget.preset(.appleSDR),
                           RenderingTarget.hdrExport(transfer: .pq, referenceWhiteNits: 203,
                                                     contentPeakNits: 1000)] {
                let transform = TargetTransform(target: target, tone: p.toneMapping,
                                                gamut: p.gamutMapping, film: p.film)
                let referenceTransform = TargetTransform(target: target, tone: reference.toneMapping,
                                                         gamut: reference.gamutMapping, film: reference.film)
                XCTAssertEqual(transform.apply(scene.apply(input)),
                               referenceTransform.apply(referenceScene.apply(input)))
            }
        }
    }

    func testHistoryRestoresTheEntireBaseSelection() {
        var p = EditParameters()
        p.applyColorBasis(.profile(.chromeLike))
        let history = EditHistory()
        history.reset(to: p)
        history.apply { $0.applyColorBasis(.film(.monoSoft)) }
        XCTAssertEqual(history.current.colorBasis, .film(.monoSoft))
        XCTAssertEqual(history.jump(to: 0), p)
    }

    func testBatchSelectionReachesSharedPreparationAndPreservesLegacySettings() async throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let image = CIImage(color: CIColor(red: 0.5, green: 0.1, blue: 0.04))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let decoded = DecodedRaw(url: URL(fileURLWithPath: "/synthetic.dng"), image: image,
                                 metadata: RawMetadata(), fullSize: image.extent.size,
                                 colorSpace: gpu.workingColorSpace)
        var settings = BatchExportSettings()
        settings.profile = .chromeLike
        for basis in ColorBasis.allCases {
            settings.applyColorBasis(basis)
            let prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                                      exposureEV: nil, maxDimension: 8)
            XCTAssertEqual(prepared.parameters.colorBasis, basis)
            XCTAssertEqual(prepared.parameters.film, settings.film)
            XCTAssertEqual(prepared.parameters.colorEngine.profile, settings.profile)
        }
        settings.profile = .negLike
        var p = EditParameters()
        p.applyFilmStyle(.cinema)
        p.film.amount = 0.4
        settings.film = p.film
        let prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                                  exposureEV: nil, maxDimension: 8)
        XCTAssertEqual(prepared.parameters.colorBasis, .existing)
        XCTAssertEqual(prepared.parameters.film, settings.film)
        XCTAssertEqual(prepared.parameters.colorEngine.profile, .negLike)
    }
}
