#include <metal_stdlib>
using namespace metal;

// 把 CPU 端烘焙好的 3D LUT 套到影像上。
//
// LUT 的輸入軸是「log2 shaper 空間」而不是線性空間：scene-referred 值的動態範圍
// 遠大於 [0,1]，直接用線性軸會讓陰影只剩下幾個取樣點。shaper 在這裡即時計算，
// 所以 pipeline 仍然吃得到 extended range 的輸入（INV-1）。

struct LUTParams {
    float shaperLo;    // 以 0.18 中灰為基準的最低 stop
    float shaperHi;    // 最高 stop
    float lutSize;     // 每軸取樣數
};

static inline float3 shaper_encode(float3 v, constant LUTParams &p) {
    float3 s = max(v, float3(1e-6f));
    float3 e = (log2(s / 0.18f) - p.shaperLo) / (p.shaperHi - p.shaperLo);
    return clamp(e, 0.0f, 1.0f);
}

kernel void rf_apply_lut(
    texture2d<float, access::read>   src [[texture(0)]],
    texture2d<float, access::write>  dst [[texture(1)]],
    texture3d<float, access::sample> lut [[texture(2)]],
    constant LUTParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float4 c = src.read(gid);
    float3 e = shaper_encode(c.rgb, p);
    // 取樣點位於格點中心，先把 [0,1] 映射到 [0.5/N, 1-0.5/N]。
    float3 uvw = (e * (p.lutSize - 1.0f) + 0.5f) / p.lutSize;
    float3 out = lut.sample(s, uvw).rgb;
    dst.write(float4(out, c.a), gid);
}
