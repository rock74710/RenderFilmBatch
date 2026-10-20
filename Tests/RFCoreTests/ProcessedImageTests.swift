import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RFCore

final class ProcessedImageTests: XCTestCase {
    func testJPEGDecoderAppliesEveryExifOrientationOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = ProcessedImageDecoder()
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!])

        for orientation in 1...8 {
            let url = directory.appendingPathComponent("orientation-\(orientation).jpg")
            try writeQuadrants(to: url, type: .jpeg, orientation: orientation)
            let decoded = try decoder.decode(url: url, context: context)
            let swapsAxes = (5...8).contains(orientation)
            XCTAssertEqual(decoded.fullSize.width, swapsAxes ? 80 : 120, "orientation \(orientation)")
            XCTAssertEqual(decoded.fullSize.height, swapsAxes ? 120 : 80, "orientation \(orientation)")

            let extent = decoded.image.extent.integral
            let output = try XCTUnwrap(context.createCGImage(
                decoded.image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            ))
            let corners = try quadrantColors(output)
            XCTAssertEqual(corners, expectedQuadrants(for: orientation), "orientation \(orientation)")
        }
    }

    func testDecoderRejectsCorruptAndMismatchedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: corrupt)
        XCTAssertThrowsError(try ProcessedImageDecoder().probe(url: corrupt))

        let mismatch = directory.appendingPathComponent("jpeg-with-heic-name.heic")
        try writeQuadrants(to: mismatch, type: .jpeg, orientation: 1)
        XCTAssertThrowsError(try ProcessedImageDecoder().probe(url: mismatch))
    }

    func testHEIFDecoderUsesImageIOWhenAvailable() throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier) else {
            throw XCTSkip("Image I/O HEIF encoding is unavailable on this host")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("processed.heif")
        try writeQuadrants(to: url, type: .heic, orientation: 1)
        let decoded = try ProcessedImageDecoder().decode(url: url, context: CIContext())
        XCTAssertEqual(decoded.info.format, .heic)
        XCTAssertEqual(decoded.fullSize, CGSize(width: 120, height: 80))
    }

    func testNeutralRendererTracksColorManagedSRGBAndDisplayP3References() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gpu = try GPUContext()
        let decoder = ProcessedImageDecoder()
        let renderer = try ProcessedImageRenderer(gpu: gpu)
        let references: [(String, CGColorSpace, UTType)] = [
            ("srgb-jpeg", CGColorSpace(name: CGColorSpace.sRGB)!, .jpeg),
            ("p3-jpeg", CGColorSpace(name: CGColorSpace.displayP3)!, .jpeg),
        ]
        let canEncodeHEIF = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
        let sources = references + (canEncodeHEIF
            ? [("srgb-heif", CGColorSpace(name: CGColorSpace.sRGB)!, UTType.heic)]
            : [])

        for (name, colorSpace, type) in sources {
            let extensionName = type.preferredFilenameExtension ?? "img"
            let url = directory.appendingPathComponent("reference-\(name).\(extensionName)")
            try writeColorReference(to: url, colorSpace: colorSpace, type: type)
            let decoded = try decoder.decode(url: url, context: gpu.ciContext)
            if name == "srgb" {
                let proxy = try renderer.render(source: decoded, parameters: ProcessedImageRenderer.defaults(),
                                                target: .preset(.webSDR), maxDimension: 48)
                XCTAssertEqual(proxy.extent.integral.width, 48)
                XCTAssertEqual(proxy.extent.integral.height, 32)
            }
            let rendered = try renderer.render(source: decoded, parameters: ProcessedImageRenderer.defaults(),
                                               target: .preset(.webSDR))
            let actualImage = try XCTUnwrap(gpu.ciContext.createCGImage(
                rendered, from: rendered.extent.integral, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            ))

            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let sourceImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            let direct = CIImage(cgImage: sourceImage, options: [.colorSpace: sourceImage.colorSpace!])
            let referenceImage = try XCTUnwrap(gpu.ciContext.createCGImage(
                direct, from: direct.extent.integral, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            ))
            XCTAssertEqual(actualImage.width, referenceImage.width)
            XCTAssertEqual(actualImage.height, referenceImage.height)

            let (meanDelta, maxDelta) = try rgbDeltas(actualImage, referenceImage)
            print("neutral-reference \(name): mean RGB delta=\(String(format: "%.4f", meanDelta)), max RGB delta=\(maxDelta)")
            XCTAssertLessThanOrEqual(maxDelta, 5, "\(name) maximum RGB channel delta")
            XCTAssertLessThanOrEqual(meanDelta, 1.0, "\(name) mean RGB channel delta")
        }
    }

    func testProcessedSourceWhiteBalanceToneSpatialAndGeometryEditsAffectOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edits.jpg")
        try writeQuadrants(to: url, type: .jpeg, orientation: 1)
        let gpu = try GPUContext()
        let decoded = try ProcessedImageDecoder().decode(url: url, context: gpu.ciContext)
        let renderer = try ProcessedImageRenderer(gpu: gpu)
        let baseline = ProcessedImageRenderer.defaults()
        let neutral = try renderRGBA(renderer, source: decoded, parameters: baseline, context: gpu.ciContext)

        var whiteBalance = baseline
        whiteBalance.layerA.whiteBalance = WhiteBalanceParameters(preset: .custom, temperature: 3400, tint: 0.02)
        let wb = try renderRGBA(renderer, source: decoded, parameters: whiteBalance, context: gpu.ciContext)
        XCTAssertGreaterThan(try channelDelta(neutral, wb), 8, "relative white-balance edits should change the rendered source")

        var tone = baseline
        tone.toneMapping.midtoneContrast = 1.25
        let toned = try renderRGBA(renderer, source: decoded, parameters: tone, context: gpu.ciContext)
        XCTAssertGreaterThan(try channelDelta(neutral, toned), 2, "tone controls should remain editable for SDR sources")

        var mixer = baseline
        mixer.colorMixer.bands[0].saturationShift = -0.7
        let mixed = try renderRGBA(renderer, source: decoded, parameters: mixer, context: gpu.ciContext)
        XCTAssertGreaterThan(try channelDelta(neutral, mixed), 2, "color mixer controls should remain editable for SDR sources")

        var spatial = baseline
        spatial.spatial.vignette.amount = 0.7
        let vignetted = try renderRGBA(renderer, source: decoded, parameters: spatial, context: gpu.ciContext)
        XCTAssertGreaterThan(try channelDelta(neutral, vignetted), 4, "spatial finishing should affect processed sources")

        var geometry = baseline
        geometry.optical.geometry.cropRect = GeometryParameters.CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try renderer.render(source: decoded, parameters: geometry)
        XCTAssertLessThanOrEqual(abs(cropped.extent.integral.width - 60), 2)
        XCTAssertLessThanOrEqual(abs(cropped.extent.integral.height - 40), 2)
    }

    func testProcessedSourceAppliesCreativeLUT() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lut.jpg")
        try writeQuadrants(to: url, type: .jpeg, orientation: 1)
        let gpu = try GPUContext()
        let decoded = try ProcessedImageDecoder().decode(url: url, context: gpu.ciContext)
        let renderer = try ProcessedImageRenderer(gpu: gpu)
        let baseline = ProcessedImageRenderer.defaults()
        let neutral = try renderRGBA(renderer, source: decoded, parameters: baseline, context: gpu.ciContext)

        var graded = baseline
        graded.film.lutID = "builtin:highContrastMono"
        let mono = try renderRGBA(renderer, source: decoded, parameters: graded, context: gpu.ciContext)
        XCTAssertGreaterThan(try channelDelta(neutral, mono), 20, "a selected LUT must bypass the neutral shortcut")

        let pixels = try XCTUnwrap(mono.dataProvider?.data as Data?)
        let offset = (mono.height / 4) * mono.bytesPerRow + (mono.width / 4) * 4
        XCTAssertLessThanOrEqual(abs(Int(pixels[offset]) - Int(pixels[offset + 2])), 3, "mono LUT output should be neutral")

        graded.film.lutID = directory.appendingPathComponent("missing.cube").path
        let missing = try renderRGBA(renderer, source: decoded, parameters: graded, context: gpu.ciContext)
        XCTAssertEqual(try rgbDeltas(neutral, missing).maximum, 0, "a missing LUT keeps the neutral rendering")

        graded.film.lutID = "builtin:highContrastMono"
        graded.film.lutAmount = 0
        let zero = try renderRGBA(renderer, source: decoded, parameters: graded, context: gpu.ciContext)
        XCTAssertEqual(try rgbDeltas(neutral, zero).maximum, 0, "LUT amount 0 keeps the neutral rendering")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeQuadrants(to url: URL, type: UTType, orientation: Int) throws {
        let width = 120
        let height = 80
        let colors: [[UInt8]] = [
            [250, 8, 8, 255], [4, 250, 45, 255],
            [5, 24, 250, 255], [250, 190, 6, 255],
        ]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let quadrant = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                let offset = (y * width + x) * 4
                bytes.replaceSubrange(offset..<(offset + 4), with: colors[quadrant])
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
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeColorReference(to url: URL, colorSpace: CGColorSpace, type: UTType) throws {
        let width = 96
        let height = 64
        let colors: [[UInt8]] = [
            [226, 56, 35, 255], [35, 207, 77, 255],
            [39, 70, 224, 255], [202, 174, 48, 255],
        ]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if y < 12 {
                    let value = UInt8((x * 255) / (width - 1))
                    bytes.replaceSubrange(offset..<(offset + 4), with: [value, value, value, 255])
                } else {
                    let quadrant = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                    let base = colors[quadrant]
                    let scale = Double(y - 12) / Double(height - 12 - 1)
                    let brightness = 0.28 + 0.72 * scale
                    let pixel = (0..<3).map { channel in
                        UInt8((Double(base[channel]) * brightness).rounded())
                    } + [255]
                    bytes.replaceSubrange(offset..<(offset + 4), with: pixel)
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func renderRGBA(_ renderer: ProcessedImageRenderer, source: DecodedProcessedImage,
                            parameters: EditParameters, context: CIContext) throws -> CGImage {
        let rendered = try renderer.render(source: source, parameters: parameters, target: .preset(.webSDR))
        return try XCTUnwrap(context.createCGImage(
            rendered, from: rendered.extent.integral, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ))
    }

    private func rgbDeltas(_ lhs: CGImage, _ rhs: CGImage) throws -> (mean: Double, maximum: Int) {
        let left = try XCTUnwrap(lhs.dataProvider?.data as Data?)
        let right = try XCTUnwrap(rhs.dataProvider?.data as Data?)
        XCTAssertEqual(lhs.width, rhs.width)
        XCTAssertEqual(lhs.height, rhs.height)
        var sum = 0
        var count = 0
        var maximum = 0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                let leftOffset = y * lhs.bytesPerRow + x * 4
                let rightOffset = y * rhs.bytesPerRow + x * 4
                for channel in 0..<3 {
                    let delta = abs(Int(left[leftOffset + channel]) - Int(right[rightOffset + channel]))
                    sum += delta
                    count += 1
                    maximum = max(maximum, delta)
                }
            }
        }
        return (Double(sum) / Double(count), maximum)
    }

    private func channelDelta(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
        let left = try XCTUnwrap(lhs.dataProvider?.data as Data?)
        let right = try XCTUnwrap(rhs.dataProvider?.data as Data?)
        return zip(left, right).reduce(into: 0) { largest, channels in
            let (a, b) = channels
            largest = max(largest, abs(Int(a) - Int(b)))
        }
    }

    private func quadrantColors(_ image: CGImage) throws -> [String] {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let bytes = data.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        let points = [
            (image.width / 4, image.height / 4),
            (image.width * 3 / 4, image.height / 4),
            (image.width / 4, image.height * 3 / 4),
            (image.width * 3 / 4, image.height * 3 / 4),
        ]
        return try points.map { x, y in
            let offset = y * image.bytesPerRow + x * 4
            let pixel = try XCTUnwrap(bytes[safe: offset..<offset + 3])
            let r = Int(pixel[pixel.startIndex])
            let g = Int(pixel[pixel.startIndex + 1])
            let b = Int(pixel[pixel.startIndex + 2])
            if r > g * 3 && r > b * 3 { return "red" }
            if g > r * 3 && g > b * 3 { return "green" }
            if b > r * 3 && b > g * 3 { return "blue" }
            if r > b * 3 && g > b * 2 { return "yellow" }
            return "other(\(r),\(g),\(b))"
        }
    }

    private func expectedQuadrants(for orientation: Int) -> [String] {
        let maps: [[String]] = [
            ["red", "green", "blue", "yellow"],
            ["green", "red", "yellow", "blue"],
            ["yellow", "blue", "green", "red"],
            ["blue", "yellow", "red", "green"],
            ["red", "blue", "green", "yellow"],
            ["blue", "red", "yellow", "green"],
            ["yellow", "green", "blue", "red"],
            ["green", "yellow", "red", "blue"],
        ]
        return maps[orientation - 1]
    }
}

private extension Collection where Index == Int {
    subscript(safe range: Range<Int>) -> SubSequence? {
        guard range.lowerBound >= startIndex, range.upperBound <= endIndex else { return nil }
        return self[range]
    }
}
