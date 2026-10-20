import Foundation

/// A-105：預覽縮放的純計算。倍率 1 是 100%（一個原檔像素對一個螢幕像素），nil 是適合視窗。
public enum PreviewZoom {
    /// 螢幕需要的像素超過 proxy 提供的像素時，補算原檔細節。
    public static func needsDetail(level: Double?, proxyScale: Double) -> Bool {
        guard let level else { return false }
        return proxyScale < 1 && level > proxyScale
    }

    public static let maxLevel = 8.0
    /// 點兩下放大可選的倍率。
    public static let doubleClickLevels = [0.5, 1, 2, 4]

    /// 點兩下：適合視窗 → 設定倍率；已放大 → 適合視窗。
    public static func toggled(_ current: Double?, doubleClickLevel: Double) -> Double? {
        current == nil ? doubleClickLevel : nil
    }

    /// 雙指縮放：從手勢開始時的倍率乘上捏合比例；縮到適合視窗以下就回 nil。
    /// `fitLevel` 是適合視窗時換算成的倍率。
    public static func pinched(from start: Double?, magnification: Double, fitLevel: Double) -> Double? {
        let level = (start ?? fitLevel) * magnification
        return level <= fitLevel ? nil : min(level, maxLevel)
    }
}
