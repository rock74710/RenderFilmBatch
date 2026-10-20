import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import RFCore

final class BatchImprovementsTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    // MARK: 輸出格式

    func testNewFormatMapping() {
        var settings = BatchExportSettings()
        settings.format = .jpeg
        XCTAssertEqual(settings.exporterFormat, .jpeg)
        settings.hdr = true
        XCTAssertEqual(settings.exporterFormat, .jpegHDR)
        XCTAssertTrue(settings.isHDR)
        settings.format = .png
        XCTAssertEqual(settings.exporterFormat, .png)
        XCTAssertFalse(settings.isHDR, "PNG 不支援 HDR，勾選 HDR 也輸出 SDR")
        XCTAssertEqual(settings.target.transferFunction, .sRGB)
    }

    // MARK: EXIF

    func testOutputKeepsCaptureMetadataAndDropsOrientation() throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("source.jpg")
        let pixel = try XCTUnwrap(GPUContext.shared?.ciContext.createCGImage(
            CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
            from: CGRect(x: 0, y: 0, width: 8, height: 8)))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixel, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:01 10:20:30",
                                             kCGImagePropertyExifISOSpeedRatings: [400]],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera",
                                             kCGImagePropertyTIFFOrientation: 6],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let metadata = BatchMetadata.outputProperties(fromRaw: source)
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        for (format, ext) in [(Exporter.Format.heic, "heic"), (.jpeg, "jpg"), (.tiff, "tiff"), (.png, "png")] {
            let url = folder.appendingPathComponent("out.\(ext)")
            try Exporter(gpu: gpu).write(image: image.settingProperties(metadata), to: url,
                                         target: .preset(.appleSDR), format: format)
            let written = try properties(url)
            let exif = written[kCGImagePropertyExifDictionary] as? [CFString: Any]
            XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                           "2026:09:01 10:20:30", "\(format)")
            let tiff = written[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "Test Camera", "\(format)")
            XCTAssertEqual((written[kCGImagePropertyOrientation] as? Int) ?? 1, 1, "\(format)")
            XCTAssertEqual(written[kCGImagePropertyPixelWidth] as? Int, 64, "\(format)")
        }
    }

    // MARK: EV 平滑

    func testShotsGroupBySettingsAndTimeGap() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func shot(_ offset: TimeInterval, iso: Double = 100, time: Double = 1.0 / 250) -> BatchExposureSmoothing.Shot {
            .init(date: t0.addingTimeInterval(offset), iso: iso, exposureTime: time, aperture: 8)
        }
        let shots = [shot(0), shot(5), shot(20), shot(200), shot(205, iso: 400), shot(210, iso: 400),
                     .init(date: nil, iso: 400, exposureTime: 1.0 / 250, aperture: 8)]
        XCTAssertEqual(BatchExposureSmoothing.groups(shots), [0, 0, 0, 1, 2, 2, 3])
    }

    func testSmoothedEVUsesGroupMedianAndKeepsMissingValues() {
        let smoothed = BatchExposureSmoothing.smoothed(evs: [0.1, 0.9, 0.3, 1.0, nil, 2.0],
                                                       groups: [0, 0, 0, 1, 2, 2])
        XCTAssertEqual(smoothed, [0.3, 0.3, 0.3, 1.0, nil, 2.0])
        let even = BatchExposureSmoothing.smoothed(evs: [0.0, 1.0], groups: [0, 0])
        XCTAssertEqual(even, [0.5, 0.5])
    }

    // MARK: CSV 報告

    func testReportCSVEscapesAndFormats() {
        let result = BatchExportResult(outputURL: URL(fileURLWithPath: "/tmp/a.heic"),
                                       appliedExposureEV: 0.456, appliedSkyEV: -0.5,
                                       meteringSources: ["face", "saliency"],
                                       automaticWhiteBalanceUsedFallback: true,
                                       neuralNoiseReduction: false, superResolved: false,
                                       automaticColorApplied: true)
        let csv = BatchReport.csv([
            .init(file: "a,1.NEF", outcome: .exported(result)),
            .init(file: "b.NEF", outcome: .skipped),
            .init(file: "c.NEF", outcome: .failed("壞檔 \"x\"")),
        ])
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "file,status,output,exposure_ev,sky_ev,metering,wb_fallback,auto_color,straighten_deg,neural_nr,super_resolution,error")
        XCTAssertEqual(lines[1], "\"a,1.NEF\",exported,a.heic,0.46,-0.50,face+saliency,yes,yes,0.00,no,no,")
        XCTAssertEqual(lines[2], "b.NEF,skipped,,,,,,,,,,")
        XCTAssertEqual(lines[3], "c.NEF,failed,,,,,,,,,,\"壞檔 \"\"x\"\"\"")
    }

    // MARK: 曲線刻度

    func testCurveSnapsToTenthsUnlessFree() {
        XCTAssertEqual(CurveEditing.gridDivisions, 10)
        XCTAssertEqual(CurveEditing.moved([], node: 2, to: 0.63, snap: true)[2], 0.6, accuracy: 1e-12)
        XCTAssertEqual(CurveEditing.moved([], node: 2, to: 0.66, snap: true)[2], 0.7, accuracy: 1e-12)
        XCTAssertEqual(CurveEditing.moved([], node: 2, to: 0.63, snap: false)[2], 0.63, accuracy: 1e-12)
        XCTAssertEqual(CurveEditing.moved([], node: 2, to: 0.52, snap: true), [], "吸回直線要收合")
    }

    // MARK: 真實 RAW（sampleraw 不在版本庫，沒有檔案就略過）

    private var sampleRaw: URL? {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("sampleraw")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter(RawDecoder.isSupported).sorted { $0.path < $1.path }.first
    }

    func testRealRawExportKeepsExifAndAutomaticColorPreview() async throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        guard let raw = sampleRaw else { throw XCTSkip("sampleraw 沒有 RAW") }
        let folder = try temporaryFolder()
        let batch = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        var settings = BatchExportSettings()
        settings.outputSize = .longEdge(800)
        settings.format = .jpeg
        let result = try await batch.process(rawURL: raw, outputURL: folder.appendingPathComponent("o.jpg"),
                                             settings: settings, exposureEV: 0.5)
        XCTAssertEqual(result.appliedExposureEV, 0.5)
        XCTAssertFalse(result.automaticColorApplied)
        let written = try properties(result.outputURL)
        let exif = try XCTUnwrap(written[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertNotNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertEqual((written[kCGImagePropertyOrientation] as? Int) ?? 1, 1)

        settings.automaticColor = true
        let preview = try await batch.preview(rawURL: raw, settings: settings, maxDimension: 400)
        XCTAssertEqual(max(preview.image.width, preview.image.height), 400)
        XCTAssertTrue(preview.result.automaticColorApplied)
        let ev = try await batch.analyzeExposure(rawURL: raw, settings: settings)
        XCTAssertTrue(ev.isFinite)
    }

    /// 取消後正在處理的照片要立刻停下：丟出 CancellationError，不留輸出檔或暫存檔。
    func testCancelledProcessStopsWithoutWritingOutput() async throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        guard let raw = sampleRaw else { throw XCTSkip("sampleraw 沒有 RAW") }
        let folder = try temporaryFolder()
        let batch = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let output = folder.appendingPathComponent("o.jpg")
        var settings = BatchExportSettings()
        settings.outputSize = .longEdge(800)
        settings.format = .jpeg
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await batch.process(rawURL: raw, outputURL: output, settings: settings)
        }
        do {
            _ = try await task.value
            XCTFail("取消後不應輸出")
        } catch is CancellationError {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}
