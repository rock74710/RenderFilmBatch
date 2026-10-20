import XCTest
import simd
@testable import RFCore

final class ColorMixerTests: XCTestCase {
    private static let namedSRGBColors: [(name: String, value: SIMD3<Double>, band: ColorMixerBand)] = [
        ("red", SIMD3(255, 0, 0), .red),
        ("orange", SIMD3(255, 128, 0), .orange),
        ("yellow", SIMD3(255, 255, 0), .yellow),
        ("green", SIMD3(0, 255, 0), .green),
        ("aqua", SIMD3(0, 255, 255), .aqua),
        ("blue", SIMD3(0, 0, 255), .blue),
        ("purple", SIMD3(128, 0, 255), .purple),
        ("magenta", SIMD3(255, 0, 255), .magenta)
    ]

    /// A-103 ⌖：照片上點到的顏色反查最接近的色帶；灰色不屬於任何色帶。
    func testDominantBandForPickedColor() {
        for color in Self.namedSRGBColors {
            XCTAssertEqual(ColorMixerBand.dominant(sRGB: color.value / 255), color.band, color.name)
        }
        XCTAssertEqual(ColorMixerBand.dominant(sRGB: SIMD3(0.45, 0.65, 0.9)), .blue)
        XCTAssertNil(ColorMixerBand.dominant(sRGB: SIMD3(0.5, 0.5, 0.5)))
    }

    func testEightBandsAreOrderedAndNeutral() {
        XCTAssertEqual(ColorMixerBand.allCases, [
            .red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta
        ])
        XCTAssertEqual(ColorMixerBand.allCases.map(\.index), Array(0..<8))
        XCTAssertEqual(ColorMixerParameters().bands.count, 8)
        XCTAssertTrue(ColorMixerParameters().isNeutral)
    }

    func testMissingMixerInLegacyEditParametersUsesNeutralDefaults() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(EditParameters()))
                as? [String: Any]
        )
        object.removeValue(forKey: "colorMixer")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(EditParameters.self, from: data)

        XCTAssertTrue(decoded.colorMixer.isNeutral)
        XCTAssertEqual(decoded.colorMixer.bands.count, 8)
    }

    func testPresetRoundTripsSelectedColorMixerSection() throws {
        var source = EditParameters()
        source.colorMixer.bands[ColorMixerBand.orange.index].hueShift = 18
        source.colorMixer.bands[ColorMixerBand.blue.index].black = 0.4
        let preset = EditPreset(name: "Color Mixer", sections: [.colorMixer], parameters: source)
        let data = try JSONEncoder().encode(preset)
        let payload = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["parameters"] as? [String: Any]
        )
        XCTAssertNotNil(payload["colorMixer"])

        let decoded = try JSONDecoder().decode(EditPreset.self, from: data)
        var base = EditParameters()
        base.colorEngine.chromaStrength = 1.2
        let applied = decoded.applied(to: base)
        XCTAssertEqual(applied.colorMixer, source.colorMixer)
        XCTAssertEqual(applied.colorEngine, base.colorEngine)
    }

    func testLegacyPresetWithoutColorMixerPayloadDecodesNeutral() throws {
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"舊預設",
         "sections":["colorEngine"],"parameters":{"colorEngine":{}}}
        """

        let decoded = try JSONDecoder().decode(EditPreset.self, from: Data(legacyJSON.utf8))

        XCTAssertTrue(decoded.parameters.colorMixer.isNeutral)
        XCTAssertFalse(decoded.sections.contains(.colorMixer))
    }

    func testMixerRoundTripsAllBandValues() throws {
        var parameters = EditParameters()
        parameters.colorMixer.bands[ColorMixerBand.orange.index].hueShift = 24
        parameters.colorMixer.bands[ColorMixerBand.green.index].saturationShift = -0.4
        parameters.colorMixer.bands[ColorMixerBand.blue.index].lightnessShift = 0.3
        parameters.colorMixer.bands[ColorMixerBand.magenta.index].cyan = 0.2
        parameters.colorMixer.bands[ColorMixerBand.red.index].magenta = -0.1
        parameters.colorMixer.bands[ColorMixerBand.aqua.index].yellow = 0.5
        parameters.colorMixer.bands[ColorMixerBand.purple.index].black = -0.6

        let decoded = try JSONDecoder().decode(EditParameters.self, from: JSONEncoder().encode(parameters))

        XCTAssertEqual(decoded, parameters)
    }

    func testNeutralMixerIsExactSceneTransformIdentity() {
        let parameters = EditParameters()
        let transform = SceneTransform(
            layerA: parameters.layerA,
            colorEngine: parameters.colorEngine,
            colorMixer: parameters.colorMixer
        )
        let samples = [
            SIMD3(0.1, 0.2, 0.3),
            SIMD3(0.45, 0.3, 0.12),
            SIMD3(1.4, 0.8, 0.3)
        ]
        let baseline = SceneTransform(layerA: parameters.layerA, colorEngine: parameters.colorEngine)

        for sample in samples {
            XCTAssertEqual(transform.apply(sample), baseline.apply(sample))
        }
    }

    func testHueBandAndSelectiveColorChangeOnlyTheirTargetColor() {
        let input = sceneLinearSRGB(SIMD3(255, 128, 0))
        let defaults = EditParameters()
        let baseline = SceneTransform(
            layerA: defaults.layerA,
            colorEngine: defaults.colorEngine,
            colorMixer: defaults.colorMixer
        ).apply(input)

        var hueParameters = defaults.colorMixer
        hueParameters.bands[ColorMixerBand.orange.index].hueShift = 30
        let hueAdjusted = SceneTransform(
            layerA: defaults.layerA,
            colorEngine: defaults.colorEngine,
            colorMixer: hueParameters
        ).apply(input)
        let baseHue = OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(baseline))).z
        let adjustedHue = OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(hueAdjusted))).z
        XCTAssertGreaterThan(hueDistance(adjustedHue, baseHue), 10)

        var selectiveParameters = defaults.colorMixer
        selectiveParameters.bands[ColorMixerBand.orange.index].cyan = 1
        let selectiveAdjusted = SceneTransform(
            layerA: defaults.layerA,
            colorEngine: defaults.colorEngine,
            colorMixer: selectiveParameters
        ).apply(input)
        XCTAssertLessThan(selectiveAdjusted.x, baseline.x)

        var magentaParameters = defaults.colorMixer
        magentaParameters.bands[ColorMixerBand.orange.index].magenta = 1
        let magentaAdjusted = SceneTransform(
            layerA: defaults.layerA,
            colorEngine: defaults.colorEngine,
            colorMixer: magentaParameters
        ).apply(input)
        XCTAssertLessThan(magentaAdjusted.y, baseline.y)

        var yellowParameters = defaults.colorMixer
        yellowParameters.bands[ColorMixerBand.orange.index].yellow = 1
        let yellowAdjusted = SceneTransform(
            layerA: defaults.layerA,
            colorEngine: defaults.colorEngine,
            colorMixer: yellowParameters
        ).apply(input)
        XCTAssertLessThan(yellowAdjusted.z, baseline.z)

        var blackParameters = defaults.colorMixer
        blackParameters.bands[ColorMixerBand.orange.index].black = 1
        let blackAdjusted = SceneTransform(
            layerA: defaults.layerA,
            colorEngine: defaults.colorEngine,
            colorMixer: blackParameters
        ).apply(input)
        XCTAssertLessThan(blackAdjusted.x, baseline.x)
        XCTAssertLessThan(blackAdjusted.y, baseline.y)
        XCTAssertLessThan(blackAdjusted.z, baseline.z)
    }

    func testNamedSRGBColorsRespondToTheirHSLBand() {
        let colorEngine = disabledColorEngine()
        for reference in Self.namedSRGBColors {
            let input = sceneLinearSRGB(reference.value)
            let inputHue = hue(of: input)
            var mixer = ColorMixerParameters()
            mixer.bands[reference.band.index].hueShift = 24

            let output = SceneTransform(
                layerA: LayerATechnical(), colorEngine: colorEngine, colorMixer: mixer
            ).apply(input)

            XCTAssertGreaterThan(
                hueDistance(hue(of: output), inputHue), 15,
                "具名 sRGB \(reference.name) 應由 \(reference.band) 色帶控制"
            )
        }
    }

    func testNamedSRGBRedRespondsToRedAndNotOrangeForHSLAndSelectiveColor() {
        let colorEngine = disabledColorEngine()
        let input = sceneLinearSRGB(Self.namedSRGBColors[0].value)
        let baseline = SceneTransform(layerA: LayerATechnical(), colorEngine: colorEngine).apply(input)

        var redHueMixer = ColorMixerParameters()
        redHueMixer.bands[ColorMixerBand.red.index].hueShift = 24
        let redHueOutput = SceneTransform(
            layerA: LayerATechnical(), colorEngine: colorEngine, colorMixer: redHueMixer
        ).apply(input)
        XCTAssertGreaterThan(hueDistance(hue(of: redHueOutput), hue(of: baseline)), 15)

        var orangeHueMixer = ColorMixerParameters()
        orangeHueMixer.bands[ColorMixerBand.orange.index].hueShift = 24
        let orangeHueOutput = SceneTransform(
            layerA: LayerATechnical(), colorEngine: colorEngine, colorMixer: orangeHueMixer
        ).apply(input)
        XCTAssertLessThan(colorDistance(orangeHueOutput, baseline), 1e-10)

        var redSelectiveMixer = ColorMixerParameters()
        redSelectiveMixer.bands[ColorMixerBand.red.index].cyan = 1
        let redSelectiveOutput = SceneTransform(
            layerA: LayerATechnical(), colorEngine: colorEngine, colorMixer: redSelectiveMixer
        ).apply(input)
        XCTAssertGreaterThan(colorDistance(redSelectiveOutput, baseline), 1e-3)

        var orangeSelectiveMixer = ColorMixerParameters()
        orangeSelectiveMixer.bands[ColorMixerBand.orange.index].cyan = 1
        let orangeSelectiveOutput = SceneTransform(
            layerA: LayerATechnical(), colorEngine: colorEngine, colorMixer: orangeSelectiveMixer
        ).apply(input)
        XCTAssertLessThan(colorDistance(orangeSelectiveOutput, baseline), 1e-10)
    }

    func testNamedSRGBColorsRespondToTheirSelectiveColorBand() {
        let colorEngine = disabledColorEngine()
        for reference in Self.namedSRGBColors {
            let input = sceneLinearSRGB(reference.value)
            let baseline = SceneTransform(layerA: LayerATechnical(), colorEngine: colorEngine).apply(input)
            var mixer = ColorMixerParameters()
            mixer.bands[reference.band.index].black = 0.5

            let output = SceneTransform(
                layerA: LayerATechnical(), colorEngine: colorEngine, colorMixer: mixer
            ).apply(input)

            XCTAssertGreaterThan(
                colorDistance(output, baseline), 1e-3,
                "具名 sRGB \(reference.name) 應由 \(reference.band) 選擇性色彩控制"
            )
        }
    }

    func testDistantHueIsUnaffectedBySelectedBand() {
        let defaults = EditParameters()
        let input = RGBColorSpace.workingRec2020.fromXYZ(
            OKLab.toXYZ(OKLab.fromLCH(SIMD3(0.55, 0.12, 220)))
        )
        var mixer = defaults.colorMixer
        mixer.bands[ColorMixerBand.orange.index] = ColorMixerBandParameters(
            hueShift: 45, saturationShift: 1, lightnessShift: 1,
            cyan: 1, magenta: -1, yellow: 1, black: -1
        )
        let original = SceneTransform(
            layerA: defaults.layerA, colorEngine: defaults.colorEngine,
            colorMixer: defaults.colorMixer
        ).apply(input)
        let adjusted = SceneTransform(
            layerA: defaults.layerA, colorEngine: defaults.colorEngine,
            colorMixer: mixer
        ).apply(input)

        XCTAssertEqual(adjusted, original)
    }

    func testNonNeutralMixerChangesBakedLUTOutput() {
        let defaults = EditParameters()
        let input = sceneLinearSRGB(SIMD3(255, 128, 0))
        let baselineScene = SceneTransform(
            layerA: defaults.layerA, colorEngine: defaults.colorEngine,
            colorMixer: defaults.colorMixer
        )
        var mixer = defaults.colorMixer
        mixer.bands[ColorMixerBand.orange.index].hueShift = 30
        let adjustedScene = SceneTransform(
            layerA: defaults.layerA, colorEngine: defaults.colorEngine,
            colorMixer: mixer
        )

        let baselineLUT = LUT3D.bake(size: 9) { baselineScene.apply($0) }
        let adjustedLUT = LUT3D.bake(size: 9) { adjustedScene.apply($0) }
        let baseline = baselineLUT.sample(input)
        let adjusted = adjustedLUT.sample(input)
        let difference = max(abs(adjusted.x - baseline.x), abs(adjusted.y - baseline.y),
                             abs(adjusted.z - baseline.z))

        XCTAssertGreaterThan(difference, 1e-3)
    }

    func testColorMixerHasAnIndependentResetSection() {
        var parameters = EditParameters()
        parameters.colorMixer.bands[ColorMixerBand.blue.index].black = 0.7
        parameters.finishing.finalContrast = 0.3
        XCTAssertFalse(parameters.isDefault(.colorMixer))

        parameters.reset(.colorMixer)

        XCTAssertTrue(parameters.isDefault(.colorMixer))
        XCTAssertEqual(parameters.finishing.finalContrast, 0.3)
    }

    private func hueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs((lhs - rhs).truncatingRemainder(dividingBy: 360))
        return min(difference, 360 - difference)
    }

    private func hue(of workingRGB: SIMD3<Double>) -> Double {
        let xyz = RGBColorSpace.workingRec2020.toXYZ(workingRGB)
        return OKLab.toLCH(OKLab.fromXYZ(xyz)).z
    }

    private func sceneLinearSRGB(_ srgb8: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ value: Double) -> Double {
            let encoded = value / 255
            return encoded <= 0.04045
                ? encoded / 12.92
                : pow((encoded + 0.055) / 1.055, 2.4)
        }
        let linearSRGB = SIMD3(linear(srgb8.x), linear(srgb8.y), linear(srgb8.z))
        let xyz = RGBColorSpace.sRGB.toXYZ(linearSRGB)
        return RGBColorSpace.workingRec2020.fromXYZ(xyz)
    }

    private func disabledColorEngine() -> ColorEngineParameters {
        var parameters = ColorEngineParameters()
        parameters.enabled = false
        return parameters
    }

    private func colorDistance(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        max(abs(lhs.x - rhs.x), abs(lhs.y - rhs.y), abs(lhs.z - rhs.z))
    }
}
