import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RFCore

/// 設定 RF_PERFORMANCE_PROBE=1 啟用；固定照片與像素參考保存在版本控制之外。
final class BatchPerformanceProbeTests: XCTestCase {
    func testReproduciblePerformanceProbe() async throws {
        guard ProcessInfo.processInfo.environment["RF_PERFORMANCE_PROBE"] == "1" else {
            throw XCTSkip("Set RF_PERFORMANCE_PROBE=1 for the 24 MP performance probe")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/qa-rfcore-performance")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let settings = BatchExportSettings()
        let phase = ProcessInfo.processInfo.environment["RF_PERFORMANCE_PHASE"] ?? "baseline"
        func record(_ name: String, _ times: [Double]) {
            let sorted = times.sorted()
            print("RF_PERF \(phase) \(name) seconds=\(times.map { String(format: "%.6f", $0) }.joined(separator: ",")) median=\(String(format: "%.6f", sorted[sorted.count / 2]))")
        }
        func pixels(_ image: CGImage, name: String) throws {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = Data(bytes)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let reference = root.appendingPathComponent("stable-\(name).rgba")
            if phase == "baseline" { try data.write(to: reference) }
            else {
                let previous = try Data(contentsOf: reference)
                XCTAssertEqual(previous.count, data.count)
                let maximum = zip(previous, data).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
                print("RF_PIXELS \(name) maximumChannelDelta=\(maximum)")
                XCTAssertLessThanOrEqual(maximum, 1, "pixel output must remain equivalent")
            }
            print("RF_PIXELS \(name) size=\(image.width)x\(image.height) sha256=\(hash)")
        }
        var createdFixtures = false
        let jpeg = root.appendingPathComponent("deterministic-6000x4000.jpg")
        if !FileManager.default.fileExists(atPath: jpeg.path) {
            createdFixtures = true
            var bytes = [UInt8](repeating: 255, count: 6000 * 4000 * 4)
            for y in 0..<4000 { for x in 0..<6000 {
                let i = (y * 6000 + x) * 4
                bytes[i] = UInt8((x * 251 / 5999 + y / 37) % 256)
                bytes[i + 1] = UInt8((y * 239 / 3999 + x / 53) % 256)
                bytes[i + 2] = UInt8(((x / 19) ^ (y / 23)) % 256)
            } }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: 6000, height: 4000, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 24000, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        var inputs = [jpeg]
        let heic = root.appendingPathComponent("deterministic-6000x4000.heic")
        if (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier) {
            if !FileManager.default.fileExists(atPath: heic.path) {
                createdFixtures = true
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            inputs.append(heic)
        }
        // 首次建立照片與讀取既有照片的 JPEG 解碼可能不同；在新的程序才建立量測參考。
        guard !createdFixtures else {
            throw XCTSkip("測試照片已準備；請在新的程序重跑，避免建立照片的程序影響基準。")
        }
        for input in inputs {
            var times: [Double] = []
            for iteration in 0..<6 {
                let start = Date()
                let output = try await exporter.preview(rawURL: input, settings: settings, maxDimension: 1600)
                let elapsed = Date().timeIntervalSince(start)
                if iteration == 0 { record("preview-\(input.pathExtension)-cold", [elapsed]); try pixels(output.image, name: "preview-\(input.pathExtension)") }
                else { times.append(elapsed) }
            }
            record("preview-\(input.pathExtension)-warm", times)
        }
        var matching: [Double] = []
        var targetSettings = settings
        targetSettings.exposureCompensationEV = -0.6
        for iteration in 0..<6 {
            let start = Date()
            let report = try await exporter.matchExposure(referenceURL: jpeg, referenceSettings: settings,
                targets: [.init(photo: inputs.last!, settings: targetSettings)], maxDimension: 512)
            XCTAssertNil(report.results.first?.error)
            if iteration > 0 { matching.append(Date().timeIntervalSince(start)) }
        }
        record("brightness-match", matching)
        let source = try ProcessedImageDecoder().decode(url: jpeg, context: gpu.ciContext).image
        let optical = try OpticalRenderer(gpu: gpu)
        for mode in ["vignette", "geometry", "both"] {
            let profile = ResolvedLensProfile(source: .manual, identifier: mode,
                distortion: mode == "vignette" ? .none : .init(kind: .poly3, a: -0.02),
                vignetting: mode == "geometry" ? .none : .init(kind: .pa, k1: -0.3, k2: 0.05))
            var times: [Double] = []
            for iteration in 0..<6 {
                let start = Date()
                let output = try optical.apply(to: source, profile: profile)
                let image = try XCTUnwrap(gpu.ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
                let elapsed = Date().timeIntervalSince(start)
                if iteration == 0 { try pixels(image, name: "optical-\(mode)") }
                else { times.append(elapsed) }
            }
            record("optical-\(mode)", times)
        }
    }
}
