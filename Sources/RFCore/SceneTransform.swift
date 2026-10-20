import Foundation
import simd

/// §3 + §4 + §5 + §6：從 RAW 解碼後的相機線性值，走到 Scene Master 的 scene-referred 值。
///
/// 全段維持 extended linear range、不做 clamp（INV-1）；Layer B 色彩調整也在 tone mapping 前完成。
public struct SceneTransform: Sendable {
    public let cameraNormalize: Matrix3
    public let layerA: LayerATechnical
    public let colorEngine: ColorEngineParameters
    public let colorMixer: ColorMixerParameters
    public let film: FilmParameters
    /// 白平衡增益（working space 下的 RGB 乘數）。
    ///
    /// 只由 Layer A 的色溫／Tint 與 RAW as-shot 白點決定；Color Engine 不參與白平衡。
    public let whiteBalanceGains: SIMD3<Double>

    public init(
        cameraNormalize: Matrix3 = .identity,
        layerA: LayerATechnical,
        colorEngine: ColorEngineParameters,
        colorMixer: ColorMixerParameters = ColorMixerParameters(),
        film: FilmParameters = FilmParameters(),
        whiteBalanceGains: SIMD3<Double> = SIMD3(1, 1, 1)
    ) {
        self.cameraNormalize = cameraNormalize
        self.layerA = layerA
        self.colorEngine = colorEngine
        self.colorMixer = colorMixer
        self.film = film
        self.whiteBalanceGains = whiteBalanceGains
    }

    /// 單一像素的 scene-referred 轉換。LUT 烘焙與單元測試共用這一份實作。
    public func apply(_ input: SIMD3<Double>) -> SIMD3<Double> {
        // §3.1 Camera normalize + white balance
        var rgb = cameraNormalize(input * whiteBalanceGains)

        // §4 Layer A：曝光
        if layerA.exposureEV != 0 {
            rgb *= pow(2.0, layerA.exposureEV)
        }

        // §4 高光 / 陰影還原。作用在線性亮度上，保留 highlight headroom（§3.1）。
        let y0 = luminance(rgb)
        if layerA.highlightRecovery > 0 || layerA.shadowRecovery > 0 {
            let recovered = recover(luminance: y0)
            rgb = scaleLuminance(rgb, from: y0, to: recovered)
        }

        // §4 線性對比：以中灰 0.18 為支點。
        if layerA.linearContrast != 0 {
            let k = 1.0 + layerA.linearContrast
            let y = max(luminance(rgb), 1e-6)
            let y2 = 0.18 * pow(y / 0.18, k)
            rgb = scaleLuminance(rgb, from: y, to: y2)
        }

        // §4 基礎 chroma：在 OKLCH 下縮放，避免 RGB 直接縮放造成色相偏移。
        if layerA.chroma != 1 || colorEngine.enabled || film.hasColorEffect {
            rgb = perceptual(rgb)
        }
        if !colorMixer.isNeutral {
            rgb = applyColorMixer(rgb)
        }
        return rgb
    }

    /// Layer B：八色帶混色與選擇性色彩，接在 perceptual color engine 後、tone mapping 前。
    private func applyColorMixer(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let working = RGBColorSpace.workingRec2020
        let xyz = working.toXYZ(rgb)
        var lch = OKLab.toLCH(OKLab.fromXYZ(xyz))
        guard lch.y > 1e-9 else { return rgb }

        let weights = Self.colorMixerWeights(lch.z)
        let bands = colorMixer.bands
        func mixed(_ keyPath: KeyPath<ColorMixerBandParameters, Double>) -> Double {
            zip(bands, weights).reduce(0) { $0 + $1.0[keyPath: keyPath] * $1.1 }
        }
        let hueShift = mixed(\.hueShift)
        let saturationShift = mixed(\.saturationShift)
        let lightnessShift = mixed(\.lightnessShift)
        let cyan = mixed(\.cyan)
        let magenta = mixed(\.magenta)
        let yellow = mixed(\.yellow)
        let black = mixed(\.black)
        guard hueShift != 0 || saturationShift != 0 || lightnessShift != 0
                || cyan != 0 || magenta != 0 || yellow != 0 || black != 0 else {
            return rgb
        }

        if hueShift != 0 || saturationShift != 0 || lightnessShift != 0 {
            lch.z = (lch.z + hueShift).truncatingRemainder(dividingBy: 360)
            if lch.z < 0 { lch.z += 360 }
            lch.y *= max(0, 1 + saturationShift)
            lch.x *= max(0, 1 + lightnessShift)
        }

        var out = working.fromXYZ(OKLab.toXYZ(OKLab.fromLCH(lch)))
        // CMYK 式相對通道加減：C/M/Y 分別作用在 R/G/B，K 同比例作用全部通道。
        // 以 2 倍曝光刻度讓 −1…1 對應減半至加倍，保留 scene-linear HDR headroom。
        out.x *= pow(2, -cyan)
        out.y *= pow(2, -magenta)
        out.z *= pow(2, -yellow)
        out *= pow(2, -black)
        return out
    }

    /// 色帶中心來自具名 sRGB 參考色轉成線性 RGB 後的 OKLab 色相。
    /// 順序必須和 ColorMixerBand 一致：red、orange (#FF8000)、yellow、green、
    /// aqua、blue、purple (#8000FF)、magenta。
    private static let colorMixerHueCenters: [Double] = [
        SIMD3(255, 0, 0), SIMD3(255, 128, 0), SIMD3(255, 255, 0),
        SIMD3(0, 255, 0), SIMD3(0, 255, 255), SIMD3(0, 0, 255),
        SIMD3(128, 0, 255), SIMD3(255, 0, 255)
    ].map { srgb8 in
        func linear(_ channel: Double) -> Double {
            let encoded = channel / 255
            return encoded <= 0.04045
                ? encoded / 12.92
                : pow((encoded + 0.055) / 1.055, 2.4)
        }
        let linearSRGB = SIMD3(linear(srgb8.x), linear(srgb8.y), linear(srgb8.z))
        let xyz = RGBColorSpace.sRGB.toXYZ(linearSRGB)
        return OKLab.toLCH(OKLab.fromXYZ(xyz)).z
    }

    static func colorMixerWeights(_ hue: Double) -> [Double] {
        let centers = colorMixerHueCenters
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        for index in centers.indices {
            let next = (index + 1) % centers.count
            let start = centers[index]
            let end = next == 0 ? centers[0] + 360 : centers[next]
            let adjustedHue = h < start ? h + 360 : h
            guard adjustedHue >= start && adjustedHue <= end else { continue }
            let t = min(max((adjustedHue - start) / (end - start), 0), 1)
            let eased = t * t * (3 - 2 * t)
            var weights = Array(repeating: 0.0, count: centers.count)
            weights[index] = 1 - eased
            weights[next] = eased
            return weights
        }
        return Array(repeating: 0, count: centers.count)
    }

    private func recover(luminance y: Double) -> Double {
        var out = y
        if layerA.highlightRecovery > 0 {
            // 高光：把超過 diffuse white 的部分往回壓，壓的量由強度決定。
            let s = layerA.highlightRecovery
            if out > 0.5 {
                let over = out - 0.5
                out = 0.5 + over / (1 + s * over)
            }
        }
        if layerA.shadowRecovery > 0 {
            let s = layerA.shadowRecovery
            // 陰影：對低亮度做單調的抬升，不影響中間調以上。
            let t = 1.0 / (1.0 + pow(max(out, 0) / 0.06, 2.0))
            out += out * s * t
        }
        return out
    }

    /// §5 Perceptual Color Engine：OKLCH 下的 hue / chroma / lightness-aware mapping。
    private func perceptual(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let working = RGBColorSpace.workingRec2020
        // 負值與極小值在 OKLab 下仍有定義（cbrt 帶正負號），不需要先 clamp。
        let xyz = working.toXYZ(rgb)
        var lch = OKLab.toLCH(OKLab.fromXYZ(xyz))

        // 風格色彩接在技術校正後，並在使用者的基礎彩度與色彩控制之前。
        if film.hasColorEffect {
            lch = film.applyingColor(to: lch)
        }
        // Layer A 的基礎 chroma
        lch.y *= layerA.chroma
        // 色彩引擎動手之前的座標。split tone 的「這個像素夠中性嗎」必須依來源判斷，
        // 否則被高光保護壓掉彩度的像素會反過來被當成中性而染色。
        let source = lch

        if colorEngine.enabled {
            let skin = Self.skinWeight(hue: lch.z)
            let protection = 1.0 - skin * colorEngine.skinProtection

            // 色帶 hue / chroma mapping（§5.3）。控制點沿色相環等距，
            // 以週期性 Catmull-Rom 平滑內插；控制點全部相同時結果等於該值，
            // 所以預設參數下這一段是精確的 no-op。
            let hueShift = Self.hueCurve(colorEngine.hueShifts, hue: lch.z)
            let chromaBand = Self.hueCurve(colorEngine.chromaBands, hue: lch.z)

            // 亮度縮放：Δh 與「chroma 偏離 1 的量」各有一條隨亮度的縮放曲線。
            let hueScale = Self.lightnessCurve(colorEngine.hueShiftByLightness, lightness: lch.x)
            let chromaScale = Self.lightnessCurve(colorEngine.chromaByLightness, lightness: lch.x)

            lch.z = (lch.z + hueShift * hueScale * protection).truncatingRemainder(dividingBy: 360)
            if lch.z < 0 { lch.z += 360 }
            lch.y *= 1.0 + (chromaBand - 1.0) * chromaScale * protection
            lch.y *= 1.0 + (colorEngine.chromaStrength - 1.0) * protection

            // §5.3 Highlight color preservation：高亮度處收斂 chroma，
            // 讓高光不會因為某個通道先到頂而產生色偏。
            if lch.x > colorEngine.highlightProtectionStart {
                let over = (lch.x - colorEngine.highlightProtectionStart)
                    / max(1.0 - colorEngine.highlightProtectionStart, 1e-3)
                let w = min(over, 1.0)
                lch.y *= 1.0 - colorEngine.highlightProtection * w * w
            }

            // 灰階染色（split tone）：只加在低彩度區，避免把彩色物體整片染色。
            if !colorEngine.splitTone.isNeutral {
                lch = Self.applySplitTone(lch, colorEngine.splitTone, source: source)
            }
        }

        let outXYZ = OKLab.toXYZ(OKLab.fromLCH(lch))
        return working.fromXYZ(outXYZ)
    }

    /// 膚色帶權重：OKLCH 色相約 20°–70° 為膚色區，邊緣平滑過渡。
    static func skinWeight(hue: Double) -> Double {
        let center = 45.0, halfWidth = 25.0, feather = 15.0
        let d = abs(hueDelta(hue, center))
        if d <= halfWidth { return 1 }
        if d >= halfWidth + feather { return 0 }
        let t = (d - halfWidth) / feather
        return 1 - t * t * (3 - 2 * t)
    }

    /// 沿色相環等距分布的控制點，以週期性 Catmull-Rom 內插。
    ///
    /// 控制點數量由陣列長度決定（12 點 = 每 30°），所以舊的 6 點資料仍可直接求值。
    /// Catmull-Rom 的權重和恆為 1，控制點全部相同時輸出就是該值，不會有數值漂移。
    static func hueCurve(_ values: [Double], hue: Double) -> Double {
        let n = values.count
        guard n > 0 else { return 0 }
        guard n > 1 else { return values[0] }
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let pos = h / 360.0 * Double(n)
        let i = Int(pos.rounded(.down)) % n
        let t = pos - pos.rounded(.down)
        if n < 4 {
            return values[i] * (1 - t) + values[(i + 1) % n] * t
        }
        let p0 = values[(i - 1 + n) % n]
        let p1 = values[i]
        let p2 = values[(i + 1) % n]
        let p3 = values[(i + 2) % n]
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * p1
            + (-p0 + p2) * t
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
            + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }

    /// 亮度縮放曲線：節點位置為 `ColorEngineParameters.lightnessNodes`（scene OKLab L），
    /// 節點之間線性內插，兩端以端點值延伸。
    static func lightnessCurve(_ values: [Double], lightness l: Double) -> Double {
        guard let first = values.first else { return 1 }
        guard values.count > 1 else { return first }
        let nodes = ColorEngineParameters.lightnessNodes
        let positions: [Double] = nodes.count == values.count
            ? nodes
            : (0..<values.count).map { i in
                nodes[0] + (nodes[nodes.count - 1] - nodes[0])
                    * Double(i) / Double(values.count - 1)
            }
        if l <= positions[0] { return first }
        if l >= positions[positions.count - 1] { return values[values.count - 1] }
        for i in 1..<positions.count where l <= positions[i] {
            let span = max(positions[i] - positions[i - 1], 1e-9)
            let t = (l - positions[i - 1]) / span
            return values[i - 1] * (1 - t) + values[i] * t
        }
        return values[values.count - 1]
    }

    /// 在 OKLab 的 ab 平面上加入陰影 / 高光染色。
    ///
    /// 兩個權重相乘：亮度權重決定「陰影或高光」，低彩度權重確保只動接近中性的像素，
    /// 讓彩色物體不會被整片染色。
    static func applySplitTone(
        _ lch: SIMD3<Double>, _ s: SplitToneParameters, source: SIMD3<Double>
    ) -> SIMD3<Double> {
        let nodes = ColorEngineParameters.lightnessNodes
        let low = nodes[0], mid = nodes[2], high = nodes[nodes.count - 1]
        // 陰影權重在 L = 低節點時為 1、到中灰降為 0；高光權重相反。
        let shadowW = smoothFalloff((source.x - low) / max(mid - low, 1e-6))
        let highW = smoothFalloff((high - source.x) / max(high - mid, 1e-6))
        // 低彩度權重用「相對亮度的彩度」而不是絕對 chroma。絕對值會讓同一個彩色物體
        // 在變暗時逐漸被當成中性而被染色，曝光掃描時出現色相跳動。
        let relativeChroma = source.y / max(source.x, 0.25)
        let neutralW = exp(-pow(relativeChroma / 0.06, 2))
        guard neutralW > 1e-6 else { return lch }

        var a = lch.y * cos(lch.z * .pi / 180)
        var b = lch.y * sin(lch.z * .pi / 180)
        let sa = s.shadowAmount * shadowW * neutralW
        let ha = s.highlightAmount * highW * neutralW
        a += sa * cos(s.shadowHue * .pi / 180) + ha * cos(s.highlightHue * .pi / 180)
        b += sa * sin(s.shadowHue * .pi / 180) + ha * sin(s.highlightHue * .pi / 180)

        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return SIMD3(lch.x, (a * a + b * b).squareRoot(), h)
    }

    /// 0…1 的平滑遞減權重：t ≤ 0 時為 1，t ≥ 1 時為 0。
    private static func smoothFalloff(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return 1 - x * x * (3 - 2 * x)
    }

    private func luminance(_ rgb: SIMD3<Double>) -> Double {
        let m = RGBColorSpace.workingRec2020.toXYZ.m.transpose[1]
        return simd_dot(rgb, m)
    }

    private func scaleLuminance(_ rgb: SIMD3<Double>, from: Double, to: Double) -> SIMD3<Double> {
        guard abs(from) > 1e-9 else { return rgb }
        return rgb * (to / from)
    }
}

/// §3.1 Camera / Scene Normalization 的建構工具。
public enum SceneNormalization {
    /// 由色溫（K）推出 xy 色度。
    ///
    /// 4000K 以上走 CIE daylight locus（D 系列光源的定義，D65 會準確落在
    /// (0.3127, 0.3290)）；4000K 以下日光公式不適用，改用 Planckian locus 的
    /// Kim 近似。兩者在 4000K 附近足夠接近，不會有可見跳階。
    public static func chromaticity(temperature t: Double) -> SIMD2<Double> {
        let T = min(max(t, 1667), 25000)
        let T2 = T * T, T3 = T2 * T

        if T < 4000 {
            let x = -0.2661239e9 / T3 - 0.2343589e6 / T2 + 0.8776956e3 / T + 0.179910
            let y: Double = T < 2222
                ? -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
                : -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
            return SIMD2(x, y)
        }

        let x = T <= 7000
            ? -4.6070e9 / T3 + 2.9678e6 / T2 + 0.09911e3 / T + 0.244063
            : -2.0064e9 / T3 + 1.9018e6 / T2 + 0.24748e3 / T + 0.237040
        let y = -3.000 * x * x + 2.870 * x - 0.275
        return SIMD2(x, y)
    }

    /// 舊 sidecar 的 Illuminant preset 對應值。渲染流程已不再呼叫此方法；保留公開 API
    /// 只為避免既有整合在解碼舊設定時中斷，白平衡現在完全由 Layer A 決定。
    public static func preset(_ i: ColorEngineParameters.Illuminant) -> (temperature: Double, tint: Double)? {
        switch i {
        case .asShot: return nil
        case .daylight: return (5500, 0)
        case .shade: return (7500, 0.02)
        case .cloudy: return (6500, 0.01)
        case .tungsten: return (2850, 0)
        case .led: return (4600, -0.02)
        }
    }

    /// `tint` 的單位是 CIE xy 的 y 偏移（量級約 ±0.05），正值偏綠、負值偏洋紅。
    ///
    /// `CIRAWFilter.neutralTint` 用的是完全不同的刻度（量級約 ±150，正值偏洋紅），
    /// 直接餵進來會讓 xy 變成無意義的值、增益爆到 1e6，整張圖變全白。
    /// 所有從 RAW metadata 來的 tint 都必須先經過這裡換算。
    public static let filterTintPerChromaticityUnit: Double = 2000

    public static func chromaticityTint(filterTint t: Double) -> Double {
        -t / filterTintPerChromaticityUnit
    }

    /// 由目標色溫 / tint 推出 working space 下的白平衡增益。
    ///
    /// 增益以 working space 的參考白（D65）為錨點：色溫選在 D65 時增益恰為 1。
    /// 少了這個錨點，色溫公式本身的近似誤差會讓中性灰永遠帶一點色。
    public static func whiteBalanceGains(
        temperature: Double, tint: Double, working: RGBColorSpace = .workingRec2020
    ) -> SIMD3<Double> {
        gains(temperature: temperature, tint: tint,
              relativeTo: referenceWhite, working: working)
    }

    /// 相對於 as-shot 的白平衡增益。
    ///
    /// `CIRAWFilter` 已經套過 as-shot 白平衡，解碼輸出的中性物體本來就落在 D65。
    /// 所以這一層只能做「相對 as-shot 的偏移」：使用者沒調色溫時增益必須恰為 1，
    /// 否則等於對同一個光源修正兩次。
    public static func whiteBalanceGains(
        temperature: Double, tint: Double,
        asShotTemperature: Double, asShotTint: Double,
        working: RGBColorSpace = .workingRec2020
    ) -> SIMD3<Double> {
        let asShotXY = chromaticity(temperature: asShotTemperature)
        return gains(temperature: temperature, tint: tint,
                     relativeTo: SIMD2(asShotXY.x, asShotXY.y + asShotTint),
                     working: working)
    }

    private static func gains(
        temperature: Double, tint: Double,
        relativeTo anchor: SIMD2<Double>, working: RGBColorSpace
    ) -> SIMD3<Double> {
        func rawGains(_ xy: SIMD2<Double>) -> SIMD3<Double> {
            // y 太小或 x+y 超過 1 都不是合法色度，夾住以免後面除出天文數字。
            let y = min(max(xy.y, 0.05), 0.9)
            let x = min(max(xy.x, 0.05), 1.0 - y)
            let xyz = SIMD3(x / y, 1.0, (1.0 - x - y) / y)
            let rgb = working.fromXYZ(xyz)
            return SIMD3(1.0 / max(rgb.x, 1e-6), 1.0 / max(rgb.y, 1e-6), 1.0 / max(rgb.z, 1e-6))
        }
        let xy = chromaticity(temperature: temperature)
        let g = rawGains(SIMD2(xy.x, xy.y + tint)) / rawGains(anchor)
        // 正規化到綠通道，避免整體亮度被白平衡帶著跑。
        let n = g / g.y
        return SIMD3(min(max(n.x, 0.05), 20), 1.0, min(max(n.z, 0.05), 20))
    }

    /// Working space 的參考白（D65）。
    public static let referenceWhite = RGBColorSpace.d65
}

extension ColorMixerBand {
    /// 照片上點到的顏色（sRGB 編碼值 0…1）落在哪個色帶；權重最大者勝出。
    /// 彩度太低（近灰）時回傳 nil，避免在灰色區塊亂挑色帶（A-103 ⌖）。
    public static func dominant(sRGB encoded: SIMD3<Double>) -> ColorMixerBand? {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rgb = SIMD3(linear(encoded.x), linear(encoded.y), linear(encoded.z))
        let lch = OKLab.toLCH(OKLab.fromXYZ(RGBColorSpace.sRGB.toXYZ(rgb)))
        guard lch.y > 0.02 else { return nil }
        let weights = SceneTransform.colorMixerWeights(lch.z)
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[best] > 0 else { return nil }
        return allCases[best]
    }
}
