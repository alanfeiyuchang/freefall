#pragma once
#include "Common.h"
#include "Atmosphere.h"

// 体积云：思路照 Schneider 的 Nubis（地平线：零之曙光），用三张预先生成的纹理拼出密度场：
//   天气图（2D，平铺 64 km）：r 覆盖率，g 云顶高度，b 云底高度。决定哪里有云、多高。
//   形状噪声（128³）：Perlin-Worley，把天气图里一团团的覆盖率侵蚀成花椰菜一样的积云。
//   细节噪声（32³）：Worley，再啃出边缘的小卷和丝。
// 光照：朝太阳走 6 步估光学深度，Wrenninge 的多次散射八度近似，加环境光（上方天空、下方海面反光）。
// 云相对你不水平移动（人和云都随风漂），所以云的坐标就是以起跳点为原点的世界坐标。
// 单位：米。地球半径和大气模型的地面一致（6360 km），云层和海面都是同心球壳。

#define EARTH_R 6360000.0f
#define CLOUD_MIN_H 1000.0f
#define CLOUD_MAX_H 8600.0f
#define WEATHER_TILE 64000.0f
#define BASE_NOISE_SIZE 2600.0f
#define DETAIL_NOISE_SIZE 420.0f
#define CLOUD_FAR 160000.0f

// 环礁：一张 16 km 见方的图，中心在起跳点右前方约 4 km（地面坐标，见 generateAtoll）
#define ATOLL_CENTER float2(1800.0f, -3800.0f)
#define ATOLL_SIZE 16000.0f
#define ATOLL_MAX_DEPTH 60.0f

struct Weather { float coverage; float base; float top; float columnar; };

static inline Weather sampleWeather(float2 xz, texture2d<float> weather) {
    float4 w = weather.sample(linearRepeat, xz / WEATHER_TILE + 0.5f, level(0));
    Weather o;
    o.coverage = w.r;
    o.top = mix(1500.0f, CLOUD_MAX_H, w.g);
    o.base = mix(CLOUD_MIN_H, 3500.0f, w.b);
    o.columnar = w.a;
    return o;
}

/// 密度 0..1（再乘消光系数才是每米的消光）。detail = false 只用形状噪声，便宜，用来粗步探路和算远处的光。
static inline float cloudDensity(float3 p, Weather w, texture3d<float> baseTex, texture3d<float> detailTex,
                                 bool detail, float coverageBias) {
    float h = p.y;
    if (h <= w.base || h >= w.top) return 0.0f;
    float hf = (h - w.base) / (w.top - w.base);
    // 平底；普通积云上半截开始收，浓积云（高塔）上下差不多粗、只在顶上收圆。
    // 圆顶的大形状主要来自天气图里半球形的云顶高度，这里只是让顶部的覆盖率再收一收。
    float dome = pow(saturate((1.0f - hf) * 2.0f), 0.6f);
    float column = pow(saturate((1.0f - hf) * 3.5f), 0.5f);
    float profile = saturate(hf * 12.0f) * mix(dome, column, w.columnar);
    float coverage = saturate(w.coverage + coverageBias) * profile;
    if (coverage <= 0.002f) return 0.0f;

    float4 n = baseTex.sample(linearRepeat, p / BASE_NOISE_SIZE, level(0));
    float lowFbm = n.g * 0.625f + n.b * 0.25f + n.a * 0.125f;
    float base = remap(n.r, lowFbm - 1.0f, 1.0f, 0.0f, 1.0f);
    float shape = saturate(remap(base, 1.0f - coverage, 1.0f, 0.0f, 1.0f));
    if (!detail || shape <= 0.0f) return shape;

    float3 d = detailTex.sample(linearRepeat, p / DETAIL_NOISE_SIZE, level(0)).rgb;
    float detailFbm = d.r * 0.625f + d.g * 0.25f + d.b * 0.125f;
    float erosion = mix(detailFbm, 1.0f - detailFbm, saturate(hf * 6.0f));   // 底部丝状，上面一团团
    // 最后拉一下对比：边缘从「几百米的渐变」收窄到几十米，云的轮廓才利落
    return saturate(remap(shape, erosion * 0.45f, 1.0f, 0.0f, 1.0f) * 2.5f);
}

/// 从高 ch、方向天顶角余弦 mu 出发的视线，和半径 EARTH_R + sh 的球面的两个交点（米，从小到大）。没交点返回 (-1,-1)。
/// 地球半径 6.36e6 米，直接套公式会抵消掉精度，这里用 r² - rs² = (ch - sh)(2R + ch + sh) 和不相消的求根写法。
static inline float2 sphereHits(float ch, float mu, float sh) {
    float r = EARTH_R + ch;
    float b = r * mu;
    float c = (ch - sh) * (2.0f * EARTH_R + ch + sh);
    float disc = b * b - c;
    if (disc < 0.0f) return float2(-1.0f);
    float s = sqrt(disc);
    float q = b >= 0.0f ? -(b + s) : (s - b);
    if (q == 0.0f) return float2(0.0f);
    float t0 = q, t1 = c / q;
    return float2(min(t0, t1), max(t0, t1));
}

/// 沿视线走 t 米后的海拔（考虑地球曲率）。
static inline float heightAt(float ch, float mu, float t) {
    float r = EARTH_R + ch;
    float x = t * (2.0f * r * mu + t);
    return ch + x / (sqrt(r * r + x) + r);
}

static inline float henyeyGreenstein(float cosT, float g) {
    float g2 = g * g;
    return (1.0f - g2) / (4.0f * PI * pow(max(1.0f + g2 - 2.0f * g * cosT, 1e-4f), 1.5f));
}

static inline float cloudPhase(float cosT, float k) {
    return mix(henyeyGreenstein(cosT, -0.2f * k), henyeyGreenstein(cosT, 0.8f * k), 0.75f);
}

struct CloudMaps {
    texture3d<float> base;
    texture3d<float> detail;
    texture2d<float> weather;
    texture2d<float> topMax;     // 附近最高的云顶（见 computeCloudTopMax）
};

/// 朝太阳走几步（越走越长）估这一点到云外的光学深度（密度 × 米）。近处 5 步（约 1 km），远处 4 步。
/// x = 全程，y = 只算前两步（约 80 米）：顺便拿来近似环境光遮蔽——凹进去、背着光的地方天光也少。
static inline float2 lightOpticalDepth(float3 p, float3 sunDir, CloudMaps maps, float bias, bool far) {
    float od = 0.0f, near = 0.0f, s = 0.0f, ds = 28.0f;
    int steps = far ? 4 : 5;
    float growth = far ? 2.6f : 2.1f;
    for (int i = 0; i < steps; i++) {
        float3 q = p + sunDir * (s + ds * 0.5f);
        Weather w = sampleWeather(q.xz, maps.weather);
        od += cloudDensity(q, w, maps.base, maps.detail, i < 2 && !far, bias) * ds;
        if (i == 1) near = od;
        s += ds;
        ds *= growth;
    }
    return float2(od, near);
}

struct CloudHit {
    float3 radiance;       // 散射进来的光（已经乘过沿途透射率）
    float transmittance;   // 云整体的透射率
    float depth;           // 按不透明度加权的平均距离（米），算空气透视用
};

static CloudHit marchClouds(float3 ro, float3 rd, float jitter, constant FrameUniforms &F,
                            constant AtmosphereConstants &A, CloudMaps maps) {
    CloudHit hit;
    hit.radiance = 0.0f;
    hit.transmittance = 1.0f;
    hit.depth = 0.0f;

    float ch = ro.y, mu = rd.y;
    float2 outer = sphereHits(ch, mu, CLOUD_MAX_H);
    float2 inner = sphereHits(ch, mu, CLOUD_MIN_H);
    float t0, t1;
    if (ch > CLOUD_MAX_H) {
        if (outer.y <= 0.0f) return hit;
        t0 = max(outer.x, 0.0f);
        t1 = inner.x > 0.0f ? inner.x : outer.y;
    } else if (ch >= CLOUD_MIN_H) {
        t0 = 0.0f;
        t1 = inner.x > 0.0f ? inner.x : outer.y;
    } else {
        t0 = max(inner.y, 0.0f);
        t1 = outer.y;
    }
    t1 = min(t1, CLOUD_FAR);
    if (t1 <= t0) return hit;

    float3 sunDir = F.sunDirection.xyz;
    float cosT = dot(rd, sunDir);
    float sunPhase = cloudPhase(cosT, 1.0f);
    const float isotropic = 1.0f / (4.0f * PI);
    float quality = F.clouds.y;
    float sigma = F.clouds.z;
    float bias = F.clouds.w;

    float T = 1.0f;
    float3 L = 0.0f;
    float depthSum = 0.0f, weightSum = 0.0f;
    bool fine = false;
    int empty = 0;
    float t = t0 + clamp(t0 * 0.004f, 24.0f, 400.0f) * quality * 3.0f * jitter;

    for (int i = 0; i < 200; i++) {
        if (t >= t1 || T < 0.02f) break;
        float fineStep = clamp(t * 0.004f, 24.0f, 400.0f) * quality;
        float coarseStep = fineStep * 3.0f;
        float3 p = float3(ro.x + rd.x * t, heightAt(ch, mu, t), ro.z + rd.z * t);
        Weather w = sampleWeather(p.xz, maps.weather);

        if (!fine) {
            // 还在附近所有云顶之上、并且在往下走：直接跳到那个高度（水平最多走 1.4 km，不越过上限图的保护范围）
            float topNear = mix(1500.0f, CLOUD_MAX_H, maps.topMax.sample(linearRepeat, p.xz / WEATHER_TILE + 0.5f,
                                                                         level(0)).r) + 60.0f;
            if (p.y > topNear && mu < -0.02f) {
                float skip = min((p.y - topNear) / -mu, 1400.0f / max(length(rd.xz), 0.05f));
                t += max(skip, coarseStep);
                continue;
            }
            if (cloudDensity(p, w, maps.base, maps.detail, false, bias) > 0.0f) {
                fine = true;                       // 碰到云了：退回半步，改用细步
                empty = 0;
                t = max(t - coarseStep * 0.5f, t0);
            } else {
                t += coarseStep;
            }
            continue;
        }

        bool far = t > 15000.0f;              // 15 km 外细节噪声小于一个像素
        float d = cloudDensity(p, w, maps.base, maps.detail, !far, bias);
        if (d > 0.003f) {
            empty = 0;
            float sigmaE = d * sigma;
            float2 lightOD = lightOpticalDepth(p, sunDir, maps, bias, far) * sigma;
            float od = lightOD.x;
            // 单次散射（带前向的相函数：逆光看边缘发亮）+ 两级越来越「穿透」的多次散射（各向同性）。
            // 多次散射是云顺光时看起来雪白的原因——只有单次散射的话，前向相函数往回散的光太少，云会发灰发蓝。
            float sunVis = sunPhase * exp(-od)
                         + isotropic * (1.2f * exp(-od * 0.3f) + 0.6f * exp(-od * 0.1f) + 0.25f * exp(-od * 0.03f));
            float hf = saturate((p.y - w.base) / max(w.top - w.base, 1.0f));
            float3 sun = mix(A.sunAtCloudBase.rgb, A.sunAtCloudTop.rgb, saturate((p.y - 1000.0f) / 8000.0f));
            float occlusion = mix(0.35f, 1.0f, exp(-lightOD.y * 0.5f));
            float3 ambient = (mix(A.groundBounce.rgb, A.skyRadianceAvg.rgb, sqrt(hf)) + sun * 0.004f) * occlusion;
            float3 S = sigmaE * (sun * sunVis + ambient);
            float stepT = exp(-sigmaE * fineStep);
            float3 Sint = (S - S * stepT) / sigmaE;   // 一步之内解析积分（Hillaire 2016），步长大也不会亮度失真
            L += T * Sint;
            depthSum += t * T * (1.0f - stepT);
            weightSum += T * (1.0f - stepT);
            T *= stepT;
        } else if (++empty > 6) {
            fine = false;
        }
        t += fineStep;
    }

    hit.radiance = L;
    hit.transmittance = T;
    hit.depth = weightSum > 0.0f ? depthSum / weightSum : t1;
    return hit;
}
