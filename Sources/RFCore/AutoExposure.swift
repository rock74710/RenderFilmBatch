import Foundation
import CoreImage

/// Estimates one global exposure correction from scene-linear RGB before tone mapping.
public enum AutoExposure {
    public struct Result: Equatable, Sendable {
        public let ev: Double
        public let medianLuminance: Double?
        public let highlightLuminance: Double?
        public let validPixelCount: Int

        public var usedFallback: Bool { validPixelCount == 0 }
    }

    /// Works on a bounded proxy so a full-resolution batch cannot allocate a full float image.
    /// `weights` is an optional single-channel metering map in the same coordinates as `image`;
    /// the median is weighted by it, while highlight protection stays global.
    public static func analyze(_ image: CIImage, context: CIContext, weights: CIImage? = nil) -> Result {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            return Result(ev: 0, medianLuminance: nil, highlightLuminance: nil, validPixelCount: 0)
        }

        let scale = min(1, 512 / max(extent.width, extent.height))
        let width = max(1, Int(ceil(extent.width * scale)))
        let height = max(1, Int(ceil(extent.height * scale)))
        let pixels = render(image, extent: extent, scale: scale, width: width, height: height,
                            context: context)
        guard let weights else { return analyzeRGBA(pixels) }
        // Masks are coverage values, not colors; keep them out of color management.
        let weightPixels = render(weights, extent: extent, scale: scale, width: width, height: height,
                                  context: context, colorSpace: nil)
        return analyzeRGBA(pixels, weights: stride(from: 0, to: weightPixels.count, by: 4).map { weightPixels[$0] })
    }

    /// Renders a proxy of `image` in the same bounds as the metering pass so weights line up per pixel.
    static func render(_ image: CIImage, extent: CGRect, scale: CGFloat, width: Int, height: Int,
                       context: CIContext,
                       colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)) -> [Float] {
        let normalized = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(normalized, toBitmap: bytes.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf,
                           colorSpace: colorSpace)
        }
        return pixels
    }

    /// RGBA float samples in linear Rec.2020. Exposed for deterministic tests.
    public static func analyzeRGBA(_ pixels: [Float], weights: [Float]? = nil) -> Result {
        var luminances: [Double] = []
        var weighted: [(luminance: Double, weight: Double)] = []
        luminances.reserveCapacity(pixels.count / 4)
        for index in stride(from: 0, to: pixels.count - pixels.count % 4, by: 4) {
            let r = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let b = Double(pixels[index + 2])
            let a = Double(pixels[index + 3])
            guard r.isFinite, g.isFinite, b.isFinite, a.isFinite, a > 0 else { continue }
            let y = 0.2627 * r + 0.6780 * g + 0.0593 * b
            guard y.isFinite, y > 0.00001 else { continue }
            luminances.append(y)
            if let weights, index / 4 < weights.count {
                let w = Double(weights[index / 4])
                if w.isFinite, w > 0 { weighted.append((y, w)) }
            }
        }
        guard !luminances.isEmpty else {
            return Result(ev: 0, medianLuminance: nil, highlightLuminance: nil, validPixelCount: 0)
        }
        luminances.sort()
        let median = weightedMedian(weighted) ?? luminances[luminances.count / 2]
        let highlight = luminances[min(luminances.count - 1, Int(Double(luminances.count) * 0.99))]
        var ev = min(max(log2(0.18 / median), -2), 2)
        if ev > 0 {
            ev = min(ev, max(0, log2(0.98 / highlight)))
        }
        return Result(ev: ev, medianLuminance: median,
                      highlightLuminance: highlight, validPixelCount: luminances.count)
    }

    /// Nil when no sample carries weight, so an empty metering map falls back to the plain median.
    static func weightedMedian(_ samples: [(luminance: Double, weight: Double)]) -> Double? {
        let total = samples.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var accumulated = 0.0
        for sample in samples.sorted(by: { $0.luminance < $1.luminance }) {
            accumulated += sample.weight
            if accumulated >= total / 2 { return sample.luminance }
        }
        return samples.last?.luminance
    }

    /// Sky is only ever darkened: after the global EV it should sit about 1.5 EV above middle gray,
    /// so clouds keep texture instead of following the subject into clipping.
    public static func skyEV(skyMedian: Double, globalEV: Double) -> Double {
        guard skyMedian.isFinite, skyMedian > 0 else { return 0 }
        let target = 0.18 * exp2(1.5)
        return min(0, max(-2, log2(target / (skyMedian * exp2(globalEV)))))
    }

    /// Scene-linear exposure inside a feathered mask; linear light makes this a plain gain blend.
    public static func applyRegionalEV(_ ev: Double, mask: CIImage, to image: CIImage) -> CIImage {
        let feather = max(image.extent.width, image.extent.height) * 0.01
        let soft = mask.clampedToExtent()
            .applyingGaussianBlur(sigma: feather)
            .cropped(to: image.extent)
        let exposed = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        return exposed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: soft,
        ]).cropped(to: image.extent)
    }
}
