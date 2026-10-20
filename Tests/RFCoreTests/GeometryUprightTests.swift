import XCTest
import CoreImage
@testable import RFCore

final class GeometryUprightTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testGuidedLinesUseOneStableMappingForPreviewCoordinates() throws {
        var geometry = GeometryParameters()
        geometry.uprightMode = .guided
        geometry.guideLines = [
            .init(start: .init(x: 0.20, y: 0.05), end: .init(x: 0.25, y: 0.95)),
            .init(start: .init(x: 0.80, y: 0.05), end: .init(x: 0.75, y: 0.95)),
        ]

        for line in geometry.guideLines {
            let start = try XCTUnwrap(geometry.outputPointIncludingOutside(
                forInput: .init(x: line.start.x, y: line.start.y), extent: extent))
            let end = try XCTUnwrap(geometry.outputPointIncludingOutside(
                forInput: .init(x: line.end.x, y: line.end.y), extent: extent))
            XCTAssertEqual(start.x, end.x, accuracy: 0.015, "guided lines should be vertical in the rendered preview")
            let source = MaskPoint(x: 0.5, y: 0.5)
            let visible = try XCTUnwrap(geometry.outputPoint(forInput: source, extent: extent))
            let roundTrip = try XCTUnwrap(geometry.inputPoint(forOutput: visible, extent: extent))
            XCTAssertEqual(roundTrip.x, source.x, accuracy: 0.002)
            XCTAssertEqual(roundTrip.y, source.y, accuracy: 0.002)
        }
    }

    func testUserCropAppliesEvenWhenTransformIsDisabled() {
        var geometry = GeometryParameters()
        geometry.enabled = false
        geometry.straighten = 5
        geometry.cropAspectSelection = .fourFive
        geometry.cropRect = .init(x: 0.2, y: 0.1, width: 0.4, height: 0.75)

        let output = geometry.apply(to: CIImage(color: .gray).cropped(to: extent))
        XCTAssertEqual(output.extent.origin, .zero)
        XCTAssertEqual(output.extent.width / output.extent.height, 0.8, accuracy: 0.01)
        XCTAssertEqual(output.extent.width, 480, accuracy: 2)
        XCTAssertEqual(output.extent.height, 600, accuracy: 2)
    }

    func testCropEditingPreviewIgnoresSavedLegacyCropButKeepsFullFrameMapping() throws {
        var geometry = GeometryParameters()
        geometry.cropAspect = .square
        let image = CIImage(color: .gray).cropped(to: extent)
        let committed = geometry.apply(to: image)
        let editing = geometry.apply(to: image, includeUserCrop: false)
        XCTAssertEqual(committed.extent.width / committed.extent.height, 1, accuracy: 0.002)
        XCTAssertEqual(editing.extent.width / editing.extent.height, 1.5, accuracy: 0.005)
        XCTAssertGreaterThan(editing.extent.width, 1190,
                             "裁切編輯應顯示完整原始比例，而不是已裁成正方形的輸出")
        let point = try XCTUnwrap(geometry.outputPointIncludingOutside(
            forInput: .init(x: 0.9, y: 0.5), extent: extent, includeUserCrop: false))
        XCTAssertEqual(point.x, 0.9, accuracy: 0.002)
    }

    func testTransformedCropKeepsRatioAndNormalizedLandmarksAcrossProxyAndFullSize() throws {
        var geometry = GeometryParameters()
        geometry.uprightMode = .auto
        geometry.autoCorrection = .init(rotation: 3.5, verticalPerspective: 34)
        geometry.cropAspectSelection = .threeTwo
        let fullInput = CIImage(color: .gray).cropped(to: CGRect(x: 37, y: 91, width: 1200, height: 800))
        let proxyInput = fullInput.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let fullOutput = geometry.apply(to: fullInput)
        let proxyOutput = geometry.apply(to: proxyInput)

        XCTAssertEqual(fullOutput.extent.origin, .zero)
        XCTAssertEqual(proxyOutput.extent.origin, .zero)
        XCTAssertEqual(fullOutput.extent.width / fullOutput.extent.height, 1.5, accuracy: 0.01)
        XCTAssertEqual(proxyOutput.extent.width / proxyOutput.extent.height, 1.5, accuracy: 0.01)
        let fullPoint = try XCTUnwrap(geometry.outputPoint(
            forInput: .init(x: 0.5, y: 0.5), extent: fullInput.extent))
        let proxyPoint = try XCTUnwrap(geometry.outputPoint(
            forInput: .init(x: 0.5, y: 0.5), extent: proxyInput.extent))
        XCTAssertEqual(fullPoint.x, proxyPoint.x, accuracy: 0.003)
        XCTAssertEqual(fullPoint.y, proxyPoint.y, accuracy: 0.003)
    }

    func testLegacyDisabledCropStillSkipsAllGeometry() throws {
        let legacy = Data(#"{"enabled":false,"straighten":5,"cropAspect":"square"}"#.utf8)
        let geometry = try JSONDecoder().decode(GeometryParameters.self, from: legacy)
        XCTAssertFalse(geometry.enabled)
        XCTAssertNil(geometry.cropAspectSelection)
        XCTAssertNil(geometry.cropRect)
        XCTAssertEqual(geometry.apply(to: CIImage(color: .gray).cropped(to: extent)).extent, extent)
    }

    func testGuidesAndCropRoundTripThroughSidecarEncoding() throws {
        var geometry = GeometryParameters()
        geometry.uprightMode = .guided
        geometry.guideLines = [
            .init(start: .init(x: 0.2, y: 0.1), end: .init(x: 0.25, y: 0.9)),
            .init(start: .init(x: 0.8, y: 0.1), end: .init(x: 0.75, y: 0.9)),
        ]
        geometry.cropAspectSelection = .free
        geometry.cropRect = .init(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        geometry.constrainCrop = false

        let encoded = try JSONEncoder().encode(geometry)
        XCTAssertEqual(try JSONDecoder().decode(GeometryParameters.self, from: encoded), geometry)
    }

    func testInvalidOrNearlyCoincidentGuideLinesDoNotCreateAnUnstableTransform() {
        var geometry = GeometryParameters()
        geometry.uprightMode = .guided
        geometry.guideLines = [
            .init(start: .init(x: 0.5, y: 0.1), end: .init(x: 0.5, y: 0.9)),
            .init(start: .init(x: 0.51, y: 0.1), end: .init(x: 0.51, y: 0.9)),
        ]
        let image = CIImage(color: .gray).cropped(to: extent)
        XCTAssertEqual(geometry.apply(to: image).extent, image.extent)
        XCTAssertNil(geometry.outputPoint(forInput: .init(x: .nan, y: 0.5), extent: extent))
    }
}
