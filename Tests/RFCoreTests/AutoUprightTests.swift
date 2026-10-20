import XCTest
import CoreImage
import CoreGraphics
@testable import RFCore

final class AutoUprightTests: XCTestCase {
    func testSyntheticBuildingConvergenceProducesBoundedPerspectiveCorrection() throws {
        let image = syntheticBuilding()
        let result = AutoUpright.analyze(image, context: CIContext())
        let correction = try XCTUnwrap(result.correction, result.message)
        XCTAssertLessThanOrEqual(abs(correction.rotation), GeometryParameters.straightenRange.upperBound)
        XCTAssertLessThanOrEqual(abs(correction.verticalPerspective), GeometryParameters.perspectiveRange.upperBound)
        XCTAssertGreaterThan(correction.verticalPerspective, 5,
                             "long building edges that converge should create a perspective correction")

        var geometry = GeometryParameters()
        geometry.uprightMode = .auto
        geometry.autoCorrection = correction
        let extent = image.extent
        let lines = [
            GeometryParameters.GuideLine(start: .init(x: 205.0 / 800, y: 35.0 / 600),
                                         end: .init(x: 305.0 / 800, y: 565.0 / 600)),
            GeometryParameters.GuideLine(start: .init(x: 695.0 / 800, y: 35.0 / 600),
                                         end: .init(x: 595.0 / 800, y: 565.0 / 600)),
        ]
        for line in lines {
            let start = try XCTUnwrap(geometry.outputPointIncludingOutside(
                forInput: .init(x: line.start.x, y: line.start.y), extent: extent))
            let end = try XCTUnwrap(geometry.outputPointIncludingOutside(
                forInput: .init(x: line.end.x, y: line.end.y), extent: extent))
            XCTAssertEqual(start.x, end.x, accuracy: 0.04,
                           "Auto 必須拉直建築邊緣，而不只是回傳非零參數")
        }
    }

    func testNoCredibleLineReturnsNoCorrection() {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 480, height: 320))
        let result = AutoUpright.analyze(image, context: CIContext())
        XCTAssertNil(result.correction)
        XCTAssertTrue(result.message.contains("維持原狀"))
    }

    private func syntheticBuilding() -> CIImage {
        let width = 800, height = 600
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.72, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.08, alpha: 1))
        context.setLineWidth(9)
        context.setLineCap(.butt)
        let left = CGMutablePath()
        left.move(to: CGPoint(x: 205, y: 35))
        left.addLine(to: CGPoint(x: 305, y: 565))
        let right = CGMutablePath()
        right.move(to: CGPoint(x: 595, y: 565))
        right.addLine(to: CGPoint(x: 695, y: 35))
        context.addPath(left)
        context.addPath(right)
        context.strokePath()
        return CIImage(cgImage: context.makeImage()!)
    }
}
