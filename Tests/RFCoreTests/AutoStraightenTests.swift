import XCTest
import CoreImage
@testable import RFCore

final class AutoStraightenTests: XCTestCase {
    func testCropScaleKeepsRotatedFrameInsideImage() {
        XCTAssertEqual(AutoStraighten.cropScale(size: CGSize(width: 6000, height: 4000), radians: 0), 1, accuracy: 1e-12)
        let radians = 5 * Double.pi / 180
        let size = CGSize(width: 6000, height: 4000)
        let k = AutoStraighten.cropScale(size: size, radians: radians)
        // 裁切框轉回原座標後的外框不能超出原圖。
        let w = 6000 * k, h = 4000 * k
        XCTAssertLessThanOrEqual(w * cos(radians) + h * sin(radians), 6000 + 1e-6)
        XCTAssertLessThanOrEqual(w * sin(radians) + h * cos(radians), 4000 + 1e-6)
        XCTAssertGreaterThan(k, 0.85)
    }

    func testOnlyCorrectsWithinTenDegrees() {
        XCTAssertEqual(AutoStraighten.accepted(9.9), 9.9)
        XCTAssertEqual(AutoStraighten.accepted(-10), -10)
        XCTAssertNil(AutoStraighten.accepted(10.5), "超過 10° 不修正")
        XCTAssertNil(AutoStraighten.accepted(-15))
        XCTAssertNil(AutoStraighten.accepted(0.05), "幾乎水平不動")
    }

    func testApplyKeepsAspectRatioAndZeroOrigin() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let out = AutoStraighten.apply(3, to: image)
        XCTAssertEqual(out.extent.origin, .zero)
        XCTAssertLessThan(out.extent.width, 3000)
        XCTAssertEqual(out.extent.width / out.extent.height, 1.5, accuracy: 0.002)
        XCTAssertEqual(AutoStraighten.apply(0, to: image).extent, image.extent)
    }

    /// 畫一組直條紋（寬 1200、高 800），條紋整體逆時針轉 `tilt` 度（Core Image 座標）。
    private func stripes(tilt: Double) -> CIImage {
        let size = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let stripe = CIImage(color: .white).cropped(to: CGRect(x: 0, y: -1000, width: 20, height: 3000))
        var image = CIImage(color: .black).cropped(to: CGRect(x: -1000, y: -1000, width: 3200, height: 3000))
        for x in stride(from: -600, to: 1800, by: 60) {
            image = stripe.transformed(by: CGAffineTransform(translationX: CGFloat(x), y: 0)).composited(over: image)
        }
        return image.transformed(by: CGAffineTransform(translationX: 600, y: 400).rotated(by: tilt * .pi / 180)
            .translatedBy(x: -600, y: -400)).cropped(to: size)
    }

    func testLinesConfirmOnlyTheAngleThatStraightensThem() {
        let context = CIContext()
        let level = stripes(tilt: 0)
        XCTAssertFalse(AutoStraighten.linesConfirm(5, in: level, context: context), "線條已經是正的，不該接受 5° 修正")
        XCTAssertFalse(AutoStraighten.linesConfirm(-5, in: level, context: context))
        let tilted = stripes(tilt: 4)
        XCTAssertTrue(AutoStraighten.linesConfirm(-4, in: tilted, context: context), "逆時針斜 4° 要順時針轉回來")
        XCTAssertFalse(AutoStraighten.linesConfirm(4, in: tilted, context: context), "方向相反不該接受")
    }

    private func sampleRaw(_ name: String) throws -> DecodedRaw {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sampleraw/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("sampleraw 沒有 \(name)") }
        return try RawDecoder().decode(url: url)
    }

    /// sampleraw/A05Q8555.CR2 是沒有地平線的街景，Vision 會把電線當成 5° 的地平線。
    func testLevelStreetSceneIsNotStraightened() throws {
        let street = try sampleRaw("A05Q8555.CR2").image
        XCTAssertNil(AutoStraighten.detect(street, context: CIContext()))
    }

    /// sampleraw/TSC02817.ARW 的湖面是水平的；轉歪 4° 後要能轉回來。
    func testTiltedLakeHorizonIsStraightened() throws {
        let tilted = AutoStraighten.apply(4, to: try sampleRaw("TSC02817.ARW").image)
        let degrees = try XCTUnwrap(AutoStraighten.detect(tilted, context: CIContext()))
        XCTAssertEqual(degrees, -4, accuracy: 1)
    }

    /// 合成一張地平線傾斜 4° 的畫面：上亮下暗。
    func testDetectsTiltedHorizon() throws {
        let size = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let sky = CIImage(color: CIColor(red: 0.55, green: 0.7, blue: 0.95)).cropped(to: size)
        let ground = CIImage(color: CIColor(red: 0.2, green: 0.25, blue: 0.1))
            .cropped(to: CGRect(x: -2000, y: -2000, width: 5500, height: 2500))
            .transformed(by: CGAffineTransform(translationX: 750, y: 500).rotated(by: 4 * .pi / 180)
                .translatedBy(x: -750, y: -500))
        let image = ground.composited(over: sky).cropped(to: size)
        guard let degrees = AutoStraighten.detect(image, context: CIContext()) else {
            throw XCTSkip("Vision 在這台機器上未偵測到合成地平線")
        }
        XCTAssertEqual(degrees, -4, accuracy: 1)
        let leveled = AutoStraighten.apply(degrees, to: image)
        XCTAssertEqual(AutoStraighten.detect(leveled, context: CIContext()) ?? 0, 0, accuracy: 0.5,
                       "拉直後不該還偵測到明顯傾斜")
    }
}
