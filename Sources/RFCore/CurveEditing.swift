import Foundation

/// §11 Final Curve 的拖曳編輯輔助（A-046）。
///
/// 曲線資料仍然是 `FinalCurve` 那份等距五點陣列：x 由索引決定，拖曳只改 y。
/// 這裡只做座標與收合規則，畫圖與手勢留在 UI。
public enum CurveEditing {

    /// 不做任何調整的直線；`FinalCurve` 用空陣列表示同一件事。
    public static let identity: [Double] = [0, 0.25, 0.5, 0.75, 1]

    /// 曲線畫布 X、Y 各分幾格；吸附時輸出值取到最近的格線。
    public static let gridDivisions = 10

    /// 讀出可編輯的控制點。空陣列或長度不符的舊資料都當成直線。
    public static func points(_ raw: [Double]) -> [Double] {
        raw.count == identity.count ? raw : identity
    }

    /// 按下位置的輸入值 x（0…1）離哪個節點最近。畫布外也會夾回合法索引。
    public static func nearestNode(at x: Double) -> Int {
        let last = identity.count - 1
        let index = Int((min(max(x, 0), 1) * Double(last)).rounded())
        return min(max(index, 0), last)
    }

    /// 把第 `node` 個節點的輸出值移到 `y`，回傳要寫回 `FinalCurve` 的陣列。
    /// 結果剛好等於直線時收合成空陣列，維持「空陣列＝未啟用」的既有約定。
    /// `snap` 為 true 時輸出值吸附到 1/`gridDivisions` 的格線。
    public static func moved(_ raw: [Double], node: Int, to y: Double, snap: Bool = false) -> [Double] {
        var updated = points(raw)
        guard updated.indices.contains(node) else { return raw }
        let steps = Double(gridDivisions)
        let clamped = min(max(y, 0), 1)
        updated[node] = snap ? (clamped * steps).rounded() / steps : clamped
        return updated == identity ? [] : updated
    }

    /// 取樣整條曲線，給 UI 畫線用。用的是 `FinalCurve` 同一條插值，
    /// 所以畫出來的線就是實際會套用的線。
    public static func sampled(_ raw: [Double], count: Int) -> [Double] {
        let curve = points(raw)
        let last = max(count - 1, 1)
        return (0..<max(count, 1)).map { FinalCurve.evaluate(curve, Double($0) / Double(last)) }
    }
}
