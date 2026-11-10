import Foundation
import simd

/// 天空之城的建筑：主岛上的城堡（三层台基上一圈柱廊、鼓座、铜皮穹顶和尖顶）、靶周围一圈残柱、大道两边的方尖碑，
/// 别的岛上的塔、亭子、立着的石环，岛和岛之间的拱桥，还有从岛边跌进云海的瀑布。
/// 都是程序生成的网格，启动时算一次。顶点在地面坐标里（x、海拔、z），着色见 Terrain.h 的 cityFragment / waterfallFragment。
/// 岛的形状来自 TerrainField 的 sky* 函数，建筑按岛面的高度立在上面。
enum SkyCity {
    /// 伞撞上会出事的建筑：圆柱形的包围（地面坐标的圆心、半径、顶的海拔）
    struct Obstacle: Sendable {
        var center: SIMD2<Double>
        var radius: Double
        var top: Double
    }

    struct Layout {
        var buildings: [MeshVertex] = []
        var waterfalls: [MeshVertex] = []
        var obstacles: [Obstacle] = []
    }

    static let layout: Layout = build()

    /// 这一点（地面坐标、脚的海拔）是不是撞进了建筑
    static func hits(_ p: SIMD2<Double>, altitude: Double) -> Bool {
        layout.obstacles.contains { altitude < $0.top && simd_length_squared(p - $0.center) < $0.radius * $0.radius }
    }

    // 材质编号（Terrain.h 的 CITY_*）
    private static let stoneMaterial: Float = 0, copperMaterial: Float = 1, goldMaterial: Float = 2
    private static let darkMaterial: Float = 3, crystalMaterial: Float = 4, foliageMaterial: Float = 5

    private static let stone = SIMD3<Float>(0.36, 0.335, 0.295)
    private static let copper = SIMD3<Float>(0.17, 0.38, 0.31)
    private static let gold = SIMD3<Float>(0.85, 0.60, 0.20)
    private static let dark = SIMD3<Float>(0.03, 0.03, 0.035)
    private static let crystal = SIMD3<Float>(0.10, 0.30, 0.28)

    // MARK: - 基本形状

    private struct Builder {
        var v: [MeshVertex] = []

        mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>, _ color: SIMD3<Float>, _ material: Float) {
            v.append(MeshVertex(position: SIMD4(p, uv.x), normal: SIMD4(n, uv.y), color: SIMD4(color, material)))
        }

        mutating func quad(_ p: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
                           _ n: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
                           _ uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
                           _ c: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ material: Float) {
            vertex(p.0, n.0, uv.0, c.0, material); vertex(p.1, n.1, uv.1, c.1, material); vertex(p.2, n.2, uv.2, c.2, material)
            vertex(p.0, n.0, uv.0, c.0, material); vertex(p.2, n.2, uv.2, c.2, material); vertex(p.3, n.3, uv.3, c.3, material)
        }

        /// 四边形，一个法线、一个颜色
        mutating func flat(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                           _ color: SIMD3<Float>, _ material: Float) {
            var n = simd_cross(b - a, d - a)
            n = simd_length(n) > 1e-9 ? simd_normalize(n) : SIMD3(0, 1, 0)
            let uv = SIMD2<Float>(0, 0)
            quad((a, b, c, d), (n, n, n, n), (uv, uv, uv, uv), (color, color, color, color), material)
        }

        /// 旋转体：竖直的轴，剖面是一串（半径, 高度）。smooth = 沿剖面也平滑（穹顶）；否则每一段一个面（线脚、台阶）。
        /// 离底 ao 米以内压暗一点（墙脚、柱脚：近地面的环境光少）。uv.x 是绕一圈的 0…1
        mutating func lathe(base: SIMD3<Float>, profile: [SIMD2<Float>], color: SIMD3<Float>, material: Float,
                            segments: Int, smooth: Bool = false, ao: Float = 4, twist: Float = 0) {
            let m = profile.count
            guard m >= 2 else { return }
            func segmentNormal(_ j: Int) -> SIMD2<Float> {
                let d = profile[j + 1] - profile[j]
                let l = simd_length(d)
                return l > 1e-6 ? SIMD2(d.y, -d.x) / l : SIMD2(1, 0)
            }
            func pointNormal(_ j: Int) -> SIMD2<Float> {
                let a = segmentNormal(max(j - 1, 0)), b = segmentNormal(min(j, m - 2))
                return simd_normalize(a + b)
            }
            func shade(_ y: Float) -> SIMD3<Float> { color * (0.62 + 0.38 * min(max(y / ao, 0), 1)) }
            for i in 0..<segments {
                let a0 = twist + 2 * Float.pi * Float(i) / Float(segments)
                let a1 = twist + 2 * Float.pi * Float(i + 1) / Float(segments)
                let r0 = SIMD3<Float>(cos(a0), 0, sin(a0)), r1 = SIMD3<Float>(cos(a1), 0, sin(a1))
                let up = SIMD3<Float>(0, 1, 0)
                let u0 = Float(i) / Float(segments), u1 = Float(i + 1) / Float(segments)
                for j in 0..<(m - 1) {
                    let p = profile[j], q = profile[j + 1]
                    let np = smooth ? pointNormal(j) : segmentNormal(j), nq = smooth ? pointNormal(j + 1) : segmentNormal(j)
                    // 少边的棱柱（方尖碑）：绕一圈也不平滑
                    let faceted = segments <= 6
                    let rm = simd_normalize(r0 + r1)
                    let n00 = simd_normalize((faceted ? rm : r0) * np.x + up * np.y)
                    let n10 = simd_normalize((faceted ? rm : r1) * np.x + up * np.y)
                    let n11 = simd_normalize((faceted ? rm : r1) * nq.x + up * nq.y)
                    let n01 = simd_normalize((faceted ? rm : r0) * nq.x + up * nq.y)
                    quad((base + r0 * p.x + up * p.y, base + r1 * p.x + up * p.y, base + r1 * q.x + up * q.y, base + r0 * q.x + up * q.y),
                         (n00, n10, n11, n01), (SIMD2(u0, p.y), SIMD2(u1, p.y), SIMD2(u1, q.y), SIMD2(u0, q.y)),
                         (shade(p.y), shade(p.y), shade(q.y), shade(q.y)), material)
                }
            }
        }

        /// 长方体：中心、三个轴方向上的半尺寸，绕竖轴转 yaw
        mutating func box(center: SIMD3<Float>, half: SIMD3<Float>, yaw: Float = 0, color: SIMD3<Float>, material: Float = 0) {
            let x = SIMD3<Float>(cos(yaw), 0, sin(yaw)) * half.x, z = SIMD3<Float>(-sin(yaw), 0, cos(yaw)) * half.z
            let y = SIMD3<Float>(0, half.y, 0)
            let low = color * 0.7
            func side(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
                var n = simd_cross(b - a, SIMD3(0, 1, 0))
                n = simd_normalize(n)
                let uv = SIMD2<Float>(0, 0)
                quad((center + a - y, center + b - y, center + b + y, center + a + y), (n, n, n, n), (uv, uv, uv, uv),
                     (low, low, color, color), material)
            }
            side(x + z, x - z); side(x - z, -x - z); side(-x - z, -x + z); side(-x + z, x + z)
            flat(center + y - x - z, center + y + x - z, center + y + x + z, center + y - x + z, color, material)
            flat(center - y - x - z, center - y - x + z, center - y + x + z, center - y + x - z, low, material)
        }

        /// 圆环（截面是圆）：环面的轴 axis，半径 radius，管半径 tube
        mutating func torus(center: SIMD3<Float>, axis: SIMD3<Float>, radius: Float, tube: Float, color: SIMD3<Float>,
                            material: Float, segments: Int = 56, sides: Int = 10) {
            let ax = simd_normalize(axis)
            let e1 = simd_normalize(simd_cross(ax, SIMD3<Float>(0, 1, 0)))
            let e2 = simd_cross(ax, e1)
            func point(_ i: Int, _ j: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD2<Float>) {
                let t = 2 * Float.pi * Float(i % segments) / Float(segments)
                let s = 2 * Float.pi * Float(j % sides) / Float(sides)
                let out = e1 * cos(t) + e2 * sin(t)
                let n = out * cos(s) + ax * sin(s)
                return (center + out * radius + n * tube, n, SIMD2(Float(i) / Float(segments), Float(j) / Float(sides)))
            }
            for i in 0..<segments {
                for j in 0..<sides {
                    let a = point(i, j), b = point(i + 1, j), c = point(i + 1, j + 1), d = point(i, j + 1)
                    quad((a.0, b.0, c.0, d.0), (a.1, b.1, c.1, d.1), (a.2, b.2, c.2, d.2), (color, color, color, color), material)
                }
            }
        }
    }

    // MARK: - 摆放

    private static func ground(_ sl: SIMD2<Float>) -> SIMD2<Float> { TerrainField.skyGround(sl) }

    /// 谷坐标的一点 → 立在岛面上的三维点（地面 x、海拔 + lift、地面 z）
    private static func onIsland(_ sl: SIMD2<Float>, lift: Float = 0) -> SIMD3<Float> {
        let g = ground(sl)
        return SIMD3(g.x, TerrainField.skyHeight(g) + lift, g.y)
    }

    /// 从岛里的一点朝 direction 走到岛边（mask 降到 0.03）
    private static func rim(island: Int, from start: SIMD2<Float>, direction: SIMD2<Float>) -> SIMD2<Float> {
        let d = simd_normalize(direction)
        var p = start
        for _ in 0..<600 {
            if TerrainField.skyMask(p + d, island) < 0.03 { break }
            p += d
        }
        return p
    }

    private static func build() -> Layout {
        var b = Builder()
        var layout = Layout()
        let twoPi = 2 * Float.pi

        func obstacle(_ sl: SIMD2<Float>, radius: Float, top: Float) {
            layout.obstacles.append(Obstacle(center: SIMD2<Double>(ground(sl)), radius: Double(radius), top: Double(top)))
        }

        /// 金色的顶饰（一颗球），可以再托一块发光的浮空石
        func finial(_ top: SIMD3<Float>, size: Float, withCrystal: Bool) {
            b.lathe(base: top, profile: [SIMD2(0.02, 0), SIMD2(size * 0.7, size * 0.3), SIMD2(size, size), SIMD2(size * 0.7, size * 1.7),
                                         SIMD2(0.02, size * 2)], color: gold, material: goldMaterial, segments: 10, smooth: true, ao: 0.01)
            if withCrystal {
                b.lathe(base: top + SIMD3(0, size * 2.4, 0), profile: [SIMD2(0.02, 0), SIMD2(size * 1.3, size * 2.2), SIMD2(0.02, size * 5.5)],
                        color: crystal, material: crystalMaterial, segments: 6, ao: 0.01)
            }
        }

        /// 一座塔：收分的塔身、腰线、挑出来的顶层、铜皮的尖顶或穹顶；一圈窄窗
        func tower(_ sl: SIMD2<Float>, height: Float, radius r: Float, dome: Bool, crystal withCrystal: Bool) {
            let base = onIsland(sl, lift: -2.5)
            b.lathe(base: base, profile: [SIMD2(r + 1.3, 0), SIMD2(r + 1.3, 3.0), SIMD2(r, 3.5), SIMD2(r * 0.93, height * 0.55),
                                          SIMD2(r * 0.93 + 0.35, height * 0.55 + 0.3), SIMD2(r * 0.93 + 0.35, height * 0.55 + 1.0),
                                          SIMD2(r * 0.9, height * 0.55 + 1.3), SIMD2(r * 0.86, height),
                                          SIMD2(r + 0.9, height + 0.7), SIMD2(r + 0.9, height + 2.4), SIMD2(r * 0.8, height + 2.6)],
                    color: stone, material: stoneMaterial, segments: 28, ao: 7)
            // 窄窗：贴在塔身外面一点的深色竖条
            let windows = 6
            for k in 0..<windows {
                let a = twoPi * (Float(k) + 0.5) / Float(windows)
                let out = SIMD3<Float>(cos(a), 0, sin(a)), side = SIMD3<Float>(-sin(a), 0, cos(a))
                let y0 = height * 0.68, y1 = height * 0.86, rr = r * 0.89 + 0.05
                b.flat(base + out * rr - side * 0.55 + SIMD3(0, y0, 0), base + out * rr + side * 0.55 + SIMD3(0, y0, 0),
                       base + out * rr + side * 0.55 + SIMD3(0, y1, 0), base + out * rr - side * 0.55 + SIMD3(0, y1, 0),
                       dark, darkMaterial)
            }
            var top = height + 2.6
            if dome {
                var profile: [SIMD2<Float>] = []
                let rd = r * 0.86
                for k in 0...9 {
                    let a = Float(k) / 9 * 1.5
                    profile.append(SIMD2(rd * cos(a), top + rd * 1.05 * sin(a)))
                }
                b.lathe(base: base, profile: profile, color: copper, material: copperMaterial, segments: 28, smooth: true, ao: 0.01)
                top += rd * 1.05
            } else {
                b.lathe(base: base, profile: [SIMD2(r + 0.5, top), SIMD2(r * 0.55, top + r * 1.1), SIMD2(0.15, top + r * 3.0)],
                        color: copper, material: copperMaterial, segments: 28, smooth: true, ao: 0.01)
                top += r * 3.0
            }
            finial(base + SIMD3(0, top - 0.2, 0), size: r * 0.14, withCrystal: withCrystal)
            obstacle(sl, radius: r + 2.5, top: base.y + top + 1)
        }

        /// 一根柱子（柱础、收分的柱身、柱头）；broken：断了，只剩下面一截
        func column(_ sl: SIMD2<Float>, height: Float, radius r: Float, broken: Bool) {
            let base = onIsland(sl, lift: -0.4)
            if broken {
                b.lathe(base: base, profile: [SIMD2(r * 1.5, 0), SIMD2(r * 1.5, 0.8), SIMD2(r * 1.1, 1.1), SIMD2(r, height),
                                              SIMD2(r * 0.4, height + 0.25), SIMD2(0.02, height + 0.1)],
                        color: stone, material: stoneMaterial, segments: 12, ao: 2.5)
            } else {
                b.lathe(base: base, profile: [SIMD2(r * 1.5, 0), SIMD2(r * 1.5, 0.8), SIMD2(r * 1.1, 1.1), SIMD2(r * 0.88, height - 0.9),
                                              SIMD2(r * 1.25, height - 0.5), SIMD2(r * 1.45, height), SIMD2(0.02, height + 0.02)],
                        color: stone, material: stoneMaterial, segments: 12, ao: 2.5)
            }
        }

        // 城堡：台基是地形（三层，每层 4 米），上面的建筑从最高一层（主岛草坪 + 12 米）立起来
        let citadel = TerrainField.skyCitadel
        let cg = ground(citadel)
        let terrace = TerrainField.skyAlt + 7 + 12
        let cBase = SIMD3<Float>(cg.x, terrace - 0.3, cg.y)
        // 三层台基：直上直下的石墙，每层顶上一圈压顶石（地形网格在这里是平的草坪，台基整个是网格）
        do {
            let lawn = TerrainField.skyAlt + 7
            let radii: [Float] = [79.5, 65.5, 51.5, 0.5]
            for k in 0..<3 {
                let height = 4 * Float(k + 1) + 0.08 + 1.5
                b.lathe(base: SIMD3(cg.x, lawn - 1.5, cg.y),
                        profile: [SIMD2(radii[k], 0), SIMD2(radii[k], height - 0.45), SIMD2(radii[k] + 0.35, height - 0.45),
                                  SIMD2(radii[k] + 0.35, height), SIMD2(radii[k + 1], height)],
                        color: stone * 1.05, material: stoneMaterial, segments: 96, ao: 4)
            }
        }
        // 一圈柱廊和上面的额枋
        for k in 0..<18 {
            let a = twoPi * Float(k) / 18
            let p = SIMD3<Float>(cos(a), 0, sin(a)) * 41
            b.lathe(base: cBase + p, profile: [SIMD2(1.9, 0), SIMD2(1.9, 0.7), SIMD2(1.4, 1.0), SIMD2(1.15, 10.4), SIMD2(1.6, 10.8),
                                               SIMD2(1.85, 11.4)], color: stone, material: stoneMaterial, segments: 12, ao: 3)
        }
        b.lathe(base: cBase, profile: [SIMD2(39.0, 11.4), SIMD2(43.0, 11.4), SIMD2(43.4, 12.9), SIMD2(43.4, 13.5), SIMD2(38.6, 13.5),
                                       SIMD2(39.0, 11.4)], color: stone, material: stoneMaterial, segments: 72, ao: 0.01)
        // 鼓座
        b.lathe(base: cBase, profile: [SIMD2(20.5, 0), SIMD2(20.5, 1.4), SIMD2(19, 1.9), SIMD2(18.4, 12), SIMD2(18.9, 12.3),
                                       SIMD2(18.9, 13.2), SIMD2(18.2, 13.5), SIMD2(18, 21), SIMD2(19.4, 21.7), SIMD2(19.4, 23.2),
                                       SIMD2(17.4, 23.5)], color: stone, material: stoneMaterial, segments: 56, ao: 9)
        for k in 0..<14 {                                  // 高窗
            let a = twoPi * (Float(k) + 0.5) / 14
            let out = SIMD3<Float>(cos(a), 0, sin(a)), side = SIMD3<Float>(-sin(a), 0, cos(a))
            b.flat(cBase + out * 18.12 - side * 1.1 + SIMD3(0, 14.6, 0), cBase + out * 18.12 + side * 1.1 + SIMD3(0, 14.6, 0),
                   cBase + out * 18.05 + side * 1.1 + SIMD3(0, 19.6, 0), cBase + out * 18.05 - side * 1.1 + SIMD3(0, 19.6, 0),
                   dark, darkMaterial)
        }
        // 大门（朝着靶和大道那一面）：一块深色的门洞
        do {
            let toward = simd_normalize(ground(SIMD2(0, 0)) - cg)
            let out = SIMD3<Float>(toward.x, 0, toward.y), side = SIMD3<Float>(-toward.y, 0, toward.x)
            b.flat(cBase + out * 19.1 - side * 2.6 + SIMD3(0, 1.9, 0), cBase + out * 19.1 + side * 2.6 + SIMD3(0, 1.9, 0),
                   cBase + out * 18.6 + side * 2.6 + SIMD3(0, 9.5, 0), cBase + out * 18.6 - side * 2.6 + SIMD3(0, 9.5, 0),
                   dark, darkMaterial)
        }
        // 穹顶、采光亭、尖顶
        var domeProfile: [SIMD2<Float>] = []
        for k in 0...12 {
            let a = Float(k) / 12 * 1.4
            domeProfile.append(SIMD2(17.6 * cos(a), 23.5 + 16.5 * sin(a)))
        }
        b.lathe(base: cBase, profile: domeProfile, color: copper, material: copperMaterial, segments: 56, smooth: true, ao: 0.01)
        b.lathe(base: cBase, profile: [SIMD2(3.9, 39.2), SIMD2(3.4, 39.7), SIMD2(3.4, 45), SIMD2(4.3, 45.5), SIMD2(4.3, 46.3)],
                color: stone, material: stoneMaterial, segments: 20, ao: 0.01)
        b.lathe(base: cBase, profile: [SIMD2(4.1, 46.3), SIMD2(1.6, 52), SIMD2(0.2, 66)], color: copper, material: copperMaterial,
                segments: 20, smooth: true, ao: 0.01)
        finial(cBase + SIMD3(0, 65.8, 0), size: 0.95, withCrystal: true)
        // 四座角楼
        for k in 0..<4 {
            let a = twoPi * (Float(k) + 0.5) / 4
            let p = cBase + SIMD3<Float>(cos(a), 0, sin(a)) * 28
            b.lathe(base: p, profile: [SIMD2(5.4, 0), SIMD2(5.4, 0.9), SIMD2(4.7, 1.3), SIMD2(4.5, 26), SIMD2(5.4, 26.6),
                                       SIMD2(5.4, 27.8), SIMD2(4.9, 28)], color: stone, material: stoneMaterial, segments: 20, ao: 8)
            b.lathe(base: p, profile: [SIMD2(5.6, 28), SIMD2(2.6, 33.5), SIMD2(0.15, 41)], color: copper, material: copperMaterial,
                    segments: 20, smooth: true, ao: 0.01)
            finial(p + SIMD3(0, 40.8, 0), size: 0.55, withCrystal: false)
        }
        // 大台阶：从草坪一路上到最高一层（朝着靶的那一面），30 级
        do {
            let toward = simd_normalize(SIMD2<Float>(0, 0) - citadel)         // 谷坐标里从城堡指向靶
            let yaw = atan2(ground(citadel + toward).y - cg.y, ground(citadel + toward).x - cg.x)
            for k in 0..<30 {
                let run = 50 + (Float(k) + 0.5) * (40.0 / 30)                 // 离城堡中心多远
                let top = terrace - Float(k + 1) * 0.4
                let g = ground(citadel + toward * run)
                b.box(center: SIMD3(g.x, top - 2.5, g.y), half: SIMD3(40.0 / 60 + 0.02, 2.5, 7), yaw: yaw, color: stone * 1.04)
            }
            // 两边的栏墙
            for side: Float in [-1, 1] {
                for k in 0..<10 {
                    let run = 50 + (Float(k) + 0.5) * 4
                    let top = terrace - (Float(k) + 0.5) * 1.2 + 1.3
                    let g = ground(citadel + toward * run + SIMD2(-toward.y, toward.x) * side * 7.7)
                    b.box(center: SIMD3(g.x, top - 3, g.y), half: SIMD3(2.02, 3, 0.7), yaw: yaw, color: stone)
                }
            }
        }
        obstacle(citadel, radius: 46, top: terrace + 70)

        // 靶周围一圈残柱（半径 58 米）：进场和大道那两个方向空着；相邻两根都完整的，上面还搭着一段额枋
        do {
            let count = 16
            var standing = [Bool](repeating: false, count: count)
            var tops = [SIMD3<Float>](repeating: .zero, count: count)
            for k in 0..<count {
                let a = twoPi * (Float(k) + 0.5) / Float(count)
                guard abs(sin(a)) > 0.38 else { continue }
                let sl = SIMD2<Float>(cos(a), sin(a)) * 58
                let roll = TerrainField.hash(Int32(k), 91) * 0.5 + 0.5
                let broken = roll < 0.38
                let h: Float = broken ? 2.2 + roll * 8 : 9.6
                column(sl, height: h, radius: 0.95, broken: broken)
                standing[k] = !broken
                tops[k] = onIsland(sl, lift: -0.4) + SIMD3(0, h, 0)
            }
            for k in 0..<count where standing[k] && standing[(k + 1) % count] {
                let a = tops[k], c = tops[(k + 1) % count]
                let mid = (a + c) / 2 + SIMD3(0, 0.55, 0)
                b.box(center: mid, half: SIMD3(simd_length(c - a) / 2 + 1.2, 0.55, 0.85), yaw: atan2(c.z - a.z, c.x - a.x), color: stone)
            }
        }

        // 大道两边的方尖碑，顶上包金
        for s: Float in [46, 80, 114] {
            for l: Float in [-9.5, 9.5] {
                let base = onIsland(SIMD2(s, l), lift: -0.3)
                b.lathe(base: base, profile: [SIMD2(1.5, 0), SIMD2(1.5, 0.9), SIMD2(1.05, 1.2), SIMD2(0.72, 7.2)],
                        color: stone, material: stoneMaterial, segments: 4, ao: 2.5, twist: .pi / 4)
                b.lathe(base: base, profile: [SIMD2(0.72, 7.2), SIMD2(0.02, 8.5)], color: gold, material: goldMaterial,
                        segments: 4, ao: 0.01, twist: .pi / 4)
            }
        }

        // 大道两边的晶石灯：一个石头墩子，上面浮着一块发光的浮空石
        for s: Float in [40, 63, 97, 131] {
            for l: Float in [-7.2, 7.2] {
                let base = onIsland(SIMD2(s, l), lift: -0.2)
                b.lathe(base: base, profile: [SIMD2(0.55, 0), SIMD2(0.55, 0.3), SIMD2(0.36, 0.45), SIMD2(0.3, 1.2), SIMD2(0.5, 1.35),
                                              SIMD2(0.5, 1.5)], color: stone, material: stoneMaterial, segments: 8, ao: 1)
                b.lathe(base: base + SIMD3(0, 1.75, 0), profile: [SIMD2(0.02, 0), SIMD2(0.26, 0.42), SIMD2(0.02, 1.0)],
                        color: crystal, material: crystalMaterial, segments: 6, ao: 0.01)
            }
        }

        // 主岛上的花树：林子里按格子撒（抖一抖），树干 + 两团树冠。开花的（粉、粉白）和没开的（绿）混着
        do {
            var count = 0
            var s: Float = -255
            while s < 385, count < 190 {
                var l: Float = -225
                while l < 225, count < 190 {
                    let cell = (Int32(s), Int32(l))
                    let sl = SIMD2<Float>(s + 5 * TerrainField.hash(cell.0, cell.1), l + 5 * TerrainField.hash(cell.1, cell.0 &+ 7))
                    l += 13
                    let g = ground(sl)
                    guard TerrainField.skyMask(sl, 0) > 0.09, TerrainField.skyForest(g) > 0.6 else { continue }
                    count += 1
                    let roll = TerrainField.hash(cell.0 &+ 3, cell.1 &+ 11) * 0.5 + 0.5
                    let size = 0.8 + 0.5 * (TerrainField.hash(cell.0 &+ 17, cell.1) * 0.5 + 0.5)
                    let leaf: SIMD3<Float> = roll < 0.4 ? SIMD3(0.50, 0.26, 0.31) : (roll < 0.7 ? SIMD3(0.60, 0.48, 0.47) : SIMD3(0.075, 0.16, 0.05))
                    let base = SIMD3<Float>(g.x, TerrainField.skyHeight(g) - 0.3, g.y)
                    let trunk = 3.6 * size
                    b.lathe(base: base, profile: [SIMD2(0.42 * size, 0), SIMD2(0.26 * size, trunk + 1.5)],
                            color: SIMD3(0.07, 0.05, 0.04), material: stoneMaterial, segments: 6, ao: 2)
                    for k in 0..<2 {
                        let off = SIMD3<Float>(TerrainField.hash(cell.0 &+ Int32(k), 29), 0, TerrainField.hash(31, cell.1 &+ Int32(k))) * (1.3 * size)
                        let rx = (k == 0 ? 3.4 : 2.5) * size, ry = (k == 0 ? 2.4 : 1.9) * size
                        let bottom = base + off + SIMD3(0, trunk + (k == 0 ? 0 : 2.2 * size), 0)
                        var profile: [SIMD2<Float>] = []
                        for j in 0...4 {
                            let theta = Float.pi * Float(j) / 4
                            profile.append(SIMD2(max(rx * sin(theta), 0.02), ry * (1 - cos(theta))))
                        }
                        b.lathe(base: bottom, profile: profile, color: leaf * (k == 0 ? 1 : 1.12), material: foliageMaterial,
                                segments: 7, smooth: true, ao: 2 * ry, twist: Float(k))
                    }
                }
                s += 13
            }
        }

        // 别的岛上的塔
        tower(SIMD2(-520, -290), height: 46, radius: 6.5, dome: false, crystal: false)
        tower(SIMD2(70, -548), height: 38, radius: 5.5, dome: true, crystal: false)
        tower(SIMD2(138, 506), height: 30, radius: 5, dome: false, crystal: false)
        tower(SIMD2(-990, 40), height: 58, radius: 8, dome: true, crystal: true)
        tower(SIMD2(-900, 150), height: 34, radius: 5, dome: false, crystal: false)
        tower(SIMD2(1180, -20), height: 72, radius: 9, dome: true, crystal: true)
        tower(SIMD2(1255, 70), height: 40, radius: 6, dome: false, crystal: false)
        tower(SIMD2(1095, -115), height: 44, radius: 6, dome: false, crystal: false)
        tower(SIMD2(650, 310), height: 27, radius: 5, dome: false, crystal: false)

        // 右后方那座岛上的圆亭：八根柱子托着一个小铜顶
        do {
            let c = SIMD2<Float>(-440, 350)
            let top = onIsland(c, lift: 7.6)
            for k in 0..<8 {
                let a = twoPi * Float(k) / 8
                column(c + SIMD2(cos(a), sin(a)) * 8.5, height: 8.2, radius: 0.7, broken: false)
            }
            b.lathe(base: top, profile: [SIMD2(7.4, 0), SIMD2(10.2, 0), SIMD2(10.4, 1.1), SIMD2(7.4, 1.1), SIMD2(7.4, 0)],
                    color: stone, material: stoneMaterial, segments: 32, ao: 0.01)
            var profile: [SIMD2<Float>] = []
            for k in 0...8 { profile.append(SIMD2(9.6 * cos(Float(k) / 8 * 1.5), 1.1 + 6.5 * sin(Float(k) / 8 * 1.5))) }
            b.lathe(base: top, profile: profile, color: copper, material: copperMaterial, segments: 32, smooth: true, ao: 0.01)
            finial(top + SIMD3(0, 7.5, 0), size: 0.5, withCrystal: false)
        }

        // 左前方高处那座岛上立着的石环：环面朝着主岛，里面套一圈金环，顶上嵌一块浮空石
        do {
            let c = SIMD2<Float>(590, -340)
            let foot = onIsland(c)
            let center = foot + SIMD3(0, 35, 0)
            let toMain = ground(SIMD2(60, 0)) - ground(c)
            let axis = simd_normalize(SIMD3<Float>(toMain.x, 0, toMain.y))
            b.torus(center: center, axis: axis, radius: 30, tube: 3.2, color: stone, material: stoneMaterial)
            b.torus(center: center, axis: axis, radius: 25.6, tube: 0.45, color: gold, material: goldMaterial, segments: 56, sides: 6)
            b.box(center: foot + SIMD3(0, 2.2, 0), half: SIMD3(4.6, 3.4, 13), yaw: atan2(axis.z, axis.x), color: stone)
            b.lathe(base: center + SIMD3(0, 31.5, 0), profile: [SIMD2(0.02, 0), SIMD2(1.9, 3.2), SIMD2(0.02, 8)],
                    color: crystal, material: crystalMaterial, segments: 6, ao: 0.01)
        }

        // 拱桥：主岛左、右各一座通到旁边的岛。桥面中间拱起来一点；下面一连串的拱和吊在半空的残墩；左边那座中间断了一截
        func bridge(from a: (island: Int, sl: SIMD2<Float>), to c: (island: Int, sl: SIMD2<Float>), broken: Bool) {
            let dir = simd_normalize(c.sl - a.sl)
            let start = rim(island: a.island, from: a.sl, direction: dir) - dir * 6
            let end = rim(island: c.island, from: c.sl, direction: -dir) + dir * 6
            let p0 = onIsland(start, lift: 0.4), p1 = onIsland(end, lift: 0.4)
            let length = simd_length(SIMD2(p1.x - p0.x, p1.z - p0.z))
            let along = simd_normalize(SIMD3(p1.x - p0.x, 0, p1.z - p0.z))
            let side = SIMD3<Float>(-along.z, 0, along.x)
            let steps = 64, span: Float = 24, halfWidth: Float = 3.2
            func deck(_ t: Float) -> SIMD3<Float> {
                p0 + (p1 - p0) * t + SIMD3(0, 7 * sin(.pi * t), 0)
            }
            /// 桥面以下到拱底的深度：拱顶最薄，墩子那里最深
            func depth(_ u: Float) -> Float {
                let x = 2 * (u / span - (u / span).rounded(.down)) - 1
                return 1.1 + 6.2 * (1 - (max(0, 1 - x * x)).squareRoot())
            }
            for i in 0..<steps {
                let t0 = Float(i) / Float(steps), t1 = Float(i + 1) / Float(steps)
                if broken, t0 > 0.43, t1 < 0.53 { continue }
                let a0 = deck(t0), a1 = deck(t1)
                let d0 = depth(t0 * length), d1 = depth(t1 * length)
                let up = SIMD3<Float>(0, 1, 0)
                // 桥面、两侧（带拱的侧墙）、底
                b.flat(a0 - side * halfWidth, a0 + side * halfWidth, a1 + side * halfWidth, a1 - side * halfWidth, stone * 1.05, stoneMaterial)
                for s: Float in [-1, 1] {
                    let e0 = a0 + side * (halfWidth * s), e1 = a1 + side * (halfWidth * s)
                    let n = side * s, uv = SIMD2<Float>(0, 0), low = stone * 0.72
                    b.quad((e0 - up * d0, e1 - up * d1, e1 + up * 1.2, e0 + up * 1.2), (n, n, n, n), (uv, uv, uv, uv),
                           (low, low, stone, stone), stoneMaterial)
                    // 栏墙的里面和顶
                    let i0 = e0 - side * (0.5 * s), i1 = e1 - side * (0.5 * s)
                    b.flat(i0, i1, i1 + up * 1.2, i0 + up * 1.2, stone * 0.9, stoneMaterial)
                    b.flat(e0 + up * 1.2, e1 + up * 1.2, i1 + up * 1.2, i0 + up * 1.2, stone * 1.05, stoneMaterial)
                }
                b.flat(a0 - side * halfWidth - up * d0, a1 - side * halfWidth - up * d1, a1 + side * halfWidth - up * d1,
                       a0 + side * halfWidth - up * d0, stone * 0.6, stoneMaterial)
            }
            // 残墩：每个拱脚下面一截往下收的墩子，吊在半空
            var u = span
            while u < length - span * 0.5 {
                let t = u / length
                if !(broken && t > 0.4 && t < 0.56) {
                    let top = deck(t) - SIMD3(0, 7.3, 0)
                    let h = 7 + 9 * (TerrainField.hash(Int32(u), 5) * 0.5 + 0.5)
                    b.lathe(base: top - SIMD3(0, h, 0), profile: [SIMD2(0.3, 0), SIMD2(1.6, h * 0.5), SIMD2(2.3, h)],
                            color: stone * 0.8, material: stoneMaterial, segments: 4, ao: 0.01, twist: atan2(along.z, along.x) + .pi / 4)
                }
                u += span
            }
        }
        bridge(from: (0, SIMD2(70, -150)), to: (5, SIMD2(70, -540)), broken: true)
        bridge(from: (0, SIMD2(130, 150)), to: (6, SIMD2(130, 500)), broken: false)

        layout.buildings = b.v

        // 瀑布：一条半圆管形的带子，从岛边往外抛一点再直落下去，越落越宽
        var w = Builder()
        func waterfall(island: Int, from start: SIMD2<Float>, direction: SIMD2<Float>, drop: Float, width: Float) {
            let d = simd_normalize(direction)
            let edge = rim(island: island, from: start, direction: d)
            let top = onIsland(edge - d * 2, lift: -0.6)
            let g0 = ground(edge), g1 = ground(edge + d)
            let out = simd_normalize(SIMD3<Float>(g1.x - g0.x, 0, g1.y - g0.y))
            let across = SIMD3<Float>(-out.z, 0, out.x)
            let rings = 28, sides = 6
            func point(_ i: Int, _ k: Int) -> (SIMD3<Float>, SIMD2<Float>) {
                let t = Float(i) / Float(rings)
                let fallen = drop * pow(t, 1.5)
                let half = width * 0.5 + 0.03 * fallen
                let phi = (Float(k) / Float(sides) - 0.5) * .pi
                let center = top + out * (2 + 1.1 * fallen.squareRoot()) - SIMD3(0, fallen, 0)
                return (center + across * (sin(phi) * half) + out * (cos(phi) * half * 0.45), SIMD2(sin(phi), fallen))
            }
            for i in 0..<rings {
                for k in 0..<sides {
                    let a = point(i, k), c = point(i + 1, k), e = point(i + 1, k + 1), f = point(i, k + 1)
                    let color = SIMD3<Float>(1, 1, 1)
                    w.quad((a.0, c.0, e.0, f.0), (out, out, out, out), (a.1, c.1, e.1, f.1), (color, color, color, color), drop)
                }
            }
        }
        // 主岛水池那条小溪跌下去的地方，和几座岛边上的
        waterfall(island: 0, from: TerrainField.skyPool + SIMD2(0, -30), direction: SIMD2(0, -1), drop: 340, width: 5)
        waterfall(island: 0, from: SIMD2(250, 120), direction: SIMD2(0.5, 1), drop: 300, width: 7)
        waterfall(island: 4, from: SIMD2(640, 300), direction: SIMD2(-0.6, -0.8), drop: 260, width: 6)
        waterfall(island: 3, from: SIMD2(590, -340), direction: SIMD2(-0.2, 1), drop: 320, width: 8)
        waterfall(island: 8, from: SIMD2(1180, -20), direction: SIMD2(-1, 0.3), drop: 400, width: 10)
        waterfall(island: 8, from: SIMD2(1180, -20), direction: SIMD2(-0.4, -1), drop: 360, width: 7)
        waterfall(island: 7, from: SIMD2(-960, 80), direction: SIMD2(1, 0.35), drop: 420, width: 9)
        waterfall(island: 1, from: SIMD2(-520, -290), direction: SIMD2(0.8, 0.6), drop: 250, width: 5)
        layout.waterfalls = w.v
        return layout
    }
}
