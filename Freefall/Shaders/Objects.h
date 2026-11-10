#pragma once
#include "Common.h"
#include "Atmosphere.h"

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
#define MATERIAL_BAR 10        // 舱门边的扶杆：开场在你的房间里只有它

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
};

/// 装备和手套共用的打光：太阳（伞衣的影子、舱里挡掉）、天光（贴着胸口朝里的一面被身体挡掉）、
/// 天空 / 地面 / 自己身体的反射、舱里的红灯、GGX 高光（几何高光抗锯齿）、尼龙的绒光
static inline float3 shadeGear(GearSurface s, float3 V, float3 dnx, float3 dny,
                               constant FrameUniforms &F, constant AtmosphereConstants &A,
                               texture2d<float> skyLUT) {
    float3 N = s.normal;
    float3 L = stageSunDirection(F);
    float altitude = F.camera.x + s.position.y;
    float3 sunE = mix(A.sunAtCloudBase.rgb, A.sunAtCloudTop.rgb, saturate((altitude - 1000.0f) / 8000.0f));
    float3 groundL = A.groundBounce.rgb * (sceneGroundAlbedo(int(F.world.x)) / 0.06f);
    float3 skyE = A.skyIrradianceSea.rgb * (0.55f + 0.45f * N.y) + groundL * PI * saturate(-N.y) * 0.5f;
    const float3 cabinRed = float3(0.05f, 0.0045f, 0.0035f);
    float dl = 1.0f - s.interior;
    float3 sunVis = canopyShadow(s.position, L, F) * (dl * dl);
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

    float3 diffuse = s.albedo / PI * (sunE * sunVis * NdotL + sky * (0.12f + 0.88f * dl) + cabinRed * s.interior);
    float3 radiance = diffuse + sunE * sunVis * spec + specEnv;
    if (s.sheen > 0.0f) {
        // 尼龙的绒光：掠射角上一层发灰的柔光（黑色织带的轮廓靠它）
        float rim = pow(1.0f - NdotV, 5.0f);
        radiance += rim * 0.1f * s.sheen * mix(s.albedo, float3(0.5f), 0.5f) / PI
                  * (sunE * sunVis * saturate(dot(N, L) + 0.3f) * 0.5f + sky);
    }
    return radiance;
}

fragment float4 objectFragment(ObjectOut in [[stage_in]],
                               constant ViewUniforms *views [[buffer(0)]],
                               constant FrameUniforms &F [[buffer(1)]],
                               constant AtmosphereConstants &A [[buffer(2)]],
                               constant ObjectUniforms &O [[buffer(3)]],
                               texture2d<float> skyLUT [[texture(0)]]) {
    float3 eye = views[in.viewIndex].cameraPosition.xyz;
    float3 V = normalize(eye - in.stagePos);
    float3 N = normalize(in.normal);
    if (dot(N, V) < 0.0f) N = -N;                 // 两面都画（舱壁、伞衣）
    // 导数在分支外面算（分支里 2×2 像素块可能走不同的路，导数没定义）
    float3 dpx = dfdx(in.stagePos), dpy = dfdy(in.stagePos);
    float2 duvx = dfdx(in.uv), duvy = dfdy(in.uv);
    float3 dnx = dfdx(N), dny = dfdy(N);
    // 太阳在世界坐标里；伞下转向是世界绕着你转，舞台里的东西要按航向反过来转一下太阳
    float3 L = stageSunDirection(F);
    int material = int(in.color.a + 0.5f);
    float3 albedo = in.color.rgb;
    float daylight = 1.0f - in.interior;
    // 开场：还没实体化的地方丢掉（深度留 0，系统透出你的房间）；扶杆和替身手一直在
    float2 reveal = float2(1.0f, 0.0f);
    if (revealActive && material != MATERIAL_BAR && material != MATERIAL_SOFT) {
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
    if (material == MATERIAL_BAR) {
        // 扶杆：在你的房间里时按屋里柔和的灯光打（上亮下暗），飞机在它周围长出来以后换成机舱里的光
        float3 E = sunE * saturate(dot(N, L)) * daylight * daylight
                 + skyE * (0.12f + 0.88f * daylight)
                 + cabinRed * in.interior;
        float3 room = float3(0.5f, 0.49f, 0.46f) * (0.6f + 0.4f * N.y);
        float roomMix = F.reveal.w < 0.0f ? 1.0f : 1.0f - smoothstep(0.4f, 3.0f, F.reveal.w);
        radiance = albedo * mix(E, room, roomMix) / PI;
        // 还没握住的时候慢慢一明一暗，提示去握
        if (F.reveal.w < 0.0f) radiance *= 1.0f + 0.3f * (0.5f + 0.5f * sin(F.camera.y * 3.5f));
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
        g.occlusion = 1.0f;
        g.sheen = 0.0f;
        g.specScale = 1.0f;
        float metallic = 0.0f;
        float3 diffuseAlbedo = albedo;
        if (material == MATERIAL_WEBBING) {
            // 织出来的面不是一整块光滑的面，镜面反射比实心塑料弱得多（黑织带在太阳下也还是黑的）
            g.roughness = 0.75f; g.sheen = 1.0f; g.specScale = 0.4f;
            // 斜纹：一道道 1.8 毫米的斜棱，按 uv（米）画；小于几个像素就淡掉（VR 里细纹会闪）
            float3 Tu = cross(dpy, N) * duvx.x + cross(N, dpx) * duvy.x;
            float3 Tv = cross(dpy, N) * duvx.y + cross(N, dpx) * duvy.y;
            float footprint = max(length(duvx) + length(duvy), 1e-6f);
            float fade = saturate(0.0018f / (footprint * 3.0f) - 0.3f);
            if (fade > 0.0f && length(Tu) > 1e-9f && length(Tv) > 1e-9f) {
                Tu = normalize(Tu); Tv = normalize(Tv);
                float phase = (in.uv.x * 0.8f + in.uv.y) / 0.0018f * 2.0f * PI;
                float warp = sin(in.uv.x / 0.0009f * 2.0f * PI);
                diffuseAlbedo *= 1.0f + fade * (0.12f * sin(phase) + 0.05f * warp);
                N = normalize(N - (Tu * 0.8f + Tv) * (cos(phase) * 0.13f * fade));
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
        radiance = shadeGear(g, V, dnx, dny, F, A, skyLUT);
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
                              texture2d<float> skyLUT [[texture(0)]],
                              texture2d<float> albedoTex [[texture(1)]],
                              texture2d<float> normalTex [[texture(2)]],
                              texture2d<float> materialTex [[texture(3)]]) {
    constexpr sampler tex(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float3 eye = views[in.viewIndex].cameraPosition.xyz;
    float3 V = normalize(eye - in.stagePos);
    float3 n0 = normalize(in.normal);
    float3 dnx = dfdx(n0), dny = dfdy(n0);
    float3 dpx = dfdx(in.stagePos), dpy = dfdy(in.stagePos);
    float2 duvx = dfdx(in.uv), duvy = dfdy(in.uv);
    float3 Ng = dot(n0, V) < 0.0f ? -n0 : n0;     // 袖口里面
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
    g.albedo = albedoTex.sample(tex, in.uv).rgb;
    // 高光贴图原本给的是 RealityKit 的镜面颜色，有的地方（护条、标签）高到像金属；布、胶、塑料的反射率都在 2%~6%
    g.F0 = float3(min(pow(mat.b, 2.2f) * 0.25f, 0.06f));
    g.roughness = clamp(mat.r, 0.1f, 1.0f);
    g.specScale = 1.0f;
    g.sheen = 0.6f;
    g.occlusion = mat.g;
    g.interior = O.params.y;
    float3 radiance = shadeGear(g, V, dnx, dny, F, A, skyLUT);
    float3 c = tonemap(radiance * F.exposure.x) * F.camera.z;
    return float4(c, F.reveal.w < 0.0f ? F.camera.z : 1.0f);
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
                             constant AtmosphereConstants &A [[buffer(2)]]) {
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
                * canopyShadow(in.stagePos, L, F);
    float3 skyE = A.skyIrradianceSea.rgb * (0.55f + 0.45f * N.y);
    // 编织的绳子：漫反射为主，顺着绳子有一点点光泽
    float3 H = normalize(L + V);
    float gloss = pow(saturate(dot(N, H)), 18.0f) * 0.08f;
    float3 radiance = in.color / PI * (sunE * saturate(dot(N, L) * 0.8f + 0.2f) + skyE) + sunE * gloss;
    float3 c = tonemap(radiance * F.exposure.x) * F.camera.z;
    return float4(c * alpha, alpha);
}
