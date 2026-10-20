import Foundation

/// §2 光學校正所需的係數。採用 Lensfun 的模型定義，方便直接吃官方資料庫。
public struct DistortionModel: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case none, poly3, poly5, ptlens }
    public var kind: Kind
    /// poly3: a=k1。poly5: a=k1, b=k2。ptlens: a, b, c。
    public var a: Double
    public var b: Double
    public var c: Double

    public init(kind: Kind = .none, a: Double = 0, b: Double = 0, c: Double = 0) {
        self.kind = kind; self.a = a; self.b = b; self.c = c
    }

    public static let none = DistortionModel()

    /// 已校正影像上的半徑 `rd` → 原始影像上的半徑 `ru`（Lensfun 的正向定義）。
    public func sourceRadius(_ rd: Double) -> Double {
        switch kind {
        case .none: return rd
        case .poly3: return rd * (1 - a + a * rd * rd)
        case .poly5: return rd * (1 + a * rd * rd + b * rd * rd * rd * rd)
        case .ptlens:
            let r2 = rd * rd
            return rd * (a * r2 * rd + b * r2 + c * rd + 1 - a - b - c)
        }
    }
}

public struct TCAModel: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case none, linear, poly3 }
    public var kind: Kind
    /// linear: kr, kb。poly3: (br, vr) 與 (bb, vb)。
    public var kr: Double
    public var kb: Double
    public var br: Double
    public var bb: Double

    public init(kind: Kind = .none, kr: Double = 1, kb: Double = 1, br: Double = 0, bb: Double = 0) {
        self.kind = kind; self.kr = kr; self.kb = kb; self.br = br; self.bb = bb
    }

    public static let none = TCAModel()

    /// 回傳 (紅通道縮放, 藍通道縮放)，以半徑 r 為變數。
    public func scales(at r: Double) -> (Double, Double) {
        switch kind {
        case .none: return (1, 1)
        case .linear: return (kr, kb)
        case .poly3:
            let r2 = r * r
            return (kr + br * r2, kb + bb * r2)
        }
    }
}

public struct VignettingModel: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case none, pa }
    public var kind: Kind
    public var k1: Double
    public var k2: Double
    public var k3: Double

    public init(kind: Kind = .none, k1: Double = 0, k2: Double = 0, k3: Double = 0) {
        self.kind = kind; self.k1 = k1; self.k2 = k2; self.k3 = k3
    }

    public static let none = VignettingModel()

    /// 鏡頭造成的亮度衰減係數（<= 1）。校正時除以它。
    public func attenuation(at r: Double) -> Double {
        switch kind {
        case .none: return 1
        case .pa:
            let r2 = r * r
            return 1 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2
        }
    }
}

/// 單一拍攝條件（焦距 / 光圈 / 對焦距離）下的校正係數。
public struct LensCalibration: Codable, Equatable, Sendable {
    public var focal: Double
    public var aperture: Double?
    public var distance: Double?
    public var distortion: DistortionModel?
    public var tca: TCAModel?
    public var vignetting: VignettingModel?

    public init(focal: Double, aperture: Double? = nil, distance: Double? = nil,
                distortion: DistortionModel? = nil, tca: TCAModel? = nil,
                vignetting: VignettingModel? = nil) {
        self.focal = focal; self.aperture = aperture; self.distance = distance
        self.distortion = distortion; self.tca = tca; self.vignetting = vignetting
    }
}

/// Lensfun 資料庫中的一支鏡頭。
public struct LensEntry: Codable, Equatable, Sendable {
    public var maker: String
    public var model: String
    public var mount: [String]
    public var cropFactor: Double
    public var calibrations: [LensCalibration]

    public init(maker: String, model: String, mount: [String] = [],
                cropFactor: Double = 1.0, calibrations: [LensCalibration] = []) {
        self.maker = maker; self.model = model; self.mount = mount
        self.cropFactor = cropFactor; self.calibrations = calibrations
    }
}

/// 對特定拍攝條件插值後、可直接送進 renderer 的一組係數（§2.2 依焦距/光圈/對焦距離插值）。
public struct ResolvedLensProfile: Codable, Equatable, Sendable {
    public var source: LensProfileSource
    public var identifier: String
    public var distortion: DistortionModel
    public var tca: TCAModel
    public var vignetting: VignettingModel
    /// 校正係數是以「對角線半徑 = 1」正規化。
    public var cropFactor: Double

    public init(source: LensProfileSource, identifier: String,
                distortion: DistortionModel = .none, tca: TCAModel = .none,
                vignetting: VignettingModel = .none, cropFactor: Double = 1.0) {
        self.source = source; self.identifier = identifier
        self.distortion = distortion; self.tca = tca
        self.vignetting = vignetting; self.cropFactor = cropFactor
    }

    public static let off = ResolvedLensProfile(source: .off, identifier: "off")

    public var isIdentity: Bool {
        distortion.kind == .none && tca.kind == .none && vignetting.kind == .none
    }
}

/// §2.1 Profile 優先順序。
public enum LensProfileSource: String, Codable, CaseIterable, Sendable {
    case embedded       // RAW 內嵌 metadata
    case lensfun        // Lensfun 資料庫
    case apple          // Apple 自動鏡頭校正
    case manual         // 手動 / 自訂
    case off

    public var displayName: String {
        switch self {
        case .embedded: return String(localized: "RAW 內嵌", bundle: .module)
        case .lensfun: return "Lensfun"
        case .apple: return String(localized: "Apple 自動", bundle: .module)
        case .manual: return String(localized: "手動", bundle: .module)
        case .off: return String(localized: "關閉", bundle: .module)
        }
    }

    /// 數字越小越優先。
    public var priority: Int {
        switch self {
        case .embedded: return 0
        case .lensfun: return 1
        case .apple: return 2
        case .manual: return 3
        case .off: return 4
        }
    }
}

extension LensEntry {
    /// 依拍攝條件插值出一組係數。
    ///
    /// 焦距在 log 空間插值（鏡頭畸變隨焦距的變化比較接近幾何級數），
    /// 光圈與對焦距離取最接近的樣本，避免在稀疏樣本上外插出奇怪的值。
    public func resolve(focal: Double, aperture: Double?, distance: Double?) -> ResolvedLensProfile {
        var p = ResolvedLensProfile(
            source: .lensfun,
            identifier: "\(maker) \(model)",
            cropFactor: cropFactor
        )
        p.distortion = interpolateDistortion(focal: focal) ?? .none
        p.tca = interpolateTCA(focal: focal) ?? .none
        p.vignetting = nearestVignetting(focal: focal, aperture: aperture, distance: distance) ?? .none
        return p
    }

    private func bracket<T>(
        _ items: [(focal: Double, value: T)], focal: Double
    ) -> (T, T, Double)? {
        guard !items.isEmpty else { return nil }
        let sorted = items.sorted { $0.focal < $1.focal }
        if focal <= sorted[0].focal { return (sorted[0].value, sorted[0].value, 0) }
        if focal >= sorted[sorted.count - 1].focal {
            let last = sorted[sorted.count - 1].value
            return (last, last, 0)
        }
        for i in 1..<sorted.count where focal <= sorted[i].focal {
            let lo = sorted[i - 1], hi = sorted[i]
            let t = (log(focal) - log(lo.focal)) / (log(hi.focal) - log(lo.focal))
            return (lo.value, hi.value, t)
        }
        return nil
    }

    private func interpolateDistortion(focal: Double) -> DistortionModel? {
        let items = calibrations.compactMap { c in c.distortion.map { (c.focal, $0) } }
        guard let (lo, hi, t) = bracket(items.map { (focal: $0.0, value: $0.1) }, focal: focal) else { return nil }
        guard lo.kind == hi.kind else { return t < 0.5 ? lo : hi }
        return DistortionModel(
            kind: lo.kind,
            a: lo.a + (hi.a - lo.a) * t,
            b: lo.b + (hi.b - lo.b) * t,
            c: lo.c + (hi.c - lo.c) * t
        )
    }

    private func interpolateTCA(focal: Double) -> TCAModel? {
        let items = calibrations.compactMap { c in c.tca.map { (c.focal, $0) } }
        guard let (lo, hi, t) = bracket(items.map { (focal: $0.0, value: $0.1) }, focal: focal) else { return nil }
        guard lo.kind == hi.kind else { return t < 0.5 ? lo : hi }
        return TCAModel(
            kind: lo.kind,
            kr: lo.kr + (hi.kr - lo.kr) * t,
            kb: lo.kb + (hi.kb - lo.kb) * t,
            br: lo.br + (hi.br - lo.br) * t,
            bb: lo.bb + (hi.bb - lo.bb) * t
        )
    }

    private func nearestVignetting(focal: Double, aperture: Double?, distance: Double?) -> VignettingModel? {
        let items = calibrations.filter { $0.vignetting != nil }
        guard !items.isEmpty else { return nil }
        func cost(_ c: LensCalibration) -> Double {
            var d = abs(log(max(c.focal, 0.1)) - log(max(focal, 0.1))) * 3
            if let a = aperture, let ca = c.aperture {
                d += abs(log2(max(ca, 0.1)) - log2(max(a, 0.1)))
            }
            if let dist = distance, let cd = c.distance {
                d += abs(log(max(cd, 0.01)) - log(max(dist, 0.01))) * 0.25
            }
            return d
        }
        return items.min(by: { cost($0) < cost($1) })?.vignetting
    }
}
