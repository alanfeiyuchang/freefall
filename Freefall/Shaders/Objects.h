#pragma once
#include "Common.h"

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
#define MATERIAL_SOFT 5        // 表带、背带（离屏测试里代替真手的手也用它）：边缘有一点柔和的亮光

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

fragment float4 objectFragment(ObjectOut in [[stage_in]],
                               constant ViewUniforms *views [[buffer(0)]],
                               constant FrameUniforms &F [[buffer(1)]],
                               constant AtmosphereConstants &A [[buffer(2)]],
                               constant ObjectUniforms &O [[buffer(3)]]) {
    float3 eye = views[in.viewIndex].cameraPosition.xyz;
    float3 V = normalize(eye - in.stagePos);
    float3 N = normalize(in.normal);
    if (dot(N, V) < 0.0f) N = -N;                 // 两面都画（舱壁、伞衣）
    // 太阳在世界坐标里；伞下转向是世界绕着你转，舞台里的东西要按航向反过来转一下太阳
    float3 L = rotateHeading(F.sunDirection.xyz, F.heading.x, -F.heading.y);
    int material = int(in.color.a + 0.5f);
    float3 albedo = in.color.rgb;
    float daylight = 1.0f - in.interior;

    float altitude = F.camera.x + in.stagePos.y;
    float3 sunE = mix(A.sunAtCloudBase.rgb, A.sunAtCloudTop.rgb, saturate((altitude - 1000.0f) / 8000.0f));
    float3 skyE = A.skyIrradianceSea.rgb * (0.55f + 0.45f * N.y) + A.groundBounce.rgb * PI * saturate(-N.y) * 0.5f;
    const float3 cabinRed = float3(0.05f, 0.0045f, 0.0035f);   // 货舱里的红色夜灯（照度）

    float3 radiance;
    if (material == MATERIAL_EMISSIVE) {
        radiance = albedo;
    } else if (material == MATERIAL_LAMP_RED) {
        radiance = albedo * (O.params.x < 0.5f ? 1.0f : 0.004f);
    } else if (material == MATERIAL_LAMP_GREEN) {
        radiance = albedo * (O.params.x > 0.5f ? 1.0f : 0.004f);
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
        float layers = 1.0f - 0.6f * rib - 0.3f * halfRib - 0.25f * seam;
        // 尼龙有一层柔和的光泽
        float3 H = normalize(L + V);
        float sheen = pow(saturate(dot(N, H)), 24.0f) * 0.12f;
        // 透过来的光被染成布的颜色（尼龙对自己颜色的光透得最多），所以逆光的伞衣颜色更浓、更亮
        float3 transmitted = albedo * sqrt(albedo) * 1.6f * through * layers;
        radiance = albedo / PI * (sunE * lit * (0.85f + 0.15f * layers) + skyE) + sunE * transmitted / PI
                 + sunE * sheen * lit;
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
    float3 c = acesFitted(radiance * F.exposure.x) * F.camera.z;
    return float4(c, 1.0f);
}

// MARK: - 伞绳（一像素宽的线）

struct LineOut {
    float4 position [[position]];
};

vertex LineOut lineVertex(uint vid [[vertex_id]],
                          ushort amp [[amplification_id]],
                          device const float4 *points [[buffer(0)]],
                          constant ViewUniforms *views [[buffer(1)]]) {
    LineOut o;
    o.position = views[amp].viewProjection * float4(points[vid].xyz, 1.0f);
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]], constant FrameUniforms &F [[buffer(1)]]) {
    return float4(float3(0.035f) * F.camera.z, 1.0f);
}
