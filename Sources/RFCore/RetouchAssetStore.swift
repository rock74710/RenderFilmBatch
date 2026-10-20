import Foundation
import CoreImage
import CryptoKit

public enum RetouchAssetError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidPatch
    case unsafeAssetName
    case missingAsset
    case assetEscapesDirectory
    case hashMismatch
    case unreadableAsset
    case cannotEncode

    public var description: String {
        switch self {
        case .invalidPatch: return String(localized: "修補資產的範圍或來源尺寸無效", bundle: .module)
        case .unsafeAssetName: return String(localized: "修補資產名稱不安全", bundle: .module)
        case .missingAsset: return String(localized: "找不到修補資產", bundle: .module)
        case .assetEscapesDirectory: return String(localized: "修補資產連結指向資料夾以外的位置", bundle: .module)
        case .hashMismatch: return String(localized: "修補資產雜湊不符，檔案可能已損壞", bundle: .module)
        case .unreadableAsset: return String(localized: "無法讀取修補 TIFF 資產", bundle: .module)
        case .cannotEncode: return String(localized: "無法以浮點 TIFF 儲存修補資產", bundle: .module)
        }
    }

    public var errorDescription: String? { description }
}

/// Stores fixed float TIFF patches next to each RAW. References contain only a safe filename;
/// loading verifies both the resolved path and the exact file hash before decoding.
public enum RetouchAssetStore {
    public static func assetDirectory(forRaw raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension("rfassets")
    }

    /// Encodes the patch as a floating-point TIFF, writes it atomically, then returns its sidecar reference.
    public static func write(patch: CIImage, imageExtent: CGRect, forRaw raw: URL,
                             context: CIContext, modelRevision: String? = nil) throws -> RetouchPatch {
        guard usable(imageExtent), usable(patch.extent) else { throw RetouchAssetError.invalidPatch }
        let cropped = patch.extent.intersection(imageExtent).integral
        guard !cropped.isNull, !cropped.isEmpty else { throw RetouchAssetError.invalidPatch }
        let normalizedBounds = CGRect(
            x: (cropped.minX - imageExtent.minX) / imageExtent.width,
            y: (cropped.minY - imageExtent.minY) / imageExtent.height,
            width: cropped.width / imageExtent.width,
            height: cropped.height / imageExtent.height
        )
        guard valid(normalizedBounds) else { throw RetouchAssetError.invalidPatch }

        let local = patch.cropped(to: cropped)
            .transformed(by: CGAffineTransform(translationX: -cropped.minX, y: -cropped.minY))
        let colorSpace = patch.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        guard let data = context.tiffRepresentation(of: local, format: .RGBAf,
                                                    colorSpace: colorSpace, options: [:]) else {
            throw RetouchAssetError.cannotEncode
        }

        let name = "retouch-\(UUID().uuidString.lowercased()).tiff"
        let directory = assetDirectory(forRaw: raw)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: destination, options: .atomic)
        return RetouchPatch(normalizedBounds: normalizedBounds, assetName: name,
                            sha256: hash(data), modelRevision: modelRevision, sourceSize: imageExtent.size)
    }

    public static func load(_ patch: RetouchPatch, forRaw raw: URL) throws -> CIImage {
        guard valid(patch.normalizedBounds), usable(patch.sourceSize) else {
            throw RetouchAssetError.invalidPatch
        }
        let file = try resolvedURL(for: patch, raw: raw)
        guard FileManager.default.fileExists(atPath: file.path) else { throw RetouchAssetError.missingAsset }
        let data = try Data(contentsOf: file)
        guard hash(data).caseInsensitiveCompare(patch.sha256) == .orderedSame else {
            throw RetouchAssetError.hashMismatch
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: false]),
              usable(image.extent) else { throw RetouchAssetError.unreadableAsset }
        return image
    }

    /// Applies stored results at any render scale. It only resizes the committed TIFF pixels;
    /// it never re-runs cloning, healing, or AI inference.
    public static func applying(_ parameters: RetouchParameters, to image: CIImage,
                                forRaw raw: URL) throws -> CIImage {
        guard parameters.enabled, !parameters.patches.isEmpty else { return image }
        guard usable(image.extent) else { throw RetouchAssetError.invalidPatch }
        var result = image
        for patch in parameters.patches {
            let stored = try load(patch, forRaw: raw)
            let sourceExtent = stored.extent
            let bounds = patch.normalizedBounds
            let destination = CGRect(
                x: image.extent.minX + bounds.minX * image.extent.width,
                y: image.extent.minY + bounds.minY * image.extent.height,
                width: bounds.width * image.extent.width,
                height: bounds.height * image.extent.height
            )
            guard usable(destination), usable(sourceExtent) else { throw RetouchAssetError.invalidPatch }
            let local = stored.transformed(by: CGAffineTransform(translationX: -sourceExtent.minX,
                                                                 y: -sourceExtent.minY))
            let resized = local.transformed(by: CGAffineTransform(scaleX: destination.width / sourceExtent.width,
                                                                  y: destination.height / sourceExtent.height))
            let placed = resized.transformed(by: CGAffineTransform(translationX: destination.minX,
                                                                   y: destination.minY))
                .cropped(to: image.extent)
            result = placed.composited(over: result).cropped(to: image.extent)
        }
        return result
    }

    private static func resolvedURL(for patch: RetouchPatch, raw: URL) throws -> URL {
        let name = patch.assetName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              URL(fileURLWithPath: name).lastPathComponent == name,
              !name.hasPrefix("~") else { throw RetouchAssetError.unsafeAssetName }

        let directory = assetDirectory(forRaw: raw)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = directory.appendingPathComponent(name, isDirectory: false)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = resolved.deletingLastPathComponent().standardizedFileURL.path
        guard resolvedParent == root.path else { throw RetouchAssetError.assetEscapesDirectory }
        return resolved
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func usable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func usable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func valid(_ rect: CGRect) -> Bool {
        usable(rect) && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }
}
