import Foundation
import CoreImage

/// §11 Layer C — Finishing 的空間性效果（A-033 M2）。
///
/// 這一段要看鄰近像素或像素座標，同樣的輸入顏色不一定得到同樣的輸出顏色，
/// 所以進不了 3D LUT，必須接在 LUT 之後、以整張影像為單位處理。
/// 預覽（proxy 縮圖）與全解析度輸出走的是同一支 `apply`，
/// 半徑一律以影像短邊的比例換算，兩邊看起來才會一致。
public final class SpatialRenderer: @unchecked Sendable {
    public enum Failure: Error { case kernel }

    private let darkChannel: CIColorKernel
    private let dehaze: CIColorKernel
    private let detail: CIColorKernel
    private let detailOffsets: CIColorKernel
    private let glowMask: CIColorKernel
    private let glowAdd: CIColorKernel
    private let vignette: CIColorKernel
    private let grain: CIColorKernel
    private let randomGrain: CIColorKernel

    /// Rec.2020 亮度權重，與 pipeline 其他地方一致。
    private static let luma = "vec3(0.2627, 0.6780, 0.0593)"

    public init() throws {
        func kernel(_ source: String) throws -> CIColorKernel {
            guard let k = CIColorKernel(source: source) else { throw Failure.kernel }
            return k
        }

        darkChannel = try kernel("""
        kernel vec4 darkChannel(__sample p) {
            vec3 c = max(p.rgb, vec3(0.0));
            return vec4(vec3(min(min(c.r, c.g), c.b)), 1.0);
        }
        """)

        // 正值：把估出來的白霧從畫面扣掉，再除以剩下的透射率把對比拉回來。
        // 負值：往白色混，等於加霧。
        dehaze = try kernel("""
        kernel vec4 dehaze(__sample src, __sample haze, float amount) {
            vec3 c = max(src.rgb, vec3(0.0));
            if (amount >= 0.0) {
                float veil = amount * 0.5 * clamp(haze.r, 0.0, 1.0);
                return vec4(max(c - vec3(veil), vec3(0.0)) / max(1.0 - veil, 0.2), src.a);
            }
            return vec4(mix(c, vec3(1.0), -amount * 0.4), src.a);
        }
        """)

        // 原圖減模糊版得到細節，只加回亮度方向，避免邊緣出現彩色鑲邊。
        detail = try kernel("""
        kernel vec4 detail(__sample src, __sample blurred, float amount, vec3 tones) {
            vec3 c = max(src.rgb, vec3(0.0));
            float l = dot(c, \(Self.luma));
            float lb = dot(max(blurred.rgb, vec3(0.0)), \(Self.luma));
            // 依周圍平均亮度分配暗部／中間調／亮部比例；三項權重總和恆為 1。
            float t = clamp(lb, 0.0, 1.0);
            float w = dot(tones, vec3((1.0 - t) * (1.0 - t), 2.0 * t * (1.0 - t), t * t));
            return vec4(max(c + vec3((l - lb) * amount * w), vec3(0.0)), src.a);
        }
        """)

        // 新版清晰度把全域總值與三個分區加減量合併後，再限制每個像素的作用量。
        detailOffsets = try kernel("""
        kernel vec4 detailOffsets(__sample src, __sample blurred, float amount, vec3 offsets) {
            vec3 c = max(src.rgb, vec3(0.0));
            float l = dot(c, \(Self.luma));
            float lb = dot(max(blurred.rgb, vec3(0.0)), \(Self.luma));
            float t = clamp(lb, 0.0, 1.0);
            vec3 weights = vec3((1.0 - t) * (1.0 - t), 2.0 * t * (1.0 - t), t * t);
            float action = clamp(amount + dot(offsets, weights), -1.0, 1.0);
            return vec4(max(c + vec3((l - lb) * action), vec3(0.0)), src.a);
        }
        """)

        // 只取超過門檻的那一部分高光，保留原本的顏色比例。
        glowMask = try kernel("""
        kernel vec4 glowMask(__sample p, float threshold) {
            vec3 c = max(p.rgb, vec3(0.0));
            float l = dot(c, \(Self.luma));
            float w = max(l - threshold, 0.0);
            return vec4(l > 0.000001 ? c * (w / l) : vec3(0.0), 1.0);
        }
        """)

        // 加法疊回去，不在 1.0 夾值，HDR 的高光才不會被壓掉。
        glowAdd = try kernel("""
        kernel vec4 glowAdd(__sample src, __sample glow, float amount) {
            return vec4(max(src.rgb, vec3(0.0)) + max(glow.rgb, vec3(0.0)) * amount, src.a);
        }
        """)

        vignette = try kernel("""
        kernel vec4 vignette(__sample p, vec2 center, float halfDiagonal,
                             float midpoint, float feather, float amount) {
            float r = length(destCoord() - center) / max(halfDiagonal, 1.0);
            float lo = midpoint * (1.0 - feather);
            float hi = midpoint + (1.0 - midpoint) * feather;
            float w = smoothstep(lo, max(hi, lo + 0.001), r);
            return vec4(max(p.rgb, vec3(0.0)) * max(1.0 - amount * w, 0.0), p.a);
        }
        """)

        // 以像素座標雜湊出雜訊，再雙線性平滑成可調大小的顆粒。
        // 強度隨亮度呈鐘形：純黑與純白幾乎沒有顆粒，中間調最明顯。
        grain = try kernel("""
        float rfHash(vec2 p) {
            return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
        }
        kernel vec4 grain(__sample p, float cell, float amount, float strength) {
            vec2 c = destCoord() / max(cell, 1.0);
            vec2 i = floor(c);
            vec2 f = c - i;
            f = f * f * (3.0 - 2.0 * f);
            float n = mix(mix(rfHash(i), rfHash(i + vec2(1.0, 0.0)), f.x),
                          mix(rfHash(i + vec2(0.0, 1.0)), rfHash(i + vec2(1.0, 1.0)), f.x), f.y) - 0.5;
            vec3 rgb = max(p.rgb, vec3(0.0));
            float l = clamp(dot(rgb, \(Self.luma)), 0.0, 1.0);
            float w = 4.0 * l * (1.0 - l);
            return vec4(max(rgb + vec3(n * amount * strength * w), vec3(0.0)), p.a);
        }
        """)
        // 每個區域的顆粒中心、半徑、正負亮度各自雜湊；鄰區可跨界重疊。
        // 以相對影像原點的座標生成，重算同一設定保持穩定。
        randomGrain = try kernel("""
        float rfRandom(vec2 p) {
            return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
        }
        kernel vec4 randomGrain(__sample p, vec2 origin, float cell,
                                float amount, float strength) {
            vec2 c = (destCoord() - origin) / cell;
            vec2 base = floor(c);
            float n = 0.0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    vec2 i = base + vec2(float(x), float(y));
                    vec2 center = i + vec2(0.1 + 0.8 * rfRandom(i + vec2(17.0, 3.0)),
                                          0.1 + 0.8 * rfRandom(i + vec2(5.0, 29.0)));
                    float radius = 0.18 + 0.42 * rfRandom(i + vec2(43.0, 11.0));
                    float weight = 1.0 - smoothstep(0.0, radius, length(c - center));
                    n += (rfRandom(i + vec2(7.0, 53.0)) - 0.5) * weight;
                }
            }
            vec3 rgb = max(p.rgb, vec3(0.0));
            float l = clamp(dot(rgb, \(Self.luma)), 0.0, 1.0);
            float w = 4.0 * l * (1.0 - l);
            return vec4(max(rgb + vec3(n * amount * strength * w), vec3(0.0)), p.a);
        }
        """)
    }

    /// 空間效果從一個輸出像素往外讀取的最遠距離（像素）。只渲染局部時，輸入至少要比
    /// 局部多留這麼寬，結果才會和整張渲染後裁切相同；暗角與顆粒只看座標，不需要邊界。
    public func sampleMargin(_ parameters: SpatialFinishingParameters, extent: CGRect) -> CGFloat {
        guard !parameters.isNeutral, extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return 0 }
        let short = Double(min(extent.width, extent.height))
        // Gaussian 在 4 倍半徑外的權重已低於 8-bit 可見差異
        let support = 4.0
        var margin = 0.0
        if parameters.dehaze > 0 {
            let patch = max(short * 0.04, 1)
            margin += patch + support * patch
        }
        if parameters.hasClarity { margin += support * short * 0.025 }
        if parameters.texture != 0 { margin += support * short * 0.004 }
        if !parameters.sharpening.isNeutral {
            margin += support * short * 0.002 * (0.2 + 0.8 * clamp(parameters.sharpening.radius, 0, 1)) + 2
        }
        if !parameters.glow.isNeutral {
            margin += support * max(short * 0.08 * clamp(parameters.glow.radius, 0, 1), 1)
        }
        return CGFloat(margin.rounded(.up) + 2)
    }

    /// 套用所有空間性效果。中性參數直接回傳輸入影像，連一道 filter 都不掛（INV-1）。
    /// `globalExtent` 是整張輸出影像的範圍：輸入只是其中一塊（含 `sampleMargin` 邊界）時，
    /// 效果半徑、暗角中心與顆粒座標仍依整張計算。
    public func apply(_ parameters: SpatialFinishingParameters, to image: CIImage,
                      globalExtent: CGRect? = nil) throws -> CIImage {
        guard !parameters.isNeutral else { return image }
        let extent = globalExtent ?? image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let short = Double(min(extent.width, extent.height))

        var out = image
        if parameters.dehaze != 0 {
            out = try applyDehaze(parameters.dehaze, to: out, extent: extent, short: short)
        }
        if parameters.hasClarity {
            if let offsets = parameters.clarityOffsets {
                out = try applyDetailOffsets(parameters.clarity, radius: short * 0.025,
                                             offsets: CIVector(x: offsets.shadows, y: offsets.midtones, z: offsets.highlights),
                                             to: out, extent: extent)
            } else {
                let t = parameters.clarityTones
                out = try applyDetail(parameters.clarity, radius: short * 0.025,
                                      tones: CIVector(x: clamp(t.shadows, -1, 1), y: clamp(t.midtones, -1, 1),
                                                      z: clamp(t.highlights, -1, 1)),
                                      to: out, extent: extent)
            }
        }
        if parameters.texture != 0 {
            out = try applyDetail(parameters.texture, radius: short * 0.004,
                                  to: out, extent: extent)
        }
        if !parameters.sharpening.isNeutral {
            out = applySharpening(parameters.sharpening, to: out, extent: extent, short: short)
        }
        if !parameters.glow.isNeutral {
            out = try applyGlow(parameters.glow, to: out, extent: extent, short: short)
        }
        if !parameters.vignette.isNeutral {
            out = try applyVignette(parameters.vignette, to: out, extent: extent)
        }
        if !parameters.grain.isNeutral {
            out = try applyGrain(parameters.grain, to: out, extent: extent, short: short)
        }
        return out
    }

    // MARK: - 各效果

    private func applyDehaze(_ amount: Double, to image: CIImage,
                             extent: CGRect, short: Double) throws -> CIImage {
        let amount = clamp(amount, -1, 1)
        guard amount > 0 else {
            guard let out = dehaze.apply(extent: extent, arguments: [image, image, amount]) else {
                throw Failure.kernel
            }
            return out.cropped(to: extent)
        }
        guard let dark = darkChannel.apply(extent: extent, arguments: [image]) else {
            throw Failure.kernel
        }
        // 先取區域最小值再模糊，得到一張低頻的「霧有多濃」估計圖。
        let patch = max(short * 0.04, 1)
        let veil = blur(
            dark.clampedToExtent().applyingFilter("CIMorphologyMinimum",
                                                  parameters: [kCIInputRadiusKey: patch]),
            radius: patch, extent: extent
        )
        guard let out = dehaze.apply(extent: extent, arguments: [image, veil, amount]) else {
            throw Failure.kernel
        }
        return out.cropped(to: extent)
    }

    private func applyDetail(_ amount: Double, radius: Double, tones: CIVector = CIVector(x: 1, y: 1, z: 1),
                             to image: CIImage, extent: CGRect) throws -> CIImage {
        let blurred = blur(image.clampedToExtent(), radius: radius, extent: extent)
        guard let out = detail.apply(extent: extent,
                                     arguments: [image, blurred, clamp(amount, -1, 1), tones]) else {
            throw Failure.kernel
        }
        return out.cropped(to: extent)
    }

    private func applyDetailOffsets(_ amount: Double, radius: Double, offsets: CIVector,
                                    to image: CIImage, extent: CGRect) throws -> CIImage {
        let blurred = blur(image.clampedToExtent(), radius: radius, extent: extent)
        guard let out = detailOffsets.apply(extent: extent,
                                            arguments: [image, blurred, amount, offsets]) else {
            throw Failure.kernel
        }
        return out.cropped(to: extent)
    }

    private func applySharpening(_ p: SharpeningParameters, to image: CIImage,
                                 extent: CGRect, short: Double) -> CIImage {
        // 半徑同樣依短邊比例換算：4000 px 的長邊約落在 3 px，屬於正常的銳化半徑。
        let radius = short * 0.002 * (0.2 + 0.8 * clamp(p.radius, 0, 1))
        return image.clampedToExtent()
            .applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": clamp(p.amount, 0, 1) * 1.2,
                kCIInputRadiusKey: radius,
            ])
            .cropped(to: extent)
    }

    private func applyGlow(_ p: GlowParameters, to image: CIImage,
                           extent: CGRect, short: Double) throws -> CIImage {
        guard let highlights = glowMask.apply(extent: extent,
                                              arguments: [image, max(p.threshold, 0)]) else {
            throw Failure.kernel
        }
        let spread = blur(highlights.clampedToExtent(),
                          radius: max(short * 0.08 * clamp(p.radius, 0, 1), 1), extent: extent)
        guard let out = glowAdd.apply(extent: extent,
                                      arguments: [image, spread, clamp(p.amount, 0, 1)]) else {
            throw Failure.kernel
        }
        return out.cropped(to: extent)
    }

    private func applyVignette(_ p: VignetteParameters, to image: CIImage,
                               extent: CGRect) throws -> CIImage {
        let center = CIVector(x: extent.midX, y: extent.midY)
        let halfDiagonal = sqrt(pow(extent.width / 2, 2) + pow(extent.height / 2, 2))
        guard let out = vignette.apply(extent: extent, arguments: [
            image, center, halfDiagonal,
            clamp(p.midpoint, 0, 1), clamp(p.feather, 0, 1), clamp(p.amount, -1, 1),
        ]) else { throw Failure.kernel }
        return out.cropped(to: extent)
    }

    private func applyGrain(_ p: GrainParameters, to image: CIImage,
                            extent: CGRect, short: Double) throws -> CIImage {
        let cell = max(short * 0.004 * clamp(p.size, 0, 1), 1)
        let strength = 0.06 + 0.10 * clamp(p.roughness, 0, 1)
        let out: CIImage?
        if p.randomized {
            out = randomGrain.apply(extent: extent, arguments: [
                image, CIVector(x: extent.minX, y: extent.minY), cell,
                clamp(p.amount, 0, 1), strength,
            ])
        } else {
            out = grain.apply(extent: extent, arguments: [
                image, cell, clamp(p.amount, 0, 1), strength,
            ])
        }
        guard let out else { throw Failure.kernel }
        return out.cropped(to: extent)
    }

    // MARK: - 小工具

    private func blur(_ image: CIImage, radius: Double, extent: CGRect) -> CIImage {
        guard radius > 0.01 else { return image.cropped(to: extent) }
        return image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
}
