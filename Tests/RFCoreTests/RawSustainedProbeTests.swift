import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import RFCore

/// Set RF_RAW_PROBE_INPUT to an absolute path to a real RAW photo to run this probe.
final class RawSustainedProbeTests: XCTestCase {
    private static let previewMaxDimension = 1600
    private static let memorySampleIntervalMilliseconds = 5

    func testPinnedRaw8And9SustainedProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["RF_RAW_PROBE_INPUT"], !inputPath.isEmpty else {
            throw XCTSkip("Set RF_RAW_PROBE_INPUT to an absolute path to a real RAW photo")
        }
        guard inputPath.hasPrefix("/") else {
            XCTFail("RF_RAW_PROBE_INPUT must be an absolute path")
            return
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            XCTFail("RF_RAW_PROBE_INPUT does not exist")
            return
        }
        guard RawDecoder.isSupported(inputURL) else {
            XCTFail("RF_RAW_PROBE_INPUT must be a supported RAW photo")
            return
        }

        guard let iterations = iterationCount(environment["RF_RAW_PROBE_ITERATIONS"]) else {
            XCTFail("RF_RAW_PROBE_ITERATIONS must be an integer from 2 through 1000")
            return
        }
        guard let minimumSeconds = minimumDuration(environment["RF_RAW_PROBE_MIN_SECONDS"]) else {
            XCTFail("RF_RAW_PROBE_MIN_SECONDS must be a finite number from 0 through 300")
            return
        }
        guard let maximumMemoryGiB = memoryCeiling(environment["RF_RAW_PROBE_MAX_GIB"]) else {
            XCTFail("RF_RAW_PROBE_MAX_GIB must be a finite number greater than 0 and at most 256")
            return
        }
        let reportURL: URL?
        if let reportPath = environment["RF_RAW_PROBE_REPORT"], !reportPath.isEmpty {
            guard reportPath.hasPrefix("/") else {
                XCTFail("RF_RAW_PROBE_REPORT must be an absolute path")
                return
            }
            let selectedReportURL = URL(fileURLWithPath: reportPath).standardizedFileURL
            guard selectedReportURL.resolvingSymlinksInPath() != inputURL.resolvingSymlinksInPath() else {
                XCTFail("RF_RAW_PROBE_REPORT must not point to the input photo")
                return
            }
            reportURL = selectedReportURL
        } else {
            reportURL = nil
        }

        let decoder = RawDecoder()
        let availableVersions = decoder.availableDecoderVersions(for: inputURL)
        let selectedVersions = ["8", "9"].compactMap { major in
            availableVersions.first(where: { $0.hasPrefix(major) })
        }
        guard selectedVersions.count == 2 else {
            throw XCTSkip("The selected RAW file must support both decoder 8 and decoder 9")
        }

        let sourceTypeIdentifier = try imageTypeIdentifier(inputURL)
        let gpu = try XCTUnwrap(GPUContext.shared, "Metal GPU is unavailable")
        let pipeline = try RenderPipeline(gpu: gpu)
        let batchExporter = BatchExporter(pipeline: pipeline)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-raw-sustained-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let thermalBefore = thermalStateName(ProcessInfo.processInfo.thermalState)
        var versionRecords: [VersionRecord] = []
        var memoryLimitReached: (version: String, footprintGiB: Double)?
        var iterationCapReached: (version: String, elapsedSeconds: Double)?
        for version in selectedVersions {
            let versionThermalBefore = thermalStateName(ProcessInfo.processInfo.thermalState)
            var samples: [IterationRecord] = []
            let versionStart = ContinuousClock.now
            while samples.count < iterations || seconds(from: versionStart, to: .now) < minimumSeconds {
                guard samples.count < 1000 else {
                    iterationCapReached = (version, seconds(from: versionStart, to: .now))
                    break
                }
                let iteration = samples.count + 1
                let filenameVersion = version.replacingOccurrences(of: "/", with: "-")
                let outputURL = temporaryRoot.appendingPathComponent(
                    "output-\(filenameVersion)-\(iteration).jpg"
                )
                let record = try await runIteration(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    pinnedDecoderVersion: version,
                    sourceTypeIdentifier: sourceTypeIdentifier,
                    gpu: gpu,
                    pipeline: pipeline,
                    batchExporter: batchExporter,
                    iteration: iteration
                )
                samples.append(record)
                if let footprint = record.memory.peakProcessFootprintBytes,
                   Double(footprint) / 1_073_741_824 >= maximumMemoryGiB {
                    memoryLimitReached = (version, Double(footprint) / 1_073_741_824)
                    break
                }
            }
            let versionElapsedSeconds = seconds(from: versionStart, to: .now)
            versionRecords.append(VersionRecord(
                requestedDecoderVersion: version,
                thermalBefore: versionThermalBefore,
                thermalAfter: thermalStateName(ProcessInfo.processInfo.thermalState),
                elapsedSeconds: versionElapsedSeconds,
                minimumDurationReached: versionElapsedSeconds >= minimumSeconds,
                firstIterationPeakFootprintBytes: samples.first?.memory.peakProcessFootprintBytes,
                lastIterationPeakFootprintBytes: samples.last?.memory.peakProcessFootprintBytes,
                timingComparison: timingComparison(for: samples),
                iterations: samples
            ))
            if memoryLimitReached != nil || iterationCapReached != nil { break }
        }

        let report = ProbeRecord(
            schemaVersion: "rf-raw-sustained-probe-v1",
            source: SourceRecord(
                kind: "user-provided-raw",
                typeIdentifier: sourceTypeIdentifier,
                decoderVersionsAvailable: availableVersions
            ),
            configuration: ConfigurationRecord(
                iterationsPerDecoderVersion: iterations,
                minimumDurationSecondsPerDecoderVersion: minimumSeconds,
                maximumProcessFootprintGiB: maximumMemoryGiB,
                previewMaxDimension: Self.previewMaxDimension,
                memorySampleIntervalMilliseconds: Self.memorySampleIntervalMilliseconds,
                noiseReduction: "camera-default"
            ),
            hardware: HardwareRecord(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                metalDevice: gpu.device.name,
                metalUnifiedMemory: gpu.device.hasUnifiedMemory,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
                renderBackend: "RFCore GPUContext Metal command queue and Core Image context"
            ),
            thermalBefore: thermalBefore,
            thermalAfter: thermalStateName(ProcessInfo.processInfo.thermalState),
            terminationReason: memoryLimitReached.map {
                String(format: "memory-ceiling-reached-%@-%.2f-GiB", $0.version, $0.footprintGiB)
            } ?? iterationCapReached.map {
                "iteration-cap-reached-\($0.version)"
            } ?? "iteration-and-duration-targets-met",
            exportRoute: "BatchExporter.prepare preview; BatchExporter.exporter.exportFullResolution with pinned decoder version because BatchExporter.process has no pinned-version setting",
            decoderVersions: versionRecords,
            limitations: [
                "Stage times include end-to-end CPU and GPU work; GPU utilization and neural-engine counters were not available to this probe.",
                "Thermal state is a system condition, not a measurement of power or energy use."
            ]
        )
        try emit(report, to: reportURL)
        if let memoryLimitReached {
            XCTFail(String(format: "RAW probe stopped after %@ iteration reached %.2f GiB, at or above the %.2f GiB ceiling; partial report was emitted", memoryLimitReached.version, memoryLimitReached.footprintGiB, maximumMemoryGiB))
        }
        if let iterationCapReached {
            XCTFail(String(format: "RAW probe reached the 1000-iteration cap for %@ after %.1f seconds before meeting RF_RAW_PROBE_MIN_SECONDS", iterationCapReached.version, iterationCapReached.elapsedSeconds))
        }
    }

    private func runIteration(
        inputURL: URL,
        outputURL: URL,
        pinnedDecoderVersion: String,
        sourceTypeIdentifier: String,
        gpu: GPUContext,
        pipeline: RenderPipeline,
        batchExporter: BatchExporter,
        iteration: Int
    ) async throws -> IterationRecord {
        let sampler = PeakFootprintSampler(intervalMilliseconds: Self.memorySampleIntervalMilliseconds)
        defer { _ = sampler.stop() }

        let iterationStart = ContinuousClock.now
        let memoryBefore = memorySnapshot(device: gpu.device)
        let preview = try await decodeAndPreview(
            inputURL: inputURL,
            pinnedDecoderVersion: pinnedDecoderVersion,
            gpu: gpu,
            pipeline: pipeline,
            batchExporter: batchExporter
        )

        let memoryBeforeExport = memorySnapshot(device: gpu.device)
        let exportStart = ContinuousClock.now
        _ = try batchExporter.exporter.exportFullResolution(
            pipeline: pipeline,
            rawURL: inputURL,
            parameters: preview.parameters,
            pinnedDecoderVersion: pinnedDecoderVersion,
            to: outputURL,
            target: .preset(.appleSDR),
            format: .jpeg,
            quality: 0.9
        )
        let exportSeconds = seconds(from: exportStart, to: .now)
        let outputInfo = try autoreleasepool { try jpegOutputInfo(outputURL) }
        XCTAssertEqual(outputInfo.typeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(outputInfo.width, preview.sourceWidth)
        XCTAssertEqual(outputInfo.height, preview.sourceHeight)
        XCTAssertGreaterThan(outputInfo.encodedBytes, 0)
        let memoryAfterExport = memorySnapshot(device: gpu.device)

        let peak = sampler.stop()
        let totalSeconds = seconds(from: iterationStart, to: .now)
        return IterationRecord(
            iteration: iteration,
            decoderVersion: preview.decoderVersion,
            dimensions: DimensionsRecord(
                sourceWidth: preview.sourceWidth,
                sourceHeight: preview.sourceHeight,
                previewWidth: preview.previewWidth,
                previewHeight: preview.previewHeight,
                jpegWidth: outputInfo.width,
                jpegHeight: outputInfo.height,
                jpegEncodedBytes: outputInfo.encodedBytes
            ),
            timingsSeconds: TimingsRecord(
                decode: preview.decodeSeconds,
                preview1600: preview.previewSeconds,
                fullResolutionJPEGExport: exportSeconds,
                combined: totalSeconds
            ),
            memory: MemoryRecord(
                sampledPeakProcessFootprintBytes: peak.peakFootprintBytes,
                sampleCount: peak.sampleCount,
                successfulFootprintSamples: peak.successfulSamples,
                samplerStatus: peak.status,
                before: memoryBefore,
                afterDecode: preview.memoryAfterDecode,
                afterPreview: preview.memoryAfterPreview,
                beforeJPEGExport: memoryBeforeExport,
                afterJPEGExport: memoryAfterExport
            ),
            sourceTypeIdentifier: sourceTypeIdentifier
        )
    }

    /// Returns only scalar measurements and settings. Decoded RAW and preview images leave scope
    /// before the full-resolution export decodes the source again.
    private func decodeAndPreview(
        inputURL: URL,
        pinnedDecoderVersion: String,
        gpu: GPUContext,
        pipeline: RenderPipeline,
        batchExporter: BatchExporter
    ) async throws -> PreviewPreparation {
        let decodeStart = ContinuousClock.now
        let decoded = try pipeline.decoder.decode(url: inputURL, pinnedDecoderVersion: pinnedDecoderVersion)
        let decodeSeconds = seconds(from: decodeStart, to: .now)
        let actualDecoderVersion = try XCTUnwrap(decoded.metadata.decoderVersion)
        XCTAssertEqual(actualDecoderVersion, pinnedDecoderVersion)
        let sourceWidth = Int(decoded.fullSize.width.rounded())
        let sourceHeight = Int(decoded.fullSize.height.rounded())
        XCTAssertGreaterThan(sourceWidth, 0)
        XCTAssertGreaterThan(sourceHeight, 0)
        let memoryAfterDecode = memorySnapshot(device: gpu.device)

        let previewStart = ContinuousClock.now
        let prepared = try await batchExporter.prepare(
            decoded: decoded,
            settings: BatchExportSettings(),
            exposureEV: nil,
            maxDimension: Self.previewMaxDimension
        )
        let previewTarget = RenderingTarget.preset(.appleSDR)
        let previewSize = try autoreleasepool { () throws -> (width: Int, height: Int) in
            let rendered = try pipeline.render(
                sceneMaster: prepared.master,
                parameters: prepared.parameters,
                target: previewTarget
            )
            let image = try XCTUnwrap(gpu.ciContext.createCGImage(
                rendered,
                from: rendered.extent,
                format: .RGBA8,
                colorSpace: RenderPipeline.colorSpace(for: previewTarget)
            ))
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
            XCTAssertLessThanOrEqual(max(image.width, image.height), Self.previewMaxDimension)
            return (image.width, image.height)
        }
        let previewSeconds = seconds(from: previewStart, to: .now)
        let memoryAfterPreview = memorySnapshot(device: gpu.device)
        return PreviewPreparation(
            decoderVersion: actualDecoderVersion,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            previewWidth: previewSize.width,
            previewHeight: previewSize.height,
            decodeSeconds: decodeSeconds,
            previewSeconds: previewSeconds,
            memoryAfterDecode: memoryAfterDecode,
            memoryAfterPreview: memoryAfterPreview,
            parameters: prepared.parameters
        )
    }

    private func iterationCount(_ rawValue: String?) -> Int? {
        guard let rawValue else { return 6 }
        guard let value = Int(rawValue), (2...1000).contains(value) else { return nil }
        return value
    }

    private func minimumDuration(_ rawValue: String?) -> Double? {
        guard let rawValue else { return 0 }
        guard let value = Double(rawValue), value.isFinite, (0...300).contains(value) else { return nil }
        return value
    }

    private func memoryCeiling(_ rawValue: String?) -> Double? {
        guard let rawValue else { return 12 }
        guard let value = Double(rawValue), value.isFinite, value > 0, value <= 256 else { return nil }
        return value
    }

    private func emit(_ report: ProbeRecord, to reportURL: URL?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reportData = try encoder.encode(report)
        if let reportURL {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try reportData.write(to: reportURL, options: .atomic)
            let summary = ProbeSummary(
                schemaVersion: report.schemaVersion,
                fullReportWritten: true,
                decoderVersions: report.decoderVersions.map { version in
                    let peak = version.iterations.compactMap(\.memory.peakProcessFootprintBytes).max()
                    return VersionSummary(
                        decoderVersion: version.requestedDecoderVersion,
                        completedIterations: version.iterations.count,
                        elapsedSeconds: version.elapsedSeconds,
                        peakProcessFootprintBytes: peak,
                        firstIterationPeakFootprintBytes: version.firstIterationPeakFootprintBytes,
                        lastIterationPeakFootprintBytes: version.lastIterationPeakFootprintBytes,
                        timingComparison: version.timingComparison
                    )
                }
            )
            print("RF_RAW_SUSTAINED_SUMMARY \(String(decoding: try encoder.encode(summary), as: UTF8.self))")
        } else {
            print("RF_RAW_SUSTAINED_JSON \(String(decoding: reportData, as: UTF8.self))")
        }
    }

    private func timingComparison(for samples: [IterationRecord]) -> TimingComparison {
        guard let first = samples.first else {
            return TimingComparison(firstIteration: nil, laterIterationsCount: 0, laterMedian: nil)
        }
        let later = Array(samples.dropFirst().map(\.timingsSeconds))
        guard !later.isEmpty else {
            return TimingComparison(
                firstIteration: first.timingsSeconds,
                laterIterationsCount: 0,
                laterMedian: nil
            )
        }
        return TimingComparison(
            firstIteration: first.timingsSeconds,
            laterIterationsCount: later.count,
            laterMedian: TimingsRecord(
                decode: median(later.map(\.decode)),
                preview1600: median(later.map(\.preview1600)),
                fullResolutionJPEGExport: median(later.map(\.fullResolutionJPEGExport)),
                combined: median(later.map(\.combined))
            )
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        precondition(!sorted.isEmpty)
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func imageTypeIdentifier(_ url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceGetType(source) as String?)
    }

    private func jpegOutputInfo(_ url: URL) throws -> JPEGOutputInfo {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let typeIdentifier = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let encodedBytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
        return JPEGOutputInfo(
            typeIdentifier: typeIdentifier,
            width: width,
            height: height,
            encodedBytes: encodedBytes
        )
    }

    private func memorySnapshot(device: any MTLDevice) -> MemorySnapshot {
        let footprint = PeakFootprintSampler.currentFootprint()
        return MemorySnapshot(
            metalAllocatedBytes: device.currentAllocatedSize,
            processPhysicalFootprintBytes: footprint.value,
            processFootprintStatus: footprint.status
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

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

private struct ProbeRecord: Encodable {
    let schemaVersion: String
    let source: SourceRecord
    let configuration: ConfigurationRecord
    let hardware: HardwareRecord
    let thermalBefore: String
    let thermalAfter: String
    let terminationReason: String
    let exportRoute: String
    let decoderVersions: [VersionRecord]
    let limitations: [String]
}

private struct ProbeSummary: Encodable {
    let schemaVersion: String
    let fullReportWritten: Bool
    let decoderVersions: [VersionSummary]
}

private struct VersionSummary: Encodable {
    let decoderVersion: String
    let completedIterations: Int
    let elapsedSeconds: Double
    let peakProcessFootprintBytes: UInt64?
    let firstIterationPeakFootprintBytes: UInt64?
    let lastIterationPeakFootprintBytes: UInt64?
    let timingComparison: TimingComparison
}

private struct SourceRecord: Encodable {
    let kind: String
    let typeIdentifier: String
    let decoderVersionsAvailable: [String]
}

private struct ConfigurationRecord: Encodable {
    let iterationsPerDecoderVersion: Int
    let minimumDurationSecondsPerDecoderVersion: Double
    let maximumProcessFootprintGiB: Double
    let previewMaxDimension: Int
    let memorySampleIntervalMilliseconds: Int
    let noiseReduction: String
}

private struct HardwareRecord: Encodable {
    let operatingSystem: String
    let metalDevice: String
    let metalUnifiedMemory: Bool
    let physicalMemoryBytes: UInt64
    let activeProcessorCount: Int
    let renderBackend: String
}

private struct VersionRecord: Encodable {
    let requestedDecoderVersion: String
    let thermalBefore: String
    let thermalAfter: String
    let elapsedSeconds: Double
    let minimumDurationReached: Bool
    let firstIterationPeakFootprintBytes: UInt64?
    let lastIterationPeakFootprintBytes: UInt64?
    let timingComparison: TimingComparison
    let iterations: [IterationRecord]
}

private struct TimingComparison: Encodable {
    let firstIteration: TimingsRecord?
    let laterIterationsCount: Int
    let laterMedian: TimingsRecord?
}

private struct IterationRecord: Encodable {
    let iteration: Int
    let decoderVersion: String
    let dimensions: DimensionsRecord
    let timingsSeconds: TimingsRecord
    let memory: MemoryRecord
    let sourceTypeIdentifier: String
}

private struct DimensionsRecord: Encodable {
    let sourceWidth: Int
    let sourceHeight: Int
    let previewWidth: Int
    let previewHeight: Int
    let jpegWidth: Int
    let jpegHeight: Int
    let jpegEncodedBytes: Int
}

private struct TimingsRecord: Encodable {
    let decode: Double
    let preview1600: Double
    let fullResolutionJPEGExport: Double
    let combined: Double
}

private struct MemoryRecord: Encodable {
    let sampledPeakProcessFootprintBytes: UInt64?
    let sampleCount: Int
    let successfulFootprintSamples: Int
    let samplerStatus: String
    let before: MemorySnapshot
    let afterDecode: MemorySnapshot
    let afterPreview: MemorySnapshot
    let beforeJPEGExport: MemorySnapshot
    let afterJPEGExport: MemorySnapshot

    var peakProcessFootprintBytes: UInt64? {
        [
            sampledPeakProcessFootprintBytes,
            before.processPhysicalFootprintBytes,
            afterDecode.processPhysicalFootprintBytes,
            afterPreview.processPhysicalFootprintBytes,
            beforeJPEGExport.processPhysicalFootprintBytes,
            afterJPEGExport.processPhysicalFootprintBytes,
        ].compactMap { $0 }.max()
    }
}

private struct PreviewPreparation {
    let decoderVersion: String
    let sourceWidth: Int
    let sourceHeight: Int
    let previewWidth: Int
    let previewHeight: Int
    let decodeSeconds: Double
    let previewSeconds: Double
    let memoryAfterDecode: MemorySnapshot
    let memoryAfterPreview: MemorySnapshot
    let parameters: EditParameters
}

private struct MemorySnapshot: Encodable {
    let metalAllocatedBytes: Int
    let processPhysicalFootprintBytes: UInt64?
    let processFootprintStatus: String
}

private struct JPEGOutputInfo {
    let typeIdentifier: String
    let width: Int
    let height: Int
    let encodedBytes: Int
}

private struct FootprintReading {
    let value: UInt64?
    let status: String
}

private struct FootprintPeak {
    let peakFootprintBytes: UInt64?
    let sampleCount: Int
    let successfulSamples: Int
    let status: String
}

/// Samples process phys_footprint on a worker thread and always joins before returning.
private final class PeakFootprintSampler: @unchecked Sendable {
    private let intervalMilliseconds: Int
    private let condition = NSCondition()
    private var running = true
    private var joined = false
    private var finalReadStarted = false
    private var finalReadCompleted = false
    private var peakFootprintBytes: UInt64?
    private var sampleCount = 0
    private var successfulSamples = 0
    private var lastFailureStatus: String?

    init(intervalMilliseconds: Int) {
        self.intervalMilliseconds = intervalMilliseconds
        let worker = Thread { [self] in sampleLoop() }
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    func stop() -> FootprintPeak {
        condition.lock()
        running = false
        while !joined {
            condition.wait()
        }
        if !finalReadStarted {
            finalReadStarted = true
            condition.unlock()
            let reading = Self.currentFootprint()
            condition.lock()
            record(reading)
            finalReadCompleted = true
            condition.broadcast()
        } else {
            while !finalReadCompleted {
                condition.wait()
            }
        }
        defer { condition.unlock() }
        return FootprintPeak(
            peakFootprintBytes: peakFootprintBytes,
            sampleCount: sampleCount,
            successfulSamples: successfulSamples,
            status: lastFailureStatus.map { "partial-\($0)" } ?? (successfulSamples > 0 ? "ok" : "unavailable")
        )
    }

    private func sampleLoop() {
        while true {
            let reading = Self.currentFootprint()
            condition.lock()
            record(reading)
            let shouldContinue = running
            if !shouldContinue {
                joined = true
                condition.broadcast()
            }
            condition.unlock()
            if !shouldContinue { return }
            usleep(useconds_t(intervalMilliseconds * 1000))
        }
    }

    private func record(_ reading: FootprintReading) {
        sampleCount += 1
        if let value = reading.value {
            peakFootprintBytes = max(peakFootprintBytes ?? 0, value)
            successfulSamples += 1
        } else {
            lastFailureStatus = reading.status
        }
    }

    static func currentFootprint() -> FootprintReading {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return FootprintReading(value: nil, status: "unavailable-kern-\(result)")
        }
        return FootprintReading(value: UInt64(info.phys_footprint), status: "ok")
    }
}
