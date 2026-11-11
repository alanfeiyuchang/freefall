#include "Common.h"
#include "Noise.h"
#include "Atmosphere.h"
#include "Clouds.h"
#include "Objects.h"
#include "Rain.h"

// 每帧：
//   1. computeSkyViewLUT     — 按你现在的高度重算天空视图表（192×108，很便宜）
//   2. cloudFragment         — 半分辨率的云层 pass：每个像素沿视线步进体积云，输出（散射光，透射率）和深度
//   3. sceneFragment         — 全分辨率：天空 / 太阳 / 海面，再把云层放大盖上去，曝光、色调映射、抖动
//   4. hudVertex/Fragment    — 高度表面板
// 启动时一次：噪声纹理、天气图、云影图、透射率表、多次散射表、海平面天空表、大气常量。
// 双眼靠 vertex amplification 一次画完；有注视点渲染时 [[position]] 是压缩过的物理坐标，先用 rate map 换回屏幕坐标。

vertex VOut fullscreenVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2) 盖住整个屏幕
    VOut o;
    o.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    o.viewIndex = amp;
    return o;
}

/// 天空 pass：深度固定在极远处（reverse-Z：0 是无穷远；不能写 0，系统会当成没有内容），
/// 深度测试只让它填地形没盖住的像素（地形先画）。必须比最远的地形（几百公里，深度 ~1e-7）还远，
/// 之前给的 1e-5 只相当于 5 公里，远山全被天空盖掉了。
vertex VOut skyVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2.0f - 1.0f, 1e-10f, 1.0f);
    o.viewIndex = amp;
    return o;
}

// MARK: - 启动时生成的纹理

kernel void generateBaseNoise(texture3d<float, access::write> out [[texture(0)]],
                              uint3 gid [[thread_position_in_grid]]) {
    uint n = out.get_width();
    if (any(gid >= uint3(n))) return;
    float3 uvw = (float3(gid) + 0.5f) / float(n);
    float perlin = perlinFbm(uvw * 4.0f, 4, 4, 11u);
    float w1 = 1.0f - worley3(uvw * 4.0f, 4, 101u);
    float w2 = 1.0f - worley3(uvw * 8.0f, 8, 102u);
    float w3 = 1.0f - worley3(uvw * 16.0f, 16, 103u);
    float w4 = 1.0f - worley3(uvw * 32.0f, 32, 104u);
    float fbm0 = w1 * 0.625f + w2 * 0.25f + w3 * 0.125f;
    float fbm1 = w2 * 0.625f + w3 * 0.25f + w4 * 0.125f;
    float fbm2 = w3 * 0.75f + w4 * 0.25f;
    float perlinWorley = remap(perlin, 0.0f, 1.0f, fbm0, 1.0f);
    out.write(float4(perlinWorley, fbm0, fbm1, fbm2), gid);
}

kernel void generateDetailNoise(texture3d<float, access::write> out [[texture(0)]],
                                uint3 gid [[thread_position_in_grid]]) {
    uint n = out.get_width();
    if (any(gid >= uint3(n))) return;
    float3 uvw = (float3(gid) + 0.5f) / float(n);
    float w1 = 1.0f - worley3(uvw * 2.0f, 2, 201u);
    float w2 = 1.0f - worley3(uvw * 4.0f, 4, 202u);
    float w3 = 1.0f - worley3(uvw * 8.0f, 8, 203u);
    float w4 = 1.0f - worley3(uvw * 16.0f, 16, 204u);
    out.write(float4(w1 * 0.625f + w2 * 0.25f + w3 * 0.125f,
                     w2 * 0.625f + w3 * 0.25f + w4 * 0.125f,
                     w3 * 0.75f + w4 * 0.25f, 1.0f), gid);
}

/// 天气图：一张平铺 64 km 的图，原点（起跳点）在图中心。
kernel void generateWeather(texture2d<float, access::write> out [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    float2 uv = (float2(gid) + 0.5f) / float2(size);
    float2 xz = (uv - 0.5f) * WEATHER_TILE;

    // 云团的疏密（十几公里一片）
    float cluster = perlinFbm(float3(uv * 4.0f, 0.5f), 4, 4, 31u);
    // 小积云（一朵 1~2 km，顶 2~3 km）和大积云（一朵 3~4 km，顶 3~4.5 km，少数长成 6~8 km 的高塔）。
    // 每朵的云顶是半球形的高度场（中心最高），云体内部覆盖率差不多一样（0.75 上下，不到 1）：
    // 表面的花椰菜起伏交给形状噪声去啃。覆盖率给到 1 的话噪声就没地方下嘴，会变成光滑的塑料柱。
    float2 cs = worley2Cell(uv * 40.0f, 40, 41u);
    float2 cm = worley2Cell(uv * 16.0f, 16, 43u);
    float rs = saturate(cs.x * 1.6f), rm = saturate(cm.x * 1.35f);
    float smallDome = sqrt(1.0f - rs * rs);
    float mediumDome = sqrt(1.0f - rm * rm);
    float smallOn = smoothstep(0.30f, 0.62f, cluster) * step(0.2f, cs.y);
    float mediumOn = smoothstep(0.52f, 0.78f, cluster);
    float coverage = max(smoothstep(0.0f, 0.35f, smallDome) * smallOn * 0.72f,
                         smoothstep(0.0f, 0.35f, mediumDome) * mediumOn * 0.78f);
    float tall = step(0.93f, cm.y) * smoothstep(0.58f, 0.78f, cluster);
    float top = max((0.07f + 0.12f * cs.y) * smallDome * smallOn,
                    (0.17f + 0.2f * cm.y + 0.3f * tall) * mediumDome * mediumOn);
    float base = 0.13f + 0.05f * cluster;
    float columnar = 0.0f;   // 只有下面特意摆的那座大塔是柱状的；天然长高的还是圆顶，不然远看像墓碑

    // 起跳点附近 4 km 内少一点云，往下看得到海
    coverage *= mix(1.0f, 0.35f, exp(-dot(xz, xz) / (4000.0f * 4000.0f)));

    // 左前方一座大积云塔（浓积云）：下落的前半段你会从它旁边经过
    float dTower = length(xz - float2(-1300.0f, -1900.0f));
    float tower = smoothstep(1900.0f, 800.0f, dTower);
    coverage = max(coverage, tower * 0.8f);
    top = max(top, sqrt(saturate(1.0f - (dTower / 2100.0f) * (dTower / 2100.0f))) * 0.88f);
    columnar = max(columnar, tower);

    // 左边一层会下雨的碎积云：大约 3,200 → 2,400 米，沿航线拉长（见 Clouds.h 的 DECK_*），下落时会穿过它；
    // 开伞后往靶飞就离开它的下面，着陆区是晴的
    float deck = deckMask(xz);
    float inDeck = smoothstep(0.15f, 0.55f, deck);
    coverage = max(coverage, deck * 0.72f);
    top = mix(top, 0.24f, inDeck);
    base = mix(base, 0.56f, inDeck);
    columnar *= 1.0f - inDeck;

    out.write(float4(coverage, top, base, columnar), gid);
}

/// 环礁图：r 陆地（沙洲），g 水深（归一化，深度 = ATOLL_MAX_DEPTH × g²），b 植被，a 礁缘的白浪。
/// 环礁是一圈珊瑚礁围着潟湖，礁上零星长着小沙洲（motu），都只高出海面几米，所以按平的画就对了。
kernel void generateAtoll(texture2d<float, access::write> out [[texture(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    float2 uv = (float2(gid) + 0.5f) / float2(size);
    float2 p = (uv - 0.5f) * ATOLL_SIZE;
    float r = length(p);
    float angle = atan2(p.y, p.x);

    // 礁环：略扁、半径随方向起伏
    float wobble = perlinFbm(float3(cos(angle) * 1.5f + 2.0f, sin(angle) * 1.5f + 2.0f, 0.3f), 4, 3, 71u) - 0.5f;
    float radius = 3600.0f * (1.0f + 0.10f * cos(2.0f * angle + 0.7f) + 0.16f * wobble);
    float ring = r - radius;                          // < 0 在潟湖里
    float n1 = perlinFbm(float3(uv * 24.0f, 0.5f), 24, 4, 73u);   // 670 m 起的细节
    float n2 = perlinFbm(float3(uv * 64.0f, 0.5f), 64, 3, 79u);   // 250 m 起的细节

    // 水深（米）：外海 → 礁坡陡降，礁顶几乎贴着水面，潟湖 5~35 米，中间有零星的珊瑚丘
    float reefHalfWidth = 230.0f + 140.0f * n1;
    float onReef = 1.0f - smoothstep(reefHalfWidth * 0.6f, reefHalfWidth, abs(ring + 60.0f));
    float lagoonDepth = mix(6.0f, 34.0f, smoothstep(-200.0f, -1800.0f, ring)) * (0.7f + 0.6f * n2);
    float patchReef = smoothstep(0.72f, 0.78f, n2) * smoothstep(-300.0f, -900.0f, ring);
    lagoonDepth = mix(lagoonDepth, 1.5f, patchReef);
    float outerDepth = mix(3.0f, ATOLL_MAX_DEPTH, smoothstep(0.0f, 700.0f, ring));
    float depth = ring < 0.0f ? lagoonDepth : outerDepth;
    depth = mix(depth, 0.6f + 1.5f * n2, onReef);

    // 沙洲：沿礁顶断断续续的一串。用平滑的场（礁顶的核心带 × 二维噪声）取等值线，边缘才是圆的；
    // 场再高一点的地方长椰林，外面留一圈白沙滩。
    float core = 1.0f - smoothstep(0.0f, reefHalfWidth * 0.55f, abs(ring + 50.0f));
    float n3 = perlinFbm(float3(uv * 40.0f, 0.9f), 40, 3, 83u);
    float motuField = core * (0.35f + 0.9f * n3);
    float motu = smoothstep(0.62f, 0.66f, motuField);
    float vegetation = smoothstep(0.70f, 0.76f, motuField);
    // 白浪：礁的外缘，一段一段的
    float surf = smoothstep(70.0f, 10.0f, abs(ring - reefHalfWidth * 0.75f + 30.0f))
               * smoothstep(0.35f, 0.65f, n2) * (1.0f - motu);

    out.write(float4(motu, sqrt(saturate(depth / ATOLL_MAX_DEPTH)), vegetation, surf), gid);
}

/// 云顶上限图：每个格子（250 m）周围约 1.6 km 内最高的云顶（归一化，同天气图的 g）。
/// 步进时视线如果还在这一带所有云顶之上，就可以大步跳过去（高空往下看时大半段都是空的）。
kernel void computeCloudTopMax(texture2d<float, access::write> out [[texture(0)]],
                               texture2d<float> weather [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    int2 src = int2(weather.get_width(), weather.get_height());
    int scale = src.x / int(size.x);
    int2 center = int2(gid) * scale + scale / 2;
    float top = 0.0f;
    for (int dy = -14; dy <= 14; dy++) {
        for (int dx = -14; dx <= 14; dx++) {
            int2 q = ((center + int2(dx, dy)) % src + src) % src;   // 平铺
            float4 w = weather.read(uint2(q));
            if (w.r > 0.002f) top = max(top, w.g);
        }
    }
    out.write(float4(top, 0.0f, 0.0f, 0.0f), gid);
}

/// 云影图：海面每一点朝太阳方向穿过云层的光学深度（密度 × 米）。云和太阳都不动，启动时算一次。
kernel void computeCloudShadow(texture2d<float, access::write> out [[texture(0)]],
                               texture3d<float> baseTex [[texture(1)]],
                               texture2d<float> weather [[texture(2)]],
                               constant float4 &sun [[buffer(0)]],
                               constant float &offset [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    float2 xz = ((float2(gid) + 0.5f) / float2(size) - 0.5f) * WEATHER_TILE;
    float3 s = sun.xyz;
    float sMin = (CLOUD_MIN_H + offset) / s.y, sMax = (CLOUD_MAX_H + offset) / s.y;
    const int N = 40;
    float ds = (sMax - sMin) / float(N);
    float od = 0.0f;
    for (int i = 0; i < N; i++) {
        float d = sMin + (float(i) + 0.5f) * ds;
        float3 p = float3(xz.x + s.x * d, s.y * d, xz.y + s.z * d);
        od += cloudDensity(p, sampleWeather(p.xz, weather, offset), baseTex, baseTex, false, 0.0f) * ds;
    }
    out.write(float4(od, 0.0f, 0.0f, 0.0f), gid);
}

kernel void computeTransmittanceLUT(texture2d<float, access::write> out [[texture(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= TRANSMITTANCE_W || gid.y >= TRANSMITTANCE_H) return;
    float2 uv = (float2(gid) + 0.5f) / float2(TRANSMITTANCE_W, TRANSMITTANCE_H);
    const float H = sqrt(ATM_TOP * ATM_TOP - ATM_BOTTOM * ATM_BOTTOM);
    float rho = H * uv.y;
    float r = sqrt(rho * rho + ATM_BOTTOM * ATM_BOTTOM);
    float dMin = ATM_TOP - r, dMax = rho + H;
    float d = dMin + uv.x * (dMax - dMin);
    float mu = d == 0.0f ? 1.0f : clamp((H * H - rho * rho - d * d) / (2.0f * r * d), -1.0f, 1.0f);
    float3 ro = float3(0.0f, r, 0.0f);
    float3 rd = float3(sqrt(max(0.0f, 1.0f - mu * mu)), mu, 0.0f);
    float tMax = raySphereNearest(ro, rd, ATM_TOP);
    const int N = 40;
    float dt = tMax / float(N);
    float3 od = 0.0f;
    for (int i = 0; i < N; i++) {
        float3 P = ro + rd * ((float(i) + 0.5f) * dt);
        od += sampleMedium(length(P) - ATM_BOTTOM).extinction * dt;
    }
    out.write(float4(exp(-od), 1.0f), gid);
}

kernel void computeMultiScatLUT(texture2d<float, access::write> out [[texture(0)]],
                                texture2d<float> transLUT [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= MULTISCAT_RES || gid.y >= MULTISCAT_RES) return;
    float2 uv = (float2(gid) + 0.5f) / float(MULTISCAT_RES);
    uv = float2(fromSubUvsToUnit(uv.x, MULTISCAT_RES), fromSubUvsToUnit(uv.y, MULTISCAT_RES));
    float cosSunZenith = uv.x * 2.0f - 1.0f;
    float3 sunDir = float3(sqrt(saturate(1.0f - cosSunZenith * cosSunZenith)), cosSunZenith, 0.0f);
    float viewHeight = ATM_BOTTOM + saturate(uv.y + 0.01f) * (ATM_TOP - ATM_BOTTOM - 0.01f);
    float3 ro = float3(0.0f, viewHeight, 0.0f);
    float3 Lsum = 0.0f, fmsSum = 0.0f;
    const int SQ = 8;
    for (int i = 0; i < SQ; i++) {
        for (int j = 0; j < SQ; j++) {
            float theta = 2.0f * PI * (float(i) + 0.5f) / float(SQ);
            float phi = acos(1.0f - 2.0f * (float(j) + 0.5f) / float(SQ));
            float3 rd = float3(cos(theta) * sin(phi), cos(phi), sin(theta) * sin(phi));
            ScatterResult s = integrateScattering(ro, rd, sunDir, 20, true, false, false, false, transLUT, transLUT);
            Lsum += s.L;
            fmsSum += s.multiScatAs1;
        }
    }
    float inv = 1.0f / float(SQ * SQ);
    out.write(float4(Lsum * inv / (1.0f - fmsSum * inv), 1.0f), gid);
}

kernel void computeAtmosphereConstants(device AtmosphereConstants &out [[buffer(0)]],
                                       constant float4 &sun [[buffer(1)]],
                                       texture2d<float> transLUT [[texture(0)]],
                                       texture2d<float> msLUT [[texture(1)]],
                                       uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    float3 s = sun.xyz;
    out.sunAtCloudBase = float4(transmittanceToTop(transLUT, ATM_BOTTOM + 1.0f, s.y), 1.0f);
    out.sunAtCloudTop = float4(transmittanceToTop(transLUT, ATM_BOTTOM + 9.0f, s.y), 1.0f);
    out.sunAtSea = float4(transmittanceToTop(transLUT, ATM_BOTTOM + 0.001f, s.y), 1.0f);
    float3 avg = 0.0f, irradiance = 0.0f;
    const int NE = 4, NA = 8;
    for (int e = 0; e < NE; e++) {
        for (int a = 0; a < NA; a++) {
            float cosZ = (float(e) + 0.5f) / float(NE);   // 上半球按立体角均匀
            float sinZ = sqrt(1.0f - cosZ * cosZ);
            float phi = 2.0f * PI * (float(a) + 0.5f) / float(NA);
            float3 rd = float3(sinZ * cos(phi), cosZ, sinZ * sin(phi));
            avg += integrateScattering(float3(0.0f, ATM_BOTTOM + 3.0f, 0.0f), rd, s, 24,
                                       false, true, true, true, transLUT, msLUT).L;
            irradiance += integrateScattering(float3(0.0f, ATM_BOTTOM + 0.002f, 0.0f), rd, s, 24,
                                              false, true, true, true, transLUT, msLUT).L * cosZ;
        }
    }
    float n = float(NE * NA);
    out.skyRadianceAvg = float4(avg / n, 1.0f);
    out.skyIrradianceSea = float4(irradiance * (2.0f * PI / n), 1.0f);
    float3 seaE = out.sunAtSea.rgb * max(s.y, 0.0f) + out.skyIrradianceSea.rgb;
    out.groundBounce = float4(0.06f * seaE / PI, 1.0f);
}

kernel void computeSkyViewLUT(texture2d<float, access::write> out [[texture(0)]],
                              texture2d<float> transLUT [[texture(1)]],
                              texture2d<float> msLUT [[texture(2)]],
                              constant float4 &sun [[buffer(0)]],
                              constant float &viewHeight [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= SKYVIEW_W || gid.y >= SKYVIEW_H) return;
    float2 uv = (float2(gid) + 0.5f) / float2(SKYVIEW_W, SKYVIEW_H);
    float viewZenithCos, lightViewCos;
    skyViewParams(uv, viewHeight, viewZenithCos, lightViewCos);
    // 表里太阳固定在 +x 方向，只保留它的天顶角
    float sunZenithCos = sun.y;
    float3 sunDir = float3(sqrt(saturate(1.0f - sunZenithCos * sunZenithCos)), sunZenithCos, 0.0f);
    float viewZenithSin = sqrt(saturate(1.0f - viewZenithCos * viewZenithCos));
    float3 rd = float3(viewZenithSin * lightViewCos, viewZenithCos,
                       viewZenithSin * sqrt(saturate(1.0f - lightViewCos * lightViewCos)));
    ScatterResult s = integrateScattering(float3(0.0f, viewHeight, 0.0f), rd, sunDir, 32,
                                          false, true, true, true, transLUT, msLUT);
    out.write(float4(s.L, 1.0f), gid);
}

// MARK: - 云层：时间累积
//
// 云层的分辨率是实际渲染分辨率 × F.clouds.x（0.5），而且每帧只重算其中四分之一：2×2 的块里轮流算一个像素
// （cloudFreshFragment，画在四分之一大小的纹理上），其余三个从上一帧的结果重投影过来（cloudResolveFragment）。
// 每帧的起步抖动也跟着换，累积几帧以后步进的分层/抖动纹就被平均掉了——不累积的话固定抖动会在云上显成一层纱窗纹。
// 重投影：用这一块刚算出来的云深度把像素还原成世界里的点，投到上一帧的视图里取历史；
// 历史再夹到这一帧周围新算的 3×3 个样本的范围里，防止下落太快、新云出现时拖影。

struct CloudOut {
    float4 color [[color(0)]];   // rgb 散射光（已含空气透视），a 透射率
    float depth [[color(1)]];    // 公里
};

fragment CloudOut cloudFreshFragment(VOut in [[stage_in]],
                                     constant ViewUniforms *views [[buffer(0)]],
                                     constant FrameUniforms &F [[buffer(1)]],
                                     constant rasterization_rate_map_data &rateMap [[buffer(2)]],
                                     constant AtmosphereConstants &A [[buffer(3)]],
                                     constant TemporalUniforms &TU [[buffer(4)]],
                                     texture2d<float> transLUT [[texture(0)]],
                                     texture2d<float> skyLUT [[texture(1)]],
                                     texture3d<float> baseTex [[texture(2)]],
                                     texture3d<float> detailTex [[texture(3)]],
                                     texture2d<float> weather [[texture(4)]],
                                     texture2d<float> msLUT [[texture(5)]],
                                     texture2d<float> topMax [[texture(6)]],
                                     depth2d_array<float> terrainDepth [[texture(7)]]) {
    // 这个片元负责云层纹理里的哪个像素
    float2 pixel = floor(in.position.xy) * 2.0f + TU.pattern.xy;
    float2 physical = (pixel + 0.5f) / F.clouds.x;
    float2 screen = screenPosition(physical, in.viewIndex, F.camera.w > 0.5f, rateMap);
    Ray r = worldRay(screen, views[in.viewIndex], F);

    CloudMaps maps;
    maps.base = baseTex;
    maps.detail = detailTex;
    maps.weather = weather;
    maps.topMax = topMax;
    maps.offset = F.world.y;
    maps.landShift = F.ground.yw;
    maps.scene = int(F.world.x + 0.5f);
    maps.time = F.camera.y;
    maps.terrainDistance = 1e9f;
    if (F.exposure.y > 0.5f) {
        // 地形深度（全分辨率、和主 pass 一样按 rate map 光栅化）→ 舞台里的点 → 到眼睛的距离
        uint2 size = uint2(terrainDepth.get_width(), terrainDepth.get_height());
        float d = terrainDepth.read(min(uint2(physical), size - 1u), in.viewIndex);
        if (d > 0.0f) {
            constant ViewUniforms &v = views[in.viewIndex];
            float2 uv = (screen - v.viewport.xy) / v.viewport.zw;
            float4 q = v.inverseViewProjection * float4(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f, d, 1.0f);
            maps.terrainDistance = length(q.xyz / q.w - v.cameraPosition.xyz);
        }
    }
    float jitter = ign(pixel + TU.pattern.z * 5.588238f);   // IGN 的帧间偏移，几帧就能把抖动平均掉
#ifdef PROFILE_SKIP_MARCH
    CloudHit h; h.radiance = 0.0f; h.transmittance = 1.0f; h.depth = 0.0f;
#else
    CloudHit h = marchClouds(r.origin, r.direction, jitter, F, A, maps);
#endif

    // 空气透视：从你到云（按不透明度加权的平均距离）这一段，沿视线积 6 步散射。
    // 只依赖这一段路径，地平线上下是连续的。
    if (h.transmittance < 0.999f) {
        float3 roKm = float3(0.0f, ATM_BOTTOM + max(r.origin.y, 1.0f) * 0.001f, 0.0f);
        ScatterResult ap = integrateScattering(roKm, r.direction, F.sunDirection.xyz, 6, false, true, true, true,
                                               transLUT, msLUT, h.depth * 0.001f);
        h.radiance = h.radiance * ap.transmittance + ap.L * (1.0f - h.transmittance);
    }

    // 雨帘（视线碰到地形 / 海面之前的那一段）：当成在云前面的一层，一起盖上去
    float rainMax = maps.terrainDistance;
    float2 seaHit = sphereHits(r.origin.y, r.direction.y, 0.0f);
    if (seaHit.x > 0.0f) rainMax = min(rainMax, seaHit.x);
    float4 rain = rainLayer(r, rainMax, jitter, F, A, baseTex);
    h.radiance = rain.rgb + rain.a * h.radiance;
    h.transmittance *= rain.a;

    CloudOut o;
    o.color = float4(h.radiance, h.transmittance);
    o.depth = h.depth * 0.001f;
#ifdef DEBUG_TERRAIN_DEPTH
    // 调试：地形距离（红 = 近，绿 = 远，蓝 = 没读到地形）
    o.color = maps.terrainDistance < 1e8f ? float4(saturate(1.0f - maps.terrainDistance / 5000.0f),
                                                    saturate(maps.terrainDistance / 20000.0f), 0.0f, 0.0f)
                                           : float4(0.0f, 0.0f, 1.0f, 0.0f);
#endif
    return o;
}

fragment CloudOut cloudResolveFragment(VOut in [[stage_in]],
                                       constant ViewUniforms *views [[buffer(0)]],
                                       constant FrameUniforms &F [[buffer(1)]],
                                       constant rasterization_rate_map_data &rateMap [[buffer(2)]],
                                       constant ViewUniforms *prevViews [[buffer(3)]],
                                       constant TemporalUniforms &TU [[buffer(4)]],
                                       constant rasterization_rate_map_data &prevRateMap [[buffer(5)]],
                                       texture2d_array<float> fresh [[texture(0)]],
                                       texture2d_array<float> freshDepth [[texture(1)]],
                                       texture2d_array<float> history [[texture(2)]]) {
    uint layer = in.viewIndex;
    int2 pixel = int2(floor(in.position.xy));
    int2 pattern = int2(TU.pattern.xy);
    int2 block = pixel >> 1;
    int2 freshMax = int2(fresh.get_width(), fresh.get_height()) - 1;
    bool isFresh = all((pixel & 1) == pattern);

    float4 own = fresh.read(uint2(min(block, freshMax)), layer);
    float depthKm = freshDepth.read(uint2(min(block, freshMax)), layer).r;
    float4 lo = own, hi = own;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float4 c = fresh.read(uint2(clamp(block + int2(dx, dy), int2(0), freshMax)), layer);
            lo = min(lo, c);
            hi = max(hi, c);
        }
    }

    // 这个像素在世界里看到的点（舞台坐标），投到上一帧
    float2 physical = (float2(pixel) + 0.5f) / F.clouds.x;
    float2 screen = screenPosition(physical, layer, F.camera.w > 0.5f, rateMap);
    // 舞台 → 世界（这一帧的位置和航向）→ 上一帧的舞台：你掉了多少、滑了多少、转了多少都算进去
    Ray r = viewRay(screen, views[layer], 0.0f);
    float3 stagePoint = r.origin + r.direction * (depthKm * 1000.0f);
    float3 world = rotateHeading(stagePoint, cos(TU.now.w), sin(TU.now.w)) + TU.now.xyz;
    float3 p = rotateHeading(world - TU.prev.xyz, cos(TU.prev.w), -sin(TU.prev.w));
    float4 clip = prevViews[layer].viewProjection * float4(p, 1.0f);
    float2 ndc = clip.xy / max(clip.w, 1e-6f);
    float2 prevScreen = prevViews[layer].viewport.xy
                      + float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * prevViews[layer].viewport.zw;
    float2 prevPhysical = screenToPhysical(prevScreen, layer, TU.motion.w > 0.5f, prevRateMap);
    float2 prevPixel = prevPhysical * F.clouds.x;
    float2 size = float2(history.get_width(), history.get_height());
    bool valid = TU.pattern.w > 0.5f && clip.w > 0.0f && all(prevPixel >= 0.5f) && all(prevPixel <= size - 0.5f);

    float4 result;
    if (valid) {
        float4 h = clamp(history.sample(pixelLinearClamp, prevPixel, layer), lo, hi);
        result = isFresh ? mix(h, own, 0.4f) : h;
    } else {
        // 没有历史：这一帧新算的四分之一样本双线性放大
        float2 freshCoord = (float2(pixel - pattern)) * 0.5f + 0.5f;
        result = isFresh ? own : fresh.sample(pixelLinearClamp, freshCoord, layer);
    }

    CloudOut o;
    o.color = result;
    o.depth = depthKm;
    return o;
}

// MARK: - 主 pass：天空、太阳、海面，合成云层

static inline float3 sunLight(float3 rd, float3 sunDir, float3 Tsun) {
    float cosA = clamp(dot(rd, sunDir), -1.0f, 1.0f);
    float angle = acos(cosA);
    const float radius = 0.00467f;                  // 太阳角半径（弧度）
    float disk = smoothstep(radius + 0.0006f, radius - 0.0006f, angle);
    float limb = sqrt(saturate(1.0f - (angle / radius) * (angle / radius)));
    float3 L = disk * (0.4f + 0.6f * limb) * 1600.0f;
    // 太阳周围的光晕（镜头和眼睛的散射，没有后处理泛光，就直接画在天上）
    L += 1.5f * exp(-angle / 0.015f) + 0.15f * exp(-angle / 0.09f);
    return Tsun * L;
}

/// 海浪的坡度：拿云的形状噪声（Perlin-Worley）当高度场，三个尺度（一格 160 / 40 / 10 米），第三维当时间让它慢慢变。
/// 之前用十几个正弦波叠，低空看太阳反光会出规则的网格纹；噪声没有周期性，就不会。
/// 小于 16 个像素的尺度不画，坡度方差加进 Beckmann 的统计粗糙度——不然远处会闪（VR 里很明显）。
static inline float2 waveSlope(float2 xz, float time, float footprint, texture3d<float> noise,
                               thread float &residualVariance) {
    const float scales[3] = { 160.0f, 40.0f, 10.0f };
    const float amplitude[3] = { 0.06f, 0.07f, 0.08f };
    const float e = 1.0f / 128.0f;          // 一个纹素
    float2 slope = 0.0f;
    residualVariance = 0.0f;
    for (int i = 0; i < 3; i++) {
        float a = amplitude[i];
        float fade = saturate(scales[i] / (footprint * 16.0f) - 1.0f);
        residualVariance += a * a * 0.5f * (1.0f - fade * fade);
        if (fade > 0.0f) {
            float3 uvw = float3(xz.x / scales[i], time * (0.015f + 0.01f * float(i)), xz.y / scales[i]);
            float h = noise.sample(linearRepeat, uvw, level(0)).r;
            float hx = noise.sample(linearRepeat, uvw + float3(e, 0.0f, 0.0f), level(0)).r;
            float hz = noise.sample(linearRepeat, uvw + float3(0.0f, 0.0f, e), level(0)).r;
            slope += float2(hx - h, hz - h) * (a * fade / (e * 6.0f));
        }
    }
    return slope;
}

/// B 样条双三次采样（4 次双线性）：环礁图被放大几十倍看时，双线性的等值线是一格一格的台阶，这个是平滑的
static inline float4 sampleBicubic(texture2d<float> tex, float2 uv) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 p = uv * size - 0.5f;
    float2 f = fract(p);
    float2 i = floor(p);
    float2 w0 = (1.0f - f) * (1.0f - f) * (1.0f - f) / 6.0f;
    float2 w1 = (4.0f - 6.0f * f * f + 3.0f * f * f * f) / 6.0f;
    float2 w2 = (1.0f + 3.0f * f + 3.0f * f * f - 3.0f * f * f * f) / 6.0f;
    float2 w3 = f * f * f / 6.0f;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 h0 = (w1 / g0) - 1.0f + i + 0.5f, h1 = (w3 / g1) + 1.0f + i + 0.5f;
    float4 a = tex.sample(linearClamp, float2(h0.x, h0.y) / size, level(0));
    float4 b = tex.sample(linearClamp, float2(h1.x, h0.y) / size, level(0));
    float4 c = tex.sample(linearClamp, float2(h0.x, h1.y) / size, level(0));
    float4 d = tex.sample(linearClamp, float2(h1.x, h1.y) / size, level(0));
    return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
}

static inline float3 oceanShade(float3 N, float3 rd, float3 sunDir, float shadow, float m2, float3 waterAlbedo,
                                constant AtmosphereConstants &A, texture2d<float> skySeaLUT) {
    float3 V = -rd;
    float NdotV = max(dot(N, V), 1e-3f);
    float NdotL = saturate(dot(N, sunDir));
    float m = 1.0f - NdotV;
    float fresnel = 0.02f + 0.98f * (m * m) * (m * m) * m;

    float3 R = reflect(rd, N);
    R.y = max(R.y, 0.003f);
    R = normalize(R);
    float3 sky = skyViewLookup(skySeaLUT, R, sunDir, ATM_BOTTOM + 0.002f, false);

    // 太阳反光：画不出来的小浪按坡度的统计分布（Beckmann）算，远处自然连成一片光
    float3 H = normalize(V + sunDir);
    float NdotH = max(dot(N, H), 1e-4f);
    float cos2 = NdotH * NdotH;
    float D = exp(-(1.0f - cos2) / (cos2 * m2)) / (PI * m2 * cos2 * cos2);
    float mh = 1.0f - saturate(dot(V, H));
    float FH = 0.02f + 0.98f * (mh * mh) * (mh * mh) * mh;
    // 太阳的倒影亮得刺眼，大片顶满白在头显里很难受，压一点
    float glint = 0.45f * FH * D / (4.0f * NdotV) * step(0.0f, dot(N, sunDir));

    float3 sunE = A.sunAtSea.rgb * shadow;
    float3 body = waterAlbedo * (sunE * NdotL + A.skyIrradianceSea.rgb) / PI;
    return fresnel * sky + sunE * glint + (1.0f - fresnel) * body;
}

/// 环礁沙洲上椰子树的影子（树是实体模型，沙面是这个 pass 画的，没有阴影图）：按和 PropsAtoll.swift 一样的一张表，
/// 把每棵树的树冠（一个带叶片缺口的圆）和树干（一条线）顺着太阳投到沙上。太阳低，影子有树的一倍半长。
/// sl：沙洲坐标；sunSl：太阳方向的水平分量（转到沙洲坐标）；sunY：太阳的高度分量。返回太阳被挡掉多少（0..1）
static inline float atollPalmShadow(float2 sl, float2 sunSl, float sunY) {
    // 每棵两项：(根的 x, y, 树高, -)、(树顶相对根的水平偏移 x, y, -, -)
    const float4 palms[30] = {
    float4(-126.0f, 8.0f, 8.5f, 0.0f), float4(1.957f, 0.828f, 0.0f, 0.0f),
    float4(-118.0f, 22.0f, 7.0f, 0.0f), float4(-0.636f, 1.088f, 0.0f, 0.0f),
    float4(-108.0f, 3.0f, 9.8f, 0.0f), float4(-1.922f, -2.225f, 0.0f, 0.0f),
    float4(-103.0f, 19.0f, 6.4f, 0.0f), float4(0.497f, -0.746f, 0.0f, 0.0f),
    float4(-96.0f, 10.0f, 8.0f, 0.0f), float4(0.638f, 1.640f, 0.0f, 0.0f),
    float4(-121.0f, -4.0f, 7.4f, 0.0f), float4(-2.070f, 0.086f, 0.0f, 0.0f),
    float4(106.0f, -22.0f, 9.2f, 0.0f), float4(-1.892f, 1.138f, 0.0f, 0.0f),
    float4(114.0f, -9.0f, 6.8f, 0.0f), float4(0.676f, 0.852f, 0.0f, 0.0f),
    float4(121.0f, -27.0f, 8.3f, 0.0f), float4(-0.279f, -2.474f, 0.0f, 0.0f),
    float4(127.0f, -14.0f, 7.2f, 0.0f), float4(1.275f, -0.669f, 0.0f, 0.0f),
    float4(111.0f, -33.0f, 10.1f, 0.0f), float4(-2.459f, -0.921f, 0.0f, 0.0f),
    float4(133.0f, -25.0f, 6.5f, 0.0f), float4(-0.126f, 0.967f, 0.0f, 0.0f),
    float4(-78.0f, -49.0f, 8.8f, 0.0f), float4(2.329f, 0.472f, 0.0f, 0.0f),
    float4(-66.0f, -57.0f, 7.1f, 0.0f), float4(-1.310f, 0.323f, 0.0f, 0.0f),
    float4(-71.0f, -44.0f, 9.5f, 0.0f), float4(0.408f, -2.147f, 0.0f, 0.0f),
    };
    float k = 1.0f / max(sunY, 0.15f);
    float shade = 0.0f;
    for (int i = 0; i < 15; i++) {
        float h = palms[2 * i].z;
        float2 base = palms[2 * i].xy;
        float2 c = base + palms[2 * i + 1].xy - sunSl * (h * k);
        float2 d = sl - c;
        float r = 0.42f * h;
        if (dot(sl - base, sl - base) > (r + h * k * 1.3f + 4.0f) * (r + h * k * 1.3f + 4.0f)) continue;
        // 树冠：八片叶子之间透光
        float fronds = 0.62f + 0.38f * cos(8.0f * atan2(d.y, d.x) + float(i));
        float crown = smoothstep(r, r * 0.35f, length(d) / max(fronds, 0.3f) * 0.8f);
        // 树干：根到树冠影子中心的一条线
        float2 ba = c - base;
        float t = saturate(dot(sl - base, ba) / max(dot(ba, ba), 1e-3f));
        float trunk = smoothstep(0.34f, 0.12f, length(sl - base - ba * t));
        shade = max(shade, max(crown, trunk));
    }
    return shade;
}

fragment float4 sceneFragment(VOut in [[stage_in]],
                                constant ViewUniforms *views [[buffer(0)]],
                                constant FrameUniforms &F [[buffer(1)]],
                                constant rasterization_rate_map_data &rateMap [[buffer(2)]],
                                constant AtmosphereConstants &A [[buffer(3)]],
                                texture2d<float> transLUT [[texture(0)]],
                                texture2d<float> skyLUT [[texture(1)]],
                                texture2d<float> skySeaLUT [[texture(2)]],
                                texture2d_array<float> cloudColor [[texture(3)]],
                                texture2d<float> cloudShadow [[texture(4)]],
                                texture2d<float> atollMap [[texture(5)]],
                                texture3d<float> waveNoise [[texture(6)]]) {
    float2 screen = screenPosition(in.position.xy, in.viewIndex, F.camera.w > 0.5f, rateMap);
    Ray r = worldRay(screen, views[in.viewIndex], F);
    float3 rd = r.direction;
    // 开场：门外的天、海、云按视线 7 米处的点实体化，没到的地方透出房间
    float2 reveal = float2(1.0f, 0.0f);
    if (revealActive) {
        reveal = revealEnvironment(views[in.viewIndex].cameraPosition.xyz, rotateHeading(rd, F.heading.x, -F.heading.y), F);
        if (reveal.x + reveal.y < 0.003f) discard_fragment();
    }
    float3 sunDir = F.sunDirection.xyz;
    float ch = max(r.origin.y, 1.0f);
    float camR = ATM_BOTTOM + ch * 0.001f;

    float2 sea = sphereHits(ch, rd.y, 0.0f);
    bool ground = sea.x > 0.0f;
    // 地形场景的地面由地形网格画，这里只剩天空；天空之城的网格只有浮岛，岛外往下看还是这里画的海
    bool skyCity = F.world.w > 0.5f;
    bool terrainScene = F.world.z > 0.5f && !skyCity;
#ifdef PROFILE_FLAT_SCENE
    float3 color = float3(0.02f);
#else
    float3 color = skyViewLookup(skyLUT, rd, sunDir, camR, ground);
    if (ground && !terrainScene) {
        float t = sea.x;
        float2 xz = r.origin.xz + rd.xz * t;
        // 一个像素在海面上盖多大（米）：斜着看拉长
        float footprint = t * 0.0011f / max(-rd.y, 0.05f);
        float residual;
        // 地面坐标 = 云坐标 + F.ground.yw（机舱里地面不跟飞机走，见 JumpTimeline.landShift）
        float2 g = xz + F.ground.xz + F.ground.yw;
        float2 slope = waveSlope(g, F.camera.y, footprint, waveNoise, residual);
        float3 sphereN = float3(xz.x / EARTH_R, 1.0f, xz.y / EARTH_R);
        float3 N = normalize(sphereN + float3(-slope.x, 0.0f, -slope.y));
        float od = cloudShadow.sample(linearRepeat, (xz + F.ground.xz) / WEATHER_TILE + 0.5f, level(0)).r;
        // 着陆区几百米内不落云影（阳光从云缝里照下来）：云相对地面的位置取决于你在舱里等了多久，靶不能碰巧在阴影里
        if (!skyCity) od *= smoothstep(300.0f, 650.0f, length(g - TARGET_CENTER));
        float shadow = exp(-od * F.clouds.z * 0.5f);
        // 自己的伞衣和身体的影子：这个点在舞台空间的位置（视线没转航向的方向 × 距离）
        float3 stageP = views[in.viewIndex].cameraPosition.xyz + rotateHeading(rd, F.heading.x, -F.heading.y) * t;
        float3 Ls = stageSunDirection(F);
        float3 sunVis = shadow * canopyShadow(stageP, Ls, F) * bodyShadow(stageP, Ls, F);

        // 水下的颜色：深海往上散出来的光 + 浅处的白沙底（红光被水吸收得最快，越浅越青绿）
        float3 waterAlbedo = float3(0.004f, 0.017f, 0.034f);
        float land = 0.0f, vegetation = 0.0f, surf = 0.0f, depth = 1000.0f;
        float detail = waveNoise.sample(linearRepeat, float3(g.x / 40.0f, 0.37f, g.y / 40.0f), level(0)).g;
        float2 atollUV = (g - ATOLL_CENTER) / ATOLL_SIZE + 0.5f;
        if (!skyCity && all(atollUV > 0.0f) && all(atollUV < 1.0f)) {
            float4 atoll = sampleBicubic(atollMap, atollUV);
            depth = ATOLL_MAX_DEPTH * atoll.g * atoll.g;
            // 环礁图一格 7.8 米，低空近看边缘是糊的：用细节噪声把沙洲、植被、浪花的边打碎
            float canopyNoise = waveNoise.sample(linearRepeat, float3(g.x / 13.0f, 0.71f, g.y / 13.0f), level(0)).r;
            float jitter = (detail - 0.55f) * 0.5f;
            land = smoothstep(0.38f, 0.62f, atoll.r + jitter);
            vegetation = smoothstep(0.35f, 0.65f, atoll.b + jitter * 1.3f) * (0.75f + 0.5f * canopyNoise);
            surf = saturate(atoll.a * (1.0f + jitter * 2.0f));
        }
        // 着陆的白沙洲（和 LandingZone.atoll 一致）：外面一圈浅水，越近越浅
        float2 sd = g - SANDBAR_CENTER;
        float2 sl = float2(sd.x * SANDBAR_COS + sd.y * SANDBAR_SIN, -sd.x * SANDBAR_SIN + sd.y * SANDBAR_COS);
        float sandEdge = (length(sl / SANDBAR_AXES) - 1.0f) * SANDBAR_AXES.y + (detail - 0.55f) * 16.0f;
        float sandbar = skyCity ? 0.0f : smoothstep(1.5f, -1.5f, sandEdge);
        if (!skyCity) depth = min(depth, max(sandEdge, 0.0f) * 0.045f + 0.15f);
        land = max(land, sandbar);
        vegetation *= 1.0f - sandbar;
        surf *= 1.0f - sandbar;
        if (depth < 900.0f) {
            const float3 absorption = float3(0.45f, 0.065f, 0.035f);   // 每米
            waterAlbedo += float3(0.55f, 0.6f, 0.55f) * exp(-2.0f * absorption * depth);
        }
        float3 surface = oceanShade(N, rd, sunDir, dot(sunVis, float3(0.3333f)), 0.006f + residual, waterAlbedo, A, skySeaLUT);
        if (land + surf > 0.0f) {
            // 沙洲和白浪：漫反射（沙滩、椰林、浪花）
            // 沙滩近看有细纹（风吹出来的沙纹），水边一圈湿沙颜色深
            // 沙面深浅：顺风拉长的一道道条带（31 米 × 5.3 米一圈）。之前拿胞状噪声 2.5 米一格平铺，
            // 近看是一格格重复的鼓包，像毛线织的地毯
            const float2 wind = float2(0.94f, 0.34f);
            float2 wq = float2(dot(g, wind) / 31.0f, dot(g, float2(-wind.y, wind.x)) / 5.3f);
            float bandLod = max(log2(footprint / (5.3f / 128.0f)), 0.0f);
            float ripple = waveNoise.sample(trilinearRepeat, float3(wq.x, 0.53f, wq.y), level(bandLod)).b;
            float wet = sandbar * smoothstep(-6.0f, 0.0f, sandEdge);
            // 落地前一两百米：沙面的起伏（差分出法线，斜阳下一道道沙纹有明暗）、沙粒、零星的贝壳和碎珊瑚、
            // 涨潮留下的一道海草线。之前沙洲按一个平面打光，近看是一整片没有细节的米白色
            float3 Ns = sphereN;
            float grain = 0.0f, debris = 0.0f;
            // （靶是铺平的一块布：沙纹的起伏在它下面只留两成，不然红白圈上一块块发黑）
            float near = saturate(2.5f / (footprint * 9.0f) - 1.0f) * sandbar
                       * mix(0.2f, 1.0f, smoothstep(TARGET_RADIUS - 1.0f, TARGET_RADIUS + 1.0f, length(g - TARGET_CENTER)));
            if (near > 0.0f) {
                // 起伏：同一张条带差分（缓的沙垄）；真正的风沙纹（十几厘米一道）只在脚边几米出现，
                // 一个波长不到 6 个像素就淡掉，一片有一片没有
                float rx = waveNoise.sample(trilinearRepeat, float3(wq.x + 0.02f, 0.53f, wq.y), level(bandLod)).b;
                float rz = waveNoise.sample(trilinearRepeat, float3(wq.x, 0.53f, wq.y + 0.06f), level(bandLod)).b;
                float lines = sin(dot(g, wind) * 38.0f + detail * 25.0f) * smoothstep(0.45f, 0.65f, ripple)
                            * saturate(0.165f / (footprint * 6.0f) - 1.0f);
                float2 across = float2(-wind.y, wind.x);
                Ns = normalize(sphereN + (float3(wind.x, 0.0f, wind.y) * ((ripple - rx) * 0.6f + lines * 0.10f)
                                          + float3(across.x, 0.0f, across.y) * ((ripple - rz) * 0.6f)) * near);
                // 沙粒：两层转了不同角度、大小不成整数比的采样相乘，看不出哪一层在重复；贝壳、碎珊瑚零零星星
                float2 q1 = float2(g.x * 0.8f + g.y * 0.6f, -g.x * 0.6f + g.y * 0.8f) / 3.7f;
                float2 q2 = float2(g.x * 0.28f - g.y * 0.96f, g.x * 0.96f + g.y * 0.28f) / 1.3f;
                float f1 = waveNoise.sample(trilinearRepeat, float3(q1.x, 0.83f, q1.y), level(max(log2(footprint * 128.0f / 3.7f), 0.0f))).a;
                float f2 = waveNoise.sample(trilinearRepeat, float3(q2.x, 0.21f, q2.y), level(max(log2(footprint * 128.0f / 1.3f), 0.0f))).a;
                float close = saturate(0.45f / (footprint * 9.0f) - 1.0f);
                grain = (f1 * f2 * 2.0f - 0.5f) * 0.6f * near;
                debris = smoothstep(0.80f, 0.86f, f1) * smoothstep(0.6f, 0.75f, f2) * near * mix(0.5f, 1.0f, close);
            }
            // 涨潮留下的海草线：沿着沙洲的岸线走，断断续续两道。之前按细节噪声的等值线画，
            // 沙上是一个个只画了半圈的褐色圆环
            float shoreD = (length(sl / SANDBAR_AXES) - 1.0f) * SANDBAR_AXES.y + 4.0f * (ripple - 0.5f);
            float wrack = sandbar * (exp(-pow((shoreD + 6.0f) / 0.35f, 2.0f)) + 0.7f * exp(-pow((shoreD + 10.5f) / 0.3f, 2.0f)))
                        * smoothstep(0.45f, 0.6f, detail) * saturate(1.5f - footprint * 2.0f);
            float palmShade = 0.0f;
            if (sandbar > 0.0f && footprint < 1.5f) {
                float2 sunSl = float2(sunDir.x * SANDBAR_COS + sunDir.z * SANDBAR_SIN, -sunDir.x * SANDBAR_SIN + sunDir.z * SANDBAR_COS);
                palmShade = atollPalmShadow(sl, sunSl, sunDir.y) * saturate(3.0f - footprint * 2.0f);
            }
            float3 E = A.sunAtSea.rgb * sunVis * (1.0f - 0.8f * palmShade) * saturate(dot(Ns, sunDir))
                     + cloudySkyFill(A.skyIrradianceSea.rgb);
            float3 sand = float3(0.55f, 0.50f, 0.40f) * (0.9f + 0.2f * ripple + 0.35f * grain) * (1.0f - 0.35f * wet);
            sand = mix(sand, float3(0.62f, 0.58f, 0.52f), debris * 0.8f);
            sand = mix(sand, float3(0.09f, 0.075f, 0.04f), wrack * 0.55f);
            // 椰林一团一团深浅不一（树冠之间有阴影）
            float3 forest = float3(0.07f, 0.15f, 0.045f) * (0.6f + 0.8f * saturate(vegetation - 0.25f));
            float3 landAlbedo = mix(sand, forest, saturate(vegetation * 1.3f));
            // 靶：铺在沙上的一大块布，同心圆红白相间，中间黄色的靶心
            float r = length(g - TARGET_CENTER);
            float ring = fract(r / 4.0f);
            float aa = max(fwidth(r) / 4.0f, 1e-4f);
            float stripe = smoothstep(0.5f - aa, 0.5f + aa, ring);
            float3 targetColor = mix(TARGET_RED, TARGET_WHITE, stripe) * (1.0f + 0.07f * grain);
            targetColor = mix(TARGET_YELLOW, targetColor, smoothstep(TARGET_BULLSEYE - aa * 4.0f, TARGET_BULLSEYE + aa * 4.0f, r));
            float onTarget = smoothstep(TARGET_RADIUS + aa * 4.0f, TARGET_RADIUS - aa * 4.0f, r) * sandbar;
            landAlbedo = mix(landAlbedo, targetColor, onTarget);
            surface = mix(surface, landAlbedo * E / PI, land);
            surface = mix(surface, float3(0.75f) * E / PI, surf * (1.0f - land));
        }
        color += surface * transmittanceSegment(transLUT, camR, rd.y, t * 0.001f, true);
    } else if (!ground) {
        color += sunLight(rd, sunDir, transmittanceToTop(transLUT, camR, rd.y));
    }
#endif

    // 云层是半分辨率的，双线性放大（预乘过的散射光 + 透射率，放大后照样能直接合成）
    float4 cloud = cloudColor.sample(pixelLinearClamp, in.position.xy * F.clouds.x, in.viewIndex);
    color = color * cloud.a + cloud.rgb;

    color = tonemap(color * F.exposure.x) * F.camera.z;
    // 伞下转弯时视野四周压暗一圈（转向是世界绕你转，暗边能明显减轻晕）
    if (F.heading.z > 0.001f) {
        float2 uv = (screen - views[in.viewIndex].viewport.xy) / views[in.viewIndex].viewport.zw - 0.5f;
        color *= 1.0f - F.heading.z * smoothstep(0.17f, 0.5f, length(uv));
    }
    // 8 位输出前抖动半个色阶，天空渐变不出色带。在 √ 空间里抖（近似 sRGB 曲线，比 pow 便宜得多）
    float3 g = sqrt(color) + (ign(in.position.xy + 17.0f) - 0.5f) / 255.0f;
    if (revealActive) {
        // 开场：预乘输出，边上半透明地透出房间，再叠一道发光
        float a = reveal.x;
        return float4(g * g * a + REVEAL_GLOW_COLOR * reveal.y * F.camera.z, saturate(a + reveal.y * 0.5f));
    }
    return float4(g * g, 1.0f);
}

// MARK: - 高度表

struct HudOut {
    float4 position [[position]];
    float2 uv;
    uint viewIndex [[flat]];
};

vertex HudOut hudVertex(uint vid [[vertex_id]],
                        ushort amp [[amplification_id]],
                        constant ViewUniforms *views [[buffer(0)]],
                        constant FrameUniforms &F [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1);   // 三角形带：(0,0) (1,0) (0,1) (1,1)
    float3 pos = F.hudCenter.xyz
               + F.hudRight.xyz * ((corner.x - 0.5f) * F.hudCenter.w)
               + F.hudUp.xyz * ((corner.y - 0.5f) * F.hudRight.w);
    HudOut o;
    o.position = views[amp].viewProjection * float4(pos, 1.0f);
    o.uv = float2(corner.x, 1.0f - corner.y);
    o.viewIndex = amp;
    return o;
}

/// 字形图集：12 格（0-9、逗号、「ft」），每格 88×128。
#define GLYPH_CELLS 12.0f
#define GLYPH_ASPECT (88.0f / 128.0f)

fragment float4 hudFragment(HudOut in [[stage_in]],
                            constant FrameUniforms &F [[buffer(1)]],
                            texture2d<float> atlas [[texture(0)]]) {
    bool watch = F.hudStyle.x > 0.5f;          // 手腕上的圆表盘；否则是前方的圆角面板
    float aspect = F.hudCenter.w / F.hudRight.w;
    float2 p = in.uv * float2(aspect, 1.0f);              // 以面板高度为单位，y 向下

    float2 halfSize = float2(aspect, 1.0f) * 0.5f;
    float radius = watch ? 0.5f : 0.24f;                   // 半径 0.5 的「圆角」就是圆
    float2 q = abs(p - halfSize) - (halfSize - radius);
    float sd = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
    float aa = max(fwidth(sd), 1e-4f);
    float panel = saturate(0.5f - sd / aa);
    float rim = saturate(1.0f - abs(sd + (watch ? 0.025f : 0.035f)) / (aa * 1.2f)) * panel;

    // 表盘外圈的橙色弧：从 12 点顺时针，扫过的比例 = 高度 / 30,000 ft（像指针式高度表）
    float arc = 0.0f;
    if (watch) {
        float2 d = p - 0.5f;
        float angle = atan2(d.x, -d.y);                    // 12 点方向为 0，顺时针为正
        float sweep = fract(angle / (2.0f * PI) + 1.0f);
        float ring = saturate(1.0f - abs(length(d) - 0.43f) / 0.035f);
        arc = ring * step(sweep, F.hudStyle.y) * smoothstep(0.0f, aa * 2.0f, F.hudStyle.y - sweep + aa);
    }

    // 文字：先量总宽度再居中
    float gh = watch ? 0.22f : 0.64f, gw = gh * GLYPH_ASPECT;
    float y0 = 0.5f - gh * (watch ? 0.45f : 0.52f);
    uint glyphs[9];
    float total = 0.0f;
    uint count = 0;
    for (uint i = 0; i < 9; i++) {
        uint g = i < 8 ? (F.hudGlyphs[i / 4] >> ((i % 4) * 8)) & 0xFFu : 255u;
        if (g == 255u) g = 11u;                             // 数字写完接「ft」
        glyphs[count++] = g;
        total += g == 10u ? gw * 0.36f : gw * 0.86f;
        if (g == 11u) break;
    }
    float x = watch ? 0.5f * aspect - total * 0.5f : 0.2f;
    float text = 0.0f;
    for (uint i = 0; i < count; i++) {
        uint g = glyphs[i];
        bool comma = g == 10u;
        float advance = comma ? gw * 0.36f : gw * 0.86f;
        float cellX = x - (comma ? (gw - advance) * 0.5f : 0.0f);
        float2 local = (p - float2(cellX, y0)) / float2(gw, gh);
        if (all(local >= 0.0f) && all(local <= 1.0f)) {
            float2 auv = float2((float(g) + local.x) / GLYPH_CELLS, local.y);
            text = max(text, atlas.sample(linearClamp, auv, level(0)).r);
        }
        x += advance;
    }

    float opacity = F.hudUp.w * F.camera.z;
    float background = watch ? 1.0f : 0.42f;               // 表盘是实心的黑表面（透明的话透出来的是天，不是手腕）
    float alpha = max(panel * background, max(max(text, arc), rim * 0.5f)) * opacity;
    const float3 orange = float3(1.0f, 0.42f, 0.08f);
    // 报警：可以开伞时表盘底色橙色闪，低于决断高度红色急闪
    float3 face = float3(0.0f);
    if (F.hudStyle.z > 0.5f) {
        float rate = F.hudStyle.z > 1.5f ? 9.0f : 3.0f;
        float blink = step(0.0f, sin(F.camera.y * rate * 2.0f * PI));
        face = (F.hudStyle.z > 1.5f ? float3(0.75f, 0.03f, 0.02f) : float3(0.8f, 0.3f, 0.02f)) * blink * panel;
    }
    float3 rgb = (face * (1.0f - text) + text + rim * (watch ? 0.35f : 0.5f) * (1.0f - text)
                  + arc * orange * (1.0f - text)) * opacity;
    return float4(rgb, alpha);
}

// MARK: - 提示文字面板

vertex HudOut panelVertex(uint vid [[vertex_id]],
                          ushort amp [[amplification_id]],
                          constant ViewUniforms *views [[buffer(0)]],
                          constant PanelUniforms &P [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    float3 pos = P.center.xyz + P.right.xyz * ((corner.x - 0.5f) * P.center.w)
               + P.up.xyz * ((corner.y - 0.5f) * P.right.w);
    HudOut o;
    o.position = views[amp].viewProjection * float4(pos, 1.0f);
    o.uv = float2(corner.x, 1.0f - corner.y);
    o.viewIndex = amp;
    return o;
}

fragment float4 panelFragment(HudOut in [[stage_in]],
                              constant PanelUniforms &P [[buffer(1)]],
                              constant FrameUniforms &F [[buffer(2)]],
                              texture2d<float> text [[texture(0)]]) {
    float aspect = P.center.w / P.right.w;
    float2 p = in.uv * float2(aspect, 1.0f);
    float2 halfSize = float2(aspect, 1.0f) * 0.5f;
    const float radius = 0.3f;
    float2 q = abs(p - halfSize) - (halfSize - radius);
    float sd = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
    float aa = max(fwidth(sd), 1e-4f);
    float panel = saturate(0.5f - sd / aa);
    float4 t = text.sample(linearClamp, in.uv, level(0));          // 预乘过的白字
    float opacity = P.up.w * F.camera.z;
    float alpha = max(panel * 0.55f, t.a) * opacity;
    return float4(t.rgb * opacity, alpha);
}

// MARK: - 头盔 HUD（HelmetHUD.swift）

/// 一块头锁定的 HUD 面板：CoreGraphics 画好的线和字（预乘），这里加发光（取模糊的 mip）、
/// 一圈很淡的暗晕（白云前面也看得清）、扫描线，开机时从上往下一行行亮起来、扫过一道亮线。
fragment float4 helmetHudFragment(HudOut in [[stage_in]],
                                  constant PanelUniforms &P [[buffer(1)]],
                                  constant FrameUniforms &F [[buffer(2)]],
                                  texture2d<float> art [[texture(0)]]) {
    constexpr sampler mipped(filter::linear, mip_filter::linear, address::clamp_to_zero, max_anisotropy(4));
    float2 uv = in.uv;
    // 贴图按两倍分辨率画的：按屏幕上的大小自动选 mip，字边干净不闪（第一版固定取第 0 级，加上很强的辉光和扫描线，看着发糊）
    float4 base = art.sample(mipped, uv);
    float4 bloom = art.sample(mipped, uv, level(4.0f)) * 0.3f + art.sample(mipped, uv, level(6.0f)) * 0.2f;
    float boot = P.up.w;
    // 开机：上面先亮；亮的边界扫过一道亮线，刚亮起来的那几行闪一闪
    float front = boot * 1.25f - 0.1f;
    float shown = smoothstep(front + 0.02f, front - 0.02f, uv.y);
    float scanBand = exp(-abs(uv.y - front) * 60.0f) * step(boot, 0.999f);
    float flicker = boot < 1.0f ? 0.75f + 0.25f * step(0.5f, fract(sin(floor(F.camera.y * 30.0f) * 91.7f) * 437.5f)) : 1.0f;
    float3 glow = bloom.rgb * float3(0.55f, 0.9f, 1.0f);
    float3 color = (base.rgb + glow) * shown * flicker + float3(0.4f, 0.85f, 1.0f) * scanBand * 0.6f;
    float alpha = max(base.a, saturate(bloom.a * 0.3f)) * shown * flicker + scanBand * 0.3f;
    float k = F.camera.z;
    if (alpha * k < 0.004f) discard_fragment();
    return float4(color * k, saturate(alpha) * k);
}

#include "Terrain.h"
