import Foundation
import CoreImage
import Vision

/// 以 Vision 產生 subject / person 遮罩（§14 Smart Mask 的第一個來源）。
///
/// 只做分析，不碰色彩：回傳的遮罩不進入任何 transform。
public struct VisionSceneIntelligence: SceneIntelligenceProvider {
    public let version: String

    public init(version: String = RFVersion.sceneIntelligence) {
        self.version = version
    }

    public func mask(
        kind: SceneMaskKind,
        for image: CIImage,
        identity: SceneImageIdentity
    ) async throws -> SceneMask? {
        switch kind {
        case .subject:
            return try subjectMask(for: image)
        case .person:
            return try personMask(for: image)
        default:
            // 尚未實作的 kind 一律缺席，讓呼叫端降級而不是整張 map 失敗（INV-3）。
            return nil
        }
    }

    private func subjectMask(for image: CIImage) throws -> SceneMask? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            return nil
        }
        let buffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        return SceneMask(
            kind: .subject,
            image: Self.refine(CIImage(cvPixelBuffer: buffer), guide: image),
            source: "rf.vision.subject",
            version: version
        )
    }

    private func personMask(for image: CIImage) throws -> SceneMask? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return SceneMask(
            kind: .person,
            image: Self.refine(CIImage(cvPixelBuffer: observation.pixelBuffer), guide: image),
            source: "rf.vision.person",
            version: version
        )
    }

    /// 把 Vision 的低解析遮罩放大到 `guide` 的座標系；以原圖亮度引導，邊緣貼齊實際輪廓而不是糊成一片。
    static func refine(_ mask: CIImage, guide: CIImage) -> CIImage {
        let extent = guide.extent
        guard mask.extent.width > 0, mask.extent.height > 0, !extent.isInfinite else { return mask }
        // 濾鏡以導引圖的像素格為準；遮罩先縮到 1/4 導引圖以內，放大時才會依邊緣重建細節。
        let target = CGSize(width: max(1, (extent.width / 4).rounded()), height: max(1, (extent.height / 4).rounded()))
        let small = mask
            .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / mask.extent.width,
                                               y: target.height / mask.extent.height))
        let origin = guide.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return origin.applyingFilter("CIEdgePreserveUpsampleFilter",
            parameters: ["inputSmallImage": small, "inputSpatialSigma": 3, "inputLumaSigma": 0.15])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
