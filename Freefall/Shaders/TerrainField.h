#pragma once
#include "Common.h"

// 地形场景的高度和地面类型：草原、高山、雪山、海岛、火山（环礁是平的海，不走这里）。
// 高度是程序生成的函数：GPU 用它画地形网格、生成高度图（云被山挡住、山的影子）；
// Swift 的 TerrainField.swift 逐行照抄了一份，CPU 用它判断落地、撞山、掉进河里 / 海里 / 树林 / 岩浆。
// **改这里必须同步改那边**（tools/render-check 的 terrain 模式会比对两边的高度）。
//
// 所有地形场景共用一个着陆点：靶在地面坐标 LZ_TARGET，开伞点大约在 (0, -100)，从开伞点到靶的方向是 VALLEY_DIR。
// 山谷、河都顺着这个方向摆，正常开伞以后顺着谷飞就能到靶。

#define SCENE_ATOLL 0
#define SCENE_GRASSLAND 1
#define SCENE_ALPINE 2
#define SCENE_SNOW 3
#define SCENE_ISLAND 4
#define SCENE_VOLCANO 5
#define SCENE_SKY 6

#define LZ_TARGET float2(380.0f, -620.0f)
#define VALLEY_DIR float2(0.59028f, -0.80720f)
#define VALLEY_SIDE float2(0.80720f, 0.59028f)

// 地面类型
#define MAT_ROCK 0
#define MAT_GRASS 1
#define MAT_FOREST 2
#define MAT_SNOW 3
#define MAT_ICE 4
#define MAT_WATER 5
#define MAT_LAVA 6
#define MAT_ASH 7
#define MAT_SCREE 8
#define MAT_FIELD 9
#define MAT_MORAINE 10
#define MAT_CREVASSE 11
#define MAT_SAND 12
#define MAT_VOID 13         // 天空之城：岛外面，下面是云海
#define MAT_PAVED 14        // 石板铺的地

// 火山：火山口、熔岩湖、烟柱（地面坐标）
#define CONE_CENTER float2(-500.0f, -950.0f)
#define CONE_BASE_RADIUS 520.0f
#define CONE_TOP 900.0f
#define CRATER_RADIUS 150.0f
#define LAVA_LAKE 780.0f
#define PLUME_DRIFT float2(-0.55f, 0.22f)

// MARK: - 噪声（整数哈希的值噪声，带导数）

static inline float tHash(int2 c) {
    uint h = (uint(c.x) * 0x8DA6B343u) ^ (uint(c.y) * 0xD8163841u);
    h ^= h >> 15u;
    h *= 0x2C1B3C6Du;
    h ^= h >> 12u;
    h *= 0x297A2D39u;
    h ^= h >> 15u;
    return float(h) * (2.0f / 4294967296.0f) - 1.0f;
}

/// 值噪声（-1..1）和它的两个偏导数
static inline float3 tNoised(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float2 du = 30.0f * f * f * (f * (f - 2.0f) + 1.0f);
    int2 c = int2(i);
    float a = tHash(c), b = tHash(c + int2(1, 0)), d = tHash(c + int2(0, 1)), e = tHash(c + int2(1, 1));
    float k1 = b - a, k2 = d - a, k4 = a - b - d + e;
    return float3(a + k1 * u.x + k2 * u.y + k4 * u.x * u.y,
                  du.x * (k1 + k4 * u.y), du.y * (k2 + k4 * u.x));
}

static inline float tNoise(float2 p) { return tNoised(p).x; }

/// 下一个八度：放大 2 倍、转 37°（不对齐网格，没有横平竖直的纹）
static inline float2 tOctave(float2 p) {
    return float2(1.6f * p.x - 1.2f * p.y, 1.2f * p.x + 1.6f * p.y);
}

/// 普通 fbm，约 -1..1
static inline float tFbm(float2 p, int octaves) {
    float a = 0.0f, b = 0.5f;
    for (int i = 0; i < octaves; i++) {
        a += b * tNoise(p);
        b *= 0.5f;
        p = tOctave(p) + float2(3.1f, 1.7f);
    }
    return a;
}

/// 有侵蚀感的 fbm（Quilez）：坡陡的地方后面的细节压小，山脊尖、山谷平
static inline float tEroded(float2 p, int octaves) {
    float a = 0.0f, b = 1.0f;
    float2 d = 0.0f;
    for (int i = 0; i < octaves; i++) {
        float3 n = tNoised(p);
        d += n.yz;
        a += b * n.x / (1.0f + dot(d, d));
        b *= 0.5f;
        p = tOctave(p);
    }
    return a;
}

/// 山脊噪声：1 - |n| 的平方，越高的八度只长在上一层的脊上，0..1
static inline float tRidged(float2 p, int octaves) {
    float a = 0.0f, b = 0.5f, w = 1.0f;
    for (int i = 0; i < octaves; i++) {
        float n = 1.0f - abs(tNoise(p));
        n = n * n * w;
        w = saturate(n * 1.8f);
        a += n * b;
        b *= 0.5f;
        p = tOctave(p) + float2(1.3f, -2.9f);
    }
    return a;
}

static inline float tSmooth(float a, float b, float x) {
    float t = saturate((x - a) / (b - a));
    return t * t * (3.0f - 2.0f * t);
}

/// (沿山谷往下游的距离, 横向往右的距离)，原点在靶上
static inline float2 valleyCoords(float2 p) {
    float2 d = p - LZ_TARGET;
    return float2(dot(d, VALLEY_DIR), dot(d, VALLEY_SIDE));
}

// MARK: - 着陆区的海拔（Swift 的 JumpScene.dzElevation 一致）

static inline float dzElevation(int scene) {
    switch (scene) {
    case SCENE_GRASSLAND: return 240.0f;
    case SCENE_ALPINE: return 1150.0f;
    case SCENE_SNOW: return 2750.0f;
    case SCENE_ISLAND: return 3.5f;
    case SCENE_VOLCANO: return 620.0f;
    case SCENE_SKY: return 3300.0f;
    default: return 0.0f;
    }
}

// MARK: - 草原：缓丘、一条弯弯的河、一个池塘、成片的树林、农田

/// 河：大致东西向，从开伞点和靶中间穿过去。返回到河中线的距离（米）
static inline float riverDistance(float2 p) {
    float x = p.x;
    float z = -390.0f + 110.0f * precise::sin(x / 310.0f + 0.4f) + 45.0f * precise::sin(x / 120.0f + 2.1f);
    float slope = 110.0f / 310.0f * precise::cos(x / 310.0f + 0.4f) + 45.0f / 120.0f * precise::cos(x / 120.0f + 2.1f);
    return abs(p.y - z) / precise::sqrt(1.0f + slope * slope);
}

#define RIVER_HALF_WIDTH 14.0f
#define POND_CENTER float2(650.0f, -800.0f)
#define POND_RADIUS 55.0f

static inline float grasslandHeight(float2 p) {
    float r = length(p - LZ_TARGET);
    float river = riverDistance(p);
    float pond = length(p - POND_CENTER);
    // 缓丘：离河、离着陆区远的地方才起伏，河在一片平的河滩里
    float hills = 55.0f * tFbm(p / 3200.0f + float2(5.2f, 1.3f), 4) + 7.0f * tFbm(p / 420.0f + float2(1.1f, 8.3f), 3);
    float flat = tSmooth(60.0f, 420.0f, river) * tSmooth(140.0f, 650.0f, r) * tSmooth(80.0f, 300.0f, pond);
    float h = 240.0f + hills * flat + 0.6f * tFbm(p / 55.0f, 3);
    // 河槽和池塘：水面比河滩低 2.5 米
    float water = 237.5f;
    h = mix(water, h, tSmooth(RIVER_HALF_WIDTH, RIVER_HALF_WIDTH + 14.0f, river));
    h = mix(water, h, tSmooth(POND_RADIUS, POND_RADIUS + 16.0f, pond));
    return h;
}

/// 树林（0..1，> 0.5 算树林）：成片的林子，河两岸一溜，着陆区周围是空地
static inline float grasslandForest(float2 p) {
    float r = length(p - LZ_TARGET);
    float river = riverDistance(p);
    float patches = tFbm(p / 650.0f + float2(7.7f, 2.2f), 4);
    float riparian = tSmooth(70.0f, 35.0f, river) * tSmooth(RIVER_HALF_WIDTH + 4.0f, RIVER_HALF_WIDTH + 12.0f, river)
                   * tSmooth(-0.25f, 0.05f, tFbm(p / 120.0f + float2(3.3f, 9.9f), 3));
    float f = max(tSmooth(0.1f, 0.2f, patches), riparian);
    return f * tSmooth(200.0f, 260.0f, r);
}

// MARK: - 高山：U 形谷，两边是陡峭的岩壁和山峰，谷底有草甸、溪流、林子

static inline float alpineFloor(float s) { return 1150.0f + 0.035f * max(-s, 0.0f) - 0.02f * max(s, 0.0f); }

/// 溪流（在谷底靶的左边一百多米，弯来弯去）到中线的距离
/// 溪的中线（横向坐标）
static inline float alpineStreamCenter(float s) {
    return -175.0f + 60.0f * precise::sin(s / 240.0f) + 25.0f * precise::sin(s / 90.0f + 1.3f);
}
/// 深潭 / 浅滩的节奏（1 深潭，0 浅滩；一百来米一段，长短很不一样）
static inline float alpineStreamPool(float s) {
    return 0.5f + 0.5f * precise::sin(s / 21.0f + 3.2f * precise::sin(s / 97.0f) + 1.7f * precise::sin(s / 41.0f));
}
/// 到溪中线的距离，「5 米」是水边：浅滩宽（半宽 6.8 米）、深潭窄（半宽 3.8 米），不再是一根等宽的带子
static inline float alpineStreamDistance(float2 sl) {
    // 离溪的走廊远（中线只在 -175 ± 85 米里摆）：不用算那几个正弦，给一个够大的下界（用到它的地方最远只看到 38 米）
    float off = abs(sl.y + 175.0f);
    if (off > 130.0f) return off - 85.0f;
    return abs(sl.y - alpineStreamCenter(sl.x)) + 3.0f * alpineStreamPool(sl.x) - 1.8f;
}

static inline float alpineHeight(float2 p) {
    float2 sl = valleyCoords(p);
    float s = sl.x, l = sl.y;
    float floorH = alpineFloor(s);
    float halfWidth = 430.0f + 150.0f * tFbm(float2(s / 1800.0f, 9.1f), 3);
    float lp = max(abs(l) - halfWidth, 0.0f);
    float wall = 2600.0f * (1.0f - precise::exp(-precise::pow(lp / 1150.0f, 1.7f)));
    float steep = tSmooth(0.0f, 500.0f, lp);
    float mountains = tEroded(p / 2400.0f + float2(3.7f, 1.3f), 10);
    float h = floorH + wall + mountains * mix(14.0f, 950.0f, steep) + 0.5f * tFbm(p / 40.0f, 3);
    // 着陆区一片平的草甸
    float r = length(p - LZ_TARGET);
    h = mix(1150.0f + 0.4f * tFbm(p / 40.0f, 3), h, tSmooth(80.0f, 240.0f, r));
    // 溪流
    float stream = alpineStreamDistance(sl);
    float water = floorH - 3.0f;
    h = mix(min(water, h), h, tSmooth(5.0f, 22.0f, stream));
    return h;
}

static inline float alpineForest(float2 p, float h) {
    float2 sl = valleyCoords(p);
    float r = length(p - LZ_TARGET);
    float lp = max(abs(sl.y) - 380.0f, 0.0f);
    float patches = tFbm(p / 500.0f + float2(4.4f, 6.1f), 4);
    // 林线：谷底往上五六百米，参差不齐
    float treeline = alpineFloor(sl.x) + 560.0f + 180.0f * tNoise(p / 700.0f + float2(2.0f, 2.0f));
    float belowTreeline = tSmooth(treeline + 60.0f, treeline - 60.0f, h);
    float onSlope = tSmooth(0.0f, 150.0f, lp) + tSmooth(0.15f, 0.3f, patches);
    return saturate(onSlope) * belowTreeline * tSmooth(-0.05f, 0.08f, patches) * tSmooth(230.0f, 300.0f, r)
         * tSmooth(18.0f, 30.0f, alpineStreamDistance(sl));
}

// MARK: - 雪山：高处的冰斗，一大片平的雪坡，四周是尖利的雪峰和岩壁

static inline float snowHeight(float2 p) {
    float2 sl = valleyCoords(p);
    float s = sl.x, l = sl.y;
    float floorH = 2750.0f + 0.06f * max(-s, 0.0f) - 0.04f * max(s, 0.0f);
    float halfWidth = 650.0f + 200.0f * tFbm(float2(s / 2000.0f, 2.7f), 3);
    float lp = max(abs(l) - halfWidth, 0.0f);
    float wall = 2300.0f * (1.0f - precise::exp(-precise::pow(lp / 1000.0f, 1.6f)));
    float steep = tSmooth(0.0f, 400.0f, lp);
    float ridges = tRidged(p / 3000.0f + float2(8.1f, 0.4f), 8);
    float h = floorH + wall + (ridges - 0.35f) * mix(30.0f, 1300.0f, steep)
            + 4.0f * tFbm(p / 260.0f, 3) * (1.0f - steep);
    float r = length(p - LZ_TARGET);
    h = mix(2750.0f + 0.6f * tFbm(p / 60.0f, 3), h, tSmooth(90.0f, 300.0f, r));
    return h;
}

// MARK: - 海岛：四面环海的热带小岛（和 Swift 的 TerrainField.islandHeight 逐行对应）

#define ISLAND_CENTER float2(1250.0f, 150.0f)
#define ISLAND_AXES float2(1330.0f, 1050.0f)

/// 离海岸多远（按岛的半轴归一化）：> 0 在岛上，< 0 在海里
static inline float islandLand(float2 p) {
    float2 q = (valleyCoords(p) - ISLAND_CENTER) / ISLAND_AXES;
    float r = length(p - LZ_TARGET);
    return 1.0f - length(q) + 0.07f * tFbm(p / 700.0f + float2(3.1f, 7.7f), 4) * tSmooth(250.0f, 700.0f, r);
}

static inline float islandHeight(float2 p) {
    float land = islandLand(p);
    float sea = -0.6f - 1.2f * tSmooth(-0.005f, -0.06f, land) - 42.0f * tSmooth(-0.11f, -0.2f, land)
              + 0.6f * tFbm(p / 60.0f, 3);
    float hills = 470.0f * precise::pow(tSmooth(0.1f, 0.75f, land), 1.3f)
                * (0.75f + 0.45f * tEroded(p / 1300.0f + float2(5.5f, 2.5f), 7));
    float ground = 2.6f * tSmooth(-0.01f, 0.03f, land) + 1.5f * tSmooth(0.03f, 0.12f, land) + hills
                 + 0.5f * tFbm(p / 45.0f, 3);
    float h = mix(sea, ground, tSmooth(-0.012f, 0.004f, land));
    float r = length(p - LZ_TARGET);
    h = mix(h, 3.5f + 0.25f * tFbm(p / 40.0f, 3), (1.0f - tSmooth(70.0f, 190.0f, r)) * tSmooth(0.0f, 0.02f, land));
    return h;
}

/// 雨林（> 0.5 算树林）：沙滩后面一条之外全是；靶周围两百米是一片空地
static inline float islandForest(float2 p) {
    float land = islandLand(p);
    float patches = tFbm(p / 380.0f + float2(8.8f, 1.4f), 4);
    return tSmooth(0.05f, 0.09f, land + 0.04f * patches) * tSmooth(180.0f, 240.0f, length(p - LZ_TARGET));
}

// MARK: - 火山：破火山口（一大片平地，四周是陡的口壁），里面一座正在喷的小火山锥，熔岩往外流

static inline float lavaFlowDistance(float2 p) {
    // 两条熔岩流：一条往右下（从靶的下方 500 米经过），一条往左
    float2 a0 = CONE_CENTER, a1 = float2(-150.0f, -1080.0f), a2 = float2(250.0f, -1180.0f), a3 = float2(700.0f, -1430.0f);
    float2 b1 = float2(-880.0f, -720.0f), b2 = float2(-1250.0f, -330.0f);
    float d = 1e9f;
    float2 seg[5][2] = { {a0, a1}, {a1, a2}, {a2, a3}, {a0, b1}, {b1, b2} };
    for (int i = 0; i < 5; i++) {
        float2 pa = p - seg[i][0], ba = seg[i][1] - seg[i][0];
        float t = saturate(dot(pa, ba) / dot(ba, ba));
        d = min(d, length(pa - ba * t));
    }
    return d + 5.0f * tNoise(p / 60.0f) + 4.0f * tNoise(p / 210.0f);     // （半宽 5~23 米：之前 2~26，窄的地方掐成一串香肠）
}

static inline float volcanoHeight(float2 p) {
    float2 kc = float2(150.0f, -350.0f);
    float rk = length(p - kc);
    // 破火山口：半径 2.3 km 的平底，口壁高 350 米，外坡一路下到 9 km 外的海里
    float rimNoise = 120.0f * tFbm(p / 900.0f + float2(2.2f, 7.1f), 4);
    float inner = 620.0f + 4.0f * tFbm(p / 300.0f, 3) + 1.2f * tFbm(p / 45.0f, 3);
    float rimH = 980.0f + rimNoise;
    float outer = rimH * precise::pow(saturate(1.0f - (rk - 2500.0f) / 7000.0f), 1.6f) - 30.0f;
    float h = rk < 2300.0f ? mix(inner, rimH, tSmooth(1950.0f, 2300.0f, rk))
                           : mix(rimH, outer, tSmooth(2300.0f, 2700.0f, rk));
    h += 160.0f * tEroded(p / 1800.0f, 7) * tSmooth(2000.0f, 2600.0f, rk);
    // 火山锥：凹的坡面，顶上一个火山口
    float rc = length(p - CONE_CENTER);
    float cone = (CONE_TOP - 620.0f) * precise::pow(saturate(1.0f - rc / CONE_BASE_RADIUS), 1.5f);
    float crater = tSmooth(CRATER_RADIUS + 40.0f, CRATER_RADIUS - 30.0f, rc);
    float coneH = 620.0f + cone + 18.0f * tFbm(p / 120.0f, 3) * tSmooth(CONE_BASE_RADIUS, 200.0f, rc);
    coneH = mix(coneH, LAVA_LAKE, crater);
    h = max(h, coneH);
    // 熔岩流比两边略高一点（流动的熔岩堤）
    float flow = lavaFlowDistance(p);
    h += 3.0f * tSmooth(40.0f, 12.0f, flow) * step(rk, 2200.0f);
    float r = length(p - LZ_TARGET);
    h = mix(620.0f + 0.3f * tFbm(p / 40.0f, 3), h, tSmooth(80.0f, 200.0f, r));
    return h;
}

static inline bool volcanoLava(float2 p) {
    return lavaFlowDistance(p) < 14.0f || length(p - CONE_CENTER) < CRATER_RADIUS - 20.0f;
}

/// 烟柱：从火山口往上，越高越粗，被风吹得往左偏。返回 0..1 的浓度（> 0.4 算冲进去了）
static inline float plumeDensity(float2 p, float altitude) {
    float above = altitude - (CONE_TOP - 40.0f);
    if (above < 0.0f || above > 3200.0f) return 0.0f;
    float2 axis = CONE_CENTER + PLUME_DRIFT * above;
    float radius = 90.0f + 0.22f * above;
    float d = length(p - axis) / radius;
    return saturate(1.0f - d * d) * tSmooth(3200.0f, 1800.0f, above);
}

// MARK: - 天空之城：云海上面的一群浮岛（和 Swift 的 TerrainField.sky* 逐行对应）
//
// 岛都摆在谷坐标里（沿进场方向, 横向，原点在靶上），每座是一个椭圆，边被噪声啃得参差不齐；俯视互不重叠，
// 所以顶面还是一张高度场。岛的底面是另一张高度场（倒过来的山，岛边上两张面合在一起），只有 GPU 用。
// 岛外面什么都没有（地形网格按 mask 裁掉）；CPU 那边岛外的「地面」是 SKY_VOID：伞降到那个高度算掉进云海。

#define SKY_COUNT 16
#define SKY_ALT 3293.0f
#define SKY_VOID 2880.0f
#define SKY_CITADEL float2(215.0f, 0.0f)
#define SKY_POOL float2(120.0f, -150.0f)
#define SKY_POOL_RADIUS 24.0f

/// 第 i 座岛：xy 中心（谷坐标），zw 两个半轴（米）。0 是着陆的主岛
static inline float4 skyIslandShape(int i) {
    const float4 shape[SKY_COUNT] = {
        float4(60.0f, 0.0f, 330.0f, 235.0f),      float4(-520.0f, -290.0f, 150.0f, 110.0f),
        float4(-440.0f, 350.0f, 125.0f, 95.0f),   float4(590.0f, -340.0f, 190.0f, 140.0f),
        float4(640.0f, 300.0f, 150.0f, 115.0f),   float4(70.0f, -540.0f, 115.0f, 85.0f),
        float4(130.0f, 500.0f, 105.0f, 85.0f),    float4(-960.0f, 80.0f, 230.0f, 170.0f),
        float4(1180.0f, -20.0f, 280.0f, 210.0f),  float4(-270.0f, -200.0f, 34.0f, 27.0f),
        float4(-190.0f, 290.0f, 30.0f, 24.0f),    float4(330.0f, -380.0f, 36.0f, 28.0f),
        float4(440.0f, 360.0f, 32.0f, 26.0f),     float4(-700.0f, 470.0f, 48.0f, 36.0f),
        float4(900.0f, -600.0f, 70.0f, 52.0f),    float4(-40.0f, 820.0f, 80.0f, 60.0f),
    };
    return shape[i];
}

/// x 岛面比主岛高多少（米），y 噪声的种子
static inline float2 skyIslandInfo(int i) {
    const float2 info[SKY_COUNT] = {
        float2(0.0f, 1.3f),    float2(45.0f, 4.1f),    float2(-60.0f, 7.7f),   float2(120.0f, 2.9f),
        float2(-90.0f, 9.3f),  float2(70.0f, 5.5f),    float2(-40.0f, 6.2f),   float2(180.0f, 8.4f),
        float2(60.0f, 3.6f),   float2(-25.0f, 11.0f),  float2(30.0f, 12.5f),   float2(-50.0f, 13.2f),
        float2(15.0f, 14.9f),  float2(100.0f, 15.4f),  float2(-140.0f, 16.8f), float2(150.0f, 17.1f),
    };
    return info[i];
}

/// 在第 i 座岛里有多深：> 0 在岛上（岛心约 1），< 0 在外面
static inline float skyMask(float2 sl, int i) {
    float4 s = skyIslandShape(i);
    float e = 1.0f - length((sl - s.xy) / s.zw);
    if (e < -0.4f) return e;
    return e + 0.2f * tFbm(sl / (0.6f * min(s.z, s.w)) + skyIslandInfo(i).y, 3);
}

/// 最近的岛：x 它的 mask，y 编号
static inline float2 skyNearest(float2 sl) {
    float best = -1e9f;
    int index = 0;
    for (int i = 0; i < SKY_COUNT; i++) {
        float m = skyMask(sl, i);
        if (m > best) { best = m; index = i; }
    }
    return float2(best, float(index));
}

/// 岛的顶面（m ≤ 0 时顺着岛边往外延出去一点：网格在岛边被裁开，裁口两侧的顶点高度要连得上）。
/// terraces：带不带城堡的三层台基。台基画的时候是 SkyCity 的网格（直上直下的石墙，地形网格的格子抹不出来），
/// 地形网格在那里是平的；落地判定、高度图用的高度带台基（和 CPU 一致）
static inline float skyTop(float2 p, float2 sl, int i, float m, bool terraces) {
    float2 info = skyIslandInfo(i);
    float mm = max(m, 0.0f);
    float h = SKY_ALT + info.x + 7.0f * tSmooth(0.0f, 0.5f, mm) - 4.0f * (1.0f - tSmooth(0.0f, 0.07f, mm))
            + 2.5f * tFbm(p / 90.0f + info.y, 3) + 0.4f * tFbm(p / 14.0f, 2);
    if (i == 0) {
        // 主岛：靶周围一片平的草坪；城堡的三层台基；一个水池
        float flatH = SKY_ALT + 7.0f;
        h = mix(flatH + 0.15f * tFbm(p / 30.0f, 2), h, tSmooth(45.0f, 110.0f, length(sl)));
        float rc = length(sl - SKY_CITADEL);
        h = mix(flatH, h, tSmooth(84.0f, 110.0f, rc));
        if (terraces) h += 4.0f * (tSmooth(79.0f, 77.5f, rc) + tSmooth(65.0f, 63.5f, rc) + tSmooth(51.0f, 49.5f, rc));
        h -= 2.2f * tSmooth(31.0f, 23.0f, length(sl - SKY_POOL));
    }
    return h;
}

/// 岛的底面（只有 GPU 用）：岛边一圈几十米的崖壁，往里是倒过来的山，挂着一道道石棱
static inline float skyBottom(float2 p, int i, float m, float top) {
    float4 s = skyIslandShape(i);
    float minAxis = min(s.z, s.w);
    // 厚度在岛边（m = 0）两侧要是 m 的线性函数（m < 0 是负的）：网格在 m = 0 被裁开，裁口上的高度是两头顶点的线性插值，
    // 厚度过零点和 mask 过零点对不上的话，顶面和底面之间会裂开一道缝
    float cliff = (14.0f + 0.12f * minAxis) * clamp(m / 0.05f, -1.0f, 1.0f);
    float body = (20.0f + 0.75f * minAxis) * (m < 0.0f ? 1.6f * m : 1.0f - pow(1.0f - min(m, 1.0f), 1.6f));
    float rough = 0.7f + 0.6f * tRidged(p / (0.45f * minAxis) + skyIslandInfo(i).y, 3);
    return top - cliff - body * rough;
}

/// 画网格用：第 i 座岛的顶面或底面在 p 的高度
static inline float skySurface(float2 p, int i, bool under) {
    float2 sl = valleyCoords(p);
    float m = skyMask(sl, i);
    float top = skyTop(p, sl, i, m, false);
    return under ? skyBottom(p, i, m, top) : top;
}

static inline float skyHeight(float2 p) {
    float2 sl = valleyCoords(p);
    float2 n = skyNearest(sl);
    return n.x > 0.0f ? skyTop(p, sl, int(n.y), n.x, true) : SKY_VOID;
}

/// 开花的树林（> 0.5 算树林）：靶周围、进场的那一路、城堡和水池边上没有
static inline float skyForest(float2 p) {
    float2 sl = valleyCoords(p);
    float2 n = skyNearest(sl);
    if (n.x <= 0.0f) return 0.0f;
    float patches = tFbm(p / 150.0f + float2(6.6f, 3.3f), 3);
    float f = tSmooth(0.02f, 0.14f, patches) * tSmooth(0.06f, 0.14f, n.x);
    if (int(n.y) == 0) {
        f *= tSmooth(60.0f, 95.0f, abs(sl.y)) * tSmooth(105.0f, 135.0f, length(sl - SKY_CITADEL))
           * tSmooth(34.0f, 46.0f, length(sl - SKY_POOL));
    }
    return f;
}

// MARK: - 汇总

static inline float terrainHeight(int scene, float2 p) {
    switch (scene) {
    case SCENE_GRASSLAND: return grasslandHeight(p);
    case SCENE_ALPINE: return alpineHeight(p);
    case SCENE_SNOW: return snowHeight(p);
    case SCENE_ISLAND: return islandHeight(p);
    case SCENE_VOLCANO: return volcanoHeight(p);
    case SCENE_SKY: return skyHeight(p);
    default: return 0.0f;
    }
}

/// 会出事的地面（和 Swift 的 TerrainField.hazard 一致）：0 没事，否则是 MAT_WATER / MAT_FOREST / MAT_LAVA / MAT_CREVASSE
static inline int terrainHazard(int scene, float2 p, float h) {
    switch (scene) {
    case SCENE_GRASSLAND:
        if (riverDistance(p) < RIVER_HALF_WIDTH || length(p - POND_CENTER) < POND_RADIUS) return MAT_WATER;
        if (grasslandForest(p) > 0.5f) return MAT_FOREST;
        return 0;
    case SCENE_ALPINE:
        if (alpineStreamDistance(valleyCoords(p)) < 5.0f) return MAT_WATER;
        if (alpineForest(p, h) > 0.5f) return MAT_FOREST;
        return 0;
    case SCENE_ISLAND:
        if (h < 0.3f) return MAT_WATER;
        if (islandForest(p) > 0.5f) return MAT_FOREST;
        return 0;
    case SCENE_VOLCANO:
        if (h < 0.5f) return MAT_WATER;
        if (volcanoLava(p)) return MAT_LAVA;
        return 0;
    case SCENE_SKY: {
        float2 sl = valleyCoords(p);
        float2 n = skyNearest(sl);
        if (n.x <= 0.0f) return MAT_VOID;
        if (int(n.y) == 0 && length(sl - SKY_POOL) < SKY_POOL_RADIUS) return MAT_WATER;
        if (skyForest(p) > 0.5f) return MAT_FOREST;
        return 0;
    }
    default:
        return 0;
    }
}
