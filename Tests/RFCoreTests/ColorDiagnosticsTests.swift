import XCTest
import simd
@testable import RFCore

final class ColorDiagnosticsTests: XCTestCase {
    private let hdrTarget = RenderingTarget(
        dynamicRange: .fullHDR,
        gamut: .displayP3,
        transferFunction: .linear,
        intent: .custom,
        referenceWhiteNits: 203,
        contentPeakNits: 1_624
    )

    func testHDRZonesUseRelativeSDRWhite() {
        XCTAssertEqual(analyze(0.5).hdrZone, .sdr)
        XCTAssertEqual(analyze(1.5).hdrZone, .highlight1To2)
        XCTAssertEqual(analyze(3).hdrZone, .highlight2To4)
        XCTAssertEqual(analyze(5).hdrZone, .highlightAbove4)
    }

    func testLegalHDRNeutralDoesNotTriggerGamutWarning() {
        let result = ColorDiagnostics.analyze(
            targetLinear: SIMD3(repeating: 3),
            unmappedTargetLinear: SIMD3(repeating: 3),
            target: hdrTarget
        )
        XCTAssertFalse(result.isOutsideTargetGamut)
        XCTAssertFalse(result.isOutsideDisplayRange)
    }

    func testNegativeUnmappedChannelTriggersGamutWarningBeforeMapping() {
        let result = ColorDiagnostics.analyze(
            targetLinear: SIMD3(0.2, 0.4, 0.1),
            unmappedTargetLinear: SIMD3(-0.02, 0.5, 0.1),
            target: hdrTarget
        )
        XCTAssertTrue(result.isOutsideTargetGamut)
        XCTAssertFalse(result.isOutsideDisplayRange)
    }

    func testHighlightAndShadowClippingHaveDistinctRules() {
        let highlight = ColorDiagnostics.analyze(
            targetLinear: SIMD3(8, 0.5, 0.5),
            unmappedTargetLinear: SIMD3(8, 0.5, 0.5),
            target: hdrTarget
        )
        XCTAssertTrue(highlight.isHighlightClipped)
        XCTAssertFalse(highlight.isShadowClipped)

        let oneDarkChannel = ColorDiagnostics.analyze(
            targetLinear: SIMD3(0, 0.2, 0.2),
            unmappedTargetLinear: SIMD3(0, 0.2, 0.2),
            target: hdrTarget
        )
        XCTAssertFalse(oneDarkChannel.isShadowClipped)

        let allDark = ColorDiagnostics.analyze(
            targetLinear: SIMD3(repeating: 0.0005),
            unmappedTargetLinear: SIMD3(repeating: 0.0005),
            target: hdrTarget
        )
        XCTAssertTrue(allDark.isShadowClipped)
    }

    func testDisplayRangeIsSeparateFromGamut() {
        let result = ColorDiagnostics.analyze(
            targetLinear: SIMD3(8.1, 2, 2),
            unmappedTargetLinear: SIMD3(8.1, 2, 2),
            target: hdrTarget
        )
        XCTAssertFalse(result.isOutsideTargetGamut)
        XCTAssertTrue(result.isOutsideDisplayRange)
    }

    func testNegativeTargetValueIsOutsideDisplayRange() {
        let result = ColorDiagnostics.analyze(
            targetLinear: SIMD3(-0.01, 0.2, 0.2),
            unmappedTargetLinear: SIMD3(0.1, 0.2, 0.2),
            target: hdrTarget
        )
        XCTAssertTrue(result.isOutsideDisplayRange)
        XCTAssertFalse(result.isOutsideTargetGamut)
    }

    func testOverlayColorsCoverEveryDiagnosticMode() {
        let neutral = PixelDiagnostics(
            hdrZone: .sdr,
            isHighlightClipped: false,
            isShadowClipped: false,
            isOutsideTargetGamut: false,
            isOutsideDisplayRange: false
        )
        XCTAssertEqual(ColorDiagnostics.overlayColor(for: neutral, mode: .hdrZones).w, 0)

        let warning = PixelDiagnostics(
            hdrZone: .highlightAbove4,
            isHighlightClipped: true,
            isShadowClipped: true,
            isOutsideTargetGamut: true,
            isOutsideDisplayRange: true
        )
        for mode in DiagnosticOverlayMode.allCases where mode != .off {
            XCTAssertGreaterThan(ColorDiagnostics.overlayColor(for: warning, mode: mode).w, 0)
        }
        XCTAssertEqual(ColorDiagnostics.overlayColor(for: warning, mode: .off).w, 0)
    }

    func testSceneEntryPointUsesPreGamutValue() {
        var gamut = GamutMappingParameters()
        gamut.enabled = true
        let transform = TargetTransform(
            target: RenderingTarget(gamut: .sRGB),
            tone: ToneMappingParameters(),
            gamut: gamut
        )
        let result = ColorDiagnostics.analyze(
            sceneLinear: SIMD3(0.0, 0.8, 0.0),
            transform: transform
        )
        XCTAssertTrue(result.isOutsideTargetGamut)
    }

    private func analyze(_ value: Double) -> PixelDiagnostics {
        ColorDiagnostics.analyze(
            targetLinear: SIMD3(repeating: value),
            unmappedTargetLinear: SIMD3(repeating: value),
            target: hdrTarget
        )
    }
}
