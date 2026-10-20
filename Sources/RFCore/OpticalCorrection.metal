#include <metal_stdlib>
using namespace metal;

// §2.3 Optical Renderer：由 Lensfun 提供係數，這裡自行以 Metal 執行。
//
// 座標一律正規化成「影像中心為原點、半對角線長度為 1」，與 Lensfun 係數的
// 定義一致。所有運算在 linear scene-referred 空間進行，不做 clamp（INV-1）。

struct OpticalParams {
    // distortion: 0=none 1=poly3 2=poly5 3=ptlens
    int   distortionKind;
    float da;
    float db;
    float dc;

    // tca: 0=none 1=linear 2=poly3
    int   tcaKind;
    float kr;
    float kb;
    float br;
    float bb;

    // vignetting: 0=none 1=pa
    int   vignKind;
    float vk1;
    float vk2;
    float vk3;

    float2 center;      // 像素座標中心
    float  invHalfDiag; // 1 / 半對角線長度（像素）
};

static inline float source_radius(constant OpticalParams &p, float rd) {
    float r2 = rd * rd;
    switch (p.distortionKind) {
        case 1: return rd * (1.0f - p.da + p.da * r2);
        case 2: return rd * (1.0f + p.da * r2 + p.db * r2 * r2);
        case 3: return rd * (p.da * r2 * rd + p.db * r2 + p.dc * rd
                             + 1.0f - p.da - p.db - p.dc);
        default: return rd;
    }
}

static inline float2 tca_scales(constant OpticalParams &p, float r) {
    switch (p.tcaKind) {
        case 1: return float2(p.kr, p.kb);
        case 2: {
            float r2 = r * r;
            return float2(p.kr + p.br * r2, p.kb + p.bb * r2);
        }
        default: return float2(1.0f, 1.0f);
    }
}

static inline float vignette_attenuation(constant OpticalParams &p, float r) {
    if (p.vignKind != 1) return 1.0f;
    float r2 = r * r;
    return 1.0f + p.vk1 * r2 + p.vk2 * r2 * r2 + p.vk3 * r2 * r2 * r2;
}

// Pass 1（早期）：暗角修正。不重新取樣，只調整亮度。
kernel void rf_vignetting(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant OpticalParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = src.read(gid);
    float2 d = (float2(gid) + 0.5f - p.center) * p.invHalfDiag;
    float att = vignette_attenuation(p, length(d));
    // 衰減趨近 0 時除法會爆掉，限制最大增益避免角落出現雜訊放大。
    float gain = 1.0f / max(att, 0.05f);
    dst.write(float4(c.rgb * gain, c.a), gid);
}

// 以雙線性取樣讀取來源，座標為「以中心為原點的正規化座標」。
static inline float sample_channel(
    texture2d<float, access::sample> src, sampler s,
    constant OpticalParams &p, float2 nd, int channel)
{
    float2 px = nd / p.invHalfDiag + p.center;
    float2 uv = px / float2(src.get_width(), src.get_height());
    float4 c = src.sample(s, uv);
    return c[channel];
}

// Pass 2（後期）：TCA + 幾何畸變，一次取樣完成。
kernel void rf_geometry(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::write>  dst [[texture(1)]],
    constant OpticalParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 d = (float2(gid) + 0.5f - p.center) * p.invHalfDiag;
    float rd = length(d);
    float2 dir = rd > 1e-6f ? d / rd : float2(0.0f, 0.0f);

    float ru = source_radius(p, rd);
    float2 tca = tca_scales(p, ru);

    float r = sample_channel(src, s, p, dir * (ru * tca.x), 0);
    float g = sample_channel(src, s, p, dir * ru, 1);
    float b = sample_channel(src, s, p, dir * (ru * tca.y), 2);
    float a = sample_channel(src, s, p, dir * ru, 3);

    dst.write(float4(r, g, b, a), gid);
}
