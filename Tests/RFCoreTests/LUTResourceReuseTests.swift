import Foundation
import XCTest
import CoreImage
@testable import RFCore

private final class ConcurrentLUTApplyInput: @unchecked Sendable {
    let image: CIImage
    let lut: LUT3D
    let outputColorSpace: CGColorSpace

    init(image: CIImage, lut: LUT3D, outputColorSpace: CGColorSpace) {
        self.image = image
        self.lut = lut
        self.outputColorSpace = outputColorSpace
    }
}

private final class ConcurrentLUTApplyResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutputs: [CIImage?]
    private var storedFailures: [String] = []

    init(count: Int) {
        storedOutputs = [CIImage?](repeating: nil, count: count)
    }

    func store(_ output: CIImage, at index: Int) {
        lock.lock()
        storedOutputs[index] = output
        lock.unlock()
    }

    func storeFailure(_ error: Error) {
        lock.lock()
        storedFailures.append(String(describing: error))
        lock.unlock()
    }

    var outputs: [CIImage?] {
        lock.lock()
        defer { lock.unlock() }
        return storedOutputs
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }
}

final class LUTResourceReuseTests: XCTestCase {
    private var gpu: GPUContext!

    override func setUpWithError() throws {
        do {
            gpu = try GPUContext()
        } catch GPUError.noDevice {
            throw XCTSkip("This test requires a Metal device")
        }
    }

    func testLUTTextureCacheUsesContentIdentityAndEvictsWithinBudget() throws {
        let renderer = try LUTRenderer(
            gpu: gpu,
            lutTextureCacheEntryLimit: 2,
            lutTextureCacheByteLimit: 1_024
        )
        let source = image(width: 4, height: 4, value: 0.18)
        let first = constantLUT(0.1, 0.2, 0.3)
        let sameContent = LUT3D(size: first.size, data: first.data)
        let changedSameSize = constantLUT(0.7, 0.2, 0.3)

        _ = try renderer.apply(to: source, lut: first, outputColorSpace: gpu.workingColorSpace)
        _ = try renderer.apply(to: source, lut: sameContent, outputColorSpace: gpu.workingColorSpace)
        _ = try renderer.apply(to: source, lut: changedSameSize, outputColorSpace: gpu.workingColorSpace)

        var stats = renderer.resourceStats
        XCTAssertEqual(stats.lutTextureUploads, 2)
        XCTAssertEqual(stats.lutTextureCacheHits, 1)
        XCTAssertEqual(stats.lutTextureCacheEntries, 2)
        XCTAssertEqual(stats.lutTextureCacheBytes, 64, "counts GPU texture and retained LUT content")

        _ = try renderer.apply(to: source, lut: constantLUT(0.4, 0.5, 0.6),
                               outputColorSpace: gpu.workingColorSpace)
        _ = try renderer.apply(to: source, lut: first, outputColorSpace: gpu.workingColorSpace)

        stats = renderer.resourceStats
        XCTAssertEqual(stats.lutTextureUploads, 4, "evicted content must upload again")
        XCTAssertEqual(stats.lutTextureEvictions, 2)
        XCTAssertEqual(stats.lutTextureCacheEntries, 2)
        XCTAssertLessThanOrEqual(stats.lutTextureCacheBytes, 1_024)
    }

    func testSourceScratchIsReusedAfterSynchronousCompletion() throws {
        let renderer = try LUTRenderer(gpu: gpu)
        let source = image(width: 12, height: 10, value: 0.18)
        let lut = constantLUT(0.2, 0.3, 0.4)
        let before = renderer.resourceStats

        _ = try renderer.apply(to: source, lut: lut, outputColorSpace: gpu.workingColorSpace)
        let afterFirst = renderer.resourceStats
        _ = try renderer.apply(to: source, lut: lut, outputColorSpace: gpu.workingColorSpace)
        let afterSecond = renderer.resourceStats

        XCTAssertEqual(afterFirst.sourceScratchAllocations - before.sourceScratchAllocations, 1)
        XCTAssertEqual(afterSecond.sourceScratchHits - afterFirst.sourceScratchHits, 1)
        XCTAssertEqual(afterSecond.sourceScratchPooledCount, 1)
        XCTAssertEqual(afterSecond.sourceScratchPooledBytes, 12 * 10 * 8)
    }

    func testDelayedImageMaterializationKeepsEarlierDestinationPixels() throws {
        let renderer = try LUTRenderer(gpu: gpu)
        let source = image(width: 8, height: 8, value: 0.18)
        let first = try renderer.apply(
            to: source, lut: constantLUT(0.12, 0.23, 0.34),
            outputColorSpace: gpu.workingColorSpace
        )
        let second = try renderer.apply(
            to: source, lut: constantLUT(0.72, 0.63, 0.54),
            outputColorSpace: gpu.workingColorSpace
        )

        let firstPixel = readPixel(first, at: CGPoint(x: 4, y: 4))
        let secondPixel = readPixel(second, at: CGPoint(x: 4, y: 4))
        XCTAssertEqual(firstPixel.x, 0.12, accuracy: 0.01)
        XCTAssertEqual(firstPixel.y, 0.23, accuracy: 0.01)
        XCTAssertEqual(firstPixel.z, 0.34, accuracy: 0.01)
        XCTAssertEqual(secondPixel.x, 0.72, accuracy: 0.01)
        XCTAssertEqual(secondPixel.y, 0.63, accuracy: 0.01)
        XCTAssertEqual(secondPixel.z, 0.54, accuracy: 0.01)
    }

    func testConcurrentAppliesWithDifferentDimensionsKeepTheirOwnPixels() throws {
        let renderer = try LUTRenderer(
            gpu: gpu,
            lutTextureCacheEntryLimit: 8,
            lutTextureCacheByteLimit: 4_096
        )
        let cases: [(width: Int, height: Int, color: SIMD3<Float>)] = [
            (13, 9, SIMD3(0.11, 0.21, 0.31)),
            (29, 7, SIMD3(0.22, 0.32, 0.42)),
            (17, 23, SIMD3(0.33, 0.43, 0.53)),
            (31, 11, SIMD3(0.44, 0.54, 0.64)),
        ]
        let outputColorSpace = gpu.workingColorSpace
        let inputs = cases.map { item in
            ConcurrentLUTApplyInput(
                image: image(width: item.width, height: item.height, value: 0.18),
                lut: constantLUT(item.color.x, item.color.y, item.color.z),
                outputColorSpace: outputColorSpace
            )
        }
        let results = ConcurrentLUTApplyResults(count: cases.count)

        DispatchQueue.concurrentPerform(iterations: cases.count) { index in
            let input = inputs[index]
            do {
                let output = try renderer.apply(to: input.image, lut: input.lut,
                                                outputColorSpace: input.outputColorSpace)
                results.store(output, at: index)
            } catch {
                results.storeFailure(error)
            }
        }

        XCTAssertTrue(results.failures.isEmpty, results.failures.joined(separator: "\n"))
        for (index, item) in cases.enumerated() {
            let output = try XCTUnwrap(results.outputs[index])
            XCTAssertEqual(output.extent.width, CGFloat(item.width))
            XCTAssertEqual(output.extent.height, CGFloat(item.height))
            let pixel = readPixel(output, at: CGPoint(x: item.width / 2, y: item.height / 2))
            XCTAssertEqual(pixel.x, Double(item.color.x), accuracy: 0.01)
            XCTAssertEqual(pixel.y, Double(item.color.y), accuracy: 0.01)
            XCTAssertEqual(pixel.z, Double(item.color.z), accuracy: 0.01)
        }
    }

    func testMalformedLUTDimensionsLengthsAndTextureSizeOverflowAreRejected() throws {
        XCTAssertNil(LUT3D(size: 0, data: []).makeTexture(device: gpu.device))
        XCTAssertNil(LUT3D(size: 1, data: [0, 0, 0]).makeTexture(device: gpu.device))
        XCTAssertNil(LUT3D(size: Int.max, data: []).makeTexture(device: gpu.device))
        XCTAssertThrowsError(try gpu.makeTexture(width: Int.max, height: 2))
        XCTAssertThrowsError(try gpu.makeTexture(width: 0, height: 1))
    }

    private func image(width: Int, height: Int, value: Float) -> CIImage {
        CIImage(color: CIColor(red: Double(value), green: Double(value), blue: Double(value),
                               colorSpace: gpu.workingColorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func constantLUT(_ red: Float, _ green: Float, _ blue: Float) -> LUT3D {
        LUT3D(size: 1, data: [red, green, blue, 1])
    }

    private func readPixel(_ image: CIImage, at point: CGPoint) -> SIMD4<Double> {
        var output = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(
            image,
            toBitmap: &output,
            rowBytes: 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: gpu.workingColorSpace
        )
        return SIMD4(Double(output[0]), Double(output[1]), Double(output[2]), Double(output[3]))
    }
}
