import Foundation
import CoreImage
import ImageIO

public struct BatchExportSettings: Sendable {
    public enum FileFormat: String, Codable, Sendable, CaseIterable {
        case tiff, heic, jpeg, png

        /// PNG 沒有 HDR 路徑；勾選 HDR 時仍輸出 SDR。
        public var supportsHDR: Bool { self != .png }
        /// 有損格式才用得到品質設定。
        public var usesQuality: Bool { self == .heic || self == .jpeg }
    }
    public enum WhiteBalance: Sendable {
        case camera
        case automatic
        case preset(WhiteBalancePreset)
    }
    /// Output pixel size; aspect ratio is always kept and sizes round to whole pixels.
    public enum OutputSize: Sendable, Equatable {
        /// 輸出長邊上限；一億畫素原圖再超解析度 2 倍（長邊約 23000）也碰不到，只擋會耗盡記憶體的誤輸入。
        public static let maxLongEdge = 32768

        case original
        case longEdge(Int)
        case percent(Double)

        public func pixelSize(for source: CGSize) -> CGSize {
            let factor: Double
            switch self {
            case .original: return source
            case .longEdge(let pixels): factor = Double(pixels) / Double(max(source.width, source.height))
            case .percent(let percent): factor = percent / 100
            }
            let longest = Double(max(source.width, source.height))
            let capped = min(factor, Double(Self.maxLongEdge) / max(longest, 1))
            return CGSize(width: max(1, (source.width * capped).rounded()),
                          height: max(1, (source.height * capped).rounded()))
        }
    }

    public var profile: ColorProfile = .natural
    /// 與單張編輯相同的底片風格快照、比例與開關。
    public var film = FilmParameters()
    public var grain = GrainParameters()
    public var curve = FinalCurve()
    public var automaticExposure = false
    /// 逐張手動補償，範圍 ±3 EV；疊加在 auto EV 或 absolute override 上。
    public var exposureCompensationEV = 0.0
    /// 匹配後的絕對基準 EV；優先於逐張 auto EV 與 smooth EV，再加上 compensation。
    public var absoluteExposureEV: Double?
    /// Meters faces/subject/saliency first and darkens a detected sky separately (sky needs macOS 27).
    public var sceneAwareExposure = false
    public var whiteBalance: WhiteBalance = .camera
    public var format: FileFormat = .heic
    public var hdr = false
    /// HEIC／JPEG 壓縮品質 0–1。
    public var quality = 0.9
    public var hdrTransfer: RenderingTarget.TransferFunction = .pq
    public var outputSize: OutputSize = .original
    /// RAW luminance noise reduction 0–1 (neural on RAW 9 cameras); nil keeps the camera default.
    public var noiseReduction: Double?
    /// Enlarge with Real-ESRGAN instead of Lanczos when the target is bigger than the photo (SDR only).
    public var superResolution = false
    /// 逐張用 `ColorEngineOptimizer` 調整色彩引擎的保護與強度，和主程式的「自動色彩最佳化」相同。
    public var automaticColor = false
    /// 逐張偵測地平線並拉直（`AutoStraighten`），旋轉後裁掉黑邊。
    public var automaticStraighten = false
    /// 自動膚色強度：0 關閉，1–10 越高越接近自然膚色範圍（`PortraitRetouch`）。
    public var skinToneLevel = 0
    /// 自動柔膚強度：0 關閉，1–10 越高斑駁削得越多，毛孔紋理保留。
    public var skinSmoothingLevel = 0

    public init() {}

    public var colorBasis: ColorBasis {
        ColorBasis.selection(profile: profile, film: film)
    }

    /// 與單張編輯共用互斥選取；prepare 仍沿用原有色彩、影調與黑白位置。
    public mutating func applyColorBasis(_ basis: ColorBasis) {
        guard basis != .existing else { return }
        var parameters = EditParameters()
        parameters.applyColorBasis(basis)
        profile = parameters.colorEngine.profile
        film = parameters.film
    }

    /// 實際是否輸出 HDR：格式不支援時退回 SDR。
    public var isHDR: Bool { hdr && format.supportsHDR }

    public var exporterFormat: Exporter.Format {
        switch (format, isHDR) {
        case (.tiff, false): .tiff
        case (.tiff, true): .tiff16
        case (.heic, _): .heic
        case (.jpeg, false): .jpeg
        case (.jpeg, true): .jpegHDR
        case (.png, _): .png
        }
    }

    public var target: RenderingTarget {
        isHDR ? .hdrExport(transfer: hdrTransfer, referenceWhiteNits: 203,
                         contentPeakNits: 1000) : .preset(.appleSDR)
    }
}

public struct BatchExportResult: Sendable {
    public let outputURL: URL
    public let appliedExposureEV: Double
    /// Extra EV applied inside the sky mask on top of `appliedExposureEV`; 0 without a sky layer.
    public let appliedSkyEV: Double
    public let meteringSources: [String]
    public let automaticWhiteBalanceUsedFallback: Bool
    /// True when noise reduction ran on the RAW 9 neural decoder.
    public let neuralNoiseReduction: Bool
    public let superResolved: Bool
    public let automaticColorApplied: Bool
    /// 自動水平套用的旋轉角度（度）；未偵測到或未開啟為 0。
    public let straightenDegrees: Double

    public init(outputURL: URL, appliedExposureEV: Double, appliedSkyEV: Double,
                meteringSources: [String], automaticWhiteBalanceUsedFallback: Bool,
                neuralNoiseReduction: Bool, superResolved: Bool, automaticColorApplied: Bool,
                straightenDegrees: Double = 0) {
        self.outputURL = outputURL
        self.appliedExposureEV = appliedExposureEV
        self.appliedSkyEV = appliedSkyEV
        self.meteringSources = meteringSources
        self.automaticWhiteBalanceUsedFallback = automaticWhiteBalanceUsedFallback
        self.neuralNoiseReduction = neuralNoiseReduction
        self.superResolved = superResolved
        self.automaticColorApplied = automaticColorApplied
        self.straightenDegrees = straightenDegrees
    }
}

/// RAW 的拍攝資訊（EXIF、GPS、機身鏡頭）寫進輸出檔。
public enum BatchMetadata {
    /// 讀 RAW 的 ImageIO 屬性，只留拍攝資訊。方向已套用在影像上、尺寸與色彩描述檔由輸出決定，
    /// 這些欄位不帶過去，避免照片被再轉一次或標錯尺寸。
    public static func outputProperties(fromRaw url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var properties: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = raw[key] { properties[key as String] = value }
        }
        if var tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        return properties
    }
}

/// 相似照片（同一組連拍或同場景）共用一個自動 EV，避免同組照片亮度跳動。
public enum BatchExposureSmoothing {
    public struct Shot: Sendable, Equatable {
        public var date: Date?
        public var iso: Double?
        public var exposureTime: Double?
        public var aperture: Double?

        public init(date: Date?, iso: Double?, exposureTime: Double?, aperture: Double?) {
            self.date = date
            self.iso = iso
            self.exposureTime = exposureTime
            self.aperture = aperture
        }

        /// 只讀 EXIF，不解碼 RAW。
        public static func read(from url: URL) -> Shot {
            let properties = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
            let metadata = RawMetadata.from(imageProperties: properties)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(formatter.date(from:))
            return Shot(date: date, iso: metadata.iso, exposureTime: metadata.exposureTime,
                        aperture: metadata.aperture)
        }
    }

    /// 依檔案順序分組：ISO、快門、光圈都相同，且和上一張的拍攝時間相差不超過 `maxGap` 秒才算同組。
    /// 缺拍攝時間的照片自成一組。
    public static func groups(_ shots: [Shot], maxGap: TimeInterval = 60) -> [Int] {
        var result: [Int] = []
        for (index, shot) in shots.enumerated() {
            guard index > 0 else { result.append(0); continue }
            let previous = shots[index - 1]
            let same = shot.date != nil && previous.date != nil
                && abs(shot.date!.timeIntervalSince(previous.date!)) <= maxGap
                && shot.iso == previous.iso && shot.exposureTime == previous.exposureTime
                && shot.aperture == previous.aperture
            result.append(same ? result[index - 1] : result[index - 1] + 1)
        }
        return result
    }

    /// 同組照片改用組內 EV 中位數；沒有分析結果（nil）的照片維持 nil。
    public static func smoothed(evs: [Double?], groups: [Int]) -> [Double?] {
        var medians: [Int: Double] = [:]
        for group in Set(groups) {
            let values = zip(evs, groups).compactMap { $1 == group ? $0 : nil }.sorted()
            guard !values.isEmpty else { continue }
            let middle = values.count / 2
            medians[group] = values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
        }
        return zip(evs, groups).map { ev, group in ev == nil ? nil : medians[group] }
    }
}

/// 批次結束時寫在輸出資料夾的 CSV 報告。
public enum BatchReport {
    public enum Outcome: Sendable {
        case exported(BatchExportResult)
        case skipped
        case failed(String)
    }

    public struct Row: Sendable {
        public var file: String
        public var outcome: Outcome
        public init(file: String, outcome: Outcome) {
            self.file = file
            self.outcome = outcome
        }
    }

    public static let header = "file,status,output,exposure_ev,sky_ev,metering,wb_fallback,auto_color,straighten_deg,neural_nr,super_resolution,error"

    public static func csv(_ rows: [Row]) -> String {
        func field(_ text: String) -> String {
            text.contains(where: { ",\"\n".contains($0) })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        func flag(_ value: Bool) -> String { value ? "yes" : "no" }
        let lines = rows.map { row -> String in
            let columns: [String]
            switch row.outcome {
            case .exported(let r):
                columns = ["exported", r.outputURL.lastPathComponent,
                           String(format: "%.2f", r.appliedExposureEV), String(format: "%.2f", r.appliedSkyEV),
                           r.meteringSources.joined(separator: "+"), flag(r.automaticWhiteBalanceUsedFallback),
                           flag(r.automaticColorApplied), String(format: "%.2f", r.straightenDegrees),
                           flag(r.neuralNoiseReduction), flag(r.superResolved), ""]
            case .skipped:
                columns = ["skipped"] + Array(repeating: "", count: 10)
            case .failed(let message):
                columns = ["failed"] + Array(repeating: "", count: 9) + [message]
            }
            return ([row.file] + columns).map(field).joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }
}

public enum BatchExportError: Error, CustomStringConvertible {
    case outputAlreadyExists(URL)

    public var description: String {
        switch self {
        case .outputAlreadyExists(let url):
            return String(localized: "輸出檔已存在：\(url.lastPathComponent)", bundle: .module)
        }
    }
}

private final class ReusableProcessedRenderer: @unchecked Sendable {
    private let gpu: GPUContext
    private let lock = NSLock()
    private var renderer: ProcessedImageRenderer?

    init(gpu: GPUContext) { self.gpu = gpu }

    func render(source: DecodedProcessedImage, parameters: EditParameters,
                target: RenderingTarget, maxDimension: Int? = nil,
                autoWhiteBalanceGains: SIMD3<Double>? = nil) throws -> CIImage {
        try Task<Never, Never>.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        try Task<Never, Never>.checkCancellation()
        if renderer == nil { renderer = try ProcessedImageRenderer(gpu: gpu) }
        let image = try renderer!.render(source: source, parameters: parameters, target: target,
                                         maxDimension: maxDimension,
                                         autoWhiteBalanceGains: autoWhiteBalanceGains)
        try Task<Never, Never>.checkCancellation()
        return image
    }
}

/// One-file batch operation. The UI owns folder enumeration, progress and cancellation.
public struct BatchExporter: Sendable {
    public let pipeline: RenderPipeline
    public let exporter: Exporter
    private let processedRenderer: ReusableProcessedRenderer
    private let previewSourceCache = BatchPreviewSourceCache()

    enum ExposureSource {
        case raw(DecodedRaw)
        case processed(DecodedProcessedImage)
    }

    public init(pipeline: RenderPipeline) {
        self.pipeline = pipeline
        self.exporter = Exporter(gpu: pipeline.gpu)
        self.processedRenderer = ReusableProcessedRenderer(gpu: pipeline.gpu)
    }

    public func releasePreviewSources() {
        previewSourceCache.removeAll()
    }

    /// Input types accepted by the batch app. Processed photos always use the SDR Image I/O path.
    public static func isSupportedInput(_ url: URL) -> Bool {
        RawDecoder.isSupported(url) || ProcessedImageDecoder.isSupported(url)
    }

    /// 單張的渲染準備結果：scene master、參數，以及回報用的分析資訊。
    struct Prepared {
        var master: SceneMaster
        var parameters: EditParameters
        var skyEV: Double
        var meteringSources: [String]
        var whiteBalanceFallback: Bool
        var automaticColorApplied: Bool
        var straightenDegrees: Double
        var neuralNoiseReduction: Bool
    }

    struct PreparedProcessed {
        var source: DecodedProcessedImage
        var parameters: EditParameters
        var exposureEV: Double
        var skyEV: Double
        var meteringSources: [String]
        var autoWhiteBalanceGains: SIMD3<Double>?
        var whiteBalanceFallback: Bool
        var automaticColorApplied: Bool
        var straightenDegrees: Double
    }

    struct ExposureMatchAnalyses {
        var meteringMap: ExposureMetering.Map?
        var skyMedian: Double?
        var autoWhiteBalance: AutoWhiteBalance.Result?
        var straightenDegrees: Double?
    }

    /// 只做自動 EV 分析（EV 平滑的第一輪）。已有匹配 override 時不再分析或平滑。
    public func analyzeExposure(rawURL: URL, settings: BatchExportSettings) async throws -> Double {
        guard settings.automaticExposure, settings.absoluteExposureEV == nil else { return 0 }
        if ProcessedImageDecoder.isSupported(rawURL) {
            let decoded = try ProcessedImageDecoder().decode(url: rawURL, context: pipeline.gpu.ciContext)
            try Task.checkCancellation()
            return await globalExposure(decoded.image, settings: settings).ev
        }
        let decoded = try pipeline.decoder.decode(url: rawURL, luminanceNoiseReduction: settings.noiseReduction)
        try Task.checkCancellation()
        return await globalExposure(decoded.image, settings: settings).ev
    }

    private func globalExposure(_ image: CIImage, settings: BatchExportSettings) async
        -> (ev: Double, map: ExposureMetering.Map?) {
        let context = pipeline.gpu.ciContext
        guard settings.sceneAwareExposure else {
            return (AutoExposure.analyze(image, context: context).ev, nil)
        }
        let map = await ExposureMetering.map(for: image, context: context)
        return (AutoExposure.analyze(image, context: context, weights: map.weights).ev, map)
    }

    /// precedence：absolute override > 平滑 EV > auto EV > 0；最後再加手動補償。
    /// absolute override 仍可做場景天空修正，但不會被 auto 或 smooth 替換。
    /// `maxDimension` 給預覽用，在測光之後才縮圖。
    func prepare(decoded: DecodedRaw, settings: BatchExportSettings, exposureEV: Double?,
                 maxDimension: Int? = nil,
                 reusableAnalyses: ExposureMatchAnalyses? = nil) async throws -> Prepared {
        let performanceInterval = RFPerformance.begin("RAWPrepare")
        defer { RFPerformance.end("RAWPrepare", performanceInterval) }
        var parameters = EditParameters()
        parameters.applyProfile(settings.profile)
        parameters.film = settings.film
        parameters.spatial.grain = settings.grain
        parameters.finishing.curve = settings.curve

        let context = pipeline.gpu.ciContext
        var sky: (mask: CIImage, ev: Double)?
        var meteringSources: [String] = []
        let adjustment = BatchExposureAdjustment(compensationEV: settings.exposureCompensationEV,
                                                matchedExposureEV: settings.absoluteExposureEV)
        if settings.automaticExposure {
            let global: (ev: Double, map: ExposureMetering.Map?)
            if settings.absoluteExposureEV == nil {
                global = await globalExposure(decoded.image, settings: settings)
            } else if settings.sceneAwareExposure {
                let map: ExposureMetering.Map
                if let reused = reusableAnalyses?.meteringMap {
                    map = reused
                } else {
                    map = await ExposureMetering.map(for: decoded.image, context: context)
                }
                global = (0, map)
            } else {
                global = (0, nil)
            }
            guard let ev = adjustment.effectiveEV(automaticExposure: true, automaticEV: global.ev,
                                                   smoothedEV: exposureEV) else {
                throw BatchExposureError.invalidValue
            }
            parameters.layerA.exposureEV = ev
            if let map = global.map {
                meteringSources = map.sources
                let skyMedian: Double?
                if let reusableAnalyses {
                    skyMedian = reusableAnalyses.skyMedian
                } else if let mask = map.sky {
                    skyMedian = AutoExposure.analyze(decoded.image, context: context, weights: mask).medianLuminance
                } else {
                    skyMedian = nil
                }
                if let mask = map.sky, let skyMedian {
                    let skyEV = AutoExposure.skyEV(skyMedian: skyMedian, globalEV: ev)
                    if skyEV != 0 { sky = (mask, skyEV) }
                }
            }
        } else {
            guard let ev = adjustment.effectiveEV(automaticExposure: false, automaticEV: 0,
                                                   smoothedEV: exposureEV) else {
                throw BatchExposureError.invalidValue
            }
            parameters.layerA.exposureEV = ev
        }
        var autoWhiteBalanceGains: SIMD3<Double>?
        var whiteBalanceFallback = false
        switch settings.whiteBalance {
        case .camera:
            break
        case .automatic:
            let result = reusableAnalyses?.autoWhiteBalance
                ?? pipeline.cachedAutoWhiteBalance(decoded: decoded)
            autoWhiteBalanceGains = result.gains
            whiteBalanceFallback = result.usedFallback
        case .preset(let preset):
            parameters.layerA.whiteBalance.select(preset)
        }

        // await 之後的影像建構使用局部 pool，避免暫存圖跟著整個批次 Task 存活。
        return try autoreleasepool {
            var sceneLinear = try pipeline.reconstruct(decoded: decoded, parameters: parameters,
                                                       maxDimension: maxDimension)
            if let sky {
                let mask = sceneLinear.scale == 1 ? sky.mask
                    : sky.mask.transformed(by: CGAffineTransform(scaleX: sceneLinear.scale, y: sceneLinear.scale))
                sceneLinear = SceneLinearImage(
                    image: AutoExposure.applyRegionalEV(sky.ev, mask: mask, to: sceneLinear.image),
                    metadata: sceneLinear.metadata, versions: sceneLinear.versions,
                    lensResolution: sceneLinear.lensResolution, scale: sceneLinear.scale)
            }
            // 臉在全解析度上找，預覽與輸出用同一份遮罩；要在拉直之前做，遮罩座標才對得上。
            if settings.skinToneLevel > 0 || settings.skinSmoothingLevel > 0,
               let portrait = PortraitRetouch.analyze(decoded.image, exposureEV: parameters.layerA.exposureEV,
                                                      context: context) {
                var image = sceneLinear.image
                let mask = portrait.mask(fittedTo: image.extent)
                // 每張臉各自量、各自修正：合照裡每個人的光線可能不同（窗邊、燈下）。
                if settings.skinToneLevel > 0 {
                    image = PortraitRetouch.correctTone(
                        image, faces: portrait.faces(fittedTo: image.extent),
                        transform: RenderPipeline.sceneTransform(for: parameters, metadata: sceneLinear.metadata,
                                                                 autoWhiteBalanceGains: autoWhiteBalanceGains),
                        level: settings.skinToneLevel, context: context)
                }
                image = PortraitRetouch.smooth(image, mask: mask, faceWidth: portrait.faceWidth(in: image.extent),
                                               level: settings.skinSmoothingLevel)
                sceneLinear = SceneLinearImage(
                    image: image, metadata: sceneLinear.metadata, versions: sceneLinear.versions,
                    lensResolution: sceneLinear.lensResolution, scale: sceneLinear.scale)
            }
            // 角度在全解析度上偵測，proxy 與正式輸出才會旋轉同樣的角度；天空遮罩已先套好。
            let straighten = reusableAnalyses?.straightenDegrees
                ?? (settings.automaticStraighten ? AutoStraighten.detect(decoded.image, context: context) ?? 0 : 0)
            if straighten != 0 {
                sceneLinear = SceneLinearImage(
                    image: AutoStraighten.apply(straighten, to: sceneLinear.image),
                    metadata: sceneLinear.metadata, versions: sceneLinear.versions,
                    lensResolution: sceneLinear.lensResolution, scale: sceneLinear.scale)
            }
            var master = pipeline.makeSceneMaster(
                sceneLinear: sceneLinear, parameters: parameters,
                autoWhiteBalanceGains: autoWhiteBalanceGains
            )
            if settings.automaticColor {
                // 同主程式：統計「色彩引擎尚未作用」的畫面，再套用完整建議。
                var probe = parameters
                probe.colorEngine.enabled = false
                probe.layerA.chroma = 1
                let stats = ColorEngineOptimizer.statistics(
                    image: master.image, context: context,
                    transform: RenderPipeline.sceneTransform(for: probe, metadata: master.metadata,
                                                             autoWhiteBalanceGains: autoWhiteBalanceGains))
                parameters.colorEngine = ColorEngineOptimizer.suggest(base: parameters.colorEngine, statistics: stats)
                master = pipeline.makeSceneMaster(sceneLinear: sceneLinear, parameters: parameters,
                                                  autoWhiteBalanceGains: autoWhiteBalanceGains)
            }
            return Prepared(master: master, parameters: parameters, skyEV: sky?.ev ?? 0,
                            meteringSources: meteringSources, whiteBalanceFallback: whiteBalanceFallback,
                            automaticColorApplied: settings.automaticColor,
                            straightenDegrees: straighten,
                            neuralNoiseReduction: settings.noiseReduction != nil
                                && decoded.metadata.decoderVersion.map { $0.hasPrefix("9") } == true)
        }
    }

    func prepareProcessed(decoded: DecodedProcessedImage, settings: BatchExportSettings,
                          exposureEV: Double?,
                          reusableAnalyses: ExposureMatchAnalyses? = nil) async throws -> PreparedProcessed {
        let performanceInterval = RFPerformance.begin("ProcessedPrepare")
        defer { RFPerformance.end("ProcessedPrepare", performanceInterval) }
        var parameters = ProcessedImageRenderer.defaults()
        if settings.profile != .natural {
            parameters.applyProfile(settings.profile)
            parameters.colorEngine.enabled = true
        }
        parameters.film = settings.film
        parameters.spatial.grain = settings.grain
        parameters.finishing.curve = settings.curve

        let context = pipeline.gpu.ciContext
        var meteringSources: [String] = []
        var skyEV = 0.0
        var sourceImage = decoded.image
        var sourceWasTransformed = false
        var analyzedExposureEV = 0.0
        let adjustment = BatchExposureAdjustment(compensationEV: settings.exposureCompensationEV,
                                                matchedExposureEV: settings.absoluteExposureEV)
        if settings.automaticExposure {
            let global: (ev: Double, map: ExposureMetering.Map?)
            if settings.absoluteExposureEV == nil {
                global = await globalExposure(decoded.image, settings: settings)
            } else if settings.sceneAwareExposure {
                let map: ExposureMetering.Map
                if let reused = reusableAnalyses?.meteringMap {
                    map = reused
                } else {
                    map = await ExposureMetering.map(for: decoded.image, context: context)
                }
                global = (0, map)
            } else {
                global = (0, nil)
            }
            guard let ev = adjustment.effectiveEV(automaticExposure: true, automaticEV: global.ev,
                                                   smoothedEV: exposureEV) else {
                throw BatchExposureError.invalidValue
            }
            analyzedExposureEV = ev
            parameters.layerA.exposureEV = analyzedExposureEV
            if let map = global.map {
                meteringSources = map.sources
                let skyMedian: Double?
                if let reusableAnalyses {
                    skyMedian = reusableAnalyses.skyMedian
                } else if let mask = map.sky {
                    skyMedian = AutoExposure.analyze(decoded.image, context: context,
                                                     weights: mask).medianLuminance
                } else {
                    skyMedian = nil
                }
                if let mask = map.sky, let skyMedian {
                    skyEV = AutoExposure.skyEV(skyMedian: skyMedian, globalEV: analyzedExposureEV)
                    if skyEV != 0 {
                        sourceImage = autoreleasepool {
                            AutoExposure.applyRegionalEV(skyEV, mask: mask, to: sourceImage)
                        }
                        sourceWasTransformed = true
                    }
                }
            }
        } else {
            guard let ev = adjustment.effectiveEV(automaticExposure: false, automaticEV: 0,
                                                   smoothedEV: exposureEV) else {
                throw BatchExposureError.invalidValue
            }
            analyzedExposureEV = ev
            parameters.layerA.exposureEV = analyzedExposureEV
        }

        return try autoreleasepool {
            var autoWhiteBalanceGains: SIMD3<Double>?
            var whiteBalanceFallback = false
            switch settings.whiteBalance {
            case .camera:
                break
            case .automatic, .preset(.auto):
                parameters.layerA.whiteBalance.select(.auto)
                let result = reusableAnalyses?.autoWhiteBalance
                    ?? AutoWhiteBalance.analyze(decoded.image, context: context)
                autoWhiteBalanceGains = result.gains
                whiteBalanceFallback = result.usedFallback
            case .preset(let preset):
                parameters.layerA.whiteBalance.select(preset)
            }

            if settings.skinToneLevel > 0 || settings.skinSmoothingLevel > 0,
               let portrait = PortraitRetouch.analyze(sourceImage, exposureEV: parameters.layerA.exposureEV,
                                                      context: context) {
                var image = sourceImage
                let mask = portrait.mask(fittedTo: image.extent)
                var transformMetadata = decoded.metadata
                transformMetadata.neutralTemperature = transformMetadata.neutralTemperature ?? 6500
                transformMetadata.neutralTint = transformMetadata.neutralTint ?? 0
                if settings.skinToneLevel > 0 {
                    image = PortraitRetouch.correctTone(
                        image, faces: portrait.faces(fittedTo: image.extent),
                        transform: RenderPipeline.sceneTransform(for: parameters, metadata: transformMetadata,
                                                                 autoWhiteBalanceGains: autoWhiteBalanceGains),
                        level: settings.skinToneLevel, context: context)
                }
                if settings.skinSmoothingLevel > 0 {
                    image = PortraitRetouch.smooth(image, mask: mask,
                                                   faceWidth: portrait.faceWidth(in: image.extent),
                                                   level: settings.skinSmoothingLevel)
                }
                sourceImage = image
                sourceWasTransformed = true
            }

            let straighten = reusableAnalyses?.straightenDegrees
                ?? (settings.automaticStraighten ? AutoStraighten.detect(decoded.image, context: context) ?? 0 : 0)
            if straighten != 0 {
                sourceImage = AutoStraighten.apply(straighten, to: sourceImage)
                sourceWasTransformed = true
            }

            if settings.automaticColor {
                parameters.colorEngine.enabled = true
                var probe = parameters
                probe.colorEngine.enabled = false
                probe.layerA.chroma = 1
                var transformMetadata = decoded.metadata
                transformMetadata.neutralTemperature = transformMetadata.neutralTemperature ?? 6500
                transformMetadata.neutralTint = transformMetadata.neutralTint ?? 0
                let stats = ColorEngineOptimizer.statistics(
                    image: sourceImage, context: context,
                    transform: RenderPipeline.sceneTransform(for: probe, metadata: transformMetadata,
                                                             autoWhiteBalanceGains: autoWhiteBalanceGains))
                parameters.colorEngine = ColorEngineOptimizer.suggest(base: parameters.colorEngine,
                                                                       statistics: stats)
            }

            try Task.checkCancellation()
            let source = DecodedProcessedImage(
                url: decoded.url, image: sourceImage, metadata: decoded.metadata,
                colorSpace: decoded.colorSpace, info: decoded.info,
                colorManagedImage: sourceWasTransformed ? nil : decoded.colorManagedImage
            )
            return PreparedProcessed(source: source, parameters: parameters,
                                     exposureEV: analyzedExposureEV, skyEV: skyEV,
                                     meteringSources: meteringSources,
                                     autoWhiteBalanceGains: autoWhiteBalanceGains,
                                     whiteBalanceFallback: whiteBalanceFallback,
                                     automaticColorApplied: settings.automaticColor,
                                     straightenDegrees: straighten)
        }
    }

    private func result(_ prepared: PreparedProcessed, outputURL: URL,
                        superResolved: Bool) -> BatchExportResult {
        BatchExportResult(outputURL: outputURL, appliedExposureEV: prepared.exposureEV,
                          appliedSkyEV: prepared.skyEV, meteringSources: prepared.meteringSources,
                          automaticWhiteBalanceUsedFallback: prepared.whiteBalanceFallback,
                          neuralNoiseReduction: false, superResolved: superResolved,
                          automaticColorApplied: prepared.automaticColorApplied,
                          straightenDegrees: prepared.straightenDegrees)
    }

    private func result(_ prepared: Prepared, outputURL: URL, superResolved: Bool) -> BatchExportResult {
        BatchExportResult(outputURL: outputURL,
                          appliedExposureEV: prepared.parameters.layerA.exposureEV,
                          appliedSkyEV: prepared.skyEV,
                          meteringSources: prepared.meteringSources,
                          automaticWhiteBalanceUsedFallback: prepared.whiteBalanceFallback,
                          neuralNoiseReduction: prepared.neuralNoiseReduction,
                          superResolved: superResolved,
                          automaticColorApplied: prepared.automaticColorApplied,
                          straightenDegrees: prepared.straightenDegrees)
    }

    func reusableExposureMatchAnalyses(
        source: ExposureSource, settings: BatchExportSettings
    ) async throws -> ExposureMatchAnalyses {
        let image: CIImage
        switch source {
        case .raw(let decoded): image = decoded.image
        case .processed(let decoded): image = decoded.image
        }

        var meteringMap: ExposureMetering.Map?
        var skyMedian: Double?
        if settings.automaticExposure && settings.sceneAwareExposure {
            let map = await ExposureMetering.map(for: image, context: pipeline.gpu.ciContext)
            meteringMap = map
            if let sky = map.sky {
                skyMedian = AutoExposure.analyze(image, context: pipeline.gpu.ciContext,
                                                 weights: sky).medianLuminance
            }
        }

        let needsAutoWhiteBalance: Bool
        switch (source, settings.whiteBalance) {
        case (.raw(_), .automatic), (.processed(_), .automatic), (.processed(_), .preset(.auto)):
            needsAutoWhiteBalance = true
        default:
            needsAutoWhiteBalance = false
        }
        let autoWhiteBalance: AutoWhiteBalance.Result?
        if needsAutoWhiteBalance {
            switch source {
            case .raw(let decoded):
                autoWhiteBalance = pipeline.cachedAutoWhiteBalance(decoded: decoded)
            case .processed:
                autoWhiteBalance = AutoWhiteBalance.analyze(image, context: pipeline.gpu.ciContext)
            }
        } else {
            autoWhiteBalance = nil
        }

        let straightenDegrees = settings.automaticStraighten
            ? AutoStraighten.detect(image, context: pipeline.gpu.ciContext) ?? 0 : nil
        try Task.checkCancellation()
        return ExposureMatchAnalyses(meteringMap: meteringMap, skyMedian: skyMedian,
                                     autoWhiteBalance: autoWhiteBalance,
                                     straightenDegrees: straightenDegrees)
    }

    private func decodeForExposureMatch(_ url: URL, settings: BatchExportSettings) throws -> ExposureSource {
        if ProcessedImageDecoder.isSupported(url) {
            return .processed(try ProcessedImageDecoder().decode(url: url, context: pipeline.gpu.ciContext))
        }
        return .raw(try pipeline.decoder.decode(url: url, luminanceNoiseReduction: settings.noiseReduction))
    }

    /// 使用固定的 512px SDR 預覽座標，避免曝光搜尋反覆完整解 RAW。
    private func renderExposurePreview(source: ExposureSource, settings: BatchExportSettings,
                                       maxDimension: Int,
                                       reusableAnalyses: ExposureMatchAnalyses? = nil) async throws -> CIImage {
        try Task.checkCancellation()
        switch source {
        case .raw(let decoded):
            let prepared = try await prepare(decoded: decoded, settings: settings,
                                             exposureEV: nil, maxDimension: maxDimension,
                                             reusableAnalyses: reusableAnalyses)
            try Task.checkCancellation()
            return try pipeline.render(sceneMaster: prepared.master, parameters: prepared.parameters,
                                       target: RenderingTarget.preset(.appleSDR))
        case .processed(let decoded):
            let prepared = try await prepareProcessed(decoded: decoded, settings: settings, exposureEV: nil,
                                                       reusableAnalyses: reusableAnalyses)
            try Task.checkCancellation()
            return try processedRenderer.render(
                source: prepared.source, parameters: prepared.parameters,
                target: RenderingTarget.preset(.appleSDR), maxDimension: maxDimension,
                autoWhiteBalanceGains: prepared.autoWhiteBalanceGains)
        }
    }

    private func measureExposurePreview(_ image: CIImage, weights: CIImage?, sources: [String])
        -> BatchExposureMatching.Measurement {
        let measured = AutoExposure.analyze(image, context: pipeline.gpu.ciContext, weights: weights)
        return BatchExposureMatching.Measurement(
            medianLuminance: measured.medianLuminance ?? 0,
            highlight99Luminance: measured.highlightLuminance ?? 0,
            validPixelCount: measured.validPixelCount,
            meteringSources: sources)
    }

    /// 以參考照目前的最終 SDR 預覽作為目標，逐張求出 absolute override。
    /// 每個檔案只解碼一次；中間候選會在 512px 預覽上重跑完整風格與曲線渲染。
    public func matchExposure(referenceURL: URL, referenceSettings: BatchExportSettings,
                              targets: [BatchExposureMatchTarget], maxDimension: Int = 512,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws
        -> BatchExposureMatchReport {
        previewSourceCache.removeAll()
        try Task.checkCancellation()
        let referenceSource = try decodeForExposureMatch(referenceURL, settings: referenceSettings)
        let referenceImage = try await renderExposurePreview(source: referenceSource,
                                                             settings: referenceSettings,
                                                             maxDimension: maxDimension)
        let referenceMap = await ExposureMetering.map(for: referenceImage,
                                                      context: pipeline.gpu.ciContext,
                                                      detectSky: false)
        let referenceMeasurement = measureExposurePreview(referenceImage,
                                                           weights: referenceMap.weights,
                                                           sources: referenceMap.sources)
        guard referenceMeasurement.validPixelCount > 0,
              referenceMeasurement.medianLuminance.isFinite,
              referenceMeasurement.medianLuminance > 0 else {
            throw BatchExposureMatching.MatchError.noSamples
        }

        var results: [BatchExposureMatchFileResult] = []
        results.reserveCapacity(targets.count)
        var usedSDRPreview = referenceSettings.isHDR
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            usedSDRPreview = usedSDRPreview || target.settings.isHDR
            if target.photo.standardizedFileURL == referenceURL.standardizedFileURL {
                let adjustment = BatchExposureAdjustment(
                    compensationEV: target.settings.exposureCompensationEV,
                    matchedExposureEV: target.settings.absoluteExposureEV)
                results.append(BatchExposureMatchFileResult(photo: target.photo, isReference: true,
                                                            adjustment: adjustment.isValid ? adjustment : nil,
                                                            search: nil,
                                                            error: adjustment.isValid ? nil : String(localized: "曝光 sidecar 包含無效數值", bundle: .module)))
                progress(index + 1, targets.count)
                continue
            }
            do {
                let source = try decodeForExposureMatch(target.photo, settings: target.settings)
                let reusableAnalyses = try await reusableExposureMatchAnalyses(
                    source: source, settings: target.settings)
                var cachedWeights: CIImage?
                var cachedSources: [String] = []
                let search = try await BatchExposureMatching.search(
                    targetLuminance: referenceMeasurement.medianLuminance,
                    exposureRange: -6...6, iterations: 14, highlightLimit: 0.995
                ) { totalEV in
                    var candidate = target.settings
                    candidate.absoluteExposureEV = totalEV - candidate.exposureCompensationEV
                    let image = try await self.renderExposurePreview(source: source,
                                                                     settings: candidate,
                                                                     maxDimension: maxDimension,
                                                                     reusableAnalyses: reusableAnalyses)
                    if cachedWeights == nil {
                        let map = await ExposureMetering.map(for: image,
                                                             context: self.pipeline.gpu.ciContext,
                                                             detectSky: false)
                        cachedWeights = map.weights
                        cachedSources = map.sources
                    }
                    return self.measureExposurePreview(image, weights: cachedWeights,
                                                       sources: cachedSources)
                }
                let adjustment = try BatchExposureAdjustment(
                    compensationEV: target.settings.exposureCompensationEV
                ).withMatchedTotalEV(search.totalEV)
                results.append(BatchExposureMatchFileResult(photo: target.photo,
                                                            adjustment: adjustment,
                                                            search: search, error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(BatchExposureMatchFileResult(photo: target.photo,
                                                            adjustment: nil, search: nil,
                                                            error: String(describing: error)))
            }
            progress(index + 1, targets.count)
        }
        return BatchExposureMatchReport(reference: referenceURL,
                                        referenceMeasurement: referenceMeasurement,
                                        results: results,
                                        usedSDRPreview: usedSDRPreview)
    }

    /// 用目前設定產生 SDR 縮圖，給批次前預覽。輸出尺寸與超解析度不影響預覽。
    public func preview(rawURL: URL, settings: BatchExportSettings,
                        maxDimension: Int) async throws -> (image: CGImage, result: BatchExportResult) {
        let performanceInterval = RFPerformance.begin("Preview")
        defer { RFPerformance.end("Preview", performanceInterval) }
        // JPEG／HEIC 預覽只解出兩倍預覽尺寸，60MP 原圖不必整張解碼；最後一步仍由原本的
        // 高品質縮小產生預覽，外觀才與全解碼一致。RAW 仍走全解析度。
        let isProcessed = ProcessedImageDecoder.isSupported(rawURL)
        let decodeLimit = maxDimension > 0 ? maxDimension * 2 : nil
        let decoded = try previewSourceCache.source(
            for: rawURL, noiseReduction: settings.noiseReduction,
            maxPixelSize: isProcessed ? decodeLimit : nil
        ) {
            if isProcessed {
                return .processed(try ProcessedImageDecoder().decode(url: rawURL,
                                                                      context: pipeline.gpu.ciContext,
                                                                      maxPixelSize: decodeLimit))
            }
            return .raw(try pipeline.decoder.decode(url: rawURL,
                                                    luminanceNoiseReduction: settings.noiseReduction))
        }
        try Task.checkCancellation()
        switch decoded {
        case .processed(let imageSource):
            let decoded = imageSource
            let prepared = try await prepareProcessed(decoded: decoded, settings: settings, exposureEV: nil)
            return try autoreleasepool {
                let target = RenderingTarget.preset(.appleSDR)
                let rendered = try processedRenderer.render(source: prepared.source,
                                                             parameters: prepared.parameters,
                                                             target: target, maxDimension: maxDimension,
                                                             autoWhiteBalanceGains: prepared.autoWhiteBalanceGains)
                try Task.checkCancellation()
                guard let image = pipeline.gpu.ciContext.createCGImage(
                    rendered, from: rendered.extent, format: .RGBA8,
                    colorSpace: RenderPipeline.colorSpace(for: target)) else {
                    throw ExportError.encodingFailed(String(localized: "無法產生預覽", bundle: .module))
                }
                return (image, result(prepared, outputURL: rawURL, superResolved: false))
            }
        case .raw(let rawSource):
            let prepared = try await prepare(decoded: rawSource, settings: settings, exposureEV: nil,
                                             maxDimension: maxDimension)
            return try autoreleasepool {
                try Task.checkCancellation()
                let target = RenderingTarget.preset(.appleSDR)
                let rendered = try pipeline.render(sceneMaster: prepared.master, parameters: prepared.parameters,
                                                   target: target)
                try Task.checkCancellation()
                guard let image = pipeline.gpu.ciContext.createCGImage(
                    rendered, from: rendered.extent, format: .RGBA8,
                    colorSpace: RenderPipeline.colorSpace(for: target)) else {
                    throw ExportError.encodingFailed(String(localized: "無法產生預覽", bundle: .module))
                }
                return (image, result(prepared, outputURL: rawURL, superResolved: false))
            }
        }
    }

    @discardableResult
    public func process(rawURL: URL, outputURL: URL, settings: BatchExportSettings,
                        exposureEV: Double? = nil) async throws -> BatchExportResult {
        let performanceInterval = RFPerformance.begin("BatchExport")
        defer { RFPerformance.end("BatchExport", performanceInterval) }
        previewSourceCache.removeAll()
        let files = FileManager.default
        guard !files.fileExists(atPath: outputURL.path) else {
            throw BatchExportError.outputAlreadyExists(outputURL)
        }
        // 取消時在各個耗時步驟之間停下，不等整張做完；暫存檔由下面的 defer 清掉。
        let preparedRaw: Prepared?
        let preparedProcessed: PreparedProcessed?
        if ProcessedImageDecoder.isSupported(rawURL) {
            let decoded = try ProcessedImageDecoder().decode(url: rawURL, context: pipeline.gpu.ciContext)
            try Task.checkCancellation()
            preparedProcessed = try await prepareProcessed(decoded: decoded, settings: settings,
                                                           exposureEV: exposureEV)
            preparedRaw = nil
        } else {
            let decoded = try pipeline.decoder.decode(url: rawURL,
                                                       luminanceNoiseReduction: settings.noiseReduction)
            try Task.checkCancellation()
            preparedRaw = try await prepare(decoded: decoded, settings: settings, exposureEV: exposureEV)
            preparedProcessed = nil
        }
        return try autoreleasepool {
            try Task.checkCancellation()
            let context = pipeline.gpu.ciContext
            let metadata = BatchMetadata.outputProperties(fromRaw: rawURL)
            // JPEG HDR 的主圖是 SDR，HDR 資訊放在 gain map 輔助圖（同 `Exporter.exportFullResolution`）。
            let jpegHDR = settings.exporterFormat == .jpegHDR
            func render(_ target: RenderingTarget, outputColorSpace: CGColorSpace? = nil) throws -> CIImage {
                if let preparedRaw {
                    return try pipeline.render(sceneMaster: preparedRaw.master,
                                               parameters: preparedRaw.parameters, target: target,
                                               outputColorSpace: outputColorSpace)
                }
                if let preparedProcessed {
                    return try self.processedRenderer.render(source: preparedProcessed.source,
                                                             parameters: preparedProcessed.parameters, target: target,
                                                             autoWhiteBalanceGains: preparedProcessed.autoWhiteBalanceGains)
                }
                throw ExportError.encodingFailed(String(localized: "無法啟動圖片渲染器", bundle: .module))
            }
            let primaryTarget = jpegHDR ? RenderingTarget.preset(.appleSDR) : settings.target
            let rendered = try render(primaryTarget)
            let (image, superResolved) = try Self.finalImage(rendered, settings: settings, context: context)
            try Task.checkCancellation()
            var hdrImage: CIImage?
            if jpegHDR {
                let auxiliaryTarget = Exporter.jpegHDRAuxiliaryTarget(for: settings.target)
                let hdr = try render(auxiliaryTarget, outputColorSpace: pipeline.gpu.workingColorSpace)
                let linearHDR: CIImage
                if preparedProcessed != nil {
                    linearHDR = try linearWorkingImage(hdr, taggedWith: RenderPipeline.colorSpace(for: auxiliaryTarget),
                                                       context: context)
                } else {
                    linearHDR = hdr
                }
                hdrImage = Self.resize(linearHDR, toPixelSize: image.extent.size)
            }
            let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(
                ".\(UUID().uuidString)-\(outputURL.lastPathComponent)"
            )
            defer { try? files.removeItem(at: temporary) }
            try exporter.write(image: image.settingProperties(metadata), to: temporary, target: settings.target,
                               format: settings.exporterFormat, quality: settings.quality, hdrImage: hdrImage)
            try Task.checkCancellation()
            guard !files.fileExists(atPath: outputURL.path) else {
                throw BatchExportError.outputAlreadyExists(outputURL)
            }
            try files.moveItem(at: temporary, to: outputURL)
            if let preparedRaw { return result(preparedRaw, outputURL: outputURL, superResolved: superResolved) }
            if let preparedProcessed {
                return result(preparedProcessed, outputURL: outputURL, superResolved: superResolved)
            }
            throw ExportError.encodingFailed(String(localized: "無法建立輸出結果", bundle: .module))
        }
    }

    /// 將已成像來源的 HDR 輔助圖重新標記為 pipeline 使用的線性 Rec.2020。
    /// 兩次包裝使用相同像素值，避免把 target 的線性值當成一般 BT.2020 編碼值。
    private func linearWorkingImage(_ image: CIImage, taggedWith outputColorSpace: CGColorSpace,
                                    context: CIContext) throws -> CIImage {
        let extent = image.extent.integral
        guard let cgImage = context.createCGImage(image, from: extent, format: .RGBAh,
                                                  colorSpace: outputColorSpace) else {
            throw ExportError.encodingFailed(String(localized: "無法準備 JPEG HDR 輔助圖", bundle: .module))
        }
        return CIImage(cgImage: cgImage, options: [.colorSpace: pipeline.gpu.workingColorSpace])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Output-size step: Real-ESRGAN 2x first when enlarging with super-resolution on (never for HDR),
    /// then Lanczos to the exact target computed from the rendered size.
    static func finalImage(_ rendered: CIImage, settings: BatchExportSettings,
                           context: CIContext) throws -> (image: CIImage, superResolved: Bool) {
        let target = settings.outputSize.pixelSize(for: rendered.extent.size)
        guard settings.superResolution, !settings.isHDR, target.width > rendered.extent.width else {
            return (resize(rendered, toPixelSize: target), false)
        }
        let upscaled = try SuperResolution.shared().upscale2x(rendered, context: context)
        return (resize(upscaled, toPixelSize: target), true)
    }

    /// Lanczos resample to the exact target pixel size; runs after rendering so metering is size-independent.
    public static func resize(_ image: CIImage, to size: BatchExportSettings.OutputSize) -> CIImage {
        resize(image, toPixelSize: size.pixelSize(for: image.extent.size))
    }

    static func resize(_ image: CIImage, toPixelSize target: CGSize) -> CIImage {
        let extent = image.extent
        guard target != extent.size else { return image }
        let scale = target.height / extent.height
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                            .clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue((target.width / extent.width) / scale, forKey: kCIInputAspectRatioKey)
        return filter.outputImage!.cropped(to: CGRect(origin: .zero, size: target))
    }
}
