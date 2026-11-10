#pragma once
#include <metal_stdlib>
using namespace metal;

// 和 Shared/ShaderTypes.swift 逐字段对应。只用 float4 / float4x4 / uint4，两边的对齐才一样。

#define PI 3.14159265358979f

struct ViewUniforms {
    float4x4 viewProjection;          // 舞台空间 → 裁剪空间（reverse-Z）
    float4x4 inverseViewProjection;
    float4 cameraPosition;            // 舞台空间里的眼睛位置
    float4 viewport;                  // 屏幕（逻辑）坐标的视口 x, y, w, h
};

struct FrameUniforms {
    float4 sunDirection;     // xyz 指向太阳（世界坐标）
    float4 camera;           // x 舞台 y 加上它 = 海拔（米），y 时间（秒），z 画面亮度（淡入淡出），w 有注视点 rate map
    float4 ground;           // xz 你在云坐标里的水平位置（米；云坐标原点 = 天气图中心），yw 地面坐标 - 云坐标
    float4 clouds;           // x 云层 pass 的分辨率比例，y 步长倍数（越大越省），z 消光系数（每米），w 覆盖率偏移
    float4 exposure;         // x 曝光，yzw 未用
    float4 hudCenter;        // 高度表中心（舞台空间），w 宽（米）
    float4 hudRight;         // 右方向，w 高（米）
    float4 hudUp;            // 上方向，w 不透明度
    uint4 hudGlyphs;         // 高度数字的字形，每字节一个（0-9 数字、10 逗号、255 结束）
    float4 hudStyle;         // x 样式（0 前方面板，1 手腕表盘），y 表盘外圈弧的比例（高度 / 30,000 ft），z 报警（0/1/2）
    float4 heading;          // x cos 航向，y sin 航向（舞台 → 世界绕 y 轴转），z 转弯时的暗边强度，w 未用
};

/// 提示文字面板（舞台空间里的一块板）
struct PanelUniforms {
    float4 center;           // xyz 中心，w 宽（米）
    float4 right;            // xyz 右方向，w 高（米）
    float4 up;               // xyz 上方向，w 不透明度
};

/// 云的时间累积（见 Freefall.metal 的 cloudResolveFragment）
struct TemporalUniforms {
    float4 pattern;          // xy 这一帧重算的是 2×2 块里的哪个像素，z 帧序号，w 历史有效（0/1）
    float4 motion;           // w 有上一帧的 rate map，xyz 未用
    float4 now;              // 这一帧：x、z 你在云坐标里的位置，y 舞台 → 海拔的偏移，w 航向（弧度）
    float4 prev;             // 上一帧，同上
};

struct AtmosphereConstants {
    float4 sunAtCloudBase;   // 海拔 1 km 处的太阳光（大气透射之后；大气外的太阳照度记为 1）
    float4 sunAtCloudTop;    // 海拔 9 km 处
    float4 sunAtSea;         // 海平面
    float4 skyRadianceAvg;   // 海拔 3 km 处上半球天空的平均辐亮度（照云的环境光）
    float4 skyIrradianceSea; // 海平面的天空照度
    float4 groundBounce;     // 海面反射上来的平均辐亮度（照亮云底）
};

struct VOut {
    float4 position [[position]];
    // 不输出 [[render_target_array_index]] / [[viewport_array_index]]：层和视口完全由 view mapping 决定。
    // Bubble Dream 在真机上踩过：这里再输出一次，偏移会被加两次，右眼越界、左眼重影。
    uint viewIndex [[flat]];
};

struct Ray { float3 origin; float3 direction; };

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler linearRepeat(filter::linear, address::repeat);
constexpr sampler pixelLinearClamp(filter::linear, coord::pixel, address::clamp_to_edge);

static inline float remap(float v, float lo, float hi, float newLo, float newHi) {
    return newLo + (v - lo) * (newHi - newLo) / (hi - lo);
}

/// 交错梯度噪声（Jimenez 2014）。每个像素固定、不随帧变——VR 里逐帧变化的噪点会闪。
static inline float ign(float2 p) {
    return fract(52.9829189f * fract(dot(p, float2(0.06711056f, 0.00583715f))));
}

/// 片元的屏幕坐标：有 rate map 时 [[position]] 是压缩后的物理坐标，要换回屏幕坐标才能算视线。
static inline float2 screenPosition(float2 physical, uint layer, bool hasRateMap,
                                    constant rasterization_rate_map_data &rateMap) {
    if (!hasRateMap) return physical;
    rasterization_rate_map_decoder decoder(rateMap);
    return decoder.map_physical_to_screen_coordinates(physical, layer);
}

/// 反过来：屏幕坐标 → 物理坐标（上一帧的历史纹理是按物理坐标存的）。
static inline float2 screenToPhysical(float2 screen, uint layer, bool hasRateMap,
                                      constant rasterization_rate_map_data &rateMap) {
    if (!hasRateMap) return screen;
    rasterization_rate_map_decoder decoder(rateMap);
    return decoder.map_screen_to_physical_coordinates(screen, layer);
}

/// 屏幕坐标 → 世界里的视线。方向在舞台空间算（朝向和世界相同），原点再抬到海拔高度。
static inline Ray viewRay(float2 screenXY, constant ViewUniforms &v, float stageToAltitude) {
    float2 uv = (screenXY - v.viewport.xy) / v.viewport.zw;
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float4 p = v.inverseViewProjection * float4(ndc, 1.0f, 1.0f);   // reverse-Z：z = 1 是近平面
    p /= p.w;
    Ray r;
    r.origin = v.cameraPosition.xyz;
    r.direction = normalize(p.xyz - r.origin);
    r.origin.y += stageToAltitude;
    return r;
}

/// 舞台方向 → 世界方向：绕 y 轴转航向（转向是世界绕你转）
static inline float3 rotateHeading(float3 v, float c, float s) {
    return float3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

/// 世界里的视线：舞台视线转到世界朝向（原点只差几厘米的眼睛偏移，一起转）
static inline Ray worldRay(float2 screenXY, constant ViewUniforms &v, constant FrameUniforms &F) {
    Ray r = viewRay(screenXY, v, F.camera.x);
    r.direction = rotateHeading(r.direction, F.heading.x, F.heading.y);
    float3 o = rotateHeading(float3(r.origin.x, 0.0f, r.origin.z), F.heading.x, F.heading.y);
    r.origin = float3(o.x, r.origin.y, o.z);
    return r;
}

static inline float3 acesFitted(float3 x) {   // Narkowicz 2015
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}

static inline float3 linearToSrgb(float3 c) {
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f);
}

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}
