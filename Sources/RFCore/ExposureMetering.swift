import Foundation
import CoreImage
import Vision

/// Scene-aware metering for batch auto exposure: Vision decides *where* to meter,
/// `AutoExposure` still decides *how much* EV. Every source is optional; a missing one only
/// removes its weight, so a failed request degrades to plain global metering.
public enum ExposureMetering {
    public struct Weights: Sendable {
        public var global: Float = 0.25
        public var saliency: Float = 1
        public var subject: Float = 2
        public var face: Float = 4
        /// Sky is metered separately, so it is kept out of the global median.
        public var sky: Float = 0.05
        public init() {}
    }

    public struct Map: @unchecked Sendable {
        /// Single-channel weights in the analyzed image's coordinates.
        public let weights: CIImage
        /// Nil when no sky was found or the OS lacks iterative segmentation.
        public let sky: CIImage?
        public let sources: [String]
    }

    /// Vision runs on a bounded proxy; masks are scaled back to `image.extent`.
    public static func map(for image: CIImage, context: CIContext,
                           weights: Weights = Weights(), detectSky: Bool = true) async -> Map {
        let extent = image.extent.integral
        let scale = min(1, 1024 / max(extent.width, extent.height, 1))
        let proxy = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Vision expects display-like input; render once so every request sees the same pixels.
        guard let cgProxy = context.createCGImage(proxy, from: proxy.extent,
                                                  format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            return Map(weights: constant(weights.global, extent: extent), sky: nil, sources: [])
        }

        var sources: [String] = []
        var map = constant(weights.global, extent: proxy.extent)
        func add(_ mask: CIImage?, weight: Float, name: String) {
            guard let mask else { return }
            let scaled = fit(mask, to: proxy.extent).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(weight), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            map = scaled.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: map])
            sources.append(name)
        }
        add(saliency(cgProxy), weight: weights.saliency, name: "saliency")
        add(subject(cgProxy), weight: weights.subject, name: "subject")
        add(faces(cgProxy, extent: proxy.extent), weight: weights.face, name: "face")

        var sky: CIImage?
        if detectSky, #available(macOS 27.0, *) {
            sky = await SkySegmentation.mask(cgProxy)
        }
        if let sky {
            // Where the sky is, replace whatever weight was there with the small sky weight.
            let skyWeight = constant(weights.sky, extent: proxy.extent)
            map = skyWeight.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: map, kCIInputMaskImageKey: fit(sky, to: proxy.extent),
            ])
            sources.append("sky")
        }

        let back = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return Map(weights: map.cropped(to: proxy.extent).transformed(by: back),
                   sky: sky.map { fit($0, to: proxy.extent).transformed(by: back) },
                   sources: sources)
    }

    private static func saliency(_ image: CGImage) -> CIImage? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
    }

    private static func subject(_ image: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first, !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler) else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    private static func faces(_ image: CGImage, extent: CGRect) -> CIImage? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }
        var result = constant(0, extent: extent)
        for face in faces {
            let box = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            result = constant(1, extent: box).composited(over: result)
        }
        return result.cropped(to: extent)
    }

    static func constant(_ value: Float, extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(value), green: 0, blue: 0)).cropped(to: extent)
    }

    /// Vision masks come back at their own resolution; stretch them onto the proxy grid.
    static func fit(_ mask: CIImage, to extent: CGRect) -> CIImage {
        guard mask.extent.width > 0, mask.extent.height > 0 else { return mask }
        return mask
            .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                               y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}

/// macOS 27 iterative segmentation seeded from the top edge. A result only counts as sky when it
/// is mostly in the upper half and covers a meaningful area; otherwise the frame has no sky layer.
@available(macOS 27.0, *)
enum SkySegmentation {
    static func mask(_ image: CGImage) async -> CIImage? {
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.95))
        request.qualityLevel = .balanced
        do {
            try request.addIncludedPoint(NormalizedPoint(x: 0.15, y: 0.92))
            try request.addIncludedPoint(NormalizedPoint(x: 0.85, y: 0.92))
            try request.addExcludedPoint(NormalizedPoint(x: 0.5, y: 0.1))
            if case .ready = await request.assetStatus {} else { try await request.downloadAssets() }
            guard let observation = try await request.perform(on: image) else { return nil }
            let mask = CIImage(cgImage: try observation.cgImage)
            return isPlausibleSky(mask) ? mask : nil
        } catch {
            return nil
        }
    }

    static func isPlausibleSky(_ mask: CIImage) -> Bool {
        let extent = mask.extent
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func mean(_ rect: CGRect) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            let average = mask.applyingFilter("CIAreaAverage",
                                              parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            context.render(average, toBitmap: &pixel, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return pixel[0]
        }
        let upper = mean(CGRect(x: extent.minX, y: extent.midY, width: extent.width, height: extent.height / 2))
        let lower = mean(CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2))
        let coverage = (upper + lower) / 2
        return coverage > 0.05 && coverage < 0.8 && upper > lower * 2
    }
}
