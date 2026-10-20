import Foundation
import simd

/// §11 Human Layer C — Finishing 的逐像素色彩層。
///
/// 這一層刻意放在 `TargetTransform` 之後：Finishing 是「看著輸出結果修飾」，
/// 不是場景描述，所以作用在 display-referred 的編碼值上，並且和前面幾段一起
/// 烘焙進同一顆 LUT，預覽與輸出因此永遠一致（INV-3）。
///
/// 空間性的 Finishing（顆粒、暈影、銳化、清晰度）不能只看單一像素，
/// 不屬於這裡，見 A-032 design.md 的 M2。
public struct FinishingTransform: Sendable {
    public let parameters: FinishingParameters
    public let target: RenderingTarget

    public init(parameters: FinishingParameters, target: RenderingTarget) {
        self.parameters = parameters
        self.target = target
    }

    /// 三段調色輪的作用寬度（以正規化亮度為單位）。
    private static let wheelWidth = 0.3

    public func apply(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
        guard !parameters.isNeutral else { return encoded }

        var v = encoded
        v = parameters.curve.apply(v)
        v = applyContrast(v)
        v = applyWheels(v)
        return clampToTarget(v)
    }

    // MARK: - Final Contrast

    private func applyContrast(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let c = parameters.finalContrast
        guard c != 0 else { return v }
        return SIMD3(contrast(v.x, c), contrast(v.y, c), contrast(v.z, c))
    }

    /// Pivot 0.5 的對稱 S 曲線。HDR headroom（>1）的部分原樣保留，
    /// 否則調對比會把高光壓成 SDR。
    private func contrast(_ x: Double, _ c: Double) -> Double {
        let over = max(x - 1, 0)
        let base = min(max(x, 0), 1)
        let power = 1 + c
        let shaped = base < 0.5
            ? 0.5 * pow(2 * base, power)
            : 1 - 0.5 * pow(2 * (1 - base), power)
        return shaped + over
    }

    // MARK: - Color Grading

    /// 陰影 / 中間調 / 高光三輪，全部依亮度加權後疊加。
    private func applyWheels(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let p = parameters
        let grading = !(p.shadows.isNeutral && p.midtones.isNeutral && p.highlights.isNeutral)
        guard grading else { return v }

        let luma = min(max(0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z, 0), 1)
        // 平衡把中間調的中心往陰影或高光挪，三輪的分界因此可整體偏移。
        let pivot = min(max(0.5 + p.balance * 0.25, 0.1), 0.9)
        let ws = weight(luma, center: 0)
        let wm = weight(luma, center: pivot)
        let wh = weight(luma, center: 1)

        // 亮度偏移直接加在編碼值上，維持三輪各自的作用範圍。
        var out = v
        let lift = p.shadows.luminance * ws + p.midtones.luminance * wm + p.highlights.luminance * wh
        if lift != 0 { out += SIMD3(repeating: lift * 0.3) }

        // 色彩偏移在 OKLab 的 a/b 上相加。這裡的 OKLab 讀的是編碼值，
        // 是 display-referred 修飾的慣例；scene-referred 的色彩科學在 §5 那一層。
        var tint = SIMD2<Double>(0, 0)
        func add(_ hue: Double, _ amount: Double, _ w: Double) {
            guard amount != 0, w > 1e-6 else { return }
            let r = hue * .pi / 180
            tint += SIMD2(cos(r), sin(r)) * (amount * w)
        }
        add(p.shadows.hue, p.shadows.amount, ws)
        add(p.midtones.hue, p.midtones.amount, wm)
        add(p.highlights.hue, p.highlights.amount, wh)

        guard tint != SIMD2(0, 0) else { return out }
        let space = target.gamut.colorSpace
        var lab = OKLab.fromXYZ(space.toXYZ(out))
        lab.y += tint.x
        lab.z += tint.y
        return space.fromXYZ(OKLab.toXYZ(lab))
    }

    private func weight(_ luma: Double, center: Double) -> Double {
        let d = (luma - center) / Self.wheelWidth
        return exp(-d * d)
    }

    // MARK: - 邊界

    private func clampToTarget(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let ceiling = target.transferFunction == .linear ? max(target.contentHeadroom, 1) : 1
        func c(_ x: Double) -> Double { min(max(x, 0), ceiling) }
        return SIMD3(c(v.x), c(v.y), c(v.z))
    }
}
