#pragma once
#include "Common.h"
#include "Noise.h"
#include "Clouds.h"

// 下雨：碎积云层（Clouds.h 的 DECK_*）里和下面在下雨。
//   远处：云底下面垂着一道道灰色的雨帘（主 pass 里沿视线积分），人在雨里时四周都发灰。
//   身边：几米内的雨丝。你往下掉得比雨快得多（55 m/s 对 8 m/s），所以雨丝是往上嗖嗖地掠过去。

/// 雨帘：沿视线在 1,500 ~ 3,200 米这一层里取 8 个点，按雨的分布（范围 × 高度 × 竖着拉长的噪声）积分消光，
/// 混进灰白的散射光。tMax 是视线碰到地面 / 海面的距离（没碰到给一个很大的数）。
/// 返回 rgb 散射进来的光，a 透射率（在云层 pass 里算：分辨率低，算好以后和云一起盖到天空和地形上）。
static inline float4 rainLayer(Ray r, float tMax, float jitter, constant FrameUniforms &F,
                               constant AtmosphereConstants &A, texture3d<float> noise) {
    float ch = r.origin.y, mu = r.direction.y;
    float off = F.world.y;                       // 云层整体抬高了多少，雨也跟着抬
    float tA, tB;
    if (abs(mu) < 1e-4f) {
        if (ch < 1500.0f + off || ch > 3200.0f + off) return float4(0.0f, 0.0f, 0.0f, 1.0f);
        tA = 0.0f;
        tB = 25000.0f;
    } else {
        float t1 = (1500.0f + off - ch) / mu, t2 = (3200.0f + off - ch) / mu;
        tA = max(min(t1, t2), 0.0f);
        tB = min(max(t1, t2), 25000.0f);
    }
    tB = min(tB, tMax);
    if (tB <= tA) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    // 粗筛：这一段的两头和中点都离雨区很远就不算了
    float2 o = r.origin.xz + F.ground.xz, d = r.direction.xz;
    float far = max(max(deckMask(o + d * tA), deckMask(o + d * tB)), deckMask(o + d * (0.5f * (tA + tB))));
    if (far < 0.01f && tB - tA < 6000.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);

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
        od += m * rainProfile(h - off) * saturate(n * 1.8f - 0.35f) * ds;
    }
    float T = exp(-od * 0.0007f);
    // 雨里的光：四面八方的天光被雨滴散开，灰白偏暗
    float3 rainLight = A.skyIrradianceSea.rgb / PI * 0.8f + A.sunAtCloudBase.rgb * 0.008f;
    return float4(rainLight * (1.0f - T), T);
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
    float along;       // 0 头（雨滴现在的位置）… 1 尾巴
    float sparkle;     // 这颗水珠亮不亮（大的、正好折射到亮处的闪一下）
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
    o.along = (vid >> 1u) != 0u ? 1.0f : 0.0f;
    float size = R.box.x;
    float3 seed = float3(pcg3d(uint3(iid, iid * 7u + 3u, 0x51u))) * (1.0f / 4294967296.0f);
    // 水珠有大有小：大多是一两毫米的小雨滴，少数三四毫米的大颗（更粗、更亮）
    float3 seed2 = float3(pcg3d(uint3(iid * 13u + 9u, iid, 0xA7u))) * (1.0f / 4294967296.0f);
    float drop = mix(0.0008f, 0.0038f, seed2.x * seed2.x * seed2.x);
    o.sparkle = (0.65f + 0.7f * seed2.y) * (seed2.z > 0.93f ? 2.6f : 1.0f) * mix(0.8f, 1.5f, drop / 0.0038f);
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
    // 按这颗水珠的粗细：画出来至少 1.4 个像素宽，细的部分折成透明度
    float trueWidth = drop * v.viewProjection[1][1] * halfVP.y / c.w;
    float width = max(trueWidth, 1.4f);
    o.position = c;
    o.position.xy += n * (o.across * width * 0.5f) / halfVP * c.w;
    o.alpha = fade * min(trueWidth / width * 2.5f, 1.0f) * (isTail ? 0.12f : 1.0f);
    return o;
}

fragment float4 rainFragment(RainOut in [[stage_in]],
                             constant FrameUniforms &F [[buffer(1)]],
                             constant AtmosphereConstants &A [[buffer(2)]],
                             constant RainUniforms &R [[buffer(3)]]) {
    // 头上是一颗亮的水珠，后面拖着越来越细的尾巴（运动模糊），中间一条亮芯（水珠把亮处折射过来）
    float taper = 1.0f - 0.7f * in.along;
    float core = saturate(1.0f - abs(in.across) / max(taper, 0.05f));
    float head = exp(-in.along * 9.0f);
    float a = in.alpha * (core * core * (0.6f + 0.9f * head)) * 0.55f * saturate(R.offset.w * 2.0f) * in.sparkle;
    // 雨滴把周围的天光（在云里是白亮的云光）折射、反射过来，有一点偏蓝
    float3 radiance = (A.skyIrradianceSea.rgb / PI * 2.2f + A.sunAtCloudBase.rgb * 0.03f) * float3(0.92f, 0.97f, 1.04f);
    float3 c = tonemap(radiance * F.exposure.x) * F.camera.z;
    return float4(c * a, 0.0f);     // 叠加上去
}

// MARK: - 身边的雾团

/// 在云里往下掉：一团团雾从脚下往上嗖嗖地掠过去，云越浓越多（按这团所在地方真的云密度算，晴的地方就没有）。
/// 一个实例 = 一个朝着眼睛、顺着相对速度拉长的方片（三角带 4 个顶点），在你周围一个盒子里循环（同雨丝）。
/// RainUniforms 复用：offset 累计位移 + 强度，velocity 空气相对你的速度 + 拉长时长，center 你的头 + 个数，box.x 盒子边长
struct MistOut {
    float4 position [[position]];
    float2 uv;           // -1..1，方片上的位置
    float alpha;
    float shade;         // 这团亮一点还是暗一点
    float seed;
};

vertex MistOut mistVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          ushort amp [[amplification_id]],
                          constant ViewUniforms *views [[buffer(0)]],
                          constant RainUniforms &R [[buffer(1)]],
                          constant FrameUniforms &F [[buffer(2)]],
                          texture2d<float> weather [[texture(0)]],
                          texture3d<float> baseNoise [[texture(1)]]) {
    MistOut o;
    float size = R.box.x;
    float3 seed = float3(pcg3d(uint3(iid * 3u + 1u, iid * 11u + 5u, 0x7Au))) * (1.0f / 4294967296.0f);
    float3 local = (fract(seed + R.offset.xyz / size) - 0.5f) * size;
    float3 center = R.center.xyz + local;
    float dist = length(local);
    // 离脸太近的不画（贴脸难受），盒子边上的淡掉
    float fade = smoothstep(1.5f, 4.0f, dist) * (1.0f - smoothstep(size * 0.3f, size * 0.47f, dist));
    // 这一团所在的地方有多少云：舞台按航向转到世界，再加上你在云坐标里的位置
    float3 w = rotateHeading(float3(center.x, 0.0f, center.z), F.heading.x, F.heading.y);
    float3 p = float3(w.x + F.ground.x, F.camera.x + center.y, w.z + F.ground.z);
    Weather wt = sampleWeather(p.xz, weather, F.world.y);
    float density = cloudDensity(p, wt, baseNoise, baseNoise, false, 0.0f);
    float a = fade * smoothstep(0.02f, 0.35f, density) * R.offset.w;
    o.uv = float2((vid & 1u) ? 1.0f : -1.0f, (vid >> 1u) ? 1.0f : -1.0f);
    if (a < 0.004f) {
        o.position = float4(0.0f, 0.0f, -2.0f, 1.0f);      // 在裁剪范围外，丢掉
        o.alpha = 0.0f;
        o.shade = 0.0f;
        o.seed = 0.0f;
        return o;
    }
    ViewUniforms v = views[amp];
    float3 toEye = normalize(v.cameraPosition.xyz - center);
    float speed = length(R.velocity.xyz);
    float3 along = speed > 0.1f ? R.velocity.xyz / speed : float3(0.0f, 1.0f, 0.0f);
    along -= dot(along, toEye) * toEye;
    along = length(along) > 1e-3f ? normalize(along) : normalize(cross(toEye, float3(1.0f, 0.0f, 0.0f)));
    float3 side = normalize(cross(along, toEye));
    float radius = mix(1.3f, 3.4f, seed.y);
    float stretch = 1.0f + min(speed * R.velocity.w, 2.2f);
    float3 pos = center + side * (o.uv.x * radius) + along * (o.uv.y * radius * stretch);
    o.position = v.viewProjection * float4(pos, 1.0f);
    o.alpha = a;
    o.shade = 0.85f + 0.4f * seed.z;
    o.seed = seed.x * 61.0f;
    return o;
}

fragment float4 mistFragment(MistOut in [[stage_in]],
                             constant FrameUniforms &F [[buffer(1)]],
                             constant AtmosphereConstants &A [[buffer(2)]]) {
    float r2 = dot(in.uv, in.uv);
    if (r2 >= 1.0f || in.alpha <= 0.0f) discard_fragment();
    // 软边 + 絮状（两层便宜的值噪声），不是一个个圆片
    float n = revealNoise(float3(in.uv * 2.3f, in.seed)) * 0.6f + revealNoise(float3(in.uv * 5.7f, in.seed + 3.7f)) * 0.4f;
    float a = in.alpha * smoothstep(1.0f, 0.1f, r2) * saturate(n * 1.7f - 0.3f) * 0.6f;
    // 云里四面八方都是被云散开的光：上面亮一点、下面暗一点；有的团亮、有的暗，才看得出一团团在动
    float3 L = A.skyIrradianceSea.rgb / PI * 0.95f + A.sunAtCloudBase.rgb * 0.03f;
    float3 c = tonemap(L * in.shade * (0.92f + 0.12f * in.uv.y) * F.exposure.x) * F.camera.z;
    return float4(c * a, a);
}

// MARK: - 自由落体路上的光环（JumpTimeline.rings）

/// 一个光环：立着的一圈发光的环，迎面过来，从中间穿过去。一张单位圆环的网格按实例放大、摆位置
struct RingInstance {
    float4 center;      // xyz 圆心（舞台空间），w 半径（米）
    float4 color;       // rgb 颜色，a 亮度
};

/// 单位圆环网格的管半径（半径为 1 时；和 SceneRenderer 里生成网格用的一致）
#define RING_TUBE 0.035f

struct RingOut {
    float4 position [[position]];
    float4 color;
    float rim;
};

vertex RingOut ringVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          ushort amp [[amplification_id]],
                          device const MeshVertex *vertices [[buffer(0)]],
                          constant ViewUniforms *views [[buffer(1)]],
                          device const RingInstance *rings [[buffer(2)]]) {
    MeshVertex v = vertices[vid];
    RingInstance r = rings[iid];
    float3 n = v.normal.xyz;
    float3 eye = views[amp].cameraPosition.xyz;
    // 环的中线上的点，再沿管的法线推出去；远了管子不到一个像素会闪，按距离加粗到一个多像素
    float3 line = r.center.xyz + (v.position.xyz - n * RING_TUBE) * r.center.w;
    float thick = max(RING_TUBE * r.center.w, length(line - eye) * 0.0014f);
    float3 p = line + n * thick;
    RingOut o;
    o.position = views[amp].viewProjection * float4(p, 1.0f);
    o.color = r.color;
    o.rim = 1.0f - abs(dot(n, normalize(eye - p)));
    return o;
}

/// 叠加上去的光（不影响 alpha）：中间亮、边上更亮一点，像一根发光的管子
fragment float4 ringFragment(RingOut in [[stage_in]],
                             constant FrameUniforms &F [[buffer(1)]]) {
    float3 c = in.color.rgb * (in.color.a * (0.4f + 0.6f * in.rim * in.rim));
    return float4(c * F.camera.z, 0.0f);
}

