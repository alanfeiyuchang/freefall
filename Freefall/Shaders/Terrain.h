#pragma once
#include "TerrainField.h"

// 地形的画法（Freefall.metal 最后才 include 这个文件：要用到那边的 oceanShade、waveSlope）。
//
// 网格：CDLOD。CPU 选出一批正方形的块（TerrainLOD.swift），每块画成同一张 16×16 格的网格，越远的块越大；
// 顶点着色器按到头的距离把块外圈的顶点往粗一级的网格上靠（morph），相邻两级之间没有缝。
// 高度在顶点着色器里直接算程序函数（TerrainField.h），近处格距 2 米；法线用差分。
// 着色：按场景决定地面材质（草、林、岩、碎石、雪、冰、冰裂缝、冰碛、水、熔岩、火山灰、农田），
// 太阳 + 天光，山影和环境光遮蔽来自启动时预算的山影图，云影按地面高度沿太阳方向偏移；
// 空气透视用天空视图表 ×（这一段的透射率换算的比例）；最后叠上云层、色调映射，和天空 pass 一样。

#define TERRAIN_GRID 16

struct TerrainNode {
    float4 origin;      // xy 块一角的地面坐标（绝对，32 米的整数倍），z 边长（米），w LOD 级别
    float4 relative;    // xy 同一角相对舞台原点的地面坐标（CPU 用双精度算好，近处不抖），zw 未用
};

struct TerrainUniforms {
    float4 camera;      // xyz 头在舞台空间的位置（按它算 LOD 距离），w 场景编号
    float4 lod;         // x 0 级块用到的距离（米），y 海面以下按海画（1/0），zw 未用
};

struct TerrainOut {
    float4 position [[position]];
    float3 stagePos;
    float3 normal;       // 世界方向（y 向上）
    float2 ground;       // 地面坐标（绝对）
    float height;        // 海拔（米）
    float cell;          // 这一块的格距（米）
    uint viewIndex [[flat]];
};

/// 一段直线路径（海拔从 h0 到 h1 公里，长 L 公里）的透射率：瑞利、米氏散射都是指数大气（标高 8 / 1.2 km），
/// 解析积分。地形最远几百公里，用不着查表；查表在贴着地平线的方向不准，地平线上下会接不上（出一道线）。
static inline float3 segmentTransmittance(float h0, float h1, float L) {
    float dh = h1 - h0;
    float fr = abs(dh) < 1e-3f ? exp(-h0 / 8.0f) : 8.0f * (exp(-h0 / 8.0f) - exp(-h1 / 8.0f)) / dh;
    float fm = abs(dh) < 1e-3f ? exp(-h0 / 1.2f) : 1.2f * (exp(-h0 / 1.2f) - exp(-h1 / 1.2f)) / dh;
    return exp(-(RAYLEIGH_SCATTERING * fr + float3(MIE_EXTINCTION) * fm) * L);
}

/// 相对舞台原点的地面坐标 + 海拔 → 舞台空间（按航向反转；远处按地球曲率往下沉）
static inline float3 terrainToStage(float2 rel, float h, constant FrameUniforms &F) {
    float3 s = rotateHeading(float3(rel.x, 0.0f, rel.y), F.heading.x, -F.heading.y);
    s.y = h - F.camera.x - dot(rel, rel) / (2.0f * EARTH_R);
    return s;
}

static inline float terrainMapHeight(texture2d<float> map, float2 ground) {
    return map.sample(linearClamp, ground / TERRAIN_MAP_SIZE + 0.5f, level(0)).r;
}

vertex TerrainOut terrainVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                ushort amp [[amplification_id]],
                                constant ViewUniforms *views [[buffer(0)]],
                                constant FrameUniforms &F [[buffer(1)]],
                                device const TerrainNode *nodes [[buffer(2)]],
                                constant TerrainUniforms &T [[buffer(3)]],
                                texture2d<float> heightMap [[texture(0)]]) {
    TerrainNode n = nodes[iid];
    int scene = int(T.camera.w);
    float cell = n.origin.z / float(TERRAIN_GRID);
    float2 g = float2(float(vid % (TERRAIN_GRID + 1)), float(vid / (TERRAIN_GRID + 1)));
    // 先用高度图粗估位置，按到头的距离决定往粗一级的网格靠多少
    float2 approx = n.origin.xy + g * cell;
    float approxH = terrainMapHeight(heightMap, approx);
    float dist = length(terrainToStage(n.relative.xy + g * cell, approxH, F) - T.camera.xyz);
    float range = T.lod.x * exp2(n.origin.w);
    float k = saturate((dist - range * 0.7f) / (range * 0.3f));
    float2 gm = g - fract(g * 0.5f) * 2.0f * k;
    float2 ground = n.origin.xy + gm * cell;
    float h = terrainHeight(scene, ground);
    float e = max(cell * 0.5f, 0.5f);
    float hx = terrainHeight(scene, ground + float2(e, 0.0f));
    float hz = terrainHeight(scene, ground + float2(0.0f, e));
    float shown = T.lod.y > 0.5f ? max(h, 0.0f) : h;
    TerrainOut o;
    o.stagePos = terrainToStage(n.relative.xy + gm * cell, shown, F);
    o.position = views[amp].viewProjection * float4(o.stagePos, 1.0f);
    o.normal = normalize(float3(h - hx, e, h - hz));
    o.ground = ground;
    o.height = h;
    o.cell = cell;
    o.viewIndex = amp;
    return o;
}

/// 地形的深度预渲染（云层 pass 之前）：只要位置，不算法线，便宜三分之二
vertex float4 terrainDepthVertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 ushort amp [[amplification_id]],
                                 constant ViewUniforms *views [[buffer(0)]],
                                 constant FrameUniforms &F [[buffer(1)]],
                                 device const TerrainNode *nodes [[buffer(2)]],
                                 constant TerrainUniforms &T [[buffer(3)]],
                                 texture2d<float> heightMap [[texture(0)]]) {
    TerrainNode n = nodes[iid];
    int scene = int(T.camera.w);
    float cell = n.origin.z / float(TERRAIN_GRID);
    float2 g = float2(float(vid % (TERRAIN_GRID + 1)), float(vid / (TERRAIN_GRID + 1)));
    float2 approx = n.origin.xy + g * cell;
    float approxH = terrainMapHeight(heightMap, approx);
    float dist = length(terrainToStage(n.relative.xy + g * cell, approxH, F) - T.camera.xyz);
    float range = T.lod.x * exp2(n.origin.w);
    float k = saturate((dist - range * 0.7f) / (range * 0.3f));
    float2 gm = g - fract(g * 0.5f) * 2.0f * k;
    float h = terrainHeight(scene, n.origin.xy + gm * cell);
    float shown = T.lod.y > 0.5f ? max(h, 0.0f) : h;
    return views[amp].viewProjection * float4(terrainToStage(n.relative.xy + gm * cell, shown, F), 1.0f);
}

// MARK: - 材质

struct Surface {
    float3 albedo;
    float roughness;      // 只给雪、冰、水用：镜面反光的宽窄
    float specular;       // 镜面反光的强度
    float3 emission;      // 熔岩的光（辐亮度）
    int material;
};

/// 靶：一大块红白相间的同心圆（和环礁的一样），中间黄色靶心
static inline float3 targetColor(float2 p, float3 under, thread float &onTarget) {
    float r = length(p - LZ_TARGET);
    float ring = fract(r / 4.0f);
    float aa = max(fwidth(r) / 4.0f, 1e-4f);
    float stripe = smoothstep(0.5f - aa, 0.5f + aa, ring);
    float3 c = mix(TARGET_RED, TARGET_WHITE, stripe);
    c = mix(TARGET_YELLOW, c, smoothstep(3.0f - aa * 4.0f, 3.0f + aa * 4.0f, r));
    onTarget = smoothstep(20.0f + aa * 4.0f, 20.0f - aa * 4.0f, r);
    return mix(under, c, onTarget);
}

/// 细节噪声取哪一级 mip：一个像素盖 footprint 米，贴图一圈 tile 米（128 个纹素）。
/// 稍微取细半级（清楚一点）；中远处不再一个像素跨十几个纹素地跳着采
static inline float noiseLod(float footprint, float tile) {
    return max(log2(footprint * 128.0f / tile) - 0.5f, 0.0f);
}

/// 细节噪声（3D 噪声纹理的一层当 2D 用），越远越淡，免得闪
static inline float detailNoise(texture3d<float> noise, float2 p, float scale, float footprint, float layer) {
    float fade = saturate(scale / (footprint * 6.0f) - 1.0f);
    if (fade <= 0.0f) return 0.5f;
    float n = noise.sample(linearRepeat, float3(p.x / scale, layer, p.y / scale), level(0)).r;
    return mix(0.5f, n, fade);
}

// 地面类型图：启动时按场景把树林、水的边、熔岩、冰碛、农田这些（每个都要算好几层噪声）预先存进一张图，
// 着色时只查一次（之前每个像素现算，地形着色一帧要多花一毫秒多）。地面坐标 ±16 km，2048²（一格 15.6 米）；
// 水和熔岩存的是到边的有符号距离，双线性插值以后边还是准的。落地判定不看这张图：CPU 用 TerrainField 精确算。
#define SURFACE_MAP_SIZE 32000.0f

static inline float encodeEdge(float d) { return saturate(0.5f + d / 64.0f); }
static inline float decodeEdge(float v) { return (v - 0.5f) * 64.0f; }

/// r 水的边（有符号距离，负的是水里），g 树林（0..1），b 各关自己的一个量，a 熔岩的边（有符号距离）
kernel void generateSurfaceMap(texture2d<float, access::write> out [[texture(0)]],
                               constant int &scene [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    float2 p = ((float2(gid) + 0.5f) / float2(size) - 0.5f) * SURFACE_MAP_SIZE;
    float4 v = float4(1.0f, 0.0f, 0.0f, 1.0f);
    if (scene == SCENE_GRASSLAND) {
        v.r = encodeEdge(min(riverDistance(p) - RIVER_HALF_WIDTH, length(p - POND_CENTER) - POND_RADIUS));
        v.g = grasslandForest(p);
        v.b = tSmooth(-0.05f, 0.05f, tFbm(p / 1100.0f + float2(2.0f, 5.0f), 3))      // 哪里是农田
            * tSmooth(260.0f, 330.0f, length(p - LZ_TARGET));
    } else if (scene == SCENE_ALPINE) {
        v.r = encodeEdge(alpineStreamDistance(valleyCoords(p)) - 5.0f);
        v.g = alpineForest(p, alpineHeight(p));
    } else if (scene == SCENE_SNOW) {
        v.b = tSmooth(0.32f, 0.4f, tFbm(p / 160.0f + float2(6.0f, 2.0f), 3))           // 雪坡上露出来的岩石
            * tSmooth(120.0f, 200.0f, length(p - LZ_TARGET));
    } else if (scene == SCENE_ISLAND) {
        v.g = islandForest(p);
    } else if (scene == SCENE_VOLCANO) {
        v.a = encodeEdge(min(lavaFlowDistance(p) - 14.0f, length(p - CONE_CENTER) - (CRATER_RADIUS - 20.0f)));
        v.b = tSmooth(0.0f, 0.12f, tFbm(p / 380.0f + float2(9.0f, 1.0f), 4));            // 老的熔岩流
        // 火山这一关没有河和树林，r、g 两个通道另作他用：r 风吹出来的一道道浅色细灰，g 氧化成铁锈红的地方
        v.r = tSmooth(0.05f, 0.3f, tFbm(float2(dot(p, float2(0.8f, 0.6f)) / 900.0f, dot(p, float2(-0.6f, 0.8f)) / 90.0f) + 3.0f, 3));
        v.g = tSmooth(0.12f, 0.3f, tFbm(p / 310.0f + float2(4.0f, 8.0f), 4));
    }
    out.write(v, gid);
}

static inline float4 surfaceMapAt(texture2d<float> map, float2 p) {
    if (any(abs(p) > SURFACE_MAP_SIZE * 0.5f)) return float4(1.0f, 0.0f, 0.0f, 1.0f);
    return map.sample(linearClamp, p / SURFACE_MAP_SIZE + 0.5f, level(0));
}

/// n1、n2：37 米、6 米尺度的细节噪声（0..1，远了是 0.5），和细节起伏共用一次采样；sm：地面类型图；
/// crown：x 树冠的高度场（0..1，远了是 0.5），y 看得清一棵棵树的程度（0 远、1 近）
static inline Surface terrainSurface(int scene, float2 p, float h, float3 N, float footprint, float n1, float n2,
                                     float4 sm, float2 crown, texture3d<float> noise) {
    Surface s;
    s.roughness = 0.3f;
    s.specular = 0.0f;
    s.emission = 0.0f;
    float flatness = N.y;                         // 1 平地，cos 35° ≈ 0.82，cos 45° ≈ 0.71
    float vary = (n1 - 0.5f) * 0.6f + (n2 - 0.5f) * 0.45f;
    // 水的边：河和溪流只有十几米宽，比地面类型图的一格还窄，插值出来会断成虚线，现算（几次正弦，不贵）
    float waterEdge = scene == SCENE_VOLCANO ? 1.0f : decodeEdge(sm.r);
    if (scene == SCENE_GRASSLAND) {
        waterEdge = min(riverDistance(p) - RIVER_HALF_WIDTH, length(p - POND_CENTER) - POND_RADIUS);
    } else if (scene == SCENE_ALPINE) {
        waterEdge = alpineStreamDistance(valleyCoords(p)) - 5.0f;
    }
    // 树林的边：近处按树冠的高度场进退，边上是一棵棵的树，而不是地面类型图插值出来的一条光滑的线；
    // 林子外面稀稀拉拉还有几棵（落地判定按 CPU 的精确函数，这里最多差一棵树的宽度）
    float crownN = saturate((crown.x - 0.42f) / 0.5f);
    float forestG = scene == SCENE_VOLCANO ? 0.0f : sm.g;
    float forestV = forestG + (crownN - 0.5f) * 0.34f * crown.y * tSmooth(0.04f, 0.2f, forestG);
    float forestEdge = mix(0.15f, 0.07f, crown.y);

    // 通用：岩石、碎石、草、雪
    float3 rock = float3(0.20f, 0.185f, 0.17f) * (1.0f + vary * 0.35f);
    float3 scree = float3(0.36f, 0.34f, 0.31f) * (1.0f + vary * 0.5f);
    // 草：橄榄绿，一片片深浅不一，夹着发黄的地方
    float3 grass = mix(float3(0.085f, 0.13f, 0.045f), float3(0.15f, 0.15f, 0.07f), saturate(n1 * 1.4f - 0.3f))
                 * (1.0f + vary * 0.8f);
    float3 snow = float3(0.80f, 0.83f, 0.88f) * (1.0f + vary * 0.10f);
    // 树林：树冠顶上亮、树和树之间的缝暗；一片片树种不一样（发黄的阔叶、发蓝的针叶）
    float3 forest = float3(0.035f, 0.065f, 0.028f) * (0.5f + 1.1f * n2);
    forest *= mix(1.0f, 0.38f + 1.25f * crownN * crownN, crown.y);
    forest *= mix(float3(0.82f, 0.95f, 1.08f), float3(1.3f, 1.12f, 0.72f), saturate(n1 * 2.2f - 0.75f));
    s.material = MAT_ROCK;

    if (scene == SCENE_GRASSLAND) {
        // 农田：200 米左右一块，每块种的东西和垄的方向不一样
        // （田块的边之前还按细节噪声抖：细节噪声远了会淡掉，田边就跟着距离变形，近看是一圈锯齿）
        float2 cellP = p / 190.0f + 0.7f * float2(tNoise(p / 420.0f), tNoise(p / 420.0f + 7.0f));
        float2 cid = floor(cellP);
        float pick = tHash(int2(cid)) * 0.5f + 0.5f;
        float angle = tHash(int2(cid) + int2(17, 3)) * 3.14159f;
        float2 dir = float2(cos(angle), sin(angle));
        float rows = 0.5f + 0.5f * sin(dot(p, dir) * 2.4f);
        float rowFade = saturate(1.6f - footprint * 0.9f);
        float3 crop = pick < 0.3f ? float3(0.36f, 0.30f, 0.10f)          // 麦子
                    : pick < 0.5f ? float3(0.07f, 0.16f, 0.035f)        // 绿的
                    : pick < 0.62f ? float3(0.16f, 0.11f, 0.07f)        // 翻过的地
                    : float3(0.10f, 0.17f, 0.05f);                       // 草场
        crop *= 1.0f + (rows - 0.5f) * 0.35f * rowFade + vary * 0.6f;
        // 田和田之间：一条土路 / 草埂，隔几块田有一道树篱（一棵棵树冠连成的线）
        float2 fc = abs(fract(cellP) - 0.5f);
        float edgeD = (0.5f - max(fc.x, fc.y)) * 190.0f;
        float track = tSmooth(3.2f, 1.6f, edgeD) * saturate(2.0f - footprint * 0.35f);
        crop = mix(crop, float3(0.19f, 0.16f, 0.10f) * (1.0f + vary * 0.5f), track * 0.75f);
        float hedged = step(0.15f, tHash(int2(cid) + int2(5, 11)));
        float hedge = tSmooth(7.5f, 4.0f, edgeD + (0.5f - crownN) * 5.0f * crown.y) * hedged
                    * saturate(2.0f - footprint * 0.25f);
        crop = mix(crop, forest * 1.15f, hedge);
        s.albedo = mix(grass * float3(1.1f, 1.15f, 1.0f), crop, sm.b);
        // 着陆区旁边一条修剪过的草跑道
        float2 sl = valleyCoords(p);
        float runway = tSmooth(16.0f, 13.0f, abs(sl.y - 95.0f)) * tSmooth(420.0f, 400.0f, abs(sl.x + 60.0f));
        s.albedo = mix(s.albedo, float3(0.13f, 0.21f, 0.06f) * (0.92f + 0.16f * step(0.5f, fract(sl.x / 25.0f))), runway);
        // 河滩：沙石
        s.albedo = mix(float3(0.30f, 0.27f, 0.21f) * (1.0f + vary), s.albedo, tSmooth(0.0f, 6.0f, waterEdge));
        s.albedo = mix(s.albedo, forest, tSmooth(0.5f - forestEdge, 0.5f + forestEdge, forestV));
        s.material = forestV > 0.5f ? MAT_FOREST : MAT_GRASS;
    } else if (scene == SCENE_ALPINE) {
        float2 sl = valleyCoords(p);
        float floorH = alpineFloor(sl.x);
        float meadow = tSmooth(0.80f, 0.90f, flatness) * tSmooth(floorH + 1500.0f, floorH + 1100.0f, h);
        float3 ground = mix(scree, grass * float3(1.15f, 1.2f, 1.0f), meadow);
        ground = mix(rock, ground, tSmooth(0.70f, 0.80f, flatness));
        float snowLine = 2950.0f + 250.0f * (n1 - 0.5f) * 2.0f;
        float snowCover = tSmooth(snowLine - 120.0f, snowLine + 120.0f, h) * tSmooth(0.62f, 0.75f, flatness);
        s.albedo = mix(ground, snow, snowCover);
        float f = forestV * tSmooth(0.72f, 0.80f, flatness);     // 悬崖上不长树
        s.albedo = mix(s.albedo, forest * float3(0.85f, 0.95f, 1.0f), tSmooth(0.5f - forestEdge, 0.5f + forestEdge, f));
        s.specular = snowCover * 0.04f;
        s.material = snowCover > 0.5f ? MAT_SNOW : (f > 0.5f ? MAT_FOREST : (meadow > 0.5f ? MAT_GRASS : MAT_ROCK));
    } else if (scene == SCENE_SNOW) {
        // 除了太陡挂不住雪的岩壁、零星露出来的岩石，全是雪；风吹过的地方露出一点蓝冰
        float cover = tSmooth(0.55f, 0.68f, flatness + (n1 - 0.5f) * 0.12f) * (1.0f - sm.b);
        float3 windIce = float3(0.62f, 0.72f, 0.82f);
        float3 snowy = mix(snow, windIce, tSmooth(0.62f, 0.75f, n1) * 0.35f * tSmooth(0.95f, 0.85f, flatness));
        s.albedo = mix(rock * float3(0.9f, 0.92f, 1.0f), snowy, cover);
        s.specular = cover * 0.05f;
        s.material = cover > 0.5f ? MAT_SNOW : MAT_ROCK;
    } else if (scene == SCENE_ISLAND) {
        // 白沙滩（靠水的一条被浪打湿了发暗），后面是热带的草地，再往里是雨林；山上太陡的地方露出黑色的火山岩
        float land = islandLand(p);
        float3 sand = float3(0.52f, 0.47f, 0.37f) * (1.0f + vary * 0.22f);
        float3 lawn = mix(float3(0.07f, 0.17f, 0.04f), float3(0.13f, 0.20f, 0.06f), saturate(n1 * 1.4f - 0.3f))
                    * (1.0f + vary * 0.7f);
        // 雨林：树冠大、一层压一层，颜色比温带的林子绿得多，夹着几棵发黄发亮的
        float3 jungle = float3(0.02f, 0.075f, 0.022f) * (0.5f + 1.1f * n2)
                      * mix(1.0f, 0.34f + 1.35f * crownN * crownN, crown.y)
                      * mix(float3(0.9f, 1.0f, 1.0f), float3(1.5f, 1.25f, 0.6f), saturate(n1 * 2.4f - 1.0f));
        float3 basalt = float3(0.11f, 0.10f, 0.095f) * (1.0f + vary * 0.4f);
        float beach = tSmooth(0.045f, 0.028f, land + (n1 - 0.5f) * 0.006f);
        float3 ground = mix(lawn, sand, beach);
        ground = mix(sand * 0.6f, ground, tSmooth(0.35f, 1.1f, h));
        ground = mix(ground, jungle, tSmooth(0.5f - forestEdge, 0.5f + forestEdge, forestV));
        ground = mix(basalt, ground, tSmooth(0.68f, 0.8f, flatness));
        s.albedo = ground;
        s.material = forestV > 0.5f ? MAT_FOREST : (beach > 0.5f ? MAT_SAND : MAT_GRASS);
        if (h < 0.3f) s.material = MAT_WATER;
    } else {   // SCENE_VOLCANO
        float2 kc = float2(150.0f, -350.0f);
        float rk = length(p - kc);
        float rc = length(p - CONE_CENTER);
        // 破火山口的底：深灰的火山灰，一片片被氧化成铁锈红，风把浅色的细灰吹成一道道；老熔岩流是发亮的黑
        float3 ash = float3(0.062f, 0.058f, 0.056f) * (1.0f + vary * 0.9f);
        ash = mix(ash, float3(0.095f, 0.050f, 0.036f) * (1.0f + vary * 0.6f), sm.g * 0.55f);
        ash = mix(ash, float3(0.12f, 0.115f, 0.108f), sm.r * 0.5f);
        float3 oldLava = float3(0.032f, 0.030f, 0.030f) * (0.6f + 0.9f * n2);
        float3 floorC = mix(ash, oldLava, sm.b);
        // 火山锥脚下、熔岩流两边的硫磺：发黄发白的一圈
        float sulfur = tSmooth(40.0f, 6.0f, decodeEdge(sm.a)) * tSmooth(0.45f, 0.7f, n2);
        floorC = mix(floorC, float3(0.30f, 0.25f, 0.07f), sulfur * 0.6f);
        // 火山锥上面是红褐色的火山渣
        floorC = mix(floorC, float3(0.16f, 0.07f, 0.04f) * (1.0f + vary), tSmooth(CONE_BASE_RADIUS, 220.0f, rc));
        // 外坡下面长着绿的（热带岛），海边是黑沙滩
        float green = tSmooth(2600.0f, 3200.0f, rk) * tSmooth(700.0f, 400.0f, h) * tSmooth(0.75f, 0.85f, flatness);
        float3 outside = mix(rock * 0.7f, float3(0.05f, 0.11f, 0.03f) * (1.0f + vary), green);
        outside = mix(float3(0.06f, 0.055f, 0.05f), outside, tSmooth(2.0f, 12.0f, h));
        s.albedo = mix(floorC, outside, tSmooth(2250.0f, 2450.0f, rk));
        s.albedo = mix(rock * 0.6f, s.albedo, tSmooth(0.66f, 0.78f, flatness));
        s.material = MAT_ASH;
        s.specular = sm.b * 0.03f * tSmooth(2250.0f, 2000.0f, rk);     // 老熔岩的壳像玻璃，有一点反光
        s.roughness = 0.5f;
        if (decodeEdge(sm.a) < 0.0f) {
            // 熔岩：发光的橙红，表面一块块结了暗壳
            float crust = tSmooth(0.45f, 0.62f, detailNoise(noise, p, 9.0f, footprint * 0.5f, 0.21f));
            float hot = 1.0f - 0.85f * crust;
            // 流动的熔岩：壳的裂缝里最亮（发黄），壳上是暗红
            s.emission = mix(float3(2.4f, 0.42f, 0.05f), float3(2.6f, 1.1f, 0.22f), hot * hot) * 0.075f * hot;
            s.albedo = mix(float3(0.08f, 0.03f, 0.02f), float3(0.03f), crust);
            s.material = MAT_LAVA;
        }
        if (h < 0.5f) s.material = MAT_WATER;
    }
    if (waterEdge < 0.0f) s.material = MAT_WATER;
    return s;
}

// MARK: - 片元

fragment float4 terrainFragment(TerrainOut in [[stage_in]],
                                constant ViewUniforms *views [[buffer(0)]],
                                constant FrameUniforms &F [[buffer(1)]],
                                constant rasterization_rate_map_data &rateMap [[buffer(2)]],
                                constant AtmosphereConstants &A [[buffer(3)]],
                                constant TerrainUniforms &T [[buffer(4)]],
                                texture2d<float> transLUT [[texture(0)]],
                                texture2d<float> skyLUT [[texture(1)]],
                                texture2d<float> skySeaLUT [[texture(2)]],
                                texture2d_array<float> cloudColor [[texture(3)]],
                                texture2d<float> cloudShadow [[texture(4)]],
                                texture2d<float> terrainShade [[texture(5)]],
                                texture3d<float> noise [[texture(6)]],
                                texture2d<float> surfaceMap [[texture(7)]]) {
#ifdef PROFILE_TERRAIN_FLAT
    return float4(0.2f, 0.3f, 0.1f, 1.0f);
#endif
    int scene = int(T.camera.w);
    float3 eye = views[in.viewIndex].cameraPosition.xyz;
    float3 toPoint = in.stagePos - eye;
    float dist = max(length(toPoint), 0.01f);
    float2 reveal = float2(1.0f, 0.0f);
    if (revealActive) {                                        // 开场：和天空一样按视线 7 米处实体化
        reveal = revealEnvironment(eye, toPoint / dist, F);
        if (reveal.x + reveal.y < 0.003f) discard_fragment();
    }
    float3 rd = rotateHeading(toPoint / dist, F.heading.x, F.heading.y);
    float3 sunDir = F.sunDirection.xyz;
    float2 p = in.ground;
    float h = in.height;
    // 一个像素在地上盖多大（米）
    float footprint = max(dist * 0.0011f / max(abs(dot(rd, normalize(in.normal))), 0.08f), 0.002f);

    // 格距以下的起伏：几个尺度的细节法线，越陡的地方（岩壁）起伏越大，越远越淡（免得闪）
    float3 N = normalize(in.normal);
    float3 geometric = N;          // 地面类型按几何法线判断（加了细节起伏的法线会把草地里零星的点判成岩石）
    float rough = mix(0.25f, 0.8f, saturate((1.0f - N.y) * 3.0f));
    // 两个尺度（37 米、6 米）的细节噪声：同一次采样既给颜色的深浅变化，也差分出细节起伏
    float n[2] = { 0.5f, 0.5f };
    float3 bump = 0.0f;
    const float scales[2] = { 37.0f, 6.0f };
    const float layers[2] = { 0.13f, 0.41f };
    for (int i = 0; i < 2; i++) {
        float sc = scales[i];
        float fade = saturate(sc / (footprint * 7.0f) - 1.0f);
        if (fade <= 0.0f) continue;
        float e = sc * 0.15f;
        // 坐标先弯一下（几百米一个来回）：噪声贴图每 37 米重复一圈，不弯的话远处的岩壁、火山口壁上是一排排整齐的鱼鳞
        float2 w = p + sc * 0.45f * sin(p.yx * (0.42f / sc) + float2(0.0f, 1.7f));
        float lod = noiseLod(footprint, sc);
        float c0 = noise.sample(trilinearRepeat, float3(w.x / sc, layers[i], w.y / sc), level(lod)).r;
        float cx = noise.sample(trilinearRepeat, float3((w.x + e) / sc, layers[i], w.y / sc), level(lod)).r;
        float cz = noise.sample(trilinearRepeat, float3(w.x / sc, layers[i], (w.y + e) / sc), level(lod)).r;
        n[i] = mix(0.5f, c0, fade);
        bump += float3(c0 - cx, 0.0f, c0 - cz) * (fade * rough * 1.4f);
    }
    // 雪原：风吹出来的一道道雪纹（顺着风向的波纹），近处才有
    if (scene == SCENE_SNOW) {
        float fade = saturate(3.0f / (footprint * 8.0f) - 1.0f);
        float2 wind = float2(0.8f, 0.6f);
        float phase = dot(p, wind) * 1.6f + 6.0f * (n[1] - 0.5f);
        bump += float3(wind.x, 0.0f, wind.y) * (0.12f * cos(phase) * fade);
        bump *= 1.0f + 1.6f * saturate((N.y - 0.8f) * 5.0f);       // 平的雪面上，雪丘和吹出来的雪垄起伏更明显
    }
    N = normalize(N + bump);

    // 近处再加两层细节（贴图一圈 1.9 米、0.37 米，各转一个角度，免得和上面两层对齐成格子）：离地一两百米以内才采样。
    // 草丛、砂砾、雪粒这些比最细的 6 米那层还小的东西，之前落地前后看是糊的一片
    float fine[2] = { 0.5f, 0.5f };
    float fineFade[2] = { 0.0f, 0.0f };
    float3 fineBump = 0.0f;
    const float fineScales[2] = { 1.9f, 0.37f };
    const float2 fineRot[2] = { float2(0.8f, 0.6f), float2(-0.28f, 0.96f) };
    for (int i = 0; i < 2; i++) {
        float sc = fineScales[i];
        float fade = saturate(sc / (footprint * 9.0f) - 1.0f);
        if (fade <= 0.0f) continue;
        float2 ax = fineRot[i], ay = float2(-ax.y, ax.x);
        float2 q = float2(dot(p, ax), dot(p, ay)) / sc;
        float layer = 0.27f + 0.4f * float(i);
        float c0 = noise.sample(linearRepeat, float3(q.x, layer, q.y), level(0)).r;
        float cx = noise.sample(linearRepeat, float3(q.x + 0.09f, layer, q.y), level(0)).r;
        float cz = noise.sample(linearRepeat, float3(q.x, layer, q.y + 0.09f), level(0)).r;
        fine[i] = mix(0.5f, c0, fade);
        fineFade[i] = fade;
        float2 gw = ax * (c0 - cx) + ay * (c0 - cz);
        fineBump += float3(gw.x, 0.0f, gw.y) * fade;
    }

    float4 sm = surfaceMapAt(surfaceMap, p);
    // 树冠：倒过来的 Worley 噪声本来就是一团团鼓包。贴图一圈 56 米（海岛的雨林树大，84 米），一棵树 7 ~ 10 米；
    // 两公里以内、附近有林子才采样。高度场差分出法线：每棵树朝太阳的一面亮、背面暗，林子不再是一块平涂的深绿
    float2 crown = float2(0.5f, 0.0f);
    float3 crownBump = 0.0f;
    if (scene != SCENE_VOLCANO && (sm.g > 0.02f || (scene == SCENE_GRASSLAND && sm.b > 0.02f))) {
        float tile = scene == SCENE_ISLAND ? 84.0f : 56.0f;
        float fade = saturate(tile / (footprint * 26.0f) - 1.0f);
        if (fade > 0.0f) {
            float2 q = p / tile;
            float lod = noiseLod(footprint, tile);
            float c0 = noise.sample(trilinearRepeat, float3(q.x, 0.58f, q.y), level(lod)).b;
            float cx = noise.sample(trilinearRepeat, float3(q.x + 0.02f, 0.58f, q.y), level(lod)).b;
            float cz = noise.sample(trilinearRepeat, float3(q.x, 0.58f, q.y + 0.02f), level(lod)).b;
            crown = float2(mix(0.5f, c0, fade), fade);
            crownBump = float3(c0 - cx, 0.0f, c0 - cz) * (fade * 5.0f);
        }
    }
    Surface s = terrainSurface(scene, p, h, geometric, footprint, n[0], n[1], sm, crown, noise);
    float onTarget = 0.0f;
    s.albedo = targetColor(p, s.albedo, onTarget);

    // 近处的细节按材质加：深浅、凹凸的幅度各不一样
    float fa = fine[0] - 0.5f, fb = fine[1] - 0.5f;
    float relief = 0.6f;
    float sparkle = 0.0f;
    if (onTarget > 0.5f) {
        s.albedo *= 1.0f + fa * 0.10f + fb * 0.08f;            // 靶是铺在地上的一块布：一点皱
        relief = 0.25f;
    } else if (s.material == MAT_FOREST) {
        N = normalize(N + crownBump);
        relief = 0.0f;
    } else if (s.material == MAT_GRASS) {
        // 草：一丛丛深浅不一，夹着干了发黄的；凑近了有零星的小花（成片地长）
        s.albedo *= 1.0f + fa * 0.7f + fb * 0.8f;
        s.albedo = mix(s.albedo, s.albedo * float3(1.5f, 1.25f, 0.7f), saturate(fa * 4.0f - 0.5f) * 0.6f);
        if (fineFade[1] > 0.0f) {
            float2 q = float2(dot(p, float2(0.6f, -0.8f)), dot(p, float2(0.8f, 0.6f))) / 2.6f;
            float dots = noise.sample(linearRepeat, float3(q.x, 0.91f, q.y), level(0)).a;
            float flower = smoothstep(0.9f, 0.95f, dots) * saturate(fa * 5.0f + 0.3f) * fineFade[1];
            float3 petal = scene == SCENE_ALPINE ? mix(float3(0.55f, 0.5f, 0.1f), float3(0.35f, 0.2f, 0.5f), step(0.5f, n[1]))
                                                 : mix(float3(0.7f, 0.7f, 0.62f), float3(0.7f, 0.55f, 0.08f), step(0.55f, n[1]));
            s.albedo = mix(s.albedo, petal, flower);
        }
        relief = 1.1f;
    } else if (s.material == MAT_SNOW) {
        // 雪：颜色几乎不变，细细的起伏；朝着太阳的雪粒一闪一闪（位置跟着视线变，头一动就换一批）
        s.albedo *= 1.0f + fa * 0.05f + fb * 0.04f;
        relief = 0.45f;
        if (fineFade[1] > 0.0f) {
            float2 q = p / 0.7f + rd.xz * 0.6f;
            float g = noise.sample(linearRepeat, float3(q.x, 0.77f + rd.y * 0.2f, q.y), level(0)).a;
            sparkle = smoothstep(0.93f, 0.985f, g) * fineFade[1];
        }
    } else if (s.material == MAT_SAND) {
        // 沙：细粒，被浪和风理出来的一道道浅纹
        float ripple = sin(dot(p, float2(0.94f, 0.34f)) * 9.0f + fa * 9.0f) * fineFade[0];
        s.albedo *= 1.0f + fa * 0.16f + fb * 0.22f + ripple * 0.035f;
        fineBump += float3(0.94f, 0.0f, 0.34f) * (ripple * 0.05f);
        relief = 0.45f;
    } else if (s.material == MAT_ASH) {
        // 火山灰、火山渣：粗砂一样的颗粒，散着拳头大的黑石头
        s.albedo *= 1.0f + fa * 0.4f + fb * 0.3f;
        s.albedo *= 1.0f - 0.5f * smoothstep(0.2f, 0.26f, fb) * fineFade[1] * step(0.55f, fine[0]);
        relief = 0.8f;
    } else {
        s.albedo *= 1.0f + fa * 0.5f + fb * 0.45f;            // 岩石、碎石
        relief = 1.3f;
    }
    N = normalize(N + fineBump * relief);

    // 光：太阳（山影 × 云影）+ 天光（× 环境光遮蔽）
    float2 shade = terrainShade.sample(linearClamp, p / TERRAIN_MAP_SIZE + 0.5f, level(0)).rg;
    float2 cloudXZ = p - F.ground.yw - sunDir.xz * (h / max(sunDir.y, 0.05f));
    float od = cloudShadow.sample(linearRepeat, cloudXZ / WEATHER_TILE + 0.5f, level(0)).r;
    od *= smoothstep(300.0f, 650.0f, length(p - LZ_TARGET));     // 着陆区不落云影（和海面一样）
    // 云影：积云底下不是全黑——阳光在云里散射过，漏下来两三成
    float cloudVis = mix(0.24f, 1.0f, exp(-od * F.clouds.z * 0.5f));
    float shadow = shade.r * cloudVis;
    // 自己的伞衣和身体的影子（快落地时才看得清：离得越近边越实）
    float3 Ls = stageSunDirection(F);
    float3 sunVis = shadow * canopyShadow(in.stagePos, Ls, F) * bodyShadow(in.stagePos, Ls, F);
    float altKm = h * 0.001f;
    float3 sunE = altKm < 1.0f ? mix(A.sunAtSea.rgb, A.sunAtCloudBase.rgb, saturate(altKm))
                               : mix(A.sunAtCloudBase.rgb, A.sunAtCloudTop.rgb, saturate((altKm - 1.0f) / 8.0f));
    // 天光（带上云漫射下来的白光，见 cloudySkyFill）
    float3 skyE = cloudySkyFill(A.skyIrradianceSea.rgb) * (0.55f + 0.45f * N.y) * shade.g;
    float NdotL = saturate(dot(N, sunDir));
    float3 color;
    if (s.material == MAT_WATER && onTarget < 0.5f) {
        // 河、湖、海：和环礁的海面一样的着色
        float residual;
        bool sea = scene == SCENE_VOLCANO || scene == SCENE_ISLAND;
        float2 slope = waveSlope(p, F.camera.y, footprint, noise, residual) * (sea ? 1.0f : 0.35f);
        float3 Nw = normalize(float3(-slope.x, 1.0f, -slope.y));
        float3 waterAlbedo = float3(0.006f, 0.02f, 0.025f);
        float foam = 0.0f;
        if (scene == SCENE_ISLAND) {
            // 海岛：浅的礁坪透出白沙底和一丛丛珊瑚（碧绿），越深越蓝；礁边浪一阵阵碎开，岸边一条冲上沙滩的白沫
            float depth = max(-h, 0.0f);
            float coral = tSmooth(0.2f, 0.6f, n[0]) * tSmooth(6.0f, 1.0f, depth);
            float3 shallow = mix(float3(0.10f, 0.42f, 0.40f), float3(0.05f, 0.22f, 0.20f), coral);
            waterAlbedo = mix(shallow, float3(0.006f, 0.022f, 0.03f), tSmooth(1.5f, 22.0f, depth));
            float c = (islandLand(p) + 0.115f) / 0.008f;
            float crest = exp(-c * c) * (0.55f + 0.45f * sin(F.camera.y * 0.9f + dot(p, float2(0.03f, 0.021f)) + 6.0f * n[0]));
            float shore = tSmooth(-0.5f, 0.1f, h) * (0.6f + 0.4f * sin(F.camera.y * 1.3f + dot(p, float2(0.05f, 0.04f))));
            foam = saturate(max(crest, shore) * (0.6f + 0.6f * n[1]));
        }
        color = oceanShade(Nw, rd, sunDir, dot(sunVis, float3(0.3333f)), 0.006f + residual, waterAlbedo, A, skySeaLUT);
        if (foam > 0.0f) {
            float3 white = float3(0.82f, 0.85f, 0.87f) / PI
                         * (sunE * saturate(sunDir.y) * dot(sunVis, float3(0.3333f)) + skyE);
            color = mix(color, white, foam * 0.8f);
        }
    } else {
        // 背阴的陡坡还会被对面照亮的山坡、谷底反射一点暖光（不然阴面只剩蓝天光，发蓝发暗）
        // （平地也有一点：周围被太阳照亮的地面、山坡反射回来的光）
        float3 bounce = sunE * float3(1.0f, 0.95f, 0.85f) * (0.035f + 0.15f * saturate(1.0f - N.y)) * shade.g;
        color = s.albedo / PI * (sunE * NdotL * sunVis + skyE + bounce);
        if (s.specular > 0.0f) {
            float3 H = normalize(sunDir - rd);
            color += sunE * sunVis * s.specular * pow(saturate(dot(N, H)), 1.0f / max(s.roughness * s.roughness, 0.002f) * 0.5f);
        }
        color += sunE * sunVis * (sparkle * 0.22f * NdotL);
        color += s.emission;
    }

    // 空气透视：这一段的透射率（查表），散射进来的光按同一方位地平线的天空色（远山发白发蓝就是这个颜色）。
    // 之前按「整条视线的散射 × 这一段占的比例」折算，视线打不打得到海面用的是天空表的两半，地平线上下接不上，
    // 地形上会出一道横线。
    float eyeAlt = max(eye.y + F.camera.x, 1.0f);
    float camR = ATM_BOTTOM + eyeAlt * 0.001f;
    // 低空比标准大气多一点霾（远山、远处的平原要淡下去，不然地平线下面一圈发深）
    float3 Tt = segmentTransmittance(eyeAlt * 0.001f, max(h, 0.0f) * 0.001f, dist * 0.001f * 2.2f);
    float3 haze = skyViewLookup(skyLUT, normalize(float3(rd.x, 0.003f, rd.z)), sunDir, camR, false);
    color = color * Tt + haze * (1.0f - Tt);

    // 云层盖上来（云在地形前面的部分，云层 pass 按地形深度截断；雨帘也在云层里）
    float4 cloud = cloudColor.sample(pixelLinearClamp, in.position.xy * F.clouds.x, in.viewIndex);
    color = color * cloud.a + cloud.rgb;

    color = tonemap(color * F.exposure.x) * F.camera.z;
    if (F.heading.z > 0.001f) {
        float2 screen = screenPosition(in.position.xy, in.viewIndex, F.camera.w > 0.5f, rateMap);
        float2 uv = (screen - views[in.viewIndex].viewport.xy) / views[in.viewIndex].viewport.zw - 0.5f;
        color *= 1.0f - F.heading.z * smoothstep(0.17f, 0.5f, length(uv));
    }
    float3 g = sqrt(color) + (ign(in.position.xy + 17.0f) - 0.5f) / 255.0f;
    if (revealActive) {
        float a = reveal.x;
        return float4(g * g * a + REVEAL_GLOW_COLOR * reveal.y * F.camera.z, saturate(a + reveal.y * 0.5f));
    }
    return float4(g * g, 1.0f);
}

// MARK: - 启动时

kernel void generateTerrainHeight(texture2d<float, access::write> out [[texture(0)]],
                                  constant int &scene [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    float2 p = ((float2(gid) + 0.5f) / float2(size) - 0.5f) * TERRAIN_MAP_SIZE;
    out.write(float4(terrainHeight(scene, p), 0.0f, 0.0f, 0.0f), gid);
}

/// 山影图：r 太阳照得到的程度（朝太阳在高度图上走一段，被山挡住就暗；边缘软一点），g 环境光遮蔽（凹下去的地方天光少）
kernel void computeTerrainShadow(texture2d<float, access::write> out [[texture(0)]],
                                 texture2d<float> heightMap [[texture(1)]],
                                 constant float4 &sun [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (any(gid >= size)) return;
    float2 uv = (float2(gid) + 0.5f) / float2(size);
    float2 p = (uv - 0.5f) * TERRAIN_MAP_SIZE;
    // 只要大山脊投下的影子：从 150 米外开始找、抬高 25 米，坡面上小起伏的细碎阴影交给法线明暗
    float h0 = heightMap.read(gid).r + 25.0f;
    float2 dir = normalize(sun.xz);
    float tanSun = sun.y / max(length(sun.xz), 1e-3f);
    float vis = 1.0f;
    float t = 150.0f;
    for (int i = 0; i < 100; i++) {
        float hq = heightMap.sample(linearClamp, (p + dir * t) / TERRAIN_MAP_SIZE + 0.5f, level(0)).r;
        float ray = h0 + t * tanSun;
        vis = min(vis, saturate((ray - hq) / (t * 0.1f + 15.0f) + 0.5f));
        t = t * 1.055f + 20.0f;
    }
    float occlusion = 0.0f;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * (2.0f * PI / 8.0f);
        float2 d = float2(cos(a), sin(a));
        for (int j = 1; j <= 3; j++) {
            float rr = 60.0f * float(j * j);
            float hq = heightMap.sample(linearClamp, (p + d * rr) / TERRAIN_MAP_SIZE + 0.5f, level(0)).r;
            occlusion += saturate((hq - h0) / rr) * (1.0f / 24.0f);
        }
    }
    out.write(float4(vis, saturate(1.0f - occlusion * 1.1f), 0.0f, 0.0f), gid);
}

/// 离屏测试用：在给定的地面坐标上算地形高度和地面类型，和 Swift 的 TerrainField 比对
kernel void sampleTerrain(device const float2 *points [[buffer(0)]],
                          device float2 *out [[buffer(1)]],
                          constant int &scene [[buffer(2)]],
                          constant uint &count [[buffer(3)]],
                          uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    float h = terrainHeight(scene, points[gid]);
    out[gid] = float2(h, float(terrainHazard(scene, points[gid], h)));
}
