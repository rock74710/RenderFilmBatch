import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ProcessedImageFormat: String, Sendable {
    case jpeg
    case heic
}

public enum ProcessedImageError: Error, CustomStringConvertible {
    case unsupportedExtension(URL)
    case unsupportedContent(URL, String)
    case cannotRead(URL)
    case corruptImage(URL)
    case invalidDimensions(URL)
    case invalidOrientation(URL)
    case cannotMaterialize(URL)

    public var description: String {
        switch self {
        case .unsupportedExtension(let url): String(localized: "不支援的已成像來源副檔名：\(url.lastPathComponent)", bundle: .module)
        case .unsupportedContent(let url, let type): String(localized: "\(url.lastPathComponent) 的內容類型 \(type) 與 JPEG／HEIF 不符", bundle: .module)
        case .cannotRead(let url): String(localized: "無法讀取影像：\(url.lastPathComponent)", bundle: .module)
        case .corruptImage(let url): String(localized: "影像已損毀或無法解碼：\(url.lastPathComponent)", bundle: .module)
        case .invalidDimensions(let url): String(localized: "影像尺寸無效：\(url.lastPathComponent)", bundle: .module)
        case .invalidOrientation(let url): String(localized: "影像方向資訊無效：\(url.lastPathComponent)", bundle: .module)
        case .cannotMaterialize(let url): String(localized: "無法轉換影像色彩：\(url.lastPathComponent)", bundle: .module)
        }
    }
}

/// Image I/O facts for one JPEG or HEIF image. Dimensions and orientation describe the
/// normalized display image; `sourceOrientation` records the original EXIF value.
public struct ProcessedImageInfo: Sendable {
    public let format: ProcessedImageFormat
    public let width: Int
    public let height: Int
    public let sourceOrientation: Int
    public let sourceTypeIdentifier: String
    public let colorProfileName: String?
    public let colorSpaceFallback: Bool

    public init(format: ProcessedImageFormat, width: Int, height: Int,
                sourceOrientation: Int, sourceTypeIdentifier: String,
                colorProfileName: String?, colorSpaceFallback: Bool) {
        self.format = format
        self.width = width
        self.height = height
        self.sourceOrientation = sourceOrientation
        self.sourceTypeIdentifier = sourceTypeIdentifier
        self.colorProfileName = colorProfileName
        self.colorSpaceFallback = colorSpaceFallback
    }
}

/// An already-rendered SDR photo, decoded to oriented, origin-zero, linear Rec.2020 pixels.
/// It intentionally does not use `DecodedRaw`, whose pixels and metadata have camera-RAW meaning.
public struct DecodedProcessedImage: @unchecked Sendable {
    public let url: URL
    public let image: CIImage
    /// 保留來源 ICC 與 EXIF 正規化後的影像，供中性 SDR 預覽直接做色彩管理轉換。
    public let colorManagedImage: CIImage?
    public let metadata: RawMetadata
    public let fullSize: CGSize
    public let colorSpace: CGColorSpace
    public let info: ProcessedImageInfo

    public init(url: URL, image: CIImage, metadata: RawMetadata,
                colorSpace: CGColorSpace, info: ProcessedImageInfo,
                colorManagedImage: CIImage? = nil) {
        self.url = url
        self.image = image
        self.colorManagedImage = colorManagedImage
        self.metadata = metadata
        self.fullSize = CGSize(width: info.width, height: info.height)
        self.colorSpace = colorSpace
        self.info = info
    }
}

/// Decode one JPEG, HEIC, or HEIF image using its embedded profile and EXIF orientation.
/// HDR-bearing containers receive Image I/O's explicit SDR decode request; this API produces
/// SDR-compatible pixels and does not promise HDR editing or display.
public struct ProcessedImageDecoder: Sendable {
    public init() {}

    public static let requiredExtensions = ["jpg", "jpeg", "heic", "heif"]

    public static func isSupported(_ url: URL) -> Bool {
        requiredExtensions.contains(url.pathExtension.lowercased())
    }

    public func probe(url: URL) throws -> ProcessedImageInfo {
        let source = try imageSource(at: url)
        let info = try information(source: source, url: url)
        // A properties-only source can still be corrupt. Creating image zero establishes that
        // Image I/O can actually decode the declared content before we report its dimensions.
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, Self.decodeOptions()) else {
            throw ProcessedImageError.corruptImage(url)
        }
        let hasEmbeddedProfile = cgImage.colorSpace?.copyICCData() != nil
        return ProcessedImageInfo(
            format: info.format, width: info.width, height: info.height,
            sourceOrientation: info.sourceOrientation, sourceTypeIdentifier: info.sourceTypeIdentifier,
            colorProfileName: info.colorProfileName ?? cgImage.colorSpace?.name as String?,
            colorSpaceFallback: !hasEmbeddedProfile
        )
    }

    public func decode(url: URL, context: CIContext) throws -> DecodedProcessedImage {
        let source = try imageSource(at: url)
        let info = try information(source: source, url: url)
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, Self.decodeOptions()) else {
            throw ProcessedImageError.corruptImage(url)
        }

        let sourceColorSpace = cgImage.colorSpace
        let decodeColorSpace: CGColorSpace
        let fallback: Bool
        if let sourceColorSpace, sourceColorSpace.copyICCData() != nil {
            decodeColorSpace = sourceColorSpace
            fallback = false
        } else {
            decodeColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            fallback = true
        }
        let decoded = CIImage(cgImage: cgImage, options: [.colorSpace: decodeColorSpace])
        let oriented = decoded.oriented(forExifOrientation: Int32(info.sourceOrientation))
        let orientedExtent = oriented.extent.integral
        guard orientedExtent.width > 0, orientedExtent.height > 0,
              orientedExtent.width == CGFloat(info.width), orientedExtent.height == CGFloat(info.height) else {
            throw ProcessedImageError.invalidDimensions(url)
        }
        let normalized = oriented.transformed(by: CGAffineTransform(
            translationX: -orientedExtent.minX, y: -orientedExtent.minY
        ))
        let linearSpace = Self.linearWorkingColorSpace()
        guard let linearCGImage = context.createCGImage(
            normalized, from: CGRect(origin: .zero, size: orientedExtent.size),
            format: .RGBAh, colorSpace: linearSpace
        ) else {
            throw ProcessedImageError.cannotMaterialize(url)
        }
        let linearImage = CIImage(cgImage: linearCGImage, options: [.colorSpace: linearSpace])
        var metadata = RawMetadata.from(imageProperties: Self.properties(source: source))
        metadata.orientation = 1 // Orientation has already been applied to `image` exactly once.
        metadata.pixelWidth = info.width
        metadata.pixelHeight = info.height
        metadata.colorProfileName = info.colorProfileName
        metadata.decoderVersion = "ImageIO SDR"
        return DecodedProcessedImage(url: url, image: linearImage, metadata: metadata,
                                     colorSpace: linearSpace, info: ProcessedImageInfo(
            format: info.format, width: info.width, height: info.height,
            sourceOrientation: info.sourceOrientation, sourceTypeIdentifier: info.sourceTypeIdentifier,
            colorProfileName: info.colorProfileName, colorSpaceFallback: fallback
        ), colorManagedImage: normalized)
    }

    private static func decodeOptions() -> CFDictionary {
        [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR,
        ] as CFDictionary
    }

    private static func linearWorkingColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    }

    private func imageSource(at url: URL) throws -> CGImageSource {
        guard Self.isSupported(url) else { throw ProcessedImageError.unsupportedExtension(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ProcessedImageError.cannotRead(url)
        }
        return source
    }

    private func information(source: CGImageSource, url: URL) throws -> ProcessedImageInfo {
        guard let actualType = CGImageSourceGetType(source) as String?,
              let type = UTType(actualType) else {
            throw ProcessedImageError.corruptImage(url)
        }
        let format: ProcessedImageFormat
        if type.conforms(to: .jpeg) {
            format = .jpeg
        } else if type.conforms(to: .heic) || type.conforms(to: .heif) {
            format = .heic
        } else {
            throw ProcessedImageError.unsupportedContent(url, actualType)
        }

        let ext = url.pathExtension.lowercased()
        let extensionMatches = (format == .jpeg && ["jpg", "jpeg"].contains(ext))
            || (format == .heic && ["heic", "heif"].contains(ext))
        guard extensionMatches else { throw ProcessedImageError.unsupportedContent(url, actualType) }
        let props = Self.properties(source: source)
        guard let rawWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0, rawHeight > 0 else {
            throw ProcessedImageError.invalidDimensions(url)
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw ProcessedImageError.invalidOrientation(url) }
        let swapsAxes = (5...8).contains(orientation)
        let profileName = props[kCGImagePropertyProfileName] as? String
        return ProcessedImageInfo(
            format: format,
            width: swapsAxes ? rawHeight : rawWidth,
            height: swapsAxes ? rawWidth : rawHeight,
            sourceOrientation: orientation,
            sourceTypeIdentifier: actualType,
            colorProfileName: profileName,
            colorSpaceFallback: false
        )
    }

    private static func properties(source: CGImageSource) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}

/// Source-specific defaults and the common RFCore render stages for an already-rendered SDR image.
public final class ProcessedImageRenderer: @unchecked Sendable {
    private let gpu: GPUContext
    private let profileManager: OpticalProfileManager
    private let optical: OpticalRenderer
    private let lutRenderer: LUTRenderer
    private let maskRenderer: MaskRenderer
    private let spatialRenderer: SpatialRenderer
    private let sceneLUTCache = LUTCache()
    private let targetLUTCache = LUTCache()
    private let fullLUTCache = LUTCache()

    public init(gpu: GPUContext, profileManager: OpticalProfileManager? = nil) throws {
        self.gpu = gpu
        self.profileManager = profileManager ?? OpticalProfileManager(database: LensfunDatabase.loadDefault())
        self.optical = try OpticalRenderer(gpu: gpu)
        self.lutRenderer = try LUTRenderer(gpu: gpu)
        self.maskRenderer = try MaskRenderer()
        self.spatialRenderer = try SpatialRenderer()
    }

    public static func defaults() -> EditParameters {
        var parameters = EditParameters()
        parameters.colorEngine.enabled = false
        parameters.gamutMapping.enabled = false
        parameters.optical.enabled = false
        return parameters
    }

    public func render(source: DecodedProcessedImage, parameters: EditParameters,
                       target: RenderingTarget? = nil, maxDimension: Int? = nil,
                       autoWhiteBalanceGains: SIMD3<Double>? = nil) throws -> CIImage {
        let parameters = parameters.effective
        let target = target ?? parameters.target
        if target.dynamicRange == .sdr, target.transferFunction == .sRGB,
           target.iccDestination == nil, let colorManagedImage = source.colorManagedImage {
            var neutral = Self.defaults()
            neutral.target = target
            var candidate = parameters
            candidate.target = target
            // 讀不到的 LUT 視同未選，維持原照片外觀（INV-3）。
            if !candidate.film.hasLUT || candidate.film.lutID.flatMap(CreativeLUTLibrary.load) == nil {
                candidate.film.lutID = nil
                candidate.film.lutAmount = 1
            }
            if candidate == neutral {
                // 中性 SDR 直接由 Core Image 依來源 ICC 轉色，避免 3D LUT 改變原照片外觀。
                if let maxDimension {
                    let longest = max(source.fullSize.width, source.fullSize.height)
                    if longest > CGFloat(maxDimension) {
                        let scale = Double(CGFloat(maxDimension) / longest)
                        return colorManagedImage.transformed(
                            by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true
                        )
                    }
                }
                return colorManagedImage
            }
        }
        let master = try makeSceneMaster(source: source, parameters: parameters, maxDimension: maxDimension,
                                         autoWhiteBalanceGains: autoWhiteBalanceGains)
        let transform = TargetTransform(target: target, tone: parameters.toneMapping,
                                        gamut: parameters.gamutMapping, film: parameters.film,
                                        preservesProcessedSDR: true)
        let finishing = FinishingTransform(parameters: parameters.finishing, target: target)
        let graded: CIImage
        if parameters.localMasks.contains(where: \.hasActiveAdjustment) {
            let sceneImage = try maskSource(master: master, parameters: parameters)
            let adjusted = try maskRenderer.apply(parameters.localMasks, to: sceneImage)
            var targetParameters = EditParameters()
            targetParameters.toneMapping = parameters.toneMapping
            targetParameters.gamutMapping = parameters.gamutMapping
            targetParameters.finishing = parameters.finishing
            targetParameters.film = parameters.film
            let key = LUTCache.Key(parameters: targetParameters, target: target, metadata: master.metadata)
            let lut = targetLUTCache.lut(key: key) {
                LUT3D.bake { finishing.apply(transform.apply($0)) }
            }
            graded = try lutRenderer.apply(to: adjusted, lut: lut,
                                            outputColorSpace: outputColorSpace(for: target))
        } else {
            let key = LUTCache.Key(parameters: parameters, target: target, metadata: master.metadata,
                                   sceneWhiteBalanceGains: master.sceneTransform.whiteBalanceGains)
            let lut = fullLUTCache.lut(scene: master.sceneTransform, targetTransform: transform,
                                       finishing: finishing, key: key)
            graded = try lutRenderer.apply(to: master.image, lut: lut,
                                            outputColorSpace: outputColorSpace(for: target))
        }
        return try spatialRenderer.apply(parameters.spatial, to: graded)
    }

    private struct SceneMasterSource {
        let image: CIImage
        let sceneTransform: SceneTransform
        let metadata: RawMetadata
    }

    private func makeSceneMaster(source: DecodedProcessedImage, parameters: EditParameters,
                                 maxDimension: Int?,
                                 autoWhiteBalanceGains: SIMD3<Double>?) throws -> SceneMasterSource {
        var image = source.image
        if let maxDimension {
            let longest = max(source.fullSize.width, source.fullSize.height)
            if longest > CGFloat(maxDimension) {
                let scale = Double(CGFloat(maxDimension) / longest)
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale),
                                          highQualityDownsample: true)
            }
        }
        let resolution = profileManager.resolve(
            metadata: source.metadata,
            preference: parameters.optical.enabled
                ? (parameters.optical.forcedSource.map { .force($0) } ?? .auto)
                : .force(.off),
            manual: parameters.optical.manualProfile,
            appleCorrectionSupported: false
        )
        if parameters.optical.enabled {
            image = try optical.apply(to: image, profile: resolution.profile)
        }
        image = try RetouchAssetStore.applying(parameters.retouch.applicable(to: parameters.optical),
                                               to: image, forRaw: source.url)
        image = parameters.optical.geometry.apply(to: image, includeUserCrop: true)

        let whiteBalance = parameters.layerA.whiteBalance
        let reference = WhiteBalanceReading(temperature: 6500, tint: 0)
        let requested = whiteBalance.resolved(asShot: reference)
        var gains = SIMD3<Double>(repeating: 1)
        if let temperature = requested.temperature, let tint = requested.tint {
            gains = SceneNormalization.whiteBalanceGains(
                temperature: temperature, tint: tint,
                asShotTemperature: 6500, asShotTint: 0
            )
        }
        if whiteBalance.preset == .auto {
            if let autoWhiteBalanceGains {
                gains *= autoWhiteBalanceGains
            } else {
                let automatic = AutoWhiteBalance.analyze(source.image, context: gpu.ciContext)
                if !automatic.usedFallback { gains *= automatic.gains }
            }
        }
        let scene = SceneTransform(cameraNormalize: .identity, layerA: parameters.layerA,
                                   colorEngine: parameters.colorEngine, colorMixer: parameters.colorMixer,
                                   film: parameters.film, whiteBalanceGains: gains)
        return SceneMasterSource(image: image, sceneTransform: scene, metadata: source.metadata)
    }

    private func maskSource(master: SceneMasterSource, parameters: EditParameters) throws -> CIImage {
        var sceneParameters = EditParameters()
        sceneParameters.layerA = parameters.layerA
        sceneParameters.colorEngine = parameters.colorEngine
        sceneParameters.colorMixer = parameters.colorMixer
        sceneParameters.film = parameters.film
        let key = LUTCache.Key(parameters: sceneParameters, target: parameters.target,
                               metadata: master.metadata,
                               sceneWhiteBalanceGains: master.sceneTransform.whiteBalanceGains)
        let lut = sceneLUTCache.lut(key: key) {
            LUT3D.bake { master.sceneTransform.apply($0) }
        }
        return try lutRenderer.apply(to: master.image, lut: lut, outputColorSpace: gpu.workingColorSpace)
    }

    private func outputColorSpace(for target: RenderingTarget) -> CGColorSpace {
        RenderPipeline.colorSpace(for: target)
    }
}
