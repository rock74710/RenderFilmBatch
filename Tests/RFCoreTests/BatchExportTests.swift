import XCTest
import ImageIO
@testable import RFCore

final class BatchExportTests: XCTestCase {
    func testGrainReachesPreviewAndExportPreparation() async throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let decoded = DecodedRaw(url: URL(fileURLWithPath: "/synthetic.dng"), image: image,
                                 metadata: RawMetadata(), fullSize: image.extent.size,
                                 colorSpace: gpu.workingColorSpace)
        XCTAssertTrue(BatchExportSettings().grain.isNeutral)
        for strength in GrainStrength.allCases {
            var settings = BatchExportSettings()
            settings.grain.apply(strength)
            for dimension: Int? in [nil, 16] {
                let prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                                          exposureEV: nil, maxDimension: dimension)
                XCTAssertEqual(prepared.parameters.spatial.grain, settings.grain)
                XCTAssertTrue(prepared.parameters.spatial.enabled)
            }
        }
    }

    func testFilmSettingsReachSharedPreviewAndExportPreparation() async throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let image = CIImage(color: CIColor(red: 0.5, green: 0.1, blue: 0.04))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let decoded = DecodedRaw(url: URL(fileURLWithPath: "/synthetic.dng"), image: image,
                                 metadata: RawMetadata(), fullSize: image.extent.size,
                                 colorSpace: gpu.workingColorSpace)
        for style in FilmStyleID.allCases {
            var settings = BatchExportSettings()
            var selected = EditParameters()
            selected.applyFilmStyle(style)
            selected.film.amount = 0.35
            settings.film = selected.film
            for enabled in [true, false] {
                settings.film.enabled = enabled
                let prepared = try await exporter.prepare(decoded: decoded, settings: settings,
                                                          exposureEV: nil, maxDimension: 8)
                XCTAssertEqual(prepared.parameters.film, settings.film)
                XCTAssertEqual(prepared.parameters.colorEngine.profile, .natural)
            }
        }
        XCTAssertTrue(BatchExportSettings().film.isNeutral)
    }

    func testHDRFormatMapping() {
        var settings = BatchExportSettings()
        settings.format = .tiff
        XCTAssertEqual(settings.exporterFormat, .tiff)
        settings.hdr = true
        XCTAssertEqual(settings.exporterFormat, .tiff16)
        XCTAssertEqual(settings.target.gamut, .rec2020)
        XCTAssertEqual(settings.target.transferFunction, .pq)
        settings.format = .heic
        XCTAssertEqual(settings.exporterFormat, .heic)
    }

    func testExistingOutputIsRejectedBeforeRawDecode() async throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("existing.heic")
        let original = Data("keep".utf8)
        try original.write(to: output)
        let pipeline = try RenderPipeline(gpu: gpu)
        do {
            _ = try await BatchExporter(pipeline: pipeline).process(
                rawURL: folder.appendingPathComponent("missing.dng"), outputURL: output,
                settings: BatchExportSettings())
            XCTFail("Expected outputAlreadyExists")
        } catch BatchExportError.outputAlreadyExists {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testOutputSizeIsCappedAtMaxLongEdge() {
        let cap = CGFloat(BatchExportSettings.OutputSize.maxLongEdge)
        XCTAssertEqual(BatchExportSettings.OutputSize.percent(10_000).pixelSize(for: CGSize(width: 6000, height: 4000)),
                       CGSize(width: cap, height: (cap * 4000 / 6000).rounded()))
        XCTAssertEqual(BatchExportSettings.OutputSize.longEdge(1_000_000).pixelSize(for: CGSize(width: 4000, height: 6000)).height,
                       cap)
    }

    func testOutputSizeTargets() {
        let source = CGSize(width: 6000, height: 4000)
        XCTAssertEqual(BatchExportSettings.OutputSize.original.pixelSize(for: source), source)
        XCTAssertEqual(BatchExportSettings.OutputSize.longEdge(3000).pixelSize(for: source),
                       CGSize(width: 3000, height: 2000))
        XCTAssertEqual(BatchExportSettings.OutputSize.percent(50).pixelSize(for: source),
                       CGSize(width: 3000, height: 2000))
        XCTAssertEqual(BatchExportSettings.OutputSize.longEdge(3000)
                        .pixelSize(for: CGSize(width: 4000, height: 6000)),
                       CGSize(width: 2000, height: 3000))
        XCTAssertEqual(BatchExportSettings.OutputSize.longEdge(2000)
                        .pixelSize(for: CGSize(width: 1000, height: 667)),
                       CGSize(width: 2000, height: 1334))
    }

    func testResizeProducesExactExtent() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let half = BatchExporter.resize(image, to: .percent(50))
        XCTAssertEqual(half.extent, CGRect(x: 0, y: 0, width: 300, height: 200))
        let up = BatchExporter.resize(image, to: .longEdge(1000))
        XCTAssertEqual(up.extent, CGRect(x: 0, y: 0, width: 1000, height: 667))
        XCTAssertTrue(BatchExporter.resize(image, to: .original) === image)
    }

    func testWrittenFileHasTargetPixelSize() throws {
        guard let gpu = GPUContext.shared else { throw XCTSkip("GPU unavailable") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = BatchExportSettings()
        let image = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        let cases: [(BatchExportSettings.OutputSize, Int, Int)] = [
            (.longEdge(3000), 3000, 2000), (.percent(50), 3000, 2000), (.original, 6000, 4000)]
        for (index, (size, width, height)) in cases.enumerated() {
            let url = folder.appendingPathComponent("\(index).heic")
            try Exporter(gpu: gpu).write(image: BatchExporter.resize(image, to: size), to: url,
                                         target: settings.target, format: settings.exporterFormat)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, width, "\(size)")
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, height, "\(size)")
        }
    }
}
