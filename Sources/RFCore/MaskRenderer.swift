import Foundation
import CoreImage
import ImageIO

/// 遮罩以色彩引擎後、局部調整前的同一張影像計算，不受其他遮罩曝光牽動。
public final class MaskRenderer: @unchecked Sendable {
    private let gradient: CIColorKernel
    private let range: CIColorKernel
    private let finish: CIColorKernel
    private let exposure: CIColorKernel
    private let color: CIColorKernel
    private let tone: CIColorKernel
    private let blend: CIColorKernel
    private let spatial: SpatialRenderer
    public enum Failure: Error { case kernel, bitmap }

    public init() throws {
        func kernel(_ source: String) throws -> CIColorKernel {
            guard let k = CIColorKernel(source: source) else { throw Failure.kernel }
            return k
        }
        gradient = try kernel("""
        kernel vec4 gradient(vec2 start, vec2 end) {
            vec2 d = end - start;
            float n = dot(d, d);
            float w = n < 0.000001 ? 0.0 : clamp(dot(destCoord() - start, d) / max(n, 0.000001), 0.0, 1.0);
            return vec4(vec3(w), 1.0);
        }
        """)
        range = try kernel("""
        kernel vec4 rangeMask(__sample pixel, float kind, float low, float high, float feather, float hue, float width, float minSat) {
            vec3 rgb = max(pixel.rgb, vec3(0.0));
            float w = 0.0;
            if (kind < 0.5) {
                float ev = log2(max(dot(rgb, vec3(0.2627, 0.6780, 0.0593)), 0.000001) / 0.18);
                float d = max(low - ev, ev - high);
                w = 1.0 - smoothstep(0.0, max(feather * 4.0, 0.00001), max(d, 0.0));
            } else {
                float hi = max(max(rgb.r, rgb.g), rgb.b);
                float lo = min(min(rgb.r, rgb.g), rgb.b);
                float delta = hi - lo;
                float saturation = delta / max(hi, 0.000001);
                float h = 0.0;
                if (delta > 0.000001) {
                    if (hi == rgb.r) h = (rgb.g - rgb.b) / delta;
                    else if (hi == rgb.g) h = 2.0 + (rgb.b - rgb.r) / delta;
                    else h = 4.0 + (rgb.r - rgb.g) / delta;
                    h = mod(h * 60.0 + 360.0, 360.0);
                }
                float distance = abs(mod(h - hue + 540.0, 360.0) - 180.0);
                w = (1.0 - smoothstep(width, width + max(feather * 60.0, 0.00001), distance))
                    * step(max(minSat, 0.0001), saturation);
            }
            return vec4(vec3(w), 1.0);
        }
        """)
        finish = try kernel("""
        kernel vec4 finishMask(__sample m, float invert, float opacity) {
            float w = mix(clamp(m.r, 0.0, 1.0), 1.0 - clamp(m.r, 0.0, 1.0), invert) * opacity;
            return vec4(vec3(w), 1.0);
        }
        """)
        exposure = try kernel("""
        kernel vec4 expose(__sample image, __sample mask, float ev) {
            return vec4(image.rgb * exp2(mask.r * ev), image.a);
        }
        """)
        // 色相：以 Rodrigues 公式繞灰軸 (1,1,1) 旋轉，角度隨遮罩強度縮放。
        color = try kernel("""
        kernel vec4 localColor(__sample image, __sample mask, vec3 gains, float chroma, float hueShift) {
            float w = clamp(mask.r, 0.0, 1.0);
            vec3 balanced = image.rgb * mix(vec3(1.0), gains, w);
            float a = hueShift * w;
            vec3 k = vec3(0.57735027);
            balanced = balanced * cos(a) + cross(k, balanced) * sin(a) + k * dot(k, balanced) * (1.0 - cos(a));
            float luma = dot(balanced, vec3(0.2627, 0.6780, 0.0593));
            return vec4(mix(vec3(luma), balanced, 1.0 + (chroma - 1.0) * w), image.a);
        }
        """)
        // 以 18% 灰為 0 EV：對比繞中灰拉伸，亮部／陰影作用於中灰兩側，白色／黑色只動最亮／最暗段。
        tone = try kernel("""
        kernel vec4 localTone(__sample image, __sample mask, float contrast, float highlights,
                              float shadows, float whites, float blacks) {
            vec3 rgb = max(image.rgb, vec3(0.0));
            float y = dot(rgb, vec3(0.2627, 0.6780, 0.0593));
            float ev = clamp(log2(max(y, 0.000001) / 0.18), -12.0, 12.0);
            float shifted = ev * (1.0 + 0.5 * contrast)
                + highlights * 1.5 * smoothstep(0.0, 3.0, ev)
                + shadows * 1.5 * smoothstep(0.0, 3.0, -ev)
                + whites * smoothstep(1.5, 4.0, ev)
                + blacks * smoothstep(2.0, 5.0, -ev);
            float gain = exp2((shifted - ev) * clamp(mask.r, 0.0, 1.0));
            return vec4(image.rgb * gain, image.a);
        }
        """)
        blend = try kernel("""
        kernel vec4 blendMask(__sample image, __sample adjusted, __sample mask) {
            return mix(image, adjusted, clamp(mask.r, 0.0, 1.0));
        }
        """)
        spatial = try SpatialRenderer()
    }

    public func image(for mask: LocalMask, source: CIImage) throws -> CIImage {
        let extent = source.extent
        let raw: CIImage?
        switch mask.kind {
        case .gradient:
            func point(_ p: MaskPoint) -> CIVector {
                CIVector(x: extent.minX + p.x * extent.width, y: extent.minY + p.y * extent.height)
            }
            raw = gradient.apply(extent: extent, arguments: [point(mask.start), point(mask.end)])
        case .brush:
            raw = try brush(mask, extent: extent)
        case .luminance, .colorRange:
            raw = range.apply(extent: extent, arguments: [source, mask.kind == .luminance ? 0.0 : 1.0,
                min(mask.lowerEV, mask.upperEV), max(mask.lowerEV, mask.upperEV), bounded(mask.feather),
                mask.hue, min(max(mask.hueWidth, 0), 180), bounded(mask.minimumSaturation)])
        }
        guard let raw, let result = finish.apply(extent: extent, arguments: [raw,
            mask.inverted ? 1.0 : 0.0, bounded(mask.opacity)]) else { throw Failure.kernel }
        return result
    }

    public func apply(_ masks: [LocalMask], to source: CIImage) throws -> CIImage {
        var result = source
        for mask in masks where mask.hasActiveAdjustment {
            let weight = try image(for: mask, source: source)
            if mask.exposureEV != 0 {
                guard let next = exposure.apply(extent: source.extent,
                    arguments: [result, weight, min(max(mask.exposureEV, -5), 5)]) else { throw Failure.kernel }
                result = next
            }
            if mask.hasTone, let t = mask.toneAdjustment {
                guard let next = tone.apply(extent: source.extent, arguments: [result, weight,
                    unit(t.contrast), unit(t.highlights), unit(t.shadows), unit(t.whites), unit(t.blacks)])
                else { throw Failure.kernel }
                result = next
            }
            if mask.hasColor, let adjustment = mask.colorAdjustment {
                let temperature = min(max(adjustment.temperature, -3000), 3000)
                let tint = min(max(adjustment.tint, -100), 100)
                    / SceneNormalization.filterTintPerChromaticityUnit
                let gains = SceneNormalization.whiteBalanceGains(
                    temperature: 5000 + temperature, tint: tint,
                    asShotTemperature: 5000, asShotTint: 0)
                guard let next = color.apply(extent: source.extent, arguments: [result, weight,
                    CIVector(x: gains.x, y: gains.y, z: gains.z), min(max(adjustment.chroma, 0), 3),
                    min(max(adjustment.hueShift, -180), 180) * .pi / 180])
                else { throw Failure.kernel }
                result = next
            }
            // 效果要看鄰近像素：整張套用後再以遮罩強度與原圖混合（INV-2）。
            if mask.hasEffect, let e = mask.effectAdjustment {
                var p = SpatialFinishingParameters()
                p.texture = unit(e.texture); p.clarity = unit(e.clarity); p.dehaze = unit(e.dehaze)
                let full = try spatial.apply(p, to: result)
                guard let next = blend.apply(extent: source.extent, arguments: [result, full, weight])
                else { throw Failure.kernel }
                result = next
            }
        }
        return result
    }

    private func bounded(_ x: Double) -> Double { min(max(x, 0), 1) }
    private func unit(_ x: Double) -> Double { min(max(x, -1), 1) }

    private func brush(_ mask: LocalMask, extent: CGRect) throws -> CIImage {
        let width = Int(ceil(extent.width)), height = Int(ceil(extent.height))
        guard width > 0, height > 0, let ctx = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
        else { throw Failure.bitmap }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let data = mask.aiSelection {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.bitmap }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let short = min(extent.width, extent.height)
        for stroke in mask.strokes {
            guard let first = stroke.points.first else { continue }
            let radius = min(max(stroke.radius, 0.001), 0.5) * short
            let gray: CGFloat = stroke.erasing ? 0 : 1
            ctx.setStrokeColor(gray: gray, alpha: 1)
            ctx.setFillColor(gray: gray, alpha: 1)
            ctx.setLineWidth(radius * 2)
            let start = CGPoint(x: first.x * extent.width, y: first.y * extent.height)
            if stroke.points.count == 1 {
                ctx.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2))
            } else {
                ctx.beginPath(); ctx.move(to: start)
                for p in stroke.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * extent.width, y: p.y * extent.height)) }
                ctx.strokePath()
            }
        }
        guard let cg = ctx.makeImage() else { throw Failure.bitmap }
        var image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        if mask.feather > 0 {
            image = image.clampedToExtent().applyingFilter("CIGaussianBlur",
                parameters: [kCIInputRadiusKey: bounded(mask.feather) * short * 0.025])
        }
        return image.cropped(to: extent)
    }
}
