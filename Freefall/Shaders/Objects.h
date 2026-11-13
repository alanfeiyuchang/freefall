#pragma once
#include "Common.h"
#include "Noise.h"
#include "Atmosphere.h"
#include "Skins.h"

// 场景里的实体：飞机（货舱内部 + 外壳）、伞衣、伞绳和背带、手腕上的表带和高度表、前方高度表面板（没有手部追踪时）。
// 手是透视出来的真手：系统按这里写的深度把手和画面合成（upperLimbVisibility = automatic），所以深度要写对。
// 都在主 pass 画完天空和云之后画，正常做深度测试（reverse-Z：更近 = 深度更大）。
// 光照和天空用同一套单位（大气外的太阳照度 = 1），最后同样乘曝光、ACES，画面才连贯。

struct MeshVertex {
    float4 position;     // xyz 物体空间
    float4 normal;       // xyz 法线，w 室内程度（0 露天 … 1 机舱深处）
    float4 color;        // rgb 反照率（自发光材质是辐亮度），a 材质，见 MATERIAL_*
};

#define MATERIAL_DIFFUSE 0
#define MATERIAL_EMISSIVE 1
#define MATERIAL_LAMP_RED 2
#define MATERIAL_LAMP_GREEN 3
#define MATERIAL_FABRIC 4      // 伞衣：两面都能看，背光时透光
#define MATERIAL_SOFT 5        // 离屏测试里代替真手的手：边缘有一点柔和的亮光
// 装备（Shared/Gear.swift）：GGX 高光 + 天空反射，按真材料给粗糙度
#define MATERIAL_WEBBING 6     // 尼龙织带（背带、伸缩带、操纵环、拉手的布面）：斜纹 + 绒光
#define MATERIAL_METAL 7       // 金属（3 环、连接环、扣眼、卡扣、钢索、表圈）
#define MATERIAL_PLASTIC 8     // 硬塑料（钢索软管、表壳）
#define MATERIAL_RUBBER 9      // 橡胶（表带）
#define MATERIAL_BAR 10        // 舱门边的扶杆（喷黄漆的钢管）：开场在你的房间里只有它（连同下面两样）
#define MATERIAL_BAR_GRIP 11   // 扶杆中段的黑色橡胶握把
#define MATERIAL_BAR_METAL 12  // 扶杆两头镀锌的套筒、法兰、螺栓
// 机舱（ProceduralMeshes.swift）：花纹按机身坐标现算，打光和装备同一套，再加舱顶四盏夜灯
#define MATERIAL_QUILT 13      // 绗缝的隔热垫
#define MATERIAL_PAINTED 14    // 喷漆的金属（加强框、支架、门、作动筒、管线）
#define MATERIAL_ALUMINUM 15   // 裸金属（滚轮、钢索、座椅管架、系留环、铰链），反照率当 F0
#define MATERIAL_TREAD 16      // 地板和跳板（防滑涂层、拼缝、螺钉、系留环的凹坑、跳板的防滑棱、尾端警示条）
#define MATERIAL_HAZARD 17     // 黄黑警示条
#define MATERIAL_WINDOW 18     // 舷窗：透出去看到天
#define MATERIAL_SEAT 19       // 红色尼龙编织带的座椅
// 换皮肤的两样（Skins.h）：颜色不看顶点，按 uv 现算图案，算完当伞布 / 织带打光
#define MATERIAL_CANOPY 20     // 伞衣（uv 是展向、弦向，米）
#define MATERIAL_SLEEVE 21     // 跳伞服的袖子（uv：x 从手腕往手肘，米；y 绕一圈 0…1）

struct ObjectUniforms {
    float4x4 model;      // 物体 → 舞台
    float4 params;       // x 跳伞灯（0 红 1 绿），y 机舱里的程度（表带、背带的光照），zw 未用
};

/// 两端半径不同的胶囊（背带、表带的一段）。a、b 的 w 是半径。
struct RoundCone {
    float4 a;
    float4 b;
    float4 color;        // rgb 反照率，a 材质
};

struct ObjectOut {
    float4 position [[position]];
    float3 stagePos;
    float3 objectPos;          // 物体空间（机舱的花纹按机身坐标画）
    float3 normal;
    float4 color;
    float interior;
    float2 uv;                 // 伞布：展向、弦向坐标（米），画缝线用
    uint viewIndex [[flat]];
};

vertex ObjectOut meshVertex(uint vid [[vertex_id]],
                            ushort amp [[amplification_id]],
                            device const MeshVertex *vertices [[buffer(0)]],
                            constant ViewUniforms *views [[buffer(1)]],
                            constant ObjectUniforms &O [[buffer(2)]]) {
    MeshVertex v = vertices[vid];
    float4 p = O.model * float4(v.position.xyz, 1.0f);
    ObjectOut o;
    o.position = views[amp].viewProjection * p;
    o.stagePos = p.xyz;
    o.objectPos = v.position.xyz;
    o.normal = (O.model * float4(v.normal.xyz, 0.0f)).xyz;
    o.color = v.color;
    o.interior = v.normal.w;
    o.uv = float2(v.position.w, v.normal.w);
    o.viewIndex = amp;
    return o;
}

// 胶囊的模板：沿轴 10 圈（A 端半球 5 圈、B 端半球 5 圈，中间直接连成锥面），每圈 12 个点。
#define CONE_AROUND 12
#define CONE_RINGS 10
#define CONE_VERTICES ((CONE_RINGS - 1) * CONE_AROUND * 6)

vertex ObjectOut roundConeVertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 ushort amp [[amplification_id]],
                                 device const RoundCone *cones [[buffer(0)]],
                                 constant ViewUniforms *views [[buffer(1)]],
                                 constant ObjectUniforms &O [[buffer(2)]]) {
    RoundCone c = cones[iid];
    uint quad = vid / 6, corner = vid % 6;
    uint band = quad / CONE_AROUND, k = quad % CONE_AROUND;
    const uint2 offsets[6] = { uint2(0, 0), uint2(1, 0), uint2(1, 1), uint2(0, 0), uint2(1, 1), uint2(0, 1) };
    uint ring = band + offsets[corner].x;
    uint around = (k + offsets[corner].y) % CONE_AROUND;

    float3 axisVec = c.b.xyz - c.a.xyz;
    float len = length(axisVec);
    float3 axis = len > 1e-6f ? axisVec / len : float3(0.0f, 1.0f, 0.0f);
    float3 helper = abs(axis.y) < 0.9f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 u = normalize(cross(axis, helper));
    float3 v = cross(axis, u);
    float theta = 2.0f * PI * float(around) / float(CONE_AROUND);
    float3 radial = u * cos(theta) + v * sin(theta);

    float3 center, offset;
    if (ring < 5) {            // A 端半球：从极点到赤道
        float phi = float(ring) / 4.0f * (PI * 0.5f);
        center = c.a.xyz;
        offset = c.a.w * (-cos(phi) * axis + sin(phi) * radial);
    } else {                   // B 端半球：从赤道到极点
        float phi = float(ring - 5) / 4.0f * (PI * 0.5f);
        center = c.b.xyz;
        offset = c.b.w * (sin(phi) * axis + cos(phi) * radial);
    }
    float3 p = center + offset;
    ObjectOut o;
    o.position = views[amp].viewProjection * float4(p, 1.0f);
    o.stagePos = p;
    o.objectPos = p;
    o.normal = offset;
    o.color = c.color;
    o.interior = O.params.y;
    o.uv = float2(0.0f);
    o.viewIndex = amp;
    return o;
}

// MARK: - 材质

/// 地面平均反照率（金属环反射到的地面、装备朝下的面接到的反光）
static inline float sceneGroundAlbedo(int scene) {
    switch (scene) {
    case 1: return 0.13f;     // 草原
    case 2: return 0.12f;     // 高山
    case 3: return 0.65f;     // 雪山
    case 4: return 0.45f;     // 冰川
    case 5: return 0.07f;     // 火山
    case 6: return 0.5f;      // 天空之城：脚下是云海
    default: return 0.06f;    // 环礁：海面
    }
}

/// GGX（Trowbridge-Reitz）+ Smith 可见性，不含菲涅耳。a2 = 粗糙度⁴（已经加过几何高光抗锯齿）
static inline float ggx(float NdotH, float NdotV, float NdotL, float a2, float roughness) {
    float d = NdotH * NdotH * (a2 - 1.0f) + 1.0f;
    float D = a2 / (PI * d * d);
    float k = (roughness + 1.0f) * (roughness + 1.0f) / 8.0f;
    float G = (NdotV / (NdotV * (1.0f - k) + k)) * (NdotL / (NdotL * (1.0f - k) + k));
    return D * G / max(4.0f * NdotV * NdotL, 1e-4f);
}

/// 环境光的镜面部分（Karis 2014 的解析近似，代替预积分表）
static inline float3 envBRDF(float3 F0, float roughness, float NdotV) {
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f);
    const float4 c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * NdotV)) * r.x + r.y;
    float2 ab = float2(-1.04f, 1.04f) * a004 + r.zw;
    return F0 * ab.x + ab.y;
}

/// 装备和手套的一个表面
struct GearSurface {
    float3 position;      // 舞台空间
    float3 normal;        // 朝着眼睛
    float3 albedo;        // 漫反射颜色（金属是 0）
    float3 F0;            // 正对着看的反射率
    float roughness;
    float specScale;      // 镜面反射打几折（织带）
    float sheen;          // 尼龙的绒光
    float occlusion;      // 环境光遮蔽（只影响天光和反射）
    float interior;       // 在机舱里的程度
    float3 cabinE;        // 机舱里夜灯的照度（装备、手套按室内程度给一个平均值；机舱表面另算点光源，这里只放反射来的那点）
    float sun;            // 太阳照不照得到（0…1，不含伞衣的影子）：装备按室内程度估，机舱表面按射线出机身的地方算
    float wet;            // 淋湿的程度 0…1：布变深、表面一层水膜（更光滑、反光更强）
    float bead;           // 这一点在一颗水珠上的程度 0…1（手套上），beadR 离水珠中心多远（÷ 半径）
    float beadR;
};

/// 装备和手套共用的打光：太阳（伞衣的影子、舱里挡掉）、天光（贴着胸口朝里的一面被身体挡掉）、
/// 天空 / 地面 / 自己身体的反射、舱里的红灯、GGX 高光（几何高光抗锯齿）、尼龙的绒光
static inline float3 shadeGear(GearSurface s, float3 V, float3 dnx, float3 dny,
                               constant FrameUniforms &F, constant AtmosphereConstants &A,
                               texture2d<float> skyLUT, texture2d<float> canopyShadowMap) {
    if (s.wet > 0.0f) {
        // 湿了：织物吸了水颜色变深，表面一层水膜，绒光没了
        s.albedo *= 1.0f - 0.38f * s.wet;
        s.roughness = mix(s.roughness, 0.18f, 0.6f * s.wet);
        s.specScale = mix(s.specScale, 1.0f, 0.7f * s.wet);
        s.F0 = max(s.F0, float3(0.02f * s.wet));
        s.sheen *= 1.0f - s.wet;
    }
    float3 N = s.normal;
    float3 L = stageSunDirection(F);
    float altitude = F.camera.x + s.position.y;
    float3 sunE = mix(A.sunAtCloudBase.rgb, A.sunAtCloudTop.rgb, saturate((altitude - 1000.0f) / 8000.0f));
    float3 groundL = A.groundBounce.rgb * (sceneGroundAlbedo(int(F.world.x)) / 0.06f);
    float3 skyE = A.skyIrradianceSea.rgb * (0.55f + 0.45f * N.y) + groundL * PI * saturate(-N.y) * 0.5f;
    const float3 cabinRed = float3(0.05f, 0.0045f, 0.0035f);
    float dl = 1.0f - s.interior;
    float3 sunVis = canopyShadow(s.position, L, F, canopyShadowMap) * s.sun;
    // 贴着胸口的东西，朝里的一面（+Z 朝着身体）看到的是自己的身体而不是天空
    float2 torso = F.bodyShadow.xz + float2(0.0f, 0.06f);
    float nearTorso = F.bodyShadow.w * smoothstep(0.32f, 0.16f, length(s.position.xz - torso));
    float3 bodyL = 0.04f * A.skyIrradianceSea.rgb / PI;              // 深色跳伞服
    float3 sky = skyE * (1.0f - 0.55f * nearTorso * saturate(N.z)) * s.occlusion;

    // 几何高光抗锯齿（Tokuyoshi & Kaplanyan）：法线在一个像素里变得越快，高光越宽，细环上不闪
    float variance = 0.25f * (dot(dnx, dnx) + dot(dny, dny));
    float a = s.roughness * s.roughness;
    float a2 = saturate(a * a + min(2.0f * variance, 0.18f));
    float NdotV = max(dot(N, V), 1e-3f);
    float NdotL = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float NdotH = saturate(dot(N, H));
    float m = 1.0f - saturate(dot(V, H));
    float3 Fs = s.F0 + (1.0f - s.F0) * (m * m) * (m * m) * m;
    float3 spec = Fs * ggx(NdotH, NdotV, NdotL, a2, s.roughness) * NdotL * s.specScale;

    // 天空的反射：反射方向转到世界坐标查天空表；朝下的反射看到地面，朝身体的看到自己
    float3 R = reflect(-V, N);
    float3 Rw = rotateHeading(R, F.heading.x, F.heading.y);
    float camR = ATM_BOTTOM + max(altitude, 1.0f) * 0.001f;
    float3 env = skyViewLookup(skyLUT, normalize(float3(Rw.x, max(Rw.y, 0.002f), Rw.z)), F.sunDirection.xyz, camR, false);
    env = mix(env, groundL, smoothstep(0.02f, -0.08f, Rw.y));
    env = mix(env, bodyL, nearTorso * saturate(R.z * 1.6f + 0.15f) * 0.9f);
    env = mix(cabinRed * 0.2f / PI, env, dl * dl);
    float3 specEnv = env * envBRDF(s.F0, s.roughness, NdotV) * s.specScale * s.occlusion;

    float3 diffuse = s.albedo / PI * (sunE * sunVis * NdotL + sky * (0.12f + 0.88f * dl) + s.cabinE);
    float3 radiance = diffuse + sunE * sunVis * spec + specEnv;
    if (s.sheen > 0.0f) {
        // 尼龙的绒光：掠射角上一层发灰的柔光（黑色织带的轮廓靠它）
        float rim = pow(1.0f - NdotV, 5.0f);
        radiance += rim * 0.1f * s.sheen * mix(s.albedo, float3(0.5f), 0.5f) / PI
                  * (sunE * sunVis * saturate(dot(N, L) + 0.3f) * 0.5f + sky);
    }
    if (s.bead > 0.0f) {
        // 水珠像一颗小透镜：边上一圈暗（折射看到的是更深处，接触的地方还有一圈影子），
        // 中间是天空和太阳的一个很亮的小倒影（球面上总有一点把它们反射进眼睛）
        float rim = smoothstep(0.45f, 1.0f, s.beadR);
        radiance *= 1.0f - 0.5f * rim * s.bead;
        float glint = exp(-s.beadR * s.beadR * 9.0f);
        float3 skyAbove = skyViewLookup(skyLUT, normalize(float3(0.15f, 1.0f, 0.1f)), F.sunDirection.xyz, camR, false);
        radiance += s.bead * glint * (sunE * sunVis * 0.05f + skyAbove * 0.6f + env * 0.4f);
    }
    return radiance;
}

// MARK: - 机舱

/// 舱顶的四盏红色夜灯（ProceduralMeshes.lampZ / lampY 要一样）：点光源，灯罩朝下，侧面也漏一点
constant float CABIN_LAMP_Z[4] = { -2.275f, 0.475f, 3.225f, 5.975f };
#define CABIN_LAMP_Y 2.685f
#define CABIN_LAMP_I float3(0.3f, 0.034f, 0.026f)

/// 四盏夜灯照到这一点的漫反射 + GGX 高光（加在 shadeGear 的结果上）
static inline float3 cabinLamps(float3 P, float3 N, float3 V, float3 albedo, float3 F0, float roughness,
                                float specScale, constant ObjectUniforms &O) {
    float a = roughness * roughness;
    float a2 = max(a * a, 0.002f);
    float NdotV = max(dot(N, V), 1e-3f);
    float3 sum = float3(0.0f);
    for (int i = 0; i < 4; i++) {
        float3 lp = (O.model * float4(0.0f, CABIN_LAMP_Y, CABIN_LAMP_Z[i], 1.0f)).xyz;
        float3 d = lp - P;
        float d2 = max(dot(d, d), 0.05f);
        float3 L = d * rsqrt(d2);
        float NdotL = saturate(dot(N, L));
        if (NdotL <= 0.0f) continue;
        float down = saturate(L.y);
        float3 E = CABIN_LAMP_I * ((0.06f + 0.94f * down * sqrt(down)) * NdotL / d2);
        float3 H = normalize(L + V);
        float m = 1.0f - saturate(dot(V, H));
        float3 Fs = F0 + (1.0f - F0) * (m * m) * (m * m) * m;
        sum += E * (albedo / PI + Fs * ggx(saturate(dot(N, H)), NdotV, NdotL, a2, roughness) * specScale);
    }
    return sum;
}

/// 射线和机身圆柱（半径 1.75 米，轴沿 z）的两个交点；尾段的截面圆心往后越来越高，按交点附近的圆心迭代
static inline float2 fuselageHits(float3 p, float3 L, bool farSide) {
    float cy = 1.05f, t = 0.0f;
    float a = dot(L.xy, L.xy);
    for (int i = 0; i < 3; i++) {
        float2 o = float2(p.x, p.y - cy);
        float b = dot(o, L.xy), c = dot(o, o) - 1.75f * 1.75f;
        float disc = b * b - a * c;
        if (disc <= 0.0f) return float2(-1.0f, 0.0f);
        t = (-b + (farSide ? 1.0f : -1.0f) * sqrt(disc)) / a;
        cy = 1.05f + max(-4.5f - (p.z + L.z * t), 0.0f) * 0.18f;
    }
    return float2(t, cy);
}

/// 机身在这里有没有壳（>0 有，单位米，离敞口的边多远）：货舱段（z > -4.5）一圈都是封死的，
/// 尾段只有上半截（0.6π ~ 1.4π），再往后（z < -8.6）整个敞开
static inline float fuselageCover(float3 q, float cy) {
    if (q.z > -4.5f) return 1.0f;
    if (q.z < -8.6f) return q.z + 8.6f;
    float phi = atan2(q.x, cy - q.y);
    if (phi < 0.0f) phi += 2.0f * PI;
    return min(min(phi - 0.6f * PI, 1.4f * PI - phi) * 1.75f, q.z + 8.6f);
}

/// 太阳照不照得到机舱里的这一点（机身坐标）：朝太阳射一条线，看它从哪儿出机身。
/// 只有尾段下面敞开的两侧和最后面的开口能透进来；地板、跳板挡住往下的光。边上软 3 厘米
static inline float cabinSunVisibility(float3 p, float3 L) {
    if (L.y < 0.0f) {
        float3 f = p + L * (-p.y / L.y);
        if (p.y > 0.002f && f.z > -8.0f && abs(f.x) < 1.4f) return 0.0f;
    }
    if (dot(L.xy, L.xy) < 1e-6f) return L.z < 0.0f ? 1.0f : 0.0f;
    float cy0 = 1.05f + max(-4.5f - p.z, 0.0f) * 0.18f;
    bool outside = length(float2(p.x, p.y - cy0)) > 1.75f;
    if (outside) {
        // 在机身圆柱外面（跳板两边）：射线可能从敞开的那侧穿进来，再从顶上出去
        float2 entry = fuselageHits(p, L, false);
        if (entry.x <= 0.0f) return 1.0f;
        float coverIn = fuselageCover(p + L * entry.x, entry.y);
        if (coverIn > 0.03f) return 0.0f;
    }
    float2 exitHit = fuselageHits(p, L, true);
    if (exitHit.x <= 0.0f) return 1.0f;
    return 1.0f - smoothstep(-0.03f, 0.03f, fuselageCover(p + L * exitHit.x, exitHit.y));
}

/// 隔热垫的高度（0…1）：一块块毯子（弧向 0.62 米、z 向在两个加强框之间，边上收进去），
/// 毯子上菱形的绗缝（边长约 9 厘米，鼓起来的枕头形）。q = (弧长, z)，或者隔板上的 (x, y)
static inline float quiltHeight(float2 q, thread float &pillow) {
    float2 cell = float2(0.62f, 0.55f);
    float2 f = fract((q - float2(0.0f, -4.2f)) / cell);
    float2 edgeDist = min(f, 1.0f - f) * cell;
    float edge = smoothstep(0.0f, 0.07f, min(edgeDist.x, edgeDist.y));
    float2 g = fract(float2(q.x + q.y, q.x - q.y) / 0.13f);
    pillow = sqrt(max(sin(PI * g.x) * sin(PI * g.y), 0.0f));
    return (0.35f + 0.65f * pillow) * edge;
}

/// 座椅编织带的高度：5 厘米宽的带子一横一竖地压着编（篮纹），c 是座面上（或靠背上）的二维坐标（米）
static inline float weaveHeight(float2 c) {
    float2 gw = c / 0.05f;
    float2 f = fract(gw);
    int2 cellI = int2(floor(gw));
    bool along = ((cellI.x + cellI.y) & 1) == 0;
    float across = along ? f.x : f.y, lengthwise = along ? f.y : f.x;
    return pow(max(sin(PI * across), 0.0f), 0.35f) * (0.55f + 0.45f * sin(PI * lengthwise));
}

/// 黄黑斜条（0 黄 1 黑），t 是沿条纹法向的坐标（条宽 = 1），fw 是一个像素有多宽（同样单位）
static inline float hazardStripe(float t, float fw) {
    float d = abs(fract(t) - 0.5f) * 2.0f;          // 0 在黑条中间 … 1 在黄条中间
    return 1.0f - smoothstep(0.5f - fw, 0.5f + fw, d);
}

/// 机舱里的表面：按材质给反照率、粗糙度、凹凸（机身坐标里现算），然后和装备同一套光
/// （太阳只照得到舱门附近、天光往里衰减），再加四盏夜灯。舷窗另算（透出去是天）。
static inline float3 shadeCabin(int material, float3 albedo, float3 Po, float3 P, float3 N, float3 V,
                                float interior, float footprint, float3 dnx, float3 dny,
                                constant FrameUniforms &F, constant AtmosphereConstants &A,
                                texture2d<float> skyLUT, texture2d<float> canopyShadowMap, constant ObjectUniforms &O) {
    if (material == MATERIAL_WINDOW) {
        // 视线穿过玻璃：天（低于地平线是太阳照着的云海），玻璃有一点发绿；掠射角上反射舱里暗红的光
        float3 Vw = rotateHeading(-V, F.heading.x, F.heading.y);
        float altitude = F.camera.x + P.y;
        float camR = ATM_BOTTOM + max(altitude, 1.0f) * 0.001f;
        float3 sky = skyViewLookup(skyLUT, normalize(float3(Vw.x, max(Vw.y, 0.002f), Vw.z)), F.sunDirection.xyz,
                                   camR, false);
        float3 deck = (A.sunAtCloudTop.rgb * saturate(F.sunDirection.y) * 0.85f + A.skyIrradianceSea.rgb * 0.6f) / PI;
        float3 outside = mix(sky, deck, smoothstep(-0.01f, -0.08f, Vw.y));
        float m = 1.0f - saturate(dot(N, V));
        float fres = 0.04f + 0.96f * (m * m) * (m * m) * m;
        float3 inside = float3(0.05f, 0.0045f, 0.0035f) * (0.3f / PI);
        return outside * float3(0.86f, 0.9f, 0.88f) * (1.0f - fres) + inside * fres;
    }
    float3x3 rot = float3x3(O.model[0].xyz, O.model[1].xyz, O.model[2].xyz);
    float3 No = transpose(rot) * N;              // 机身坐标里的法线（朝着看的人）
    float roughness = 0.5f, specScale = 0.8f, sheen = 0.0f, metallic = 0.0f, occlusion = 1.0f;
    float3 base = albedo;
    float3 grad = float3(0.0f);                  // 机身坐标里高度场的梯度：法线 = N - 梯度的切向部分
    float n1 = revealNoise(Po * 5.0f), n2 = revealNoise(Po * 21.0f + 3.0f);

    if (material == MATERIAL_QUILT) {
        float2 q; float3 T1, T2;
        if (abs(No.z) > 0.7f) {                  // 前端隔板：平面
            q = Po.xy; T1 = float3(1.0f, 0.0f, 0.0f); T2 = float3(0.0f, 1.0f, 0.0f);
        } else {                                 // 舱壁：截面上的弧长和 z（尾段的截面圆心往后越来越高）
            float cy = 1.05f + max(-4.5f - Po.z, 0.0f) * 0.18f;
            float phi = atan2(Po.x, cy - Po.y);
            if (phi < 0.0f) phi += 2.0f * PI;        // 接缝放在地板下面看不到的地方
            q = float2(phi * 1.75f, Po.z);
            T1 = float3(cos(phi), sin(phi), 0.0f); T2 = float3(0.0f, 0.0f, 1.0f);
        }
        float pillow, p1, p2;
        const float eps = 0.003f, depth = 0.012f;
        float h = quiltHeight(q, pillow);
        float hs = (quiltHeight(q + float2(eps, 0.0f), p1) - h) / eps;
        float hz = (quiltHeight(q + float2(0.0f, eps), p2) - h) / eps;
        float detail = saturate(0.13f / (footprint * 8.0f) - 0.5f);
        grad = (hs * T1 + hz * T2) * depth * detail;
        occlusion = mix(1.0f, mix(0.5f, 1.0f, h) * mix(0.75f, 1.0f, pillow), detail);
        // 每块毯子旧得不一样，越往下越脏
        float2 blanket = floor((q - float2(0.0f, -4.2f)) / float2(0.62f, 0.55f));
        float tone = revealHash(float3(blanket, 1.0f));
        base *= (0.86f + 0.24f * tone) * mix(float3(1.0f), float3(0.96f, 1.03f, 0.97f), revealHash(float3(blanket, 7.0f)));
        base *= 0.78f + 0.22f * smoothstep(0.0f, 0.9f, Po.y);
        roughness = 0.9f; specScale = 0.2f; sheen = 0.6f;
    } else if (material == MATERIAL_PAINTED) {
        base *= 0.86f + 0.2f * n1 + 0.08f * n2;
        roughness = 0.38f + 0.3f * n2;
    } else if (material == MATERIAL_ALUMINUM) {
        metallic = 1.0f;
        roughness = 0.26f + 0.16f * n2;
        base *= 0.9f + 0.12f * n1;
    } else if (material == MATERIAL_HAZARD) {
        float t = (Po.x + Po.y + Po.z) / 0.1f;
        float black = hazardStripe(t, footprint / 0.1f * 1.5f);
        base = mix(base, float3(0.022f, 0.022f, 0.024f), black);
        float chip = smoothstep(0.66f, 0.72f, revealNoise(Po * 38.0f)) * smoothstep(0.3f, 0.7f, n1);
        base = mix(base, float3(0.2f, 0.2f, 0.21f), chip);
        roughness = mix(0.5f, 0.32f, chip);
        metallic = chip * 0.6f;
    } else if (material == MATERIAL_TREAD) {
        roughness = 0.8f; specScale = 0.6f;
        float detail = saturate(0.02f / (footprint * 6.0f) - 0.5f);
        // 防滑颗粒（几毫米的斑点），中间过道走得多，磨得亮一点、滑一点
        float grit = revealNoise(Po * 160.0f);
        base *= 1.0f + (grit - 0.5f) * 0.35f * detail;
        float aisle = 1.0f - smoothstep(0.25f, 0.65f, abs(Po.x));
        float wear = aisle * (0.55f + 0.45f * n1);
        base *= 1.0f + 0.4f * wear;
        roughness -= 0.28f * wear;
        if (Po.z > -4.5f) {
            // 货舱地板：拼缝（x = -1、0、1，z 每 0.5 米），拼缝两边每 10 厘米一颗沉头螺钉，拼缝交叉处是系留环的凹坑
            float2 c = float2(Po.x, Po.z + 4.2f);
            float2 nearest = round(c / float2(1.0f, 0.5f)) * float2(1.0f, 0.5f);
            float2 rel = c - nearest;
            float seamD = min(abs(rel.x), abs(rel.y));
            float seam = 1.0f - smoothstep(0.0015f, 0.0015f + footprint * 1.5f, seamD);
            base *= 1.0f - 0.65f * seam;
            float r = length(rel);
            bool hasRing = abs(nearest.x) <= 1.0f && nearest.y > -0.1f && nearest.y < 12.1f;
            float2 s1 = float2(abs(rel.x) - 0.022f, (fract(rel.y / 0.1f) - 0.5f) * 0.1f);
            float2 s2 = float2((fract(rel.x / 0.1f) - 0.5f) * 0.1f, abs(rel.y) - 0.022f);
            float screw = (1.0f - smoothstep(0.0032f, 0.0032f + footprint * 1.2f, min(length(s1), length(s2))))
                        * detail * (hasRing ? smoothstep(0.065f, 0.08f, r) : 1.0f);
            base = mix(base, float3(0.17f, 0.17f, 0.18f), screw);
            roughness = mix(roughness, 0.35f, screw);
            if (hasRing) {
                float cup = 1.0f - smoothstep(0.046f, 0.046f + footprint * 1.5f, r);
                base = mix(base, float3(0.018f, 0.018f, 0.02f), cup * 0.9f);
                occlusion = mix(1.0f, 0.45f, cup);
                float rim = exp(-pow((r - 0.047f) / 0.0035f, 2.0f));
                float2 dir = r > 1e-4f ? rel / r : float2(0.0f);
                grad.xz += dir * rim * 0.7f;
            }
        } else {
            // 跳板：每 12 厘米一道横着的防滑棱（顶上磨得发亮），尾端 18 厘米宽的黄黑警示条
            float w = fract((Po.z + 8.0f) / 0.12f);
            float ridge = smoothstep(0.0f, 0.06f, w) * (1.0f - smoothstep(0.2f, 0.26f, w));
            float slope = (smoothstep(0.0f, 0.06f, w + 0.02f) - smoothstep(0.0f, 0.06f, w)) * (w < 0.1f ? 1.0f : 0.0f)
                        - (smoothstep(0.2f, 0.26f, w + 0.02f) - smoothstep(0.2f, 0.26f, w)) * (w > 0.15f ? 1.0f : 0.0f);
            float ridgeDetail = saturate(0.12f / (footprint * 8.0f) - 0.5f);
            grad.z += slope / (0.02f * 0.12f) * 0.004f * ridgeDetail;
            base *= 1.0f + 0.45f * ridge * ridgeDetail;
            roughness -= 0.2f * ridge * ridgeDetail;
            if (Po.z < -7.82f) {
                float black = hazardStripe((Po.x + Po.z) / 0.09f, footprint / 0.09f * 1.5f);
                float3 stripe = mix(float3(0.6f, 0.42f, 0.02f), float3(0.022f), black);
                float chip = smoothstep(0.62f, 0.7f, revealNoise(Po * 30.0f)) * (0.5f + 0.5f * n1);
                base = mix(stripe, float3(0.16f, 0.16f, 0.17f), chip);
                roughness = mix(0.5f, 0.35f, chip);
            }
        }
    } else {                                     // MATERIAL_SEAT：红色尼龙编织带
        bool pan = abs(No.y) > 0.6f;
        float2 c = pan ? Po.xz : Po.yz;
        const float eps = 0.002f, depth = 0.003f;
        float h = weaveHeight(c);
        float ha = (weaveHeight(c + float2(eps, 0.0f)) - h) / eps;
        float hb = (weaveHeight(c + float2(0.0f, eps)) - h) / eps;
        float detail = saturate(0.05f / (footprint * 6.0f) - 0.5f);
        grad = (pan ? float3(ha, 0.0f, hb) : float3(0.0f, ha, hb)) * depth * detail;
        occlusion = mix(1.0f, 0.55f + 0.45f * h, detail);
        float strap = revealHash(float3(floor(c / 0.05f), 3.0f));
        base *= 0.88f + 0.2f * strap * detail + 0.1f * n1;
        // 每 0.5 米一个座位，中间一道黑色的分隔带
        float divider = abs(fract((Po.z + 2.4f) / 0.5f + 0.5f) - 0.5f) * 0.5f;
        base = mix(base, float3(0.025f, 0.02f, 0.02f), 1.0f - smoothstep(0.016f, 0.016f + footprint * 1.5f, divider));
        roughness = 0.72f; specScale = 0.4f; sheen = 1.0f;
    }

    float3 g = rot * grad;
    g -= dot(g, N) * N;
    float3 Nb = normalize(N - g);
    GearSurface s;
    s.position = P;
    s.normal = Nb;
    s.albedo = base * (1.0f - metallic);
    s.F0 = mix(float3(0.04f), base, metallic);
    s.roughness = roughness;
    s.specScale = specScale;
    s.sheen = sheen;
    s.occlusion = occlusion * 0.7f;               // 尾段顶上有壳：天光只从两侧和后面进来
    s.interior = interior;
    s.cabinE = float3(0.05f, 0.0045f, 0.0035f) * 0.25f * interior;     // 夜灯在舱里来回反射的那点光
    s.sun = cabinSunVisibility(Po, transpose(rot) * stageSunDirection(F));
    s.wet = 0.0f;
    s.bead = 0.0f;
    s.beadR = 1.0f;
    float3 radiance = shadeGear(s, V, dnx, dny, F, A, skyLUT, canopyShadowMap);
    return radiance + cabinLamps(P, Nb, V, s.albedo, s.F0, roughness, specScale, O) * occlusion;
}

/// 扶杆：喷黄漆的钢管、黑色橡胶握把、镀锌件。在你的房间里时按屋里的光（顶上一盏柔和的灯 + 四周墙的反光），
/// 飞机在它周围长出来以后换成机舱里的光
static inline float3 shadeBar(int material, float3 albedo, float3 P, float3 N, float3 V, float interior,
                              float3 dnx, float3 dny, constant FrameUniforms &F, constant AtmosphereConstants &A,
                              texture2d<float> skyLUT, texture2d<float> canopyShadowMap, constant ObjectUniforms &O) {
    float metallic = material == MATERIAL_BAR_METAL ? 1.0f : 0.0f;
    GearSurface s;
    s.position = P;
    s.normal = N;
    s.albedo = albedo * (1.0f - metallic);
    s.F0 = mix(float3(material == MATERIAL_BAR_GRIP ? 0.035f : 0.045f), albedo, metallic);
    s.roughness = material == MATERIAL_BAR ? 0.3f : (material == MATERIAL_BAR_GRIP ? 0.6f : 0.32f);
    s.specScale = 1.0f;
    s.sheen = 0.0f;
    s.occlusion = 0.7f;
    s.interior = interior;
    s.cabinE = float3(0.05f, 0.0045f, 0.0035f) * 0.25f * interior;
    float3x3 rot = float3x3(O.model[0].xyz, O.model[1].xyz, O.model[2].xyz);
    s.sun = cabinSunVisibility(transpose(rot) * (P - O.model[3].xyz), transpose(rot) * stageSunDirection(F));
    s.wet = 0.0f;
    s.bead = 0.0f;
    s.beadR = 1.0f;
    float3 cabin = shadeGear(s, V, dnx, dny, F, A, skyLUT, canopyShadowMap)
                 + cabinLamps(P, N, V, s.albedo, s.F0, s.roughness, s.specScale, O);

    // 房间：顶上偏后一盏柔和的灯（高光宽一点），四周墙的反光当成均匀的灰
    const float3 roomE = float3(0.5f, 0.49f, 0.46f);
    float3 Lr = normalize(float3(0.25f, 1.0f, 0.4f));
    float NdotL = saturate(dot(N, Lr));
    float NdotV = max(dot(N, V), 1e-3f);
    float rough = max(s.roughness, 0.42f);
    float a = rough * rough;
    float3 H = normalize(Lr + V);
    float m = 1.0f - saturate(dot(V, H));
    float3 Fs = s.F0 + (1.0f - s.F0) * (m * m) * (m * m) * m;
    float3 room = s.albedo / PI * roomE * (0.6f + 0.4f * N.y)
                + Fs * ggx(saturate(dot(N, H)), NdotV, NdotL, a * a, rough) * NdotL * roomE * 0.9f
                + roomE * (0.32f / PI) * envBRDF(s.F0, s.roughness, NdotV);
    float roomMix = F.reveal.w < 0.0f ? 1.0f : 1.0f - smoothstep(0.4f, 3.0f, F.reveal.w);
    float3 radiance = mix(cabin, room, roomMix);
    // 还没握住的时候慢慢一明一暗，提示去握
    if (F.reveal.w < 0.0f) radiance *= 1.0f + 0.3f * (0.5f + 0.5f * sin(F.camera.y * 3.5f));
    return radiance;
}

fragment float4 objectFragment(ObjectOut in [[stage_in]],
                               constant ViewUniforms *views [[buffer(0)]],
                               constant FrameUniforms &F [[buffer(1)]],
                               constant AtmosphereConstants &A [[buffer(2)]],
                               constant ObjectUniforms &O [[buffer(3)]],
                               constant SkinUniforms &skin [[buffer(4)]],
                               texture2d<float> skyLUT [[texture(0)]],
                               texture2d<float> canopyShadowMap [[texture(14)]]) {
    float3 eye = views[in.viewIndex].cameraPosition.xyz;
    float3 V = normalize(eye - in.stagePos);
    float3 N = normalize(in.normal);
    if (dot(N, V) < 0.0f) N = -N;                 // 两面都画（舱壁、伞衣）
    // 导数在分支外面算（分支里 2×2 像素块可能走不同的路，导数没定义）
    float3 dpx = dfdx(in.stagePos), dpy = dfdy(in.stagePos);
    float2 duvx = dfdx(in.uv), duvy = dfdy(in.uv);
    float3 dnx = dfdx(N), dny = dfdy(N);
    float footprint = max(max(length(dpx), length(dpy)), 1e-6f);     // 一个像素在表面上多大（米）
    // 太阳在世界坐标里；伞下转向是世界绕着你转，舞台里的东西要按航向反过来转一下太阳
    float3 L = stageSunDirection(F);
    int material = int(in.color.a + 0.5f);
    float3 albedo = in.color.rgb;
    // 伞衣、袖子：颜色按皮肤的图案现算（边按一个像素在 uv 上多宽抗锯齿），然后照原来的伞布 / 织带打光。
    // 袖子的 uv.y 是绕一圈的比例，织纹要米：一圈约 0.32 米
    float2 twillUV = in.uv, twillDx = duvx, twillDy = duvy;
    bool isSleeve = material == MATERIAL_SLEEVE;
    if (material == MATERIAL_CANOPY) {
        albedo = canopySkinAlbedo(in.uv, abs(duvx) + abs(duvy), skin);
        material = MATERIAL_FABRIC;
    } else if (material == MATERIAL_FABRIC) {
        albedo = skin.slider.rgb;                 // 伞布做的只剩滑块：跟着伞换色
    } else if (material == MATERIAL_SLEEVE) {
        albedo = sleeveSkinAlbedo(in.uv, abs(duvx) + abs(duvy), skin);
        material = MATERIAL_WEBBING;
        const float2 toMeters = float2(1.0f, 0.32f);
        twillUV *= toMeters; twillDx *= toMeters; twillDy *= toMeters;
    }
    bool isBar = material >= MATERIAL_BAR && material <= MATERIAL_BAR_METAL;
    float daylight = 1.0f - in.interior;
    // 开场：还没实体化的地方丢掉（深度留 0，系统透出你的房间）；扶杆和替身手一直在
    float2 reveal = float2(1.0f, 0.0f);
    if (revealActive && !isBar && material != MATERIAL_SOFT) {
        reveal = revealAt(in.stagePos, F);
        if (reveal.x < 0.5f) discard_fragment();
    }

    float altitude = F.camera.x + in.stagePos.y;
    float3 sunE = mix(A.sunAtCloudBase.rgb, A.sunAtCloudTop.rgb, saturate((altitude - 1000.0f) / 8000.0f));
    float groundAlbedo = sceneGroundAlbedo(int(F.world.x));
    float3 groundL = A.groundBounce.rgb * (groundAlbedo / 0.06f);       // 地面往上的平均辐亮度
    float3 skyE = A.skyIrradianceSea.rgb * (0.55f + 0.45f * N.y) + groundL * PI * saturate(-N.y) * 0.5f;
    const float3 cabinRed = float3(0.05f, 0.0045f, 0.0035f);   // 货舱里的红色夜灯（照度）

    float3 radiance;
    if (isBar) {
        radiance = shadeBar(material, albedo, in.stagePos, N, V, in.interior, dnx, dny, F, A, skyLUT, canopyShadowMap, O);
    } else if (material >= MATERIAL_QUILT) {
        radiance = shadeCabin(material, albedo, in.objectPos, in.stagePos, N, V, in.interior, footprint, dnx, dny,
                              F, A, skyLUT, canopyShadowMap, O);
    } else if (material == MATERIAL_EMISSIVE) {
        radiance = albedo;
    } else if (material == MATERIAL_LAMP_RED) {
        radiance = albedo * (O.params.x < 0.5f ? 1.0f : 0.004f);
    } else if (material == MATERIAL_LAMP_GREEN) {
        radiance = albedo * (O.params.x > 0.5f ? 1.0f : 0.004f);
    } else if (material >= MATERIAL_WEBBING) {
        // 装备。室内程度用机舱里的程度（顶点里那一位存的是 uv）
        GearSurface g;
        g.position = in.stagePos;
        g.interior = O.params.y;
        g.cabinE = cabinRed * O.params.y;
        g.sun = (1.0f - O.params.y) * (1.0f - O.params.y);
        g.wet = material == MATERIAL_METAL ? 0.0f : O.params.z;
        g.bead = 0.0f;
        g.beadR = 1.0f;
        g.occlusion = 1.0f;
        g.sheen = 0.0f;
        g.specScale = 1.0f;
        float metallic = 0.0f;
        float3 diffuseAlbedo = albedo;
        if (material == MATERIAL_WEBBING) {
            // 织出来的面不是一整块光滑的面，镜面反射比实心塑料弱得多（黑织带在太阳下也还是黑的）
            g.roughness = 0.75f; g.sheen = 1.0f; g.specScale = 0.4f;
            // 斜纹：一道道 1.8 毫米的斜棱，按 uv（米）画；小于几个像素就淡掉（VR 里细纹会闪）
            float3 Tu = cross(dpy, N) * twillDx.x + cross(N, dpx) * twillDy.x;
            float3 Tv = cross(dpy, N) * twillDx.y + cross(N, dpx) * twillDy.y;
            float footprint = max(length(twillDx) + length(twillDy), 1e-6f);
            float fade = saturate(0.0018f / (footprint * 3.0f) - 0.3f);
            if (fade > 0.0f && length(Tu) > 1e-9f && length(Tv) > 1e-9f) {
                Tu = normalize(Tu); Tv = normalize(Tv);
                float phase = (twillUV.x * 0.8f + twillUV.y) / 0.0018f * 2.0f * PI;
                float warp = sin(twillUV.x / 0.0009f * 2.0f * PI);
                diffuseAlbedo *= 1.0f + fade * (0.12f * sin(phase) + 0.05f * warp);
                N = normalize(N - (Tu * 0.8f + Tv) * (cos(phase) * 0.13f * fade));
            }
            // 袖子的布褶：网格本身只有几道大的起伏，换成大面积鲜艳的皮肤图案以后像一根光滑的管子。
            // 加两层褶子扰动法线：绕着小臂一道道、有点歪斜的横褶（4~6 厘米一道，靠袖口密），顺着小臂的几道长褶；
            // 褶子的凹处颜色压暗一点。按像素大小淡掉（远了不画，不闪）
            if (isSleeve && length(Tu) > 1e-9f && length(Tv) > 1e-9f) {
                float3 Ta = normalize(Tu), Tb = normalize(Tv);
                float along = twillUV.x, around = twillUV.y;
                float foldFade = saturate(0.02f / (footprint * 3.0f) - 0.3f);
                float p1 = along / 0.05f * 2.0f * PI + 2.2f * sin(around / 0.11f * 2.0f * PI) + 6.0f * along * along;
                float p2 = around / 0.07f * 2.0f * PI + 3.0f * along;
                float h = 0.65f * sin(p1) + 0.35f * sin(p2);
                float2 slope = float2(0.65f * cos(p1) * (2.0f * PI / 0.05f + 12.0f * along),
                                      0.65f * cos(p1) * 2.2f * (2.0f * PI / 0.11f) + 0.35f * cos(p2) * (2.0f * PI / 0.07f));
                N = normalize(N - (Ta * slope.x + Tb * slope.y) * (0.0016f * foldFade));
                diffuseAlbedo *= 1.0f - 0.10f * foldFade * saturate(-h);
            }
        } else if (material == MATERIAL_METAL) {
            g.roughness = 0.24f; metallic = 1.0f;
        } else if (material == MATERIAL_PLASTIC) {
            g.roughness = 0.36f;
        } else {
            g.roughness = 0.58f;
        }
        g.normal = N;
        g.F0 = mix(float3(0.04f), albedo, metallic);
        g.albedo = diffuseAlbedo * (1.0f - metallic);
        radiance = shadeGear(g, V, dnx, dny, F, A, skyLUT, canopyShadowMap);
    } else if (material == MATERIAL_FABRIC) {
        // 正面挨太阳照；背面看过去是透过来的光（尼龙伞布很薄，逆光下整片发亮）
        float lit = saturate(dot(N, L)), through = saturate(-dot(N, L));
        // 缝线：每个气室之间的承重肋（挂伞绳，几层布加加强带，透光最少），气室中间还有一道不承重的肋；
        // 弦向每 0.6 米一道拼缝。从下面逆光看，就是一格一格的暗线
        const float cellWidth = 8.4f / 9.0f;
        float u = in.uv.x, v = in.uv.y;
        float du = abs(fract(u / cellWidth + 0.5f) - 0.5f) * cellWidth;
        float dh = abs(fract(u / cellWidth) - 0.5f) * cellWidth;
        float dv = abs(fract(v / 0.6f + 0.5f) - 0.5f) * 0.6f;
        float fu = max(fwidth(u), 1e-4f), fv = max(fwidth(v), 1e-4f);
        float rib = 1.0f - smoothstep(0.015f, 0.015f + fu * 1.5f, du);
        float halfRib = 1.0f - smoothstep(0.008f, 0.008f + fu * 1.5f, dh);
        float seam = 1.0f - smoothstep(0.006f, 0.006f + fv * 1.5f, dv);
        // 防撕裂格（ripstop）：每 6 毫米一道粗一点的线，近看才有
        float grid = 0.0f;
        float gridFade = saturate(0.006f / (max(fu, fv) * 4.0f) - 0.25f);
        if (gridFade > 0.0f) {
            float2 g = abs(fract(float2(u, v) / 0.006f + 0.5f) - 0.5f) * 0.006f;
            float2 w = float2(fu, fv) * 1.2f + 0.0003f;
            grid = max(1.0f - smoothstep(0.0f, w.x, g.x), 1.0f - smoothstep(0.0f, w.y, g.y)) * gridFade;
        }
        float layers = 1.0f - 0.6f * rib - 0.3f * halfRib - 0.25f * seam - 0.12f * grid;
        // 尼龙有一层柔和的光泽
        float3 H = normalize(L + V);
        float gloss = pow(saturate(dot(N, H)), 24.0f) * 0.12f;
        // 透过来的光被染成布的颜色（尼龙对自己颜色的光透得最多），所以逆光的伞衣颜色更浓、更亮
        float3 transmitted = albedo * sqrt(albedo) * 1.6f * through * layers;
        radiance = albedo / PI * (sunE * lit * (0.85f + 0.15f * layers) + skyE) + sunE * transmitted / PI
                 + sunE * gloss * lit;
        // 每个气室是一个鼓包：肋那里是凹进去的折缝，光照不进去（网格上只鼓了十几厘米，光靠法线看不太出来）
        float across = fract(u / cellWidth);
        radiance *= mix(0.55f, 1.0f, smoothstep(0.0f, 0.6f, 4.0f * across * (1.0f - across)));
    } else {
        // 太阳只照得到舱门附近（室内程度低的地方）；天光往里衰减得慢一些；越往里红灯越明显
        float3 E = sunE * saturate(dot(N, L)) * daylight * daylight
                 + skyE * (0.12f + 0.88f * daylight)
                 + cabinRed * in.interior;
        radiance = albedo * E / PI;
        if (material == MATERIAL_SOFT) {
            float rim = pow(1.0f - saturate(dot(N, V)), 3.0f);
            radiance += rim * 0.35f * (sunE * 0.05f * daylight + skyE * 0.08f + cabinRed * 0.3f * in.interior);
        }
    }
    float3 c = tonemap(radiance * F.exposure.x) * F.camera.z;
    c += REVEAL_GLOW_COLOR * reveal.y * F.camera.z;
    // 开场还在房间里时，开头的淡入是从透明淡入（预乘），不是从黑色：屋里不会先冒出一根黑杆子
    return float4(c, F.reveal.w < 0.0f ? F.camera.z : 1.0f);
}

// MARK: - 手套（Shared/Glove.swift：苹果示例的手套，按手部追踪的关节蒙皮）

/// 手套上的水珠：按绑定姿势里的位置（跟着手套走、大小是真的毫米）在 7 毫米的格子里撒，越湿越多。
/// x：在水珠上的程度（边上软），y：离水珠中心多远 ÷ 半径
static inline float2 waterBead(float3 p, float wet) {
    if (wet <= 0.01f) return float2(0.0f, 1.0f);
    const float cell = 0.007f;
    float3 c = floor(p / cell);
    uint3 h = pcg3d(uint3(int3(c) + 4096));
    float3 r3 = float3(h) * (1.0f / 4294967296.0f);
    if (r3.x > wet * 0.75f) return float2(0.0f, 1.0f);
    float3 center = (c + 0.35f + 0.3f * float3(r3.y, r3.z, fract(r3.x * 37.0f))) * cell;
    float radius = 0.0009f + 0.0014f * fract(r3.y * 17.0f + r3.z * 3.0f);
    float d = length(p - center) / radius;
    return float2(1.0f - smoothstep(0.82f, 1.0f, d), d);
}

struct GloveVertex {
    packed_float3 position;   // 绑定姿势（米）
    float u;
    packed_float3 normal;
    float v;
    uchar4 joints;
    uchar4 weights;           // 和 255
};

struct GloveOut {
    float4 position [[position]];
    float3 stagePos;
    float3 bindPos;            // 绑定姿势里的位置（米）：水珠贴着手套长，跟着手套动
    float3 normal;
    float2 uv;
    uint viewIndex [[flat]];
};

vertex GloveOut gloveVertex(uint vid [[vertex_id]],
                            ushort amp [[amplification_id]],
                            device const GloveVertex *vertices [[buffer(0)]],
                            constant ViewUniforms *views [[buffer(1)]],
                            constant float4x4 *skin [[buffer(2)]]) {
    GloveVertex v = vertices[vid];
    float4 w = float4(v.weights) / 255.0f;
    float4x4 m = skin[v.joints.x] * w.x + skin[v.joints.y] * w.y + skin[v.joints.z] * w.z + skin[v.joints.w] * w.w;
    float4 p = m * float4(float3(v.position), 1.0f);
    GloveOut o;
    o.position = views[amp].viewProjection * p;
    o.stagePos = p.xyz;
    o.bindPos = float3(v.position);
    o.normal = (m * float4(float3(v.normal), 0.0f)).xyz;
    o.uv = float2(v.u, v.v);
    o.viewIndex = amp;
    return o;
}

fragment float4 gloveFragment(GloveOut in [[stage_in]],
                              constant ViewUniforms *views [[buffer(0)]],
                              constant FrameUniforms &F [[buffer(1)]],
                              constant AtmosphereConstants &A [[buffer(2)]],
                              constant ObjectUniforms &O [[buffer(3)]],
                              constant SkinUniforms &skin [[buffer(4)]],
                              texture2d<float> skyLUT [[texture(0)]],
                              texture2d<float> albedoTex [[texture(1)]],
                              texture2d<float> normalTex [[texture(2)]],
                              texture2d<float> materialTex [[texture(3)]],
                              texture2d<float> canopyShadowMap [[texture(14)]]) {
    constexpr sampler tex(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float3 eye = views[in.viewIndex].cameraPosition.xyz;
    float3 V = normalize(eye - in.stagePos);
    float3 n0 = normalize(in.normal);
    float3 dnx = dfdx(n0), dny = dfdy(n0);
    float3 dpx = dfdx(in.stagePos), dpy = dfdy(in.stagePos);
    float2 duvx = dfdx(in.uv), duvy = dfdy(in.uv);
    float3 Ng = dot(n0, V) < 0.0f ? -n0 : n0;     // 袖口里面
    // 开场：手套也跟着飞机一起长出来（在房间里看到的是真手）
    float2 reveal = float2(1.0f, 0.0f);
    if (revealActive) {
        reveal = revealAt(in.stagePos, F);
        if (reveal.x < 0.5f) discard_fragment();
    }
    // 法线贴图：切线方向用屏幕导数现推（Schüler 的 cotangent frame），不用存切线
    float3 T = cross(dpy, Ng) * duvx.x + cross(Ng, dpx) * duvy.x;
    float3 B = cross(dpy, Ng) * duvx.y + cross(Ng, dpx) * duvy.y;
    float invmax = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-24f));
    float3 nm = normalTex.sample(tex, in.uv).xyz * 2.0f - 1.0f;
    nm.y = -nm.y;                                  // 转换时 v 翻过（Metal 纹理原点在左上）
    float3 N = normalize(T * (invmax * nm.x) + B * (invmax * nm.y) + Ng * max(nm.z, 0.05f));
    float4 mat = materialTex.sample(tex, in.uv);

    GearSurface g;
    g.position = in.stagePos;
    g.normal = N;
    // 皮肤：把贴图拆成布面和点缀，换成这一套的两种颜色（默认原样）
    float4 dyed = gloveSkinAlbedo(albedoTex.sample(tex, in.uv).rgb, skin);
    g.albedo = dyed.rgb;
    // 高光贴图原本给的是 RealityKit 的镜面颜色，有的地方（护条、标签）高到像金属；布、胶、塑料的反射率都在 2%~6%
    g.F0 = float3(min(pow(mat.b, 2.2f) * 0.25f, 0.06f));
    g.roughness = clamp(mat.r, 0.1f, 1.0f);
    g.specScale = 1.0f;
    g.sheen = 0.6f;
    g.occlusion = mat.g;
    g.interior = O.params.y;
    g.cabinE = float3(0.05f, 0.0045f, 0.0035f) * O.params.y;
    g.sun = (1.0f - O.params.y) * (1.0f - O.params.y);
    g.wet = O.params.z;
    float2 bead = waterBead(in.bindPos, O.params.z);
    float beadFade = saturate(0.0016f / (max(length(dfdx(in.stagePos)), length(dfdy(in.stagePos))) * 2.0f) - 0.5f);
    g.bead = bead.x * beadFade;
    g.beadR = bead.y;
    float3 radiance = shadeGear(g, V, dnx, dny, F, A, skyLUT, canopyShadowMap);
    radiance += dyed.a * skin.glove[2].rgb;        // 火山那套：点缀像熔岩一样自己微微发光
    float3 c = tonemap(radiance * F.exposure.x) * F.camera.z;
    c += REVEAL_GLOW_COLOR * reveal.y * F.camera.z;
    return float4(c, 1.0f);
}

// MARK: - 绳子（伞绳、刹车绳）

/// 一段绳子：画成始终朝着眼睛的细长条，按真实粗细（不到一个像素就按覆盖率变淡），横截面当圆柱打光
struct LineSegment {
    float4 a;            // xyz 起点，w 半径（米）
    float4 b;            // xyz 终点
    float4 color;        // rgb 反照率
};

struct LineOut {
    float4 position [[position]];
    float3 stagePos;
    float3 side;                             // 横过绳子的方向（舞台空间）
    float3 color [[flat]];
    float across [[center_no_perspective]];  // 离中线多少像素
    float radiusPx [[center_no_perspective]];
    uint viewIndex [[flat]];
};

vertex LineOut lineVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          ushort amp [[amplification_id]],
                          device const LineSegment *segments [[buffer(0)]],
                          constant ViewUniforms *views [[buffer(1)]]) {
    LineSegment s = segments[iid];
    float4x4 VP = views[amp].viewProjection;
    float3 a = s.a.xyz, b = s.b.xyz;
    float4 ca = VP * float4(a, 1.0f), cb = VP * float4(b, 1.0f);
    LineOut o;
    o.viewIndex = amp;
    o.color = s.color.rgb;
    // 近平面裁剪：一端跑到眼睛后面，就把它挪回 w = 1 厘米的地方
    const float nearW = 0.01f;
    if (ca.w < nearW && cb.w < nearW) {
        o.position = float4(0.0f, 0.0f, -1.0f, 1.0f);
        o.stagePos = a; o.side = float3(1.0f, 0.0f, 0.0f); o.across = 0.0f; o.radiusPx = 0.0f;
        return o;
    }
    if (ca.w < nearW) { float t = (nearW - ca.w) / (cb.w - ca.w); a = mix(a, b, t); ca = mix(ca, cb, t); }
    if (cb.w < nearW) { float t = (nearW - cb.w) / (ca.w - cb.w); b = mix(b, a, t); cb = mix(cb, ca, t); }
    bool atB = vid >= 2;
    float sideSign = (vid & 1) ? 1.0f : -1.0f;
    float4 c = atB ? cb : ca;
    float3 p = atB ? b : a;
    float2 halfVP = views[amp].viewport.zw * 0.5f;
    float2 sa = ca.xy / ca.w * halfVP, sb = cb.xy / cb.w * halfVP;
    float2 dir = sb - sa;
    float len = length(dir);
    dir = len > 1e-4f ? dir / len : float2(1.0f, 0.0f);
    float2 normal = float2(-dir.y, dir.x);
    // 这一端一米有多少像素
    float pxPerMeter = length(float3(VP[0][0], VP[1][0], VP[2][0])) * halfVP.x / c.w;
    float radiusPx = s.a.w * pxPerMeter;
    float halfPx = max(radiusPx, 0.5f) + 1.0f;               // 比绳子宽一像素，边缘留给抗锯齿
    float2 offset = normal * (sideSign * halfPx) + dir * (atB ? 0.7f : -0.7f);
    c.xy += offset / halfVP * c.w;
    // 屏幕上的横向对应到舞台里哪个方向（符号要和屏幕上一致，圆柱哪边亮才对）
    float3 axis = normalize(b - a + 1e-6f);
    float3 toEye = normalize(views[amp].cameraPosition.xyz - p);
    float3 side = normalize(cross(axis, toEye) + 1e-6f);
    float4 cs = VP * float4(p + side * 0.01f, 1.0f);
    if (dot(cs.xy / cs.w * halfVP - (atB ? sb : sa), normal) < 0.0f) side = -side;
    o.position = c;
    o.stagePos = p;
    o.side = side;
    o.across = sideSign * halfPx;
    o.radiusPx = radiusPx;
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]],
                             constant ViewUniforms *views [[buffer(0)]],
                             constant FrameUniforms &F [[buffer(1)]],
                             constant AtmosphereConstants &A [[buffer(2)]],
                             texture2d<float> canopyShadowMap [[texture(14)]]) {
    float r = max(in.radiusPx, 0.5f);
    float alpha = saturate(r + 0.5f - abs(in.across)) * saturate(in.radiusPx / 0.5f);
    if (alpha < 0.003f) discard_fragment();
    float3 eye = views[in.viewIndex].cameraPosition.xyz;
    float3 V = normalize(eye - in.stagePos);
    float x = clamp(in.across / r, -1.0f, 1.0f);
    float3 N = normalize(normalize(in.side) * x + V * sqrt(saturate(1.0f - x * x)));
    float3 L = stageSunDirection(F);
    float altitude = F.camera.x + in.stagePos.y;
    float3 sunE = mix(A.sunAtCloudBase.rgb, A.sunAtCloudTop.rgb, saturate((altitude - 1000.0f) / 8000.0f))
                * canopyShadow(in.stagePos, L, F, canopyShadowMap);
    float3 skyE = A.skyIrradianceSea.rgb * (0.55f + 0.45f * N.y);
    // 编织的绳子：漫反射为主，顺着绳子有一点点光泽
    float3 H = normalize(L + V);
    float gloss = pow(saturate(dot(N, H)), 18.0f) * 0.08f;
    float3 radiance = in.color / PI * (sunE * saturate(dot(N, L) * 0.8f + 0.2f) + skyE) + sunE * gloss;
    float3 c = tonemap(radiance * F.exposure.x) * F.camera.z;
    return float4(c * alpha, alpha);
}

// MARK: - 伞和人的剪影贴图（PlayerShadow.swift）：从太阳的方向正交投影

struct ShadowPassUniforms {
    float4 u;        // xyz 贴图的横轴（舞台空间），w 1 / 半宽
    float4 v;        // xyz 贴图的纵轴
    float4 center;   // xy 贴图中心在（横轴, 纵轴）上的坐标
};

struct ShadowPassOut {
    float4 position [[position]];
    float3 color;
    float2 uv;           // 伞布的展向、弦向（米）：皮肤的图案按它算，影子的颜色和伞一样
};

static inline float4 shadowPassPosition(float3 p, constant ShadowPassUniforms &S) {
    float2 xy = (float2(dot(p, S.u.xyz), dot(p, S.v.xyz)) - S.center.xy) * S.u.w;
    return float4(xy, 0.5f, 1.0f);
}

/// 伞衣：就是主 pass 画的那张网格（舞台空间），顶点颜色是伞布的反照率
vertex ShadowPassOut canopyShadowVertex(uint vid [[vertex_id]],
                                        device const MeshVertex *vertices [[buffer(0)]],
                                        constant ShadowPassUniforms &S [[buffer(1)]]) {
    MeshVertex v = vertices[vid];
    ShadowPassOut o;
    o.position = shadowPassPosition(v.position.xyz, S);
    o.color = v.color.rgb;
    o.uv = float2(v.position.w, v.normal.w);
    return o;
}

/// 一层伞布透过来的光：尼龙透得最多的是它自己颜色的光（约 0.4 × 反照率^1.5）。
/// 管线是相乘混合：上下两层布、叠在一起的褶子，画一层乘一次
fragment float4 canopyShadowFragment(ShadowPassOut in [[stage_in]], constant SkinUniforms &skin [[buffer(0)]]) {
    float3 albedo = canopySkinAlbedo(in.uv, fwidth(in.uv), skin);
    return float4(0.4f * pow(max(albedo, 0.0f), float3(1.5f)), 1.0f);
}

/// 人：一堆三角形（舞台空间），不透光
vertex ShadowPassOut bodyShadowVertex(uint vid [[vertex_id]],
                                      device const float4 *vertices [[buffer(0)]],
                                      constant ShadowPassUniforms &S [[buffer(1)]]) {
    ShadowPassOut o;
    o.position = shadowPassPosition(vertices[vid].xyz, S);
    o.color = 0.0f;
    o.uv = 0.0f;
    return o;
}

fragment float4 bodyShadowFragment(ShadowPassOut in [[stage_in]]) {
    return float4(0.0f, 0.0f, 0.0f, 1.0f);
}
