import Foundation
import simd

/// 场景里的实体模型（SceneProps）用的材质编号，和 Terrain.h 的 CITY_* 一一对应。顶点的 color.a 存这个
enum PropMaterial {
    /// 砌石（一层层错缝的石块，带风化和青苔）
    static let stone: Float = 0
    /// 铜皮（氧化成青绿色）
    static let copper: Float = 1
    static let gold: Float = 2
    /// 深色的洞口（窗、门）
    static let dark: Float = 3
    /// 自己发光的晶石
    static let crystal: Float = 4
    /// 树冠（背面也透一点光）
    static let foliage: Float = 5
    /// 天然的石头（深浅不匀，朝上的面长地衣）
    static let rock: Float = 6
    /// 树干、木头（竖着的纹）
    static let bark: Float = 7
    /// 顶点颜色照原样打光，不加任何花纹
    static let plain: Float = 8
    /// 朝上的面积着雪（石头、树、屋顶都能用）
    static let snowy: Float = 9
}

/// 拼实体模型网格的工具：旋转体、长方体、圆环这几个基本形状。顶点在地面坐标里（x、海拔、z），
/// 着色见 Terrain.h 的 cityFragment。各关在自己的 Props*.swift 里用它拼自己的东西
struct PropBuilder {
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

// MARK: - 树、石头这些自然物（各关的 Props<关名>.swift 用）

extension PropBuilder {
    private static func h01(_ a: Int32, _ b: Int32) -> Float { TerrainField.hash(a, b) * 0.5 + 0.5 }

    mutating func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                      _ na: SIMD3<Float>, _ nb: SIMD3<Float>, _ nc: SIMD3<Float>,
                      _ ca: SIMD3<Float>, _ cb: SIMD3<Float>, _ cc: SIMD3<Float>, _ material: Float) {
        vertex(a, na, SIMD2(0, 0), ca, material)
        vertex(b, nb, SIMD2(1, 0), cb, material)
        vertex(c, nc, SIMD2(0.5, 1), cc, material)
    }

    /// 一个棱锥（针叶树的一层、树干）：底下一圈暗（被上面一层挡着），尖上亮
    mutating func cone(base: SIMD3<Float>, radius: Float, height: Float, sides: Int, color: SIMD3<Float>,
                       material: Float, phase: Float = 0, lean: SIMD3<Float> = .zero) {
        let apex = base + SIMD3(0, height, 0) + lean
        for i in 0..<sides {
            let a0 = phase + 2 * .pi * Float(i) / Float(sides), a1 = phase + 2 * .pi * Float(i + 1) / Float(sides)
            let d0 = SIMD3<Float>(cos(a0), 0, sin(a0)), d1 = SIMD3<Float>(cos(a1), 0, sin(a1))
            let up = radius / max(height, 0.01)
            let n0 = simd_normalize(d0 + SIMD3(0, up, 0)), n1 = simd_normalize(d1 + SIMD3(0, up, 0))
            tri(base + d0 * radius, apex, base + d1 * radius, n0, simd_normalize(n0 + n1), n1,
                color * 0.6, color * 1.15, color * 0.6, material)
        }
    }

    /// 一团树冠 / 一块石头：上下两个棱锥对着扣，法线按椭球取（看起来是圆的），底下暗
    mutating func blob(center: SIMD3<Float>, radius: SIMD3<Float>, sides: Int, color: SIMD3<Float>, material: Float,
                       phase: Float = 0, seed: Int32 = 0) {
        // （中间一圈最宽，上面再一圈收小，顶是一个很矮的尖：轮廓是圆的。只有上下两个尖的话像针叶树）
        let top = center + SIMD3(0, radius.y * 0.92, 0), bottom = center - SIMD3(0, radius.y * 0.7, 0)
        func ring(_ i: Int, _ level: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let a = phase + 2 * .pi * (Float(i % sides) + 0.5 * Float(level)) / Float(sides)
            let k = (0.82 + 0.36 * Self.h01(seed &+ Int32(i % sides), 77 &+ Int32(level))) * (level == 0 ? 1 : 0.68)
            let y = level == 0 ? -0.12 * radius.y : 0.55 * radius.y
            let p = center + SIMD3(cos(a) * radius.x * k, y, sin(a) * radius.z * k)
            return (p, simd_normalize((p - center) / radius + SIMD3(0, 0.15, 0)))
        }
        let up = SIMD3<Float>(0, 1, 0)
        for i in 0..<sides {
            let (p0, n0) = ring(i, 0), (p1, n1) = ring(i + 1, 0), (q0, m0) = ring(i, 1), (q1, m1) = ring(i + 1, 1)
            tri(p0, q0, p1, n0, m0, n1, color * 0.8, color * 1.1, color * 0.8, material)
            tri(p1, q0, q1, n1, m0, m1, color * 0.8, color * 1.1, color * 1.1, material)
            tri(q0, top, q1, m0, up, m1, color * 1.1, color * 1.22, color * 1.1, material)
            tri(p1, bottom, p0, n1, -up, n0, color * 0.8, color * 0.4, color * 0.8, material)
        }
    }

    /// 两点之间的一段管子（棕榈的树干、漂木、杆子）
    mutating func tube(from: SIMD3<Float>, to: SIMD3<Float>, r0: Float, r1: Float, sides: Int, color: SIMD3<Float>, material: Float) {
        let axis = simd_normalize(to - from)
        let ref: SIMD3<Float> = abs(axis.y) > 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(axis, ref)), w = simd_cross(axis, u)
        for i in 0..<sides {
            let a0 = 2 * .pi * Float(i) / Float(sides), a1 = 2 * .pi * Float(i + 1) / Float(sides)
            let n0 = u * cos(a0) + w * sin(a0), n1 = u * cos(a1) + w * sin(a1)
            tri(from + n0 * r0, to + n0 * r1, from + n1 * r0, n0, n0, n1, color, color, color, material)
            tri(from + n1 * r0, to + n0 * r1, to + n1 * r1, n1, n0, n1, color, color, color, material)
        }
    }

    /// 针叶树（云杉）：几层越往上越小的棱锥。near：近处的多一层、带树干
    mutating func conifer(base: SIMD3<Float>, height: Float, near: Bool, seed: Int32) {
        let tint = 0.8 + 0.5 * Self.h01(seed, 3)
        let green = SIMD3<Float>(0.020, 0.046, 0.022) * tint
        let r = height * (0.17 + 0.05 * Self.h01(seed, 5))
        let phase = 6.28 * Self.h01(seed, 9)
        if near {
            cone(base: base, radius: height * 0.022, height: height * 0.5, sides: 4, color: SIMD3(0.07, 0.05, 0.035), material: PropMaterial.bark)
            cone(base: base + SIMD3(0, height * 0.14, 0), radius: r, height: height * 0.45, sides: 6, color: green, material: PropMaterial.foliage, phase: phase)
            cone(base: base + SIMD3(0, height * 0.38, 0), radius: r * 0.72, height: height * 0.38, sides: 6, color: green * 1.08, material: PropMaterial.foliage, phase: phase + 0.5)
            cone(base: base + SIMD3(0, height * 0.62, 0), radius: r * 0.45, height: height * 0.38, sides: 5, color: green * 1.16, material: PropMaterial.foliage, phase: phase + 1.1)
        } else {
            cone(base: base + SIMD3(0, height * 0.08, 0), radius: r, height: height * 0.55, sides: 5, color: green, material: PropMaterial.foliage, phase: phase)
            cone(base: base + SIMD3(0, height * 0.45, 0), radius: r * 0.6, height: height * 0.55, sides: 5, color: green * 1.12, material: PropMaterial.foliage, phase: phase + 0.6)
        }
    }

    /// 阔叶树：树干上一两团树冠。green：这一关树叶的颜色
    mutating func broadleaf(base: SIMD3<Float>, height: Float, near: Bool, seed: Int32, green: SIMD3<Float>) {
        let tint = 0.8 + 0.45 * Self.h01(seed, 3)
        let c = green * tint
        let rx = height * (0.30 + 0.10 * Self.h01(seed, 5)), ry = height * (0.30 + 0.06 * Self.h01(seed, 6))
        let phase = 6.28 * Self.h01(seed, 9)
        if near {
            cone(base: base, radius: height * 0.035, height: height * 0.62, sides: 4, color: SIMD3(0.075, 0.058, 0.04), material: PropMaterial.bark)
            blob(center: base + SIMD3(0, height * 0.66, 0), radius: SIMD3(rx, ry, rx), sides: 7, color: c, material: PropMaterial.foliage, phase: phase, seed: seed)
            let off = SIMD3<Float>(cos(phase), 0, sin(phase)) * rx * 0.6
            blob(center: base + off + SIMD3(0, height * 0.5, 0), radius: SIMD3(rx, ry, rx) * 0.62, sides: 5, color: c * 0.9, material: PropMaterial.foliage,
                 phase: phase + 1, seed: seed &+ 11)
        } else {
            blob(center: base + SIMD3(0, height * 0.62, 0), radius: SIMD3(rx, ry * 1.15, rx), sides: 5, color: c, material: PropMaterial.foliage, phase: phase, seed: seed)
        }
    }

    /// 椰子树：歪着往上长的细树干，顶上一圈往下垂的大叶子
    mutating func palm(base: SIMD3<Float>, height: Float, seed: Int32) {
        let dir = 6.28 * Self.h01(seed, 3)
        let leanTo = SIMD3<Float>(cos(dir), 0, sin(dir)) * height * (0.12 + 0.22 * Self.h01(seed, 4))
        let bark = SIMD3<Float>(0.11, 0.09, 0.065)
        var p = base - SIMD3(0, 0.3, 0)
        var top = p
        for k in 0..<3 {
            let t = Float(k + 1) / 3
            top = base + leanTo * (t * t) + SIMD3(0, height * t, 0)
            tube(from: p, to: top, r0: 0.19 - 0.035 * Float(k), r1: 0.155 - 0.035 * Float(k), sides: 5, color: bark, material: PropMaterial.bark)
            p = top
        }
        let leaf = SIMD3<Float>(0.045, 0.10, 0.03) * (0.85 + 0.3 * Self.h01(seed, 6))
        let fronds = 8
        for i in 0..<fronds {
            let a = dir + 2 * .pi * (Float(i) + 0.4 * Self.h01(seed &+ Int32(i), 8)) / Float(fronds)
            let out = SIMD3<Float>(cos(a), 0, sin(a)), side = SIMD3<Float>(-sin(a), 0, cos(a))
            let len = height * (0.36 + 0.10 * Self.h01(seed &+ Int32(i), 12))
            let lift = 0.05 + 0.3 * Self.h01(seed &+ Int32(i), 14)
            let mid = top + out * len * 0.5 + SIMD3(0, len * lift, 0)
            let tip = top + out * len + SIMD3(0, len * (lift - 0.45), 0)
            let w0 = side * 0.18, w1 = side * len * 0.2
            let n = simd_normalize(SIMD3<Float>(0, 1, 0) + out * 0.3)
            tri(top - w0, mid - w1, top + w0, n, n, n, leaf * 0.8, leaf, leaf * 0.8, PropMaterial.foliage)
            tri(top + w0, mid - w1, mid + w1, n, n, n, leaf * 0.8, leaf, leaf, PropMaterial.foliage)
            tri(mid - w1, tip, mid + w1, n, n, n, leaf, leaf * 1.15, leaf, PropMaterial.foliage)
        }
        // 叶子底下一小串椰子
        blob(center: top - SIMD3(0, 0.25, 0), radius: SIMD3(0.32, 0.26, 0.32), sides: 5, color: SIMD3(0.05, 0.045, 0.02), material: PropMaterial.plain)
    }
}

/// 在一关里撒树的位置：以靶为中心、抖过的格点，离得越远留得越稀（远处地面上画的林子接着）；按从近到远排好
enum PropScatter {
    struct Spot {
        var p: SIMD2<Float>
        var h: Float
        var distance: Float
        var seed: Int32
        var size: Float      // 0..1
    }

    /// keep：这个点要不要（传进来地面坐标和这里的地面高度）
    static func spots(scene: JumpScene, radius: Float, spacing: Float, full: Float, salt: Int32 = 0,
                      keep: (SIMD2<Float>, Float) -> Bool) -> [Spot] {
        let center = TerrainField.target
        let n = Int32((radius / spacing).rounded(.up))
        var out: [Spot] = []
        for j in -n...n {
            for i in -n...n {
                let a = i &* 7 &+ salt, b = j &* 13 &- salt
                let jitter = SIMD2<Float>(TerrainField.hash(a, b), TerrainField.hash(b &+ 91, a &- 17)) * 0.45
                let p = center + (SIMD2(Float(i), Float(j)) + jitter) * spacing
                let d = simd_length(p - center)
                guard d < radius else { continue }
                let chance = min(1, (full / max(d, 1)) * (full / max(d, 1)))
                guard TerrainField.hash(a &+ 5, b &+ 3) * 0.5 + 0.5 < chance else { continue }
                let h = TerrainField.height(scene, p)
                guard keep(p, h) else { continue }
                out.append(Spot(p: p, h: h, distance: d, seed: a &* 31 &+ b, size: TerrainField.hash(a &- 3, b &+ 8) * 0.5 + 0.5))
            }
        }
        return out.sorted { $0.distance < $1.distance }
    }
}
