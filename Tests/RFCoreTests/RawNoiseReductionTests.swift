import XCTest
import CoreImage
@testable import RFCore

final class RawNoiseReductionTests: XCTestCase {
    func testPrefersNeuralDecoderWhenCameraSupportsIt() {
        XCTAssertEqual(RawDecoder.noiseReductionDecoderVersion(available: ["7", "8", "9"]), "9")
        XCTAssertEqual(RawDecoder.noiseReductionDecoderVersion(available: ["8DNG", "9DNG"]), "9DNG")
        XCTAssertNil(RawDecoder.noiseReductionDecoderVersion(available: ["6", "7"]))
    }

    /// AC-3 on a real high-ISO RAW (set RF_NOISY_RAW); fine-detail noise must drop by at least 40%.
    func testStrengthReducesNoiseOnRealRaw() throws {
        guard let path = ProcessInfo.processInfo.environment["RF_NOISY_RAW"] else { throw XCTSkip("RF_NOISY_RAW not set") }
        let url = URL(fileURLWithPath: path)
        let none = try RawDecoder().decode(url: url, luminanceNoiseReduction: 0)
        let full = try RawDecoder().decode(url: url, luminanceNoiseReduction: 1)
        XCTAssertEqual(none.metadata.decoderVersion, full.metadata.decoderVersion)
        XCTAssertLessThan(Self.detailNoise(full.image), 0.6 * Self.detailNoise(none.image))
    }

    /// RAW 9 output must keep camera colour under the app's linear Rec.2020 working space
    /// (it rendered red below zero there, turning Sony photos cyan).
    func testNeuralDecoderKeepsColourInAppContext() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../sampleraw/TSC02817.ARW").standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("sampleraw ARW missing") }
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let plain = try RawDecoder().decode(url: url)
        let neural = try RawDecoder().decode(url: url, luminanceNoiseReduction: 0.5)
        guard neural.metadata.decoderVersion == "9" else { throw XCTSkip("RAW 9 unavailable") }
        let a = Self.average(plain.image, context: gpu.ciContext)
        let b = Self.average(neural.image, context: gpu.ciContext)
        for c in 0..<3 { XCTAssertEqual(b[c], a[c], accuracy: 0.1 * a[c], "channel \(c)") }
    }

    static func average(_ image: CIImage, context: CIContext) -> [Float] {
        var px = [Float](repeating: 0, count: 4)
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        return Array(px[0..<3])
    }

    static func detailNoise(_ image: CIImage) -> Float {
        let size = 400
        var px = [Float](repeating: 0, count: size * size * 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            image, toBitmap: &px, rowBytes: size * 16,
            bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: CGFloat(size), height: CGFloat(size)),
            format: .RGBAf, colorSpace: nil)
        var values: [Float] = []
        for y in 1..<size - 1 {
            for x in 1..<size - 1 {
                let i = (y * size + x) * 4 + 1
                values.append(px[i] - (px[i - 4] + px[i + 4] + px[i - size * 4] + px[i + size * 4]) / 4)
            }
        }
        let mean = values.reduce(0, +) / Float(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
    }
}
