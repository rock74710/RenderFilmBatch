import Foundation
import CoreImage

/// A committed retouch patch. Bounds are normalized to the optical-corrected image,
/// and the referenced TIFF stores a premultiplied RGBA patch with its feather in alpha.
public struct RetouchPatch: Codable, Equatable, Sendable {
    public var normalizedBounds: CGRect
    /// Filename relative to the RAW's `.rfassets` directory.
    public var assetName: String
    /// Lowercase SHA-256 of the exact TIFF bytes.
    public var sha256: String
    /// Model revision for AI-generated pixels; nil for clone and traditional healing.
    public var modelRevision: String?
    /// Full source dimensions at the time this patch was committed.
    public var sourceSize: CGSize
    /// 可重編輯的操作；舊 TIFF 修補沒有此紀錄，保持原樣。
    public var recipe: RetouchRecipe?
    /// 前面的筆畫或光學基底改變後，固定結果需要人工檢視。
    public var needsReview: Bool?

    public init(normalizedBounds: CGRect, assetName: String, sha256: String,
                modelRevision: String? = nil, sourceSize: CGSize, recipe: RetouchRecipe? = nil,
                needsReview: Bool? = nil) {
        self.normalizedBounds = normalizedBounds
        self.assetName = assetName
        self.sha256 = sha256
        self.modelRevision = modelRevision
        self.sourceSize = sourceSize
        self.recipe = recipe
        self.needsReview = needsReview
    }
}

/// Per-photo retouch history. Existing sidecars without this field decode to the empty default.
public struct RetouchParameters: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var patches: [RetouchPatch]

    public init(enabled: Bool = true, patches: [RetouchPatch] = []) {
        self.enabled = enabled
        self.patches = patches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        patches = try container.decodeIfPresent([RetouchPatch].self, forKey: .patches) ?? []
    }
}

public enum RetouchError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidImageExtent
    case invalidStroke
    case invalidRadius
    case sourceOutsideImage
    case noCleanSource
    case patchTooLarge
    case cannotCreateMask
    case cannotCreatePatch
    case incompatibleAIResult

    public var description: String {
        switch self {
        case .invalidImageExtent: return String(localized: "修補影像尺寸無效", bundle: .module)
        case .invalidStroke: return String(localized: "修補筆畫座標無效或沒有點", bundle: .module)
        case .invalidRadius: return String(localized: "修補筆刷半徑必須介於 0 到 20% 影像短邊", bundle: .module)
        case .sourceOutsideImage: return String(localized: "來源範圍必須完整位於影像內，且不能覆蓋本次修補區域", bundle: .module)
        case .noCleanSource: return String(localized: "找不到可用的完整來源，請手動選另一塊乾淨區域，或改用「移除」", bundle: .module)
        case .patchTooLarge: return String(localized: "修補區域過大，請縮小筆刷或分成較短筆畫", bundle: .module)
        case .cannotCreateMask: return String(localized: "無法建立修補遮罩", bundle: .module)
        case .cannotCreatePatch: return String(localized: "無法建立修補影像", bundle: .module)
        case .incompatibleAIResult: return String(localized: "AI 修補結果尺寸與輸入區域不同", bundle: .module)
        }
    }

    public var errorDescription: String? { description }
}

/// Builds a fixed, cropped patch in the optical-corrected source's coordinate system.
public enum RetouchEngine {
    public static let minimumBrushRadius = 0.0005
    public static let maximumBrushRadius = 0.2

    private struct Segment {
        var start: CGPoint
        var end: CGPoint
    }

    private struct HeapNode {
        var index: Int
        var distance: Double
    }

    private struct MinHeap {
        private var values: [HeapNode] = []
        var isEmpty: Bool { values.isEmpty }

        mutating func push(_ value: HeapNode) {
            values.append(value)
            var child = values.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard values[child].distance < values[parent].distance else { break }
                values.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> HeapNode? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let first = values[0]
            values[0] = values.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                guard left < values.count else { break }
                let child = right < values.count && values[right].distance < values[left].distance ? right : left
                guard values[child].distance < values[parent].distance else { break }
                values.swapAt(parent, child)
                parent = child
            }
            return first
        }
    }

    /// `source == nil` performs floating-point fast-marching inpainting. Otherwise the first
    /// destination point is cloned from `source`, keeping that offset for the whole stroke.
    /// An AI callback, when supplied for a heal, receives the patch crop and a hard binary mask;
    /// the returned pixels are combined with the original soft brush edge for the saved patch.
    public static func makePatch(
        image: CIImage,
        points: [MaskPoint],
        radius: Double,
        source: MaskPoint? = nil,
        context: CIContext,
        aiFill: (@Sendable (CIImage, CIImage) throws -> CIImage)? = nil
    ) throws -> CIImage {
        let imageExtent = image.extent
        guard isUsable(imageExtent), imageExtent.width.rounded(.towardZero) <= CGFloat(Int.max / 4),
              imageExtent.height.rounded(.towardZero) <= CGFloat(Int.max / 4) else {
            throw RetouchError.invalidImageExtent
        }
        guard !points.isEmpty, points.allSatisfy(isNormalized) else { throw RetouchError.invalidStroke }
        guard radius.isFinite, radius >= minimumBrushRadius,
              radius <= maximumBrushRadius else { throw RetouchError.invalidRadius }

        let pixelRadius = radius * Double(min(imageExtent.width, imageExtent.height))
        guard pixelRadius.isFinite, pixelRadius >= 0.5 else { throw RetouchError.invalidRadius }
        let centers = points.map {
            CGPoint(x: imageExtent.minX + CGFloat($0.x) * imageExtent.width,
                    y: imageExtent.minY + CGFloat($0.y) * imageExtent.height)
        }
        let segments: [Segment]
        if centers.count == 1 {
            segments = [Segment(start: centers[0], end: centers[0])]
        } else {
            segments = zip(centers, centers.dropFirst()).map { Segment(start: $0.0, end: $0.1) }
        }

        var cloneShift = CGPoint.zero
        if let source {
            guard isNormalized(source) else { throw RetouchError.sourceOutsideImage }
            let sourcePixel = CGPoint(x: imageExtent.minX + CGFloat(source.x) * imageExtent.width,
                                      y: imageExtent.minY + CGFloat(source.y) * imageExtent.height)
            guard imageExtent.contains(sourcePixel) else { throw RetouchError.sourceOutsideImage }
            cloneShift = CGPoint(x: centers[0].x - sourcePixel.x, y: centers[0].y - sourcePixel.y)
        }

        let minimumX = centers.map(\.x).min() ?? 0
        let maximumX = centers.map(\.x).max() ?? 0
        let minimumY = centers.map(\.y).min() ?? 0
        let maximumY = centers.map(\.y).max() ?? 0
        // Heal fully replaces the selected radius, then feathers through a small outer ring.
        // Clone keeps its earlier feather inside the selected radius.
        let featherWidth = max(pixelRadius * 0.12, 0.5)
        let maskRadius = source == nil ? pixelRadius + featherWidth : pixelRadius
        let boundsMinX = floor(minimumX - CGFloat(maskRadius))
        let boundsMaxX = ceil(maximumX + CGFloat(maskRadius))
        let boundsMinY = floor(minimumY - CGFloat(maskRadius))
        let boundsMaxY = ceil(maximumY + CGFloat(maskRadius))
        let rawBounds = CGRect(
            x: boundsMinX,
            y: boundsMinY,
            width: boundsMaxX - boundsMinX,
            height: boundsMaxY - boundsMinY
        )
        let patchBounds = rawBounds.intersection(imageExtent).integral
        guard !patchBounds.isNull, patchBounds.width >= 1, patchBounds.height >= 1 else {
            throw RetouchError.invalidStroke
        }
        let width = Int(patchBounds.width), height = Int(patchBounds.height)
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard !pixelCount.overflow, pixelCount.partialValue <= 8_000_000 else { throw RetouchError.patchTooLarge }
        try checkCancellation()

        let softMaskData = try makeSoftMask(width: width, height: height, bounds: patchBounds,
                                            segments: segments, radius: pixelRadius,
                                            featherOutside: source == nil,
                                            validSource: source == nil ? nil : imageExtent,
                                            sourceShift: cloneShift)
        return try renderPatch(image: image, maskData: softMaskData, width: width, height: height,
                               bounds: patchBounds, cloneShift: cloneShift, isClone: source != nil,
                               context: context, aiFill: aiFill, contextMargin: CGFloat(max(64.0, 2 * pixelRadius)))
    }

    /// Builds a patch from a mask already mapped into source-image coordinates.
    public static func makePatch(image: CIImage, brushMask: RetouchBrushMask,
                                 source: MaskPoint? = nil, context: CIContext,
                                 aiFill: (@Sendable (CIImage, CIImage) throws -> CIImage)? = nil) throws -> CIImage {
        let imageExtent = image.extent
        guard isUsable(imageExtent), imageExtent.width.rounded(.towardZero) <= CGFloat(Int.max / 4),
              imageExtent.height.rounded(.towardZero) <= CGFloat(Int.max / 4) else {
            throw RetouchError.invalidImageExtent
        }
        let bounds = brushMask.bounds.integral.intersection(imageExtent)
        guard !bounds.isNull, bounds == brushMask.bounds,
              bounds.width >= 1, bounds.height >= 1 else { throw RetouchError.invalidStroke }
        let width = Int(bounds.width), height = Int(bounds.height)
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow, count.partialValue <= 8_000_000,
              brushMask.bytes.count == count.partialValue else { throw RetouchError.patchTooLarge }

        var cloneShift = CGPoint.zero
        var maskData = brushMask.bytes
        if let source {
            guard isNormalized(source), isNormalized(brushMask.anchor) else { throw RetouchError.sourceOutsideImage }
            let sourcePoint = CGPoint(x: imageExtent.minX + CGFloat(source.x) * imageExtent.width,
                                      y: imageExtent.minY + CGFloat(source.y) * imageExtent.height)
            let targetPoint = CGPoint(x: imageExtent.minX + CGFloat(brushMask.anchor.x) * imageExtent.width,
                                      y: imageExtent.minY + CGFloat(brushMask.anchor.y) * imageExtent.height)
            guard imageExtent.contains(sourcePoint) else { throw RetouchError.sourceOutsideImage }
            cloneShift = CGPoint(x: targetPoint.x - sourcePoint.x, y: targetPoint.y - sourcePoint.y)
            maskData.withUnsafeMutableBytes { raw in
                guard let pixels = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for y in 0..<height {
                    let targetY = bounds.maxY - CGFloat(y) - 0.5
                    let sourceY = targetY - cloneShift.y
                    for x in 0..<width {
                        let index = y * width + x
                        guard pixels[index] > 0 else { continue }
                        let sourceX = bounds.minX + CGFloat(x) + 0.5 - cloneShift.x
                        if sourceX < imageExtent.minX || sourceX >= imageExtent.maxX
                            || sourceY < imageExtent.minY || sourceY >= imageExtent.maxY {
                            pixels[index] = 0
                        }
                    }
                }
            }
        }
        try checkCancellation()
        return try renderPatch(image: image, maskData: maskData, width: width, height: height,
                               bounds: bounds, cloneShift: cloneShift, isClone: source != nil,
                               context: context, aiFill: aiFill, contextMargin: brushMask.contextMargin)
    }

    private static func renderPatch(image: CIImage, maskData: Data, width: Int, height: Int,
                                    bounds: CGRect, cloneShift: CGPoint, isClone: Bool,
                                    context: CIContext,
                                    aiFill: (@Sendable (CIImage, CIImage) throws -> CIImage)?,
                                    contextMargin: CGFloat) throws -> CIImage {
        let imageExtent = image.extent
        let softMask = try maskImage(maskData, width: width, height: height, bounds: bounds)
        let clear = CIImage(color: .clear).cropped(to: bounds)
        if isClone {
            let shifted = image.transformed(by: CGAffineTransform(translationX: cloneShift.x,
                                                                  y: cloneShift.y)).cropped(to: bounds)
            return try maskedPatch(shifted, mask: softMask, clear: clear, extent: bounds)
        }

        if let aiFill {
            let contextBounds = bounds.insetBy(dx: -contextMargin, dy: -contextMargin)
                .intersection(imageExtent).integral.intersection(imageExtent)
            let contextWidth = Int(contextBounds.width), contextHeight = Int(contextBounds.height)
            let contextPixelCount = contextWidth.multipliedReportingOverflow(by: contextHeight)
            guard contextWidth > 0, contextHeight > 0, !contextPixelCount.overflow,
                  contextPixelCount.partialValue <= 8_000_000 else { throw RetouchError.patchTooLarge }
            var contextMask = Data(count: contextWidth * contextHeight)
            let offsetX = Int(bounds.minX - contextBounds.minX)
            let offsetY = Int(contextBounds.maxY - bounds.maxY)
            contextMask.withUnsafeMutableBytes { targetBytes in
                guard let target = targetBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                maskData.withUnsafeBytes { sourceBytes in
                    guard let source = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for y in 0..<height {
                        for x in 0..<width where source[y * width + x] > 0 {
                            target[(y + offsetY) * contextWidth + x + offsetX] = 255
                        }
                    }
                }
            }
            let binaryMask = try maskImage(contextMask, width: contextWidth, height: contextHeight,
                                           bounds: contextBounds)
            let filled = try aiFill(image.cropped(to: contextBounds), binaryMask)
            guard filled.extent.isFiniteRect, approximatelyEqual(filled.extent, contextBounds) else {
                throw RetouchError.incompatibleAIResult
            }
            return try maskedPatch(filled.cropped(to: bounds), mask: softMask,
                                   clear: clear, extent: bounds)
        }

        return try traditionalHeal(image: image, mask: maskData, width: width, height: height,
                                  bounds: bounds, context: context, clear: clear,
                                  colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!)
    }

    private static func makeSoftMask(width: Int, height: Int, bounds: CGRect,
                                     segments: [Segment], radius: Double, featherOutside: Bool,
                                     validSource: CGRect?, sourceShift: CGPoint) throws -> Data {
        let radiusCGFloat = CGFloat(radius)
        let featherWidth = max(radiusCGFloat * 0.12, 0.5)
        let outerRadius = featherOutside ? radiusCGFloat + featherWidth : radiusCGFloat
        let tileSide = 32
        let tilesWide = (width + tileSide - 1) / tileSide
        let tilesHigh = (height + tileSide - 1) / tileSide
        var bins = [[Int]](repeating: [], count: tilesWide * tilesHigh)
        for (index, segment) in segments.enumerated() {
            try checkCancellation()
            let minX = max(bounds.minX, min(segment.start.x, segment.end.x) - outerRadius)
            let maxX = min(bounds.maxX, max(segment.start.x, segment.end.x) + outerRadius)
            let minY = max(bounds.minY, min(segment.start.y, segment.end.y) - outerRadius)
            let maxY = min(bounds.maxY, max(segment.start.y, segment.end.y) + outerRadius)
            let firstX = min(tilesWide - 1, max(0, Int(floor((minX - bounds.minX) / CGFloat(tileSide)))))
            let lastX = min(tilesWide - 1, max(0, Int(floor((maxX - bounds.minX) / CGFloat(tileSide)))))
            let firstY = min(tilesHigh - 1, max(0, Int(floor((bounds.maxY - maxY) / CGFloat(tileSide)))))
            let lastY = min(tilesHigh - 1, max(0, Int(floor((bounds.maxY - minY) / CGFloat(tileSide)))))
            guard firstX <= lastX, firstY <= lastY else { continue }
            for ty in firstY...lastY {
                for tx in firstX...lastX { bins[ty * tilesWide + tx].append(index) }
            }
        }

        var bytes = Data(count: width * height)
        let featherStart = radius * 0.68
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let buffer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for ty in 0..<tilesHigh {
                for tx in 0..<tilesWide {
                    let candidateSegments = bins[ty * tilesWide + tx]
                    guard !candidateSegments.isEmpty else { continue }
                    if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return }
                    let xStart = tx * tileSide, xEnd = min(width, xStart + tileSide)
                    let yStart = ty * tileSide, yEnd = min(height, yStart + tileSide)
                    for y in yStart..<yEnd {
                        // 位圖第 0 列是上緣（maxY），與 CIImage(bitmapData:) 及 render(toBitmap:) 相同。
                        let absoluteY = bounds.maxY - CGFloat(y) - 0.5
                        for x in xStart..<xEnd {
                            let absoluteX = bounds.minX + CGFloat(x) + 0.5
                            let p = CGPoint(x: absoluteX, y: absoluteY)
                            if let validSource,
                               !(validSource.minX <= absoluteX - sourceShift.x
                                 && absoluteX - sourceShift.x < validSource.maxX
                                 && validSource.minY <= absoluteY - sourceShift.y
                                 && absoluteY - sourceShift.y < validSource.maxY) { continue }
                            var nearest = Double.infinity
                            for segmentIndex in candidateSegments {
                                nearest = min(nearest, distance(p, to: segments[segmentIndex]))
                            }
                            let t: Double
                            if featherOutside {
                                guard nearest < Double(outerRadius) else { continue }
                                t = nearest <= radius ? 1
                                    : min(max((Double(outerRadius) - nearest) / Double(featherWidth), 0), 1)
                            } else {
                                guard nearest < radius else { continue }
                                t = nearest <= featherStart ? 1
                                    : min(max((radius - nearest) / (radius - featherStart), 0), 1)
                            }
                            let alpha = t * t * (3 - 2 * t)
                            buffer[y * width + x] = UInt8((alpha * 255).rounded())
                        }
                    }
                }
            }
        }
        try checkCancellation()
        return bytes
    }

    private static func distance(_ point: CGPoint, to segment: Segment) -> Double {
        let x = Double(point.x), y = Double(point.y)
        let ax = Double(segment.start.x), ay = Double(segment.start.y)
        let vx = Double(segment.end.x - segment.start.x), vy = Double(segment.end.y - segment.start.y)
        let lengthSquared = vx * vx + vy * vy
        let t = lengthSquared > 0 ? min(max(((x - ax) * vx + (y - ay) * vy) / lengthSquared, 0), 1) : 0
        let dx = x - (ax + t * vx), dy = y - (ay + t * vy)
        return sqrt(dx * dx + dy * dy)
    }

    private static func maskImage(_ bytes: Data, width: Int, height: Int, bounds: CGRect) throws -> CIImage {
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray) else { throw RetouchError.cannotCreateMask }
        let local = CIImage(bitmapData: bytes, bytesPerRow: width,
                            size: CGSize(width: width, height: height), format: .R8,
                            colorSpace: gray)
        return local.transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    private static func maskedPatch(_ image: CIImage, mask: CIImage, clear: CIImage,
                                    extent: CGRect) throws -> CIImage {
        let result = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
        guard !result.extent.isEmpty else { throw RetouchError.cannotCreatePatch }
        return result
    }

    /// 修復筆刷：以內容感知填補（RetouchPatchMatch）在附近範圍逐塊找相似紋理填進洞內。
    /// 全程使用場景線性浮點值，保留大於 1 的高光。找不到可用來源（影像太小）時，退回邊界色彩擴散。
    private static func traditionalHeal(image: CIImage, mask: Data, width: Int, height: Int,
                                        bounds: CGRect, context: CIContext, clear: CIImage,
                                        colorSpace: CGColorSpace) throws -> CIImage {
        let size = max(width, height)
        let margin = CGFloat(max(6, size / 4))
        let ring = bounds.insetBy(dx: -margin, dy: -margin).intersection(image.extent).integral
        let reach = CGFloat(size * 2) + margin
        let search = ring.insetBy(dx: -reach, dy: -reach).intersection(image.extent).integral
        let sw = Int(search.width), sh = Int(search.height)
        let searchCount = sw.multipliedReportingOverflow(by: sh)
        guard !searchCount.overflow, searchCount.partialValue <= 24_000_000 else { throw RetouchError.patchTooLarge }

        // 位圖第 0 列是上緣；patch、ring 都換算成 search 位圖座標。
        var source = [Float](repeating: 0, count: sw * sh * 4)
        source.withUnsafeMutableBytes { buffer in
            context.render(image.cropped(to: search), toBitmap: buffer.baseAddress!,
                           rowBytes: sw * 16, bounds: search, format: .RGBAf, colorSpace: colorSpace)
        }
        try checkCancellation()
        let px = Int(bounds.minX - search.minX), py = Int(search.maxY - bounds.maxY)
        let rx0 = Int(ring.minX - search.minX), ry0 = Int(search.maxY - ring.maxY)
        let rw = Int(ring.width), rh = Int(ring.height)

        var hole = [Bool](repeating: false, count: rw * rh)
        var holeInSearch = [Bool](repeating: false, count: sw * sh)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] > 3 {
                let ringIndex = (y + py - ry0) * rw + x + px - rx0
                let searchIndex = (y + py) * sw + x + px
                hole[ringIndex] = true
                holeInSearch[searchIndex] = true
            }
        }

        // ring 內：洞外保留原值；洞內由內容感知填補逐塊取紋理，沒有可用來源時退回邊界色彩擴散。
        let inpainted = try RetouchPatchMatch.inpaint(pixels: source, hole: holeInSearch, width: sw, height: sh)
        var filled = [Float](repeating: 0, count: rw * rh * 4)
        for index in 0..<(rw * rh) {
            let from = ((ry0 + index / rw) * sw + rx0 + index % rw) * 4
            for channel in 0..<3 { filled[index * 4 + channel] = (inpainted ?? source)[from + channel] }
            filled[index * 4 + 3] = 1
        }
        if inpainted == nil {
            try marchFill(pixels: &filled, unknown: hole, width: rw, height: rh)
        }

        var premultiplied = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = Float(mask[y * width + x]) / 255
                guard alpha > 0 else { continue }
                let from = ((y + py - ry0) * rw + x + px - rx0) * 4, to = (y * width + x) * 4
                for channel in 0..<3 { premultiplied[to + channel] = filled[from + channel] * alpha }
                premultiplied[to + 3] = alpha
            }
        }
        let rowBytes = width * MemoryLayout<Float>.size * 4
        let bytes = premultiplied.withUnsafeBytes { Data($0) }
        let patch = CIImage(bitmapData: bytes, bytesPerRow: rowBytes,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: colorSpace)
        return patch.transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: bounds)
    }

    /// 由已知像素往未知區域依距離順序填色（快速行進法）；pixels 為 RGBA 浮點，alpha 須為 1。
    private static func marchFill(pixels: inout [Float], unknown: [Bool], width: Int, height: Int) throws {
        var distanceMap = [Double](repeating: 0, count: width * height)
        var isFilled = [Bool](repeating: true, count: width * height)
        for index in 0..<(width * height) where unknown[index] {
            distanceMap[index] = .infinity
            isFilled[index] = false
        }

        var heap = MinHeap()
        for y in 0..<height {
            if y.isMultiple(of: 64) { try checkCancellation() }
            for x in 0..<width {
                let index = y * width + x
                guard !isFilled[index] else { continue }
                let candidate = fastMarchingDistance(x: x, y: y, width: width, height: height,
                                                     distances: distanceMap, filled: isFilled)
                if candidate.isFinite {
                    distanceMap[index] = candidate
                    heap.push(HeapNode(index: index, distance: candidate))
                }
            }
        }

        var visited = 0
        while let node = heap.pop() {
            if node.distance > distanceMap[node.index] + 1e-9 { continue }
            guard !isFilled[node.index] else { continue }
            if visited.isMultiple(of: 1024) { try checkCancellation() }
            let x = node.index % width, y = node.index / width
            fillFromKnownNeighbors(x: x, y: y, width: width, height: height,
                                   distances: distanceMap, filled: isFilled, pixels: &pixels)
            isFilled[node.index] = true
            visited += 1

            let x0 = max(0, x - 1), x1 = min(width - 1, x + 1)
            let y0 = max(0, y - 1), y1 = min(height - 1, y + 1)
            for ny in y0...y1 {
                for nx in x0...x1 where nx != x || ny != y {
                    let neighbor = ny * width + nx
                    guard !isFilled[neighbor] else { continue }
                    let candidate = fastMarchingDistance(x: nx, y: ny, width: width, height: height,
                                                         distances: distanceMap, filled: isFilled)
                    if candidate < distanceMap[neighbor] {
                        distanceMap[neighbor] = candidate
                        heap.push(HeapNode(index: neighbor, distance: candidate))
                    }
                }
            }
        }
        guard visited > 0 || !isFilled.contains(false) else { throw RetouchError.cannotCreatePatch }
    }

    /// A small native approximation inspired by Alexandru Telea's fast-marching method, with
    /// weighted boundary colors and native Float channels. It is not an exact OpenCV Telea port.
    /// Reference: “An Image Inpainting Technique Based on the Fast Marching Method,”
    /// Journal of Graphics Tools 9(1), 2004.
    private static func fastMarchingDistance(x: Int, y: Int, width: Int, height: Int,
                                             distances: [Double], filled: [Bool]) -> Double {
        var horizontal = Double.infinity, vertical = Double.infinity
        if x > 0, filled[y * width + x - 1] { horizontal = min(horizontal, distances[y * width + x - 1]) }
        if x + 1 < width, filled[y * width + x + 1] { horizontal = min(horizontal, distances[y * width + x + 1]) }
        if y > 0, filled[(y - 1) * width + x] { vertical = min(vertical, distances[(y - 1) * width + x]) }
        if y + 1 < height, filled[(y + 1) * width + x] { vertical = min(vertical, distances[(y + 1) * width + x]) }
        if horizontal.isInfinite && vertical.isInfinite { return .infinity }
        if horizontal.isInfinite { return vertical + 1 }
        if vertical.isInfinite { return horizontal + 1 }
        let difference = abs(horizontal - vertical)
        if difference >= 1 { return min(horizontal, vertical) + 1 }
        return (horizontal + vertical + sqrt(max(0, 2 - difference * difference))) / 2
    }

    private static func fillFromKnownNeighbors(x: Int, y: Int, width: Int, height: Int,
                                               distances: [Double], filled: [Bool], pixels: inout [Float]) {
        let center = y * width + x
        let left = x > 0 ? distances[center - 1] : .infinity
        let right = x + 1 < width ? distances[center + 1] : .infinity
        let down = y > 0 ? distances[center - width] : .infinity
        let up = y + 1 < height ? distances[center + width] : .infinity
        let gradX = left.isFinite && right.isFinite ? (right - left) * 0.5 : 0
        let gradY = down.isFinite && up.isFinite ? (up - down) * 0.5 : 0

        var totals = SIMD3<Double>.zero
        var weightSum = 0.0
        let radius = 4
        for ny in max(0, y - radius)...min(height - 1, y + radius) {
            for nx in max(0, x - radius)...min(width - 1, x + radius) {
                let neighbor = ny * width + nx
                guard filled[neighbor] else { continue }
                let dx = Double(nx - x), dy = Double(ny - y)
                let squared = dx * dx + dy * dy
                guard squared > 0 else { continue }
                let directional = abs(dx * gradX + dy * gradY)
                let weight = (0.001 + directional) / (squared * sqrt(squared))
                let offset = neighbor * 4
                let alpha = max(Double(pixels[offset + 3]), 1e-8)
                totals += SIMD3(Double(pixels[offset]) / alpha,
                                Double(pixels[offset + 1]) / alpha,
                                Double(pixels[offset + 2]) / alpha) * weight
                weightSum += weight
            }
        }
        guard weightSum > 0 else { return }
        let result = totals / weightSum
        let offset = center * 4
        pixels[offset] = Float(result.x)
        pixels[offset + 1] = Float(result.y)
        pixels[offset + 2] = Float(result.z)
        pixels[offset + 3] = 1
    }

    private static func isUsable(_ extent: CGRect) -> Bool {
        extent.isFiniteRect && !extent.isEmpty && extent.width >= 1 && extent.height >= 1
    }

    private static func isNormalized(_ point: MaskPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.01
        return abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }

    private static func checkCancellation() throws {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { throw CancellationError() }
    }
}

private extension CGRect {
    var isFiniteRect: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}
