import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case encodingFailed(String)
    case invalidResize(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let f): return String(localized: "不支援的輸出格式：\(f)", bundle: .module)
        case .encodingFailed(let m): return String(localized: "輸出編碼失敗：\(m)", bundle: .module)
        case .invalidResize(let m): return String(localized: "無效的輸出尺寸：\(m)", bundle: .module)
        }
    }
}

/// §19 輸出。基本格式共用 display-referred 路徑；scene-linear master 明確繞過 target transform。
public struct Exporter: Sendable {
    public struct Resize: Sendable, Equatable {
        public enum Mode: String, Sendable {
            case longEdge
            case percent
        }

        public let mode: Mode
        public let value: Double
        public let dontEnlarge: Bool

        public init(mode: Mode, value: Double, dontEnlarge: Bool = false) {
            self.mode = mode
            self.value = value
            self.dontEnlarge = dontEnlarge
        }
    }

    public enum Format: String, CaseIterable, Sendable {
        case heic
        case jpeg
        case jpegHDR
        case tiff
        case tiff16
        case tiffFloat
        case sceneLinearTIFF
        case png

        public var utType: UTType {
            switch self {
            case .heic: .heic
            case .jpeg, .jpegHDR: .jpeg
            case .tiff, .tiff16, .tiffFloat, .sceneLinearTIFF: .tiff
            case .png: .png
            }
        }

        public var fileExtension: String {
            switch self {
            case .heic: "heic"
            case .jpeg, .jpegHDR: "jpg"
            case .tiff, .tiff16, .tiffFloat, .sceneLinearTIFF: "tiff"
            case .png: "png"
            }
        }

        public var displayName: String {
            switch self {
            case .heic: "HEIC / HEIF"
            case .jpeg: "JPEG"
            case .jpegHDR: "JPEG HDR（Gain Map）"
            case .tiff: "TIFF"
            case .tiff16: "TIFF 16-bit HDR"
            case .tiffFloat: "TIFF 32-bit Float"
            case .sceneLinearTIFF: "Scene-linear Master（TIFF Float）"
            case .png: "PNG"
            }
        }

        public var supportsHDR: Bool {
            switch self {
            case .heic, .jpegHDR, .tiff16, .tiffFloat, .sceneLinearTIFF: true
            case .jpeg, .tiff, .png: false
            }
        }

        public var isSceneLinear: Bool { self == .sceneLinearTIFF }

        public var isAvailable: Bool {
            if self == .jpegHDR {
                if #available(iOS 18.0, macOS 15.0, *) { return true }
                return false
            }
            return true
        }

        public var fixedBitsPerComponent: Int? {
            switch self {
            case .tiff16: 16
            case .tiffFloat, .sceneLinearTIFF: 32
            case .jpeg, .tiff, .png: 8
            case .heic, .jpegHDR: nil
            }
        }
    }

    public let gpu: GPUContext

    public init(gpu: GPUContext) {
        self.gpu = gpu
    }

    /// 輸出已經是 display-referred 的影像。`target` 決定嵌入的色彩描述檔。
    public func write(
        image: CIImage,
        to url: URL,
        target: RenderingTarget,
        format: Format = .heic,
        quality: Double = 0.9,
        hdrImage: CIImage? = nil
    ) throws {
        let interval = RFPerformance.begin("Encode")
        defer { RFPerformance.end("Encode", interval) }
        let colorSpace = RenderPipeline.colorSpace(for: target)
        let options: [CIImageRepresentationOption: Any] =
            [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        let isHDRTransfer = target.transferFunction == .pq || target.transferFunction == .hlg
        guard format.supportsHDR || !isHDRTransfer else {
            throw ExportError.unsupportedFormat(
                String(localized: "\(format.displayName) 尚不支援 \(target.transferFunction.rawValue) HDR", bundle: .module)
            )
        }
        if target.dynamicRange != .sdr {
            switch format {
            case .heic, .tiff16:
                guard isHDRTransfer else {
                    throw ExportError.unsupportedFormat(
                        String(localized: "\(format.displayName) 的 HDR 輸出需要 PQ 或 HLG；linear HDR 請使用 Float TIFF", bundle: .module)
                    )
                }
            case .tiffFloat, .sceneLinearTIFF:
                guard target.transferFunction == .linear else {
                    throw ExportError.unsupportedFormat(
                        String(localized: "\(format.displayName) 只接受 linear target，避免把已編碼的 PQ／HLG 標成 linear", bundle: .module)
                    )
                }
            case .jpegHDR:
                break
            case .jpeg, .tiff, .png:
                break
            }
        }
        if let destination = target.iccDestination, target.dynamicRange == .sdr {
            try writeICC(image: image, to: url, target: target, destination: destination,
                         format: format, quality: quality)
            return
        }
        switch format {
        case .heic:
            do {
                // PQ / HLG 需要 10-bit 才承載得住高光；SDR 維持既有 8-bit 路徑。
                switch target.transferFunction {
                case .pq, .hlg:
                    try gpu.ciContext.writeHEIF10Representation(
                        of: image,
                        to: url,
                        colorSpace: colorSpace,
                        options: options
                    )
                case .sRGB, .linear:
                    try gpu.ciContext.writeHEIFRepresentation(
                        of: image,
                        to: url,
                        format: .RGBA8,
                        colorSpace: colorSpace,
                        options: options
                    )
                }
            } catch {
                throw ExportError.encodingFailed(String(describing: error))
            }
        case .jpeg:
            do {
                try gpu.ciContext.writeJPEGRepresentation(
                    of: image, to: url, colorSpace: colorSpace, options: options
                )
            } catch {
                throw ExportError.encodingFailed(String(describing: error))
            }
        case .jpegHDR:
            guard #available(iOS 18.0, macOS 15.0, *) else {
                throw ExportError.unsupportedFormat(String(localized: "JPEG HDR gain map 需要 macOS 15 或 iOS 18 或更新版本", bundle: .module))
            }
            guard let hdrImage else {
                throw ExportError.encodingFailed(String(localized: "JPEG HDR 缺少 HDR auxiliary image", bundle: .module))
            }
            do {
                var jpegOptions = options
                jpegOptions[.hdrImage] = hdrImage
                try gpu.ciContext.writeJPEGRepresentation(
                    of: image, to: url,
                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                    options: jpegOptions
                )
            } catch {
                throw ExportError.encodingFailed(String(describing: error))
            }
        case .tiff:
            do {
                try gpu.ciContext.writeTIFFRepresentation(
                    of: image, to: url, format: .RGBA8,
                    colorSpace: colorSpace, options: [:]
                )
            } catch {
                throw ExportError.encodingFailed(String(describing: error))
            }
        case .tiff16:
            do {
                try gpu.ciContext.writeTIFFRepresentation(
                    of: image, to: url, format: .RGBA16,
                    colorSpace: colorSpace, options: [:]
                )
            } catch {
                throw ExportError.encodingFailed(String(describing: error))
            }
        case .tiffFloat, .sceneLinearTIFF:
            do {
                try gpu.ciContext.writeTIFFRepresentation(
                    of: image, to: url, format: .RGBAf,
                    colorSpace: gpu.workingColorSpace, options: [:]
                )
            } catch {
                throw ExportError.encodingFailed(String(describing: error))
            }
        case .png:
            do {
                try gpu.ciContext.writePNGRepresentation(
                    of: image, to: url, format: .RGBA8,
                    colorSpace: colorSpace, options: [:]
                )
            } catch {
                throw ExportError.encodingFailed(String(describing: error))
            }
        }
    }

    /// ICC destination：先在 target 色域算出 display-referred 值，再由 ColorSync 轉到描述檔並嵌入。
    private func writeICC(
        image: CIImage, to url: URL, target: RenderingTarget,
        destination: ICCDestination, format: Format, quality: Double
    ) throws {
        let bits: Int
        switch format {
        case .jpeg, .tiff, .png, .heic: bits = 8
        case .tiff16: bits = 16
        case .jpegHDR, .tiffFloat, .sceneLinearTIFF:
            throw ExportError.unsupportedFormat(String(localized: "\(format.displayName) 不支援 ICC destination", bundle: .module))
        }
        let space = try destination.loadColorSpace()
        if space.model == .cmyk && !(format == .jpeg || format == .tiff || format == .tiff16) {
            throw ExportError.unsupportedFormat(String(localized: "\(format.displayName) 不支援 CMYK；請改用 JPEG 或 TIFF", bundle: .module))
        }
        guard let rendered = gpu.ciContext.createCGImage(
            image, from: image.extent, format: bits == 16 ? .RGBA16 : .RGBA8,
            colorSpace: RenderPipeline.colorSpace(for: target)
        ) else { throw ExportError.encodingFailed(String(localized: "無法產生 \(target.gamut.displayName) 影像", bundle: .module)) }
        let converted = try destination.convert(rendered, bitsPerComponent: bits)
        guard let output = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil
        ) else { throw ExportError.encodingFailed(String(localized: "無法建立 \(format.displayName) 檔案", bundle: .module)) }
        CGImageDestinationAddImage(output, converted, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw ExportError.encodingFailed(String(localized: "\(format.displayName) 寫檔失敗", bundle: .module))
        }
    }

    /// 全解析度輸出：重新從 RAW 走一次完整 pipeline，不使用預覽 proxy
    /// （§20「最終輸出才全解析度算圖」）。
    /// JPEG HDR 高動態輔助圖用的 linear target。HDR target 保留它的參考白與峰值；
    /// SDR target 沒有亮度資訊，沿用存檔設定。
    public static func jpegHDRAuxiliaryTarget(for target: RenderingTarget) -> RenderingTarget {
        if target.transferFunction == .linear { return target }
        guard target.dynamicRange != .sdr else { return .preset(.archive) }
        return RenderingTarget(dynamicRange: target.dynamicRange, gamut: .rec2020,
                               transferFunction: .linear, intent: target.intent,
                               referenceWhiteNits: target.referenceWhiteNits,
                               contentPeakNits: target.contentPeakNits)
    }

    @discardableResult
    public func exportFullResolution(
        pipeline: RenderPipeline,
        rawURL: URL,
        parameters: EditParameters,
        pinnedDecoderVersion: String?,
        to url: URL,
        target: RenderingTarget? = nil,
        format: Format = .heic,
        quality: Double = 0.9,
        resize: Resize? = nil
    ) throws -> URL {
        return try autoreleasepool {
            let target = target ?? parameters.target
            let master = try pipeline.makeSceneMaster(
                url: rawURL,
                parameters: parameters,
                pinnedDecoderVersion: pinnedDecoderVersion,
                maxDimension: nil
            )
            if format.isSceneLinear {
                let sceneLinear = try pipeline.renderSceneLinear(
                    sceneMaster: master, parameters: parameters
                )
                let output = try resize.map { try self.resize(sceneLinear, to: $0) } ?? sceneLinear
                try write(image: output, to: url, target: .preset(.archive),
                          format: format, quality: quality)
            } else if format == .jpegHDR {
                let sdr = try pipeline.render(
                    sceneMaster: master, parameters: parameters, target: .preset(.appleSDR)
                )
                let hdrTarget = Self.jpegHDRAuxiliaryTarget(for: target)
                let hdr = try pipeline.render(
                    sceneMaster: master, parameters: parameters, target: hdrTarget,
                    outputColorSpace: gpu.workingColorSpace
                )
                if let resize {
                    let resizedSDR = try self.resize(sdr, to: resize)
                    let outputSize = resizedSDR.extent.integral.size
                    let resizedHDR = try Self.resize(hdr, toPixelSize: outputSize)
                    try write(image: resizedSDR, to: url, target: target, format: format,
                              quality: quality, hdrImage: resizedHDR)
                } else {
                    try write(image: sdr, to: url, target: target, format: format,
                              quality: quality, hdrImage: hdr)
                }
            } else {
                let rendered = try pipeline.render(sceneMaster: master, parameters: parameters,
                                                   target: target)
                let output = try resize.map { try self.resize(rendered, to: $0) } ?? rendered
                try write(image: output, to: url, target: target,
                          format: format, quality: quality)
            }
            return url
        }
    }

    /// High-quality output resampling shared by RAW and already-rendered bridge exports.
    /// The source is expected to have completed its full-resolution processing first.
    public func resize(_ image: CIImage, to options: Resize) throws -> CIImage {
        let dimensions = try Self.outputDimensions(for: image.extent, options: options)
        return try Self.resize(image, toPixelSize: CGSize(width: dimensions.width, height: dimensions.height))
    }

    private static func outputDimensions(for extent: CGRect, options: Resize) throws -> CGSize {
        let bounds = extent.integral
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width < CGFloat(Int.max), bounds.height < CGFloat(Int.max) else {
            throw ExportError.invalidResize(String(localized: "影像尺寸無效", bundle: .module))
        }
        switch options.mode {
        case .longEdge:
            guard options.value.isFinite, options.value.rounded() == options.value,
                  (1...65_535).contains(options.value) else {
                throw ExportError.invalidResize(String(localized: "longEdge 必須是 1 到 65535 的整數", bundle: .module))
            }
        case .percent:
            guard options.value.isFinite, options.value > 0, options.value <= 10_000 else {
                throw ExportError.invalidResize(String(localized: "percent 必須大於 0 且不超過 10000", bundle: .module))
            }
        }

        let sourceWidth = Double(bounds.width)
        let sourceHeight = Double(bounds.height)
        let requestedScale: Double
        switch options.mode {
        case .longEdge:
            requestedScale = options.value / max(sourceWidth, sourceHeight)
        case .percent:
            requestedScale = options.value / 100
        }
        let longest = max(sourceWidth, sourceHeight)
        let shortest = min(sourceWidth, sourceHeight)
        let maximumScale = 65_535 / longest
        let minimumScale = 1 / shortest
        var scale = min(requestedScale, maximumScale)
        if options.dontEnlarge { scale = min(scale, 1) }
        // Keep the short side at least one pixel, matching the batch export sizing rule.
        scale = minimumScale <= maximumScale ? max(scale, minimumScale) : maximumScale
        guard scale.isFinite, scale > 0 else { throw ExportError.invalidResize(String(localized: "縮放比例無效", bundle: .module)) }

        func dimension(_ source: Double) -> CGFloat {
            CGFloat(min(65_535, max(1, Int((source * scale).rounded()))))
        }
        return CGSize(width: dimension(sourceWidth), height: dimension(sourceHeight))
    }

    private static func resize(_ image: CIImage, toPixelSize target: CGSize) throws -> CIImage {
        let bounds = image.extent.integral
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              target.width.isFinite, target.height.isFinite,
              target.width >= 1, target.height >= 1,
              target.width <= 65_535, target.height <= 65_535,
              target.width.rounded() == target.width, target.height.rounded() == target.height else {
            throw ExportError.invalidResize(String(localized: "影像或目標尺寸無效", bundle: .module))
        }
        let outputBounds = CGRect(origin: .zero, size: target)
        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -bounds.minX, y: -bounds.minY
        ))
        if bounds.size == target {
            return normalized.cropped(to: outputBounds)
        }

        let transform = CGAffineTransform(scaleX: target.width / bounds.width,
                                          y: target.height / bounds.height)
        let output = normalized.transformed(by: transform, highQualityDownsample: true)
        return output.cropped(to: outputBounds)
    }

}
