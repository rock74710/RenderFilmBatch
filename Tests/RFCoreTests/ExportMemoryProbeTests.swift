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

/// Opt in with RF_EXPORT_MEMORY_PROBE=1, RF_EXPORT_MEMORY_SOURCE=/path/to/60mp.jpg,
/// and RF_EXPORT_MEMORY_MODE=current|strip. Run each mode in a fresh process.
final class ExportMemoryProbeTests: XCTestCase {
    private struct InputHeader: Encodable {
        let typeIdentifier: String
        let width: Int
        let height: Int
        let orientation: Int
    }

    private struct FootprintPeak: Encodable {
        let bytes: UInt64?
        let sampleCount: Int
    }

    private struct MemorySnapshot: Encodable {
        let footprintBytes: UInt64?
        let metalBytes: Int
    }

    private struct StageRecord: Encodable {
        let stage: String
        let seconds: Double
        let peak: FootprintPeak
        let before: MemorySnapshot
        let after: MemorySnapshot
    }

    private struct PixelReference: Codable {
        let sourceSHA256: String
        let width: Int
        let height: Int
        let format: String
        let exposureEV: Double
        let outputRGBA8SHA256: String
    }

    private struct ProbeRecord: Encodable {
        let mode: String
        let sourceName: String
        let sourceSHA256: String
        let source: InputHeader
        let device: String
        let physicalMemoryBytes: UInt64
        let thermalBefore: String
        let thermalAfter: String
        let stages: [StageRecord]
        let totalPeak: FootprintPeak
        let outputWidth: Int
        let outputHeight: Int
        let outputBytes: Int
        let outputRGBA8SHA256: String
    }

    func testLargeProcessedExportMemoryProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RF_EXPORT_MEMORY_PROBE"] == "1" else {
            throw XCTSkip("Set RF_EXPORT_MEMORY_PROBE=1 to run the opt-in 60 MP export memory probe")
        }
        guard let sourcePath = environment["RF_EXPORT_MEMORY_SOURCE"] else {
            throw XCTSkip("Set RF_EXPORT_MEMORY_SOURCE to the same 60 MP JPEG or HEIC for every mode")
        }
        guard let mode = environment["RF_EXPORT_MEMORY_MODE"],
              ["current", "strip"].contains(mode) else {
            XCTFail("Set RF_EXPORT_MEMORY_MODE to current or strip")
            return
        }

        let input = URL(fileURLWithPath: sourcePath)
        let header = try readHeader(input)
        XCTAssertTrue([UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier]
            .contains(header.typeIdentifier), "The probe needs a JPEG or HEIC source")
        XCTAssertGreaterThanOrEqual(header.width * header.height, 59_000_000,
                                     "Use a source with about 60 megapixels")
        let sourceData = try Data(contentsOf: input, options: .mappedIfSafe)
        let sourceSHA256 = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let format: BatchExportSettings.FileFormat = header.typeIdentifier == UTType.jpeg.identifier
            ? .jpeg : .heic

        let gpu = try XCTUnwrap(GPUContext.shared)
        let pipeline = try RenderPipeline(gpu: gpu)
        let batch = BatchExporter(pipeline: pipeline)
        let lutRenderer: LUTRenderer
        if mode == "current" {
            lutRenderer = try LUTRenderer(gpu: gpu, maximumSourceRows: Int.max)
        } else {
            lutRenderer = try LUTRenderer(gpu: gpu)
        }
        let renderer = try ProcessedImageRenderer(gpu: gpu, lutRenderer: lutRenderer)
        let exporter = Exporter(gpu: gpu)
        var settings = BatchExportSettings()
        settings.format = format
        settings.outputSize = .original
        settings.quality = 0.9
        // This matches the iPhone probe. The nonzero exposure forces the regular edited path,
        // where the neutral colorManagedImage shortcut cannot be used.
        settings.exposureCompensationEV = 0.6

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RFExportMemoryProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let output = outputDirectory.appendingPathComponent("probe.\(format == .jpeg ? "jpg" : "heic")")

        let resultsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/qa-rfcore-performance/export-memory", isDirectory: true)
        try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        let referenceURL = resultsDirectory.appendingPathComponent("\(sourceSHA256)-reference.json")

        gpu.ciContext.clearCaches()
        let thermalBefore = thermalStateName(ProcessInfo.processInfo.thermalState)
        let totalBefore = memorySnapshot(device: gpu.device)
        let totalSampler = PeakFootprintSampler()
        defer { _ = totalSampler.stop() }
        var stages: [StageRecord] = []

        let decodedAndMeasured = try measure("decode", device: gpu.device) {
            try ProcessedImageDecoder().decode(url: input, context: gpu.ciContext)
        }
        let decoded = decodedAndMeasured.value
        stages.append(decodedAndMeasured.record)
        XCTAssertEqual(decoded.fullSize.width, CGFloat(header.width))
        XCTAssertEqual(decoded.fullSize.height, CGFloat(header.height))

        let preparedAndMeasured = try await measureAsync("prepare", device: gpu.device) {
            try await batch.prepareProcessed(decoded: decoded, settings: settings, exposureEV: nil)
        }
        let prepared = preparedAndMeasured.value
        stages.append(preparedAndMeasured.record)
        XCTAssertEqual(prepared.parameters.layerA.exposureEV, 0.6, accuracy: 0.0001)

        let renderedAndMeasured = try measure("render-and-resize", device: gpu.device) {
            let rendered = try renderer.render(source: prepared.source,
                                               parameters: prepared.parameters,
                                               target: settings.target)
            return try BatchExporter.finalImage(rendered, settings: settings,
                                                context: gpu.ciContext).image
        }
        let finalImage = renderedAndMeasured.value
        stages.append(renderedAndMeasured.record)
        XCTAssertEqual(Int(finalImage.extent.integral.width), header.width)
        XCTAssertEqual(Int(finalImage.extent.integral.height), header.height)

        let metadata = BatchMetadata.outputProperties(fromRaw: input)
        let encodedAndMeasured = try measure("encode", device: gpu.device) {
            let write: () throws -> Void = {
                try exporter.write(image: finalImage.settingProperties(metadata), to: output,
                                   target: settings.target, format: settings.exporterFormat,
                                   quality: settings.quality)
            }
            try write()
        }
        stages.append(encodedAndMeasured.record)
        let totalPeak = totalSampler.stop()
        let totalAfter = memorySnapshot(device: gpu.device)

        let outputInfo = try ProcessedImageDecoder().probe(url: output)
        XCTAssertEqual(outputInfo.width, header.width)
        XCTAssertEqual(outputInfo.height, header.height)
        XCTAssertEqual(outputInfo.format, format == .jpeg ? .jpeg : .heic)
        let outputPixelHash = try outputRGBA8SHA256(output)
        let pixelReference = PixelReference(
            sourceSHA256: sourceSHA256,
            width: outputInfo.width,
            height: outputInfo.height,
            format: outputInfo.format.rawValue,
            exposureEV: settings.exposureCompensationEV,
            outputRGBA8SHA256: outputPixelHash
        )
        if mode == "current" {
            let data = try JSONEncoder().encode(pixelReference)
            try data.write(to: referenceURL, options: .atomic)
        } else {
            guard FileManager.default.fileExists(atPath: referenceURL.path) else {
                throw XCTSkip("Run current mode first to write the pixel reference for this source")
            }
            let reference = try JSONDecoder().decode(PixelReference.self,
                                                      from: Data(contentsOf: referenceURL))
            XCTAssertEqual(reference.sourceSHA256, pixelReference.sourceSHA256)
            XCTAssertEqual(reference.width, pixelReference.width)
            XCTAssertEqual(reference.height, pixelReference.height)
            XCTAssertEqual(reference.format, pixelReference.format)
            XCTAssertEqual(reference.exposureEV, pixelReference.exposureEV)
            XCTAssertEqual(pixelReference.outputRGBA8SHA256, reference.outputRGBA8SHA256,
                           "The candidate export must preserve every decoded RGBA8 pixel exactly")
        }

        let outputBytes = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: output.path)[.size]
            as? NSNumber)?.intValue)
        let record = ProbeRecord(
            mode: mode,
            sourceName: input.lastPathComponent,
            sourceSHA256: sourceSHA256,
            source: header,
            device: gpu.device.name,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            thermalBefore: thermalBefore,
            thermalAfter: thermalStateName(ProcessInfo.processInfo.thermalState),
            stages: stages,
            totalPeak: totalPeak,
            outputWidth: outputInfo.width,
            outputHeight: outputInfo.height,
            outputBytes: outputBytes,
            outputRGBA8SHA256: outputPixelHash
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try jsonEncoder.encode(record)
        print("RF_EXPORT_MEMORY_PROBE \(String(decoding: json, as: UTF8.self))")
        print("RF_EXPORT_MEMORY_SUMMARY mode=\(mode) beforeFootprint=\(totalBefore.footprintBytes ?? 0) afterFootprint=\(totalAfter.footprintBytes ?? 0) totalPeak=\(totalPeak.bytes ?? 0) samples=\(totalPeak.sampleCount) result=\(resultsDirectory.appendingPathComponent("\(mode)-\(sourceSHA256).json").path)")
        try json.write(to: resultsDirectory.appendingPathComponent("\(mode)-\(sourceSHA256).json"),
                       options: .atomic)
    }

    private func readHeader(_ url: URL) throws -> InputHeader {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ProcessedImageError.cannotRead(url)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return InputHeader(
            typeIdentifier: type,
            width: swapsAxes ? height : width,
            height: swapsAxes ? width : height,
            orientation: orientation
        )
    }

    private func outputRGBA8SHA256(_ url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary))
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, pixelCount <= Int.max / 4 else {
            throw ExportError.encodingFailed("Output is too large for the RGBA8 verification buffer")
        }
        var rgba = Data(count: pixelCount * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined()
    }

    private func measure<T>(_ name: String, device: any MTLDevice,
                            operation: () throws -> T) rethrows -> (value: T, record: StageRecord) {
        let before = memorySnapshot(device: device)
        let sampler = PeakFootprintSampler()
        defer { _ = sampler.stop() }
        let start = ContinuousClock.now
        let value = try operation()
        let end = ContinuousClock.now
        let peak = sampler.stop()
        let after = memorySnapshot(device: device)
        return (value, StageRecord(stage: name, seconds: seconds(from: start, to: end),
                                   peak: peak, before: before, after: after))
    }

    private func measureAsync<T>(_ name: String, device: any MTLDevice,
                                 operation: () async throws -> T) async rethrows
        -> (value: T, record: StageRecord) {
        let before = memorySnapshot(device: device)
        let sampler = PeakFootprintSampler()
        defer { _ = sampler.stop() }
        let start = ContinuousClock.now
        let value = try await operation()
        let end = ContinuousClock.now
        let peak = sampler.stop()
        let after = memorySnapshot(device: device)
        return (value, StageRecord(stage: name, seconds: seconds(from: start, to: end),
                                   peak: peak, before: before, after: after))
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private func memorySnapshot(device: any MTLDevice) -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return MemorySnapshot(
            footprintBytes: result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil,
            metalBytes: device.currentAllocatedSize
        )
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown-\(state.rawValue)"
        }
    }

    private final class PeakFootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peakBytes: UInt64?
        private var sampleCount = 0
        private var running = true
        private let finished = DispatchSemaphore(value: 0)

        init() {
            Thread.detachNewThread { [self] in
                while true {
                    let bytes = Self.currentFootprint()
                    lock.lock()
                    if let bytes { peakBytes = max(peakBytes ?? 0, bytes) }
                    sampleCount += 1
                    let keepGoing = running
                    lock.unlock()
                    if !keepGoing { break }
                    usleep(5_000)
                }
                finished.signal()
            }
        }

        func stop() -> FootprintPeak {
            lock.lock()
            let wasRunning = running
            running = false
            lock.unlock()
            if wasRunning {
                finished.wait()
                let bytes = Self.currentFootprint()
                lock.lock()
                if let bytes { peakBytes = max(peakBytes ?? 0, bytes) }
                sampleCount += 1
                lock.unlock()
            }
            lock.lock()
            defer { lock.unlock() }
            return FootprintPeak(bytes: peakBytes, sampleCount: sampleCount)
        }

        private static func currentFootprint() -> UInt64? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { infoPointer in
                infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
        }
    }
}
