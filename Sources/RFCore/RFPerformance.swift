import os

/// Instruments 的 Points of Interest 區間。不記錄照片名稱或內容。
/// CIImage 可能延後運算：RenderGraph 只代表建圖／同步 pass；
/// Preview 與 Encode 才涵蓋實際產出，區間可巢狀，不能相加當成 GPU 時間。
enum RFPerformance {
    private static let signposter = OSSignposter(subsystem: "com.renderfilm.RFCore", category: "PointsOfInterest")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
