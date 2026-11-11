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
    float4 exposure;         // x 曝光，y 有地形 / 实体模型的深度预渲染（云层按它截断，0/1），zw 未用
    float4 hudCenter;        // 高度表中心（舞台空间），w 宽（米）
    float4 hudRight;         // 右方向，w 高（米）
    float4 hudUp;            // 上方向，w 不透明度
    uint4 hudGlyphs;         // 高度数字的字形，每字节一个（0-9 数字、10 逗号、255 结束）
    float4 hudStyle;         // x 样式（0 前方面板，1 手腕表盘），y 表盘外圈弧的比例（高度 / 30,000 ft），z 报警（0/1/2）
    float4 heading;          // x cos 航向，y sin 航向（舞台 → 世界绕 y 轴转），z 转弯时的暗边强度，w 未用
    float4 world;            // x 场景编号，y 云层整体抬高多少米（= 着陆区海拔），z 有地形（0/1），w 地形下面还有海（天空之城，0/1）
    float4 canopyCenter;     // 伞衣的影子（舞台空间）：xyz 伞衣中心，w 影子强度（0 = 没开伞）
    float4 canopySpan;       // xyz 展向单位向量，w 投影的半展长（米）
    float4 canopyChord;      // xyz 弦向单位向量（前缘 → 后缘），w 半弦长（米）
    float4 bodyShadow;       // 身体的影子：xyz 头顶（舞台空间），w 有没有。身体是从头顶竖直垂到脚的胶囊
    float4 bodyRight;        // xyz 身体的右方向（肩膀在头顶下面、往两边），w 未用
    float4 armShadow[2];     // 左、右手腕（舞台空间），w 有没有（追踪到才有）：从肩膀到手腕各一条胳膊的影子
    float4 reveal;           // 开场的实体化：xyz 起点（舞台空间），w 波前半径（米；< 0 只有扶杆，≥ 1000 全部完成）
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
/// 按指定的 mip 级取（linearRepeat 没有 mip 过滤，永远取第 0 级）
constexpr sampler trilinearRepeat(filter::linear, mip_filter::linear, address::repeat);
constexpr sampler trilinearClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);
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

/// AgX（Troy Sobotka；多项式近似 Benjamin Wrensch 2023）：高光往白色收、不偏色，饱和的颜色不会一下子顶到纯色
static inline float3 agxContrast(float3 x) {
    float3 x2 = x * x, x4 = x2 * x2;
    return 15.5f * x4 * x2 - 40.14f * x4 * x + 31.96f * x4 - 6.868f * x2 * x + 0.4298f * x2 + 0.1191f * x - 0.00232f;
}

static inline float3 agx(float3 c) {
    const float3x3 inset = float3x3(float3(0.842479062253094f, 0.0423282422610123f, 0.0423756549057051f),
                                    float3(0.0784335999999992f, 0.878468636469772f, 0.0784336f),
                                    float3(0.0792237451477643f, 0.0791661274605434f, 0.879142973793104f));
    const float3x3 outset = float3x3(float3(1.19687900512017f, -0.0528968517574562f, -0.0529716355144438f),
                                     float3(-0.0980208811401368f, 1.15190312990417f, -0.0980434501171241f),
                                     float3(-0.0990297440797205f, -0.0989611768448433f, 1.15107367264116f));
    const float minEv = -12.47393f, maxEv = 4.026069f;
    float3 v = inset * max(c, 1e-10f);
    v = (clamp(log2(v), minEv, maxEv) - minEv) / (maxEv - minEv);
    v = agxContrast(v);
#ifdef TONEMAP_AGX_PUNCHY
    float luma = dot(v, float3(0.2126f, 0.7152f, 0.0722f));
    v = luma + 1.35f * (v - luma);
#endif
    v = outset * v;
    return pow(saturate(v), float3(2.2f));
}

/// 场景辐亮度（乘过曝光）→ 显示的线性颜色
static inline float3 tonemap(float3 x) {
#if defined(TONEMAP_AGX) || defined(TONEMAP_AGX_PUNCHY)
    return agx(x);
#else
    return acesFitted(x);
#endif
}

/// 地面受到的天光。晴空的辐照度又蓝又暗，但天上一半是被太阳照得雪白的积云，漫射下来的是白光：
/// 只按蓝天算，背阴的山坡、云影里的地面、自己影子里的沙滩经过色调映射是一片发黑的藏蓝色。
static inline float3 cloudySkyFill(float3 skyBlue) {
    return mix(skyBlue, float3(dot(skyBlue, float3(0.2126f, 0.7152f, 0.0722f))), 0.5f) * 1.32f;
}

/// 靶的红、白、黄（铺在地上的一块布）。比真布暗一点：太阳直射下再亮，色调映射会把红色冲成橙粉色
#define TARGET_RED float3(0.50f, 0.032f, 0.026f)
#define TARGET_WHITE float3(0.70f)
#define TARGET_YELLOW float3(0.78f, 0.56f, 0.04f)

static inline float3 linearToSrgb(float3 c) {
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f);
}

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}

// MARK: - 伞衣和身体的影子

/// 两层伞布透过来的阳光（伞衣配色见 CanopyCloth.buildMesh：深蓝、橙、白相间，9 个气室）。
/// 尼龙透得最多的是它自己颜色的光（一层约 0.4 × 反照率^1.5），上下两层再平方。
static inline float3 canopyCellTransmission(int cell) {
    const float3 navy = float3(0.00002f, 0.00016f, 0.0052f);
    const float3 orange = float3(0.098f, 0.0017f, 0.00002f);
    const float3 white = float3(0.088f, 0.088f, 0.082f);
    if (cell == 0 || cell == 8) return navy;
    return (cell & 1) ? orange : white;
}
#define CANOPY_T_AVERAGE float3(0.083f, 0.039f, 0.038f)

/// 阳光被伞衣挡掉以后剩下多少（rgb：透过伞布的光带着布的颜色）。p、L（指向太阳）都在舞台空间。
/// 伞衣当成一块平板（展向投影后约 7.9 × 3 米），太阳是 0.53° 的圆盘：离伞越远，影子边越糊、越淡——
/// 太阳圆盘投到伞衣平面上有多大，两个方向各算一次被挡住的比例再相乘（盒子模糊近似圆盘）。
/// 离地 1 km 的时候半影 9 米宽，比伞衣还大，地上几乎看不出影子；快落地时影子才清楚起来，越来越小、越来越实。
static inline float3 canopyShadow(float3 p, float3 L, constant FrameUniforms &F, float minDistance = 0.05f) {
    float strength = F.canopyCenter.w;
    if (strength <= 0.0f) return float3(1.0f);
    float3 ex = F.canopySpan.xyz, ez = F.canopyChord.xyz;
    float3 n = cross(ez, ex);
    float denom = dot(L, n);
    if (abs(denom) < 1e-3f) return float3(1.0f);
    float s = dot(F.canopyCenter.xyz - p, n) / denom;      // 顺着阳光往回走多远碰到伞衣
    if (s <= minDistance) return float3(1.0f);    // 伞衣自己（或者伞衣在点的背后）
    float3 h = p + L * s - F.canopyCenter.xyz;
    float x = dot(h, ex), z = dot(h, ez);
    float R = max(s * 0.00465f, 0.004f);                     // 太阳圆盘在伞衣那里的半径（米）
    float az = F.canopyChord.w;
    // 平面形状：长方形，两个翼尖的四个角是圆的（离前缘、后缘越近，展向越短）
    float corner = az * 0.75f;
    float dz = max(abs(z) - (az - corner), 0.0f);
    float ax = F.canopySpan.w - corner + sqrt(max(corner * corner - dz * dz, 0.0f));
    float fx = saturate((min(x + R, ax) - max(x - R, -ax)) / (2.0f * R));
    float fz = saturate((min(z + R, az) - max(z - R, -az)) / (2.0f * R));
    float cover = fx * fz * strength;
    if (cover <= 0.0f) return float3(1.0f);
    int cell = clamp(int((x / F.canopySpan.w * 0.5f + 0.5f) * 9.0f), 0, 8);
    float3 t = mix(canopyCellTransmission(cell), CANOPY_T_AVERAGE, saturate(R / 0.5f));
    return 1.0f - cover * (1.0f - t);
}

/// 阳光被身体挡掉以后剩下多少：身体当成从头顶竖直垂到脚（舞台地板）的一根柱子，粗细按头、肩、腿变。
/// 快落地时自己的影子从远处朝脚下收过来——判断离地多高最直观的线索。
static inline float bodyShadow(float3 p, float3 L, constant FrameUniforms &F) {
    if (F.bodyShadow.w <= 0.0f) return 1.0f;
    float3 a = F.bodyShadow.xyz;
    float3 d2 = float3(0.0f, 0.12f - a.y, 0.0f);             // 头顶 → 脚
    float3 r = p - a;
    float e = dot(d2, d2), f = dot(d2, r), b = dot(L, d2), c = dot(L, r);
    float den = e - b * b;
    float t = den > 1e-6f ? (b * f - c * e) / den : 0.0f;     // 光线上离身体最近的地方
    t = max(t, 0.0f);
    float u = saturate((b * t + f) / e);
    t = max(dot(a + d2 * u - p, L), 0.0f);
    if (t <= 0.05f) return 1.0f;
    float dist = length(p + L * t - a - d2 * u);
    // 粗细按人的轮廓变：头、脖子、肩、胸、腰、胯、大腿、膝、脚踝。第一版只有三段（头 / 一块方的上身 / 一根腿），
    // 边又是硬的，落地时脚下像贴了一个厕所门上的小人
    const float us[10] = { 0.0f, 0.055f, 0.105f, 0.15f, 0.24f, 0.37f, 0.47f, 0.62f, 0.75f, 1.0f };
    const float rs[10] = { 0.07f, 0.10f, 0.058f, 0.185f, 0.165f, 0.135f, 0.165f, 0.135f, 0.105f, 0.085f };
    float radius = rs[9];
    for (int i = 0; i < 9; i++) {
        if (u < us[i + 1]) {
            float k = (u - us[i]) / (us[i + 1] - us[i]);
            radius = mix(rs[i], rs[i + 1], k * k * (3.0f - 2.0f * k));
            break;
        }
    }
    // 半影：太阳圆盘的张角，再加一点起码的虚边（身体本来就不是硬边的圆柱）
    float R = max(t * 0.00465f, 0.0f) + 0.022f;
    float cover = saturate((min(dist + radius, R) - max(dist - radius, -R)) / (2.0f * R));
    // 两条胳膊：肩膀 → 手腕的胶囊（手举着操纵环，影子里的胳膊也举着，跟着你的手动）
    float3 shoulderMid = a + float3(0.0f, -0.36f, 0.0f);
    for (int i = 0; i < 2; i++) {
        if (F.armShadow[i].w <= 0.0f) continue;
        float3 s0 = shoulderMid + F.bodyRight.xyz * (i == 0 ? -0.19f : 0.19f);
        float3 seg = F.armShadow[i].xyz - s0;
        float3 rr = p - s0;
        float e2 = dot(seg, seg), f2 = dot(seg, rr), b2 = dot(L, seg), c2 = dot(L, rr);
        float den2 = e2 - b2 * b2;
        float t2 = max(den2 > 1e-6f ? (b2 * f2 - c2 * e2) / den2 : 0.0f, 0.0f);
        float u2 = saturate((b2 * t2 + f2) / max(e2, 1e-6f));
        t2 = max(dot(s0 + seg * u2 - p, L), 0.0f);
        if (t2 <= 0.05f) continue;
        float d = length(p + L * t2 - s0 - seg * u2);
        float ra = mix(0.055f, 0.04f, u2);
        float Ra = t2 * 0.00465f + 0.018f;
        cover = max(cover, saturate((min(d + ra, Ra) - max(d - ra, -Ra)) / (2.0f * Ra)));
    }
    return 1.0f - cover * 0.94f;
}

/// 太阳在舞台空间的方向（伞下转向是世界绕你转，舞台里的东西要按航向反过来转）
static inline float3 stageSunDirection(constant FrameUniforms &F) {
    return rotateHeading(F.sunDirection.xyz, F.heading.x, -F.heading.y);
}

// MARK: - 开场的实体化（混合沉浸：没画的地方透出你的房间）

// 只有开场那几秒的管线带着这段遮罩（会丢弃片元）：着色器里一出现 discard，GPU 就没法提前剔除被挡住的片元，
// 天空、地形这种全屏的 pass 会白算很多。所以用函数常量编两套，实体化完成以后换回不带遮罩的。
constant bool revealConstant [[function_constant(10)]];
constant bool revealActive = is_function_constant_defined(revealConstant) && revealConstant;

static inline float revealHash(float3 p) {
    p = fract(p * 0.1031f);
    p += dot(p, p.zyx + 31.32f);
    return fract((p.x + p.y) * p.z);
}

/// 便宜的三维值噪声（0…1），只用来把波前的边打碎
static inline float revealNoise(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0f - 2.0f * f);
    float a = mix(mix(revealHash(i), revealHash(i + float3(1, 0, 0)), f.x),
                  mix(revealHash(i + float3(0, 1, 0)), revealHash(i + float3(1, 1, 0)), f.x), f.y);
    float b = mix(mix(revealHash(i + float3(0, 0, 1)), revealHash(i + float3(1, 0, 1)), f.x),
                  mix(revealHash(i + float3(0, 1, 1)), revealHash(i + float3(1, 1, 1)), f.x), f.y);
    return mix(a, b, f.z);
}

/// 波前离这个点还有多远：x > 0 表示波前已经扫过（米，边被噪声打碎），y 是发光的收尾系数（快完成时收掉），
/// z 是离起点的距离。全部完成恒为 (1e6, 0, 0)，还在房间里恒为 (-1e6, 0, 0)。
static inline float3 revealEdge(float3 p, constant FrameUniforms &F, float noiseScale) {
    float r = F.reveal.w;
    if (r >= 1000.0f) return float3(1e6f, 0.0f, 0.0f);
    if (r < 0.0f) return float3(-1e6f, 0.0f, 0.0f);
    float d = distance(p, F.reveal.xyz);
    float3 q = p * noiseScale;
    float n = revealNoise(q * 3.1f) * 0.65f + revealNoise(q * 9.3f + 7.0f) * 0.35f;
    float edge = r - d + (n - 0.5f) * 0.45f / noiseScale;
    return float3(edge, 1.0f - smoothstep(10.0f, 16.0f, r), d);
}

/// 网格（飞机、装备）：x = 1 已经出现、0 还是房间（片元直接丢掉，深度留 0，系统就透出房间）；
/// y = 波前的发光（刚出现的边上一道亮线，往里一圈慢慢暗下去的扫描纹）
static inline float2 revealAt(float3 p, constant FrameUniforms &F) {
    float3 e = revealEdge(p, F, 1.0f);
    if (e.x <= 0.0f) return float2(0.0f, 0.0f);
    float scan = 0.6f + 0.4f * sin(e.z * 48.0f - F.camera.y * 9.0f);
    float glow = (exp(-e.x / 0.022f) * 1.4f + exp(-e.x / 0.28f) * 0.45f * scan) * e.y;
    return float2(1.0f, glow);
}

/// 波前的颜色（显示空间，直接加在色调映射之后）
#define REVEAL_GLOW_COLOR float3(0.42f, 0.86f, 1.0f)

/// 天空、海、地形这种「很远」的东西：按视线上舱壁外面一点的地方算（朝舱门 7 米；朝机头要过了 14 米长的货舱，
/// 按 16 米，不然机头那端还没长出来就先透出天），噪声放大四倍（一大片一大片地出现），
/// 边是软的：x = 不透明度（预乘输出，没到的地方半透出房间），y = 边上的发光（也是预乘的，叠在房间上）
static inline float2 revealEnvironment(float3 eye, float3 stageDirection, constant FrameUniforms &F) {
    float distanceOut = 7.0f + 9.0f * saturate(stageDirection.z);
    float3 e = revealEdge(eye + stageDirection * distanceOut, F, 0.25f);
    float alpha = smoothstep(0.0f, 1.2f, e.x);
    float glow = exp(-abs(e.x - 0.35f) / 0.3f) * 0.55f * e.y;
    return float2(alpha, glow);
}
