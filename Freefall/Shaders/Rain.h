#pragma once
#include "Common.h"
#include "Noise.h"
#include "Clouds.h"

// 下雨：碎积云层（Clouds.h 的 DECK_*）里和下面在下雨。
//   远处：云底下面垂着一道道灰色的雨帘（主 pass 里沿视线积分），人在雨里时四周都发灰。
//   身边：几米内的雨丝。你往下掉得比雨快得多（55 m/s 对 8 m/s），所以雨丝是往上嗖嗖地掠过去。

/// 雨帘：沿视线在 1,500 ~ 3,200 米这一层里取 8 个点，按雨的分布（范围 × 高度 × 竖着拉长的噪声）积分消光，
/// 混进灰白的散射光。tMax 是视线碰到海面的距离（没碰到给一个很大的数）。
static inline float3 rainCurtains(float3 color, Ray r, float tMax, float jitter, constant FrameUniforms &F,
                                  constant AtmosphereConstants &A, texture3d<float> noise) {
    float ch = r.origin.y, mu = r.direction.y;
    float tA, tB;
    if (abs(mu) < 1e-4f) {
        if (ch < 1500.0f || ch > 3200.0f) return color;
        tA = 0.0f;
        tB = 25000.0f;
    } else {
        float t1 = (1500.0f - ch) / mu, t2 = (3200.0f - ch) / mu;
        tA = max(min(t1, t2), 0.0f);
        tB = min(max(t1, t2), 25000.0f);
    }
    tB = min(tB, tMax);
    if (tB <= tA) return color;
    // 粗筛：这一段的两头和中点都离雨区很远就不算了
    float2 o = r.origin.xz + F.ground.xz, d = r.direction.xz;
    float far = max(max(deckMask(o + d * tA), deckMask(o + d * tB)), deckMask(o + d * (0.5f * (tA + tB))));
    if (far < 0.01f && tB - tA < 6000.0f) return color;

    const int N = 8;
    float ds = (tB - tA) / float(N);
    float od = 0.0f;
    for (int i = 0; i < N; i++) {
        float t = tA + (float(i) + jitter) * ds;
        float2 c = o + d * t;
        float m = deckMask(c);
        if (m < 0.01f) continue;
        float h = ch + mu * t;
        // 雨帘：竖着拉得很长的噪声（一道道雨柱），慢慢往下移
        float n = noise.sample(linearRepeat, float3(c.x / 300.0f, h / 2600.0f + F.camera.y * 0.003f, c.y / 300.0f),
                               level(0)).r;
        od += m * rainProfile(h) * saturate(n * 1.8f - 0.35f) * ds;
    }
    float T = exp(-od * 0.0007f);
    // 雨里的光：四面八方的天光被雨滴散开，灰白偏暗
    float3 rainLight = A.skyIrradianceSea.rgb / PI * 0.8f + A.sunAtCloudBase.rgb * 0.008f;
    return color * T + rainLight * (1.0f - T);
}

/// 和 Swift 的 RainUniforms 一样
struct RainUniforms {
    float4 offset;     // xyz 雨相对你累计走过的距离（舞台空间，米，已按盒子取模），w 强度 0..1
    float4 velocity;   // xyz 雨相对你的速度（舞台空间，m/s），w 拖影时长（秒）
    float4 center;     // xyz 盒子中心（舞台空间，你的头），w 雨丝总数
    float4 box;        // x 盒子边长（米）
};

struct RainOut {
    float4 position [[position]];
    float alpha;
    float across;      // -1..1，横过雨丝，做软边
};

/// 一根雨丝 = 一个实例的 4 个顶点（三角带）：头（雨滴现在的位置）和尾（往相对速度反方向拖一帧的距离），
/// 在屏幕上往两边各扩半个线宽。雨丝在你周围一个盒子里循环：位置 = 随机种子 + 累计位移，按盒子取模。
vertex RainOut rainVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          ushort amp [[amplification_id]],
                          constant ViewUniforms *views [[buffer(0)]],
                          constant RainUniforms &R [[buffer(1)]]) {
    RainOut o;
    o.across = (vid & 1u) ? 1.0f : -1.0f;
    float size = R.box.x;
    float3 seed = float3(pcg3d(uint3(iid, iid * 7u + 3u, 0x51u))) * (1.0f / 4294967296.0f);
    float3 local = (fract(seed + R.offset.xyz / size) - 0.5f) * size;
    float3 head = R.center.xyz + local;
    float3 tail = head - R.velocity.xyz * R.velocity.w;
    // 离眼睛太近（贴脸看着难受）和盒子边上的淡掉，免得突然出现
    float dist = length(local);
    float fade = smoothstep(0.45f, 1.2f, dist) * (1.0f - smoothstep(size * 0.3f, size * 0.47f, dist));

    ViewUniforms v = views[amp];
    float4 ca = v.viewProjection * float4(head, 1.0f);
    float4 cb = v.viewProjection * float4(tail, 1.0f);
    if (ca.w < 0.1f || cb.w < 0.1f || fade <= 0.0f) {
        o.position = float4(0.0f, 0.0f, -2.0f, 1.0f);     // 在裁剪范围外，丢掉
        o.alpha = 0.0f;
        return o;
    }
    float2 halfVP = v.viewport.zw * 0.5f;
    float2 dir = cb.xy / cb.w * halfVP - ca.xy / ca.w * halfVP;
    float len = length(dir);
    dir = len > 1e-3f ? dir / len : float2(0.0f, 1.0f);
    float2 n = float2(-dir.y, dir.x);
    bool isTail = (vid >> 1u) != 0u;
    float4 c = isTail ? cb : ca;
    // 雨滴约 2 毫米粗：画出来至少 1.4 个像素宽，细的部分折成透明度
    float trueWidth = 0.002f * v.viewProjection[1][1] * halfVP.y / c.w;
    float width = max(trueWidth, 1.4f);
    o.position = c;
    o.position.xy += n * (o.across * width * 0.5f) / halfVP * c.w;
    o.alpha = fade * min(trueWidth / width * 2.5f, 1.0f) * (isTail ? 0.15f : 1.0f);
    return o;
}

fragment float4 rainFragment(RainOut in [[stage_in]],
                             constant FrameUniforms &F [[buffer(1)]],
                             constant AtmosphereConstants &A [[buffer(2)]],
                             constant RainUniforms &R [[buffer(3)]]) {
    float a = in.alpha * (1.0f - in.across * in.across) * 0.6f * saturate(R.offset.w * 2.0f);
    // 雨滴把周围的天光（在云里是白亮的云光）折射、反射过来
    float3 radiance = A.skyIrradianceSea.rgb / PI * 2.2f + A.sunAtCloudBase.rgb * 0.03f;
    float3 c = acesFitted(radiance * F.exposure.x) * F.camera.z;
    return float4(c * a, 0.0f);     // 叠加上去
}
