import XCTest
import simd
@testable import RFCore

final class SceneTransformTests: XCTestCase {
    func testColorEngineIlluminantDoesNotOverrideLayerAWhiteBalance() {
        let a = EditParameters()
        var b = a
        b.colorEngine.illuminant = .tungsten
        var metadata = RawMetadata()
        metadata.neutralTemperature = 5700
        metadata.neutralTint = 8
        XCTAssertEqual(
            RenderPipeline.sceneTransform(for: a, metadata: metadata).whiteBalanceGains,
            RenderPipeline.sceneTransform(for: b, metadata: metadata).whiteBalanceGains
        )
    }
    private func transform(_ configure: (inout EditParameters) -> Void = { _ in }) -> SceneTransform {
        var params = EditParameters()
        configure(&params)
        var meta = RawMetadata()
        // 以 D65 拍攝為前提，白平衡增益接近 1，測試才是在量色彩引擎本身。
        meta.neutralTemperature = 6504
        meta.neutralTint = 0
        return RenderPipeline.sceneTransform(for: params, metadata: meta)
    }

    /// 驗收條件 3：色彩引擎不能讓中性灰變色。
    func testNeutralStaysNeutral() {
        let t = transform()
        for v in [0.05, 0.18, 0.5, 2.0] {
            let out = t.apply(SIMD3(repeating: v))
            let lch = OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(out)))
            XCTAssertLessThan(lch.y, 2e-3, "灰階 \(v) 經過色彩引擎後出現色偏")
        }
    }

    /// 曝光 +1 EV 必須讓 scene-referred 值加倍（線性、未 clamp）。
    func testExposureIsLinearAndUnclamped() {
        let base = transform()
        let plusOne = transform { $0.layerA.exposureEV = 1 }
        let input = SIMD3(repeating: 0.18)
        let a = base.apply(input), b = plusOne.apply(input)
        XCTAssertEqual(b.y / a.y, 2.0, accuracy: 1e-6)

        // INV-1：高光不被 clamp 到 1。
        let bright = plusOne.apply(SIMD3(repeating: 4.0))
        XCTAssertGreaterThan(bright.y, 4.0)
    }

    /// 高光還原會把超過 diffuse white 的值壓回來，但不影響中間調。
    func testHighlightRecoveryOnlyAffectsHighlights() {
        let plain = transform()
        let recovered = transform { $0.layerA.highlightRecovery = 1 }
        let mid = SIMD3(repeating: 0.18)
        XCTAssertEqual(recovered.apply(mid).y, plain.apply(mid).y, accuracy: 1e-6)
        let high = SIMD3(repeating: 3.0)
        XCTAssertLessThan(recovered.apply(high).y, plain.apply(high).y)
    }

    func testShadowRecoveryLiftsShadows() {
        let plain = transform()
        let lifted = transform { $0.layerA.shadowRecovery = 1 }
        let dark = SIMD3(repeating: 0.02)
        XCTAssertGreaterThan(lifted.apply(dark).y, plain.apply(dark).y)
    }

    /// Chroma 只動彩度，不動色相。
    func testChromaDoesNotShiftHue() {
        let plain = transform()
        let boosted = transform { $0.layerA.chroma = 1.5 }
        let input = SIMD3(0.4, 0.2, 0.1)
        func lch(_ v: SIMD3<Double>) -> SIMD3<Double> {
            OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(v)))
        }
        let a = lch(plain.apply(input)), b = lch(boosted.apply(input))
        XCTAssertLessThan(abs(hueDelta(a.z, b.z)), 0.5)
        XCTAssertGreaterThan(b.y, a.y)
    }

    /// 膚色保護：保護開啟時，膚色帶的色相位移必須小於未保護時。
    func testSkinProtectionLimitsHueShift() {
        var shifted = EditParameters()
        shifted.colorEngine.hueShifts = Array(repeating: 10, count: 6)
        shifted.colorEngine.skinProtection = 0

        var protectedParams = shifted
        protectedParams.colorEngine.skinProtection = 1

        // 基準組：同樣的 pipeline 但不做色相位移，扣掉白平衡等共同影響。
        var baseline = shifted
        baseline.colorEngine.hueShifts = Array(repeating: 0, count: 6)

        var meta = RawMetadata()
        meta.neutralTemperature = 6504
        let unprotected = RenderPipeline.sceneTransform(for: shifted, metadata: meta)
        let guarded = RenderPipeline.sceneTransform(for: protectedParams, metadata: meta)
        let reference = RenderPipeline.sceneTransform(for: baseline, metadata: meta)

        // 一個落在膚色帶（OKLCH hue ≈ 45°）的顏色。
        let skin = RGBColorSpace.workingRec2020.fromXYZ(
            OKLab.toXYZ(OKLab.fromLCH(SIMD3(0.7, 0.08, 45)))
        )
        func hue(_ v: SIMD3<Double>) -> Double {
            OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.workingRec2020.toXYZ(v))).z
        }
        let base = hue(reference.apply(skin))
        let guardedShift = abs(hueDelta(hue(guarded.apply(skin)), base))
        let unprotectedShift = abs(hueDelta(hue(unprotected.apply(skin)), base))
        XCTAssertLessThan(guardedShift, 0.5, "完全保護時膚色色相不應移動")
        XCTAssertGreaterThan(unprotectedShift, 5.0, "不保護時應看到明顯位移")
        XCTAssertLessThan(guardedShift, unprotectedShift)
    }

    /// 關掉色彩引擎（A/B 的「前」）必須真的略過 perceptual mapping。
    func testColorEngineToggleChangesResult() {
        var on = EditParameters()
        on.colorEngine.chromaStrength = 1.4
        var off = on
        off.colorEngine.enabled = false
        var meta = RawMetadata()
        meta.neutralTemperature = 6504
        let input = SIMD3(0.5, 0.2, 0.1)
        let a = RenderPipeline.sceneTransform(for: on, metadata: meta).apply(input)
        let b = RenderPipeline.sceneTransform(for: off, metadata: meta).apply(input)
        XCTAssertNotEqual(a.x, b.x, accuracy: 0)
    }
}

final class TargetTransformTests: XCTestCase {
    private func make(_ gamut: RenderingTarget.Gamut = .displayP3) -> TargetTransform {
        TargetTransform(
            target: RenderingTarget(gamut: gamut),
            tone: ToneMappingParameters(),
            gamut: GamutMappingParameters()
        )
    }

    /// 驗收條件 4：tone curve 單調遞增，不會在高光反轉。
    func testToneCurveIsMonotonic() {
        let t = make()
        var previous = -1.0
        for i in 0...400 {
            let l = Double(i) / 100.0   // 一路推到遠超過 diffuse white
            let v = t.toneCurve(l)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-12, "在 L=\(l) 反轉")
            previous = v
            XCTAssertLessThanOrEqual(v, 1.0 + 1e-9)
        }
    }

    /// Diffuse white 對應到 SDR white 附近，而不是被壓成灰。
    func testDiffuseWhiteLandsNearSDRWhite() {
        let t = make()
        let whiteL = OKLab.toLCH(OKLab.fromXYZ(
            RGBColorSpace.workingRec2020.toXYZ(SIMD3(repeating: 1.0))
        )).x
        let mapped = t.toneCurve(whiteL)
        XCTAssertGreaterThan(mapped, 0.7)
    }

    /// 中間調對比越大，暗部越暗、亮部越亮。
    func testMidtoneContrast() {
        var high = ToneMappingParameters()
        high.midtoneContrast = 1.6
        let plain = make()
        let punchy = TargetTransform(target: RenderingTarget(), tone: high,
                                     gamut: GamutMappingParameters())
        XCTAssertLessThan(punchy.toneCurve(0.25), plain.toneCurve(0.25))
    }

    func testProcessedSDRToneEditsStayContinuousAtTheirNeutralValues() {
        let baseline = ToneMappingParameters()
        let gamut = GamutMappingParameters()
        let target = RenderingTarget.preset(.webSDR)
        let neutral = TargetTransform(target: target, tone: baseline, gamut: gamut,
                                      preservesProcessedSDR: true)
        var highlight = baseline
        highlight.highlightRollOff += 0.0001
        let highlightEdit = TargetTransform(target: target, tone: highlight, gamut: gamut,
                                            preservesProcessedSDR: true)
        XCTAssertLessThan(abs(highlightEdit.toneCurve(0.9) - neutral.toneCurve(0.9)), 0.001,
                          "A tiny highlight adjustment should not trigger the whole SDR shoulder")

        var shadow = baseline
        shadow.shadowShaping += 0.0001
        let shadowEdit = TargetTransform(target: target, tone: shadow, gamut: gamut,
                                         preservesProcessedSDR: true)
        XCTAssertLessThan(abs(shadowEdit.toneCurve(0.1) - neutral.toneCurve(0.1)), 0.001,
                          "A tiny shadow adjustment should remain a small relative change")
    }

    /// 驗收條件 5：gamut mapping 保色相（OKLCH 下 < 0.5°），並把色彩帶進目標色域。
    func testGamutMappingPreservesHue() {
        for gamut in RenderingTarget.Gamut.allCases {
            let t = make(gamut)
            let space = gamut.colorSpace
            for hue in stride(from: 0.0, to: 360.0, by: 15.0) {
                let source = SIMD3(0.6, 0.35, hue)   // 遠超出 sRGB / P3 的飽和度
                let mapped = t.gamutCompress(source)
                XCTAssertLessThan(abs(hueDelta(mapped.z, source.z)), 0.5,
                                  "\(gamut) hue \(hue) 偏移過大")
                let rgb = space.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(mapped)))
                XCTAssertLessThanOrEqual(rgb.max(), 1.02, "\(gamut) hue \(hue) 仍超出色域")
            }
        }
    }

    /// 色域內的顏色不應該被動到。
    func testInGamutColorsUntouched() {
        let t = make(.sRGB)
        let inside = OKLab.toLCH(OKLab.fromXYZ(
            RGBColorSpace.sRGB.toXYZ(SIMD3(0.4, 0.35, 0.3))
        ))
        let mapped = t.gamutCompress(inside)
        XCTAssertEqual(mapped.y, inside.y, accuracy: 1e-9)
        XCTAssertEqual(mapped.x, inside.x, accuracy: 1e-9)
    }

    /// 壓縮後不應該讓大量顏色貼齊邊界（§10）。
    func testCompressionDoesNotPileOnBoundary() {
        let t = make(.sRGB)
        var values: Set<String> = []
        for c in stride(from: 0.2, through: 0.45, by: 0.01) {
            let mapped = t.gamutCompress(SIMD3(0.6, c, 30))
            values.insert(String(format: "%.5f", mapped.y))
        }
        XCTAssertGreaterThan(values.count, 15, "壓縮後的 chroma 應維持可分辨的層次")
    }

    func testTransferFunctionRoundTrip() {
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(TargetTransform.decodeSRGB(TargetTransform.encodeSRGB(v)),
                           v, accuracy: 1e-9)
        }
    }

    func testHDRTargetsAllocateMoreHighlightRangeThanSDR() {
        let sdr = make()
        let constrained = TargetTransform(
            target: RenderingTarget(dynamicRange: .constrainedHDR, gamut: .displayP3,
                                    transferFunction: .hlg),
            tone: ToneMappingParameters(), gamut: GamutMappingParameters()
        )
        let full = TargetTransform(
            target: RenderingTarget(dynamicRange: .fullHDR, gamut: .rec2020,
                                    transferFunction: .pq),
            tone: ToneMappingParameters(), gamut: GamutMappingParameters()
        )
        let highlight = 1.5
        XCTAssertGreaterThan(constrained.toneCurve(highlight), sdr.toneCurve(highlight))
        XCTAssertGreaterThan(full.toneCurve(highlight), constrained.toneCurve(highlight))
    }

    func testEDRHeadroomKeepsDiffuseWhiteAtReferenceWhiteAndAllocatesHighlightsAboveIt() {
        let target = RenderingTarget(
            dynamicRange: .fullHDR, gamut: .displayP3, transferFunction: .linear,
            intent: .appleHDR, contentPeakNits: 203 * 2.5
        )
        let transform = TargetTransform(
            target: target, tone: ToneMappingParameters(), gamut: GamutMappingParameters()
        )
        let whiteL = OKLab.toLCH(OKLab.fromXYZ(
            RGBColorSpace.workingRec2020.toXYZ(SIMD3(repeating: 1.0))
        )).x

        XCTAssertEqual(transform.toneCurve(whiteL), 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(transform.toneCurve(whiteL * 2), 1.0)
        XCTAssertLessThanOrEqual(transform.toneCurve(whiteL * 20), 2.5)
    }

    func testSDRAndUnavailableHDRNeverProduceEDRValues() {
        let sdr = TargetTransform(
            target: RenderingTarget(contentPeakNits: 203 * 4),
            tone: ToneMappingParameters(), gamut: GamutMappingParameters()
        )
        let unavailable = TargetTransform(
            target: RenderingTarget(dynamicRange: .fullHDR, gamut: .displayP3,
                                    transferFunction: .linear, intent: .appleHDR,
                                    contentPeakNits: 203),
            tone: ToneMappingParameters(), gamut: GamutMappingParameters()
        )

        XCTAssertLessThanOrEqual(sdr.toneCurve(4), 1)
        XCTAssertLessThanOrEqual(unavailable.toneCurve(4), 1)
    }

    func testEDRColorSpaceIsExtendedLinearOnlyForLinearHDRTargets() {
        let edr = RenderingTarget(dynamicRange: .constrainedHDR, gamut: .displayP3,
                                  transferFunction: .linear, intent: .appleHDR,
                                  contentPeakNits: 406)
        XCTAssertEqual(RenderPipeline.edrColorSpace(for: edr).name,
                       CGColorSpace.extendedLinearDisplayP3)

        // SDR 與非 linear HDR（HLG / PQ）不能掛 extended-linear，否則會被解讀成兩次編碼。
        let sdr = RenderingTarget.preset(.appleSDR)
        XCTAssertEqual(RenderPipeline.edrColorSpace(for: sdr).name, CGColorSpace.displayP3)
        let hlg = RenderingTarget.preset(.appleHDR)
        XCTAssertEqual(RenderPipeline.edrColorSpace(for: hlg).name,
                       RenderPipeline.colorSpace(for: hlg).name)
    }

    func testHDRPreviewStillHonorsMidtoneContrast() {
        let target = RenderingTarget(
            dynamicRange: .constrainedHDR, gamut: .displayP3,
            transferFunction: .linear, intent: .appleHDR, contentPeakNits: 406
        )
        var contrast = ToneMappingParameters()
        contrast.midtoneContrast = 1.6
        let plain = TargetTransform(target: target, tone: ToneMappingParameters(),
                                    gamut: GamutMappingParameters())
        let punchy = TargetTransform(target: target, tone: contrast,
                                     gamut: GamutMappingParameters())

        XCTAssertLessThan(punchy.toneCurve(0.25), plain.toneCurve(0.25))
    }

    func testEveryDynamicRangeToneCurveIsFiniteAndMonotonic() {
        for range in RenderingTarget.DynamicRange.allCases {
            let transfer: RenderingTarget.TransferFunction = range == .fullHDR ? .pq : .hlg
            let t = TargetTransform(
                target: RenderingTarget(dynamicRange: range, gamut: .rec2020,
                                        transferFunction: range == .sdr ? .sRGB : transfer),
                tone: ToneMappingParameters(), gamut: GamutMappingParameters()
            )
            var previous = -Double.infinity
            for i in 0...400 {
                let value = t.toneCurve(Double(i) / 100)
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, previous - 1e-12)
                previous = value
            }
        }
    }

    func testPQAndHLGTransferFunctionsAreMonotonicWithCorrectEndpoints() {
        for transfer in [RenderingTarget.TransferFunction.pq, .hlg] {
            var previous = -Double.infinity
            for i in 0...100 {
                let value = TargetTransform.encode(Double(i) / 100, transfer: transfer)
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, previous)
                previous = value
            }
            XCTAssertEqual(TargetTransform.encode(0, transfer: transfer), 0, accuracy: 1e-12)
            XCTAssertEqual(TargetTransform.encode(1, transfer: transfer), 1, accuracy: 1e-9)
        }
    }

    func testPQEncodesRelativeOneAtReferenceWhiteNotAt10000Nits() {
        let target = RenderingTarget.preset(.hdrStandard)
        XCTAssertEqual(target.referenceWhiteNits, 203)
        XCTAssertEqual(target.contentHeadroom, 1000.0 / 203.0, accuracy: 1e-9)

        // diffuse white → 203 nit → PQ normalized 0.0203。
        XCTAssertEqual(TargetTransform.encodeRelative(1, target: target),
                       TargetTransform.encode(203.0 / 10000, transfer: .pq), accuracy: 1e-12)
        XCTAssertEqual(TargetTransform.encodeRelative(1, target: target), 0.581, accuracy: 0.01)
        // content peak → 1000 nit。
        XCTAssertEqual(TargetTransform.encodeRelative(target.contentHeadroom, target: target),
                       0.751, accuracy: 0.01)
    }

    func testHLGIsRelativeAndMapsContentPeakToOne() {
        let target = RenderingTarget.preset(.appleHDR)
        XCTAssertEqual(TargetTransform.encodeRelative(target.contentHeadroom, target: target),
                       1.0, accuracy: 1e-9)
        // HLG 不做絕對亮度換算，所以 reference white 不是 PQ 那條曲線上的值。
        XCTAssertGreaterThan(TargetTransform.encodeRelative(1, target: target), 0.4)
    }

    func testHDRExportToneCurveUsesContentHeadroomNotSDRRange() {
        let transform = TargetTransform(
            target: .preset(.hdrStandard),
            tone: ToneMappingParameters(), gamut: GamutMappingParameters()
        )
        let whiteL = OKLab.toLCH(OKLab.fromXYZ(
            RGBColorSpace.workingRec2020.toXYZ(SIMD3(repeating: 1.0))
        )).x
        XCTAssertEqual(transform.toneCurve(whiteL), 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(transform.toneCurve(whiteL * 4), 1.0)
        XCTAssertLessThanOrEqual(transform.toneCurve(whiteL * 40), 1000.0 / 203.0 + 1e-9)
    }

    func testEDRPreviewTargetTracksDisplayHeadroom() {
        let target = RenderingTarget.edrPreview(gamut: .displayP3, displayHeadroom: 1.7)
        XCTAssertEqual(target.contentHeadroom, 1.7, accuracy: 1e-9)
        XCTAssertEqual(target.transferFunction, .linear)
        XCTAssertEqual(RenderPipeline.edrColorSpace(for: target).name,
                       CGColorSpace.extendedLinearDisplayP3)
    }

    func testOutputIntentPresetsAreCoherent() {
        let appleHDR = RenderingTarget.preset(.appleHDR)
        XCTAssertEqual(appleHDR.dynamicRange, .constrainedHDR)
        XCTAssertEqual(appleHDR.gamut, .displayP3)
        XCTAssertEqual(appleHDR.transferFunction, .hlg)

        let standard = RenderingTarget.preset(.hdrStandard)
        XCTAssertEqual(standard.dynamicRange, .fullHDR)
        XCTAssertEqual(standard.gamut, .rec2020)
        XCTAssertEqual(standard.transferFunction, .pq)
    }

    /// 黑與白必須落在編碼範圍的兩端。
    func testBlackAndWhiteEndpoints() {
        let t = make()
        let black = t.apply(SIMD3(repeating: 0))
        XCTAssertEqual(black.x, 0, accuracy: 1e-6)
        // Filmic 的預設肩部刻意讓 diffuse white 落在編碼值 0.8 附近，
        // 把最上面一段留給鏡面高光，而不是一路推到 1.0。
        let white = t.apply(SIMD3(repeating: 1.0))
        XCTAssertGreaterThan(white.x, 0.75)
        XCTAssertLessThan(white.x, 0.95)
    }
}

final class LUT3DTests: XCTestCase {
    /// 驗收條件：LUT 查表結果要貼近直接運算，否則預覽與輸出會不一致。
    func testLUTMatchesDirectEvaluation() {
        var params = EditParameters()
        params.layerA.exposureEV = 0.5
        params.colorEngine.chromaStrength = 1.1
        var meta = RawMetadata()
        meta.neutralTemperature = 5500

        let scene = RenderPipeline.sceneTransform(for: params, metadata: meta)
        let target = TargetTransform(target: params.target, tone: params.toneMapping,
                                     gamut: params.gamutMapping)
        let lut = LUT3D.bake(scene: scene, target: target)

        let samples: [SIMD3<Double>] = [
            SIMD3(0.18, 0.18, 0.18),
            SIMD3(0.5, 0.25, 0.1),
            SIMD3(0.05, 0.12, 0.3),
            SIMD3(1.5, 1.2, 0.9),
        ]
        for s in samples {
            let direct = target.apply(scene.apply(s))
            let viaLUT = lut.sample(s)
            XCTAssertEqual(viaLUT.x, direct.x, accuracy: 0.02)
            XCTAssertEqual(viaLUT.y, direct.y, accuracy: 0.02)
            XCTAssertEqual(viaLUT.z, direct.z, accuracy: 0.02)
        }
    }

    func testShaperRoundTrip() {
        for stop in stride(from: -10.0, through: 5.0, by: 0.5) {
            let v = 0.18 * pow(2.0, stop)
            XCTAssertEqual(LUT3D.shaperDecode(LUT3D.shaperEncode(v)), v, accuracy: v * 1e-6)
        }
    }

    func testLUTSize() {
        let lut = LUT3D.bake(
            scene: RenderPipeline.sceneTransform(for: EditParameters(), metadata: RawMetadata()),
            target: TargetTransform(target: RenderingTarget(), tone: ToneMappingParameters(),
                                    gamut: GamutMappingParameters()),
            size: 9
        )
        XCTAssertEqual(lut.data.count, 9 * 9 * 9 * 4)
    }
}

/// A-002 白畫面回歸：as-shot 白平衡不得被重複套用，RAW 的 tint 刻度不得被當成色度偏移。
final class WhiteBalanceAnchorTests: XCTestCase {
    /// `CIRAWFilter.neutralTint` 量級約 ±150，換算後必須落在色度偏移的量級。
    func testFilterTintConvertsToChromaticityScale() {
        XCTAssertEqual(SceneNormalization.chromaticityTint(filterTint: 0), 0, accuracy: 1e-12)
        for t in [-150.0, -10.5, 10.5, 150.0] {
            let c = SceneNormalization.chromaticityTint(filterTint: t)
            XCTAssertLessThan(abs(c), 0.1, "tint \(t) 換算後仍超出色度偏移量級")
            XCTAssertEqual(c.sign == .minus, t > 0, "tint 正值應偏洋紅（y 變小）")
        }
    }

    /// 使用者沒調色溫時，增益必須恰為 1 —— 否則就是對 as-shot 再校正一次。
    func testAsShotProducesIdentityGains() {
        for (temp, filterTint) in [(5708.5, 10.5), (2850.0, -40.0), (7500.0, 0.0)] {
            var meta = RawMetadata()
            meta.neutralTemperature = temp
            meta.neutralTint = filterTint
            let g = RenderPipeline.sceneTransform(for: EditParameters(), metadata: meta)
                .whiteBalanceGains
            XCTAssertEqual(g.x, 1, accuracy: 1e-9, "as-shot \(temp)K 的 R 增益應為 1")
            XCTAssertEqual(g.y, 1, accuracy: 1e-9)
            XCTAssertEqual(g.z, 1, accuracy: 1e-9, "as-shot \(temp)K 的 B 增益應為 1")
        }
    }

    /// 真實 ARW 的 as-shot 值（5708K / tint 10.5）曾讓增益爆到 1e6、整張變白。
    func testRealWorldAsShotDoesNotExplode() {
        var meta = RawMetadata()
        meta.neutralTemperature = 5708.52
        meta.neutralTint = 10.4973
        let t = RenderPipeline.sceneTransform(for: EditParameters(), metadata: meta)
        // 三個相差數百倍的輸入，輸出必須仍然相差數百倍（而不是一起飽和）。
        let dark = t.apply(SIMD3(repeating: 0.002))
        let bright = t.apply(SIMD3(repeating: 0.68))
        XCTAssertEqual(bright.y / dark.y, 340, accuracy: 1)
        XCTAssertLessThan(bright.max(), 1.0, "scene-referred 值不該被白平衡放大")
    }

    /// 使用者手動調整仍要生效，且方向正確：調高色溫 = 畫面變暖。
    func testManualTemperatureStillApplies() {
        var meta = RawMetadata()
        meta.neutralTemperature = 5500
        meta.neutralTint = 0
        var warm = EditParameters()
        warm.layerA.temperature = 8000
        let g = RenderPipeline.sceneTransform(for: warm, metadata: meta).whiteBalanceGains
        XCTAssertGreaterThan(g.x, 1.0, "色溫調高應該加紅")
        XCTAssertLessThan(g.z, 1.0, "色溫調高應該減藍")
    }
}
