import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// AI 只產生選區；局部調整仍使用既有遮罩渲染路徑。
public enum AIMaskSelection {
    public enum Target: String, CaseIterable, Sendable {
        case subject, person, background

        public var displayName: String {
            switch self {
            case .subject: return String(localized: "AI 主體", bundle: .module)
            case .person: return String(localized: "AI 人物", bundle: .module)
            case .background: return String(localized: "AI 背景", bundle: .module)
            }
        }
    }

    public enum Failure: LocalizedError {
        case noSelection, bitmap
        public var errorDescription: String? {
            switch self {
            case .noSelection: return String(localized: "沒有辨識到可選取的主體，請改用筆刷或另一種 AI 選取。", bundle: .module)
            case .bitmap: return String(localized: "無法建立 AI 遮罩影像。", bundle: .module)
            }
        }
    }

    public static func generate(target: Target, image: CIImage, identity: SceneImageIdentity,
                                context: CIContext,
                                provider: any SceneIntelligenceProvider = VisionSceneIntelligence()) async throws -> Data {
        let kind: SceneMaskKind = target == .person ? .person : .subject
        guard let selection = try await provider.mask(kind: kind, for: image, identity: identity) else {
            throw Failure.noSelection
        }
        try Task.checkCancellation()
        let maximum = selection.image.applyingFilter("CIAreaMaximum",
            parameters: [kCIInputExtentKey: CIVector(cgRect: selection.image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(maximum, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        guard pixel[0] > 0.01 else { throw Failure.noSelection }
        let mask = target == .background
            ? selection.image.applyingFilter("CIColorInvert") : selection.image
        return try encode(mask, context: context)
    }

    public static func encode(_ image: CIImage, context: CIContext) throws -> Data {
        guard let bitmap = context.createCGImage(image, from: image.extent, format: .L8,
                                                 colorSpace: CGColorSpaceCreateDeviceGray()) else {
            throw Failure.bitmap
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.bitmap
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.bitmap }
        return data as Data
    }
}
