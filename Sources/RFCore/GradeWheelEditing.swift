import Foundation

/// §11 Layer C 陰影／中間調／高光色輪的拖曳換算（A-069）。
///
/// 資料仍然是 `GradeWheel` 的色相與色彩量：輪上的點用數學座標（x 向右、y 向上），
/// 角度就是 OKLCh 色相，離圓心的距離（0…1）乘上 `maxAmount` 就是色彩量。
/// 這裡只做座標換算與輪面顏色，畫圖與手勢留在 UI。
public enum GradeWheelEditing {

    /// 輪緣對應的色彩量，和原本「色彩量」滑桿的上限相同。
    public static let maxAmount = 0.15

    /// 目前設定在輪上的位置，半徑 0…1。
    public static func point(_ wheel: GradeWheel) -> SIMD2<Double> {
        let r = min(max(wheel.amount / maxAmount, 0), 1)
        let angle = wheel.hue * .pi / 180
        return SIMD2(cos(angle), sin(angle)) * r
    }

    /// 拖到 `point` 後的新設定；超出輪緣夾回輪緣，亮度不變。
    /// 正中心沒有方向，只把色彩量歸零、保留原本色相。
    public static func dragged(_ wheel: GradeWheel, to point: SIMD2<Double>) -> GradeWheel {
        var out = wheel
        let r = (point.x * point.x + point.y * point.y).squareRoot()
        guard r > 0 else {
            out.amount = 0
            return out
        }
        var hue = atan2(point.y, point.x) * 180 / .pi
        if hue < 0 { hue += 360 }
        out.hue = hue
        out.amount = min(r, 1) * maxAmount
        return out
    }

    /// 輪面上某個色相要畫的顏色（sRGB 編碼後 0…1）。
    /// 用固定亮度與彩度的 OKLCh 取色，所以輪上的方向就是實際染色的方向。
    public static func displayColor(hue: Double) -> SIMD3<Double> {
        let lab = OKLab.fromLCH(SIMD3(0.72, 0.12, hue))
        let linear = RGBColorSpace.sRGB.fromXYZ(OKLab.toXYZ(lab))
        return SIMD3(TargetTransform.encodeSRGB(linear.x),
                     TargetTransform.encodeSRGB(linear.y),
                     TargetTransform.encodeSRGB(linear.z))
    }
}
