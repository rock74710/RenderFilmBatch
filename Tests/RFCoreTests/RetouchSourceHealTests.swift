import XCTest
import CoreImage
@testable import RFCore

final class RetouchSourceHealTests: XCTestCase {
    private let extent = CGRect(x: 13, y: 17, width: 320, height: 240)
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue),
    ])

    func testCloneKeepsFloatSourcePixelsAndLeavesTransparentPatchOutsideMask() throws {
        let base = makeImage(extent: extent) { x, y in
            let value = Float((x * 31 + y * 17) % 37) / 9 - 1.3
            return SIMD4(value, value + 2.2, value * 0.5, 1)
        }
        let target = MaskPoint(x: 0.72, y: 0.72)
        let mask = try makeMask(points: [target], radius: 0.09, extent: extent)
        let source = MaskPoint(x: 0.25, y: 0.72)
        let shift = snappedShift(mask: mask, source: source, extent: extent)
        let patch = try RetouchSourceHeal.makePatch(image: base, mask: mask, source: source,
                                                    heal: false, context: context)
        let center = Int(extent.minX + target.x * Double(extent.width))
        let centerY = Int(extent.minY + target.y * Double(extent.height))
        let copied = sample(patch, x: center, y: centerY)
        let originalSource = sample(base, x: center - shift.0, y: centerY - shift.1)
        XCTAssertEqual(copied.x, originalSource.x, accuracy: 0.0001)
        XCTAssertEqual(copied.y, originalSource.y, accuracy: 0.0001)
        let patchBounds = mask.bounds.integral
        let sourceBounds = patchBounds.offsetBy(dx: -CGFloat(shift.0), dy: -CGFloat(shift.1))
        let patchPixels = renderPixels(patch, bounds: patchBounds)
        let sourcePixels = renderPixels(base, bounds: sourceBounds)
        var copiedNegativeValue = false, copiedHDRValue = false
        for row in 0..<Int(mask.bounds.height) {
            for column in 0..<Int(mask.bounds.width) {
                let index = row * Int(mask.bounds.width) + column
                guard mask.bytes[index] == 255 else { continue }
                let actual = pixel(patchPixels, index: index)
                let expected = pixel(sourcePixels, index: index)
                XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
                XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001)
                copiedNegativeValue = copiedNegativeValue || actual.x < 0
                copiedHDRValue = copiedHDRValue || actual.y > 1
            }
        }
        XCTAssertTrue(copiedNegativeValue, "複製應保留負的浮點值")
        XCTAssertTrue(copiedHDRValue, "複製應保留大於 1 的浮點值")

        let outside = sample(patch, x: Int(extent.minX) + 4, y: Int(extent.minY) + 4)
        XCTAssertEqual(outside.w, 0, accuracy: 0.0001)
        let composed = patch.composited(over: base).cropped(to: extent)
        XCTAssertEqual(sample(composed, x: Int(extent.minX) + 4, y: Int(extent.minY) + 4),
                       sample(base, x: Int(extent.minX) + 4, y: Int(extent.minY) + 4))
        XCTAssertGreaterThan(copied.w, 0.9, "筆刷中心必須留在正確位置")
        XCTAssertLessThan(sample(patch, x: center,
                                 y: Int(extent.minY + 0.28 * Double(extent.height))).w,
                          0.001, "非零影像原點與由上往下的點陣列不能把遮罩翻轉")
    }

    func testHealKeepsNegativeAndHDRChannelsOnConstantToneAndLeavesOutsidePixelsExact() throws {
        let hdrExtent = CGRect(x: 13, y: 17, width: 96, height: 80)
        let base = makeImage(extent: hdrExtent) { _, _ in SIMD4(4, 16, -0.5, 1) }
        let target = MaskPoint(x: 0.72, y: 0.52)
        let source = MaskPoint(x: 0.25, y: 0.52)
        let mask = try makeMask(points: [target], radius: 0.12, extent: hdrExtent)
        let dirty = replacingMaskedPixels(in: base, mask: mask, color: SIMD4(0.02, 0.01, 0.01, 1))
        let patch = try RetouchSourceHeal.makePatch(image: dirty, mask: mask, source: source,
                                                    heal: true, context: context)
        let centerX = Int(hdrExtent.minX + target.x * Double(hdrExtent.width))
        let centerY = Int(hdrExtent.minY + target.y * Double(hdrExtent.height))
        let center = sample(patch, x: centerX, y: centerY)
        XCTAssertGreaterThan(center.w, 0.99)
        XCTAssertTrue([center.x, center.y, center.z, center.w].allSatisfy(\.isFinite))
        XCTAssertEqual(center.x / center.w, 4, accuracy: 0.001)
        XCTAssertEqual(center.y / center.w, 16, accuracy: 0.001)
        XCTAssertEqual(center.z / center.w, -0.5, accuracy: 0.001)

        let composed = patch.composited(over: dirty).cropped(to: hdrExtent)
        XCTAssertEqual(sample(composed, x: Int(hdrExtent.minX) + 3, y: Int(hdrExtent.minY) + 3),
                       sample(dirty, x: Int(hdrExtent.minX) + 3, y: Int(hdrExtent.minY) + 3))
    }

    func testHealKeepsNonPeriodicSparkleContrastAndBeatsConstantBoundaryMeanOnToneRamp() throws {
        let base = makeImage(extent: extent) { x, y in
            let localX = Float(x - Int(extent.minX))
            let localY = Float(y - Int(extent.minY))
            let hash = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663))
                &* 2_654_435_761
            let sparkle: Float = hash % 41 == 0 ? 0.24 : (hash % 13 == 0 ? 0.04 : 0)
            return SIMD4(0.08 + 0.000006 * localX * localX,
                         0.12 + 0.000001 * localY * localY + sparkle * 0.7,
                         0.2 + 0.0003 * localX + sparkle, 1)
        }
        let target = MaskPoint(x: 0.70, y: 0.50)
        let source = MaskPoint(x: 0.25, y: 0.50)
        let mask = try makeMask(points: [target], radius: 0.10, extent: extent)
        let dirty = replacingMaskedPixels(in: base, mask: mask, color: SIMD4(3.2, -0.2, 0.05, 1))
        let shift = snappedShift(mask: mask, source: source, extent: extent)

        let searchStart = ProcessInfo.processInfo.systemUptime
        let automatic = try RetouchSourceHeal.candidates(image: dirty, mask: mask,
                                                         context: context, limit: 3)
        let searchSeconds = ProcessInfo.processInfo.systemUptime - searchStart
        XCTAssertFalse(automatic.isEmpty)
        let start = ProcessInfo.processInfo.systemUptime
        let healed = try RetouchSourceHeal.makePatch(image: dirty, mask: mask, source: source,
                                                     heal: true, context: context)
        let solverSeconds = ProcessInfo.processInfo.systemUptime - start
        let cloned = try RetouchSourceHeal.makePatch(image: dirty, mask: mask, source: source,
                                                     heal: false, context: context)
        let legacy = ProcessInfo.processInfo.environment["RF_RETOUCH_VISUAL_DIR"] == nil
            ? nil : try RetouchEngine.makePatch(image: dirty, points: [target], radius: 0.10,
                                                context: context)

        let bounds = mask.bounds.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        var healErrors: [Double] = [], meanErrors: [Double] = []
        let meanDelta = try constantBoundaryMean(image: base, mask: mask, shift: shift)
        var sourceHighPass: [Double] = [], healedHighPass: [Double] = []
        let healedPixels = renderPixels(healed, bounds: bounds)
        let clonedPixels = renderPixels(cloned, bounds: bounds)
        let sourcePixels = renderPixels(base, bounds: bounds.offsetBy(dx: -CGFloat(shift.0),
                                                                       dy: -CGFloat(shift.1)))
        for row in 1..<(height - 1) {
            for column in 1..<(width - 1) {
                let index = row * width + column
                guard mask.bytes[index] >= 250 else { continue }
                let x = Int(bounds.minX) + column
                let actual = pixel(healedPixels, index: index)
                guard actual.w > 0.95 else { continue }
                let rawSource = pixel(sourcePixels, index: index)
                let sourceLocalX = Float(x - shift.0 - Int(extent.minX))
                let targetLocalX = Float(x - Int(extent.minX))
                let sourceTone = 0.08 + 0.000006 * sourceLocalX * sourceLocalX
                let targetTone = 0.08 + 0.000006 * targetLocalX * targetLocalX
                let expected = rawSource.x + targetTone - sourceTone
                let correctedMean = rawSource.x + meanDelta.x
                healErrors.append(pow(Double(actual.x / actual.w - expected), 2))
                meanErrors.append(pow(Double(correctedMean - expected), 2))

                let left = pixel(clonedPixels, index: index - 1).y
                let right = pixel(clonedPixels, index: index + 1).y
                let up = pixel(clonedPixels, index: index - width).y
                let down = pixel(clonedPixels, index: index + width).y
                let sourceCenter = pixel(clonedPixels, index: index).y
                let sourceResidual = Double(sourceCenter - (left + right + down + up) / 4)
                let healLeft = pixel(healedPixels, index: index - 1).y
                let healRight = pixel(healedPixels, index: index + 1).y
                let healUp = pixel(healedPixels, index: index - width).y
                let healDown = pixel(healedPixels, index: index + width).y
                let healCenter = actual.y
                let healResidual = Double(healCenter - (healLeft + healRight + healUp + healDown) / 4)
                sourceHighPass.append(sourceResidual * sourceResidual)
                healedHighPass.append(healResidual * healResidual)
            }
        }
        let healRMSE = sqrt(healErrors.reduce(0, +) / Double(healErrors.count))
        let meanRMSE = sqrt(meanErrors.reduce(0, +) / Double(meanErrors.count))
        let textureRatio = sqrt(healedHighPass.reduce(0, +) / Double(healedHighPass.count))
            / sqrt(sourceHighPass.reduce(0, +) / Double(sourceHighPass.count))
        print(String(format: "RetouchSourceHeal search %.3fs; Heal %.3fs; tone seam RMSE %.5f vs constant boundary mean %.5f; sparkle high-pass ratio %.3f",
                     searchSeconds, solverSeconds, healRMSE, meanRMSE, textureRatio))
        XCTAssertLessThan(healRMSE, 0.02,
                          "harmonic correction should follow the smooth target tone ramp")
        XCTAssertLessThan(healRMSE, meanRMSE * 0.5,
                          "空間變化的邊界色差應比單一平均偏移更貼近目標色調")
        XCTAssertGreaterThan(textureRatio, 0.72, "修復要保留來源斑點紋理的對比")
        XCTAssertLessThan(textureRatio, 1.30, "色差求解不能額外製造高頻紋理")
        try writeVisualsIfRequested([
            "truth": base,
            "blemish": dirty,
            "clone": cloned.composited(over: dirty).cropped(to: extent),
            "heal": healed.composited(over: dirty).cropped(to: extent),
        ])
        if let legacy {
            try writeVisualsIfRequested(["legacy": legacy.composited(over: dirty).cropped(to: extent)])
        }
    }

    func testMaskedObjectPixelsCannotChangeAutoSourcesOrHealResultForSlopedMask() throws {
        let base = makeImage(extent: extent) { x, y in
            let hash = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663))
                &* 2_654_435_761
            let sparkle: Float = hash % 29 == 0 ? 0.3 : 0
            return SIMD4(0.14 + 0.0008 * Float(x - Int(extent.minX)) + sparkle,
                         0.22 + 0.0004 * Float(y - Int(extent.minY)) + sparkle * 0.5,
                         0.3 + sparkle * 0.2, 1)
        }
        let points = [MaskPoint(x: 0.43, y: 0.34), MaskPoint(x: 0.56, y: 0.62)]
        let mask = try makeMask(points: points, radius: 0.035, extent: extent)
        let dirty = replacingMaskedPixels(in: base, mask: mask, color: SIMD4(5, -1, 0.02, 1))
        let alternate = replacingMaskedPixels(in: base, mask: mask, color: SIMD4(-3, 4, 2, 1))

        let automaticA = try RetouchSourceHeal.candidates(image: dirty, mask: mask,
                                                          context: context, limit: 3)
        let automaticB = try RetouchSourceHeal.candidates(image: alternate, mask: mask,
                                                          context: context, limit: 3)
        XCTAssertEqual(automaticA, automaticB, "遮罩內的物件顏色不得影響自動來源排序")
        let manualSource = MaskPoint(x: 0.18, y: 0.23)
        let healedA = try RetouchSourceHeal.makePatch(image: dirty, mask: mask, source: manualSource,
                                                      heal: true, context: context)
        let healedB = try RetouchSourceHeal.makePatch(image: alternate, mask: mask, source: manualSource,
                                                      heal: true, context: context)
        let bounds = mask.bounds.integral
        let healedPixels = renderPixels(healedA, bounds: bounds)
        let alternatePixels = renderPixels(healedB, bounds: bounds)
        let width = Int(bounds.width)
        for row in 0..<Int(mask.bounds.height) {
            for column in 0..<Int(mask.bounds.width) where mask.bytes[row * Int(mask.bounds.width) + column] > 0 {
                let index = row * width + column
                let a = pixel(healedPixels, index: index), b = pixel(alternatePixels, index: index)
                XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
                XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
                XCTAssertEqual(a.z, b.z, accuracy: 0.0001)
                XCTAssertEqual(a.w, b.w, accuracy: 0.0001)
            }
        }
    }

    func testManualSourceSupportOutsideImageOrOverlappingMaskIsRejected() throws {
        let base = makeImage(extent: extent) { _, _ in SIMD4(0.3, 0.2, 0.1, 1) }
        let target = MaskPoint(x: 0.50, y: 0.50)
        let mask = try makeMask(points: [target], radius: 0.08, extent: extent)
        XCTAssertThrowsError(try RetouchSourceHeal.makePatch(
            image: base, mask: mask, source: MaskPoint(x: 0.01, y: 0.50),
            heal: false, context: context)) { error in
                guard case RetouchError.sourceOutsideImage = error else {
                    return XCTFail("預期來源區域無效，收到 \(error)")
                }
            }
        XCTAssertThrowsError(try RetouchSourceHeal.makePatch(
            image: base, mask: mask, source: target, heal: false, context: context)) { error in
                guard case RetouchError.sourceOutsideImage = error else {
                    return XCTFail("預期來源區域重疊，收到 \(error)")
                }
            }

        let tinyExtent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let tinyImage = makeImage(extent: tinyExtent) { _, _ in SIMD4(0.3, 0.2, 0.1, 1) }
        let hugeMask = try makeMask(points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.2,
                                    extent: tinyExtent)
        XCTAssertThrowsError(try RetouchSourceHeal.candidates(image: tinyImage, mask: hugeMask,
                                                               context: context)) { error in
            guard case RetouchError.noCleanSource = error else {
                return XCTFail("預期沒有可用來源，收到 \(error)")
            }
        }
    }

    func testPreCancelledCandidateSearchThrowsCancellationError() async throws {
        let base = makeImage(extent: extent) { _, _ in SIMD4(0.2, 0.3, 0.4, 1) }
        let mask = try makeMask(points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.05, extent: extent)
        let gate = TestGate()
        let taskContext = context
        let task = Task.detached { [base, mask, taskContext] in
            await gate.wait()
            return try RetouchSourceHeal.candidates(image: base, mask: mask, context: taskContext)
        }
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("已取消的來源搜尋應中止")
        } catch is CancellationError {
        }
    }

    private func makeMask(points: [MaskPoint], radius: Double, extent: CGRect) throws -> RetouchBrushMask {
        try GeometryParameters().inputBrushMask(forOutput: points, radius: radius,
                                                extent: extent, featherOutside: true)
    }

    private func makeImage(extent: CGRect,
                           pixel: (Int, Int) -> SIMD4<Float>) -> CIImage {
        let width = Int(extent.width), height = Int(extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = Int(extent.maxY) - 1 - row
            for column in 0..<width {
                let x = Int(extent.minX) + column
                let value = pixel(x, y)
                let index = (row * width + column) * 4
                values[index] = value.x
                values[index + 1] = value.y
                values[index + 2] = value.z
                values[index + 3] = value.w
            }
        }
        let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: colorSpace)
        return image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func replacingMaskedPixels(in image: CIImage, mask: RetouchBrushMask,
                                       color: SIMD4<Float>) -> CIImage {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: colorSpace)
        let sourceWidth = Int(mask.bounds.width), sourceHeight = Int(mask.bounds.height)
        for row in 0..<sourceHeight {
            for column in 0..<sourceWidth where mask.bytes[row * sourceWidth + column] > 0 {
                let x = Int(mask.bounds.minX) + column
                let y = Int(mask.bounds.maxY) - 1 - row
                let targetRow = Int(bounds.maxY) - 1 - y
                let index = (targetRow * width + x - Int(bounds.minX)) * 4
                values[index] = color.x
                values[index + 1] = color.y
                values[index + 2] = color.z
                values[index + 3] = color.w
            }
        }
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: colorSpace)
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: bounds)
    }

    private func sample(_ image: CIImage, x: Int, y: Int) -> SIMD4<Float> {
        var value = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &value, rowBytes: 16,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: colorSpace)
        return SIMD4(value[0], value[1], value[2], value[3])
    }

    private func renderPixels(_ image: CIImage, bounds: CGRect) -> [Float] {
        let rect = bounds.integral
        let width = Int(rect.width), height = Int(rect.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: rect,
                       format: .RGBAf, colorSpace: colorSpace)
        return values
    }

    private func pixel(_ values: [Float], index: Int) -> SIMD4<Float> {
        let offset = index * 4
        return SIMD4(values[offset], values[offset + 1], values[offset + 2], values[offset + 3])
    }

    private func snappedShift(mask: RetouchBrushMask, source: MaskPoint,
                              extent: CGRect) -> (Int, Int) {
        let targetX = extent.minX + CGFloat(mask.anchor.x) * extent.width
        let targetY = extent.minY + CGFloat(mask.anchor.y) * extent.height
        let sourceX = extent.minX + CGFloat(source.x) * extent.width
        let sourceY = extent.minY + CGFloat(source.y) * extent.height
        return (Int((targetX - sourceX).rounded()), Int((targetY - sourceY).rounded()))
    }

    private func constantBoundaryMean(image: CIImage, mask: RetouchBrushMask,
                                      shift: (Int, Int)) throws -> SIMD3<Float> {
        let bounds = mask.bounds.integral
        var total = SIMD3<Float>(repeating: 0)
        var count: Float = 0
        for y in (Int(bounds.minY) - 1)...Int(bounds.maxY) {
            for x in (Int(bounds.minX) - 1)...Int(bounds.maxX) {
                let outside = x < Int(bounds.minX) || x >= Int(bounds.maxX)
                    || y < Int(bounds.minY) || y >= Int(bounds.maxY)
                guard outside else { continue }
                let target = sample(image, x: x, y: y)
                let source = sample(image, x: x - shift.0, y: y - shift.1)
                guard target.w > 0, source.w > 0 else { continue }
                total += SIMD3(target.x / target.w - source.x / source.w,
                               target.y / target.w - source.y / source.w,
                               target.z / target.w - source.z / source.w)
                count += 1
            }
        }
        guard count > 0 else { throw RetouchError.sourceOutsideImage }
        return total / count
    }

    private func writeVisualsIfRequested(_ images: [String: CIImage]) throws {
        guard let path = ProcessInfo.processInfo.environment["RF_RETOUCH_VISUAL_DIR"], !path.isEmpty else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for (name, image) in images {
            try context.writePNGRepresentation(of: image.cropped(to: extent),
                to: directory.appendingPathComponent("\(name).png"), format: .RGBA8,
                colorSpace: displaySpace, options: [:])
        }
    }
}

private actor TestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
