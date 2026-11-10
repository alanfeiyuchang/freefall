#pragma once
#include "Common.h"

// 生成云噪声纹理用的可平铺噪声（只在启动时跑一次）。
// 做法照 Schneider《GPU Pro 7: Real-Time Volumetric Cloudscapes》和 sebh 的 TileableVolumeNoise（MIT）。

static inline uint3 pcg3d(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

static inline float3 hash3(int3 c, uint seed) {
    uint3 h = pcg3d(as_type<uint3>(c) ^ uint3(seed * 0x9E3779B9u, seed * 0x85EBCA6Bu, seed * 0xC2B2AE35u));
    return float3(h) * (1.0f / 4294967296.0f);
}

static inline int3 wrapCell(int3 c, int period) { return ((c % period) + period) % period; }

/// 可平铺的 Worley 噪声：p 以格子为单位，period 是一圈几个格子。返回到最近特征点的距离（约 0..0.9）。
static inline float worley3(float3 p, int period, uint seed) {
    int3 cell = int3(floor(p));
    float3 f = p - float3(cell);
    float best = 8.0f;
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        int3 o = int3(x, y, z);
        float3 d = float3(o) + hash3(wrapCell(cell + o, period), seed) - f;
        best = min(best, dot(d, d));
    }
    return sqrt(best);
}

/// 二维 Worley：x = 到最近特征点的距离，y = 那个格子的随机数（用来给每朵云不同的高度）。
static inline float2 worley2Cell(float2 p, int period, uint seed) {
    int2 cell = int2(floor(p));
    float2 f = p - float2(cell);
    float best = 8.0f, id = 0.0f;
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        int2 o = int2(x, y);
        int2 c = ((cell + o) % period + period) % period;
        float3 h = hash3(int3(c, 0), seed);
        float2 d = float2(o) + h.xy - f;
        float dd = dot(d, d);
        if (dd < best) { best = dd; id = h.z; }
    }
    return float2(sqrt(best), id);
}

static inline float3 gradient3(int3 c, int period, uint seed) {
    return normalize(hash3(wrapCell(c, period), seed) * 2.0f - 1.0f + float3(1e-5f));
}

/// 可平铺的 Perlin 梯度噪声，返回约 -0.9..0.9（大多数值在 ±0.4 以内）。
static inline float perlin3(float3 p, int period, uint seed) {
    int3 i = int3(floor(p));
    float3 f = p - float3(i);
    float3 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float n000 = dot(gradient3(i + int3(0, 0, 0), period, seed), f - float3(0, 0, 0));
    float n100 = dot(gradient3(i + int3(1, 0, 0), period, seed), f - float3(1, 0, 0));
    float n010 = dot(gradient3(i + int3(0, 1, 0), period, seed), f - float3(0, 1, 0));
    float n110 = dot(gradient3(i + int3(1, 1, 0), period, seed), f - float3(1, 1, 0));
    float n001 = dot(gradient3(i + int3(0, 0, 1), period, seed), f - float3(0, 0, 1));
    float n101 = dot(gradient3(i + int3(1, 0, 1), period, seed), f - float3(1, 0, 1));
    float n011 = dot(gradient3(i + int3(0, 1, 1), period, seed), f - float3(0, 1, 1));
    float n111 = dot(gradient3(i + int3(1, 1, 1), period, seed), f - float3(1, 1, 1));
    float nx00 = mix(n000, n100, u.x), nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x), nx11 = mix(n011, n111, u.x);
    return mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
}

/// Perlin fbm，结果拉到 0..1。
static inline float perlinFbm(float3 p, int period, int octaves, uint seed) {
    float sum = 0.0f, amp = 1.0f, norm = 0.0f;
    for (int o = 0; o < octaves; o++) {
        sum += amp * perlin3(p, period, seed + uint(o));
        norm += amp;
        amp *= 0.5f;
        p *= 2.0f;
        period *= 2;
    }
    return saturate(sum / norm * 1.4f + 0.5f);
}
