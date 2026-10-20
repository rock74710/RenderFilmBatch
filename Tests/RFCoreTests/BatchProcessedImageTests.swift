import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RFCore

final class BatchProcessedImageTests: XCTestCase {
    func testJPEGPreviewUsesProcessedImagePath() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("processed.jpg")
        try writeImage(to: input, type: .jpeg)

        let gpu = try XCTUnwrap(GPUContext.shared)
        let pipeline = try RenderPipeline(gpu: gpu)
        let exporter = BatchExporter(pipeline: pipeline)
        let preview = try await exporter.preview(rawURL: input, settings: BatchExportSettings(),
                                                 maxDimension: 120)
        XCTAssertEqual(preview.image.width, 64)
        XCTAssertEqual(preview.image.height, 48)

        let decoded = try ProcessedImageDecoder().decode(url: input, context: gpu.ciContext)
        let expected = try ProcessedImageRenderer(gpu: gpu).render(
            source: decoded, parameters: ProcessedImageRenderer.defaults(),
            target: .preset(.appleSDR), maxDimension: 120
        )
        let expectedCG = try XCTUnwrap(gpu.ciContext.createCGImage(
            expected, from: expected.extent, format: .RGBA8,
            colorSpace: RenderPipeline.colorSpace(for: .preset(.appleSDR))
        ))
        XCTAssertLessThanOrEqual(try maximumChannelDelta(preview.image, expectedCG), 1,
                                 "neutral processed input should keep its color-managed appearance")

        var editedSettings = BatchExportSettings()
        editedSettings.profile = .chromeLike
        editedSettings.film.select(.cinema)
        editedSettings.curve.rgb = [0, 0.25, 0.75, 1]
        let edited = try await exporter.preview(rawURL: input, settings: editedSettings, maxDimension: 120)
        XCTAssertGreaterThan(try maximumChannelDelta(preview.image, edited.image), 3,
                             "profile, film, and curve settings should change the processed preview")
    }

    func testJPEGExportUsesProcessedSettingsAndNormalizesOrientation() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("rotated.jpg")
        try writeImage(to: input, type: .jpeg, orientation: 6)
        let output = folder.appendingPathComponent("export.jpg")

        let gpu = try XCTUnwrap(GPUContext.shared)
        let pipeline = try RenderPipeline(gpu: gpu)
        var settings = BatchExportSettings()
        settings.format = .jpeg
        settings.automaticExposure = true
        settings.noiseReduction = 1
        settings.outputSize = .percent(50)
        settings.profile = .chromeLike
        settings.curve.rgb = [0, 0.25, 0.75, 1]

        let result = try await BatchExporter(pipeline: pipeline).process(
            rawURL: input, outputURL: output, settings: settings
        )
        XCTAssertNotEqual(result.appliedExposureEV, 0)
        XCTAssertFalse(result.neuralNoiseReduction, "RAW noise reduction must not run for JPEG")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 24)
        XCTAssertEqual(image.height, 32)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any])
        XCTAssertNotEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6,
                          "the exported pixels already include the source orientation")
    }

    func testHEICPreviewAndExportUseProcessedImagePathWhenImageIOCanEncodeHEIF() async throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
            .contains(UTType.heic.identifier) else {
            throw XCTSkip("Image I/O HEIF encoding is unavailable on this host")
        }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("processed.heic")
        let output = folder.appendingPathComponent("export.heic")
        try writeImage(to: input, type: .heic)

        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let preview = try await exporter.preview(rawURL: input, settings: BatchExportSettings(),
                                                 maxDimension: 120)
        XCTAssertEqual(preview.image.width, 64)
        let result = try await exporter.process(rawURL: input, outputURL: output,
                                                settings: BatchExportSettings())
        XCTAssertEqual(result.outputURL, output)
        XCTAssertEqual(try ProcessedImageDecoder().probe(url: output).format, .heic)
    }

    func testProcessedJPEGHDRExportBuildsAuxiliaryImage() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("JPEG HDR export needs macOS 15 or newer") }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("sdr.jpg")
        let output = folder.appendingPathComponent("hdr.jpg")
        try writeImage(to: input, type: .jpeg)

        let gpu = try XCTUnwrap(GPUContext.shared)
        var settings = BatchExportSettings()
        settings.format = .jpeg
        settings.hdr = true
        let result = try await BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
            .process(rawURL: input, outputURL: output, settings: settings)
        XCTAssertEqual(result.outputURL, output)
        XCTAssertNotNil(CGImageSourceCreateWithURL(output as CFURL, nil))
    }

    func testBatchFreezesOriginalAutoWhiteBalanceAcrossStraightenPreviewAndExport() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("tilted.jpg")
        let output = folder.appendingPathComponent("straightened.tiff")
        try writeTiltedHorizonImage(to: input)

        let gpu = try XCTUnwrap(GPUContext.shared)
        let decoded = try ProcessedImageDecoder().decode(url: input, context: gpu.ciContext)
        let originalWhiteBalance = AutoWhiteBalance.analyze(decoded.image, context: gpu.ciContext)
        XCTAssertFalse(originalWhiteBalance.usedFallback)
        XCTAssertGreaterThan(abs(originalWhiteBalance.gains.x - 1) + abs(originalWhiteBalance.gains.z - 1), 0.1)

        let degrees = try XCTUnwrap(AutoStraighten.detect(decoded.image, context: gpu.ciContext))
        XCTAssertGreaterThan(abs(degrees), AutoStraighten.minDegrees)
        let straightened = AutoStraighten.apply(degrees, to: decoded.image)
        let transformedWhiteBalance = AutoWhiteBalance.analyze(straightened, context: gpu.ciContext)
        XCTAssertTrue(transformedWhiteBalance.usedFallback
                      || abs(transformedWhiteBalance.gains.x - originalWhiteBalance.gains.x)
                        + abs(transformedWhiteBalance.gains.z - originalWhiteBalance.gains.z) > 0.05,
                      "straighten should crop away the neutral patch that informed the original analysis")

        var settings = BatchExportSettings()
        settings.whiteBalance = .automatic
        settings.automaticStraighten = true
        settings.format = .tiff
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))
        let preview = try await exporter.preview(rawURL: input, settings: settings, maxDimension: 2000)
        XCTAssertFalse(preview.result.automaticWhiteBalanceUsedFallback)
        XCTAssertEqual(preview.result.straightenDegrees, degrees, accuracy: 0.01)

        var expectedParameters = ProcessedImageRenderer.defaults()
        expectedParameters.layerA.whiteBalance.select(.auto)
        let expectedSource = DecodedProcessedImage(
            url: decoded.url, image: straightened, metadata: decoded.metadata,
            colorSpace: decoded.colorSpace, info: decoded.info
        )
        let expected = try ProcessedImageRenderer(gpu: gpu).render(
            source: expectedSource, parameters: expectedParameters,
            target: .preset(.appleSDR), autoWhiteBalanceGains: originalWhiteBalance.gains
        )
        let expectedImage = try XCTUnwrap(gpu.ciContext.createCGImage(
            expected, from: expected.extent, format: .RGBA8,
            colorSpace: RenderPipeline.colorSpace(for: .preset(.appleSDR))
        ))
        XCTAssertLessThanOrEqual(try maximumChannelDelta(preview.image, expectedImage), 1,
                                 "batch preview must render with the gains analyzed from the original image")

        _ = try await exporter.process(rawURL: input, outputURL: output, settings: settings)
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let outputImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        XCTAssertLessThanOrEqual(try maximumChannelDelta(preview.image, outputImage), 1,
                                 "batch export should match the preview's frozen white balance")
    }

    func testInputFilteringKeepsRAWAndAddsJPEGAndHEIC() {
        for ext in ProcessedImageDecoder.requiredExtensions {
            XCTAssertTrue(BatchExporter.isSupportedInput(URL(fileURLWithPath: "/tmp/photo.\(ext)")))
        }
        let rawExtension = RawDecoder.requiredExtensions.first ?? "dng"
        XCTAssertTrue(BatchExporter.isSupportedInput(URL(fileURLWithPath: "/tmp/photo.\(rawExtension)")))
        XCTAssertFalse(BatchExporter.isSupportedInput(URL(fileURLWithPath: "/tmp/readme.txt")))
    }

    func testCorruptProcessedImageFailsAndExistingOutputIsPreserved() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let corrupt = folder.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: corrupt)
        let output = folder.appendingPathComponent("broken-export.heic")
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = BatchExporter(pipeline: try RenderPipeline(gpu: gpu))

        do {
            _ = try await exporter.preview(rawURL: corrupt, settings: BatchExportSettings(), maxDimension: 120)
            XCTFail("corrupt JPEG preview should fail")
        } catch is ProcessedImageError {
        }
        do {
            _ = try await exporter.process(rawURL: corrupt, outputURL: output, settings: BatchExportSettings())
            XCTFail("corrupt JPEG export should fail")
        } catch is ProcessedImageError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let original = Data("keep".utf8)
        try original.write(to: output)
        do {
            _ = try await exporter.process(rawURL: corrupt, outputURL: output, settings: BatchExportSettings())
            XCTFail("an existing output should be rejected before decoding")
        } catch BatchExportError.outputAlreadyExists {
        }
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                               isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(to url: URL, type: UTType, orientation: Int = 1) throws {
        let width = 64
        let height = 48
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(x * 255 / (width - 1))
                bytes[offset + 1] = UInt8(y * 255 / (height - 1))
                bytes[offset + 2] = 80
                bytes[offset + 3] = 255
            }
        }
        let data = Data(bytes) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeTiltedHorizonImage(to url: URL) throws {
        let extent = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let sky = CIImage(color: CIColor(red: 0.55, green: 0.7, blue: 0.95)).cropped(to: extent)
        let ground = CIImage(color: CIColor(red: 0.2, green: 0.25, blue: 0.1))
            .cropped(to: CGRect(x: -2000, y: -2000, width: 5500, height: 2500))
            .transformed(by: CGAffineTransform(translationX: 750, y: 500).rotated(by: 4 * .pi / 180)
                .translatedBy(x: -750, y: -500))
        let scene = ground.composited(over: sky).cropped(to: extent)
        // This warm-neutral corner patch is over 1% of the source pixels, then mostly cropped
        // away by the straighten correction so the renderer must reuse the original analysis.
        let neutralPatch = CIImage(color: CIColor(red: 0.42, green: 0.40, blue: 0.38))
            .cropped(to: CGRect(x: 800, y: 960, width: 650, height: 40))
        let image = neutralPatch.composited(over: scene).cropped(to: extent)
        let context = CIContext()
        let cgImage = try XCTUnwrap(context.createCGImage(
            image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func maximumChannelDelta(_ a: CGImage, _ b: CGImage) throws -> Int {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        // 先統一色彩空間與通道排列，避免直接比較 TIFF 與預覽不同的位元組格式。
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        return zip(try pixels(a), try pixels(b)).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}
