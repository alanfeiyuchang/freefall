#pragma once
#include "Common.h"

// 场景里的实体：飞机（货舱内部 + 外壳）、伞衣、伞绳和背带、手套、手腕高度表、前方高度表面板（没有手部追踪时）。
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
#define MATERIAL_GLOVE 5       // 手套：布料，边缘有一点绒面的亮光

struct ObjectUniforms {
    float4x4 model;      // 物体 → 舞台
    float4 params;       // x 跳伞灯（0 红 1 绿），y 机舱里的程度（手套用），zw 未用
};

/// 两端半径不同的胶囊（手指的一节、背带）。a、b 的 w 是半径。
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
    float3 L = F.sunDirection.xyz;
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
        radiance = albedo / PI * (sunE * (lit + 0.45f * through) + skyE);
    } else {
        // 太阳只照得到舱门附近（室内程度低的地方）；天光往里衰减得慢一些；越往里红灯越明显
        float3 E = sunE * saturate(dot(N, L)) * daylight * daylight
                 + skyE * (0.12f + 0.88f * daylight)
                 + cabinRed * in.interior;
        radiance = albedo * E / PI;
        if (material == MATERIAL_GLOVE) {
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
