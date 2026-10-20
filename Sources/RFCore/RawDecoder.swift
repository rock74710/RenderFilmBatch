import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum RawDecodeError: Error, CustomStringConvertible {
    case unsupportedFile(URL)
    case cannotCreateFilter(URL)
    case noOutputImage(URL)

    public var description: String {
        switch self {
        case .unsupportedFile(let u): return String(localized: "不支援的檔案：\(u.lastPathComponent)", bundle: .module)
        case .cannotCreateFilter(let u): return String(localized: "無法建立 CIRAWFilter：\(u.lastPathComponent)", bundle: .module)
        case .noOutputImage(let u): return String(localized: "RAW 解碼沒有產生影像：\(u.lastPathComponent)", bundle: .module)
        }
    }
}

/// 解碼結果。`image` 為 scene-referred、extended linear range 的 CIImage（INV-1）。
public struct DecodedRaw: @unchecked Sendable {
    public let url: URL
    public let image: CIImage
    public let metadata: RawMetadata
    public let fullSize: CGSize
    /// Core Image 認定的 RAW 解碼色彩空間（線性 wide gamut）。
    public let colorSpace: CGColorSpace
}

/// §1 RAW Decode Engine：以 Apple Core Image `CIRAWFilter` 作為前端。
public struct RawDecoder: Sendable {
    public init() {}

    /// §1.1 支援格式。以 Image I/O 實際回報的 UTI 為準，不硬寫死清單。
    public static var supportedTypeIdentifiers: [String] {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).filter { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .rawImage)
        }
    }

    /// 第一階段明示要求的副檔名（§20）。
    public static let requiredExtensions = ["arw", "cr2", "cr3", "nef", "raf", "dng"]

    public static func isSupported(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return requiredExtensions.contains(url.pathExtension.lowercased())
        }
        if t.conforms(to: .rawImage) { return true }
        return requiredExtensions.contains(url.pathExtension.lowercased())
    }

    /// 解碼 RAW。`decoderVersion` 為 nil 時採用 filter 預設，並把實際版本記錄回 metadata，
    /// 之後重新編輯會固定使用同一版本，避免 macOS 更新造成 rendering 漂移（§1.1）。
    /// `luminanceNoiseReduction` (0–1) nil keeps the camera default; otherwise it switches to the RAW 9
    /// decoder when this camera supports it (Apple's neural noise reduction) and sets the amount.
    public func decode(url: URL, pinnedDecoderVersion: String? = nil,
                       luminanceNoiseReduction: Double? = nil) throws -> DecodedRaw {
        guard Self.isSupported(url) else { throw RawDecodeError.unsupportedFile(url) }
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RawDecodeError.cannotCreateFilter(url)
        }

        // 固定 decoder version。
        let available = filter.supportedDecoderVersions.map { $0.rawValue }
        if let pinned = pinnedDecoderVersion, available.contains(pinned) {
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: pinned)
        } else if luminanceNoiseReduction != nil, let neural = Self.noiseReductionDecoderVersion(available: available) {
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: neural)
        }
        if let amount = luminanceNoiseReduction, filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = Float(min(max(amount, 0), 1))
        }

        // 保持 scene-referred：關掉解碼器自己的 look，色彩由我們的 pipeline 負責。
        filter.isGamutMappingEnabled = false
        filter.boostAmount = 0
        filter.extendedDynamicRangeAmount = 0
        filter.localToneMapAmount = 0
        filter.contrastAmount = 0
        filter.isLensCorrectionEnabled = false   // 光學校正由 §2 自行處理，避免 double correction

        guard var out = filter.outputImage else { throw RawDecodeError.noOutputImage(url) }
        if filter.decoderVersion.rawValue.hasPrefix("9") {
            out = try Self.materializeRAW9(out, url: url)
        }

        var meta = RawMetadata()
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            meta = RawMetadata.from(imageProperties: props)
        }
        meta.decoderVersion = filter.decoderVersion.rawValue
        let neutral = filter.neutralChromaticity
        meta.neutralChromaticity = SIMD2(Double(neutral.x), Double(neutral.y))
        meta.neutralTemperature = Double(filter.neutralTemperature)
        meta.neutralTint = Double(filter.neutralTint)
        if meta.pixelWidth == nil {
            meta.pixelWidth = Int(out.extent.width)
            meta.pixelHeight = Int(out.extent.height)
        }
        if !meta.hasEmbeddedLensCorrection {
            meta.hasEmbeddedLensCorrection = filter.isLensCorrectionSupported
        }

        let cs = out.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        return DecodedRaw(
            url: url,
            image: out,
            metadata: meta,
            fullSize: out.extent.size,
            colorSpace: cs
        )
    }

    /// RAW 9 (or 9DNG) runs luminance noise reduction on the Neural Engine; older versions use classic filtering.
    /// RAW 9 在非預設 working space（我們的線性 Rec.2020）裡算出的顏色是錯的（紅色掉到負值、整張偏青）。
    /// 先用預設 working space 的 context 轉成線性 Rec.2020 中間影像，再交回 pipeline。
    private static let raw9Context = CIContext(options: [.cacheIntermediates: false])

    static func materializeRAW9(_ image: CIImage, url: URL) throws -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        guard let cg = raw9Context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space) else {
            throw RawDecodeError.noOutputImage(url)
        }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(
            translationX: image.extent.minX, y: image.extent.minY))
    }

    static func noiseReductionDecoderVersion(available: [String]) -> String? {
        available.first { $0 == "9" || $0 == "9DNG" }
    }

    /// 可用的 decoder 版本清單，供 UI 顯示與鎖定。
    public func availableDecoderVersions(for url: URL) -> [String] {
        (CIRAWFilter(imageURL: url)?.supportedDecoderVersions ?? []).map { $0.rawValue }
    }
}
