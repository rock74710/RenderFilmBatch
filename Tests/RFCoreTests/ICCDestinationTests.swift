import XCTest
import CoreGraphics
import CoreImage
import ImageIO
@testable import RFCore

final class ICCDestinationTests: XCTestCase {
    private let sRGBProfile = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf-icc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func cmykProfilePath() throws -> String {
        let data = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK)?.copyICCData() as Data?)
        let url = tempDir.appendingPathComponent("cmyk.icc")
        try data.write(to: url)
        return url.path
    }

    /// 1×1 的 Display P3 8-bit 影像。
    private func p3Pixel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    /// 把影像畫進同一個 P3 bitmap 讀回 0…255 的 RGB。
    private func p3Components(_ image: CGImage) throws -> [Int] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map(Int.init)
    }

    // MARK: - AC-1 sidecar 相容

    func testLegacyTargetDecodesWithoutDestinationAndEncodesNoKey() throws {
        let legacy = #"{"dynamicRange":"sdr","gamut":"displayP3","transferFunction":"sRGB","intent":"appleSDR","referenceWhiteNits":203,"contentPeakNits":203}"#
        let target = try JSONDecoder().decode(RenderingTarget.self, from: Data(legacy.utf8))
        XCTAssertNil(target.iccDestination)
        let json = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        XCTAssertFalse(json.contains("iccDestination"))
    }

    func testDestinationRoundTripsThroughTarget() throws {
        var target = RenderingTarget.preset(.appleSDR)
        target.iccDestination = ICCDestination(profilePath: sRGBProfile, renderingIntent: .relativeColorimetric)
        let decoded = try JSONDecoder().decode(RenderingTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded.iccDestination, target.iccDestination)
    }

    // MARK: - AC-3 soft proof

    func testSoftProofDesaturatesOutOfGamutRedAndKeepsGray() throws {
        let destination = ICCDestination(profilePath: sRGBProfile, renderingIntent: .relativeColorimetric)
        let display = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))

        let red = try p3Components(destination.proof(p3Pixel(1, 0, 0), displaySpace: display))
        XCTAssertGreaterThan(red[1], 25, "P3 紅超出 sRGB，經過 sRGB 描述檔後綠色分量應該上升")

        let gray = try p3Components(destination.proof(p3Pixel(0.5, 0.5, 0.5), displaySpace: display))
        let original = try p3Components(p3Pixel(0.5, 0.5, 0.5))
        for (a, b) in zip(gray, original) { XCTAssertLessThanOrEqual(abs(a - b), 2) }
    }

    func testGamutWarningMarksP3RedButNotNeutralGray() throws {
        let display = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        for intent in ICCDestination.RenderingIntent.allCases {
            let destination = ICCDestination(profilePath: sRGBProfile, renderingIntent: intent)
            let red = try destination.gamutWarningOverlay(p3Pixel(1, 0, 0), displaySpace: display)
            let gray = try destination.gamutWarningOverlay(p3Pixel(0.5, 0.5, 0.5), displaySpace: display)
            XCTAssertGreaterThan(try alpha(red), 0)
            XCTAssertEqual(try alpha(gray), 0)
        }
    }

    func testPaperWhiteUsesICCWhitePointAndOffKeepsOriginalProof() throws {
        var profile = try Data(contentsOf: URL(fileURLWithPath: sRGBProfile))
        let count = Int(profile[128..<132].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let whiteTag = (0..<count).first { index in
            Array(profile[(132 + index * 12)..<(136 + index * 12)]) == Array("wtpt".utf8)
        }
        let tag = try XCTUnwrap(whiteTag)
        let offset = Int(profile[(136 + tag * 12)..<(140 + tag * 12)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        // 測試專用的偏暖暗紙白，ICC XYZ 使用 signed 16.16 fixed point。
        for (channel, value) in [0.76, 0.78, 0.64].enumerated() {
            let fixed = UInt32((value * 65536).rounded())
            for byte in 0..<4 {
                profile[offset + 8 + channel * 4 + byte] = UInt8((fixed >> (24 - byte * 8)) & 0xff)
            }
        }
        let path = tempDir.appendingPathComponent("paper-white.icc")
        try profile.write(to: path)
        let destination = ICCDestination(profilePath: path.path)
        let display = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let white = try p3Pixel(1, 1, 1)
        let off = try p3Components(destination.proof(white, displaySpace: display, simulatePaperWhite: false))
        let on = try p3Components(destination.proof(white, displaySpace: display, simulatePaperWhite: true))
        XCTAssertEqual(off, [255, 255, 255])
        // 0.76/0.78/0.64 的紙白約為偏暖的 P3 (231, 228, 228)，且比螢幕白暗。
        for (actual, expected) in zip(on, [231, 228, 228]) {
            XCTAssertLessThanOrEqual(abs(actual - expected), 3)
        }
        XCTAssertLessThan(on[1], off[1])
        XCTAssertLessThan(on[2], on[0])
    }

    func testPaperWhiteRejectsProfileWithoutMediaWhiteTag() throws {
        var profile = try Data(contentsOf: URL(fileURLWithPath: sRGBProfile))
        let count = Int(profile[128..<132].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let tag = try XCTUnwrap((0..<count).first { index in
            profile[(132 + index * 12)..<(136 + index * 12)].elementsEqual("wtpt".utf8)
        })
        profile.replaceSubrange((132 + tag * 12)..<(136 + tag * 12), with: "xxxx".utf8)
        let path = tempDir.appendingPathComponent("no-paper-white.icc")
        try profile.write(to: path)
        let destination = ICCDestination(profilePath: path.path)
        let display = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        XCTAssertThrowsError(try destination.proof(p3Pixel(1, 1, 1), displaySpace: display,
                                                   simulatePaperWhite: true)) { error in
            guard case ICCDestinationError.missingMediaWhitePoint = error else {
                XCTFail("應明確指出缺少媒材白點，而非轉換失敗：\(error)")
                return
            }
        }
    }

    private func alpha(_ image: CGImage) throws -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes[3]
    }

    func testConvertProducesImageInDestinationSpace() throws {
        let rgb = try ICCDestination(profilePath: sRGBProfile).convert(p3Pixel(1, 0, 0))
        XCTAssertEqual(rgb.colorSpace?.model, .rgb)
        let cmyk = try ICCDestination(profilePath: cmykProfilePath()).convert(p3Pixel(1, 0, 0))
        XCTAssertEqual(cmyk.colorSpace?.model, .cmyk)
        XCTAssertEqual(cmyk.colorSpace?.numberOfComponents, 4)
    }

    // MARK: - AC-4 錯誤

    func testMissingProfileThrows() {
        let destination = ICCDestination(profilePath: tempDir.appendingPathComponent("nope.icc").path)
        XCTAssertThrowsError(try destination.loadColorSpace())
    }

    // MARK: - AC-2 / AC-4 輸出

    private func exportImage() -> CIImage {
        CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 6))
    }

    func testExportEmbedsRGBDestinationProfile() throws {
        let gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        let exporter = Exporter(gpu: gpu)
        var target = RenderingTarget.preset(.appleSDR)
        target.iccDestination = ICCDestination(profilePath: sRGBProfile)
        for format in [Exporter.Format.jpeg, .tiff, .tiff16, .png, .heic] {
            let url = tempDir.appendingPathComponent("rgb-\(format.rawValue).\(format.fileExtension)")
            try exporter.write(image: exportImage(), to: url, target: target, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let name = (image.colorSpace?.name as String?)?.lowercased() ?? ""
            XCTAssertTrue(name.contains("srgb"), "\(format) 應嵌入 sRGB 描述檔，實際為 \(name)")
            XCTAssertEqual(image.bitsPerComponent, format == .tiff16 ? 16 : 8, "\(format)")
        }
    }

    func testExportWritesCMYKForPrintFormatsAndRejectsOthers() throws {
        let gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        let exporter = Exporter(gpu: gpu)
        var target = RenderingTarget.preset(.appleSDR)
        target.iccDestination = ICCDestination(profilePath: try cmykProfilePath())
        for format in [Exporter.Format.jpeg, .tiff, .tiff16] {
            let url = tempDir.appendingPathComponent("cmyk-\(format.rawValue).\(format.fileExtension)")
            try exporter.write(image: exportImage(), to: url, target: target, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.colorSpace?.model, .cmyk, "\(format)")
            XCTAssertEqual(image.bitsPerComponent, format == .tiff16 ? 16 : 8, "\(format)")
        }
        for format in [Exporter.Format.png, .heic] {
            let url = tempDir.appendingPathComponent("cmyk-reject.\(format.fileExtension)")
            XCTAssertThrowsError(try exporter.write(image: exportImage(), to: url, target: target, format: format))
        }
    }

    func testMissingProfileFailsExportInsteadOfFallingBack() throws {
        let gpu = try XCTUnwrap(GPUContext.shared, "此測試需要 Metal 裝置")
        var target = RenderingTarget.preset(.appleSDR)
        target.iccDestination = ICCDestination(profilePath: tempDir.appendingPathComponent("gone.icc").path)
        let url = tempDir.appendingPathComponent("gone.jpg")
        XCTAssertThrowsError(try Exporter(gpu: gpu).write(image: exportImage(), to: url, target: target, format: .jpeg))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
