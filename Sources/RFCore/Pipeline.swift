import Foundation
import CoreImage
import simd

/// Reconstruction 的輸出。影像維持 extended scene-linear working RGB；後續階段
/// 只依賴這份資料，不需知道它來自單張 RAW 或未來的 fusion。
public struct SceneLinearImage: @unchecked Sendable {
    public let image: CIImage
    public let metadata: RawMetadata
    public let versions: PipelineVersions
    public let lensResolution: OpticalProfileManager.Resolution
    /// 影像相對於全解析度的比例；預覽 proxy 小於 1。
    public let scale: Double

    public init(image: CIImage, metadata: RawMetadata, versions: PipelineVersions,
                lensResolution: OpticalProfileManager.Resolution, scale: Double = 1) {
        self.image = image
        self.metadata = metadata
        self.versions = versions
        self.lensResolution = lensResolution
        self.scale = scale
    }
}

/// §7 Scene Master：所有 scene-referred 編輯的匯總。
///
/// SDR 與 HDR、不同色域共用同一份 Scene Master，不存在兩套編輯資料。
public struct SceneMaster: @unchecked Sendable {
    /// 已做完解碼與光學校正的 scene-referred 影像。
    public let image: CIImage
    /// 從相機線性值走到 Scene Master 的 per-pixel 轉換。
    public let sceneTransform: SceneTransform
    public let metadata: RawMetadata
    public let versions: PipelineVersions
    public let lensResolution: OpticalProfileManager.Resolution
    /// 目前影像相對於全解析度的縮放比例（預覽 proxy 為 <1）。
    public let scale: Double
}

private enum PortraitPipelineFailure: LocalizedError {
    case noFace

    var errorDescription: String? {
        String(localized: "沒有辨識到可用的人臉；請關閉人像修飾或選擇另一張照片。", bundle: .module)
    }
}

/// §17 建議 pipeline 的實作入口。
public final class RenderPipeline: @unchecked Sendable {
    public let gpu: GPUContext
    public let decoder = RawDecoder()
    public let profileManager: OpticalProfileManager
    private let optical: OpticalRenderer
    private let lutRenderer: LUTRenderer
    private let lutCache = LUTCache()
    private let analysisReuseCache = AnalysisReuseCache()
    private let maskRenderer: MaskRenderer
    private let spatialRenderer: SpatialRenderer
    private let diagnosticRenderer: DiagnosticOverlayRenderer
    private let sceneLUTCache = LUTCache()
    private let targetLUTCache = LUTCache()
    private let monochromeLUTCache = LUTCache()
    private let diagnosticMappedLUTCache = LUTCache()
    private let diagnosticUnmappedLUTCache = LUTCache()

    public init(gpu: GPUContext, lensDatabase: LensfunDatabase? = nil) throws {
        self.gpu = gpu
        self.profileManager = OpticalProfileManager(
            database: lensDatabase ?? LensfunDatabase.loadDefault()
        )
        self.optical = try OpticalRenderer(gpu: gpu)
        self.lutRenderer = try LUTRenderer(gpu: gpu)
        self.maskRenderer = try MaskRenderer()
        self.spatialRenderer = try SpatialRenderer()
        self.diagnosticRenderer = try DiagnosticOverlayRenderer()
    }

    /// RAW → Scene Master。`maxDimension` 給預覽用，nil 表示全解析度。
    /// 同一個已解碼 RAW 的自動白平衡結果（含 fallback 與中性像素數）；預覽快取、
    /// 白平衡建議與一般渲染共用，曝光改變不會重算。
    public func cachedAutoWhiteBalance(decoded: DecodedRaw) -> AutoWhiteBalance.Result {
        cachedAutoWhiteBalance(decoded: decoded) { AutoWhiteBalance.analyze($0, context: gpu.ciContext) }
    }

    func cachedAutoWhiteBalance(decoded: DecodedRaw,
                                analyze: (CIImage) -> AutoWhiteBalance.Result) -> AutoWhiteBalance.Result {
        analysisReuseCache.autoWhiteBalance(image: decoded.image, sourceURL: decoded.url,
                                            decoderVersion: decoded.metadata.decoderVersion, analyze: analyze)
    }

    public func makeSceneMaster(
        url: URL,
        parameters: EditParameters,
        pinnedDecoderVersion: String? = nil,
        maxDimension: Int? = nil,
        autoWhiteBalanceGains: SIMD3<Double>? = nil
    ) throws -> SceneMaster {
        let decoded = try decoder.decode(url: url, pinnedDecoderVersion: pinnedDecoderVersion)
        return try makeSceneMaster(decoded: decoded, parameters: parameters,
                                   maxDimension: maxDimension,
                                   autoWhiteBalanceGains: autoWhiteBalanceGains)
    }

    public func makeSceneMaster(
        decoded: DecodedRaw,
        parameters: EditParameters,
        maxDimension: Int? = nil,
        autoWhiteBalanceGains: SIMD3<Double>? = nil,
        cropPreview: Bool = false
    ) throws -> SceneMaster {
        var resolvedAutoWhiteBalanceGains = autoWhiteBalanceGains
        if resolvedAutoWhiteBalanceGains == nil,
           parameters.effective.layerA.whiteBalance.preset == .auto {
            resolvedAutoWhiteBalanceGains = analysisReuseCache.autoWhiteBalance(
                image: decoded.image, sourceURL: decoded.url,
                decoderVersion: decoded.metadata.decoderVersion, context: gpu.ciContext
            ).gains
        }
        let reconstructed = try reconstruct(decoded: decoded, parameters: parameters,
                                            maxDimension: maxDimension, cropPreview: cropPreview,
                                            autoWhiteBalanceGains: resolvedAutoWhiteBalanceGains)
        return makeSceneMaster(sceneLinear: reconstructed, parameters: parameters,
                               autoWhiteBalanceGains: resolvedAutoWhiteBalanceGains)
    }

    /// Reconstruction：單張 RAW 的解碼結果加上光學校正。未來 fusion 可以直接產生
    /// `SceneLinearImage`，再交給 `makeSceneMaster(sceneLinear:parameters:)`。
    public func reconstruct(decoded: DecodedRaw, parameters: EditParameters,
                            maxDimension: Int? = nil, cropPreview: Bool = false,
                            autoWhiteBalanceGains: SIMD3<Double>? = nil) throws -> SceneLinearImage {
        // §12「預覽反應速度優先」：proxy 先縮圖，後面所有運算都省下來。
        var image = decoded.image
        var scale = 1.0
        if let maxDimension {
            let longest = max(decoded.fullSize.width, decoded.fullSize.height)
            if longest > CGFloat(maxDimension) {
                scale = Double(CGFloat(maxDimension) / longest)
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale),
                                          highQualityDownsample: true)
            }
        }

        // §2 光學校正
        let resolution = profileManager.resolve(
            metadata: decoded.metadata,
            preference: parameters.optical.enabled
                ? (parameters.optical.forcedSource.map { .force($0) } ?? .auto)
                : .force(.off),
            manual: parameters.optical.manualProfile,
            appleCorrectionSupported: decoded.metadata.hasEmbeddedLensCorrection
        )
        if parameters.optical.enabled {
            image = try optical.apply(to: image, profile: resolution.profile)
        }
        // Committed retouch pixels are fixed at full resolution and resized for preview here.
        // They share the pre-geometry coordinate system with the full-resolution export.
        image = try RetouchAssetStore.applying(parameters.retouch.applicable(to: parameters.optical), to: image, forRaw: decoded.url)
        let portrait = parameters.effective.portraitRetouch
        if portrait.skinToneLevel > 0 || portrait.skinSmoothingLevel > 0 {
            guard let analysis = analysisReuseCache.portraitAnalysis(
                image: decoded.image, sourceURL: decoded.url,
                decoderVersion: decoded.metadata.decoderVersion,
                exposureEV: parameters.layerA.exposureEV, context: gpu.ciContext) else {
                throw PortraitPipelineFailure.noFace
            }
            let mask = analysis.mask(fittedTo: image.extent)
            if portrait.skinToneLevel > 0 {
                let portraitAutoWhiteBalanceGains: SIMD3<Double>?
                if let autoWhiteBalanceGains {
                    portraitAutoWhiteBalanceGains = autoWhiteBalanceGains
                } else if parameters.layerA.whiteBalance.preset == .auto {
                    let result = analysisReuseCache.autoWhiteBalance(
                        image: decoded.image, sourceURL: decoded.url,
                        decoderVersion: decoded.metadata.decoderVersion, context: gpu.ciContext
                    )
                    portraitAutoWhiteBalanceGains = result.usedFallback ? nil : result.gains
                } else {
                    portraitAutoWhiteBalanceGains = nil
                }
                image = PortraitRetouch.correctTone(
                    image, faces: analysis.faces(fittedTo: image.extent),
                    transform: Self.sceneTransform(for: parameters, metadata: decoded.metadata,
                                                    autoWhiteBalanceGains: portraitAutoWhiteBalanceGains),
                    level: portrait.skinToneLevel, context: gpu.ciContext)
            }
            if portrait.skinSmoothingLevel > 0 {
                image = PortraitRetouch.smooth(image, mask: mask,
                    faceWidth: analysis.faceWidth(in: image.extent), level: portrait.skinSmoothingLevel)
            }
            image = image.cropped(to: image.extent)
        }
        // 幾何在縮圖之後套用；角度與比例不受縮放影響，預覽與輸出一致。
        image = parameters.optical.geometry.apply(to: image, includeUserCrop: !cropPreview)

        var versions = PipelineVersions()
        versions.rawDecoder = decoded.metadata.decoderVersion ?? "unknown"
        versions.lensProfile = "\(resolution.profile.source.rawValue):\(resolution.databaseVersion)"

        return SceneLinearImage(image: image, metadata: decoded.metadata,
                                versions: versions, lensResolution: resolution, scale: scale)
    }

    /// Full-resolution optical-corrected base before geometry, including all committed patches.
    /// Brush generation uses this source so its saved pixels line up with preview and export.
    public func retouchBase(decoded: DecodedRaw, parameters: EditParameters) throws -> CIImage {
        var image = decoded.image
        let resolution = profileManager.resolve(
            metadata: decoded.metadata,
            preference: parameters.optical.enabled
                ? (parameters.optical.forcedSource.map { .force($0) } ?? .auto)
                : .force(.off),
            manual: parameters.optical.manualProfile,
            appleCorrectionSupported: decoded.metadata.hasEmbeddedLensCorrection
        )
        if parameters.optical.enabled {
            image = try optical.apply(to: image, profile: resolution.profile)
        }
        return try RetouchAssetStore.applying(parameters.retouch.applicable(to: parameters.optical), to: image, forRaw: decoded.url)
    }

    /// Scene Processing / Creative Rendering 的設定，沿用既有 lazy transform 與 LUT。
    /// 這個入口不依賴 RAW decoder，供將來的 reconstruction / fusion 使用。
    public func makeSceneMaster(
        sceneLinear: SceneLinearImage,
        parameters: EditParameters,
        autoWhiteBalanceGains: SIMD3<Double>? = nil
    ) -> SceneMaster {
        var resolvedAutoWhiteBalanceGains = autoWhiteBalanceGains
        if resolvedAutoWhiteBalanceGains == nil,
           parameters.effective.layerA.whiteBalance.preset == .auto {
            resolvedAutoWhiteBalanceGains = analysisReuseCache.autoWhiteBalance(
                image: sceneLinear.image, decoderVersion: sceneLinear.metadata.decoderVersion,
                context: gpu.ciContext
            ).gains
        }
        return SceneMaster(
            image: sceneLinear.image,
            sceneTransform: Self.sceneTransform(for: parameters, metadata: sceneLinear.metadata,
                                                autoWhiteBalanceGains: resolvedAutoWhiteBalanceGains),
            metadata: sceneLinear.metadata,
            versions: sceneLinear.versions,
            lensResolution: sceneLinear.lensResolution,
            scale: sceneLinear.scale
        )
    }

    /// 由編輯參數與 RAW metadata 組出 scene-referred 轉換。
    public static func sceneTransform(
        for parameters: EditParameters, metadata: RawMetadata,
        autoWhiteBalanceGains: SIMD3<Double>? = nil
    ) -> SceneTransform {
        let parameters = parameters.effective
        // 白平衡：preset / manual state 先解析到同一組 Temperature + Tint。
        // CIRAWFilter 已套過 camera WB，只有 metadata 完整時才能安全計算相對偏移。
        let asShot = metadata.asShotWhiteBalance
        let requested = parameters.layerA.whiteBalance.resolved(asShot: asShot)
        let gains: SIMD3<Double>
        if let asShotTemperature = asShot.temperature,
           let asShotTint = asShot.tint,
           let temperature = requested.temperature,
           let tint = requested.tint {
            gains = SceneNormalization.whiteBalanceGains(
                temperature: temperature, tint: tint,
                asShotTemperature: asShotTemperature, asShotTint: asShotTint
            )
        } else {
            // 不用固定數字冒充 As Shot；等待 decoder 提供完整 camera WB。
            gains = SIMD3(repeating: 1)
        }

        return SceneTransform(
            cameraNormalize: .identity,   // CIRAWFilter 已輸出線性 wide-gamut，不需額外矩陣
            layerA: parameters.layerA,
            colorEngine: parameters.colorEngine,
            colorMixer: parameters.colorMixer,
            film: parameters.film,
            whiteBalanceGains: gains * (autoWhiteBalanceGains ?? SIMD3(repeating: 1))
        )
    }

    /// Scene Master → 指定 rendering target 的 display-referred 影像。
    /// `region`（輸出影像座標）只渲染這一塊：LUT 與其前的場景運算只處理區域加上空間效果
    /// 需要的邊界，空間效果仍依整張影像的尺度與座標，結果等於整張渲染後裁出同一塊。
    public func render(
        sceneMaster: SceneMaster,
        parameters: EditParameters,
        target: RenderingTarget? = nil,
        outputColorSpace: CGColorSpace? = nil,
        region: CGRect? = nil
    ) throws -> CIImage {
        let parameters = parameters.effective
        let fullExtent = sceneMaster.image.extent
        let work = region.map { regionWorkRect($0, parameters: parameters, fullExtent: fullExtent) }
        func limited(_ image: CIImage) -> CIImage { work.map { image.cropped(to: $0) } ?? image }
        func finish(_ graded: CIImage) throws -> CIImage {
            let out = try spatialRenderer.apply(parameters.spatial, to: graded,
                                                globalExtent: work == nil ? nil : fullExtent)
            return region.map { out.cropped(to: $0.intersection(fullExtent)) } ?? out
        }
        let target = target ?? parameters.target
        // §11 Finishing 接在 target transform 之後，兩條渲染路徑共用同一段。
        let finishing = FinishingTransform(parameters: parameters.finishing, target: target)
        if parameters.localMasks.contains(where: \.hasActiveAdjustment) {
            let sceneImage = try maskSource(sceneMaster: sceneMaster, parameters: parameters)
            let adjusted = try maskRenderer.apply(parameters.localMasks, to: sceneImage)
            let transform = TargetTransform(
                target: target, tone: parameters.toneMapping,
                gamut: parameters.gamutMapping, film: parameters.film
            )
            var targetParameters = EditParameters()
            targetParameters.toneMapping = parameters.toneMapping
            targetParameters.gamutMapping = parameters.gamutMapping
            targetParameters.finishing = parameters.finishing
            targetParameters.film = parameters.film
            let lut = targetLUTCache.lut(
                key: LUTCache.Key(parameters: targetParameters, target: target, metadata: RawMetadata())
            ) { LUT3D.bake { finishing.apply(transform.apply($0)) } }
            let graded = try lutRenderer.apply(to: limited(adjusted), lut: lut,
                outputColorSpace: outputColorSpace ?? Self.colorSpace(for: target))
            return try finish(graded)
        }
        let lut = lutCache.lut(
            scene: sceneMaster.sceneTransform,
            targetTransform: TargetTransform(
                target: target,
                tone: parameters.toneMapping,
                gamut: parameters.gamutMapping,
                film: parameters.film
            ),
            finishing: finishing,
            key: LUTCache.Key(parameters: parameters, target: target,
                              metadata: sceneMaster.metadata,
                              sceneWhiteBalanceGains: sceneMaster.sceneTransform.whiteBalanceGains)
        )
        let graded = try lutRenderer.apply(
            to: limited(sceneMaster.image),
            lut: lut,
            outputColorSpace: outputColorSpace ?? Self.colorSpace(for: target)
        )
        // §11 空間性 Finishing 進不了 LUT，接在這裡；兩條渲染路徑共用同一段。
        return try finish(graded)
    }

    /// 只渲染 `region` 時實際要處理的範圍：區域加上空間效果的取樣邊界，限制在整張之內。
    public func regionWorkRect(_ region: CGRect, parameters: EditParameters, fullExtent: CGRect) -> CGRect {
        let margin = spatialRenderer.sampleMargin(parameters.effective.spatial, extent: fullExtent)
        return region.insetBy(dx: -margin, dy: -margin).intersection(fullExtent).integral
    }

    /// 預覽覆蓋與輸出選區使用完全相同的 scene-linear 來源。
    public func maskSource(sceneMaster: SceneMaster, parameters: EditParameters) throws -> CIImage {
        var p = EditParameters()
        p.layerA = parameters.layerA
        p.colorEngine = parameters.colorEngine
        p.colorMixer = parameters.colorMixer
        p.film = parameters.film
        let lut = sceneLUTCache.lut(key: LUTCache.Key(
            parameters: p, target: p.target, metadata: sceneMaster.metadata,
            sceneWhiteBalanceGains: sceneMaster.sceneTransform.whiteBalanceGains
        )) {
            LUT3D.bake { sceneMaster.sceneTransform.apply($0) }
        }
        return try lutRenderer.apply(to: sceneMaster.image, lut: lut, outputColorSpace: gpu.workingColorSpace)
    }

    /// Target transform 前的 scene-linear master；保留局部曝光與 HDR headroom，
    /// 不套用 display tone/gamut mapping、transfer function 或 display-referred finishing。
    public func renderSceneLinear(
        sceneMaster: SceneMaster,
        parameters: EditParameters
    ) throws -> CIImage {
        let source = try maskSource(sceneMaster: sceneMaster, parameters: parameters)
        let adjusted: CIImage
        if parameters.localMasks.contains(where: \.hasActiveAdjustment) {
            adjusted = try maskRenderer.apply(parameters.localMasks, to: source)
        } else {
            adjusted = source
        }
        return try applySceneLinearMonochrome(adjusted, film: parameters.film)
    }

    /// Scene-linear 匯出保留原動態範圍並略過 tone／gamut mapping；黑白轉換接在局部遮罩之後，
    /// 讓遮罩判斷仍可使用彩色來源。
    private func applySceneLinearMonochrome(_ image: CIImage, film: FilmParameters) throws -> CIImage {
        guard film.hasMonochromeEffect else { return image }
        var parameters = EditParameters()
        parameters.film = film
        let lut = monochromeLUTCache.lut(key: LUTCache.Key(
            parameters: parameters, target: parameters.target, metadata: RawMetadata()
        )) {
            LUT3D.bake { film.applyingMonochrome(to: $0) }
        }
        return try lutRenderer.apply(to: image, lut: lut, outputColorSpace: gpu.workingColorSpace)
    }

    public func maskImage(_ mask: LocalMask, sceneMaster: SceneMaster, parameters: EditParameters) throws -> CIImage {
        try maskRenderer.image(for: mask, source: maskSource(sceneMaster: sceneMaster, parameters: parameters))
    }

    /// 產生只供預覽使用的診斷覆蓋層；不進正式 render 或 exporter。
    public func diagnosticOverlay(
        mode: DiagnosticOverlayMode,
        sceneMaster: SceneMaster,
        parameters: EditParameters,
        target: RenderingTarget? = nil
    ) throws -> CIImage? {
        guard mode != .off else { return nil }
        let target = target ?? parameters.target
        let transform = TargetTransform(
            target: target, tone: parameters.toneMapping,
            gamut: parameters.gamutMapping, film: parameters.film
        )
        let hasLocalExposure = parameters.localMasks.contains(where: \.hasActiveAdjustment)
        let source: CIImage
        let mappedLUT: LUT3D
        let unmappedLUT: LUT3D
        if hasLocalExposure {
            let scene = try maskSource(sceneMaster: sceneMaster, parameters: parameters)
            source = try maskRenderer.apply(parameters.localMasks, to: scene)
            var targetParameters = EditParameters()
            targetParameters.toneMapping = parameters.toneMapping
            targetParameters.gamutMapping = parameters.gamutMapping
            targetParameters.film = parameters.film
            let key = LUTCache.Key(parameters: targetParameters, target: target, metadata: RawMetadata())
            mappedLUT = diagnosticMappedLUTCache.lut(key: key) {
                LUT3D.bake { transform.targetLinear($0) }
            }
            unmappedLUT = diagnosticUnmappedLUTCache.lut(key: key) {
                LUT3D.bake { transform.targetLinear($0, applyGamutMapping: false) }
            }
        } else {
            source = sceneMaster.image
            let key = LUTCache.Key(parameters: parameters, target: target,
                                   metadata: sceneMaster.metadata,
                                   sceneWhiteBalanceGains: sceneMaster.sceneTransform.whiteBalanceGains)
            mappedLUT = diagnosticMappedLUTCache.lut(key: key) {
                LUT3D.bake { transform.targetLinear(sceneMaster.sceneTransform.apply($0)) }
            }
            unmappedLUT = diagnosticUnmappedLUTCache.lut(key: key) {
                LUT3D.bake {
                    transform.targetLinear(sceneMaster.sceneTransform.apply($0), applyGamutMapping: false)
                }
            }
        }
        let space = Self.diagnosticColorSpace(for: target)
        let mapped = try lutRenderer.apply(to: source, lut: mappedLUT, outputColorSpace: space)
        let unmapped = try lutRenderer.apply(to: source, lut: unmappedLUT, outputColorSpace: space)
        return try diagnosticRenderer.render(
            mode: mode, mapped: mapped, unmapped: unmapped, target: target
        )
    }

    private static func diagnosticColorSpace(for target: RenderingTarget) -> CGColorSpace {
        switch target.gamut {
        case .sRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        case .rec2020: return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        }
    }

    public static func colorSpace(for target: RenderingTarget) -> CGColorSpace {
        // PQ / HLG 檔案必須掛 Rec.2100 描述檔，否則會被當成掛著 Rec.2020 的 SDR。
        switch target.transferFunction {
        case .pq: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        case .sRGB, .linear: break
        }
        switch target.gamut {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .rec2020: return CGColorSpace(name: CGColorSpace.itur_2020)!
        }
    }

    /// EDR 顯示用色彩空間。target 是 HDR + linear 時回傳 extended-linear，
    /// 1.0 以上的 headroom 值才不會在掛色彩空間時被夾掉；其餘情況同 `colorSpace(for:)`。
    public static func edrColorSpace(for target: RenderingTarget) -> CGColorSpace {
        guard target.dynamicRange != .sdr, target.transferFunction == .linear else {
            return colorSpace(for: target)
        }
        switch target.gamut {
        case .sRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        case .rec2020: return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        }
    }
}

/// LUT 烘焙有成本，參數沒變就不要重算 —— 這是預覽能即時的關鍵。
final class LUTCache: @unchecked Sendable {
    struct Key: Hashable {
        private struct ColorParameters: Encodable {
            let layerA: LayerATechnical
            let colorEngine: ColorEngineParameters
            let colorMixer: ColorMixerParameters
            let film: FilmParameters
            let creativeLUTAmount: Double?
            let toneMapping: ToneMappingParameters
            let gamutMapping: GamutMappingParameters
            let finishing: FinishingParameters
        }

        private struct TargetParameters: Hashable {
            let dynamicRange: RenderingTarget.DynamicRange
            let gamut: RenderingTarget.Gamut
            let transferFunction: RenderingTarget.TransferFunction
            let referenceWhiteNits: Double
            let contentPeakNits: Double

            init(_ target: RenderingTarget) {
                dynamicRange = target.dynamicRange
                gamut = target.gamut
                transferFunction = target.transferFunction
                referenceWhiteNits = target.referenceWhiteNits
                contentPeakNits = target.contentPeakNits
            }
        }

        let parameters: Data?
        private let target: TargetParameters
        let cameraModel: String?
        let neutralTemperature: Double?
        let neutralTint: Double?
        let sceneWhiteBalanceGains: SIMD3<Double>?
        private let lutContentFingerprint: String?
        private let lutSnapshotMatchesCurrentFile: Bool
        private let lutAssetID: String?
        private let unavailableLUTAssetID: String?

        init(parameters: EditParameters, target: RenderingTarget, metadata: RawMetadata,
             sceneWhiteBalanceGains: SIMD3<Double>? = nil) {
            let effective = parameters.effective
            var film = effective.film
            let lutAmount = film.hasLUT ? film.lutAmount : nil
            let lutAssetID = film.hasLUT ? film.lutID : nil
            let lutIdentity = lutAssetID.map(CreativeLUTLibrary.cacheIdentity(for:))
            film.lutID = nil
            film.lutAmount = 1

            let colorParameters = ColorParameters(
                layerA: effective.layerA,
                colorEngine: effective.colorEngine,
                colorMixer: effective.colorMixer,
                film: film,
                creativeLUTAmount: lutAmount,
                toneMapping: effective.toneMapping,
                gamutMapping: effective.gamutMapping,
                finishing: effective.finishing
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
            )
            self.parameters = try? encoder.encode(colorParameters)
            self.target = TargetParameters(target)
            self.cameraModel = metadata.cameraModel
            self.neutralTemperature = metadata.neutralTemperature
            self.neutralTint = metadata.neutralTint
            self.sceneWhiteBalanceGains = sceneWhiteBalanceGains
            self.lutContentFingerprint = lutIdentity?.fingerprint
            self.lutSnapshotMatchesCurrentFile = lutIdentity?.matchesLoadedSnapshot ?? true
            self.lutAssetID = lutAssetID
            self.unavailableLUTAssetID = lutIdentity?.fingerprint == nil ? lutAssetID : nil
        }

        var assetMatchesCurrentFile: Bool {
            guard let lutAssetID else { return true }
            guard lutSnapshotMatchesCurrentFile else { return false }
            return CreativeLUTLibrary.contentFingerprint(for: lutAssetID) == lutContentFingerprint
        }

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.parameters == rhs.parameters
                && lhs.target == rhs.target
                && lhs.cameraModel == rhs.cameraModel
                && lhs.neutralTemperature == rhs.neutralTemperature
                && lhs.neutralTint == rhs.neutralTint
                && lhs.sceneWhiteBalanceGains == rhs.sceneWhiteBalanceGains
                && lhs.lutContentFingerprint == rhs.lutContentFingerprint
                && lhs.lutSnapshotMatchesCurrentFile == rhs.lutSnapshotMatchesCurrentFile
                && lhs.unavailableLUTAssetID == rhs.unavailableLUTAssetID
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(parameters)
            hasher.combine(target)
            hasher.combine(cameraModel)
            hasher.combine(neutralTemperature)
            hasher.combine(neutralTint)
            hasher.combine(sceneWhiteBalanceGains)
            hasher.combine(lutContentFingerprint)
            hasher.combine(lutSnapshotMatchesCurrentFile)
            hasher.combine(unavailableLUTAssetID)
        }
    }

    private let lock = NSLock()
    private var cached: (Key, LUT3D)?

    func lut(scene: SceneTransform, targetTransform: TargetTransform,
             finishing: FinishingTransform, key: Key) -> LUT3D {
        lut(key: key) { LUT3D.bake(scene: scene, target: targetTransform, finishing: finishing) }
    }

    func lut(key: Key, bake: () -> LUT3D) -> LUT3D {
        guard key.assetMatchesCurrentFile else {
            let lut = bake()
            return lut
        }
        lock.lock()
        if let cached, cached.0 == key {
            defer { lock.unlock() }
            return cached.1
        }
        lock.unlock()

        let lut = bake()
        guard key.assetMatchesCurrentFile else { return lut }
        lock.lock()
        cached = (key, lut)
        lock.unlock()
        return lut
    }
}
