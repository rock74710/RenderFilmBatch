import Foundation

/// §2.1 Profile 優先序管理 + double correction 防呆。
///
/// 同一時間只會有一個來源生效：解析出來的 `ResolvedLensProfile` 就是唯一真相，
/// 其他來源（包含 Apple 自動校正）都必須被關閉。
public struct OpticalProfileManager: Sendable {
    public let database: LensfunDatabase

    public init(database: LensfunDatabase) {
        self.database = database
    }

    /// 使用者對來源的偏好。`auto` 表示照優先序自動挑第一個可用的。
    public enum Preference: Equatable, Sendable {
        case auto
        case force(LensProfileSource)
    }

    public struct Resolution: Sendable {
        public let profile: ResolvedLensProfile
        /// Apple 的自動鏡頭校正是否應該開啟。只有 source == .apple 時為 true。
        public let useAppleCorrection: Bool
        /// 說明為何挑到這個來源，UI 直接顯示。
        public let reason: String
        public let databaseVersion: String
    }

    public func resolve(
        metadata: RawMetadata,
        preference: Preference = .auto,
        manual: ResolvedLensProfile? = nil,
        appleCorrectionSupported: Bool = false
    ) -> Resolution {
        let order: [LensProfileSource]
        switch preference {
        case .auto:
            order = LensProfileSource.allCases.sorted { $0.priority < $1.priority }
        case .force(let s):
            order = [s]
        }

        for source in order {
            switch source {
            case .embedded:
                // 第一階段只判斷是否存在；內嵌係數的完整解析留待後續階段。
                // 存在時交給 Apple 解碼器處理，不再疊加 Lensfun（防止 double correction）。
                if metadata.hasEmbeddedLensCorrection && appleCorrectionSupported {
                    return Resolution(
                        profile: ResolvedLensProfile(source: .embedded,
                                                     identifier: metadata.lensName ?? "embedded"),
                        useAppleCorrection: true,
                        reason: String(localized: "RAW 內嵌鏡頭校正資料", bundle: .module),
                        databaseVersion: "embedded"
                    )
                }
            case .lensfun:
                if let lens = database.findLens(name: metadata.lensName, maker: metadata.cameraMake) {
                    let p = lens.resolve(
                        focal: metadata.focalLength ?? 50,
                        aperture: metadata.aperture,
                        distance: metadata.focusDistance
                    )
                    if !p.isIdentity {
                        return Resolution(
                            profile: p,
                            useAppleCorrection: false,
                            reason: "Lensfun：\(p.identifier)",
                            databaseVersion: database.version
                        )
                    }
                }
            case .apple:
                if appleCorrectionSupported {
                    return Resolution(
                        profile: ResolvedLensProfile(source: .apple, identifier: String(localized: "Apple 自動", bundle: .module)),
                        useAppleCorrection: true,
                        reason: String(localized: "Apple 自動鏡頭校正", bundle: .module),
                        databaseVersion: "apple"
                    )
                }
            case .manual:
                if let manual, !manual.isIdentity {
                    return Resolution(profile: manual, useAppleCorrection: false,
                                      reason: String(localized: "手動 profile", bundle: .module), databaseVersion: "manual")
                }
            case .off:
                break
            }
        }

        return Resolution(profile: .off, useAppleCorrection: false,
                          reason: String(localized: "找不到可用 profile，維持未校正", bundle: .module),
                          databaseVersion: database.version)
    }
}
