import Foundation
import simd

/// §9 + §10 + §8：由 Scene Master 的 scene-referred 值，產生某個 rendering target
/// 的 display-referred 編碼值。
///
/// HDR 不是「SDR 變亮」，所以 tone mapping 明確吃 target 的 dynamic range 與
/// diffuse white；第二階段加入 constrained/full HDR 的高光配置。
public struct TargetTransform: Sendable {
    public let target: RenderingTarget
    public let tone: ToneMappingParameters
    public let gamut: GamutMappingParameters
    public let film: FilmParameters
    public let working: RGBColorSpace
    /// The input already carries an SDR rendering. Its neutral tone defaults must therefore
    /// preserve that appearance; user changes still pass through the processed-SDR tone policy.
    public let preservesProcessedSDR: Bool
    private let creativeLUT: CreativeLUT?

    public init(
        target: RenderingTarget,
        tone: ToneMappingParameters,
        gamut: GamutMappingParameters,
        film: FilmParameters = FilmParameters(),
        working: RGBColorSpace = .workingRec2020,
        preservesProcessedSDR: Bool = false
    ) {
        self.target = target
        self.tone = tone
        self.gamut = gamut
        self.film = film
        self.working = working
        self.preservesProcessedSDR = preservesProcessedSDR
        self.creativeLUT = film.hasLUT ? film.lutID.flatMap(CreativeLUTLibrary.load) : nil
    }

    /// scene-referred working RGB → 目標色域的編碼值；EDR linear target 可高於 1。
    public func apply(_ scene: SIMD3<Double>) -> SIMD3<Double> {
        var rgb = targetLinear(scene)
        let ceiling = target.contentHeadroom
        rgb = SIMD3(min(max(rgb.x, 0), ceiling), min(max(rgb.y, 0), ceiling),
                    min(max(rgb.z, 0), ceiling))
        if let creativeLUT { rgb = applyingCreativeLUT(creativeLUT, to: rgb) }
        return SIMD3(
            Self.encodeRelative(rgb.x, target: target),
            Self.encodeRelative(rgb.y, target: target),
            Self.encodeRelative(rgb.z, target: target)
        )
    }

    /// 創意 LUT 作用在 sRGB 編碼值上：先轉到 sRGB，查表後依強度混合，再轉回 target 色域。
    /// 高於 reference white 的 HDR 值依比例縮放後查表，保留 headroom。
    private func applyingCreativeLUT(_ lut: CreativeLUT, to rgb: SIMD3<Double>) -> SIMD3<Double> {
        let targetSpace = target.gamut.colorSpace
        let linear = simd_max(RGBColorSpace.sRGB.fromXYZ(targetSpace.toXYZ(rgb)), SIMD3(repeating: 0))
        let peak = max(linear.max(), 1)
        let unit = linear / peak
        let encoded = SIMD3(Self.encodeSRGB(unit.x), Self.encodeSRGB(unit.y), Self.encodeSRGB(unit.z))
        let looked = simd_clamp(lut.sample(encoded), SIMD3(repeating: 0), SIMD3(repeating: 1))
        let decoded = SIMD3(Self.decodeSRGB(looked.x), Self.decodeSRGB(looked.y), Self.decodeSRGB(looked.z)) * peak
        let mixed = linear + (decoded - linear) * film.lutAmount
        return targetSpace.fromXYZ(RGBColorSpace.sRGB.toXYZ(mixed))
    }

    /// scene-referred working RGB → 未夾值的 target-linear RGB。
    /// 可略過 gamut mapping，供診斷保留映射前的色域資訊。
    public func targetLinear(
        _ scene: SIMD3<Double>,
        applyGamutMapping: Bool = true
    ) -> SIMD3<Double> {
        // 黑白轉換放在遮罩之後，讓依色彩選取的工具仍能看到彩色來源。
        let filmScene = film.applyingMonochrome(to: scene)
        let lab = OKLab.fromXYZ(working.toXYZ(filmScene))
        var lch = OKLab.toLCH(lab)

        // §9 Tone mapping 作用在感知亮度上，色相不動。
        let mappedL = toneCurve(lch.x)
        // 亮度被壓縮時同步收斂 chroma，避免高光變成過飽和色塊。
        if lch.x > 1e-6 {
            let ratio = mappedL / lch.x
            if ratio < 1 { lch.y *= pow(ratio, 0.5) }
        }
        lch.x = mappedL

        // §10 Gamut mapping：保 hue、壓 chroma、必要時微調 lightness。
        if applyGamutMapping && gamut.enabled {
            lch = gamutCompress(lch)
        }

        let outXYZ = OKLab.toXYZ(OKLab.fromLCH(lch))
        let targetSpace = target.gamut.colorSpace
        return targetSpace.fromXYZ(outXYZ)
    }

    /// Filmic tone curve，作用於 OKLab L。
    ///
    /// 目標：diffuse white 對應到 target 的 SDR white（L = 1），高光單調滾降，
    /// 陰影可調塑形，中間調對比可調。
    public func toneCurve(_ l: Double) -> Double {
        guard l > 0 else { return l }
        let effectiveTone = film.composedTone(from: tone)
        if preservesProcessedSDR {
            return processedSDRToneCurve(l, tone: effectiveTone)
        }

        // diffuse white 先正規化到 L = 1（§9 Diffuse white preservation）。
        let whiteL = OKLab.toLCH(OKLab.fromXYZ(
            working.toXYZ(SIMD3(repeating: effectiveTone.diffuseWhite))
        )).x
        var x = l / max(whiteL, 1e-6)

        func shape(_ value: Double) -> Double {
            var value = value
            let pivot = 0.5
            if effectiveTone.midtoneContrast != 1 {
                value = pivot * pow(max(value, 1e-6) / pivot, effectiveTone.midtoneContrast)
            }
            if effectiveTone.shadowShaping != 0 {
                let w = exp(-pow(value / 0.35, 2))
                value *= 1.0 + effectiveTone.shadowShaping * w
            }
            return value
        }
        x = shape(x)

        // HDR 保留 tone controls，並重新錨定 diffuse white 到 1.0（= reference white）；
        // 其上的 scene highlight 單調配置到 content headroom（輸出 target 的 peak/ref，
        // 預覽時則是螢幕現在給得出的 headroom 換算成的 peak）。
        if target.contentHeadroom > 1.0 {
            x /= max(shape(1), 1e-6)
            if x <= 1 { return max(x, 0) }
            let range = target.contentHeadroom - 1
            let rollOff = 0.5 + effectiveTone.highlightRollOff * 1.5
            return min(1 + range * (1 - exp(-(x - 1) / rollOff)), target.contentHeadroom)
        }

        // Filmic 肩部：肩點以下維持線性，以上以雙曲線滾降到 1。
        let targetShoulder: Double
        switch target.dynamicRange {
        case .sdr: targetShoulder = effectiveTone.shoulderStart
        case .constrainedHDR: targetShoulder = effectiveTone.shoulderStart + 0.18
        case .fullHDR: targetShoulder = effectiveTone.shoulderStart + 0.30
        }
        let s = min(max(targetShoulder, 0.05), 0.95)
        if x > s {
            let k = max(1.0 - s, 1e-3) * (0.25 + effectiveTone.highlightRollOff)
            x = s + k * (1.0 - exp(-(x - s) / k))
        }
        return min(max(x, 0), 1.0)
    }

    /// SDR JPEG/HEIF pixels have already passed through a camera or phone rendering. Keep the
    /// default tone controls exactly neutral, then apply only controls that the user changes.
    private func processedSDRToneCurve(_ lightness: Double, tone: ToneMappingParameters) -> Double {
        let baseline = ToneMappingParameters()
        guard tone != baseline else { return lightness }
        let neutralMapping = processedSDRToneMapping(lightness, tone: baseline)
        let editedMapping = processedSDRToneMapping(lightness, tone: tone)
        return lightness + editedMapping - neutralMapping
    }

    private func processedSDRToneMapping(_ lightness: Double, tone: ToneMappingParameters) -> Double {
        let baseline = ToneMappingParameters()
        var value = lightness / max(tone.diffuseWhite, 1e-6)
        if tone.midtoneContrast != baseline.midtoneContrast {
            let pivot = 0.5
            value = pivot * pow(max(value, 1e-6) / pivot, tone.midtoneContrast)
        }
        if tone.shadowShaping != baseline.shadowShaping {
            let weight = exp(-pow(value / 0.35, 2))
            value *= 1.0 + tone.shadowShaping * weight
        }
        let shoulder = min(max(tone.shoulderStart, 0.05), 0.95)
        if value > shoulder {
            let k = max(1.0 - shoulder, 1e-3) * (0.25 + tone.highlightRollOff)
            value = shoulder + k * (1.0 - exp(-(value - shoulder) / k))
        }
        return value
    }

    /// 以固定色相為前提，把 chroma 壓進目標色域；必要時微調 lightness。
    func gamutCompress(_ lch: SIMD3<Double>) -> SIMD3<Double> {
        var out = lch
        let targetSpace = target.gamut.colorSpace
        let maxC = Self.maxChroma(l: out.x, h: out.z, space: targetSpace)
        guard maxC > 1e-6 else {
            out.y = 0
            return out
        }
        let knee = min(max(gamut.knee, 0.1), 0.99)
        let t = out.y / maxC
        if t > knee {
            // Soft knee：knee 以上漸進壓向邊界但不貼齊，避免顏色堆在 gamut boundary。
            let over = (t - knee) / max(1 - knee, 1e-6)
            let compressed = knee + (1 - knee) * (over / (1 + over)) * 0.98
            out.y = compressed * maxC

            // 極飽和色若仍差得遠，允許小幅調整 lightness 換取更多可用 chroma。
            if gamut.lightnessAdapt > 0, t > 1.0 {
                let pull = min((t - 1.0) * 0.25, gamut.lightnessAdapt)
                out.x += (0.5 - out.x) * pull
                let newMax = Self.maxChroma(l: out.x, h: out.z, space: targetSpace)
                out.y = min(out.y, newMax * 0.98)
            }
        }
        return out
    }

    /// 給定 OKLab L 與色相，求目標色域內的最大 chroma（二分搜尋）。
    static func maxChroma(l: Double, h: Double, space: RGBColorSpace) -> Double {
        guard l > 0, l < 1 else { return 0 }
        func inGamut(_ c: Double) -> Bool {
            let rgb = space.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(SIMD3(l, c, h))))
            return rgb.min() >= -1e-4 && rgb.max() <= 1 + 1e-4
        }
        var lo = 0.0, hi = 0.5
        if inGamut(hi) { return hi }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if inGamut(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// sRGB / Display P3 共用的傳遞函數。
    public static func encodeSRGB(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    public static func decodeSRGB(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// 將「相對 reference white」的 target-linear 值（1.0 = reference white，HDR 可到
    /// content headroom）編碼成 target 的 transfer function。
    ///
    /// PQ 是絕對亮度曲線：必須先乘回 reference white 換成 nit、再除以 10,000 才能編碼；
    /// 直接把相對 1.0 當成 PQ 輸入 1.0 等於宣告 diffuse white = 10,000 nit。
    /// HLG 則是 relative / scene-referred，不做絕對亮度換算，只把 content peak 對到 1.0，
    /// 顯示端的 OOTF 交給系統。
    public static func encodeRelative(_ v: Double, target: RenderingTarget) -> Double {
        let x = max(v, 0)
        switch target.transferFunction {
        case .sRGB:
            return encodeSRGB(min(x, 1))
        case .linear:
            // EDR linear：1.0 就是 reference white，>1 是合法的 headroom 值。
            return x
        case .pq:
            let nits = x * target.referenceWhiteNits
            return encode(min(nits / 10000.0, 1), transfer: .pq)
        case .hlg:
            return encode(min(x / target.contentHeadroom, 1), transfer: .hlg)
        }
    }

    /// 將 0…1 的正規化訊號編碼成指定 transfer function（PQ 的 1.0 = 10,000 nit）。
    public static func encode(_ v: Double, transfer: RenderingTarget.TransferFunction) -> Double {
        let x = transfer == .linear ? max(v, 0) : min(max(v, 0), 1)
        if x == 0 { return 0 }
        if x == 1 { return 1 }
        switch transfer {
        case .linear:
            return x
        case .sRGB:
            return encodeSRGB(x)
        case .pq:
            // SMPTE ST 2084，輸入以 10,000 nit 正規化。
            let m1 = 2610.0 / 16384.0
            let m2 = 2523.0 / 32.0
            let c1 = 3424.0 / 4096.0
            let c2 = 2413.0 / 128.0
            let c3 = 2392.0 / 128.0
            let p = pow(x, m1)
            return pow((c1 + c2 * p) / (1 + c3 * p), m2)
        case .hlg:
            // ARIB STD-B67 / BT.2100 OETF，scene-linear 0…1。
            if x <= 1.0 / 12.0 { return sqrt(3 * x) }
            let a = 0.17883277
            let b = 1 - 4 * a
            let c = 0.5 - a * log(4 * a)
            return a * log(12 * x - b) + c
        }
    }
}
