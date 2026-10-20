import CoreImage
import Foundation
import RFCore
import XCTest

final class ExporterResizeTests: XCTestCase {
    func testLongEdgeAndPercentUseSharedHighQualityResizePath() throws {
        let exporter = Exporter(gpu: try GPUContext())
        let image = CIImage(color: .red).cropped(to: CGRect(x: 17, y: -9, width: 6_000, height: 4_000))

        let longEdge = try exporter.resize(
            image, to: Exporter.Resize(mode: .longEdge, value: 2_048)
        )
        XCTAssertEqual(longEdge.extent.integral, CGRect(x: 0, y: 0, width: 2_048, height: 1_365))

        let percent = try exporter.resize(
            image, to: Exporter.Resize(mode: .percent, value: 50)
        )
        XCTAssertEqual(percent.extent.integral, CGRect(x: 0, y: 0, width: 3_000, height: 2_000))
    }

    func testDontEnlargePreservesSmallerDimensionsAndOutputIsClamped() throws {
        let exporter = Exporter(gpu: try GPUContext())
        let small = CIImage(color: .blue).cropped(to: CGRect(x: 5, y: 8, width: 320, height: 200))
        let unchanged = try exporter.resize(
            small, to: Exporter.Resize(mode: .longEdge, value: 640, dontEnlarge: true)
        )
        XCTAssertEqual(unchanged.extent.integral, CGRect(x: 0, y: 0, width: 320, height: 200))

        let enlarged = try exporter.resize(
            small, to: Exporter.Resize(mode: .longEdge, value: 640, dontEnlarge: false)
        )
        XCTAssertEqual(enlarged.extent.integral, CGRect(x: 0, y: 0, width: 640, height: 400))

        let larger = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 1_000, height: 500))
        let clamped = try exporter.resize(
            larger, to: Exporter.Resize(mode: .percent, value: 10_000)
        )
        XCTAssertEqual(clamped.extent.integral, CGRect(x: 0, y: 0, width: 65_535, height: 32_768))

        let minimum = try exporter.resize(
            small, to: Exporter.Resize(mode: .percent, value: 0.01)
        )
        XCTAssertEqual(minimum.extent.integral, CGRect(x: 0, y: 0, width: 2, height: 1))
    }

    func testResizeHelperRejectsInvalidTypedValues() throws {
        let exporter = Exporter(gpu: try GPUContext())
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))

        XCTAssertThrowsError(try exporter.resize(image, to: .init(mode: .longEdge, value: 1.5)))
        XCTAssertThrowsError(try exporter.resize(image, to: .init(mode: .longEdge, value: 65_536)))
        XCTAssertThrowsError(try exporter.resize(image, to: .init(mode: .percent, value: 0)))
        XCTAssertThrowsError(try exporter.resize(image, to: .init(mode: .percent, value: .infinity)))
    }

    @available(macOS 15.0, *)
    func testJPEGHDRResizeKeepsGainMapAtTheResizedDimensions() throws {
        let gpu = try GPUContext()
        let exporter = Exporter(gpu: gpu)
        let options = Exporter.Resize(mode: .longEdge, value: 48)
        let sdr = try exporter.resize(linearImage(value: 0.45), to: options)
        let hdr = try exporter.resize(linearImage(value: 2.0), to: options)
        XCTAssertEqual(sdr.extent.integral.size, CGSize(width: 48, height: 36))
        XCTAssertEqual(hdr.extent.integral.size, sdr.extent.integral.size)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rf-resize-hdr-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try exporter.write(image: sdr, to: url, target: .preset(.webSDR), format: .jpegHDR, hdrImage: hdr)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let hdrGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
        let isoGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        let gainMap = try XCTUnwrap(hdrGainMap ?? isoGainMap)
        let dataDescription = try XCTUnwrap(
            (gainMap as NSDictionary).object(forKey: kCGImageAuxiliaryDataInfoDataDescription) as? NSDictionary
        )
        XCTAssertEqual(dataDescription.object(forKey: kCGImagePropertyWidth) as? Int, 48)
        XCTAssertEqual(dataDescription.object(forKey: kCGImagePropertyHeight) as? Int, 36)
    }

    private func linearImage(value: Float) -> CIImage {
        let width = 32
        let height = 24
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = value
            pixels[index + 1] = value * 0.8
            pixels[index + 2] = value * 0.6
            pixels[index + 3] = 1
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
    }
}
