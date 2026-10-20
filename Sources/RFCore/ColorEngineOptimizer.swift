import Foundation
import CoreImage
import simd

/// 一張影像在 OKLab 下的彩度 / 亮度統計，供色彩引擎的一鍵最佳化使用。
public struct SceneColorStatistics: Equatable, Sendable {
    /// 中位亮度（OKLab L）。
    public var medianLightness: Double
    /// 第 90 百分位 chroma，代表「畫面裡最鮮的那一群顏色」有多鮮。
    public var p90Chroma: Double
    /// 亮度高於 `highlightThreshold` 的像素比例。
    public var highlightRatio: Double
    /// 落在膚色帶且有明顯彩度的像素比例。
    public var skinRatio: Double

    public init(medianLightness: Double, p90Chroma: Double,
                highlightRatio: Double, skinRatio: Double) {
        self.medianLightness = medianLightness
        self.p90Chroma = p90Chroma
        self.highlightRatio = highlightRatio
        self.skinRatio = skinRatio
    }
}

/// §5 Perceptual Color Engine 的一鍵最佳化。
///
/// 拆成「統計 → 建議 → 百分比混合」三段：統計與建議是純資料運算，
/// 沒有 GPU 也能測；取樣那一段才碰 Core Image。
public enum ColorEngineOptimizer {
    /// 判定為高光的 OKLab L 門檻。
    public static let highlightThreshold = 0.85
    /// 建議值想讓 p90 chroma 落在的位置：再鮮一點就開始有不自然的塊面。
    public static let referenceChroma = 0.12

    // MARK: - 統計

    /// 由 working space 的線性 RGB 取樣算統計值。輸入應為「已套白平衡與曝光、
    /// 但色彩引擎尚未作用」的 scene-referred 值。
    public static func statistics(samples: [SIMD3<Double>]) -> SceneColorStatistics {
        guard !samples.isEmpty else {
            return SceneColorStatistics(medianLightness: 0, p90Chroma: 0,
                                        highlightRatio: 0, skinRatio: 0)
        }
        let working = RGBColorSpace.workingRec2020
        var lightness: [Double] = []
        var chroma: [Double] = []
        var highlights = 0
        var skin = 0

        lightness.reserveCapacity(samples.count)
        chroma.reserveCapacity(samples.count)

        for rgb in samples {
            let lch = OKLab.toLCH(OKLab.fromXYZ(working.toXYZ(rgb)))
            lightness.append(lch.x)
            chroma.append(lch.y)
            if lch.x > highlightThreshold { highlights += 1 }
            if lch.y > 0.02 && SceneTransform.skinWeight(hue: lch.z) > 0.5 { skin += 1 }
        }

        let n = Double(samples.count)
        return SceneColorStatistics(
            medianLightness: percentile(lightness, 0.5),
            p90Chroma: percentile(chroma, 0.9),
            highlightRatio: Double(highlights) / n,
            skinRatio: Double(skin) / n
        )
    }

    /// 從 scene master 影像取一張小圖來統計。`transform` 用來套上白平衡與曝光。
    public static func statistics(
        image: CIImage, context: CIContext,
        transform: SceneTransform, maxDimension: Int = 96
    ) -> SceneColorStatistics {
        statistics(samples: samples(image: image, context: context, maxDimension: maxDimension)
            .map { transform.apply($0) })
    }

    /// 把影像縮到 `maxDimension` 以內，讀成 working space 的線性 RGB 取樣。
    public static func samples(
        image: CIImage, context: CIContext, maxDimension: Int = 96
    ) -> [SIMD3<Double>] {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return [] }

        let longest = max(extent.width, extent.height)
        let scale = min(1.0, CGFloat(maxDimension) / longest)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale),
                                      highQualityDownsample: true)
        let bounds = small.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { return [] }

        // 線性 Rec.2020 = working space，讀出來不必再做轉換。
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { return [] }
        let rowBytes = width * 4 * MemoryLayout<Float>.size
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                           bounds: bounds, format: .RGBAf, colorSpace: space)
        }

        var out: [SIMD3<Double>] = []
        out.reserveCapacity(width * height)
        for i in stride(from: 0, to: buffer.count, by: 4) {
            out.append(SIMD3(Double(buffer[i]), Double(buffer[i + 1]), Double(buffer[i + 2])))
        }
        return out
    }

    // MARK: - 建議與混合

    /// 依統計值給出建議參數。只動四個「保護 / 強度」欄位，光源與色帶維持使用者設定（INV-4）。
    public static func suggest(
        base: ColorEngineParameters, statistics s: SceneColorStatistics
    ) -> ColorEngineParameters {
        var p = base
        if s.p90Chroma > 1e-4 {
            p.chromaStrength = clamp(referenceChroma / s.p90Chroma, 0.7, 1.3)
        }
        // 高光越多，越需要收斂高光彩度，且提早開始收斂。
        let h = min(1.0, s.highlightRatio / 0.05)
        p.highlightProtection = clamp(0.35 + 0.55 * h, 0, 1)
        p.highlightProtectionStart = clamp(0.85 - 0.15 * h, 0.6, 0.9)
        // 膚色佔比越高，越不該讓色帶調整動到膚色。
        p.skinProtection = clamp(0.55 + 0.45 * min(1.0, s.skinRatio / 0.15), 0, 1)
        return p
    }

    /// 以百分比把建議值混回基準值。`amount` 0 = 完全不套用，1 = 完全套用。
    public static func blend(
        base: ColorEngineParameters, suggestion: ColorEngineParameters, amount: Double
    ) -> ColorEngineParameters {
        let t = clamp(amount, 0, 1)
        var p = base
        p.chromaStrength = lerp(base.chromaStrength, suggestion.chromaStrength, t)
        p.highlightProtection = lerp(base.highlightProtection, suggestion.highlightProtection, t)
        p.highlightProtectionStart = lerp(base.highlightProtectionStart,
                                          suggestion.highlightProtectionStart, t)
        p.skinProtection = lerp(base.skinProtection, suggestion.skinProtection, t)
        return p
    }

    // MARK: - 小工具

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[idx]
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
