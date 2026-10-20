import XCTest
import CoreImage
@testable import RFCore

final class GeometryTests: XCTestCase {
    private let size = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private lazy var gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: size)

    /// 四角像素的 alpha 都要是 1（沒有透明或黑邊）。
    private func assertOpaqueCorners(_ image: CIImage, file: StaticString = #filePath, line: UInt = #line) {
        let context = CIContext()
        let e = image.extent
        for p in [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX - 1, y: e.minY),
                  CGPoint(x: e.minX, y: e.maxY - 1), CGPoint(x: e.maxX - 1, y: e.maxY - 1)] {
            var px = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: p, size: CGSize(width: 1, height: 1)),
                           format: .RGBAf, colorSpace: nil)
            XCTAssertEqual(px[3], 1, accuracy: 1e-3, "角落 \(p) 透明", file: file, line: line)
            XCTAssertGreaterThan(px[0], 0.1, "角落 \(p) 是黑邊", file: file, line: line)
        }
    }

    // AC-1
    func testDefaultIsUnchanged() {
        let out = GeometryParameters().apply(to: gray)
        XCTAssertTrue(out === gray || out.extent == gray.extent)
        XCTAssertEqual(out.extent, gray.extent)
    }

    // AC-2
    func testStraightenCropsWithoutBlackEdges() {
        var g = GeometryParameters()
        g.straighten = 5
        let out = g.apply(to: gray)
        XCTAssertEqual(out.extent.origin, .zero)
        XCTAssertLessThan(out.extent.width, 1200)
        XCTAssertEqual(out.extent.width / out.extent.height, 1.5, accuracy: 0.01)
        assertOpaqueCorners(out)
    }

    // AC-3
    func testPerspectiveCropsWithoutBlackEdges() {
        for (v, h) in [(60.0, 0.0), (-60, 0), (0, 60), (0, -60), (40, -30)] {
            var g = GeometryParameters()
            g.verticalPerspective = v
            g.horizontalPerspective = h
            let out = g.apply(to: gray)
            XCTAssertEqual(out.extent.origin, .zero)
            XCTAssertLessThan(out.extent.width, 1200)
            assertOpaqueCorners(out)
        }
    }

    /// 垂直透視為正時，上窄下寬的梯形要被拉成上下等寬：原本頂端偏內的點往外移。
    func testVerticalPerspectiveWidensTop() {
        var g = GeometryParameters()
        g.verticalPerspective = 50
        let q = g.quad(for: size)
        XCTAssertGreaterThan(q.topRight.x - q.topLeft.x, q.bottomRight.x - q.bottomLeft.x)
    }

    // AC-4
    func testCropAspect() {
        var g = GeometryParameters()
        g.cropAspect = .square
        let square = g.apply(to: gray)
        XCTAssertEqual(square.extent.width, square.extent.height, accuracy: 1)
        XCTAssertEqual(square.extent.height, 800, accuracy: 4)
        g.cropAspect = .threeTwo
        g.straighten = 3
        let wide = g.apply(to: gray)
        XCTAssertEqual(wide.extent.width / wide.extent.height, 1.5, accuracy: 1.0 / wide.extent.height + 0.005)
        g.cropAspect = .nineSixteen
        let tall = g.apply(to: gray)
        XCTAssertLessThan(tall.extent.width, tall.extent.height)
        assertOpaqueCorners(tall)
    }

    // AC-5
    func testLegacyOpticalDecodesWithDefaultGeometry() throws {
        let legacy = Data(#"{"enabled":false}"#.utf8)
        let optical = try JSONDecoder().decode(OpticalParameters.self, from: legacy)
        XCTAssertFalse(optical.enabled)
        XCTAssertEqual(optical.geometry, GeometryParameters())
        var changed = OpticalParameters()
        changed.geometry.straighten = 2
        changed.geometry.cropAspect = .fourFive
        let round = try JSONDecoder().decode(OpticalParameters.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(round, changed)
    }

    // AC-7
    func testDisabledKeepsValuesAndSkipsGeometry() {
        var g = GeometryParameters()
        g.straighten = 5
        g.cropAspect = .square
        g.enabled = false
        XCTAssertEqual(g.apply(to: gray).extent, gray.extent)
        g.enabled = true
        XCTAssertNotEqual(g.apply(to: gray).extent, gray.extent)
    }
}
