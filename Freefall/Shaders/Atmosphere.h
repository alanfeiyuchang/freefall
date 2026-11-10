#pragma once
#include "Common.h"

// 大气散射：Hillaire 2020「A Scalable and Production Ready Sky and Atmosphere Rendering Technique」，
// 写法照参考实现 github.com/sebh/UnrealEngineSkyAtmosphere（MIT）。
// 这个文件里的长度单位都是公里；大气外的太阳照度记为 1，最后统一乘曝光。
//
// 三张查找表：
//   透射率（256×64）       ：某高度沿某方向到大气顶的透射率。启动时算一次。
//   多次散射（32×32）      ：各向同性的高阶散射近似。启动时算一次。
//   天空视图（192×108）    ：从你所在高度看各方向的天空光（只含散射进来的光，不含太阳本体和地面）。
//                            你的高度一直在变，所以每帧重算（很便宜）。海平面版本启动时算一次，给海面反射用。

#define ATM_BOTTOM 6360.0f
#define ATM_TOP 6460.0f
#define RAYLEIGH_SCATTERING float3(0.005802f, 0.013558f, 0.033100f)
#define MIE_SCATTERING 0.003996f
#define MIE_EXTINCTION 0.004440f
#define MIE_G 0.8f
#define OZONE_ABSORPTION float3(0.000650f, 0.001881f, 0.000085f)
#define GROUND_ALBEDO float3(0.06f)
#define TRANSMITTANCE_W 256
#define TRANSMITTANCE_H 64
#define MULTISCAT_RES 32
#define SKYVIEW_W 192
#define SKYVIEW_H 108

struct Medium { float3 scattering; float3 extinction; float3 mie; float3 rayleigh; };

static inline Medium sampleMedium(float h) {
    float dMie = exp(-h / 1.2f);
    float dRay = exp(-h / 8.0f);
    float dOzone = max(0.0f, h < 25.0f ? h / 15.0f - 2.0f / 3.0f : -h / 15.0f + 8.0f / 3.0f);
    Medium m;
    m.mie = float3(dMie * MIE_SCATTERING);
    m.rayleigh = dRay * RAYLEIGH_SCATTERING;
    m.scattering = m.mie + m.rayleigh;
    m.extinction = float3(dMie * MIE_EXTINCTION) + m.rayleigh + dOzone * OZONE_ABSORPTION;
    return m;
}

static inline float rayleighPhase(float cosT) { return 3.0f / (16.0f * PI) * (1.0f + cosT * cosT); }

/// Cornette-Shanks。cosT = 视线和太阳方向的夹角余弦，迎着太阳看时最大。
static inline float miePhase(float cosT) {
    const float g = MIE_G;
    float k = 3.0f / (8.0f * PI) * (1.0f - g * g) / (2.0f + g * g);
    return k * (1.0f + cosT * cosT) / pow(1.0f + g * g - 2.0f * g * cosT, 1.5f);
}

/// 前方最近的球面交点（球心在原点），没有返回 -1。
static inline float raySphereNearest(float3 ro, float3 rd, float radius) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0f) return -1.0f;
    float s = sqrt(disc);
    float t0 = -b - s, t1 = -b + s;
    if (t1 < 0.0f) return -1.0f;
    return t0 >= 0.0f ? t0 : t1;
}

static inline float fromUnitToSubUvs(float u, float res) { return (u + 0.5f / res) * (res / (res + 1.0f)); }
static inline float fromSubUvsToUnit(float u, float res) { return (u - 0.5f / res) * (res / (res - 1.0f)); }

static inline float2 transmittanceUV(float r, float mu) {
    const float H = sqrt(ATM_TOP * ATM_TOP - ATM_BOTTOM * ATM_BOTTOM);
    float rho = sqrt(max(0.0f, r * r - ATM_BOTTOM * ATM_BOTTOM));
    float disc = r * r * (mu * mu - 1.0f) + ATM_TOP * ATM_TOP;
    float d = max(0.0f, -r * mu + sqrt(max(disc, 0.0f)));
    float dMin = ATM_TOP - r;
    float dMax = rho + H;
    return float2((d - dMin) / (dMax - dMin), rho / H);
}

static inline float3 transmittanceToTop(texture2d<float> lut, float r, float mu) {
    return lut.sample(linearClamp, transmittanceUV(r, mu), level(0)).rgb;
}

static inline float2 multiScatUV(float cosSunZenith, float r) {
    float2 uv = saturate(float2(cosSunZenith * 0.5f + 0.5f, (r - ATM_BOTTOM) / (ATM_TOP - ATM_BOTTOM)));
    return float2(fromUnitToSubUvs(uv.x, MULTISCAT_RES), fromUnitToSubUvs(uv.y, MULTISCAT_RES));
}

/// 从高 r、天顶角余弦 mu 往前 d 公里这一段的透射率（Bruneton 的做法：两次查表相除）。
static inline float3 transmittanceSegment(texture2d<float> lut, float r, float mu, float d, bool hitsGround) {
    float rd = sqrt(max(d * d + 2.0f * r * mu * d + r * r, ATM_BOTTOM * ATM_BOTTOM));
    float mud = clamp((r * mu + d) / rd, -1.0f, 1.0f);
    if (hitsGround) {
        return min(transmittanceToTop(lut, rd, -mud) / max(transmittanceToTop(lut, r, -mu), float3(1e-6f)), float3(1.0f));
    }
    return min(transmittanceToTop(lut, r, mu) / max(transmittanceToTop(lut, rd, mud), float3(1e-6f)), float3(1.0f));
}

// MARK: - 天空视图表的参数化（地平线附近分辨率高）

static inline void skyViewParams(float2 uv, float viewHeight, thread float &viewZenithCos, thread float &lightViewCos) {
    uv = float2(fromSubUvsToUnit(uv.x, SKYVIEW_W), fromSubUvsToUnit(uv.y, SKYVIEW_H));
    float vHorizon = sqrt(max(viewHeight * viewHeight - ATM_BOTTOM * ATM_BOTTOM, 0.0f));
    float beta = acos(vHorizon / viewHeight);
    float zenithHorizonAngle = PI - beta;
    if (uv.y < 0.5f) {
        float coord = 1.0f - 2.0f * uv.y;
        coord = 1.0f - coord * coord;
        viewZenithCos = cos(zenithHorizonAngle * coord);
    } else {
        float coord = uv.y * 2.0f - 1.0f;
        coord *= coord;
        viewZenithCos = cos(zenithHorizonAngle + beta * coord);
    }
    float coord = uv.x * uv.x;
    lightViewCos = -(coord * 2.0f - 1.0f);
}

static inline float2 skyViewUV(bool intersectGround, float viewZenithCos, float lightViewCos, float viewHeight) {
    float vHorizon = sqrt(max(viewHeight * viewHeight - ATM_BOTTOM * ATM_BOTTOM, 0.0f));
    float beta = acos(vHorizon / viewHeight);
    float zenithHorizonAngle = PI - beta;
    float2 uv;
    float zenith = acos(clamp(viewZenithCos, -1.0f, 1.0f));
    if (!intersectGround) {
        float coord = 1.0f - saturate(zenith / zenithHorizonAngle);
        coord = 1.0f - sqrt(coord);
        uv.y = coord * 0.5f;
    } else {
        float coord = saturate((zenith - zenithHorizonAngle) / beta);
        uv.y = sqrt(coord) * 0.5f + 0.5f;
    }
    uv.x = sqrt(saturate(-lightViewCos * 0.5f + 0.5f));
    return float2(fromUnitToSubUvs(uv.x, SKYVIEW_W), fromUnitToSubUvs(uv.y, SKYVIEW_H));
}

/// 天空视图表查询：rd 是世界方向（y 向上），viewHeight 公里，hitsGround 视线是否打到海面。
static inline float3 skyViewLookup(texture2d<float> lut, float3 rd, float3 sunDir, float viewHeight, bool hitsGround) {
    float2 vh = rd.xz, sh = sunDir.xz;
    float lv = length(vh), ls = length(sh);
    float lightViewCos = (lv > 1e-5f && ls > 1e-5f) ? dot(vh, sh) / (lv * ls) : 1.0f;
    return lut.sample(linearClamp, skyViewUV(hitsGround, rd.y, lightViewCos, viewHeight), level(0)).rgb;
}

// MARK: - 沿视线积分散射（三张表的计算都用它）

struct ScatterResult { float3 L; float3 multiScatAs1; float3 transmittance; };

static ScatterResult integrateScattering(float3 ro, float3 rd, float3 sunDir, int sampleCount,
                                         bool ground, bool mieRayPhase, bool useMultiScat, bool quadratic,
                                         texture2d<float> transLUT, texture2d<float> msLUT,
                                         float maxDistance = 1e9f) {
    ScatterResult res;
    res.L = 0.0f;
    res.multiScatAs1 = 0.0f;
    res.transmittance = 1.0f;

    float tBottom = raySphereNearest(ro, rd, ATM_BOTTOM);
    float tTop = raySphereNearest(ro, rd, ATM_TOP);
    float tMax;
    if (tBottom < 0.0f) {
        if (tTop < 0.0f) return res;
        tMax = tTop;
    } else {
        tMax = tTop > 0.0f ? min(tTop, tBottom) : tBottom;
    }
    bool reachesGround = tBottom >= 0.0f && tMax == tBottom && maxDistance >= tMax;
    tMax = min(tMax, maxDistance);

    float cosT = dot(sunDir, rd);
    float phaseMie = miePhase(cosT);
    float phaseRay = rayleighPhase(cosT);
    const float uniformPhase = 1.0f / (4.0f * PI);
    float3 throughput = 1.0f;

    for (int i = 0; i < sampleCount; i++) {
        float t, dt;
        if (quadratic) {
            float a = float(i) / float(sampleCount), b = float(i + 1) / float(sampleCount);
            float t0 = tMax * a * a, t1 = tMax * b * b;
            t = t0 + (t1 - t0) * 0.3f;
            dt = t1 - t0;
        } else {
            dt = tMax / float(sampleCount);
            t = (float(i) + 0.3f) * dt;
        }
        float3 P = ro + t * rd;
        float pHeight = length(P);
        Medium m = sampleMedium(pHeight - ATM_BOTTOM);
        float3 sampleT = exp(-m.extinction * dt);
        float3 up = P / pHeight;
        float sunZenithCos = dot(sunDir, up);
        float3 Tsun = transmittanceToTop(transLUT, pHeight, sunZenithCos);
        float3 phaseTimesScattering = mieRayPhase ? (m.mie * phaseMie + m.rayleigh * phaseRay)
                                                  : m.scattering * uniformPhase;
        float earthShadow = raySphereNearest(P - up * 0.01f, sunDir, ATM_BOTTOM) >= 0.0f ? 0.0f : 1.0f;
        float3 multiScat = useMultiScat ? msLUT.sample(linearClamp, multiScatUV(sunZenithCos, pHeight), level(0)).rgb
                                        : float3(0.0f);
        float3 S = earthShadow * Tsun * phaseTimesScattering + multiScat * m.scattering;
        res.multiScatAs1 += throughput * (m.scattering - m.scattering * sampleT) / m.extinction;
        res.L += throughput * (S - S * sampleT) / m.extinction;
        throughput *= sampleT;
    }

    if (ground && reachesGround) {
        float3 P = ro + tBottom * rd;
        float pHeight = length(P);
        float3 up = P / pHeight;
        float3 Tsun = transmittanceToTop(transLUT, pHeight, dot(sunDir, up));
        res.L += Tsun * throughput * saturate(dot(up, sunDir)) * GROUND_ALBEDO / PI;
    }
    res.transmittance = throughput;
    return res;
}
