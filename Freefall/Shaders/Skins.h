#pragma once
#include "Common.h"

// 皮肤（Shared/Skins.swift）：七关各一顶伞、一套手套和袖子，落进那一关的降落点 / 黄色靶心解锁。
// 颜色在 Swift 的一张小表里（SkinUniforms），图案的形状在这里按伞布 / 袖子的 uv 现算——不另做贴图。
// 图案的边按一个像素在 uv 上有多宽做抗锯齿（伞衣的色块边原来落在三角形的边上，是硬边）。
// 每个片元只多十几到几十条算术（没有采样），只用在伞衣、袖子、手套和伞的剪影贴图上，地形和云不碰。

#define SKIN_STRIPES 0     // 默认：海军蓝翼尖，橙白相间的气室
#define SKIN_ATOLL 1       // 环礁：从中间往外一圈圈白沙、潟湖、礁、碎浪、外海
#define SKIN_FARM 2        // 草原：拼布一样的农田，树篱隔开，有的田里一垄垄作物
#define SKIN_ALPINE 3      // 高山：天、雪峰、岩石、一排排尖尖的云杉
#define SKIN_SNOW 4        // 雪山：白底上冰蓝的人字纹，翼尖冰川蓝
#define SKIN_ISLAND 5      // 海岛：中间一片棕榈叶，两边扶桑花红、礁坪绿、白沙
#define SKIN_VOLCANO 6     // 火山：黑底，从前缘烧过来的三层火苗，翼尖火山灰
#define SKIN_SKY 7         // 天空之城：铜绿的天、奶白石墙的城垛、一排柱廊、金线

struct SkinUniforms {
    float4 canopy[6];      // 伞衣的调色板（rgb 反照率），各图案按自己的顺序用
    float4 glove[3];       // 手套：[0] rgb 布面的颜色 ÷ 原贴图布面的亮度；[1] 橡胶护甲（指节、手背）；[2] rgb 点缀，a 点缀的自发光
    float4 sleeve[3];      // 袖子：[0] 底色，[1] 手背那一侧一道条纹，[2] 袖口一圈（a = 1 才画）
    float4 slider;         // rgb 滑块（伞绳上那块方布）的颜色
    float4 sleeveShape;    // x 条纹边的形状（0 直 1 波浪 2 锯齿 3 城垛 4 火苗 5 扇贝），y 起伏（圈的比例），z 周期（米），w 条纹半宽（圈的比例）
    int4 kind;             // x 伞的图案（SKIN_*），y 换了手套的颜色（0 = 默认，贴图原样用）
};

/// x 越过 edge 的程度（0…1），过渡宽一个像素（w = 一个像素里 x 变多少）
static inline float skinStep(float edge, float x, float w) { return saturate((x - edge) / max(w, 1e-5f) + 0.5f); }
/// 三角波：整数处 1，半整数处 0
static inline float skinTri(float x) { return abs(fract(x) * 2.0f - 1.0f); }
/// x 落在周期 P 里 [a, b] 这一段的程度（米，0 < a < b < P），边上一个像素的过渡
static inline float skinBand(float x, float P, float a, float b, float w) {
    float t = fract(x / P) * P;
    return saturate(min(t - a, b - t) / max(w, 1e-5f) + 0.5f);
}
static inline float skinHash(float2 p) { return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f); }

/// 伞布的颜色。uv：展向（0 左翼尖 … 8.4 右翼尖）、弦向（0 前缘 … 3 后缘），米；fw：一个像素里 u、v 各变多少。
/// 有上下的图案（山、火苗、城墙）按「后缘是上」画：玩家几乎总是在伞下仰头看，前缘在视野的下方
static inline float3 canopySkinAlbedo(float2 uv, float2 fw, constant SkinUniforms &S) {
    const float span = 8.4f, cw = 8.4f / 9.0f;
    float u = uv.x, v = uv.y;
    float up = 3.0f - v;                             // 离后缘多远：这些图案的「高度」越小越靠上
    float xc = abs(u - span * 0.5f);                 // 离中线多远：图案左右对称，从下面看、从上面看都一样
    float3 C0 = S.canopy[0].rgb, C1 = S.canopy[1].rgb, C2 = S.canopy[2].rgb;
    float3 C3 = S.canopy[3].rgb, C4 = S.canopy[4].rgb, C5 = S.canopy[5].rgb;
    switch (S.kind.x) {
    case SKIN_ATOLL: {
        // 一圈圈的边按弦向起伏（像沙洲和礁的边），越往外越接近一格一格的气室
        float f = xc + 0.09f * sin(v * 6.5f + xc * 2.2f);
        float w = fw.x * 1.2f + fw.y * 0.6f;
        float3 c = mix(C0, C1, skinStep(0.55f, f, w));
        c = mix(c, C2, skinStep(1.55f, f, w));
        c = mix(c, C3, skinStep(2.42f, f, w));
        c = mix(c, C4, skinStep(2.58f, f, w));
        return mix(c, C5, skinStep(3.45f, f, w));
    }
    case SKIN_FARM: {
        // 一块田 = 一个气室 × 弦向 0.6 米（和拼缝对齐），颜色按田的编号挑；田边一道深绿的树篱
        float2 cell = float2(floor(u / cw), floor(v / 0.6f));
        float h = skinHash(cell + 3.0f);
        float3 c = h < 0.24f ? C0 : h < 0.46f ? C1 : h < 0.68f ? C2 : h < 0.84f ? C3 : C4;
        // 一半的田里一垄垄作物（顺着展向或弦向，0.16 米一垄），远了淡掉
        float h2 = skinHash(cell + 17.0f);
        if (h2 < 0.5f) {
            float along = h2 < 0.25f ? u : v, fa = h2 < 0.25f ? fw.x : fw.y;
            float fade = saturate(0.16f / (fa * 6.0f) - 0.4f);
            c *= 1.0f - 0.16f * fade * skinBand(along, 0.16f, 0.02f, 0.07f, fa);
        }
        float du = abs(fract(u / cw + 0.5f) - 0.5f) * cw, dv = abs(fract(v / 0.6f + 0.5f) - 0.5f) * 0.6f;
        float hedge = max(1.0f - skinStep(0.03f, du, fw.x), 1.0f - skinStep(0.03f, dv, fw.y));
        return mix(c, C5, hedge);
    }
    case SKIN_ALPINE: {
        // 山脊：两个周期的三角波叠起来（大峰 + 小峰），峰尖朝后缘（仰头看是正的）；雪线跟着山脊往下退一截；
        // 林线是一排小三角（云杉的树梢）
        float p1 = 1.0f - skinTri(u / 2.1f + 0.25f), p2 = 1.0f - skinTri(u / 0.7f + 0.1f);
        float ridge = 0.62f + 0.55f * (1.0f - p1) + 0.18f * (1.0f - p2);
        float wr = fw.y + fw.x * 1.1f;
        float trees = 1.95f - 0.24f * (1.0f - skinTri(u / 0.21f));
        float wt = fw.y + fw.x * 2.3f;
        float3 c = mix(C0, C1, skinStep(ridge, up, wr));                    // 天 → 雪
        c = mix(c, C2, skinStep(ridge + 0.34f + 0.1f * p2, up, wr));        // 雪 → 岩石
        c = mix(c, C3, skinStep(trees, up, wt));                             // 岩石 → 林子
        return mix(c, C4, skinStep(trees + 0.55f, up, wt));                  // 林子深处
    }
    case SKIN_SNOW: {
        // 人字纹：尖朝前缘，0.8 米一组（白、冰蓝、深一点的蓝），翼尖两格冰川蓝
        float s = v + 0.6f * xc;
        float w = fw.y + fw.x * 0.6f;
        float3 c = mix(C0, C1, skinBand(s, 0.8f, 0.44f, 0.66f, w));
        c = mix(c, C2, skinBand(s, 0.8f, 0.66f, 0.72f, w));
        return mix(c, C3, skinStep(3.5f * cw, xc, fw.x));
    }
    case SKIN_ISLAND: {
        // 中间三格：一片棕榈叶（叶脉一道白沙色，小叶斜着往后长，叶缘锯齿跟着小叶走）
        float s = v - 0.9f * xc;
        float leaflet = skinBand(s, 0.24f, 0.03f, 0.18f, fw.y + fw.x * 0.9f);
        float3 frond = mix(C0, C1, leaflet);
        frond = mix(C4, frond, skinStep(0.025f, xc, fw.x));
        float edge = 1.5f * cw - 0.12f + 0.12f * skinTri(s / 0.24f);
        float3 c = mix(frond, C2, skinStep(edge, xc, fw.x * 1.5f + fw.y));
        c = mix(c, C3, skinStep(2.5f * cw, xc, fw.x));
        return mix(c, C4, skinStep(3.5f * cw, xc, fw.x));
    }
    case SKIN_VOLCANO: {
        // 火苗：从前缘往后缘烧的一排火舌（仰头看是往上烧），每条 0.7 米宽、高矮不一，舌尖是尖的；里面一层套一层（红、橙、黄）
        float k = floor(u / 0.7f), x = fract(u / 0.7f);
        float tall = 0.9f + 0.8f * skinHash(float2(k, 5.0f));
        float tongue = tall * pow(1.0f - abs(2.0f * x - 1.0f), 1.4f);
        float f = v - (0.7f + tongue);                                       // < 0 在火里
        float w = fw.y + fw.x * 4.0f * tall;
        float3 c = mix(C0, C1, 1.0f - skinStep(0.0f, f, w));
        c = mix(c, C2, 1.0f - skinStep(-0.2f, f, w));
        c = mix(c, C3, 1.0f - skinStep(-0.45f, f, w));
        // 翼尖：火山灰的灰（火苗烧过来的地方照样是火）
        return mix(c, C4, skinStep(3.5f * cw, xc, fw.x) * skinStep(0.0f, f, w));
    }
    case SKIN_SKY: {
        // 后缘（仰头看是上面）一片铜绿（穹顶的颜色）；城墙顶上的城垛（方齿）往上伸；一道金线；
        // 城墙上一排柱子（奶白的柱、深一点的柱间）；再一道金线，前缘一截石板灰的台基。翼尖整格铜绿
        float merlon = skinBand(u, 0.42f, 0.05f, 0.26f, fw.x);
        float wall = max(skinStep(0.86f, up, fw.y), min(skinStep(0.66f, up, fw.y), merlon));
        float3 c = mix(C1, C0, wall);
        float columns = 1.0f - skinBand(u, cw / 3.0f, 0.2f, 0.29f, fw.x);
        float3 colonnade = mix(C3, C0, columns);
        c = mix(c, colonnade, skinStep(1.12f, up, fw.y) * (1.0f - skinStep(2.3f, up, fw.y)));
        float gold = max(skinStep(1.0f, up, fw.y) * (1.0f - skinStep(1.08f, up, fw.y)),
                         skinStep(2.34f, up, fw.y) * (1.0f - skinStep(2.44f, up, fw.y)));
        c = mix(c, C2, gold);
        c = mix(c, C4, skinStep(2.44f, up, fw.y));
        return mix(c, C1, skinStep(3.5f * cw, xc, fw.x));
    }
    default: {
        // 默认的气室条纹：翼尖海军蓝，中间橙白相间（中间那格是橙）
        float3 c = mix(C0, C1, skinStep(0.5f * cw, xc, fw.x));
        c = mix(c, C2, skinStep(1.5f * cw, xc, fw.x));
        c = mix(c, C3, skinStep(2.5f * cw, xc, fw.x));
        return mix(c, C4, skinStep(3.5f * cw, xc, fw.x));
    }
    }
}

/// 袖子的颜色。uv：x 从手腕往手肘（米，0.034 … 0.27），y 绕袖子一圈（0…1，0.25 是手背那一侧）；fw 同上
static inline float3 sleeveSkinAlbedo(float2 uv, float2 fw, constant SkinUniforms &S) {
    float3 c = S.sleeve[0].rgb;
    float halfWidth = S.sleeveShape.w;
    if (halfWidth > 0.0f) {
        // 手背那一侧一道条纹，边按形状起伏（和这一关的伞是一个意思：波浪、锯齿、城垛、火苗……）
        float a = abs(fract(uv.y - 0.25f + 0.5f) - 0.5f);            // 离手背中线多远（圈的比例）
        float P = S.sleeveShape.z, x = uv.x / P;
        int shape = int(S.sleeveShape.x + 0.5f);
        float e, slope;
        if (shape == 1) { e = 0.5f + 0.5f * sin(x * 2.0f * PI); slope = PI; }
        else if (shape == 2) { e = skinTri(x); slope = 2.0f; }
        else if (shape == 3) { e = skinBand(uv.x, P, 0.08f * P, 0.5f * P, fw.x); slope = 0.0f; }
        else if (shape == 4) { e = pow(1.0f - skinTri(x), 1.6f); slope = 3.2f; }
        else if (shape == 5) { e = abs(sin(x * PI)); slope = PI; }
        else { e = 0.0f; slope = 0.0f; }
        float edge = halfWidth + S.sleeveShape.y * (e - 0.5f);
        float w = fw.y + fw.x * slope * S.sleeveShape.y / P;
        c = mix(c, S.sleeve[1].rgb, 1.0f - skinStep(edge, a, w));
    }
    // 袖口一圈（松紧带那一截）
    if (S.sleeve[2].a > 0.5f) c = mix(S.sleeve[2].rgb, c, skinStep(0.056f, uv.x, fw.x));
    return c;
}

/// 手套：原贴图 = 布面亮度 L × 炭灰 (0.075, 0.075, 0.085) + 点缀程度 m × 橙 (0.62, 0.17, 0.018)
/// （tools/gloves/convert_gloves.py 就是这么配的色，线性空间里的线性组合，mip 过滤以后也成立），
/// 用红、蓝两个通道解出 L 和 m。原来的白布 L ≈ 0.62，指节、手背那些黑色橡胶护甲 L ≈ 0：
/// 按 L 在布面和护甲两种颜色之间插，再加上点缀。返回 rgb 反照率、a 点缀的自发光（辐亮度）
static inline float4 gloveSkinAlbedo(float3 a, constant SkinUniforms &S) {
    if (S.kind.y == 0) return float4(a, 0.0f);
    const float det = 0.075f * 0.018f - 0.62f * 0.085f;
    float L = max((a.r * 0.018f - 0.62f * a.b) / det, 0.0f);
    float m = saturate((0.075f * a.b - 0.085f * a.r) / det);
    float fabric = saturate(L / 0.62f), rubber = saturate(1.0f - m - fabric);
    return float4(L * S.glove[0].rgb + rubber * S.glove[1].rgb + m * S.glove[2].rgb, m * S.glove[2].a);
}
