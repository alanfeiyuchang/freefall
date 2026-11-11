import Foundation
import simd

/// 地形场景的高度和地面类型：Shaders/TerrainField.h 的逐行照抄（CPU 用来判断落地、撞山、掉进河里 / 树林 / 岩浆 / 冰裂缝）。
/// **改那边必须同步改这里**。GPU 那边的超越函数都用 precise:: 版本，两边算出来只差浮点舍入
/// （tools/render-check 的 terrain 模式会比对）。
enum TerrainField {
    static let target = SIMD2<Float>(380, -620)
    static let valleyDir = SIMD2<Float>(0.59028, -0.80720)
    static let valleySide = SIMD2<Float>(0.80720, 0.59028)

    enum Material: Int {
        case rock = 0, grass, forest, snow, ice, water, lava, ash, scree, field, moraine, crevasse, sand, void, paved
    }

    static let coneCenter = SIMD2<Float>(-500, -950)
    static let coneBaseRadius: Float = 520
    static let coneTop: Float = 900
    static let craterRadius: Float = 150
    static let lavaLake: Float = 780
    static let plumeDrift = SIMD2<Float>(-0.55, 0.22)

    // MARK: - 噪声

    @inline(__always)
    static func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = (UInt32(bitPattern: x) &* 0x8DA6_B343) ^ (UInt32(bitPattern: y) &* 0xD816_3841)
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        h = h &* 0x297A_2D39
        h ^= h >> 15
        return Float(h) * (2.0 / 4_294_967_296.0) - 1.0
    }

    @inline(__always)
    static func noised(_ p: SIMD2<Float>) -> SIMD3<Float> {
        let i = SIMD2<Float>(p.x.rounded(.down), p.y.rounded(.down))
        let f = p - i
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        let du = 30 * f * f * (f * (f - 2) + 1)
        let cx = Int32(i.x), cy = Int32(i.y)
        let a = hash(cx, cy), b = hash(cx &+ 1, cy), d = hash(cx, cy &+ 1), e = hash(cx &+ 1, cy &+ 1)
        let k1 = b - a, k2 = d - a, k4 = a - b - d + e
        return SIMD3(a + k1 * u.x + k2 * u.y + k4 * u.x * u.y, du.x * (k1 + k4 * u.y), du.y * (k2 + k4 * u.x))
    }

    @inline(__always)
    static func noise(_ p: SIMD2<Float>) -> Float { noised(p).x }

    @inline(__always)
    static func octave(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(1.6 * p.x - 1.2 * p.y, 1.2 * p.x + 1.6 * p.y)
    }

    static func fbm(_ p0: SIMD2<Float>, _ octaves: Int) -> Float {
        var a: Float = 0, b: Float = 0.5, p = p0
        for _ in 0..<octaves {
            a += b * noise(p)
            b *= 0.5
            p = octave(p) + SIMD2(3.1, 1.7)
        }
        return a
    }

    static func eroded(_ p0: SIMD2<Float>, _ octaves: Int) -> Float {
        var a: Float = 0, b: Float = 1, p = p0
        var d = SIMD2<Float>(0, 0)
        for _ in 0..<octaves {
            let n = noised(p)
            d += SIMD2(n.y, n.z)
            a += b * n.x / (1 + simd_dot(d, d))
            b *= 0.5
            p = octave(p)
        }
        return a
    }

    static func ridged(_ p0: SIMD2<Float>, _ octaves: Int) -> Float {
        var a: Float = 0, b: Float = 0.5, w: Float = 1, p = p0
        for _ in 0..<octaves {
            var n = 1 - abs(noise(p))
            n = n * n * w
            w = min(max(n * 1.8, 0), 1)
            a += n * b
            b *= 0.5
            p = octave(p) + SIMD2(1.3, -2.9)
        }
        return a
    }

    @inline(__always)
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    @inline(__always)
    static func saturate(_ x: Float) -> Float { min(max(x, 0), 1) }

    static func valleyCoords(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let d = p - target
        return SIMD2(simd_dot(d, valleyDir), simd_dot(d, valleySide))
    }

    // MARK: - 草原

    static let riverHalfWidth: Float = 14
    static let pondCenter = SIMD2<Float>(650, -800)
    static let pondRadius: Float = 55

    static func riverDistance(_ p: SIMD2<Float>) -> Float {
        let x = p.x
        let z = -390 + 110 * sin(x / 310 + 0.4) + 45 * sin(x / 120 + 2.1)
        let slope = 110 / 310 * cos(x / 310 + 0.4) + 45 / 120 * cos(x / 120 + 2.1)
        return abs(p.y - z) / (1 + slope * slope).squareRoot()
    }

    static func grasslandHeight(_ p: SIMD2<Float>) -> Float {
        let r = simd_length(p - target)
        let river = riverDistance(p)
        let pond = simd_length(p - pondCenter)
        let hills = 55 * fbm(p / 3200 + SIMD2(5.2, 1.3), 4) + 7 * fbm(p / 420 + SIMD2(1.1, 8.3), 3)
        let flat = smooth(60, 420, river) * smooth(140, 650, r) * smooth(80, 300, pond)
        var h = 240 + hills * flat + 0.6 * fbm(p / 55, 3)
        let water: Float = 237.5
        h = mix(water, h, smooth(riverHalfWidth, riverHalfWidth + 14, river))
        h = mix(water, h, smooth(pondRadius, pondRadius + 16, pond))
        return h
    }

    static func grasslandForest(_ p: SIMD2<Float>) -> Float {
        let r = simd_length(p - target)
        let river = riverDistance(p)
        let patches = fbm(p / 650 + SIMD2(7.7, 2.2), 4)
        let riparian = smooth(70, 35, river) * smooth(riverHalfWidth + 4, riverHalfWidth + 12, river)
            * smooth(-0.25, 0.05, fbm(p / 120 + SIMD2(3.3, 9.9), 3))
        let f = max(smooth(0.1, 0.2, patches), riparian)
        return f * smooth(200, 260, r)
    }

    // MARK: - 高山

    static func alpineFloor(_ s: Float) -> Float { 1150 + 0.035 * max(-s, 0) - 0.02 * max(s, 0) }

    static func alpineStreamDistance(_ sl: SIMD2<Float>) -> Float {
        let off = abs(sl.y + 175)
        if off > 130 { return off - 85 }
        let center = -175 + 60 * sin(sl.x / 240) + 25 * sin(sl.x / 90 + 1.3)
        let pool = 0.5 + 0.5 * sin(sl.x / 21 + 3.2 * sin(sl.x / 97) + 1.7 * sin(sl.x / 41))
        return abs(sl.y - center) + 3.0 * pool - 1.8
    }

    static func alpineHeight(_ p: SIMD2<Float>) -> Float {
        let sl = valleyCoords(p)
        let s = sl.x, l = sl.y
        let floorH = alpineFloor(s)
        let halfWidth = 430 + 150 * fbm(SIMD2(s / 1800, 9.1), 3)
        let lp = max(abs(l) - halfWidth, 0)
        let wall = 2600 * (1 - exp(-pow(lp / 1150, 1.7)))
        let steep = smooth(0, 500, lp)
        let mountains = eroded(p / 2400 + SIMD2(3.7, 1.3), 10)
        var h = floorH + wall + mountains * mix(14, 950, steep) + 0.5 * fbm(p / 40, 3)
        let r = simd_length(p - target)
        h = mix(1150 + 0.4 * fbm(p / 40, 3), h, smooth(80, 240, r))
        let stream = alpineStreamDistance(sl)
        let water = floorH - 3
        h = mix(min(water, h), h, smooth(5, 22, stream))
        return h
    }

    static func alpineForest(_ p: SIMD2<Float>, _ h: Float) -> Float {
        let sl = valleyCoords(p)
        let r = simd_length(p - target)
        let lp = max(abs(sl.y) - 380, 0)
        let patches = fbm(p / 500 + SIMD2(4.4, 6.1), 4)
        let treeline = alpineFloor(sl.x) + 560 + 180 * noise(p / 700 + SIMD2(2, 2))
        let belowTreeline = smooth(treeline + 60, treeline - 60, h)
        let onSlope = smooth(0, 150, lp) + smooth(0.15, 0.3, patches)
        return saturate(onSlope) * belowTreeline * smooth(-0.05, 0.08, patches) * smooth(230, 300, r)
            * smooth(18, 30, alpineStreamDistance(sl))
    }

    // MARK: - 雪山

    static func snowHeight(_ p: SIMD2<Float>) -> Float {
        let sl = valleyCoords(p)
        let s = sl.x, l = sl.y
        let floorH = 2750 + 0.06 * max(-s, 0) - 0.04 * max(s, 0)
        let halfWidth = 650 + 200 * fbm(SIMD2(s / 2000, 2.7), 3)
        let lp = max(abs(l) - halfWidth, 0)
        let wall = 2300 * (1 - exp(-pow(lp / 1000, 1.6)))
        let steep = smooth(0, 400, lp)
        let ridges = ridged(p / 3000 + SIMD2(8.1, 0.4), 8)
        var h = floorH + wall + (ridges - 0.35) * mix(30, 1300, steep) + 4 * fbm(p / 260, 3) * (1 - steep)
        let r = simd_length(p - target)
        h = mix(2750 + 0.6 * fbm(p / 60, 3), h, smooth(90, 300, r))
        return h
    }

    // MARK: - 海岛：四面环海的热带小岛。开伞点在海上，靶在岛西岸沙滩后面的草地上；
    // 岸边一圈浅浅的珊瑚礁坪，礁外一下子掉进深海；往岛里是两座长满雨林的山

    /// 岛的中心和半轴（山谷坐标：沿 valleyDir、沿 valleySide，米）
    static let islandCenter = SIMD2<Float>(1250, 150)
    static let islandAxes = SIMD2<Float>(1330, 1050)

    /// 离海岸多远（按岛的半轴归一化）：> 0 在岛上，< 0 在海里。海岸弯弯曲曲（海湾、岬角），靶前面那一段规整一点
    static func islandLand(_ p: SIMD2<Float>) -> Float {
        let q = (valleyCoords(p) - islandCenter) / islandAxes
        let r = simd_length(p - target)
        return 1 - simd_length(q) + 0.07 * fbm(p / 700 + SIMD2(3.1, 7.7), 4) * smooth(250, 700, r)
    }

    static func islandHeight(_ p: SIMD2<Float>) -> Float {
        let land = islandLand(p)
        // 海里：岸边水深一两米的礁坪，礁外掉到四十多米深
        let sea = -0.6 - 1.2 * smooth(-0.005, -0.06, land) - 42 * smooth(-0.11, -0.2, land) + 0.6 * fbm(p / 60, 3)
        // 岸上：沙滩、平地，再往里两座山（四五百米）
        let hills = 470 * pow(smooth(0.1, 0.75, land), 1.3) * (0.75 + 0.45 * eroded(p / 1300 + SIMD2(5.5, 2.5), 7))
        let ground = 2.6 * smooth(-0.01, 0.03, land) + 1.5 * smooth(0.03, 0.12, land) + hills + 0.5 * fbm(p / 45, 3)
        var h = mix(sea, ground, smooth(-0.012, 0.004, land))
        // 着陆区：靶周围一片平的草地（只在岸上压平，不往海里填）
        let r = simd_length(p - target)
        h = mix(h, 3.5 + 0.25 * fbm(p / 40, 3), (1 - smooth(70, 190, r)) * smooth(0, 0.02, land))
        return h
    }

    /// 雨林（> 0.5 算树林）：沙滩后面一条之外全是；靶周围两百米是一片空地
    static func islandForest(_ p: SIMD2<Float>) -> Float {
        let land = islandLand(p)
        let patches = fbm(p / 380 + SIMD2(8.8, 1.4), 4)
        return smooth(0.05, 0.09, land + 0.04 * patches) * smooth(180, 240, simd_length(p - target))
    }

    static func fract(_ x: Float) -> Float { x - x.rounded(.down) }

    // MARK: - 火山

    static func lavaFlowDistance(_ p: SIMD2<Float>) -> Float {
        let a0 = coneCenter, a1 = SIMD2<Float>(-150, -1080), a2 = SIMD2<Float>(250, -1180), a3 = SIMD2<Float>(700, -1430)
        let b1 = SIMD2<Float>(-880, -720), b2 = SIMD2<Float>(-1250, -330)
        let segments = [(a0, a1), (a1, a2), (a2, a3), (a0, b1), (b1, b2)]
        var d: Float = 1e9
        for (from, to) in segments {
            let pa = p - from, ba = to - from
            let t = saturate(simd_dot(pa, ba) / simd_dot(ba, ba))
            d = min(d, simd_length(pa - ba * t))
        }
        return d + 5 * noise(p / 60) + 4 * noise(p / 210)
    }

    static func volcanoHeight(_ p: SIMD2<Float>) -> Float {
        let kc = SIMD2<Float>(150, -350)
        let rk = simd_length(p - kc)
        let rimNoise = 120 * fbm(p / 900 + SIMD2(2.2, 7.1), 4)
        let inner = 620 + 4 * fbm(p / 300, 3) + 1.2 * fbm(p / 45, 3)
        let rimH = 980 + rimNoise
        let outer = rimH * pow(saturate(1 - (rk - 2500) / 7000), 1.6) - 30
        var h = rk < 2300 ? mix(inner, rimH, smooth(1950, 2300, rk)) : mix(rimH, outer, smooth(2300, 2700, rk))
        h += 160 * eroded(p / 1800, 7) * smooth(2000, 2600, rk)
        let rc = simd_length(p - coneCenter)
        let cone = (coneTop - 620) * pow(saturate(1 - rc / coneBaseRadius), 1.5)
        let crater = smooth(craterRadius + 40, craterRadius - 30, rc)
        var coneH = 620 + cone + 18 * fbm(p / 120, 3) * smooth(coneBaseRadius, 200, rc)
        coneH = mix(coneH, lavaLake, crater)
        h = max(h, coneH)
        let flow = lavaFlowDistance(p)
        h += 3 * smooth(40, 12, flow) * (2200 >= rk ? 1 : 0)
        let r = simd_length(p - target)
        h = mix(620 + 0.3 * fbm(p / 40, 3), h, smooth(80, 200, r))
        return h
    }

    static func volcanoLava(_ p: SIMD2<Float>) -> Bool {
        lavaFlowDistance(p) < 14 || simd_length(p - coneCenter) < craterRadius - 20
    }

    static func plumeDensity(_ p: SIMD2<Float>, altitude: Float) -> Float {
        let above = altitude - (coneTop - 40)
        if above < 0 || above > 3200 { return 0 }
        let axis = coneCenter + plumeDrift * above
        let radius = 90 + 0.22 * above
        let d = simd_length(p - axis) / radius
        return saturate(1 - d * d) * smooth(3200, 1800, above)
    }

    // MARK: - 天空之城（TerrainField.h 的 sky* 逐行对应）

    static let skyAlt: Float = 3293
    static let skyVoid: Float = 2880
    static let skyCitadel = SIMD2<Float>(215, 0)
    static let skyPool = SIMD2<Float>(120, -150)
    static let skyPoolRadius: Float = 24

    /// 每座岛：xy 中心（谷坐标），zw 两个半轴（米）。0 是着陆的主岛
    static let skyIslandShape: [SIMD4<Float>] = [
        SIMD4(60, 0, 330, 235), SIMD4(-520, -290, 150, 110), SIMD4(-440, 350, 125, 95), SIMD4(590, -340, 190, 140),
        SIMD4(640, 300, 150, 115), SIMD4(70, -540, 115, 85), SIMD4(130, 500, 105, 85), SIMD4(-960, 80, 230, 170),
        SIMD4(1180, -20, 280, 210), SIMD4(-270, -200, 34, 27), SIMD4(-190, 290, 30, 24), SIMD4(330, -380, 36, 28),
        SIMD4(440, 360, 32, 26), SIMD4(-700, 470, 48, 36), SIMD4(900, -600, 70, 52), SIMD4(-40, 820, 80, 60),
    ]
    /// x 岛面比主岛高多少（米），y 噪声的种子
    static let skyIslandInfo: [SIMD2<Float>] = [
        SIMD2(0, 1.3), SIMD2(45, 4.1), SIMD2(-60, 7.7), SIMD2(120, 2.9), SIMD2(-90, 9.3), SIMD2(70, 5.5),
        SIMD2(-40, 6.2), SIMD2(180, 8.4), SIMD2(60, 3.6), SIMD2(-25, 11.0), SIMD2(30, 12.5), SIMD2(-50, 13.2),
        SIMD2(15, 14.9), SIMD2(100, 15.4), SIMD2(-140, 16.8), SIMD2(150, 17.1),
    ]

    static func skyMask(_ sl: SIMD2<Float>, _ i: Int) -> Float {
        let s = skyIslandShape[i]
        let e = 1 - simd_length((sl - SIMD2(s.x, s.y)) / SIMD2(s.z, s.w))
        if e < -0.4 { return e }
        return e + 0.2 * fbm(sl / (0.6 * min(s.z, s.w)) + SIMD2(repeating: skyIslandInfo[i].y), 3)
    }

    /// 最近的岛：它的 mask 和编号
    static func skyNearest(_ sl: SIMD2<Float>) -> (mask: Float, index: Int) {
        var best: Float = -1e9
        var index = 0
        for i in 0..<skyIslandShape.count {
            let m = skyMask(sl, i)
            if m > best { best = m; index = i }
        }
        return (best, index)
    }

    static func skyTop(_ p: SIMD2<Float>, _ sl: SIMD2<Float>, _ i: Int, _ m: Float) -> Float {
        let info = skyIslandInfo[i]
        let mm = max(m, 0)
        var h = skyAlt + info.x + 7 * smooth(0, 0.5, mm) - 4 * (1 - smooth(0, 0.07, mm))
            + 2.5 * fbm(p / 90 + SIMD2(repeating: info.y), 3) + 0.4 * fbm(p / 14, 2)
        if i == 0 {
            let flatH = skyAlt + 7
            h = mix(flatH + 0.15 * fbm(p / 30, 2), h, smooth(45, 110, simd_length(sl)))
            let rc = simd_length(sl - skyCitadel)
            h = mix(flatH, h, smooth(84, 110, rc))
            h += 4 * (smooth(79, 77.5, rc) + smooth(65, 63.5, rc) + smooth(51, 49.5, rc))
            h -= 2.2 * smooth(31, 23, simd_length(sl - skyPool))
        }
        return h
    }

    static func skyHeight(_ p: SIMD2<Float>) -> Float {
        let sl = valleyCoords(p)
        let n = skyNearest(sl)
        return n.mask > 0 ? skyTop(p, sl, n.index, n.mask) : skyVoid
    }

    static func skyForest(_ p: SIMD2<Float>) -> Float {
        let sl = valleyCoords(p)
        let n = skyNearest(sl)
        if n.mask <= 0 { return 0 }
        let patches = fbm(p / 150 + SIMD2(6.6, 3.3), 3)
        var f = smooth(0.02, 0.14, patches) * smooth(0.06, 0.14, n.mask)
        if n.index == 0 {
            f *= smooth(60, 95, abs(sl.y)) * smooth(105, 135, simd_length(sl - skyCitadel))
                * smooth(34, 46, simd_length(sl - skyPool))
        }
        return f
    }

    /// 谷坐标 → 地面坐标（摆建筑用）
    static func skyGround(_ sl: SIMD2<Float>) -> SIMD2<Float> { target + valleyDir * sl.x + valleySide * sl.y }

    // MARK: - 汇总

    static func height(_ scene: JumpScene, _ p: SIMD2<Float>) -> Float {
        switch scene {
        case .grassland: return grasslandHeight(p)
        case .alpine: return alpineHeight(p)
        case .snow: return snowHeight(p)
        case .island: return islandHeight(p)
        case .volcano: return volcanoHeight(p)
        case .sky: return skyHeight(p)
        case .atoll: return 0
        }
    }

    /// 会出事的地面（和 TerrainField.h 的 terrainHazard 一致）
    static func hazard(_ scene: JumpScene, _ p: SIMD2<Float>, _ h: Float) -> Material? {
        switch scene {
        case .grassland:
            if riverDistance(p) < riverHalfWidth || simd_length(p - pondCenter) < pondRadius { return .water }
            if grasslandForest(p) > 0.5 { return .forest }
            return nil
        case .alpine:
            if alpineStreamDistance(valleyCoords(p)) < 5 { return .water }
            if alpineForest(p, h) > 0.5 { return .forest }
            return nil
        case .island:
            if h < 0.3 { return .water }
            if islandForest(p) > 0.5 { return .forest }
            return nil
        case .volcano:
            if h < 0.5 { return .water }
            if volcanoLava(p) { return .lava }
            return nil
        case .sky:
            let sl = valleyCoords(p)
            let n = skyNearest(sl)
            if n.mask <= 0 { return .void }
            if n.index == 0, simd_length(sl - skyPool) < skyPoolRadius { return .water }
            if skyForest(p) > 0.5 { return .forest }
            return nil
        case .snow, .atoll:
            return nil
        }
    }

    /// 坡度（度）：按 1 米的差分
    static func slopeDegrees(_ scene: JumpScene, _ p: SIMD2<Float>) -> Float {
        let h = height(scene, p)
        let hx = height(scene, p + SIMD2(1, 0)), hz = height(scene, p + SIMD2(0, 1))
        let g = SIMD2(hx - h, hz - h)
        return atan(simd_length(g)) * 180 / .pi
    }
}
