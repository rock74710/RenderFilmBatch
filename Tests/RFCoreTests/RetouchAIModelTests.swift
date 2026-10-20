import XCTest
import CoreImage
@testable import RFCore

final class RetouchAIModelTests: XCTestCase {
    func testVerticalTileBlendWeightsFadeAcrossBitmapOrderOverlap() {
        let lowerTile = RetouchAIModel.tileAxisBlendWeights(tileIndex: 0, tileCount: 2, reverseOrder: true)
        let upperTile = RetouchAIModel.tileAxisBlendWeights(tileIndex: 1, tileCount: 2, reverseOrder: true)

        for offset in 0..<32 {
            XCTAssertEqual(lowerTile[95 - offset] + upperTile[735 - offset], 1, accuracy: 0.0001,
                           "垂直相鄰區塊在 bitmap overlap 內應平滑互補")
        }
    }

    func testMissingModelReportsFailure() throws {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        XCTAssertThrowsError(try RetouchAIModel.fill(image: image, mask: image, context: CIContext(),
            modelAt: URL(fileURLWithPath: "/missing-retouch-model.mlmodelc")))
    }

    func testRealModelRemovesBlemishAndReturnsOriginalExtent() throws {
        guard let path = ProcessInfo.processInfo.environment["RENDERFILM_LAMA_TEST_MODEL"] else {
            throw XCTSkip("實際模型測試需 RENDERFILM_LAMA_TEST_MODEL")
        }
        let bounds = CGRect(x: 13, y: 17, width: 96, height: 64)
        let hole = CGRect(x: 51, y: 39, width: 20, height: 20)
        let background = CIImage(color: CIColor(red: 0.12, green: 0.5, blue: 0.7)).cropped(to: bounds)
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: hole)
            .composited(over: background)
        let mask = CIImage(color: .white).cropped(to: hole)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let result = try RetouchAIModel.fill(image: image, mask: mask, context: context,
            modelAt: URL(fileURLWithPath: path))
        XCTAssertEqual(result.extent, bounds)
        var pixel = [Float](repeating: 0, count: 4)
        context.render(result, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: hole.midX, y: hole.midY, width: 1, height: 1), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        XCTAssertTrue(pixel.allSatisfy(\.isFinite))
        XCTAssertLessThan(pixel[0], 0.65, "生成結果應清除洋紅污點")
        XCTAssertGreaterThan(pixel[1], 0.15, "生成結果應補回附近綠／藍背景")
    }

    func testRealModelTilesLongNonSquareMaskAtNonzeroOrigin() throws {
        guard let path = ProcessInfo.processInfo.environment["RENDERFILM_LAMA_TEST_MODEL"] else {
            throw XCTSkip("實際模型測試需 RENDERFILM_LAMA_TEST_MODEL")
        }
        let bounds = CGRect(x: 23, y: 41, width: 1_200, height: 240)
        let hole = CGRect(x: 143, y: 120, width: 1_000, height: 40)
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let background = CIImage(color: CIColor(red: 0.12, green: 0.5, blue: 0.7, colorSpace: colorSpace)!)
            .cropped(to: bounds)
        let object = CIImage(color: CIColor(red: 1, green: 0, blue: 1, colorSpace: colorSpace)!)
            .cropped(to: hole)
        let image = object.composited(over: background)
        let mask = CIImage(color: .white).cropped(to: hole)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        let result = try RetouchAIModel.fill(image: image, mask: mask, context: context,
            modelAt: URL(fileURLWithPath: path))

        XCTAssertEqual(result.extent, bounds)
        for x in [500, 815, 1_050] {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(result, toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: x, y: 137, width: 1, height: 1), format: .RGBAf,
                colorSpace: colorSpace)
            XCTAssertTrue(pixel.allSatisfy(\.isFinite), "每個區塊都應回傳有效像素")
        }
    }

    func testRealModelTilesLongVerticalNonSquareMaskAtNonzeroOrigin() throws {
        guard let path = ProcessInfo.processInfo.environment["RENDERFILM_LAMA_TEST_MODEL"] else {
            throw XCTSkip("實際模型測試需 RENDERFILM_LAMA_TEST_MODEL")
        }
        let bounds = CGRect(x: 37, y: 29, width: 240, height: 1_200)
        let hole = CGRect(x: 120, y: 130, width: 40, height: 1_000)
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let background = CIImage(color: CIColor(red: 0.12, green: 0.5, blue: 0.7, colorSpace: colorSpace)!)
            .cropped(to: bounds)
        let object = CIImage(color: CIColor(red: 1, green: 0, blue: 1, colorSpace: colorSpace)!)
            .cropped(to: hole)
        let image = object.composited(over: background)
        let mask = CIImage(color: .white).cropped(to: hole)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        let result = try RetouchAIModel.fill(image: image, mask: mask, context: context,
            modelAt: URL(fileURLWithPath: path))

        XCTAssertEqual(result.extent, bounds)
        for y in [500, 786, 1_050] {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(result, toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: 140, y: y, width: 1, height: 1), format: .RGBAf,
                colorSpace: colorSpace)
            XCTAssertTrue(pixel.allSatisfy(\.isFinite), "垂直區塊交界與遮罩內應回傳有效像素")
        }
    }
}
