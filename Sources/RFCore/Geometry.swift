import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// A brush mask rasterized in the optical-corrected image space.
public struct RetouchBrushMask: Sendable {
    public let bounds: CGRect
    public let bytes: Data
    /// The first stroke point after it is projected back to the source image.
    public let anchor: MaskPoint
    public let contextMargin: CGFloat

    fileprivate init(bounds: CGRect, bytes: Data, anchor: MaskPoint, contextMargin: CGFloat) {
        self.bounds = bounds
        self.bytes = bytes
        self.anchor = anchor
        self.contextMargin = contextMargin
    }
}

/// 光學頁「幾何」：水平、透視與裁切比例。放在鏡頭校正之後，預覽與輸出共用。
public struct GeometryParameters: Codable, Equatable, Sendable {
    public enum CropAspect: String, Codable, CaseIterable, Sendable {
        case original, free, square, fourFive, fiveFour, threeTwo, twoThree, sixteenNine, nineSixteen

        public var displayName: String {
            switch self {
            case .original: return String(localized: "原始", bundle: .module)
            case .free: return String(localized: "自由", bundle: .module)
            case .square: return "1:1"
            case .fourFive: return "4:5"
            case .fiveFour: return "5:4"
            case .threeTwo: return "3:2"
            case .twoThree: return "2:3"
            case .sixteenNine: return "16:9"
            case .nineSixteen: return "9:16"
            }
        }

        /// 寬／高；原始比例回傳 nil。
        public var ratio: Double? {
            switch self {
            case .original, .free: return nil
            case .square: return 1
            case .fourFive: return 4.0 / 5
            case .fiveFour: return 5.0 / 4
            case .threeTwo: return 3.0 / 2
            case .twoThree: return 2.0 / 3
            case .sixteenNine: return 16.0 / 9
            case .nineSixteen: return 9.0 / 16
            }
        }
    }

    public enum UprightMode: String, Codable, CaseIterable, Sendable {
        case off, auto, guided

        public var displayName: String {
            switch self {
            case .off: return String(localized: "關閉", bundle: .module)
            case .auto: return String(localized: "自動", bundle: .module)
            case .guided: return String(localized: "引導", bundle: .module)
            }
        }
    }

    public struct UprightCorrection: Codable, Equatable, Sendable {
        public var rotation: Double
        public var verticalPerspective: Double

        public init(rotation: Double, verticalPerspective: Double) {
            self.rotation = rotation
            self.verticalPerspective = verticalPerspective
        }

        public var isValid: Bool {
            rotation.isFinite && verticalPerspective.isFinite
                && abs(rotation) <= Self.maximumRotation
                && abs(verticalPerspective) <= Self.maximumPerspective
        }

        static let maximumRotation = 10.0
        static let maximumPerspective = 100.0
    }

    /// 鏡頭校正後來源影像上的正規化座標，以左下角為原點。
    public struct GuidePoint: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        var isNormalized: Bool {
            x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
        }

        func point(in extent: CGRect) -> CGPoint {
            CGPoint(x: extent.minX + CGFloat(x) * extent.width,
                    y: extent.minY + CGFloat(y) * extent.height)
        }
    }

    /// 以來源影像座標保存、可供編輯的垂直參考線。
    public struct GuideLine: Codable, Equatable, Sendable {
        public var start: GuidePoint
        public var end: GuidePoint

        public init(start: GuidePoint, end: GuidePoint) {
            self.start = start
            self.end = end
        }

        public var isValid: Bool {
            guard start.isNormalized, end.isNormalized else { return false }
            return hypot(start.x - end.x, start.y - end.y) >= 0.05
        }
    }

    /// 幾何變形後影像上的正規化裁切框，以左上角為原點。
    public struct CropRect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var isValid: Bool {
            [x, y, width, height].allSatisfy(\.isFinite)
                && x >= 0 && y >= 0 && width > 0 && height > 0
                && x + width <= 1.000001 && y + height <= 1.000001
        }
    }

    public static let straightenRange = -10.0...10.0
    public static let perspectiveRange = -100.0...100.0
    /// 透視 ±100 時，較窄的一邊每側內縮的比例。
    static let maxPerspectiveInset = 0.25

    /// 關閉時跳過整段幾何處理，但保留數值。
    public var enabled = true
    /// 旋轉角度（度，逆時針為正）。
    public var straighten = 0.0
    /// 正值把上方拉寬（修正仰拍時往上收窄的建築）。
    public var verticalPerspective = 0.0
    /// 正值把右側拉高。
    public var horizontalPerspective = 0.0
    /// 自動／引導模式與下方三個手動控制分開保存。
    public var uprightMode = UprightMode.off
    /// Auto 的有限範圍分析結果；nil 表示分析找不到安全的校正值。
    public var autoCorrection: UprightCorrection?
    /// 引導線固定在鏡頭校正後的來源影像上。
    public var guideLines: [GuideLine] = []
    /// 新裁切欄位採選填，舊 sidecar 仍沿用原本的 `cropAspect` 行為。
    public var cropAspectSelection: CropAspect?
    public var cropRect: CropRect?
    /// 變形後填滿所選裁切範圍，避免成品角落露出空白。
    public var constrainCrop = true
    /// 為相容舊 sidecar 保留的置中輸出裁切比例。
    public var cropAspect = CropAspect.original

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        verticalPerspective = try c.decodeIfPresent(Double.self, forKey: .verticalPerspective) ?? 0
        horizontalPerspective = try c.decodeIfPresent(Double.self, forKey: .horizontalPerspective) ?? 0
        cropAspect = try c.decodeIfPresent(CropAspect.self, forKey: .cropAspect) ?? .original
        uprightMode = try c.decodeIfPresent(UprightMode.self, forKey: .uprightMode) ?? .off
        autoCorrection = try c.decodeIfPresent(UprightCorrection.self, forKey: .autoCorrection)
        guideLines = try c.decodeIfPresent([GuideLine].self, forKey: .guideLines) ?? []
        cropAspectSelection = try c.decodeIfPresent(CropAspect.self, forKey: .cropAspectSelection)
        cropRect = try c.decodeIfPresent(CropRect.self, forKey: .cropRect)
        constrainCrop = try c.decodeIfPresent(Bool.self, forKey: .constrainCrop) ?? true
    }

    var isIdentity: Bool {
        straighten == 0 && verticalPerspective == 0 && horizontalPerspective == 0
            && cropAspect == .original && uprightMode == .off
            && autoCorrection == nil && cropAspectSelection == nil && cropRect == nil
    }

    struct Quad {
        var bottomLeft, bottomRight, topRight, topLeft: CGPoint
        var points: [CGPoint] { [bottomLeft, bottomRight, topRight, topLeft] }
    }

    /// 原畫面四角經透視與旋轉後的位置（Core Image 座標，逆時針排列）。
    func quad(for rect: CGRect) -> Quad {
        quad(for: rect, rotation: straighten, verticalPerspective: verticalPerspective,
             horizontalPerspective: horizontalPerspective)
    }

    private func quad(for rect: CGRect, rotation straighten: Double,
                      verticalPerspective: Double, horizontalPerspective: Double) -> Quad {
        let w = rect.width, h = rect.height
        let v = CGFloat(verticalPerspective / 100 * Self.maxPerspectiveInset)
        let hz = CGFloat(horizontalPerspective / 100 * Self.maxPerspectiveInset)
        // 較窄的一邊往內收，另一邊不動，四角都留在原畫面內。
        let bottomInset = max(v, 0) * w, topInset = max(-v, 0) * w
        let leftInset = max(hz, 0) * h, rightInset = max(-hz, 0) * h
        var q = Quad(bottomLeft: CGPoint(x: rect.minX + bottomInset, y: rect.minY + leftInset),
                     bottomRight: CGPoint(x: rect.maxX - bottomInset, y: rect.minY + rightInset),
                     topRight: CGPoint(x: rect.maxX - topInset, y: rect.maxY - rightInset),
                     topLeft: CGPoint(x: rect.minX + topInset, y: rect.maxY - leftInset))
        let rotation = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: straighten * .pi / 180)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        q.bottomLeft = q.bottomLeft.applying(rotation)
        q.bottomRight = q.bottomRight.applying(rotation)
        q.topRight = q.topRight.applying(rotation)
        q.topLeft = q.topLeft.applying(rotation)
        return q
    }

    /// 套用幾何並裁成不露邊、置中的最大比例矩形；輸出原點在 0。
    public func apply(to image: CIImage) -> CIImage {
        apply(to: image, includeUserCrop: true)
    }

    /// 裁切編輯預覽暫時顯示整張變形後的畫面，讓使用者能把裁切框往外移。
    public func apply(to image: CIImage, includeUserCrop: Bool) -> CIImage {
        guard Self.isUsable(image.extent) else { return image }
        if !usesNewGeometry && includeUserCrop {
            guard enabled, !isIdentity else { return image }
            return applyLegacy(to: image)
        }

        let extent = image.extent
        let correction = resolvedCorrection(in: extent)
        let rotation = enabled ? straighten + (correction?.rotation ?? 0) : 0
        let vertical = enabled ? verticalPerspective + (correction?.verticalPerspective ?? 0) : 0
        let horizontal = enabled ? horizontalPerspective : 0
        let hasUserCrop = includeUserCrop && (cropAspectSelection != nil || cropRect != nil)
        if rotation == 0 && vertical == 0 && horizontal == 0 && !hasUserCrop
            && cropAspect == .original {
            return image
        }
        let q = quad(for: extent, rotation: rotation,
                     verticalPerspective: vertical, horizontalPerspective: horizontal)
        var warped = image
        if rotation != 0 || vertical != 0 || horizontal != 0 {
            let filter = CIFilter.perspectiveTransform()
            filter.inputImage = image
            filter.bottomLeft = q.bottomLeft
            filter.bottomRight = q.bottomRight
            filter.topRight = q.topRight
            filter.topLeft = q.topLeft
            warped = filter.outputImage ?? image
        }
        let frame = newGeometryFrame(in: extent, quad: q)
        guard let crop = selectedCrop(in: frame, includeUserCrop: includeUserCrop) else { return image }
        return warped.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    private var usesNewGeometry: Bool {
        uprightMode != .off || autoCorrection != nil || cropAspectSelection != nil
            || cropRect != nil || !constrainCrop
    }

    private func applyLegacy(to image: CIImage) -> CIImage {
        let extent = image.extent
        let q = quad(for: extent)
        var warped = image
        if straighten != 0 || verticalPerspective != 0 || horizontalPerspective != 0 {
            let filter = CIFilter.perspectiveTransform()
            filter.inputImage = image
            filter.bottomLeft = q.bottomLeft
            filter.bottomRight = q.bottomRight
            filter.topRight = q.topRight
            filter.topLeft = q.topLeft
            warped = filter.outputImage ?? image
        }
        let ratio = cropAspect.ratio ?? Double(extent.width / extent.height)
        let crop = Self.largestCenteredRect(in: q, center: CGPoint(x: extent.midX, y: extent.midY),
                                            ratio: ratio, bounds: extent)
        return warped.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    private func resolvedCorrection(in extent: CGRect) -> UprightCorrection? {
        switch uprightMode {
        case .off: return nil
        case .auto: return autoCorrection?.isValid == true ? autoCorrection : nil
        case .guided: return Self.guidedCorrection(guideLines, extent: extent)
        }
    }

    private func newGeometryFrame(in extent: CGRect, quad: Quad) -> CGRect {
        guard constrainCrop else { return extent }
        return Self.largestCenteredRect(in: quad,
                                        center: CGPoint(x: extent.midX, y: extent.midY),
                                        ratio: Double(extent.width / extent.height), bounds: extent)
    }

    private func selectedCrop(in frame: CGRect, includeUserCrop: Bool) -> CGRect? {
        guard Self.isUsable(frame) else { return nil }
        guard includeUserCrop else { return frame }

        if let cropRect, cropRect.isValid {
            let width = frame.width * CGFloat(cropRect.width)
            let height = frame.height * CGFloat(cropRect.height)
            let x = frame.minX + frame.width * CGFloat(cropRect.x)
            let y = frame.maxY - frame.height * CGFloat(cropRect.y + cropRect.height)
            return CGRect(x: x, y: y, width: width, height: height)
        }

        if let cropAspectSelection {
            guard let ratio = cropAspectSelection.ratio else { return frame }
            return Self.centeredRect(in: frame, ratio: ratio)
        }

        // 使用者編輯新裁切前，舊 sidecar 仍沿用原本的置中比例裁切。
        guard cropAspect != .original else { return frame }
        return Self.centeredRect(in: frame, ratio: cropAspect.ratio ?? Double(frame.width / frame.height))
    }

    private static func centeredRect(in bounds: CGRect, ratio: Double) -> CGRect {
        guard ratio.isFinite, ratio > 0, isUsable(bounds) else { return bounds }
        var width = bounds.width
        var height = width / CGFloat(ratio)
        if height > bounds.height {
            height = bounds.height
            width = height * CGFloat(ratio)
        }
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height).integral
    }

    /// 引導解算只調整旋轉與垂直透視，並限制在現有控制範圍內。
    public static func guidedCorrection(_ lines: [GuideLine], extent: CGRect) -> UprightCorrection? {
        guard isUsable(extent) else { return nil }
        let valid = lines.filter(\.isValid)
        guard valid.count >= 2 else { return nil }
        let pair = Array(valid.prefix(2))
        let centers = pair.map { ($0.start.x + $0.end.x) / 2 }
        guard abs(centers[0] - centers[1]) >= 0.035 else { return nil }
        let sourceCorners = [
            CGPoint(x: extent.minX, y: extent.minY), CGPoint(x: extent.maxX, y: extent.minY),
            CGPoint(x: extent.maxX, y: extent.maxY), CGPoint(x: extent.minX, y: extent.maxY),
        ]
        let sourceLines = pair.map { line -> (CGPoint, CGPoint) in
            let a = line.start.point(in: extent), b = line.end.point(in: extent)
            return a.y < b.y ? (a, b) : (b, a)
        }

        var best: (score: Double, vertical: Double, angles: [Double])?
        for vertical in stride(from: -100.0, through: 100.0, by: 1.0) {
            let quad = Quad(
                bottomLeft: CGPoint(x: extent.minX + max(vertical / 100, 0) * maxPerspectiveInset * extent.width,
                                    y: extent.minY),
                bottomRight: CGPoint(x: extent.maxX - max(vertical / 100, 0) * maxPerspectiveInset * extent.width,
                                     y: extent.minY),
                topRight: CGPoint(x: extent.maxX - max(-vertical / 100, 0) * maxPerspectiveInset * extent.width,
                                  y: extent.maxY),
                topLeft: CGPoint(x: extent.minX + max(-vertical / 100, 0) * maxPerspectiveInset * extent.width,
                                 y: extent.maxY)
            )
            guard let mapping = Homography(from: sourceCorners, to: quad.points) else { continue }
            let angles = sourceLines.compactMap { line -> Double? in
                guard let bottom = mapping.applying(to: line.0),
                      let top = mapping.applying(to: line.1) else { return nil }
                return atan2(Double(top.x - bottom.x), Double(top.y - bottom.y)) * 180 / .pi
            }
            guard angles.count == 2 else { continue }
            let difference = angles[0] - angles[1]
            let score = difference * difference / 2 + 0.00005 * vertical * vertical
            if best == nil || score < best!.score { best = (score, vertical, angles) }
        }
        guard let best, abs(best.vertical) < 100 else { return nil }
        let rotation = best.angles.reduce(0, +) / Double(best.angles.count)
        guard abs(rotation) <= straightenRange.upperBound,
              abs(best.angles[0] - best.angles[1]) < 12,
              best.angles.allSatisfy({ abs($0 - rotation) < 12 }) else { return nil }
        let correction = UprightCorrection(rotation: rotation, verticalPerspective: best.vertical)
        return correction.isValid ? correction : nil
    }

    /// 將幾何後的正規化座標反算回光學校正後的影像座標。
    /// 透視與旋轉使用和 `apply(to:)` 相同的四角及中央裁切矩形。
    public func inputPoint(forOutput point: MaskPoint, extent: CGRect,
                           includeUserCrop: Bool = true) -> MaskPoint? {
        guard Self.isNormalized(point), Self.isUsable(extent),
              let mapping = coordinateMapping(in: extent, includeUserCrop: includeUserCrop),
              let inverse = mapping.homography.inverted else { return nil }
        let corrected = CGPoint(x: mapping.crop.minX + CGFloat(point.x) * mapping.crop.width,
                                y: mapping.crop.minY + CGFloat(point.y) * mapping.crop.height)
        guard let input = inverse.applying(to: corrected) else { return nil }
        let result = MaskPoint(x: Double((input.x - extent.minX) / extent.width),
                               y: Double((input.y - extent.minY) / extent.height))
        return Self.isNormalized(result) ? result : nil
    }

    /// 將光學校正後的正規化座標映到幾何後影像，供來源標記等預覽用途。
    public func outputPoint(forInput point: MaskPoint, extent: CGRect,
                            includeUserCrop: Bool = true) -> MaskPoint? {
        guard let output = outputPointIncludingOutside(forInput: point, extent: extent,
                                                       includeUserCrop: includeUserCrop),
              Self.isNormalized(output) else { return nil }
        return output
    }

    /// 也映射被裁切遮住的來源點，讓引導線端點能貼在預覽邊緣顯示。
    public func outputPointIncludingOutside(forInput point: MaskPoint, extent: CGRect,
                                            includeUserCrop: Bool = true) -> MaskPoint? {
        guard Self.isNormalized(point), Self.isUsable(extent),
              let mapping = coordinateMapping(in: extent, includeUserCrop: includeUserCrop),
              let corrected = mapping.homography.applying(to: CGPoint(
                x: extent.minX + CGFloat(point.x) * extent.width,
                y: extent.minY + CGFloat(point.y) * extent.height
              )) else { return nil }
        let result = MaskPoint(x: Double((corrected.x - mapping.crop.minX) / mapping.crop.width),
                               y: Double((corrected.y - mapping.crop.minY) / mapping.crop.height))
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    /// 把幾何後、以短邊比例表示的圓形筆刷半徑換成幾何前半徑。
    /// 透視會把圓變成橢圓；回傳局部雅可比矩陣的最大縮放值，讓來源筆刷不會比畫面上小。
    public func inputRadius(forOutput radius: Double, at point: MaskPoint,
                            extent: CGRect) -> Double? {
        guard radius.isFinite, radius > 0, Self.isNormalized(point), Self.isUsable(extent),
              let mapping = coordinateMapping(in: extent),
              let inverse = mapping.homography.inverted else { return nil }
        let corrected = CGPoint(x: mapping.crop.minX + CGFloat(point.x) * mapping.crop.width,
                                y: mapping.crop.minY + CGFloat(point.y) * mapping.crop.height)
        guard inverse.applying(to: corrected) != nil,
              let jacobian = inverse.jacobian(at: corrected) else { return nil }
        let a = jacobian.0, b = jacobian.1, c = jacobian.2, d = jacobian.3
        let trace = a * a + b * b + c * c + d * d
        let determinant = a * d - b * c
        let discriminant = max(0, trace * trace - 4 * determinant * determinant)
        let maximumScale = sqrt(max(0, (trace + sqrt(discriminant)) / 2))
        let outputPixelRadius = radius * Double(min(mapping.crop.width, mapping.crop.height))
        let result = outputPixelRadius * maximumScale / Double(min(extent.width, extent.height))
        return result.isFinite && result > 0 ? result : nil
    }

    /// Rasterizes a circular brush in rendered-image coordinates back into the source image.
    /// Under perspective, testing each source pixel in output space preserves the visible circle.
    public func inputBrushMask(forOutput points: [MaskPoint], radius: Double,
                               extent: CGRect, featherOutside: Bool,
                               feather: Double? = nil, opacity: Double = 1) throws -> RetouchBrushMask {
        guard !points.isEmpty, points.allSatisfy(Self.isNormalized), Self.isUsable(extent) else {
            throw RetouchError.invalidStroke
        }
        guard radius.isFinite, radius >= RetouchEngine.minimumBrushRadius,
              radius <= RetouchEngine.maximumBrushRadius else { throw RetouchError.invalidRadius }
        guard let mapping = coordinateMapping(in: extent),
              let inverse = mapping.homography.inverted else { throw RetouchError.invalidStroke }

        let outputRadius = radius * Double(min(mapping.crop.width, mapping.crop.height))
        guard outputRadius.isFinite, outputRadius >= 0.5 else { throw RetouchError.invalidRadius }
        guard opacity.isFinite, (0...1).contains(opacity),
              feather == nil || (feather!.isFinite && (0...1).contains(feather!)) else {
            throw RetouchError.invalidRadius
        }
        let featherWidth = max(outputRadius * (feather ?? 0.12), 0.5)
        let outerRadius = featherOutside ? outputRadius + featherWidth : outputRadius
        let centers = points.map {
            CGPoint(x: mapping.crop.minX + CGFloat($0.x) * mapping.crop.width,
                    y: mapping.crop.minY + CGFloat($0.y) * mapping.crop.height)
        }
        let segments: [(CGPoint, CGPoint)] = centers.count == 1
            ? [(centers[0], centers[0])]
            : zip(centers, centers.dropFirst()).map { ($0.0, $0.1) }
        let outputMinX = max(mapping.crop.minX, centers.map(\.x).min()! - CGFloat(outerRadius))
        let outputMaxX = min(mapping.crop.maxX, centers.map(\.x).max()! + CGFloat(outerRadius))
        let outputMinY = max(mapping.crop.minY, centers.map(\.y).min()! - CGFloat(outerRadius))
        let outputMaxY = min(mapping.crop.maxY, centers.map(\.y).max()! + CGFloat(outerRadius))
        guard outputMaxX > outputMinX, outputMaxY > outputMinY else { throw RetouchError.invalidStroke }
        let outputBounds = CGRect(x: outputMinX, y: outputMinY,
                                  width: outputMaxX - outputMinX, height: outputMaxY - outputMinY)
        let outputCorners = [
            CGPoint(x: outputBounds.minX, y: outputBounds.minY),
            CGPoint(x: outputBounds.maxX, y: outputBounds.minY),
            CGPoint(x: outputBounds.maxX, y: outputBounds.maxY),
            CGPoint(x: outputBounds.minX, y: outputBounds.maxY),
        ]
        var sourceCorners: [CGPoint] = []
        for point in outputCorners {
            guard let input = inverse.applying(to: point) else { throw RetouchError.invalidStroke }
            sourceCorners.append(input)
        }
        let sourceMinX = sourceCorners.map(\.x).min()!, sourceMaxX = sourceCorners.map(\.x).max()!
        let sourceMinY = sourceCorners.map(\.y).min()!, sourceMaxY = sourceCorners.map(\.y).max()!
        let sourceBounds = CGRect(x: sourceMinX, y: sourceMinY,
                                  width: sourceMaxX - sourceMinX, height: sourceMaxY - sourceMinY)
            .intersection(extent).integral
        guard !sourceBounds.isNull, sourceBounds.width >= 1, sourceBounds.height >= 1 else {
            throw RetouchError.invalidStroke
        }
        let width = Int(sourceBounds.width), height = Int(sourceBounds.height)
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow, count.partialValue <= 8_000_000 else { throw RetouchError.patchTooLarge }

        guard let anchorPoint = inverse.applying(to: centers[0]) else { throw RetouchError.invalidStroke }
        let anchor = MaskPoint(x: Double((anchorPoint.x - extent.minX) / extent.width),
                               y: Double((anchorPoint.y - extent.minY) / extent.height))
        guard Self.isNormalized(anchor) else { throw RetouchError.invalidStroke }
        var maximumInputRadius = outputRadius
        let jacobianSamples = centers + zip(centers, centers.dropFirst()).map { pair in
            CGPoint(x: (pair.0.x + pair.1.x) / 2, y: (pair.0.y + pair.1.y) / 2)
        }
        for point in jacobianSamples {
            guard let jacobian = inverse.jacobian(at: point) else { throw RetouchError.invalidStroke }
            let a = jacobian.0, b = jacobian.1, c = jacobian.2, d = jacobian.3
            let trace = a * a + b * b + c * c + d * d
            let determinant = a * d - b * c
            let discriminant = max(0, trace * trace - 4 * determinant * determinant)
            let scale = sqrt(max(0, (trace + sqrt(discriminant)) / 2))
            let inputRadius = outputRadius * scale
            guard inputRadius.isFinite else { throw RetouchError.invalidRadius }
            maximumInputRadius = max(maximumInputRadius, inputRadius)
        }

        let tileSide: CGFloat = 32
        let tilesWide = max(1, Int(ceil(mapping.crop.width / tileSide)))
        let tilesHigh = max(1, Int(ceil(mapping.crop.height / tileSide)))
        var bins: [Int: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            let minX = max(mapping.crop.minX, min(segment.0.x, segment.1.x) - CGFloat(outerRadius))
            let maxX = min(mapping.crop.maxX, max(segment.0.x, segment.1.x) + CGFloat(outerRadius))
            let minY = max(mapping.crop.minY, min(segment.0.y, segment.1.y) - CGFloat(outerRadius))
            let maxY = min(mapping.crop.maxY, max(segment.0.y, segment.1.y) + CGFloat(outerRadius))
            let firstX = min(tilesWide - 1, max(0, Int(floor((minX - mapping.crop.minX) / tileSide))))
            let lastX = min(tilesWide - 1, max(0, Int(floor((maxX - mapping.crop.minX) / tileSide))))
            let firstY = min(tilesHigh - 1, max(0, Int(floor((minY - mapping.crop.minY) / tileSide))))
            let lastY = min(tilesHigh - 1, max(0, Int(floor((maxY - mapping.crop.minY) / tileSide))))
            guard firstX <= lastX, firstY <= lastY else { continue }
            for ty in firstY...lastY {
                for tx in firstX...lastX { bins[ty * tilesWide + tx, default: []].append(index) }
            }
        }

        var bytes = Data(count: count.partialValue)
        bytes.withUnsafeMutableBytes { raw in
            guard let pixels = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                if y.isMultiple(of: 64), withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return }
                let sourceY = sourceBounds.maxY - CGFloat(y) - 0.5
                for x in 0..<width {
                    let sourcePoint = CGPoint(x: sourceBounds.minX + CGFloat(x) + 0.5, y: sourceY)
                    guard let output = mapping.homography.applying(to: sourcePoint),
                          mapping.crop.contains(output) else { continue }
                    let tx = min(tilesWide - 1, max(0, Int(floor((output.x - mapping.crop.minX) / tileSide))))
                    let ty = min(tilesHigh - 1, max(0, Int(floor((output.y - mapping.crop.minY) / tileSide))))
                    guard let candidates = bins[ty * tilesWide + tx] else { continue }
                    var nearest = Double.infinity
                    for index in candidates { nearest = min(nearest, Self.distance(output, to: segments[index])) }
                    let alpha: Double
                    if featherOutside {
                        if nearest <= outputRadius { alpha = 1 }
                        else { alpha = min(max((Double(outerRadius) - nearest) / featherWidth, 0), 1) }
                    } else {
                        let featherStart = outputRadius * (1 - (feather ?? 0.32))
                        alpha = nearest <= featherStart ? 1
                            : min(max((outputRadius - nearest) / max(outputRadius - featherStart, 0.5), 0), 1)
                    }
                    pixels[y * width + x] = UInt8((alpha * alpha * (3 - 2 * alpha) * opacity * 255).rounded())
                }
            }
        }
        try Task.checkCancellation()
        return RetouchBrushMask(bounds: sourceBounds, bytes: bytes, anchor: anchor,
                                contextMargin: CGFloat(max(64, 2 * maximumInputRadius)))
    }

    private static func distance(_ point: CGPoint, to segment: (CGPoint, CGPoint)) -> Double {
        let x = Double(point.x), y = Double(point.y)
        let ax = Double(segment.0.x), ay = Double(segment.0.y)
        let vx = Double(segment.1.x - segment.0.x), vy = Double(segment.1.y - segment.0.y)
        let lengthSquared = vx * vx + vy * vy
        let t = lengthSquared > 0 ? min(max(((x - ax) * vx + (y - ay) * vy) / lengthSquared, 0), 1) : 0
        let dx = x - (ax + t * vx), dy = y - (ay + t * vy)
        return sqrt(dx * dx + dy * dy)
    }

    private func coordinateMapping(in extent: CGRect, includeUserCrop: Bool = true)
        -> (homography: Homography, crop: CGRect)? {
        guard Self.isUsable(extent) else { return nil }
        let corners = [
            CGPoint(x: extent.minX, y: extent.minY),
            CGPoint(x: extent.maxX, y: extent.minY),
            CGPoint(x: extent.maxX, y: extent.maxY),
            CGPoint(x: extent.minX, y: extent.maxY),
        ]
        if !usesNewGeometry && includeUserCrop {
            guard enabled else { return (Homography.identity, extent) }
            if isIdentity { return (Homography.identity, extent) }
            let q = quad(for: extent)
            guard let homography = Homography(from: corners, to: q.points) else { return nil }
            let ratio = cropAspect.ratio ?? Double(extent.width / extent.height)
            let crop = Self.largestCenteredRect(in: q,
                                                center: CGPoint(x: extent.midX, y: extent.midY),
                                                ratio: ratio, bounds: extent)
            guard crop.width > 0, crop.height > 0 else { return nil }
            return (homography, crop)
        }

        let correction = resolvedCorrection(in: extent)
        let rotation = enabled ? straighten + (correction?.rotation ?? 0) : 0
        let vertical = enabled ? verticalPerspective + (correction?.verticalPerspective ?? 0) : 0
        let horizontal = enabled ? horizontalPerspective : 0
        let hasUserCrop = includeUserCrop && (cropAspectSelection != nil || cropRect != nil)
        if rotation == 0 && vertical == 0 && horizontal == 0 && !hasUserCrop
            && cropAspect == .original {
            return (Homography.identity, extent)
        }
        let q = quad(for: extent, rotation: rotation,
                     verticalPerspective: vertical, horizontalPerspective: horizontal)
        // CIPerspectiveTransform 把原圖四角送到 quad；正向（幾何前→後）即 corners → quad。
        guard let homography = Homography(from: corners, to: q.points) else { return nil }
        let frame = newGeometryFrame(in: extent, quad: q)
        guard let crop = selectedCrop(in: frame, includeUserCrop: includeUserCrop) else { return nil }
        guard crop.width > 0, crop.height > 0 else { return nil }
        return (homography, crop)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func isNormalized(_ point: MaskPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= 0 && point.x <= 1
            && point.y >= 0 && point.y <= 1
    }

    /// 四對角點決定的平面投影。用同一組四角解出正向矩陣，座標 API 再取反矩陣。
    private struct Homography {
        var a, b, c, d, e, f, g, h, i: Double
        static let identity = Homography(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0, g: 0, h: 0, i: 1)

        init?(from source: [CGPoint], to destination: [CGPoint]) {
            guard source.count == 4, destination.count == 4 else { return nil }
            var matrix = [[Double]]()
            matrix.reserveCapacity(8)
            for (p, q) in zip(source, destination) {
                let x = Double(p.x), y = Double(p.y), u = Double(q.x), v = Double(q.y)
                guard [x, y, u, v].allSatisfy(\.isFinite) else { return nil }
                matrix.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
                matrix.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
            }
            guard let values = Self.solve(matrix) else { return nil }
            self.init(a: values[0], b: values[1], c: values[2],
                      d: values[3], e: values[4], f: values[5],
                      g: values[6], h: values[7], i: 1)
        }

        private init(a: Double, b: Double, c: Double, d: Double, e: Double,
                     f: Double, g: Double, h: Double, i: Double) {
            self.a = a; self.b = b; self.c = c
            self.d = d; self.e = e; self.f = f
            self.g = g; self.h = h; self.i = i
        }

        var inverted: Homography? {
            let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
            guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
            return Homography(
                a: (e * i - f * h) / determinant,
                b: (c * h - b * i) / determinant,
                c: (b * f - c * e) / determinant,
                d: (f * g - d * i) / determinant,
                e: (a * i - c * g) / determinant,
                f: (c * d - a * f) / determinant,
                g: (d * h - e * g) / determinant,
                h: (b * g - a * h) / determinant,
                i: (a * e - b * d) / determinant
            )
        }

        func applying(to point: CGPoint) -> CGPoint? {
            let x = Double(point.x), y = Double(point.y)
            let denominator = g * x + h * y + i
            guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
            let u = (a * x + b * y + c) / denominator
            let v = (d * x + e * y + f) / denominator
            guard u.isFinite, v.isFinite else { return nil }
            return CGPoint(x: CGFloat(u), y: CGFloat(v))
        }

        func jacobian(at point: CGPoint) -> (Double, Double, Double, Double)? {
            let x = Double(point.x), y = Double(point.y)
            let denominator = g * x + h * y + i
            guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
            let numeratorX = a * x + b * y + c
            let numeratorY = d * x + e * y + f
            let square = denominator * denominator
            let values = ((a * denominator - g * numeratorX) / square,
                          (b * denominator - h * numeratorX) / square,
                          (d * denominator - g * numeratorY) / square,
                          (e * denominator - h * numeratorY) / square)
            return [values.0, values.1, values.2, values.3].allSatisfy(\.isFinite) ? values : nil
        }

        private static func solve(_ augmented: [[Double]]) -> [Double]? {
            guard augmented.count == 8, augmented.allSatisfy({ $0.count == 9 }) else { return nil }
            var rows = augmented
            for column in 0..<8 {
                guard let pivot = (column..<8).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
                      abs(rows[pivot][column]) > 1e-12 else { return nil }
                rows.swapAt(column, pivot)
                let divisor = rows[column][column]
                for j in column..<9 { rows[column][j] /= divisor }
                for row in 0..<8 where row != column {
                    let factor = rows[row][column]
                    if factor != 0 {
                        for j in column..<9 { rows[row][j] -= factor * rows[column][j] }
                    }
                }
            }
            let result = rows.map { $0[8] }
            return result.allSatisfy(\.isFinite) ? result : nil
        }
    }

    /// 以 `center` 為中心、寬高比 `ratio`、完全落在凸四邊形內的最大整數像素矩形；內縮 1 像素避開邊緣取樣到透明。
    static func largestCenteredRect(in q: Quad, center: CGPoint, ratio: Double, bounds: CGRect) -> CGRect {
        let points = q.points
        func inside(_ p: CGPoint) -> Bool {
            for i in 0..<4 {
                let a = points[i], b = points[(i + 1) % 4]
                if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) < -1e-6 { return false }
            }
            return true
        }
        func fits(_ halfHeight: Double) -> Bool {
            let hw = halfHeight * ratio
            return [(-hw, -halfHeight), (hw, -halfHeight), (hw, halfHeight), (-hw, halfHeight)]
                .allSatisfy { inside(CGPoint(x: center.x + $0.0, y: center.y + $0.1)) }
        }
        var low = 0.0, high = Double(bounds.height) / 2
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        let height = max(1, (2 * low - 2).rounded(.down))
        let width = max(1, (height * ratio).rounded(.down))
        return CGRect(x: (center.x - width / 2).rounded(.up), y: (center.y - height / 2).rounded(.up),
                      width: width, height: height)
    }
}
