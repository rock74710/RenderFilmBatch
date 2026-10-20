import Foundation
import simd

/// 3x3 矩陣運算的薄包裝，方便以列為單位書寫色彩轉換矩陣。
public struct Matrix3: Equatable, Sendable {
    public var m: simd_double3x3

    public init(rows r0: SIMD3<Double>, _ r1: SIMD3<Double>, _ r2: SIMD3<Double>) {
        // simd_double3x3(columns:) 吃的是「行」，所以這裡做一次轉置。
        m = simd_double3x3(rows: [r0, r1, r2])
    }

    public init(_ m: simd_double3x3) { self.m = m }

    public var inverse: Matrix3 { Matrix3(m.inverse) }

    public func callAsFunction(_ v: SIMD3<Double>) -> SIMD3<Double> { m * v }

    public static func * (lhs: Matrix3, rhs: Matrix3) -> Matrix3 { Matrix3(lhs.m * rhs.m) }

    /// 逐列展開成 9 個 Float，供 Metal / Core Image 使用。
    public var floatRows: [Float] {
        let t = m.transpose // columns -> rows
        return (0..<3).flatMap { i -> [Float] in
            let c = t[i]
            return [Float(c.x), Float(c.y), Float(c.z)]
        }
    }

    public static let identity = Matrix3(simd_double3x3(1))
}

/// RGB working space 與輸出色域的定義。所有內部運算都在 linear、wide-gamut 空間進行。
public struct RGBColorSpace: Equatable, Sendable {
    public let name: String
    /// 線性 RGB → XYZ (D65)
    public let toXYZ: Matrix3
    /// XYZ (D65) → 線性 RGB
    public let fromXYZ: Matrix3

    public init(name: String, toXYZ: Matrix3) {
        self.name = name
        self.toXYZ = toXYZ
        self.fromXYZ = toXYZ.inverse
    }

    /// 由 primaries 與白點（xy 色度）推導 RGB→XYZ 矩陣。
    public init(
        name: String,
        red: SIMD2<Double>,
        green: SIMD2<Double>,
        blue: SIMD2<Double>,
        white: SIMD2<Double>
    ) {
        func xyzFromXY(_ c: SIMD2<Double>) -> SIMD3<Double> {
            SIMD3(c.x / c.y, 1.0, (1.0 - c.x - c.y) / c.y)
        }
        let r = xyzFromXY(red), g = xyzFromXY(green), b = xyzFromXY(blue)
        let w = xyzFromXY(white)
        let primaries = simd_double3x3(columns: (r, g, b))
        let scale = primaries.inverse * w
        let m = primaries * simd_double3x3(diagonal: scale)
        self.init(name: name, toXYZ: Matrix3(m))
    }

    public static let d65 = SIMD2<Double>(0.3127, 0.3290)

    /// 內部 working space：Rec.2020 primaries / D65，足以涵蓋 Display P3 與 sRGB。
    public static let workingRec2020 = RGBColorSpace(
        name: "Linear Rec.2020 D65",
        red: SIMD2(0.708, 0.292),
        green: SIMD2(0.170, 0.797),
        blue: SIMD2(0.131, 0.046),
        white: d65
    )

    public static let sRGB = RGBColorSpace(
        name: "sRGB",
        red: SIMD2(0.640, 0.330),
        green: SIMD2(0.300, 0.600),
        blue: SIMD2(0.150, 0.060),
        white: d65
    )

    public static let displayP3 = RGBColorSpace(
        name: "Display P3",
        red: SIMD2(0.680, 0.320),
        green: SIMD2(0.265, 0.690),
        blue: SIMD2(0.150, 0.060),
        white: d65
    )

    public static let rec2020 = workingRec2020

    /// 由本色域線性 RGB 轉到另一個色域線性 RGB 的矩陣。
    public func matrix(to other: RGBColorSpace) -> Matrix3 { other.fromXYZ * toXYZ }
}

/// OKLab / OKLCH 轉換（Björn Ottosson）。輸入輸出皆為 linear sRGB 以外的
/// 任意 working space，故先轉到 XYZ 再進 LMS。
public enum OKLab {
    // XYZ(D65) → LMS
    static let xyzToLMS = Matrix3(
        rows: SIMD3(0.8189330101, 0.3618667424, -0.1288597137),
        SIMD3(0.0329845436, 0.9293118715, 0.0361456387),
        SIMD3(0.0482003018, 0.2643662691, 0.6338517070)
    )
    static let lmsToXYZ = xyzToLMS.inverse

    // LMS' → OKLab
    static let lmsToLab = Matrix3(
        rows: SIMD3(0.2104542553, 0.7936177850, -0.0040720468),
        SIMD3(1.9779984951, -2.4285922050, 0.4505937099),
        SIMD3(0.0259040371, 0.7827717662, -0.8086757660)
    )
    static let labToLMS = lmsToLab.inverse

    @inlinable
    static func cbrtSigned(_ x: Double) -> Double {
        x < 0 ? -pow(-x, 1.0 / 3.0) : pow(x, 1.0 / 3.0)
    }

    public static func fromXYZ(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
        let lms = xyzToLMS(xyz)
        let l = SIMD3(cbrtSigned(lms.x), cbrtSigned(lms.y), cbrtSigned(lms.z))
        return lmsToLab(l)
    }

    public static func toXYZ(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = labToLMS(lab)
        let lms = SIMD3(l.x * l.x * l.x, l.y * l.y * l.y, l.z * l.z * l.z)
        return lmsToXYZ(lms)
    }

    /// OKLab → OKLCH（L, C, H；H 以度為單位，範圍 [0, 360)）
    public static func toLCH(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let c = sqrt(lab.y * lab.y + lab.z * lab.z)
        var h = atan2(lab.z, lab.y) * 180.0 / .pi
        if h < 0 { h += 360 }
        return SIMD3(lab.x, c, h)
    }

    public static func fromLCH(_ lch: SIMD3<Double>) -> SIMD3<Double> {
        let r = lch.z * .pi / 180.0
        return SIMD3(lch.x, lch.y * cos(r), lch.y * sin(r))
    }
}

/// 兩個角度（度）之間的最短差值，範圍 (-180, 180]。
@inlinable
public func hueDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d <= -180 { d += 360 }
    return d
}
