import Foundation
import XCTest
@testable import RFCore

final class CreativeLUTTests: XCTestCase {
    func testParsesCubeAndSamplesTrilinearly() throws {
        let lut = try CreativeLUT.parse("""
        # 反相
        TITLE "invert"
        LUT_3D_SIZE 2
        1 1 1
        0 1 1
        1 0 1
        0 0 1
        1 1 0
        0 1 0
        1 0 0
        0 0 0
        """)
        XCTAssertEqual(lut.size, 2)
        let out = lut.sample(SIMD3(0.25, 0.5, 1))
        XCTAssertEqual(out.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(out.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(out.z, 0, accuracy: 1e-6)
    }

    func testRejectsMalformedCube() {
        XCTAssertThrowsError(try CreativeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n"))
        XCTAssertThrowsError(try CreativeLUT.parse("0 0 0\n"))
    }

    func testEveryBuiltInLoads() throws {
        XCTAssertEqual(CreativeLUTLibrary.builtIns.count, 8)
        for item in CreativeLUTLibrary.builtIns {
            XCTAssertTrue(item.id.hasPrefix("builtin:"))
            XCTAssertNotNil(CreativeLUTLibrary.load(id: item.id), item.id)
        }
    }

    func testFilmParametersWithoutLUTKeepTheirJSON() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FilmParameters())) as? [String: Any]
        XCTAssertNil(plain?["lutID"])
        XCTAssertNil(plain?["lutAmount"])

        var film = FilmParameters()
        film.lutID = "builtin:warmSlide"
        film.lutAmount = 0.4
        let decoded = try JSONDecoder().decode(FilmParameters.self, from: JSONEncoder().encode(film))
        XCTAssertEqual(decoded.lutID, "builtin:warmSlide")
        XCTAssertEqual(decoded.lutAmount, 0.4)
    }

    func testTargetTransformAppliesLUTWithAmount() {
        let scene = SIMD3(0.18, 0.12, 0.08)
        let target = RenderingTarget.preset(.webSDR)
        func output(_ id: String?, amount: Double = 1) -> SIMD3<Double> {
            var film = FilmParameters()
            film.lutID = id
            film.lutAmount = amount
            return TargetTransform(target: target, tone: ToneMappingParameters(),
                                   gamut: GamutMappingParameters(), film: film).apply(scene)
        }
        let none = output(nil)
        let graded = output("builtin:highContrastMono")
        XCTAssertGreaterThan(abs(graded.x - none.x) + abs(graded.z - none.z), 0.02)
        XCTAssertEqual(graded.x, graded.z, accuracy: 0.01, "mono LUT output should be neutral")
        let zero = output("builtin:highContrastMono", amount: 0)
        XCTAssertEqual(zero, none)
        // INV-3: a missing file renders as if no LUT were selected.
        XCTAssertEqual(output("/nonexistent/missing.cube"), none)
    }
}
