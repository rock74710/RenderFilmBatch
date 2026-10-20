import XCTest
import simd
@testable import RFCore

/// A-010：色彩基底 profile 與 12 控制點色彩引擎的回歸測試。
final class ColorProfileTests: XCTestCase {

    /// INV-1 的 golden：導入 profile 之前，預設參數下整條 pipeline 的輸出。
    /// 取樣為 5×5×5 的 RGB 網格（0…1.2），順序為 r 外層、b 內層。
    private static let goldenDefaultOutput: [Double] = [
        0.000000, 0.000000, 0.000000,
        0.037348, 0.200909, 0.351766,
        0.038637, 0.265040, 0.464330,
        0.034999, 0.311588, 0.546475,
        0.028807, 0.349491, 0.613557,
        0.037809, 0.546717, 0.235454,
        0.041984, 0.544508, 0.526936,
        0.045192, 0.550336, 0.655855,
        0.048056, 0.558778, 0.742524,
        0.050652, 0.568105, 0.807317,
        0.063041, 0.705769, 0.312338,
        0.065256, 0.697690, 0.549786,
        0.066918, 0.694708, 0.672734,
        0.068278, 0.693552, 0.758406,
        0.069481, 0.693594, 0.824053,
        0.076598, 0.791631, 0.353833,
        0.078346, 0.784706, 0.554715,
        0.079519, 0.779966, 0.669454,
        0.080480, 0.776768, 0.752390,
        0.081360, 0.774846, 0.817864,
        0.088673, 0.868256, 0.390860,
        0.090544, 0.864555, 0.570430,
        0.092014, 0.862550, 0.682270,
        0.093320, 0.861806, 0.766547,
        0.098307, 0.862000, 0.835131,
        0.618476, 0.071885, 0.119901,
        0.611277, 0.077051, 0.553289,
        0.604697, 0.093268, 0.739940,
        0.595843, 0.110414, 0.881190,
        0.577195, 0.180118, 0.969937,
        0.590374, 0.580542, 0.115548,
        0.576714, 0.576714, 0.576715,
        0.556515, 0.570143, 0.787634,
        0.535423, 0.563003, 0.939104,
        0.522131, 0.565933, 0.970256,
        0.505890, 0.756465, 0.136307,
        0.465205, 0.762126, 0.539700,
        0.443422, 0.753942, 0.742685,
        0.422514, 0.745829, 0.884535,
        0.427464, 0.736955, 0.976123,
        0.432036, 0.860644, 0.186191,
        0.398220, 0.856985, 0.528129,
        0.391516, 0.847746, 0.703221,
        0.387265, 0.839408, 0.823218,
        0.385548, 0.832080, 0.913644,
        0.441272, 0.908656, 0.335919,
        0.452215, 0.896929, 0.569076,
        0.464153, 0.886967, 0.698457,
        0.477362, 0.878406, 0.787797,
        0.491892, 0.871085, 0.853528,
        0.836453, 0.101030, 0.171996,
        0.830131, 0.099112, 0.569415,
        0.825375, 0.107161, 0.748585,
        0.818671, 0.117275, 0.880700,
        0.798708, 0.175789, 0.969603,
        0.819093, 0.557636, 0.132212,
        0.824614, 0.541281, 0.559581,
        0.808668, 0.533347, 0.765331,
        0.792292, 0.525444, 0.912127,
        0.754901, 0.539868, 0.973865,
        0.742754, 0.730786, 0.161968,
        0.732793, 0.725026, 0.530195,
        0.718039, 0.718033, 0.718023,
        0.704045, 0.711961, 0.847311,
        0.690899, 0.707054, 0.945639,
        0.678932, 0.828215, 0.256838,
        0.672135, 0.819023, 0.548675,
        0.666235, 0.811545, 0.696992,
        0.661440, 0.805563, 0.798843,
        0.657876, 0.800983, 0.874395,
        0.671886, 0.869545, 0.456912,
        0.676247, 0.859343, 0.618262,
        0.681142, 0.851532, 0.716452,
        0.686942, 0.845467, 0.784248,
        0.693808, 0.840820, 0.832754,
        0.970943, 0.164462, 0.222524,
        0.971483, 0.123084, 0.572767,
        0.964630, 0.115189, 0.743241,
        0.955189, 0.120294, 0.866941,
        0.945369, 0.126407, 0.967187,
        0.963286, 0.531842, 0.145308,
        0.970100, 0.511006, 0.545160,
        0.958021, 0.501317, 0.739438,
        0.940461, 0.497875, 0.876900,
        0.915963, 0.506927, 0.973210,
        0.882668, 0.706291, 0.203041,
        0.872138, 0.698710, 0.536805,
        0.857587, 0.694391, 0.702988,
        0.843651, 0.691700, 0.816846,
        0.830436, 0.690642, 0.902034,
        0.807426, 0.802288, 0.377552,
        0.800004, 0.794780, 0.585474,
        0.793030, 0.789824, 0.704614,
        0.786846, 0.786794, 0.786695,
        0.781623, 0.785382, 0.846392,
        0.779514, 0.844105, 0.568941,
        0.778187, 0.839378, 0.663631,
        0.776005, 0.836549, 0.731422,
        0.773338, 0.834798, 0.785246,
        0.770356, 0.833744, 0.830340,
        0.947491, 0.342690, 0.331275,
        0.945445, 0.329350, 0.557358,
        0.944028, 0.322742, 0.682678,
        0.945954, 0.320117, 0.781031,
        0.949023, 0.317429, 0.866263,
        0.958803, 0.545960, 0.321544,
        0.963732, 0.538682, 0.559425,
        0.969341, 0.534616, 0.701487,
        0.975082, 0.531503, 0.814466,
        0.980345, 0.528741, 0.913332,
        0.963918, 0.692782, 0.294395,
        0.948350, 0.689038, 0.559981,
        0.933009, 0.688000, 0.700205,
        0.918185, 0.689091, 0.796407,
        0.904019, 0.692036, 0.867201,
        0.871851, 0.790840, 0.490050,
        0.863281, 0.785910, 0.635796,
        0.854974, 0.783998, 0.725441,
        0.847561, 0.784091, 0.786747,
        0.844399, 0.783597, 0.832671,
        0.838001, 0.839292, 0.576393,
        0.836398, 0.834547, 0.666321,
        0.834088, 0.831553, 0.731771,
        0.831366, 0.829586, 0.784120,
        0.828375, 0.828300, 0.828157,    ]

    private func defaultPipelineOutputs() -> [Double] {
        let p = EditParameters()
        let scene = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
        let target = TargetTransform(target: p.target, tone: p.toneMapping, gamut: p.gamutMapping)
        var out: [Double] = []
        for r in stride(from: 0.0, through: 1.0, by: 0.25) {
            for g in stride(from: 0.0, through: 1.0, by: 0.25) {
                for b in stride(from: 0.0, through: 1.0, by: 0.25) {
                    let d = target.apply(scene.apply(SIMD3(r, g, b) * 1.2))
                    out.append(contentsOf: [d.x, d.y, d.z])
                }
            }
        }
        return out
    }

    /// INV-1：profile = natural 且全為預設值時，輸出與導入 profile 之前逐像素相同。
    func testDefaultRenderingUnchanged() {
        let produced = defaultPipelineOutputs()
        XCTAssertEqual(produced.count, Self.goldenDefaultOutput.count)
        for (i, v) in produced.enumerated() {
            XCTAssertEqual(v, Self.goldenDefaultOutput[i], accuracy: 1e-6, "sample \(i)")
        }
        XCTAssertEqual(EditParameters().colorEngine.profile, .natural)
    }

    /// INV-1 的另一半：natural profile 的定義本身就是 no-op。
    func testNaturalProfileIsNoOp() {
        var p = EditParameters()
        p.applyProfile(.natural)
        XCTAssertEqual(p, EditParameters())
    }

    /// INV-2：舊 sidecar（6 值色帶）載入後值被保留，rendering 只有可量測的微小差異。
    func testLegacySixBandSidecarUpgrades() throws {
        let legacyJSON = """
        {"formatVersion":1,"rawFileName":"IMG.ARW","modifiedAt":"2026-01-01T00:00:00Z",
         "versions":{"pipeline":"rf.pipeline.1","colorEngine":"rf.hncslike.1",
           "opticalRenderer":"rf.optical.1","toneMapping":"rf.tonemap.filmic.1",
           "gamutMapping":"rf.gamut.oklch.1","rawDecoder":"apple.raw.test","lensProfile":"rf.lens.test"},
         "parameters":{"layerA":{"exposureEV":0,"highlightRecovery":0,"shadowRecovery":0,
           "linearContrast":0,"chroma":1},
          "colorEngine":{"enabled":true,"illuminant":"asShot","chromaStrength":1,
           "highlightProtectionStart":0.75,"highlightProtection":0.6,"skinProtection":0.8,
           "hueShifts":[6,0,0,0,0,0],"chromaBands":[1.2,1,1,1,1,1]},
          "toneMapping":{"shoulderStart":0.6,"highlightRollOff":0.7,"shadowShaping":0,
           "midtoneContrast":1,"diffuseWhite":1},
          "gamutMapping":{"knee":0.85,"lightnessAdapt":0.15,"enabled":true},
          "optical":{"enabled":true},
          "target":{"dynamicRange":"sdr","gamut":"displayP3"}}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(Sidecar.self, from: Data(legacyJSON.utf8))
        let engine = sidecar.parameters.colorEngine

        // 升取樣到 12 點，且舊值落在原本的色帶位置上。
        XCTAssertEqual(engine.hueShifts.count, 12)
        XCTAssertEqual(engine.chromaBands.count, 12)
        XCTAssertEqual(engine.hueShifts[0], 6, accuracy: 1e-9)
        XCTAssertEqual(engine.chromaBands[0], 1.2, accuracy: 1e-9)
        XCTAssertEqual(engine.hueShifts[2], 0, accuracy: 1e-9)   // 舊的 60° 色帶
        XCTAssertEqual(engine.hueShifts[1], 3, accuracy: 1e-9)   // 30°：舊線性內插的中點
        // 未出現在舊檔的新欄位回到中性預設。
        XCTAssertEqual(engine.profile, .natural)
        XCTAssertTrue(engine.splitTone.isNeutral)
        XCTAssertEqual(engine.hueShiftByLightness, Array(repeating: 1, count: 5))

        // rendering 差異：與「舊的 6 點線性內插」相比，只在色帶峰值附近有微小差異。
        var worstHue = 0.0, worstChroma = 0.0
        for deg in stride(from: 0.0, to: 360.0, by: 1.0) {
            let legacyHue = legacyLinear([6, 0, 0, 0, 0, 0], hue: deg)
            let legacyChroma = legacyLinear([1.2, 1, 1, 1, 1, 1], hue: deg)
            worstHue = max(worstHue, abs(SceneTransform.hueCurve(engine.hueShifts, hue: deg) - legacyHue))
            worstChroma = max(worstChroma,
                              abs(SceneTransform.hueCurve(engine.chromaBands, hue: deg) - legacyChroma))
        }
        // 這兩個數字就是 INV-2 的實際代價，故意寫死以便日後改動時被測試擋下。
        XCTAssertLessThan(worstHue, 0.75, "色相位移偏差（度）")
        XCTAssertLessThan(worstChroma, 0.025, "chroma 倍率偏差")
    }

    private func legacyLinear(_ values: [Double], hue: Double) -> Double {
        let pos = hue / 60.0
        let low = Int(pos.rounded(.down)) % 6
        let t = pos - pos.rounded(.down)
        return values[low] * (1 - t) + values[(low + 1) % 6] * t
    }

    /// 控制點全部相同時，色相曲線必須精確回傳該值（no-op 的數學前提）。
    func testHueCurveIsExactForConstantControlPoints() {
        for deg in stride(from: 0.0, to: 360.0, by: 7.0) {
            XCTAssertEqual(SceneTransform.hueCurve(Array(repeating: 1, count: 12), hue: deg),
                           1, accuracy: 1e-12)
            XCTAssertEqual(SceneTransform.hueCurve(Array(repeating: 0, count: 12), hue: deg),
                           0, accuracy: 1e-12)
        }
    }

    /// 12 個控制點必須能表達 CN 的三個色相峰；舊的 6 點會把它們抹平。
    func testTwelvePointsResolveThreeNegPeaks() {
        let neg = ColorProfile.negLike.definition.hueShifts
        // 取原始控制點上的紅 / 青 / 洋紅三個峰。
        XCTAssertGreaterThan(neg[0], 15)     // 紅
        XCTAssertGreaterThan(neg[6], 15)     // 青
        XCTAssertGreaterThan(neg[11], 20)    // 洋紅
        XCTAssertLessThan(neg[2], 0)         // 黃綠是谷
        // 用 6 點重新取樣（每 60°）會漏掉 330° 這個峰。
        let coarse = stride(from: 0.0, to: 360.0, by: 60.0).map {
            SceneTransform.hueCurve(neg, hue: $0)
        }
        XCTAssertLessThan(SceneTransform.hueCurve(coarse, hue: 330), neg[11] - 5)
    }

    /// 亮度縮放曲線在節點上取到節點值，兩端以端點值延伸。
    func testLightnessCurveNodesAndClamping() {
        let values = [0.5, 0.7, 1.0, 1.3, 1.6]
        for (i, node) in ColorEngineParameters.lightnessNodes.enumerated() {
            XCTAssertEqual(SceneTransform.lightnessCurve(values, lightness: node),
                           values[i], accuracy: 1e-9)
        }
        XCTAssertEqual(SceneTransform.lightnessCurve(values, lightness: -1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SceneTransform.lightnessCurve(values, lightness: 5), 1.6, accuracy: 1e-9)
    }

    /// chromeLike 的高光彩度必須比中灰收斂得更多（量測到的特徵）。
    func testChromeLikeConvergesHighlightChroma() {
        var p = EditParameters()
        p.applyProfile(.chromeLike)
        let engine = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
        func chromaRatio(ev: Double) -> Double {
            let grey = 0.18 * pow(2.0, ev)
            // 以紅橙方向的彩色樣本比較：輸入相同色相、相同相對彩度。
            let base = SIMD3(grey * 1.6, grey * 0.8, grey * 0.6)
            let inC = OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(base))).y
            let outC = OKLab.toLCH(OKLab.fromXYZ(
                RGBColorSpace.workingRec2020.toXYZ(engine.apply(base)))).y
            return outC / inC
        }
        XCTAssertLessThan(chromaRatio(ev: 2.0), chromaRatio(ev: 0.0))
    }

    /// INV-3：splitTone = 0 時中性輸入的輸出 chroma 必須為 0。
    func testNeutralInputStaysNeutralWithoutSplitTone() {
        var p = EditParameters()
        p.applyProfile(.chromeLike)
        XCTAssertTrue(p.colorEngine.splitTone.isNeutral)
        let engine = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
        for ev in stride(from: -4.0, through: 3.0, by: 0.5) {
            let g = 0.18 * pow(2.0, ev)
            let out = engine.apply(SIMD3(g, g, g))
            let c = OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(out))).y
            XCTAssertLessThan(c, 0.002, "EV \(ev)")
        }
    }

    /// negLike 的灰階必須帶色：陰影偏青綠、高光偏橙，且方向與量測一致。
    func testNegLikeSplitTonesGreyRamp() {
        var p = EditParameters()
        p.applyProfile(.negLike)
        let engine = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
        func greyLCH(ev: Double) -> SIMD3<Double> {
            let g = 0.18 * pow(2.0, ev)
            return OKLab.toLCH(OKLab.fromXYZ(
                RGBColorSpace.workingRec2020.toXYZ(engine.apply(SIMD3(g, g, g)))))
        }
        let shadow = greyLCH(ev: -3)
        let highlight = greyLCH(ev: 3)
        XCTAssertGreaterThan(shadow.y, 0.003)
        XCTAssertGreaterThan(highlight.y, 0.003)
        XCTAssertEqual(shadow.z, 155.6, accuracy: 15)   // 青綠
        XCTAssertEqual(highlight.z, 26.8, accuracy: 15) // 橙
        // 中灰附近幾乎不染色。
        XCTAssertLessThan(greyLCH(ev: 0).y, 0.002)
    }

    /// split tone 只作用在低彩度區：飽和色不該被整片染色。
    func testSplitToneLeavesSaturatedColorsAlone() {
        var p = EditParameters()
        p.applyProfile(.negLike)
        var neutralSplit = p
        neutralSplit.colorEngine.splitTone = SplitToneParameters()
        let withTone = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
        let without = SceneTransform(layerA: neutralSplit.layerA, colorEngine: neutralSplit.colorEngine)
        let saturated = SIMD3(0.35, 0.03, 0.03)
        let a = withTone.apply(saturated), b = without.apply(saturated)
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        XCTAssertEqual(a.z, b.z, accuracy: 1e-6)
    }

    /// profile 必須同時帶一組 tone 預設，而且與 natural 不同。
    func testProfileCarriesToneDefaults() {
        var p = EditParameters()
        p.applyProfile(.chromeLike)
        XCTAssertNotEqual(p.toneMapping, ToneMappingParameters())
        XCTAssertTrue(p.matchesProfileDefaults)
        p.colorEngine.hueShifts[0] += 1
        XCTAssertFalse(p.matchesProfileDefaults)
    }

    /// 套 profile 不得動到使用者層級的設定與其他區塊。
    func testApplyProfileKeepsUserLevelSettings() {
        var p = EditParameters()
        p.layerA.exposureEV = 0.7
        p.colorEngine.skinProtection = 0.4
        p.colorEngine.chromaStrength = 1.15
        p.colorEngine.illuminant = .tungsten
        p.gamutMapping.knee = 0.7
        p.target.gamut = .sRGB
        p.applyProfile(.negLike)
        XCTAssertEqual(p.layerA.exposureEV, 0.7)
        XCTAssertEqual(p.colorEngine.skinProtection, 0.4)
        XCTAssertEqual(p.colorEngine.chromaStrength, 1.15)
        XCTAssertEqual(p.colorEngine.illuminant, .tungsten)
        XCTAssertEqual(p.gamutMapping.knee, 0.7)
        XCTAssertEqual(p.target.gamut, .sRGB)
    }

    /// A-011：profile 的 tone 預設只能帶「相對 PROVIA 的差量」，不能帶原廠的絕對曲線。
    ///
    /// A-010 直接擬合絕對灰階曲線，shadowShaping 兩個 profile 都頂到 -0.9 的下界、
    /// midtoneContrast 到 1.45，實際使用時陰影被壓死、要靠 linearContrast -0.36 才壓得回來。
    /// 參數落在合理範圍是那個失誤最直接的防線。
    func testProfileToneStaysCloseToDefault() {
        let natural = TargetTransform(target: RenderingTarget(), tone: ToneMappingParameters(),
                                      gamut: GamutMappingParameters())
        for profile in ColorProfile.allCases where profile != .natural {
            let tone = profile.definition.toneMapping
            XCTAssertLessThanOrEqual(abs(tone.shadowShaping), 0.45, "\(profile) shadowShaping")
            XCTAssertLessThanOrEqual(tone.midtoneContrast, 1.25, "\(profile) midtoneContrast")

            let t = TargetTransform(target: RenderingTarget(), tone: tone,
                                    gamut: GamutMappingParameters())
            for l in stride(from: 0.05, through: 1.0, by: 0.05) {
                XCTAssertLessThan(abs(t.toneCurve(l) - natural.toneCurve(l)), 0.09,
                                  "\(profile) L \(l)")
            }
        }
    }

    /// A-011：切到 chromeLike / negLike 之後，灰階與陰影彩度都要維持在可用範圍，
    /// 使用者不需要再用 Layer A 的線性對比去補償。
    func testProfileNeedsNoContrastCompensation() {
        var natural = EditParameters()
        natural.applyProfile(.natural)

        func pipeline(_ p: EditParameters, _ scene: SIMD3<Double>) -> SIMD3<Double> {
            let s = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
            let t = TargetTransform(target: p.target, tone: p.toneMapping, gamut: p.gamutMapping)
            return t.apply(s.apply(scene))
        }
        func outputChroma(_ p: EditParameters, _ scene: SIMD3<Double>) -> Double {
            let rgb = pipeline(p, scene)
            return OKLab.toLCH(OKLab.fromXYZ(p.target.gamut.colorSpace.toXYZ(
                SIMD3(TargetTransform.decodeSRGB(rgb.x),
                      TargetTransform.decodeSRGB(rgb.y),
                      TargetTransform.decodeSRGB(rgb.z))))).y
        }

        for profile in ColorProfile.allCases where profile != .natural {
            var p = EditParameters()
            p.applyProfile(profile)

            // 灰階：與 natural 的差距要小到不必補償。A-010 的預設在 -3EV 差到 0.15。
            for ev in stride(from: -3.0, through: 3.0, by: 0.25) {
                let g = SIMD3<Double>(repeating: 0.18 * pow(2.0, ev))
                XCTAssertLessThan(abs(pipeline(p, g).x - pipeline(natural, g).x), 0.12,
                                  "\(profile) EV \(ev)")
            }

            // 陰影彩度：色彩引擎的成果不能被 tone 壓掉。A-010 的預設在 -2EV 只剩 69%。
            // 下界 0.50 的位置由 profile 自己的色帶決定（negLike 的紫 0.64），不是 tone。
            let ev = -2.0
            let l = OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020
                .toXYZ(SIMD3(repeating: 0.18 * pow(2.0, ev))))).x
            for hue in stride(from: 0.0, to: 360.0, by: 30.0) {
                let lin = RGBColorSpace.workingRec2020.fromXYZ(
                    OKLab.toXYZ(OKLab.fromLCH(SIMD3(l, 0.08, hue))))
                let ratio = outputChroma(p, lin) / outputChroma(natural, lin)
                XCTAssertGreaterThan(ratio, 0.50, "\(profile) hue \(hue)")
            }
        }
    }

    /// 膚色保護必須擋下 negLike 在紅橙區的大幅色相位移（驗收準則 4）。
    func testSkinProtectionLimitsHueShift() {
        var p = EditParameters()
        p.applyProfile(.negLike)
        let engine = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
        for hue in stride(from: 30.0, through: 70.0, by: 5.0) {
            let lin = OKLab.toXYZ(OKLab.fromLCH(SIMD3(0.55, 0.06, hue)))
            let input = RGBColorSpace.workingRec2020.fromXYZ(lin)
            let out = OKLab.toLCH(OKLab.fromXYZ(
                RGBColorSpace.workingRec2020.toXYZ(engine.apply(input))))
            var delta = abs(out.z - hue)
            if delta > 180 { delta = 360 - delta }
            XCTAssertLessThan(delta, 3.0, "hue \(hue)")
        }
    }

    /// 曝光連續性：同一色相由暗掃到亮，輸出色相不得跳點（驗收準則 3）。
    func testHueIsContinuousAcrossExposure() {
        for profile in ColorProfile.allCases {
            var p = EditParameters()
            p.applyProfile(profile)
            let engine = SceneTransform(layerA: p.layerA, colorEngine: p.colorEngine)
            var previous: Double?
            for ev in stride(from: -4.0, through: 4.0, by: 0.25) {
                let g = 0.18 * pow(2.0, ev)
                let input = SIMD3(g * 1.5, g * 0.9, g * 0.5)
                let out = OKLab.toLCH(OKLab.fromXYZ(
                    RGBColorSpace.workingRec2020.toXYZ(engine.apply(input))))
                if let prev = previous {
                    var step = abs(out.z - prev)
                    if step > 180 { step = 360 - step }
                    XCTAssertLessThan(step, 3.0 * 0.25, "\(profile) EV \(ev)")
                }
                previous = out.z
            }
        }
    }
}
