import Foundation
import CoreGraphics

public enum ICCDestinationError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupportedModel(String)
    case conversionFailed(String)
    case missingMediaWhitePoint(String)

    public var description: String {
        switch self {
        case .unreadable(let path): return String(localized: "讀不到 ICC 描述檔：\(path)", bundle: .module)
        case .unsupportedModel(let name): return String(localized: "不支援的 ICC 描述檔色彩模型（只接受 RGB 或 CMYK）：\(name)", bundle: .module)
        case .conversionFailed(let name): return String(localized: "轉換到 ICC 描述檔失敗：\(name)", bundle: .module)
        case .missingMediaWhitePoint(let name): return String(localized: "ICC 描述檔沒有可用的媒材白點：\(name)", bundle: .module)
        }
    }
}

/// §8.2 / §10 ICC destination：管線先映射到 target 色域，最後一步交給 ColorSync
/// 依描述檔自己的表格與 rendering intent 轉到目的空間（螢幕、印表機或 CMYK 印刷）。
public struct ICCDestination: Codable, Hashable, Sendable {
    public enum RenderingIntent: String, Codable, CaseIterable, Hashable, Sendable {
        case perceptual, relativeColorimetric

        public var displayName: String {
            switch self {
            case .perceptual: return "Perceptual"
            case .relativeColorimetric: return "Relative Colorimetric"
            }
        }

        var cgIntent: CGColorRenderingIntent {
            switch self {
            case .perceptual: return .perceptual
            case .relativeColorimetric: return .relativeColorimetric
            }
        }
    }

    /// 以路徑記錄，sidecar 不內嵌整份描述檔；檔案不見時明確報錯。
    public var profilePath: String
    public var renderingIntent: RenderingIntent

    public init(profilePath: String, renderingIntent: RenderingIntent = .perceptual) {
        self.profilePath = profilePath
        self.renderingIntent = renderingIntent
    }

    public var displayName: String {
        URL(fileURLWithPath: profilePath).deletingPathExtension().lastPathComponent
    }

    public func loadColorSpace() throws -> CGColorSpace {
        guard let data = FileManager.default.contents(atPath: profilePath),
              let space = CGColorSpace(iccData: data as CFData) else {
            throw ICCDestinationError.unreadable(profilePath)
        }
        guard space.model == .rgb || space.model == .cmyk else {
            throw ICCDestinationError.unsupportedModel(displayName)
        }
        return space
    }

    /// 把 display-referred 影像轉到描述檔空間；回傳的 CGImage 帶著該描述檔。
    public func convert(_ image: CGImage, bitsPerComponent: Int = 8) throws -> CGImage {
        try draw(image, into: loadColorSpace(), bitsPerComponent: bitsPerComponent,
                 intent: renderingIntent.cgIntent)
    }

    /// Soft proof：先轉到描述檔，再以 relative colorimetric 轉回顯示空間。
    /// 紙白模式另讀取 ICC 的 wtpt 標籤，在 Display P3 預覽中模擬媒材白點。
    public func proof(
        _ image: CGImage, displaySpace: CGColorSpace, simulatePaperWhite: Bool = false
    ) throws -> CGImage {
        let converted = try convert(image)
        let returned = try draw(converted, into: displaySpace, bitsPerComponent: 8,
                                intent: .relativeColorimetric)
        return simulatePaperWhite ? try applyPaperWhite(returned, in: displaySpace) : returned
    }

    private func applyPaperWhite(_ image: CGImage, in space: CGColorSpace) throws -> CGImage {
        guard let data = FileManager.default.contents(atPath: profilePath), data.count >= 132 else {
            throw ICCDestinationError.missingMediaWhitePoint(displayName)
        }
        func word(_ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let count = Int(word(128))
        guard count <= (data.count - 132) / 12 else {
            throw ICCDestinationError.missingMediaWhitePoint(displayName)
        }
        var white: SIMD3<Double>?
        for index in 0..<count {
            let entry = 132 + index * 12
            guard data[entry..<(entry + 4)].elementsEqual("wtpt".utf8) else { continue }
            let offset = Int(word(entry + 4))
            guard offset <= data.count - 20,
                  data[offset..<(offset + 4)].elementsEqual("XYZ ".utf8) else { break }
            white = SIMD3((0..<3).map { channel in
                Double(Int32(bitPattern: word(offset + 8 + channel * 4))) / 65536
            })
            break
        }
        guard let white, white.x > 0, white.y > 0, white.z > 0 else {
            throw ICCDestinationError.missingMediaWhitePoint(displayName)
        }
        // ICC wtpt 為 D50 XYZ。以標準 D50/D65 白點比例換算到預覽的 D65 XYZ，
        // 再取出 Display P3 線性 RGB 白點；原始 D50 白點的倍率為 1。
        let xyz = SIMD3(0.95047 * white.x / 0.9642,
                        white.y,
                        1.08883 * white.z / 0.8249)
        let factor = RGBColorSpace.displayP3.fromXYZ(xyz)
        var bytes = try rgbaBytes(image, in: space)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                let encoded = Double(bytes[offset + channel]) / 255
                let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
                let adjusted = max(0, min(1, linear * factor[channel]))
                let result = adjusted <= 0.0031308 ? 12.92 * adjusted : 1.055 * pow(adjusted, 1 / 2.4) - 0.055
                bytes[offset + channel] = UInt8((result * 255).rounded())
            }
        }
        return try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let result = context.makeImage() else {
                throw ICCDestinationError.conversionFailed(displayName)
            }
            return result
        }
    }

    /// 以 ICC 往返造成的顏色差異標出目的描述檔無法保留的顏色。
    /// 使用 relative proof，避免紙白模擬的整體亮度變化被當作色域外。
    public func gamutWarningOverlay(
        _ image: CGImage, displaySpace: CGColorSpace, tolerance: UInt8 = 12
    ) throws -> CGImage {
        // 用 relative colorimetric 檢查目的色域的裁切；perceptual 會重排色域內顏色。
        let converted = try draw(image, into: loadColorSpace(), bitsPerComponent: 8,
                                 intent: .relativeColorimetric)
        let proofed = try draw(converted, into: displaySpace, bitsPerComponent: 8,
                               intent: .relativeColorimetric)
        let original = try rgbaBytes(image, in: displaySpace)
        let proofBytes = try rgbaBytes(proofed, in: displaySpace)
        var overlay = [UInt8](repeating: 0, count: original.count)
        for offset in stride(from: 0, to: original.count, by: 4) {
            let difference = (0..<3).map { abs(Int(original[offset + $0]) - Int(proofBytes[offset + $0])) }.max() ?? 0
            if difference > tolerance {
                overlay[offset] = 160
                overlay[offset + 2] = 160
                overlay[offset + 3] = 160
            }
        }
        return try overlay.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: displaySpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let result = context.makeImage() else {
                throw ICCDestinationError.conversionFailed(displayName)
            }
            return result
        }
    }

    private func rgbaBytes(_ image: CGImage, in space: CGColorSpace) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setRenderingIntent(.relativeColorimetric)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard success else { throw ICCDestinationError.conversionFailed(displayName) }
        return bytes
    }

    private func draw(
        _ image: CGImage, into space: CGColorSpace, bitsPerComponent: Int,
        intent: CGColorRenderingIntent
    ) throws -> CGImage {
        // CMYK bitmap 不能帶 alpha；RGB 用不透明的 skip 格式，輸出檔同樣不帶 alpha。
        let alpha: CGImageAlphaInfo = space.model == .cmyk ? .none : .noneSkipLast
        // CMYK 四個通道；RGB 三個通道加一個略過的位元組，同樣每像素 4 個分量。
        let components = 4
        var info = alpha.rawValue
        if bitsPerComponent == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: image.width * components * bitsPerComponent / 8,
            space: space, bitmapInfo: info
        ) else { throw ICCDestinationError.conversionFailed(displayName) }
        context.setRenderingIntent(intent)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else {
            throw ICCDestinationError.conversionFailed(displayName)
        }
        return result
    }
}
