import Foundation
import CoreImage

/// 用既有筆刷遮罩建立單一來源複製或修復結果。
/// 影像座標以左下為原點；點陣資料列由上往下排列。
public enum RetouchSourceHeal {
    private static let maximumPatchPixels = 1_000_000
    private static let maximumSearchPixels = 4_000_000
    private static let candidateRingWidth = 8
    private static let candidateSupportPadding = candidateRingWidth + 2
    private static let healRingWidth = 1
    private static let maximumRingSamples = 512

    private struct PixelWindow {
        let bounds: CGRect
        let width: Int
        let height: Int
        let pixels: [Float]

        func pixel(x: Int, y: Int) -> SIMD4<Float>? {
            guard x >= Int(bounds.minX), x < Int(bounds.maxX),
                  y >= Int(bounds.minY), y < Int(bounds.maxY) else { return nil }
            let column = x - Int(bounds.minX)
            let row = Int(bounds.maxY) - 1 - y
            let index = (row * width + column) * 4
            return SIMD4(pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
        }

        func localPixel(column: Int, row: Int) -> SIMD4<Float>? {
            guard column >= 0, column < width, row >= 0, row < height else { return nil }
            let index = (row * width + column) * 4
            return SIMD4(pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
        }
    }

    private struct RGB {
        var r: Float
        var g: Float
        var b: Float
    }

    private struct RingSample {
        let x: Int
        let y: Int
    }

    private struct MatchSample {
        let x: Int
        let y: Int
        let target: RGB
        let gradientX: Float?
        let gradientY: Float?
        let textureX: Float?
        let textureY: Float?
    }

    private struct PreparedRing {
        let samples: [MatchSample]
        let scale: Double
    }

    private struct Candidate {
        let shiftX: Int
        let shiftY: Int
        let score: Double
    }

    /// 只用遮罩外的乾淨環帶，以色彩、梯度與細節紋理排列附近來源。
    /// 遮罩 alpha 非零的像素不會參與比對。
    public static func candidates(image: CIImage, mask: RetouchBrushMask,
                                  context: CIContext, limit: Int = 5) throws -> [MaskPoint] {
        guard limit > 0 else { return [] }
        try checkCancellation()
        let extent = image.extent
        let dimensions = try validatedMask(mask, in: extent)
        let ring = try makeOuterRingSamples(mask: mask, dimensions: dimensions,
                                            extent: extent, ringWidth: candidateRingWidth)
        guard ring.count >= 8 else { throw RetouchError.noCleanSource }

        let anchor = pointInImage(mask.anchor, extent: extent)
        let maskSize = max(dimensions.width, dimensions.height)
        var radius = min(512, max(96, maskSize + candidateRingWidth + 24))
        var searchBounds = searchRect(mask.bounds, radius: radius + candidateSupportPadding)
        while pixelCount(searchBounds) > maximumSearchPixels && radius > 32 {
            radius = max(32, radius - 16)
            searchBounds = searchRect(mask.bounds, radius: radius + candidateSupportPadding)
        }
        guard pixelCount(searchBounds) <= maximumSearchPixels else { throw RetouchError.patchTooLarge }
        let window = try render(image, bounds: searchBounds, context: context,
                                pixelLimit: maximumSearchPixels)
        try checkCancellation()
        let preparedRing = try prepareRing(ring: ring, maskBounds: mask.bounds.integral,
                                           window: window, extent: extent)

        let coarseStep = max(3, Int(ceil(Double(radius) / 48)))
        var coarse: [Candidate] = []
        for dy in stride(from: -radius, through: radius, by: coarseStep) {
            if abs(dy).isMultiple(of: max(1, coarseStep * 8)) { try checkCancellation() }
            for dx in stride(from: -radius, through: radius, by: coarseStep) {
                guard validSupport(mask: mask, extent: extent,
                                   shiftX: dx, shiftY: dy, padding: candidateSupportPadding) else { continue }
                guard let score = matchScore(ring: preparedRing, window: window,
                                             shiftX: dx, shiftY: dy) else { continue }
                coarse.append(Candidate(shiftX: dx, shiftY: dy, score: score))
            }
        }
        guard !coarse.isEmpty else { throw RetouchError.noCleanSource }
        coarse.sort { $0.score < $1.score }

        let refineCount = min(coarse.count, max(limit * 4, 12))
        var refined: [Candidate] = []
        var visited = Set<Int64>()
        for item in coarse.prefix(refineCount) {
            for dy in max(-radius, item.shiftY - coarseStep)...min(radius, item.shiftY + coarseStep) {
                for dx in max(-radius, item.shiftX - coarseStep)...min(radius, item.shiftX + coarseStep) {
                    let key = (Int64(dx) << 32) ^ Int64(UInt32(bitPattern: Int32(dy)))
                    guard visited.insert(key).inserted,
                          validSupport(mask: mask, extent: extent,
                                       shiftX: dx, shiftY: dy, padding: candidateSupportPadding),
                          let score = matchScore(ring: preparedRing, window: window,
                                                 shiftX: dx, shiftY: dy) else { continue }
                    refined.append(Candidate(shiftX: dx, shiftY: dy, score: score))
                }
            }
            try checkCancellation()
        }
        refined.sort { $0.score < $1.score }

        let minimumSeparation = max(12, min(96, maskSize / 2))
        var results: [MaskPoint] = []
        var selected: [Candidate] = []
        for item in refined {
            guard selected.allSatisfy({
                let dx = item.shiftX - $0.shiftX, dy = item.shiftY - $0.shiftY
                return dx * dx + dy * dy >= minimumSeparation * minimumSeparation
            }) else { continue }
            let source = MaskPoint(x: Double(anchor.x - CGFloat(item.shiftX) - extent.minX) / Double(extent.width),
                                   y: Double(anchor.y - CGFloat(item.shiftY) - extent.minY) / Double(extent.height))
            guard isNormalized(source) else { continue }
            selected.append(item)
            results.append(source)
            if results.count == limit { break }
        }
        guard !results.isEmpty else { throw RetouchError.noCleanSource }
        return results
    }

    /// 建立單一來源複製或修復。修復只用遮罩外的乾淨像素計算平滑色差，
    /// 保留來源紋理，也不把待移除物件的顏色當成引導。
    public static func makePatch(image: CIImage, mask: RetouchBrushMask, source: MaskPoint,
                                 heal: Bool, context: CIContext) throws -> CIImage {
        try checkCancellation()
        let extent = image.extent
        let dimensions = try validatedMask(mask, in: extent)
        guard isNormalized(source) else { throw RetouchError.sourceOutsideImage }
        let targetAnchor = pointInImage(mask.anchor, extent: extent)
        let requestedSource = pointInImage(source, extent: extent)
        let shiftX = Int((targetAnchor.x - requestedSource.x).rounded())
        let shiftY = Int((targetAnchor.y - requestedSource.y).rounded())
        let padding = heal ? healRingWidth : 0
        guard validSupport(mask: mask, extent: extent, shiftX: shiftX, shiftY: shiftY,
                           padding: padding) else { throw RetouchError.sourceOutsideImage }

        let bounds = mask.bounds.integral
        let width = dimensions.width, height = dimensions.height
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow, count.partialValue <= maximumPatchPixels else {
            throw RetouchError.patchTooLarge
        }
        let sourceBounds = bounds.offsetBy(dx: -CGFloat(shiftX), dy: -CGFloat(shiftY))
        let sourceWindow = try render(image, bounds: sourceBounds, context: context,
                                      pixelLimit: maximumPatchPixels)
        try checkCancellation()

        var correction = [Float](repeating: 0, count: count.partialValue * 3)
        if heal {
            let targetHaloBounds = expanded(bounds, by: healRingWidth).intersection(extent).integral
            let sourceHaloBounds = targetHaloBounds.offsetBy(dx: -CGFloat(shiftX), dy: -CGFloat(shiftY))
            guard sourceHaloBounds.intersection(extent) == sourceHaloBounds else {
                throw RetouchError.sourceOutsideImage
            }
            let targetHalo = try render(image, bounds: targetHaloBounds, context: context,
                                        pixelLimit: maximumPatchPixels)
            let sourceHalo = try render(image, bounds: sourceHaloBounds, context: context,
                                        pixelLimit: maximumPatchPixels)
            try solveHarmonicCorrection(mask: mask, dimensions: dimensions, extent: extent,
                                        target: targetHalo, source: sourceHalo,
                                        shiftX: shiftX, shiftY: shiftY, result: &correction)
        }

        var output = [Float](repeating: 0, count: count.partialValue * 4)
        for index in 0..<count.partialValue {
            if index.isMultiple(of: 32_768) { try checkCancellation() }
            let alpha = Float(mask.bytes[index]) / 255
            guard alpha > 0 else { continue }
            let sourcePixel = sourceWindow.localPixel(column: index % width, row: index / width)
                ?? SIMD4<Float>(repeating: .nan)
            guard sourcePixel.allFinite, sourcePixel.w > 0 else { throw RetouchError.sourceOutsideImage }
            let base = index * 4
            let sourceAlpha = sourcePixel.w
            if heal {
                let color = RGB(r: sourcePixel.x / sourceAlpha + correction[index * 3],
                                g: sourcePixel.y / sourceAlpha + correction[index * 3 + 1],
                                b: sourcePixel.z / sourceAlpha + correction[index * 3 + 2])
                let outputAlpha = sourceAlpha * alpha
                let channels = [color.r * outputAlpha, color.g * outputAlpha, color.b * outputAlpha]
                guard channels.allSatisfy(\.isFinite), outputAlpha.isFinite else {
                    throw RetouchError.cannotCreatePatch
                }
                output[base] = channels[0]
                output[base + 1] = channels[1]
                output[base + 2] = channels[2]
                output[base + 3] = outputAlpha
            } else {
                output[base] = sourcePixel.x * alpha
                output[base + 1] = sourcePixel.y * alpha
                output[base + 2] = sourcePixel.z * alpha
                output[base + 3] = sourceAlpha * alpha
            }
        }
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else {
            throw RetouchError.cannotCreatePatch
        }
        let data = output.withUnsafeBytes { Data($0) }
        let local = CIImage(bitmapData: data, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: colorSpace)
        let patch = local.transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: bounds)
        guard !patch.extent.isEmpty else { throw RetouchError.cannotCreatePatch }
        return patch
    }

    private static func validatedMask(_ mask: RetouchBrushMask, in extent: CGRect)
        throws -> (width: Int, height: Int) {
        guard extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1 else { throw RetouchError.invalidImageExtent }
        let bounds = mask.bounds.integral
        guard bounds == mask.bounds, !bounds.isNull, bounds.width >= 1, bounds.height >= 1,
              bounds.width <= CGFloat(Int.max / 4), bounds.height <= CGFloat(Int.max / 4) else {
            throw RetouchError.invalidStroke
        }
        let width = Int(bounds.width), height = Int(bounds.height)
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow, count.partialValue <= maximumPatchPixels,
              mask.bytes.count == count.partialValue else { throw RetouchError.patchTooLarge }
        guard isNormalized(mask.anchor), mask.bytes.contains(where: { $0 > 0 }) else {
            throw RetouchError.invalidStroke
        }
        return (width, height)
    }

    private static func validSupport(mask: RetouchBrushMask, extent: CGRect,
                                     shiftX: Int, shiftY: Int, padding: Int) -> Bool {
        let support = expanded(mask.bounds.integral, by: padding)
            .offsetBy(dx: -CGFloat(shiftX), dy: -CGFloat(shiftY))
        guard support.intersection(extent) == support,
              !support.intersects(mask.bounds.integral) else { return false }
        return true
    }

    private static func makeOuterRingSamples(mask: RetouchBrushMask,
                                             dimensions: (width: Int, height: Int),
                                             extent: CGRect, ringWidth: Int) throws -> [RingSample] {
        let bounds = mask.bounds.integral
        let minX = Int(bounds.minX), maxY = Int(bounds.maxY)
        var samples: [RingSample] = []
        for row in -ringWidth..<(dimensions.height + ringWidth) {
            for column in -ringWidth..<(dimensions.width + ringWidth) {
                let exterior = column < 0 || column >= dimensions.width || row < 0 || row >= dimensions.height
                guard exterior else { continue }
                let x = minX + column
                let y = maxY - 1 - row
                guard pixelCenter(x: x, y: y, isInside: extent) else { continue }
                samples.append(RingSample(x: x, y: y))
            }
        }
        guard samples.count > 0 else { return [] }
        if samples.count <= maximumRingSamples { return samples }
        let stride = Int(ceil(Double(samples.count) / Double(maximumRingSamples)))
        return samples.enumerated().compactMap { $0.offset.isMultiple(of: stride) ? $0.element : nil }
    }

    private static func prepareRing(ring: [RingSample], maskBounds: CGRect,
                                    window: PixelWindow, extent: CGRect) throws -> PreparedRing {
        var samples: [MatchSample] = []
        samples.reserveCapacity(ring.count)
        var means = [Double](repeating: 0, count: 3)
        for point in ring {
            guard let pixel = window.pixel(x: point.x, y: point.y),
                  let color = unpremultiplied(pixel) else { throw RetouchError.noCleanSource }
            let gradientX = targetGradient(at: point, dx: 1, dy: 0, center: color,
                                           bounds: maskBounds, window: window, extent: extent)
            let gradientY = targetGradient(at: point, dx: 0, dy: 1, center: color,
                                           bounds: maskBounds, window: window, extent: extent)
            let textureX = targetTexture(at: point, dx: 1, dy: 0, center: color,
                                         bounds: maskBounds, window: window, extent: extent)
            let textureY = targetTexture(at: point, dx: 0, dy: 1, center: color,
                                         bounds: maskBounds, window: window, extent: extent)
            samples.append(MatchSample(x: point.x, y: point.y, target: color,
                                       gradientX: gradientX, gradientY: gradientY,
                                       textureX: textureX, textureY: textureY))
            means[0] += Double(color.r)
            means[1] += Double(color.g)
            means[2] += Double(color.b)
        }
        guard !samples.isEmpty else { throw RetouchError.noCleanSource }
        for channel in 0..<3 { means[channel] /= Double(samples.count) }
        var variances = [Double](repeating: 0, count: 3)
        for sample in samples {
            variances[0] += pow(Double(sample.target.r) - means[0], 2)
            variances[1] += pow(Double(sample.target.g) - means[1], 2)
            variances[2] += pow(Double(sample.target.b) - means[2], 2)
        }
        let scale = max(0.035, sqrt(variances.reduce(0, +) / Double(samples.count * 3)))
        return PreparedRing(samples: samples, scale: scale)
    }

    private static func targetGradient(at point: RingSample, dx: Int, dy: Int, center: RGB,
                                       bounds: CGRect, window: PixelWindow,
                                       extent: CGRect) -> Float? {
        let x = point.x + dx, y = point.y + dy
        guard isOutside(bounds, x: x, y: y), pixelCenter(x: x, y: y, isInside: extent),
              let pixel = window.pixel(x: x, y: y), let next = unpremultiplied(pixel) else { return nil }
        return luminance(next) - luminance(center)
    }

    private static func targetTexture(at point: RingSample, dx: Int, dy: Int, center: RGB,
                                      bounds: CGRect, window: PixelWindow,
                                      extent: CGRect) -> Float? {
        let nextX = point.x + dx, nextY = point.y + dy
        let farX = nextX + dx, farY = nextY + dy
        guard isOutside(bounds, x: nextX, y: nextY), isOutside(bounds, x: farX, y: farY),
              pixelCenter(x: nextX, y: nextY, isInside: extent),
              pixelCenter(x: farX, y: farY, isInside: extent),
              let nextPixel = window.pixel(x: nextX, y: nextY),
              let farPixel = window.pixel(x: farX, y: farY),
              let next = unpremultiplied(nextPixel), let far = unpremultiplied(farPixel) else { return nil }
        return luminance(far) - 2 * luminance(next) + luminance(center)
    }

    private static func matchScore(ring: PreparedRing, window: PixelWindow,
                                   shiftX: Int, shiftY: Int) -> Double? {
        var colorLoss = 0.0, gradientLoss = 0.0, textureLoss = 0.0
        var colorCount = 0, gradientCount = 0, textureCount = 0
        for sample in ring.samples {
            guard let pixel = window.pixel(x: sample.x - shiftX, y: sample.y - shiftY),
                  let candidate = unpremultiplied(pixel) else { return nil }
            let target = sample.target
            colorLoss += squaredDifference(candidate.r, target.r)
                + squaredDifference(candidate.g, target.g) + squaredDifference(candidate.b, target.b)
            colorCount += 3

            for (dx, dy, targetGradient, targetTexture) in [
                (1, 0, sample.gradientX, sample.textureX),
                (0, 1, sample.gradientY, sample.textureY),
            ] {
                guard let targetGradient,
                      let nextPixel = window.pixel(x: sample.x + dx - shiftX,
                                                   y: sample.y + dy - shiftY),
                      let next = unpremultiplied(nextPixel) else { continue }
                let sourceGradient = luminance(next) - luminance(candidate)
                gradientLoss += squaredDifference(sourceGradient, targetGradient)
                gradientCount += 1
                guard let targetTexture,
                      let farPixel = window.pixel(x: sample.x + 2 * dx - shiftX,
                                                  y: sample.y + 2 * dy - shiftY),
                      let far = unpremultiplied(farPixel) else { continue }
                let sourceTexture = luminance(far) - 2 * luminance(next) + luminance(candidate)
                textureLoss += squaredDifference(sourceTexture, targetTexture)
                textureCount += 1
            }
        }
        guard colorCount > 0 else { return nil }
        let scaleSquared = ring.scale * ring.scale
        let color = colorLoss / Double(colorCount) / scaleSquared
        let gradient = gradientCount > 0 ? gradientLoss / Double(gradientCount) / scaleSquared : color
        let texture = textureCount > 0 ? textureLoss / Double(textureCount) / scaleSquared : gradient
        let distancePenalty = 0.003 * hypot(Double(shiftX), Double(shiftY))
        let result = 0.55 * color + 0.35 * gradient + 0.10 * texture + distancePenalty
        return result.isFinite ? result : nil
    }

    private static func solveHarmonicCorrection(mask: RetouchBrushMask,
                                                 dimensions: (width: Int, height: Int),
                                                 extent: CGRect, target: PixelWindow,
                                                 source: PixelWindow, shiftX: Int, shiftY: Int,
                                                 result: inout [Float]) throws {
        let width = dimensions.width, height = dimensions.height, count = width * height
        var fixed = [Bool](repeating: false, count: count)
        var active = [Bool](repeating: false, count: count)
        var boundarySums = RGB(r: 0, g: 0, b: 0)
        var boundaryCount = 0
        let originX = Int(mask.bounds.minX), topY = Int(mask.bounds.maxY)
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        for row in 0..<height {
            if row.isMultiple(of: 32) { try checkCancellation() }
            for column in 0..<width {
                let index = row * width + column
                guard mask.bytes[index] > 0 else { continue }
                active[index] = true
                var local = RGB(r: 0, g: 0, b: 0)
                var localCount = 0
                let x = originX + column, y = topY - 1 - row
                for (dx, dy) in directions {
                    let nx = column + dx, ny = row + dy
                    guard nx < 0 || nx >= width || ny < 0 || ny >= height
                            || mask.bytes[ny * width + nx] == 0 else { continue }
                    // 位圖列往下代表影像 y 減少。
                    let targetX = x + dx, targetY = y - dy
                    guard pixelCenter(x: targetX, y: targetY, isInside: extent),
                          let targetPixel = target.pixel(x: targetX, y: targetY),
                          let sourcePixel = source.pixel(x: targetX - shiftX, y: targetY - shiftY),
                          let targetColor = unpremultiplied(targetPixel),
                          let sourceColor = unpremultiplied(sourcePixel) else { continue }
                    local.r += targetColor.r - sourceColor.r
                    local.g += targetColor.g - sourceColor.g
                    local.b += targetColor.b - sourceColor.b
                    localCount += 1
                }
                if localCount > 0 {
                    let base = index * 3
                    result[base] = local.r / Float(localCount)
                    result[base + 1] = local.g / Float(localCount)
                    result[base + 2] = local.b / Float(localCount)
                    fixed[index] = true
                    boundarySums.r += result[base]
                    boundarySums.g += result[base + 1]
                    boundarySums.b += result[base + 2]
                    boundaryCount += 1
                }
            }
        }
        guard boundaryCount > 0 else { throw RetouchError.sourceOutsideImage }
        let mean = RGB(r: boundarySums.r / Float(boundaryCount),
                       g: boundarySums.g / Float(boundaryCount),
                       b: boundarySums.b / Float(boundaryCount))
        guard [mean.r, mean.g, mean.b].allSatisfy(\.isFinite) else { throw RetouchError.cannotCreatePatch }

        var even = [Int](), odd = [Int]()
        even.reserveCapacity(count / 2)
        odd.reserveCapacity(count / 2)
        for index in 0..<count where active[index] && !fixed[index] {
            let x = index % width, y = index / width
            if (x + y).isMultiple(of: 2) { even.append(index) } else { odd.append(index) }
            result[index * 3] = mean.r
            result[index * 3 + 1] = mean.g
            result[index * 3 + 2] = mean.b
        }

        let maxDimension = max(width, height)
        let maximumIterations = min(240, max(48, maxDimension / 2))
        let omega: Float = 1.78
        let tolerance = 0.0001 * max(1, max(abs(mean.r), max(abs(mean.g), abs(mean.b))))
        for iteration in 0..<maximumIterations {
            if iteration.isMultiple(of: 4) { try checkCancellation() }
            var largestChange: Float = 0
            for indices in [even, odd] {
                for index in indices {
                    let column = index % width, row = index / width
                    var sums = SIMD3<Float>(repeating: 0)
                    for (dx, dy) in directions {
                        let nx = column + dx, ny = row + dy
                        if nx >= 0, nx < width, ny >= 0, ny < height,
                           active[ny * width + nx] {
                            let neighbor = (ny * width + nx) * 3
                            sums += SIMD3(result[neighbor], result[neighbor + 1], result[neighbor + 2])
                        } else {
                            sums += SIMD3(mean.r, mean.g, mean.b)
                        }
                    }
                    let base = index * 3
                    let old = SIMD3(result[base], result[base + 1], result[base + 2])
                    let next = old + (sums * 0.25 - old) * omega
                    guard next.x.isFinite, next.y.isFinite, next.z.isFinite else {
                        throw RetouchError.cannotCreatePatch
                    }
                    largestChange = max(largestChange, max(abs(next.x - old.x),
                                                           max(abs(next.y - old.y), abs(next.z - old.z))))
                    result[base] = next.x
                    result[base + 1] = next.y
                    result[base + 2] = next.z
                }
            }
            if iteration >= 24 && largestChange < tolerance { break }
        }
        try checkCancellation()
    }

    private static func render(_ image: CIImage, bounds: CGRect,
                               context: CIContext, pixelLimit: Int) throws -> PixelWindow {
        let rect = bounds.integral
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              rect.width <= CGFloat(Int.max / 4), rect.height <= CGFloat(Int.max / 4) else {
            throw RetouchError.sourceOutsideImage
        }
        let width = Int(rect.width), height = Int(rect.height)
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow, count.partialValue <= pixelLimit else { throw RetouchError.patchTooLarge }
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else {
            throw RetouchError.cannotCreatePatch
        }
        var pixels = [Float](repeating: 0, count: count.partialValue * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(image.cropped(to: rect), toBitmap: address,
                           rowBytes: width * 16, bounds: rect, format: .RGBAf,
                           colorSpace: colorSpace)
        }
        try checkCancellation()
        guard pixels.allSatisfy(\.isFinite) else { throw RetouchError.cannotCreatePatch }
        return PixelWindow(bounds: rect, width: width, height: height, pixels: pixels)
    }

    private static func searchRect(_ bounds: CGRect, radius: Int) -> CGRect {
        expanded(bounds.integral, by: radius)
    }

    private static func pixelCount(_ rect: CGRect) -> Int {
        guard rect.width >= 1, rect.height >= 1,
              rect.width < CGFloat(Int.max / 4), rect.height < CGFloat(Int.max / 4) else { return Int.max }
        let product = Int(rect.width) .multipliedReportingOverflow(by: Int(rect.height))
        return product.overflow ? Int.max : product.partialValue
    }

    private static func expanded(_ rect: CGRect, by amount: Int) -> CGRect {
        rect.insetBy(dx: -CGFloat(amount), dy: -CGFloat(amount)).integral
    }

    private static func pointInImage(_ point: MaskPoint, extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + CGFloat(point.x) * extent.width,
                y: extent.minY + CGFloat(point.y) * extent.height)
    }

    private static func pixelCenter(x: Int, y: Int, isInside extent: CGRect) -> Bool {
        extent.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
    }

    private static func isOutside(_ rect: CGRect, x: Int, y: Int) -> Bool {
        !rect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
    }

    private static func unpremultiplied(_ pixel: SIMD4<Float>) -> RGB? {
        guard pixel.allFinite, pixel.w > 0.00001 else { return nil }
        let value = RGB(r: pixel.x / pixel.w, g: pixel.y / pixel.w, b: pixel.z / pixel.w)
        return [value.r, value.g, value.b].allSatisfy(\.isFinite) ? value : nil
    }

    private static func luminance(_ value: RGB) -> Float {
        value.r * 0.2126 + value.g * 0.7152 + value.b * 0.0722
    }

    private static func squaredDifference(_ lhs: Float, _ rhs: Float) -> Double {
        let difference = Double(lhs - rhs)
        return difference * difference
    }

    private static func squaredDifference(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = lhs - rhs
        return difference * difference
    }

    private static func isNormalized(_ point: MaskPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func checkCancellation() throws {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { throw CancellationError() }
    }
}

private extension SIMD4 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
