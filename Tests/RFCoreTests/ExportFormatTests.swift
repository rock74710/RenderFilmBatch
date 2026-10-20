import XCTest
import CoreImage
import ImageIO
@testable import RFCore

final class ExportFormatTests: XCTestCase {
    private func makeImage(gpu: GPUContext) -> CIImage {
        let width = 24
        let height = 16
        let color = CIColor(red: 0.65, green: 0.4, blue: 0.2, alpha: 1)
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func testFormatContractMatchesContainerTypes() {
        XCTAssertEqual(Exporter.Format.heic.fileExtension, "heic")
        XCTAssertEqual(Exporter.Format.jpeg.fileExtension, "jpg")
        XCTAssertEqual(Exporter.Format.tiff.fileExtension, "tiff")
        XCTAssertEqual(Exporter.Format.tiff16.fileExtension, "tiff")
        XCTAssertEqual(Exporter.Format.tiffFloat.fileExtension, "tiff")
        XCTAssertEqual(Exporter.Format.sceneLinearTIFF.fileExtension, "tiff")
        XCTAssertEqual(Exporter.Format.png.fileExtension, "png")
        XCTAssertEqual(Exporter.Format.jpegHDR.fileExtension, "jpg")
        XCTAssertEqual(Exporter.Format.allCases.map(\.utType),
                       [.heic, .jpeg, .jpeg, .tiff, .tiff, .tiff, .tiff, .png])
    }

    func testBasicSDRFormatsWriteReadableFilesWithExpectedTypeAndColorSpace() throws {
        let gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        let exporter = Exporter(gpu: gpu)
        let image = makeImage(gpu: gpu)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let targets: [(RenderingTarget, String)] = [
            (.preset(.webSDR), "srgb"),
            (.preset(.appleSDR), "p3")
        ]
        for format in [Exporter.Format.heic, .jpeg, .tiff, .png] {
            for (target, expectedProfile) in targets {
                let url = directory.appendingPathComponent(
                    "output-\(expectedProfile).\(format.fileExtension)"
                )
                try exporter.write(image: image, to: url, target: target, format: format)

                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, format.utType.identifier)
                let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(cgImage.width, 24)
                XCTAssertEqual(cgImage.height, 16)
                XCTAssertEqual(cgImage.bitsPerComponent, 8)
                let colorSpaceName = (cgImage.colorSpace?.name as String?)?.lowercased() ?? ""
                XCTAssertTrue(
                    colorSpaceName.contains(expectedProfile),
                    "\(format) 應保留 \(expectedProfile)，實際為 \(colorSpaceName)"
                )
            }
        }
    }

    func testBasicFormatsRejectHDRTargetsInsteadOfSilentlyFlattening() throws {
        let gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        let exporter = Exporter(gpu: gpu)
        let image = makeImage(gpu: gpu)

        for format in [Exporter.Format.jpeg, .tiff, .png] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rf-hdr-reject-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(
                try exporter.write(image: image, to: url,
                                   target: .preset(.hdrStandard), format: format)
            )
        }
    }

    func testHDRAndArchiveFormatsExposeExplicitCapabilities() {
        XCTAssertTrue(Exporter.Format.heic.supportsHDR)
        XCTAssertTrue(Exporter.Format.jpegHDR.supportsHDR)
        XCTAssertTrue(Exporter.Format.tiff16.supportsHDR)
        XCTAssertTrue(Exporter.Format.tiffFloat.supportsHDR)
        XCTAssertTrue(Exporter.Format.sceneLinearTIFF.isSceneLinear)
        XCTAssertEqual(Exporter.Format.tiff16.fixedBitsPerComponent, 16)
        XCTAssertEqual(Exporter.Format.tiffFloat.fixedBitsPerComponent, 32)
        XCTAssertEqual(Exporter.Format.sceneLinearTIFF.fixedBitsPerComponent, 32)
    }

    func testArchiveFormatsRejectMismatchedTransferFunctions() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = Exporter(gpu: gpu)
        let image = makeImage(gpu: gpu)
        let directory = FileManager.default.temporaryDirectory

        XCTAssertThrowsError(try exporter.write(
            image: image, to: directory.appendingPathComponent("float-pq.tiff"),
            target: .preset(.hdrStandard), format: .tiffFloat
        ))
        XCTAssertThrowsError(try exporter.write(
            image: image, to: directory.appendingPathComponent("integer-linear.tiff"),
            target: .preset(.archive), format: .tiff16
        ))
        XCTAssertThrowsError(try exporter.write(
            image: image, to: directory.appendingPathComponent("heic-linear.heic"),
            target: .preset(.archive), format: .heic
        ))
    }
}
