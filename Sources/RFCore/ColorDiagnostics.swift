import Foundation
import simd

/// 相對於 target 的 SDR reference white 分區。
public enum HDRZone: Equatable, Sendable {
    case sdr
    case highlight1To2
    case highlight2To4
    case highlightAbove4
}

/// 預覽可選的單一診斷覆蓋模式。這是暫時顯示狀態，不屬於編輯參數。
public enum DiagnosticOverlayMode: String, CaseIterable, Equatable, Sendable {
    case off
    case hdrZones
    case gamutWarning
    case highlightClipping
    case shadowClipping
    case displayRange
}

/// 逐像素診斷使用的容差與陰影門檻。
public struct DiagnosticThresholds: Equatable, Sendable {
    /// mapping 前 RGB 通道低於此負值時視為超出目標色域。
    public var gamutTolerance: Double
    /// 所有 target-linear RGB 通道都低於此值時視為陰影 clipping。
    public var shadowThreshold: Double

    public init(gamutTolerance: Double = 1e-4, shadowThreshold: Double = 0.001) {
        self.gamutTolerance = gamutTolerance
        self.shadowThreshold = shadowThreshold
    }
}

/// 一個像素在指定 rendering target 上的診斷結果。
public struct PixelDiagnostics: Equatable, Sendable {
    public let hdrZone: HDRZone
    public let isHighlightClipped: Bool
    public let isShadowClipped: Bool
    public let isOutsideTargetGamut: Bool
    public let isOutsideDisplayRange: Bool

    public init(
        hdrZone: HDRZone,
        isHighlightClipped: Bool,
        isShadowClipped: Bool,
        isOutsideTargetGamut: Bool,
        isOutsideDisplayRange: Bool
    ) {
        self.hdrZone = hdrZone
        self.isHighlightClipped = isHighlightClipped
        self.isShadowClipped = isShadowClipped
        self.isOutsideTargetGamut = isOutsideTargetGamut
        self.isOutsideDisplayRange = isOutsideDisplayRange
    }
}

/// 對 target-linear 顏色或 scene-linear 像素計算診斷資訊。
public enum ColorDiagnostics {
    /// 與批次 renderer 相同的顏色規則；公開純函式供 UI 圖例與單元測試共用。
    public static func overlayColor(
        for diagnostics: PixelDiagnostics,
        mode: DiagnosticOverlayMode
    ) -> SIMD4<Double> {
        switch mode {
        case .off:
            return .zero
        case .hdrZones:
            switch diagnostics.hdrZone {
            case .sdr: return .zero
            case .highlight1To2: return SIMD4(0.1, 0.45, 1.0, 0.42)
            case .highlight2To4: return SIMD4(1.0, 0.75, 0.05, 0.48)
            case .highlightAbove4: return SIMD4(1.0, 0.2, 0.05, 0.58)
            }
        case .gamutWarning:
            return diagnostics.isOutsideTargetGamut ? SIMD4(1.0, 0.0, 1.0, 0.62) : .zero
        case .highlightClipping:
            return diagnostics.isHighlightClipped ? SIMD4(1.0, 0.05, 0.05, 0.68) : .zero
        case .shadowClipping:
            return diagnostics.isShadowClipped ? SIMD4(0.05, 0.2, 1.0, 0.68) : .zero
        case .displayRange:
            return diagnostics.isOutsideDisplayRange ? SIMD4(1.0, 1.0, 0.0, 0.62) : .zero
        }
    }

    /// 分析既有的 target-linear RGB；gamut 判定讀取 mapping 前的值。
    public static func analyze(
        targetLinear: SIMD3<Double>,
        unmappedTargetLinear: SIMD3<Double>,
        target: RenderingTarget,
        thresholds: DiagnosticThresholds = DiagnosticThresholds()
    ) -> PixelDiagnostics {
        let luminance = target.gamut.colorSpace.toXYZ(targetLinear).y
        let hdrZone: HDRZone
        if luminance <= 1 {
            hdrZone = .sdr
        } else if luminance <= 2 {
            hdrZone = .highlight1To2
        } else if luminance <= 4 {
            hdrZone = .highlight2To4
        } else {
            hdrZone = .highlightAbove4
        }

        let headroom = target.contentHeadroom
        return PixelDiagnostics(
            hdrZone: hdrZone,
            isHighlightClipped: targetLinear.max() >= headroom,
            isShadowClipped: targetLinear.max() < thresholds.shadowThreshold,
            isOutsideTargetGamut: unmappedTargetLinear.min() < -thresholds.gamutTolerance,
            isOutsideDisplayRange: targetLinear.min() < 0 || targetLinear.max() > headroom
        )
    }

    /// 分析 scene-linear 像素，沿用 transform 的 tone mapping 與 gamut mapping 計算。
    public static func analyze(
        sceneLinear: SIMD3<Double>,
        transform: TargetTransform,
        thresholds: DiagnosticThresholds = DiagnosticThresholds()
    ) -> PixelDiagnostics {
        let unmappedTargetLinear = transform.targetLinear(
            sceneLinear,
            applyGamutMapping: false
        )
        let targetLinear = transform.targetLinear(sceneLinear)
        return analyze(
            targetLinear: targetLinear,
            unmappedTargetLinear: unmappedTargetLinear,
            target: transform.target,
            thresholds: thresholds
        )
    }
}
