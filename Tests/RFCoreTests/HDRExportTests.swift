import XCTest
import CoreImage
import ImageIO
@testable import RFCore

/// A-023 HDR 輸出里程碑：勾選時走 10-bit PQ HEIC，未勾選維持 8-bit SDR。
final class HDRExportTests: XCTestCase {
    private func makeImage(_ value: CGFloat = 0.5) -> CIImage {
        let width = 24
        let height = 16
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = Float(value)
            pixels[index + 1] = Float(value * 0.8)
            pixels[index + 2] = Float(value * 0.6)
            pixels[index + 3] = 1
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
    }


    // MARK: - 色彩空間對應

    func testColorSpaceUsesPQAndHLGWhenTransferFunctionIsHDR() {
        let pq = RenderingTarget.preset(.hdrStandard)
        XCTAssertEqual(RenderPipeline.colorSpace(for: pq).name,
                       CGColorSpace.itur_2100_PQ)

        let hlg = RenderingTarget.preset(.appleHDR)
        XCTAssertEqual(RenderPipeline.colorSpace(for: hlg).name,
                       CGColorSpace.itur_2100_HLG)
    }

    func testColorSpaceKeepsGamutMappingForSDRTargets() {
        XCTAssertEqual(RenderPipeline.colorSpace(for: .preset(.webSDR)).name,
                       CGColorSpace.sRGB)
        XCTAssertEqual(RenderPipeline.colorSpace(for: .preset(.appleSDR)).name,
                       CGColorSpace.displayP3)
    }

    // MARK: - 輸出分流

    private func makeImage(gpu: GPUContext) -> CIImage {
        let size = 32
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0.6
            pixels[i + 1] = 0.5
            pixels[i + 2] = 0.4
            pixels[i + 3] = 1
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: size, height: size),
                       format: .RGBAf,
                       colorSpace: gpu.workingColorSpace)
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return props
    }

    func testHDRTargetWritesTenBitPQFile() throws {
        let gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        let exporter = Exporter(gpu: gpu)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-hdr-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }

        try exporter.write(image: makeImage(gpu: gpu), to: url,
                           target: .preset(.hdrStandard))

        let props = try properties(of: url)
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 10)
        let profile = props[kCGImagePropertyProfileName] as? String ?? ""
        XCTAssertTrue(profile.contains("2100") || profile.contains("PQ"),
                      "色彩描述檔應為 Rec.2100 PQ，實際為 \(profile)")
    }

    func testHEICWritesTenBitHLGFile() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = Exporter(gpu: gpu)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-hlg-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }

        try exporter.write(image: makeImage(), to: url,
                           target: .preset(.broadcastHDR), format: .heic)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 10)
        let profile = (image.colorSpace?.name as String?)?.lowercased() ?? ""
        XCTAssertTrue(profile.contains("2100") || profile.contains("hlg"), profile)
    }

    @available(macOS 15.0, *)
    func testJPEGHDRContainsGainMapAuxiliaryImage() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = Exporter(gpu: gpu)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-gain-map-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        try exporter.write(image: makeImage(0.45), to: url,
                           target: .preset(.hdrStandard), format: .jpegHDR,
                           hdrImage: makeImage(2.0))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let hdrGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
        )
        let isoGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeISOGainMap
        )
        XCTAssertTrue(hdrGainMap != nil || isoGainMap != nil)
    }

    func testHDRTIFFAndFloatTIFFPreserveBitDepthAndHeadroom() throws {
        let gpu = try XCTUnwrap(GPUContext.shared)
        let exporter = Exporter(gpu: gpu)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-tiff-hdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for transfer in [RenderingTarget.TransferFunction.pq, .hlg] {
            let target = RenderingTarget(dynamicRange: .fullHDR, gamut: .rec2020,
                                         transferFunction: transfer, intent: .archive,
                                         contentPeakNits: 1000)
            let url = directory.appendingPathComponent("\(transfer.rawValue)-16.tiff")
            try exporter.write(image: makeImage(), to: url, target: target, format: .tiff16)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.bitsPerComponent, 16)
        }

        let floatURL = directory.appendingPathComponent("linear-float.tiff")
        try exporter.write(image: makeImage(2.0), to: floatURL,
                           target: .preset(.archive), format: .tiffFloat)
        let loaded = try XCTUnwrap(CIImage(contentsOf: floatURL))
        var pixel = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(loaded, toBitmap: &pixel, rowBytes: 16,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBAf,
                             colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        XCTAssertGreaterThan(pixel[0], 1.0)

        let masterURL = directory.appendingPathComponent("scene-linear-master.tiff")
        try exporter.write(image: makeImage(2.0), to: masterURL,
                           target: .preset(.archive), format: .sceneLinearTIFF)
        let master = try XCTUnwrap(CIImage(contentsOf: masterURL))
        pixel = [Float](repeating: 0, count: 4)
        gpu.ciContext.render(master, toBitmap: &pixel, rowBytes: 16,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBAf,
                             colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        XCTAssertGreaterThan(pixel[0], 1.0)
    }

    func testSDRTargetStillWritesEightBitFile() throws {
        let gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        let exporter = Exporter(gpu: gpu)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-sdr-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }

        try exporter.write(image: makeImage(gpu: gpu), to: url,
                           target: .preset(.appleSDR))

        let props = try properties(of: url)
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 8)
    }

    // MARK: - A-054 HDR 亮度參數

    func testHDRExportTargetCarriesUserLuminance() {
        let pq = RenderingTarget.hdrExport(transfer: .pq, referenceWhiteNits: 100, contentPeakNits: 1600)
        XCTAssertEqual(pq.transferFunction, .pq)
        XCTAssertEqual(pq.gamut, .rec2020)
        XCTAssertEqual(pq.intent, .hdrStandard)
        XCTAssertEqual(pq.referenceWhiteNits, 100)
        XCTAssertEqual(pq.contentPeakNits, 1600)
        XCTAssertEqual(pq.contentHeadroom, 16, accuracy: 1e-9)

        let hlg = RenderingTarget.hdrExport(transfer: .hlg, referenceWhiteNits: 203, contentPeakNits: 1000)
        XCTAssertEqual(hlg, RenderingTarget.preset(.broadcastHDR))
        XCTAssertEqual(RenderingTarget.hdrExport(transfer: .pq, referenceWhiteNits: 203, contentPeakNits: 1000),
                       RenderingTarget.preset(.hdrStandard))
    }

    func testHDRExportTargetKeepsPeakAtOrAboveReferenceWhite() {
        let t = RenderingTarget.hdrExport(transfer: .pq, referenceWhiteNits: 400, contentPeakNits: 300)
        XCTAssertEqual(t.contentPeakNits, 400)
        XCTAssertEqual(t.contentHeadroom, 1, accuracy: 1e-9)
    }

    func testJPEGHDRAuxiliaryTargetKeepsUserLuminance() {
        let pq = RenderingTarget.hdrExport(transfer: .pq, referenceWhiteNits: 100, contentPeakNits: 1600)
        let aux = Exporter.jpegHDRAuxiliaryTarget(for: pq)
        XCTAssertEqual(aux.transferFunction, .linear)
        XCTAssertEqual(aux.gamut, .rec2020)
        XCTAssertEqual(aux.referenceWhiteNits, 100)
        XCTAssertEqual(aux.contentPeakNits, 1600)

        // 沒勾 HDR 輸出時維持原本的存檔設定。
        XCTAssertEqual(Exporter.jpegHDRAuxiliaryTarget(for: .preset(.appleSDR)), .preset(.archive))
        let linear = RenderingTarget.preset(.archive)
        XCTAssertEqual(Exporter.jpegHDRAuxiliaryTarget(for: linear), linear)
    }
}
