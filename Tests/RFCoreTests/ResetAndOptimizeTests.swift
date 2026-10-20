import XCTest
import simd
@testable import RFCore

/// A-006 驗收條件 1：分區重置與重置全部。
final class ParameterResetTests: XCTestCase {
    /// 把每個區塊都改掉，方便驗證「只有指定區塊被重置」。
    private func dirtyParameters() -> EditParameters {
        var p = EditParameters()
        p.applyFilmStyle(.cinema)
        p.layerA.exposureEV = 1.5
        p.layerA.temperature = 7000
        p.layerA.chroma = 1.4
        p.colorEngine.chromaStrength = 1.3
        p.colorEngine.skinProtection = 0.1
        p.colorMixer.bands[ColorMixerBand.orange.index].saturationShift = 0.4
        p.toneMapping.shoulderStart = 0.9
        p.gamutMapping.knee = 0.4
        p.optical.enabled = false
        p.target.gamut = .sRGB
        p.finishing.finalContrast = 0.35
        p.finishing.highlights.amount = 0.04
        p.spatial.clarity = 0.4
        p.spatial.grain.amount = 0.3
        return p
    }

    func testResetAllReturnsToDefaults() {
        var p = dirtyParameters()
        XCTAssertFalse(p.isDefaultAll)
        p.resetAll()
        XCTAssertEqual(p, EditParameters())
        XCTAssertTrue(p.isDefaultAll)
    }

    func testResetSectionTouchesOnlyThatSection() {
        for section in EditSection.allCases {
            let dirty = dirtyParameters()
            var p = dirty
            XCTAssertFalse(p.isDefault(section), "\(section) 應該是被改過的")
            p.reset(section)
            XCTAssertTrue(p.isDefault(section))

            for other in EditSection.allCases where other != section {
                XCTAssertEqual(p.isDefault(other), dirty.isDefault(other),
                               "重置 \(section) 不應動到 \(other)")
            }
            // 其餘欄位維持原值。
            var expected = dirty
            expected.reset(section)
            XCTAssertEqual(p, expected)
        }
    }
}

/// A-006 驗收條件 2–4：色彩引擎一鍵最佳化的統計、建議與百分比混合。
final class ColorEngineOptimizerTests: XCTestCase {
    /// 產生指定 OKLCH 的 working space 線性 RGB。
    private func rgb(l: Double, c: Double, h: Double) -> SIMD3<Double> {
        let lab = OKLab.fromLCH(SIMD3(l, c, h))
        return RGBColorSpace.workingRec2020.fromXYZ(OKLab.toXYZ(lab))
    }

    func testHighChromaSceneSuggestsLowerChromaStrength() {
        let vivid = (0..<100).map { _ in rgb(l: 0.5, c: 0.25, h: 250) }
        let s = ColorEngineOptimizer.statistics(samples: vivid)
        XCTAssertGreaterThan(s.p90Chroma, 0.2)

        let p = ColorEngineOptimizer.suggest(base: ColorEngineParameters(), statistics: s)
        XCTAssertLessThan(p.chromaStrength, 1.0)
        XCTAssertGreaterThanOrEqual(p.chromaStrength, 0.7)
    }

    func testLowChromaSceneSuggestsHigherChromaStrengthWithinClamp() {
        let flat = (0..<100).map { _ in rgb(l: 0.5, c: 0.02, h: 250) }
        let s = ColorEngineOptimizer.statistics(samples: flat)
        let p = ColorEngineOptimizer.suggest(base: ColorEngineParameters(), statistics: s)
        XCTAssertGreaterThan(p.chromaStrength, 1.0)
        XCTAssertLessThanOrEqual(p.chromaStrength, 1.3)
    }

    func testHighlightHeavySceneSuggestsStrongerHighlightProtection() {
        let dark = (0..<100).map { _ in rgb(l: 0.4, c: 0.1, h: 250) }
        var bright = dark
        for i in 0..<20 { bright[i] = rgb(l: 0.95, c: 0.1, h: 250) }

        let flatStats = ColorEngineOptimizer.statistics(samples: dark)
        let brightStats = ColorEngineOptimizer.statistics(samples: bright)
        XCTAssertEqual(flatStats.highlightRatio, 0, accuracy: 1e-9)
        XCTAssertEqual(brightStats.highlightRatio, 0.2, accuracy: 1e-9)

        let a = ColorEngineOptimizer.suggest(base: ColorEngineParameters(), statistics: flatStats)
        let b = ColorEngineOptimizer.suggest(base: ColorEngineParameters(), statistics: brightStats)
        XCTAssertGreaterThan(b.highlightProtection, a.highlightProtection)
        XCTAssertLessThan(b.highlightProtectionStart, a.highlightProtectionStart)
    }

    func testSkinHeavySceneSuggestsStrongerSkinProtection() {
        var samples = (0..<100).map { _ in rgb(l: 0.5, c: 0.1, h: 250) }
        for i in 0..<30 { samples[i] = rgb(l: 0.6, c: 0.08, h: 45) }
        let s = ColorEngineOptimizer.statistics(samples: samples)
        XCTAssertGreaterThan(s.skinRatio, 0.25)

        let p = ColorEngineOptimizer.suggest(base: ColorEngineParameters(), statistics: s)
        XCTAssertEqual(p.skinProtection, 1.0, accuracy: 1e-9)
    }

    /// INV-3 / INV-4：百分比是線性插值，且不動光源與色帶設定。
    func testBlendIsLinearAndPreservesUntouchedFields() {
        var base = ColorEngineParameters()
        base.illuminant = .tungsten
        base.hueShifts[2] = 4
        base.chromaBands[3] = 1.2
        base.chromaStrength = 1.0
        base.highlightProtection = 0.6

        var suggestion = base
        suggestion.chromaStrength = 1.2
        suggestion.highlightProtection = 0.9
        suggestion.illuminant = .tungsten

        XCTAssertEqual(ColorEngineOptimizer.blend(base: base, suggestion: suggestion, amount: 0), base)
        XCTAssertEqual(ColorEngineOptimizer.blend(base: base, suggestion: suggestion, amount: 1), suggestion)

        let half = ColorEngineOptimizer.blend(base: base, suggestion: suggestion, amount: 0.5)
        XCTAssertEqual(half.chromaStrength, 1.1, accuracy: 1e-12)
        XCTAssertEqual(half.highlightProtection, 0.75, accuracy: 1e-12)
        XCTAssertEqual(half.illuminant, .tungsten)
        XCTAssertEqual(half.hueShifts, base.hueShifts)
        XCTAssertEqual(half.chromaBands, base.chromaBands)
    }

    func testBlendClampsAmount() {
        var suggestion = ColorEngineParameters()
        suggestion.chromaStrength = 1.2
        let base = ColorEngineParameters()
        XCTAssertEqual(
            ColorEngineOptimizer.blend(base: base, suggestion: suggestion, amount: -1), base)
        XCTAssertEqual(
            ColorEngineOptimizer.blend(base: base, suggestion: suggestion, amount: 5), suggestion)
    }

    func testEmptySamplesGiveZeroStatistics() {
        let s = ColorEngineOptimizer.statistics(samples: [])
        XCTAssertEqual(s.p90Chroma, 0)
        XCTAssertEqual(s.highlightRatio, 0)
        // 沒有取樣就不該動 chroma 強度。
        let p = ColorEngineOptimizer.suggest(base: ColorEngineParameters(), statistics: s)
        XCTAssertEqual(p.chromaStrength, ColorEngineParameters().chromaStrength)
    }
}
