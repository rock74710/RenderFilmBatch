import XCTest
import simd
@testable import RFCore

final class FilmStyleTests: XCTestCase {
    func testAuthoredCatalogContainsAllSupportedStyles() throws {
        let profiles = FilmStyleCatalog.profiles
        XCTAssertEqual(Set(profiles.map(\.id)), Set(FilmStyleID.allCases))
        XCTAssertEqual(profiles.first(where: { $0.id == .cinema })?.displayName, "Cinema")
        XCTAssertEqual(profiles.first(where: { $0.id == .cinema })?.provenance,
                       "Kodak cinema negative inspired interpretation")
        XCTAssertEqual(FilmStyleID.monoSoft.rawValue, "mono-soft")
        XCTAssertEqual(FilmStyleID.everyday100.rawValue, "everyday-100")
        XCTAssertEqual(FilmStyleID.warmGold.rawValue, "warm-gold")
        XCTAssertTrue(profiles.first(where: { $0.id == .everyday100 })?.provenance.contains("not Fujifilm stock data") == true)

        XCTAssertTrue(profiles.allSatisfy { $0.version > 0 })
        let versions = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.version) })
        XCTAssertEqual(versions[.none], 1)
        XCTAssertEqual(versions[.monoSoft], 1)
        XCTAssertEqual(versions[.monoHard], 1)
        XCTAssertEqual(versions[.cinema], 2)
        XCTAssertEqual(versions[.everyday100], 2)
        XCTAssertEqual(versions[.warmGold], 2)
    }

    func testCatalogRejectsInvalidProfileValues() throws {
        let invalidFields: [[String: Any]] = [
            ["chromaRollOff": 4.0],
            ["hueShifts": [0.0]],
            ["chromaByLightness": [1.0]],
            ["chromaByLightness": [1.0, 1.0, 0.49, 1.0, 1.0]],
            ["chromaByLightness": [1.0, 1.0, 2.01, 1.0, 1.0]],
            ["skinProtection": 1.1],
            ["midtoneA": 0.051],
            ["midtoneB": -0.051],
            ["skinTintProtection": 1.1],
            ["skinTintProtection": -0.1],
            ["monoWeights": [0.0, 0.0, 0.0]],
        ]
        for invalid in invalidFields {
            var profile = profileRecord()
            profile.merge(invalid) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: profile)
            XCTAssertThrowsError(
                try JSONDecoder().decode(FilmStyleProfile.self, from: data),
                "invalid fields: \(invalid.keys)"
            )
        }
    }

    func testLegacyProfileDefaultsChromaByLightnessAndReencodesSnapshot() throws {
        let profile = try JSONDecoder().decode(
            FilmStyleProfile.self,
            from: JSONSerialization.data(withJSONObject: legacyProfileRecord())
        )
        let encoded = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["chromaByLightness"] as? [Double], [1, 1, 1, 1, 1])
    }

    func testProfileRejectsNonFiniteChromaByLightnessValues() throws {
        var record = profileRecord()
        record["chromaByLightness"] = [1.0, 1.0, Double.nan, 1.0, 1.0]
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        XCTAssertThrowsError(try PropertyListDecoder().decode(FilmStyleProfile.self, from: data))
    }

    func testStyleSelectionStoresVersionedSnapshotAndRoundTrips() throws {
        var parameters = EditParameters()
        parameters.applyFilmStyle(.warmGold)
        parameters.film.amount = 0.63

        XCTAssertEqual(parameters.film.styleID, .warmGold)
        XCTAssertEqual(parameters.film.profileSnapshot.id, .warmGold)
        XCTAssertEqual(parameters.film.profileSnapshot.version, 2)

        let data = try JSONEncoder().encode(parameters)
        let decoded = try JSONDecoder().decode(EditParameters.self, from: data)
        XCTAssertEqual(decoded, parameters)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let film = try XCTUnwrap(object["film"] as? [String: Any])
        let snapshot = try XCTUnwrap(film["profileSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["version"] as? Int, parameters.film.profileVersion)
        XCTAssertEqual(snapshot["midtoneA"] as? Double, 0.004)
        XCTAssertEqual(snapshot["midtoneB"] as? Double, 0.012)
        XCTAssertEqual(snapshot["skinTintProtection"] as? Double, 0.35)
    }

    func testLegacySidecarDefaultsToNeutralFilmParameters() throws {
        let encoded = try JSONEncoder().encode(EditParameters())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "film")

        let decoded = try JSONDecoder().decode(
            EditParameters.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.film.styleID, .none)
        XCTAssertTrue(decoded.film.isNeutral)
    }

    func testSelectedStyleWithoutItsSavedSnapshotIsRejected() throws {
        var parameters = EditParameters()
        parameters.applyFilmStyle(.cinema)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any]
        )
        var film = try XCTUnwrap(object["film"] as? [String: Any])
        film.removeValue(forKey: "profileSnapshot")
        object["film"] = film

        XCTAssertThrowsError(try JSONDecoder().decode(
            EditParameters.self, from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testFilmAmountIsFiniteAndClamped() {
        var film = FilmParameters()
        film.amount = 4
        XCTAssertEqual(film.amount, 1)
        film.amount = -2
        XCTAssertEqual(film.amount, 0)
        film.amount = .infinity
        XCTAssertEqual(film.amount, 0)
        film.amount = .nan
        XCTAssertEqual(film.amount, 0)
    }

    func testNoneAndZeroAmountAreExactTransformBypasses() {
        let input = SIMD3<Double>(0.72, 0.23, 0.11)
        let none = FilmParameters()
        let scene = SceneTransform(layerA: LayerATechnical(), colorEngine: ColorEngineParameters(), film: none)
        let baseline = SceneTransform(layerA: LayerATechnical(), colorEngine: ColorEngineParameters())
        XCTAssertEqual(scene.apply(input), baseline.apply(input))

        var zeroEdit = EditParameters()
        zeroEdit.applyFilmStyle(.cinema)
        zeroEdit.film.amount = 0
        let zero = zeroEdit.film
        let selectedButZero = SceneTransform(
            layerA: LayerATechnical(), colorEngine: ColorEngineParameters(), film: zero
        )
        XCTAssertEqual(selectedButZero.apply(input), baseline.apply(input))

        let target = RenderingTarget()
        let baselineTarget = TargetTransform(
            target: target, tone: ToneMappingParameters(), gamut: GamutMappingParameters()
        )
        let filmTarget = TargetTransform(
            target: target, tone: ToneMappingParameters(), gamut: GamutMappingParameters(), film: zero
        )
        XCTAssertEqual(filmTarget.targetLinear(input), baselineTarget.targetLinear(input))
    }

    func testColorLooksChangeColorBeforeCreativeColorEngineButMonoIsLate() {
        let input = SIMD3<Double>(0.72, 0.24, 0.10)
        var colorParameters = EditParameters()
        colorParameters.applyFilmStyle(.cinema)
        let color = colorParameters.film
        let colorScene = SceneTransform(
            layerA: LayerATechnical(), colorEngine: ColorEngineParameters(), film: color
        )
        let neutralScene = SceneTransform(layerA: LayerATechnical(), colorEngine: ColorEngineParameters())
        XCTAssertNotEqual(colorScene.apply(input), neutralScene.apply(input))

        var monoParameters = EditParameters()
        monoParameters.applyFilmStyle(.monoSoft)
        let mono = monoParameters.film
        let monoScene = SceneTransform(
            layerA: LayerATechnical(), colorEngine: ColorEngineParameters(), film: mono
        )
        XCTAssertEqual(monoScene.apply(input), neutralScene.apply(input))

        let monoTarget = TargetTransform(
            target: RenderingTarget(), tone: ToneMappingParameters(),
            gamut: GamutMappingParameters(), film: mono
        ).targetLinear(neutralScene.apply(input))
        XCTAssertEqual(monoTarget.x, monoTarget.y, accuracy: 1e-5)
        XCTAssertEqual(monoTarget.y, monoTarget.z, accuracy: 1e-5)
    }

    func testWarmGoldAddsWarmTintToMiddleGrayAtFullAmount() {
        var parameters = EditParameters()
        parameters.applyFilmStyle(.warmGold)

        let warmGray = parameters.film.applyingColor(to: SIMD3(0.565, 0, 0))
        XCTAssertGreaterThan(warmGray.y * sin(warmGray.z * .pi / 180), 0.008)

        parameters.film.amount = 0
        XCTAssertEqual(parameters.film.applyingColor(to: SIMD3(0.565, 0, 0)), SIMD3(0.565, 0, 0))
    }

    func testLegacyV1SnapshotKeepsItsColorTransformAndVersion() throws {
        let legacyRecord = legacyProfileRecord()
        let profileData = try JSONSerialization.data(withJSONObject: legacyRecord)
        let profile = try JSONDecoder().decode(FilmStyleProfile.self, from: profileData)
        XCTAssertEqual(profile.version, 1)
        XCTAssertEqual(profile.midtoneA, 0)
        XCTAssertEqual(profile.midtoneB, 0)
        XCTAssertEqual(profile.skinTintProtection, profile.skinProtection)

        let amount = 0.63
        let filmData = try JSONSerialization.data(withJSONObject: [
            "enabled": true,
            "styleID": "cinema",
            "amount": amount,
            "profileSnapshot": legacyRecord,
        ])
        let film = try JSONDecoder().decode(FilmParameters.self, from: filmData)
        let samples = [SIMD3(0.58, 0.16, 45), SIMD3(0.27, 0.12, 205),
                       SIMD3(0.72, 0.09, 310), SIMD3(0.565, 0, 0)]
        for sample in samples {
            let expected = legacyApplyingColor(profile: profile, amount: amount, input: sample)
            let actual = film.applyingColor(to: sample)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12)
            XCTAssertEqual(actual.z, expected.z, accuracy: 1e-12)
        }

        let encoded = try JSONEncoder().encode(film)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let snapshot = try XCTUnwrap(object["profileSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["version"] as? Int, 1)
    }

    func testProfileChromaByLightnessExpandsShadowsAndCalmsMidtonesAndHighlights() throws {
        var styledRecord = profileRecord()
        styledRecord["id"] = FilmStyleID.classicCinema.rawValue
        styledRecord["displayName"] = "Test Classic Cinema"
        styledRecord["chromaByLightness"] = [1.5, 1.2, 0.95, 0.8, 0.65]
        var neutralRecord = styledRecord
        neutralRecord["chromaByLightness"] = [1.0, 1.0, 1.0, 1.0, 1.0]
        let styledProfile = try JSONDecoder().decode(
            FilmStyleProfile.self, from: JSONSerialization.data(withJSONObject: styledRecord)
        )
        let neutralProfile = try JSONDecoder().decode(
            FilmStyleProfile.self, from: JSONSerialization.data(withJSONObject: neutralRecord)
        )
        let styled = try film(for: styledProfile)
        let neutral = try film(for: neutralProfile)
        let nodes = ColorEngineParameters.lightnessNodes

        let dark = SIMD3(nodes[0], 0.08, 150.0)
        let middle = SIMD3(nodes[2], 0.08, 150.0)
        let highlight = SIMD3(nodes[4], 0.08, 150.0)
        XCTAssertGreaterThan(styled.applyingColor(to: dark).y, neutral.applyingColor(to: dark).y)
        XCTAssertLessThan(styled.applyingColor(to: middle).y, neutral.applyingColor(to: middle).y)
        XCTAssertLessThan(styled.applyingColor(to: highlight).y, neutral.applyingColor(to: highlight).y)

        let gray = SIMD3(nodes[0], 0.0, 0.0)
        XCTAssertEqual(styled.applyingColor(to: gray), gray, "chroma response must not tint neutral gray")
    }

    func testProfileChromaByLightnessHonorsAmountAndExactZeroBypass() throws {
        var record = profileRecord()
        record["id"] = FilmStyleID.classicCinema.rawValue
        record["displayName"] = "Test Classic Cinema"
        record["chromaByLightness"] = [1.5, 1.2, 0.95, 0.8, 0.65]
        let profile = try JSONDecoder().decode(
            FilmStyleProfile.self, from: JSONSerialization.data(withJSONObject: record)
        )
        let input = SIMD3(ColorEngineParameters.lightnessNodes[0], 0.08, 150.0)
        let zero = try film(for: profile, amount: 0)
        let partial = try film(for: profile, amount: 0.4)
        let full = try film(for: profile, amount: 1)

        XCTAssertEqual(zero.applyingColor(to: input), input)
        XCTAssertEqual(partial.applyingColor(to: input).y, input.y * 1.2, accuracy: 1e-12)
        XCTAssertEqual(full.applyingColor(to: input).y, input.y * 1.5, accuracy: 1e-12)
    }

    func testColorStylesHaveObservableSoftOrWarmMiddleToneResponse() {
        let target = RenderingTarget()
        let tone = ToneMappingParameters()
        let gamut = GamutMappingParameters()
        let neutral = TargetTransform(target: target, tone: tone, gamut: gamut)
        let neutralLow = neutral.toneCurve(0.30)
        let neutralMiddleTone = neutral.toneCurve(0.45)
        let neutralHigh = neutral.toneCurve(0.65)

        for style in [FilmStyleID.cinema, .everyday100] {
            var parameters = EditParameters()
            parameters.applyFilmStyle(style)
            let transform = TargetTransform(
                target: target, tone: parameters.toneMapping,
                gamut: parameters.gamutMapping, film: parameters.film
            )
            XCTAssertGreaterThan(transform.toneCurve(0.30), neutralLow, "\(style) should open low tones")
            XCTAssertLessThan(transform.toneCurve(0.65), neutralHigh, "\(style) should soften upper midtones")
            XCTAssertGreaterThan(
                abs(transform.toneCurve(0.45) - neutralMiddleTone), 0.01,
                "\(style) should have an observable middle-tone change"
            )
        }

        var warmGold = EditParameters()
        warmGold.applyFilmStyle(.warmGold)
        let goldTransform = TargetTransform(
            target: target, tone: warmGold.toneMapping,
            gamut: warmGold.gamutMapping, film: warmGold.film
        )
        XCTAssertLessThan(goldTransform.toneCurve(0.30), neutralLow, "Gold should deepen low tones")
        XCTAssertGreaterThan(goldTransform.toneCurve(0.65), neutralHigh, "Gold should strengthen upper midtones")
        XCTAssertGreaterThan(
            abs(goldTransform.toneCurve(0.65) - neutralHigh), 0.01,
            "Gold should have an observable upper mid-tone change"
        )
    }

    func testClassicCinemaIsArriInspiredWithLongShoulderAndCalmerCyanBlue() {
        let profile = FilmStyleCatalog.profile(for: .classicCinema)
        XCTAssertEqual(FilmStyleID.classicCinema.rawValue, "classic-cinema")
        XCTAssertEqual(profile.displayName, "Classic Cinema")
        XCTAssertEqual(profile.version, 2)
        XCTAssertTrue(profile.provenance.contains("ARRI"))

        let target = RenderingTarget()
        let neutral = TargetTransform(target: target, tone: ToneMappingParameters(), gamut: GamutMappingParameters())
        var parameters = EditParameters()
        parameters.applyFilmStyle(.classicCinema)
        let styled = TargetTransform(
            target: target, tone: parameters.toneMapping,
            gamut: parameters.gamutMapping, film: parameters.film
        )
        XCTAssertLessThan(styled.toneCurve(0.95), neutral.toneCurve(0.95), "longer highlight shoulder")
        XCTAssertLessThan(
            SceneTransform.hueCurve(profile.chromaBands, hue: 240),
            SceneTransform.hueCurve(profile.chromaBands, hue: 60),
            "cyan-blue calmer than warm colors"
        )
    }

    func testWarmGoldAppliesReducedTintToSkinWhileRetainingHueProtection() throws {
        let profile = FilmStyleCatalog.profile(for: .warmGold)
        let input = SIMD3(0.565, 0.15, 45)
        var unprotected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        )
        unprotected["skinTintProtection"] = 0.0
        let unprotectedProfile = try JSONDecoder().decode(
            FilmStyleProfile.self, from: JSONSerialization.data(withJSONObject: unprotected)
        )

        let protectedOutput = try film(for: profile).applyingColor(to: input)
        let unprotectedOutput = try film(for: unprotectedProfile).applyingColor(to: input)
        let protectedAB = ab(from: protectedOutput)
        let unprotectedAB = ab(from: unprotectedOutput)
        let tintDifference = hypot(unprotectedAB.x - protectedAB.x, unprotectedAB.y - protectedAB.y)
        let expectedDifference = profile.skinTintProtection * hypot(profile.midtoneA, profile.midtoneB)

        XCTAssertGreaterThan(profile.skinProtection, 0.5)
        XCTAssertEqual(profile.skinTintProtection, 0.35, accuracy: 1e-12)
        XCTAssertEqual(tintDifference, expectedDifference, accuracy: 1e-10)
        XCTAssertLessThan(abs(hueDelta(protectedOutput.z, input.z)), 4)
    }

    func testMonochromeProfilesUseDifferentColorResponses() {
        func gray(for id: FilmStyleID, input: SIMD3<Double>) -> Double {
            var parameters = EditParameters()
            parameters.applyFilmStyle(id)
            let target = TargetTransform(
                target: RenderingTarget(), tone: parameters.toneMapping,
                gamut: parameters.gamutMapping, film: parameters.film
            )
            let mapped = target.targetLinear(input)
            return (mapped.x + mapped.y + mapped.z) / 3
        }

        let red = SIMD3<Double>(0.8, 0.03, 0.02)
        let blue = SIMD3<Double>(0.02, 0.04, 0.8)
        let softRed = gray(for: .monoSoft, input: red)
        let softBlue = gray(for: .monoSoft, input: blue)
        let hardRed = gray(for: .monoHard, input: red)
        let hardBlue = gray(for: .monoHard, input: blue)
        XCTAssertNotEqual(softRed, hardRed, accuracy: 1e-4)
        XCTAssertNotEqual(softBlue, hardBlue, accuracy: 1e-4)
    }

    func testFilmToneModulatesCurrentUserToneControlsWithoutChangingThem() {
        var parameters = EditParameters()
        parameters.toneMapping.midtoneContrast = 1.3
        parameters.toneMapping.shadowShaping = 0.15
        parameters.applyFilmStyle(.cinema)
        parameters.film.amount = 0.5
        let storedTone = parameters.toneMapping

        let withFilm = TargetTransform(
            target: parameters.target, tone: parameters.toneMapping,
            gamut: parameters.gamutMapping, film: parameters.film
        )
        let withoutFilm = TargetTransform(
            target: parameters.target, tone: parameters.toneMapping,
            gamut: parameters.gamutMapping
        )

        XCTAssertNotEqual(withFilm.toneCurve(0.35), withoutFilm.toneCurve(0.35), accuracy: 1e-5)
        XCTAssertEqual(parameters.toneMapping, storedTone)
    }

    func testEverydayResponseIsHueDependentAndProtectsSkin() {
        var parameters = EditParameters()
        parameters.colorEngine.enabled = false
        parameters.applyFilmStyle(.everyday100)
        let film = SceneTransform(
            layerA: parameters.layerA, colorEngine: parameters.colorEngine, film: parameters.film
        )
        let neutral = SceneTransform(layerA: parameters.layerA, colorEngine: parameters.colorEngine)
        let greenInput = rgb(from: SIMD3(0.58, 0.16, 150))
        let skinInput = rgb(from: SIMD3(0.58, 0.15, 45))
        let redInput = rgb(from: SIMD3(0.58, 0.16, 0))
        let blueInput = rgb(from: SIMD3(0.58, 0.16, 240))

        let greenBefore = lch(from: neutral.apply(greenInput))
        let greenAfter = lch(from: film.apply(greenInput))
        let skinBefore = lch(from: neutral.apply(skinInput))
        let skinAfter = lch(from: film.apply(skinInput))
        let redBefore = lch(from: neutral.apply(redInput))
        let redAfter = lch(from: film.apply(redInput))
        let blueBefore = lch(from: neutral.apply(blueInput))
        let blueAfter = lch(from: film.apply(blueInput))

        let greenShift = abs(hueDelta(greenAfter.z, greenBefore.z))
        let skinShift = abs(hueDelta(skinAfter.z, skinBefore.z))
        XCTAssertGreaterThan(greenShift, 5, "green response should move toward cyan")
        XCTAssertLessThan(skinShift, greenShift * 0.25, "orange skin should be protected")
        XCTAssertLessThan(redAfter.y / redBefore.y, greenAfter.y / greenBefore.y)
        XCTAssertLessThan(blueAfter.y / blueBefore.y, greenAfter.y / greenBefore.y)
    }

    func testUserChromaZeroRemovesFilmColorBeforeUserCreativeControl() {
        var parameters = EditParameters()
        parameters.colorEngine.enabled = false
        parameters.layerA.chroma = 0
        parameters.applyFilmStyle(.everyday100)
        let withFilm = SceneTransform(
            layerA: parameters.layerA, colorEngine: parameters.colorEngine, film: parameters.film
        )
        let withoutFilm = SceneTransform(layerA: parameters.layerA, colorEngine: parameters.colorEngine)
        let input = rgb(from: SIMD3(0.58, 0.16, 150))
        XCTAssertEqual(withFilm.apply(input), withoutFilm.apply(input))
    }

    func testNearNeutralInputsApproachTheSameTintedGray() {
        var parameters = EditParameters()
        parameters.colorEngine.enabled = false
        parameters.applyFilmStyle(.everyday100)
        let scene = SceneTransform(
            layerA: parameters.layerA, colorEngine: parameters.colorEngine, film: parameters.film
        )
        let outputs = [25.0, 80.0, 150.0, 260.0].map { hue in
            scene.apply(rgb(from: SIMD3(0.5, 1e-6, hue)))
        }
        let reference = outputs[0]
        XCTAssertTrue(outputs.dropFirst().allSatisfy { simd_length($0 - reference) < 5e-6 })
    }

    func testToneIsMonotonicAndTransformsStayFiniteAcrossRanges() {
        let grayLevels: [Double] = [0, 1e-6, 1e-5, 1e-4, 1e-3, 0.01, 0.05, 0.18,
                                    0.5, 1, 1.5, 2, 4, 8, 16, 32]
        let samples = [SIMD3<Double>(-2, -0.01, 0.2), .zero,
                       SIMD3(0.4, 0.2, 0.1), SIMD3(2, 8, 32), SIMD3(-0.2, 1.5, 4)]

        for style in FilmStyleID.allCases {
            var parameters = EditParameters()
            parameters.colorEngine.enabled = false
            parameters.applyFilmStyle(style)
            let scene = SceneTransform(
                layerA: parameters.layerA, colorEngine: parameters.colorEngine, film: parameters.film
            )
            for range in [RenderingTarget.DynamicRange.sdr, .fullHDR] {
                let target = RenderingTarget(
                    dynamicRange: range, gamut: .rec2020, transferFunction: .linear,
                    contentPeakNits: 203 * 32
                )
                var noGamut = GamutMappingParameters()
                noGamut.enabled = false
                let transform = TargetTransform(
                    target: target, tone: parameters.toneMapping,
                    gamut: noGamut, film: parameters.film
                )
                var previousLightness = -Double.infinity
                for value in grayLevels {
                    let source = SIMD3(repeating: value)
                    let working = scene.apply(source)
                    let mapped = transform.targetLinear(working, applyGamutMapping: false)
                    let mappedLab = OKLab.fromXYZ(target.gamut.colorSpace.toXYZ(mapped))
                    XCTAssertTrue(mapped.x.isFinite && mapped.y.isFinite && mapped.z.isFinite,
                                  "nonfinite gray output for \(style), \(range), \(value)")
                    XCTAssertGreaterThanOrEqual(mappedLab.x, previousLightness - 1e-10,
                                                 "tone must stay monotonic for \(style), \(range)")
                    previousLightness = mappedLab.x
                }
                for sample in samples {
                    let mapped = transform.targetLinear(scene.apply(sample), applyGamutMapping: false)
                    XCTAssertTrue(mapped.x.isFinite && mapped.y.isFinite && mapped.z.isFinite,
                                  "nonfinite RGB output for \(style), \(range), \(sample)")
                }
            }
        }
    }

    func testHDRFilmRenderingRetainsHighlightsAboveReferenceWhite() {
        var parameters = EditParameters()
        parameters.colorEngine.enabled = false
        parameters.applyFilmStyle(.cinema)
        let scene = SceneTransform(
            layerA: parameters.layerA, colorEngine: parameters.colorEngine, film: parameters.film
        )
        let target = TargetTransform(
            target: RenderingTarget(
                dynamicRange: .fullHDR, gamut: .rec2020, transferFunction: .linear,
                contentPeakNits: 203 * 8
            ),
            tone: parameters.toneMapping,
            gamut: {
                var value = GamutMappingParameters()
                value.enabled = false
                return value
            }(),
            film: parameters.film
        )
        XCTAssertGreaterThan(target.targetLinear(scene.apply(SIMD3(repeating: 4))).max(), 1)
    }

    private func film(for profile: FilmStyleProfile, amount: Double = 1) throws -> FilmParameters {
        let profileObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        )
        let object: [String: Any] = [
            "enabled": true,
            "styleID": profile.id.rawValue,
            "amount": amount,
            "profileSnapshot": profileObject,
        ]
        return try JSONDecoder().decode(
            FilmParameters.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func ab(from lch: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(lch.y * cos(lch.z * .pi / 180), lch.y * sin(lch.z * .pi / 180))
    }

    private func legacyProfileRecord() -> [String: Any] {
        [
            "id": "cinema", "version": 1, "displayName": "Cinema v1", "provenance": "legacy test",
            "chromaRollOff": 0.50,
            "hueShifts": [0, -1, -3, -2, 0, 1, 1, 0, -2, -1, 0, 0],
            "chromaBands": [0.94, 0.98, 1.0, 1.0, 1.0, 1.0, 0.98, 0.95, 0.88, 0.90, 0.94, 0.96],
            "shadowA": -0.008, "shadowB": -0.012, "highlightA": 0.008, "highlightB": 0.014,
            "midtoneContrastScale": 0.97, "shadowShapingOffset": 0.04,
            "highlightRollOffOffset": 0.09, "skinProtection": 0.70,
            "monoWeights": [0.2627, 0.6780, 0.0593],
        ]
    }

    private func legacyApplyingColor(
        profile: FilmStyleProfile,
        amount: Double,
        input: SIMD3<Double>
    ) -> SIMD3<Double> {
        var lch = input
        let sourceHue = lch.z
        let c = max(lch.y, 0)
        let relativeChroma = c / max(lch.x, 0.25)
        let chromaGate = smoothstep(0.01, 0.04, relativeChroma)
        let skinWeight = SceneTransform.skinWeight(hue: sourceHue) * chromaGate
        let colorAllowance = 1 - skinWeight * profile.skinProtection
        let hueShift = SceneTransform.hueCurve(profile.hueShifts, hue: sourceHue)
        let chromaBand = SceneTransform.hueCurve(profile.chromaBands, hue: sourceHue)
        if profile.chromaRollOff != 0, c > 0 {
            let saturationWeight = relativeChroma / (relativeChroma + 0.20)
            lch.y *= 1 - amount * profile.chromaRollOff * colorAllowance * saturationWeight
        }
        if hueShift != 0 {
            lch.z = (lch.z + hueShift * amount * colorAllowance).truncatingRemainder(dividingBy: 360)
            if lch.z < 0 { lch.z += 360 }
        }
        if chromaBand != 1 {
            lch.y *= 1 + (chromaBand - 1) * amount * colorAllowance
        }

        let shadowWeight = 1 - smoothstep(0.08, 0.55, lch.x)
        let highlightWeight = smoothstep(0.62, 1.15, lch.x)
        let a = lch.y * cos(lch.z * .pi / 180)
            + amount * colorAllowance * (profile.shadowA * shadowWeight + profile.highlightA * highlightWeight)
        let b = lch.y * sin(lch.z * .pi / 180)
            + amount * colorAllowance * (profile.shadowB * shadowWeight + profile.highlightB * highlightWeight)
        lch.y = hypot(a, b)
        if lch.y > 1e-12 {
            lch.z = atan2(b, a) * 180 / .pi
            if lch.z < 0 { lch.z += 360 }
        }
        return lch
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func profileRecord() -> [String: Any] {
        [
            "id": "none", "version": 1, "displayName": "None", "provenance": "test",
            "chromaRollOff": 0.0,
            "hueShifts": [Double](repeating: 0, count: 12),
            "chromaBands": [Double](repeating: 1, count: 12),
            "shadowA": 0.0, "shadowB": 0.0, "highlightA": 0.0, "highlightB": 0.0,
            "midtoneContrastScale": 1.0, "shadowShapingOffset": 0.0,
            "highlightRollOffOffset": 0.0, "skinProtection": 0.0,
            "monoWeights": [0.2627, 0.6780, 0.0593],
        ]
    }

    private func rgb(from lch: SIMD3<Double>) -> SIMD3<Double> {
        RGBColorSpace.workingRec2020.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(lch)))
    }

    private func lch(from rgb: SIMD3<Double>) -> SIMD3<Double> {
        OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(rgb)))
    }
}
