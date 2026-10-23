import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import RFCore

/// 設定 RF_EXPORT_CACHE_PROBE=1，並以 RF_EXPORT_CACHE_MODE=on|off 選擇模式；每種模式各用新程序執行。
final class ExportCacheProbeTests: XCTestCase {
    private struct StageTimes {
        let decode: Double
        let render: Double
        let encode: Double
        let total: Double
    }

    private struct MemorySnapshot {
        let metalBytes: Int
        let footprintBytes: UInt64?
        let footprintStatus: String
    }

    private struct OutputEvidence {
        let width: Int
        let height: Int
        let profileName: String
        let hasEmbeddedICC: Bool
        let rgba: Data
        let sha256: String
    }

    func testExportCacheProbe() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RF_EXPORT_CACHE_PROBE"] == "1" else {
            throw XCTSkip("Set RF_EXPORT_CACHE_PROBE=1 to run the export cache probe")
        }
        guard let mode = environment["RF_EXPORT_CACHE_MODE"], ["on", "off"].contains(mode) else {
            XCTFail("Set RF_EXPORT_CACHE_MODE to exactly one of: on, off")
            return
        }

        let cacheIntermediates = mode == "on"
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureRoot = repositoryRoot.appendingPathComponent("build/qa-rfcore-performance")
        let outputRoot = repositoryRoot.appendingPathComponent("build/qa-export-cache/\(mode)")
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let gpu = try XCTUnwrap(GPUContext.shared)
        let options: [CIContextOption: Any] = [
            .workingColorSpace: gpu.workingColorSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: cacheIntermediates,
            .highQualityDownsample: true,
        ]
        // 解碼與 renderer 仍使用 GPUContext.ciContext（快取開啟）；此額外 context 只切換快取設定，並在同一 queue 寫出最後 JPEG。
        let exportContext = CIContext(mtlCommandQueue: gpu.commandQueue, options: options)
        let renderer = try ProcessedImageRenderer(gpu: gpu)
        let decoder = ProcessedImageDecoder()
        let target = RenderingTarget.preset(.appleSDR)
        let outputColorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let quality = 0.9
        var parameters = ProcessedImageRenderer.defaults()
        parameters.layerA.exposureEV = 0.3
        parameters.target = target

        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        print("RF_EXPORT_CACHE mode=\(mode) cacheIntermediates=\(cacheIntermediates) pid=\(ProcessInfo.processInfo.processIdentifier) os=\(ProcessInfo.processInfo.operatingSystemVersionString) gpu=\(gpu.device.name) physicalMemory=\(ProcessInfo.processInfo.physicalMemory) thermalBefore=\(thermalBefore)")
        print("RF_EXPORT_CACHE_CONTEXT renderAndDecode=GPUContext.ciContext(cacheIntermediates:true) exportContext=sameCommandQueue(workingColorSpace:extendedLinearITUR_2020,workingFormat:RGBAh,highQualityDownsample:true,cacheIntermediates:\(cacheIntermediates)) exposureEV=0.3 target=appleSDR jpegQuality=\(quality)")

        for ext in ["jpg", "heic"] {
            let input = fixtureRoot.appendingPathComponent("deterministic-6000x4000.\(ext)")
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw XCTSkip("Missing fixed fixture: \(input.path)")
            }
            let fixtureData = try Data(contentsOf: input, options: .mappedIfSafe)
            let fixtureSHA = SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined()
            print("RF_EXPORT_CACHE_FIXTURE source=\(ext) path=\(input.path) bytes=\(fixtureData.count) sha256=\(fixtureSHA)")

            let sourceOutputRoot = outputRoot.appendingPathComponent(ext, isDirectory: true)
            try FileManager.default.createDirectory(at: sourceOutputRoot, withIntermediateDirectories: true)
            var durations: [StageTimes] = []
            var outputURLs: [URL] = []

            for iteration in 0..<6 {
                let output = sourceOutputRoot.appendingPathComponent(String(format: "output-%02d.jpg", iteration))
                try? FileManager.default.removeItem(at: output)
                let before = memorySnapshot(device: gpu.device)
                let iterationResult = try autoreleasepool { () throws -> (StageTimes, MemorySnapshot) in
                    let totalStart = ContinuousClock.now

                    let decodeStart = ContinuousClock.now
                    let decoded = try decoder.decode(url: input, context: gpu.ciContext)
                    let decodeEnd = ContinuousClock.now

                    let renderStart = ContinuousClock.now
                    let rendered = try renderer.render(source: decoded, parameters: parameters, target: target)
                    let renderEnd = ContinuousClock.now
                    XCTAssertEqual(Int(rendered.extent.integral.width), 6000)
                    XCTAssertEqual(Int(rendered.extent.integral.height), 4000)

                    let encodeStart = ContinuousClock.now
                    try exportContext.writeJPEGRepresentation(
                        of: rendered,
                        to: output,
                        colorSpace: outputColorSpace,
                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
                    )
                    let encodeEnd = ContinuousClock.now
                    let totalEnd = ContinuousClock.now
                    let times = StageTimes(
                        decode: seconds(from: decodeStart, to: decodeEnd),
                        render: seconds(from: renderStart, to: renderEnd),
                        encode: seconds(from: encodeStart, to: encodeEnd),
                        total: seconds(from: totalStart, to: totalEnd)
                    )
                    return (times, memorySnapshot(device: gpu.device))
                }
                let measured = iterationResult.0
                durations.append(measured)
                outputURLs.append(output)
                let afterRelease = memorySnapshot(device: gpu.device)
                let pass = iteration == 0 ? "first" : "repeat"
                print("RF_EXPORT_CACHE_SAMPLE source=\(ext) iteration=\(iteration + 1)/6 class=\(pass) decode=\(format(measured.decode)) render=\(format(measured.render)) encode=\(format(measured.encode)) total=\(format(measured.total)) metalBefore=\(before.metalBytes) metalWriteCompleteLive=\(iterationResult.1.metalBytes) metalAfterRelease=\(afterRelease.metalBytes) footprintBefore=\(footprintText(before)) footprintWriteCompleteLive=\(footprintText(iterationResult.1)) footprintAfterRelease=\(footprintText(afterRelease))")
            }

            let sourceEvidence = try autoreleasepool { () throws -> (Int, Int, String, Bool) in
                let info = try decoder.probe(url: input)
                XCTAssertEqual(info.width, 6000)
                XCTAssertEqual(info.height, 4000)
                return (info.width, info.height, info.colorProfileName ?? "unknown", !info.colorSpaceFallback)
            }
            print("RF_EXPORT_CACHE_INPUT source=\(ext) decoded=\(sourceEvidence.0)x\(sourceEvidence.1) iccProfile=\(sourceEvidence.2) iccEmbedded=\(sourceEvidence.3)")

            for (label, index) in [("first", 0), ("last", 5)] {
                let outputURL = outputURLs[index]
                let evidence = try autoreleasepool { () throws -> OutputEvidence in
                    let outputInfo = try decoder.probe(url: outputURL)
                    XCTAssertEqual(outputInfo.format, .jpeg)
                    XCTAssertEqual(outputInfo.width, 6000)
                    XCTAssertEqual(outputInfo.height, 4000)
                    let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
                    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, [
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary))
                    let rgba = try rgba8(image)
                    let sha = SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined()
                    return OutputEvidence(
                        width: image.width,
                        height: image.height,
                        profileName: outputInfo.colorProfileName ?? "unknown",
                        hasEmbeddedICC: !outputInfo.colorSpaceFallback,
                        rgba: rgba,
                        sha256: sha
                    )
                }
                let rgbaURL = sourceOutputRoot.appendingPathComponent("output-\(label).rgba")
                try evidence.rgba.write(to: rgbaURL, options: .atomic)
                print("RF_EXPORT_CACHE_OUTPUT source=\(ext) edge=\(label) decoded=\(evidence.width)x\(evidence.height) iccProfile=\(evidence.profileName) iccEmbedded=\(evidence.hasEmbeddedICC) rgbaBytes=\(evidence.rgba.count) rgbaSha256=\(evidence.sha256) rgbaFile=\(rgbaURL.path)")
            }

            let first = durations[0]
            let repeats = durations.dropFirst().map(\.total).sorted()
            let medianRepeat = repeats[repeats.count / 2]
            let finalMemory = memorySnapshot(device: gpu.device)
            print("RF_EXPORT_CACHE_SUMMARY source=\(ext) count=6 firstTotal=\(format(first.total)) repeatCount=5 repeatMedian=\(format(medianRepeat)) repeatTotals=\(durations.dropFirst().map { format($0.total) }.joined(separator: ",")) metalAfter=\(finalMemory.metalBytes) footprintAfter=\(footprintText(finalMemory))")
        }
        print("RF_EXPORT_CACHE_THERMAL before=\(thermalBefore) after=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%.6f", seconds)
    }

    private func rgba8(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes)
    }

    private func memorySnapshot(device: any MTLDevice) -> MemorySnapshot {
        let footprint = physicalFootprint()
        return MemorySnapshot(
            metalBytes: device.currentAllocatedSize,
            footprintBytes: footprint.bytes,
            footprintStatus: footprint.status
        )
    }

    private func physicalFootprint() -> (bytes: UInt64?, status: String) {
#if os(macOS)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (nil, "unavailable-kern-\(result)")
        }
        return (UInt64(info.phys_footprint), "ok")
#else
        return (nil, "unsupported-platform")
#endif
    }

    private func footprintText(_ snapshot: MemorySnapshot) -> String {
        guard let bytes = snapshot.footprintBytes else { return "\(snapshot.footprintStatus)" }
        return "\(bytes)-\(snapshot.footprintStatus)"
    }
}
