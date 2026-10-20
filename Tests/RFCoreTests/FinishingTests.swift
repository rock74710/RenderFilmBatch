import XCTest
import simd
@testable import RFCore

/// §11 Layer C Finishing 的逐像素色彩層（A-032 M1）。
final class FinishingTests: XCTestCase {
    private let sdr = RenderingTarget()

    private func transform(_ p: FinishingParameters) -> FinishingTransform {
        FinishingTransform(parameters: p, target: sdr)
    }

    // MARK: - INV-1 / INV-2 中性

    func testNeutralIsIdentity() {
        let t = transform(FinishingParameters())
        XCTAssertTrue(FinishingParameters().isNeutral)
        for v in [SIMD3<Double>(0, 0, 0), SIMD3(0.25, 0.5, 0.75), SIMD3(1, 1, 1)] {
            let out = t.apply(v)
            XCTAssertEqual(out.x, v.x, accuracy: 1e-12)
            XCTAssertEqual(out.y, v.y, accuracy: 1e-12)
            XCTAssertEqual(out.z, v.z, accuracy: 1e-12)
        }
    }

    func testLegacySidecarWithoutFinishingIsNeutral() throws {
        let json = """
        {"layerA":{"exposureEV":0,"highlightRecovery":0,"shadowRecovery":0,\
        "linearContrast":0,"chroma":1},"colorEngine":{},\
        "toneMapping":{"shoulderStart":0.6,"highlightRollOff":0.7,"shadowShaping":0,\
        "midtoneContrast":1,"diffuseWhite":1},\
        "gamutMapping":{"knee":0.85,"lightnessAdapt":0.15,"enabled":true},\
        "optical":{"enabled":true},"target":{}}
        """
        let p = try JSONDecoder().decode(EditParameters.self, from: Data(json.utf8))
        XCTAssertTrue(p.finishing.isNeutral)
        XCTAssertTrue(p.isDefault(.finishing))
    }

    func testRoundTripKeepsFinishing() throws {
        var p = EditParameters()
        p.finishing.finalContrast = 0.4
        p.finishing.curve.rgb = [0, 0.6, 1]
        p.finishing.highlights.hue = 60
        p.finishing.highlights.amount = 0.05
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(EditParameters.self, from: data)
        XCTAssertEqual(back.finishing, p.finishing)
    }

    // MARK: - Final Curve

    func testFinalCurveLiftsMidtoneAndKeepsEndpoints() {
        var p = FinishingParameters()
        p.curve.rgb = [0, 0.65, 1]
        XCTAssertFalse(p.isNeutral)
        let t = transform(p)
        XCTAssertEqual(t.apply(SIMD3(repeating: 0.5)).x, 0.65, accuracy: 0.02)
        XCTAssertEqual(t.apply(SIMD3(repeating: 0)).x, 0, accuracy: 1e-9)
        XCTAssertEqual(t.apply(SIMD3(repeating: 1)).x, 1, accuracy: 1e-9)
    }

    func testPerChannelCurveOnlyMovesItsChannel() {
        var p = FinishingParameters()
        p.curve.red = [0, 0.7, 1]
        let out = transform(p).apply(SIMD3(repeating: 0.5))
        XCTAssertGreaterThan(out.x, 0.6)
        XCTAssertEqual(out.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(out.z, 0.5, accuracy: 1e-9)
    }

    // MARK: - Final Contrast

    func testFinalContrastDarkensShadowsAndBrightensHighlights() {
        var p = FinishingParameters()
        p.finalContrast = 0.5
        let t = transform(p)
        XCTAssertLessThan(t.apply(SIMD3(repeating: 0.25)).x, 0.25)
        XCTAssertGreaterThan(t.apply(SIMD3(repeating: 0.75)).x, 0.75)
        XCTAssertEqual(t.apply(SIMD3(repeating: 0.5)).x, 0.5, accuracy: 1e-6)
    }

    // MARK: - Color Grading

    func testHighlightWheelTintsHighlightsOnly() {
        var p = FinishingParameters()
        p.highlights.hue = 60          // 暖黃
        p.highlights.amount = 0.08
        let t = transform(p)

        func chroma(_ v: SIMD3<Double>) -> Double {
            OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.displayP3.toXYZ(v))).y
        }
        let bright = SIMD3<Double>(repeating: 0.85)
        let dark = SIMD3<Double>(repeating: 0.12)
        XCTAssertGreaterThan(chroma(t.apply(bright)), chroma(bright) + 0.01)
        XCTAssertEqual(chroma(t.apply(dark)), chroma(dark), accuracy: 0.005)
    }

    func testShadowLuminanceOffsetLiftsShadows() {
        var p = FinishingParameters()
        p.shadows.luminance = 0.2
        let t = transform(p)
        XCTAssertGreaterThan(t.apply(SIMD3(repeating: 0.1)).x, 0.1)
        XCTAssertEqual(t.apply(SIMD3(repeating: 0.95)).x, 0.95, accuracy: 0.01)
    }

    func testBalanceMovesTheMidtoneCentre() {
        var p = FinishingParameters()
        p.midtones.luminance = 0.2
        let centred = transform(p).apply(SIMD3(repeating: 0.5)).x
        p.balance = -0.5
        let shifted = transform(p).apply(SIMD3(repeating: 0.5)).x
        XCTAssertNotEqual(centred, shifted, accuracy: 0.0)
        XCTAssertLessThan(shifted, centred)
    }

    // MARK: - 舊染色併入色輪（A-103 INV-1）

    /// 舊 sidecar 的 Finishing 染色在讀取時以向量相加併入陰影／高光色輪，畫面不變。
    func testLegacySplitToneFoldsIntoWheels() throws {
        let json = """
        {"shadows":{"hue":60,"amount":0.02,"luminance":0.1},\
        "splitTone":{"shadowHue":240,"shadowAmount":0.05,"highlightHue":80,"highlightAmount":0.03}}
        """
        let p = try JSONDecoder().decode(FinishingParameters.self, from: Data(json.utf8))

        func vec(_ hue: Double, _ amount: Double) -> SIMD2<Double> {
            SIMD2(cos(hue * .pi / 180), sin(hue * .pi / 180)) * amount
        }
        func wheelVec(_ w: GradeWheel) -> SIMD2<Double> { vec(w.hue, w.amount) }
        let shadow = vec(60, 0.02) + vec(240, 0.05)
        XCTAssertEqual(wheelVec(p.shadows).x, shadow.x, accuracy: 1e-12)
        XCTAssertEqual(wheelVec(p.shadows).y, shadow.y, accuracy: 1e-12)
        XCTAssertEqual(p.shadows.luminance, 0.1)
        XCTAssertEqual(wheelVec(p.highlights).x, vec(80, 0.03).x, accuracy: 1e-12)
        XCTAssertEqual(wheelVec(p.highlights).y, vec(80, 0.03).y, accuracy: 1e-12)

        let encoded = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        XCTAssertFalse(encoded.contains("splitTone"))
    }

    // MARK: - LUT 串接

    /// Finishing 必須和 scene / target 烘焙進同一顆 LUT，預覽與輸出才會一致。
    func testBakedLUTIncludesFinishing() {
        let scene = SceneTransform(cameraNormalize: .identity,
                                   layerA: LayerATechnical(),
                                   colorEngine: ColorEngineParameters(),
                                   whiteBalanceGains: SIMD3(repeating: 1))
        let target = TargetTransform(target: sdr, tone: ToneMappingParameters(),
                                     gamut: GamutMappingParameters())
        var p = FinishingParameters()
        p.finalContrast = 0.6

        let baseline = LUT3D.bake(scene: scene, target: target)
        let neutral = LUT3D.bake(scene: scene, target: target,
                                 finishing: transform(FinishingParameters()))
        let graded = LUT3D.bake(scene: scene, target: target, finishing: transform(p))

        // INV-1：中性 finishing 不改變烘焙結果。
        XCTAssertEqual(neutral.data, baseline.data)
        XCTAssertNotEqual(graded.data, baseline.data)

        let mid = SIMD3<Double>(repeating: 0.18)
        XCTAssertLessThan(graded.sample(mid).x, baseline.sample(mid).x)
    }

    // MARK: - Reset

    func testResetFinishingSectionOnlyClearsFinishing() {
        var p = EditParameters()
        p.layerA.exposureEV = 1.0
        p.finishing.finalContrast = 0.3
        XCTAssertFalse(p.isDefault(.finishing))
        p.reset(.finishing)
        XCTAssertTrue(p.isDefault(.finishing))
        XCTAssertEqual(p.layerA.exposureEV, 1.0)
    }

    // MARK: - HDR

    func testHDRHeadroomValuesArePreservedAboveOne() {
        var p = FinishingParameters()
        p.finalContrast = 0.3
        let hdr = RenderingTarget(dynamicRange: .fullHDR, gamut: .rec2020,
                                  transferFunction: .linear, intent: .custom,
                                  contentPeakNits: 1000)
        let t = FinishingTransform(parameters: p, target: hdr)
        let out = t.apply(SIMD3(repeating: 3.0))
        XCTAssertGreaterThan(out.x, 1.0)
    }
}
