import Foundation

/// 為了 INV-2（可重現），每一段會影響像素的子系統都帶一個版本字串，
/// 並隨 sidecar 一起保存。
public enum RFVersion {
    /// Pipeline 整體版本。任何會改變輸出像素的行為變動都要提高它。
    public static let pipeline = "rf.pipeline.2"

    /// Perceptual color engine 的 profile 版本（§5.1 色彩引擎 profile 版本化）。
    /// 2：色帶由 6 點擴為 12 點平滑曲線，並加入亮度縮放與 split tone（A-010）。
    public static let colorEngine = "rf.hncslike.2"

    /// 光學校正實作版本。
    public static let opticalRenderer = "rf.optical.1"

    /// Tone mapping 實作版本。
    public static let toneMapping = "rf.tonemap.filmic.1"

    /// Gamut mapping 實作版本。
    public static let gamutMapping = "rf.gamut.oklch.1"

    /// §13 Scene Intelligence 產生者版本。改變時遮罩快取必須失效（A-029）。
    public static let sceneIntelligence = "rf.scene.vision.1"
}

/// Pipeline 各環節版本的快照，寫進 sidecar 後可判斷舊編輯是否仍能逐位元重現。
public struct PipelineVersions: Codable, Equatable, Sendable {
    public var pipeline: String
    public var colorEngine: String
    public var opticalRenderer: String
    public var toneMapping: String
    public var gamutMapping: String
    /// Apple RAW decoder 版本（由 CIRAWFilter 回報），鎖定後避免 macOS 更新造成漂移。
    public var rawDecoder: String
    /// 使用的鏡頭 profile 來源與其資料版本。
    public var lensProfile: String

    public init(
        pipeline: String = RFVersion.pipeline,
        colorEngine: String = RFVersion.colorEngine,
        opticalRenderer: String = RFVersion.opticalRenderer,
        toneMapping: String = RFVersion.toneMapping,
        gamutMapping: String = RFVersion.gamutMapping,
        rawDecoder: String = "",
        lensProfile: String = ""
    ) {
        self.pipeline = pipeline
        self.colorEngine = colorEngine
        self.opticalRenderer = opticalRenderer
        self.toneMapping = toneMapping
        self.gamutMapping = gamutMapping
        self.rawDecoder = rawDecoder
        self.lensProfile = lensProfile
    }
}
