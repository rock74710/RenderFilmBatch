import Foundation
import ImageIO
import CoreGraphics

/// §1.2 RAW metadata。所有欄位都可能缺席，因此一律 optional。
public struct RawMetadata: Codable, Equatable, Sendable {
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensID: String?
    public var lensName: String?
    public var focalLength: Double?        // mm
    public var aperture: Double?           // f-number
    public var focusDistance: Double?      // m
    public var iso: Double?
    public var exposureTime: Double?       // s
    /// RAW 解碼器回報的中性色度（WB）。
    public var neutralChromaticity: SIMD2<Double>?
    public var neutralTemperature: Double?
    public var neutralTint: Double?
    /// RAW 內嵌的鏡頭校正參數是否存在。
    public var hasEmbeddedLensCorrection: Bool
    public var orientation: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var colorProfileName: String?
    /// 實際使用的 Apple RAW decoder 版本。
    public var decoderVersion: String?

    public init() {
        hasEmbeddedLensCorrection = false
    }

    enum CodingKeys: String, CodingKey {
        case cameraMake, cameraModel, lensID, lensName, focalLength, aperture
        case focusDistance, iso, exposureTime, neutralX, neutralY
        case neutralTemperature, neutralTint, hasEmbeddedLensCorrection
        case orientation, pixelWidth, pixelHeight, colorProfileName, decoderVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraMake = try c.decodeIfPresent(String.self, forKey: .cameraMake)
        cameraModel = try c.decodeIfPresent(String.self, forKey: .cameraModel)
        lensID = try c.decodeIfPresent(String.self, forKey: .lensID)
        lensName = try c.decodeIfPresent(String.self, forKey: .lensName)
        focalLength = try c.decodeIfPresent(Double.self, forKey: .focalLength)
        aperture = try c.decodeIfPresent(Double.self, forKey: .aperture)
        focusDistance = try c.decodeIfPresent(Double.self, forKey: .focusDistance)
        iso = try c.decodeIfPresent(Double.self, forKey: .iso)
        exposureTime = try c.decodeIfPresent(Double.self, forKey: .exposureTime)
        if let x = try c.decodeIfPresent(Double.self, forKey: .neutralX),
           let y = try c.decodeIfPresent(Double.self, forKey: .neutralY) {
            neutralChromaticity = SIMD2(x, y)
        }
        neutralTemperature = try c.decodeIfPresent(Double.self, forKey: .neutralTemperature)
        neutralTint = try c.decodeIfPresent(Double.self, forKey: .neutralTint)
        hasEmbeddedLensCorrection = try c.decodeIfPresent(Bool.self, forKey: .hasEmbeddedLensCorrection) ?? false
        orientation = try c.decodeIfPresent(Int.self, forKey: .orientation)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        colorProfileName = try c.decodeIfPresent(String.self, forKey: .colorProfileName)
        decoderVersion = try c.decodeIfPresent(String.self, forKey: .decoderVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(cameraMake, forKey: .cameraMake)
        try c.encodeIfPresent(cameraModel, forKey: .cameraModel)
        try c.encodeIfPresent(lensID, forKey: .lensID)
        try c.encodeIfPresent(lensName, forKey: .lensName)
        try c.encodeIfPresent(focalLength, forKey: .focalLength)
        try c.encodeIfPresent(aperture, forKey: .aperture)
        try c.encodeIfPresent(focusDistance, forKey: .focusDistance)
        try c.encodeIfPresent(iso, forKey: .iso)
        try c.encodeIfPresent(exposureTime, forKey: .exposureTime)
        try c.encodeIfPresent(neutralChromaticity?.x, forKey: .neutralX)
        try c.encodeIfPresent(neutralChromaticity?.y, forKey: .neutralY)
        try c.encodeIfPresent(neutralTemperature, forKey: .neutralTemperature)
        try c.encodeIfPresent(neutralTint, forKey: .neutralTint)
        try c.encode(hasEmbeddedLensCorrection, forKey: .hasEmbeddedLensCorrection)
        try c.encodeIfPresent(orientation, forKey: .orientation)
        try c.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try c.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
        try c.encodeIfPresent(colorProfileName, forKey: .colorProfileName)
        try c.encodeIfPresent(decoderVersion, forKey: .decoderVersion)
    }
}

extension RawMetadata {
    /// 從 Image I/O 的 properties 字典萃取 metadata。與 CIRAWFilter 的欄位互補。
    public static func from(imageProperties props: [CFString: Any]) -> RawMetadata {
        var m = RawMetadata()
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        m.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
        m.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        m.lensName = exif[kCGImagePropertyExifLensModel] as? String
            ?? exifAux[kCGImagePropertyExifAuxLensModel] as? String
        if let id = exifAux[kCGImagePropertyExifAuxLensID] {
            m.lensID = String(describing: id)
        }
        m.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        m.aperture = exif[kCGImagePropertyExifFNumber] as? Double
        m.focusDistance = exif[kCGImagePropertyExifSubjectDistance] as? Double
        if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Double] {
            m.iso = isoArray.first
        }
        m.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
        m.orientation = props[kCGImagePropertyOrientation] as? Int
        m.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        m.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        m.colorProfileName = props[kCGImagePropertyProfileName] as? String

        // DNG 的 OpcodeList 或製造商的 embedded correction 標記。
        if let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any] {
            m.hasEmbeddedLensCorrection = dng["OpcodeList3" as CFString] != nil
                || dng["OpcodeList2" as CFString] != nil
        }
        return m
    }
}
