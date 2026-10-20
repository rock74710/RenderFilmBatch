import XCTest
@testable import RFCore

final class LensfunParserTests: XCTestCase {
    let xml = """
    <lensdatabase version="2">
      <lens>
        <maker>Canon</maker>
        <model>Canon EF 24-70mm f/2.8L II USM</model>
        <mount>Canon EF</mount>
        <cropfactor>1.0</cropfactor>
        <calibration>
          <distortion model="poly3" focal="24" k1="-0.02"/>
          <distortion model="poly3" focal="70" k1="0.006"/>
          <tca model="linear" focal="24" kr="0.99985" kb="1.00012"/>
          <vignetting model="pa" focal="24" aperture="2.8" distance="10" k1="-0.5" k2="0.1" k3="0.0"/>
          <vignetting model="pa" focal="24" aperture="8" distance="10" k1="-0.1" k2="0.02" k3="0.0"/>
        </calibration>
      </lens>
    </lensdatabase>
    """

    func testParsesLensAndCalibrations() {
        let db = LensfunDatabase()
        db.load(xml: Data(xml.utf8))
        XCTAssertEqual(db.lenses.count, 1)
        let lens = db.lenses[0]
        XCTAssertEqual(lens.maker, "Canon")
        XCTAssertEqual(lens.cropFactor, 1.0)
        XCTAssertEqual(lens.calibrations.filter { $0.distortion != nil }.count, 2)
        XCTAssertEqual(lens.calibrations.filter { $0.vignetting != nil }.count, 2)
    }

    /// 焦距在兩個校正點之間時應插值，且落在兩端之間。
    func testFocalInterpolation() {
        let db = LensfunDatabase()
        db.load(xml: Data(xml.utf8))
        let p = db.lenses[0].resolve(focal: 40, aperture: 2.8, distance: 10)
        XCTAssertEqual(p.distortion.kind, .poly3)
        XCTAssertGreaterThan(p.distortion.a, -0.02)
        XCTAssertLessThan(p.distortion.a, 0.006)
        XCTAssertEqual(p.tca.kind, .linear)
    }

    /// 暗角係數依光圈挑最接近的樣本：f/8 要拿到較弱的那組。
    func testVignettingPicksNearestAperture() {
        let db = LensfunDatabase()
        db.load(xml: Data(xml.utf8))
        let wide = db.lenses[0].resolve(focal: 24, aperture: 2.8, distance: 10)
        let stopped = db.lenses[0].resolve(focal: 24, aperture: 8, distance: 10)
        XCTAssertEqual(wide.vignetting.k1, -0.5, accuracy: 1e-9)
        XCTAssertEqual(stopped.vignetting.k1, -0.1, accuracy: 1e-9)
    }

    /// 名稱比對允許空白與大小寫差異，但差太多要判定為找不到。
    func testLensMatching() {
        let db = LensfunDatabase()
        db.load(xml: Data(xml.utf8))
        XCTAssertNotNil(db.findLens(name: "EF24-70mm f/2.8L II USM", maker: "Canon"))
        XCTAssertNil(db.findLens(name: "FE 85mm F1.4 GM", maker: "Sony"))
        XCTAssertNil(db.findLens(name: nil, maker: "Canon"))
    }
}

final class LensModelTests: XCTestCase {
    /// Lensfun poly3 的定義讓 r=1 成為固定點；桶狀畸變（k1 < 0）在中間半徑
    /// 要往更外圈取樣，中心則完全不動。
    func testBarrelDistortionDirection() {
        let d = DistortionModel(kind: .poly3, a: -0.02)
        XCTAssertEqual(d.sourceRadius(0), 0, accuracy: 1e-12)
        XCTAssertEqual(d.sourceRadius(1.0), 1.0, accuracy: 1e-12)
        XCTAssertGreaterThan(d.sourceRadius(0.5), 0.5)

        // 枕狀畸變（k1 > 0）方向相反。
        let pincushion = DistortionModel(kind: .poly3, a: 0.02)
        XCTAssertLessThan(pincushion.sourceRadius(0.5), 0.5)
    }

    func testNoneDistortionIsIdentity() {
        let d = DistortionModel.none
        for r in [0.0, 0.3, 1.0, 1.4] {
            XCTAssertEqual(d.sourceRadius(r), r, accuracy: 1e-12)
        }
    }

    /// 暗角模型：中心無衰減、邊緣衰減。
    func testVignettingAttenuation() {
        let v = VignettingModel(kind: .pa, k1: -0.5, k2: 0.1, k3: 0)
        XCTAssertEqual(v.attenuation(at: 0), 1, accuracy: 1e-12)
        XCTAssertLessThan(v.attenuation(at: 1.0), 1.0)
    }

    func testTCAScales() {
        let t = TCAModel(kind: .linear, kr: 0.999, kb: 1.001)
        let (r, b) = t.scales(at: 0.8)
        XCTAssertEqual(r, 0.999, accuracy: 1e-12)
        XCTAssertEqual(b, 1.001, accuracy: 1e-12)
    }
}

final class OpticalProfileManagerTests: XCTestCase {
    private func database() -> LensfunDatabase {
        let db = LensfunDatabase()
        db.load(xml: Data("""
        <lensdatabase><lens><maker>Canon</maker>
        <model>Canon EF 24-70mm f/2.8L II USM</model><cropfactor>1.0</cropfactor>
        <calibration><distortion model="poly3" focal="24" k1="-0.02"/></calibration>
        </lens></lensdatabase>
        """.utf8))
        return db
    }

    private func metadata(lens: String?, embedded: Bool) -> RawMetadata {
        var m = RawMetadata()
        m.cameraMake = "Canon"
        m.lensName = lens
        m.focalLength = 24
        m.aperture = 2.8
        m.hasEmbeddedLensCorrection = embedded
        return m
    }

    /// INV-4：內嵌校正存在時走 Apple 路徑，且不會再疊上 Lensfun 係數。
    func testEmbeddedWinsAndDisablesOwnRenderer() {
        let mgr = OpticalProfileManager(database: database())
        let r = mgr.resolve(
            metadata: metadata(lens: "Canon EF 24-70mm f/2.8L II USM", embedded: true),
            appleCorrectionSupported: true
        )
        XCTAssertEqual(r.profile.source, .embedded)
        XCTAssertTrue(r.useAppleCorrection)
        XCTAssertTrue(r.profile.isIdentity, "走 Apple 路徑時不能同時帶自家係數")
    }

    /// 沒有內嵌資料時落到 Lensfun，並關閉 Apple 校正。
    func testFallsBackToLensfun() {
        let mgr = OpticalProfileManager(database: database())
        let r = mgr.resolve(
            metadata: metadata(lens: "Canon EF 24-70mm f/2.8L II USM", embedded: false)
        )
        XCTAssertEqual(r.profile.source, .lensfun)
        XCTAssertFalse(r.useAppleCorrection)
        XCTAssertEqual(r.profile.distortion.kind, .poly3)
    }

    func testForcedOffProducesIdentity() {
        let mgr = OpticalProfileManager(database: database())
        let r = mgr.resolve(
            metadata: metadata(lens: "Canon EF 24-70mm f/2.8L II USM", embedded: true),
            preference: .force(.off),
            appleCorrectionSupported: true
        )
        XCTAssertEqual(r.profile.source, .off)
        XCTAssertTrue(r.profile.isIdentity)
    }

    func testUnknownLensProducesOff() {
        let mgr = OpticalProfileManager(database: database())
        let r = mgr.resolve(metadata: metadata(lens: "Unknown 35mm", embedded: false))
        XCTAssertEqual(r.profile.source, .off)
    }
}
