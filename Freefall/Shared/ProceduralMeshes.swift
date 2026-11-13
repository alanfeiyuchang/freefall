import Foundation
import simd

// 程序生成的网格：飞机（货舱内部 + 外壳）和伞衣。只在启动时生成一次。
// 都是不带索引的三角形列表；法线朝哪边无所谓（shader 两面都画，自动翻向看的人）。

/// 和 Shaders/Objects.h 的 MeshVertex 一样
struct MeshVertex {
    var position: SIMD4<Float>
    /// w：室内程度（0 露天 … 1 机舱深处）
    var normal: SIMD4<Float>
    /// rgb 反照率（自发光是辐亮度），a 材质
    var color: SIMD4<Float>
}

enum MeshMaterial: Float {
    case diffuse = 0, emissive = 1, lampRed = 2, lampGreen = 3, fabric = 4, soft = 5
    /// 装备（Gear.swift）：尼龙织带、金属（环、扣、钢索）、塑料（软管、表壳）、橡胶（表带）
    case webbing = 6, metal = 7, plastic = 8, rubber = 9
    /// 舱门边的扶杆：开场在你的房间里只有它（不参与实体化，先按屋里的光打）。
    /// 喷黄漆的钢管、中段的黑色橡胶握把（一圈圈防滑棱）、上下两头镀锌的法兰和螺栓
    case bar = 10, barGrip = 11, barMetal = 12
    /// 机舱（花纹都在 shader 里按机身坐标现算）：绗缝的隔热垫、喷漆的金属（框、支架、门）、
    /// 裸金属（滚轮、钢索、管子、系留环、铰链）、地板（防滑涂层、拼缝、螺钉、系留环的凹坑、跳板的防滑棱和尾端警示条）、
    /// 黄黑警示条、舷窗玻璃（透出去是天）、红色尼龙编织带的座椅
    case quilt = 13, painted = 14, aluminum = 15, tread = 16, hazard = 17, window = 18, seat = 19
    /// 换皮肤的两样（颜色在 shader 里按皮肤的图案现算，Skins.h）：伞衣（打光同 fabric）、跳伞服的袖子（打光同 webbing）
    case canopy = 20, sleeve = 21
}

/// 和 v 垂直的一个单位向量
func orthogonalUnit(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let helper: SIMD3<Float> = abs(v.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
    return normalize(cross(v, helper))
}

struct MeshBuilder {
    var vertices: [MeshVertex] = []
    /// 每个顶点的室内程度，按位置算
    var interiorAt: (SIMD3<Float>) -> Float = { _ in 0 }

    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ color: SIMD3<Float>, _ material: MeshMaterial) {
        vertices.append(MeshVertex(position: SIMD4(p, 1), normal: SIMD4(n, interiorAt(p)),
                                   color: SIMD4(color, material.rawValue)))
    }

    mutating func quad(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                       normals: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? = nil,
                       color: SIMD3<Float>, material: MeshMaterial = .diffuse) {
        let flat = normalize(cross(p1 - p0, p3 - p0))
        let n = normals ?? (flat, flat, flat, flat)
        vertex(p0, n.0, color, material); vertex(p1, n.1, color, material); vertex(p2, n.2, color, material)
        vertex(p0, n.0, color, material); vertex(p2, n.2, color, material); vertex(p3, n.3, color, material)
    }

    /// 轴对齐的盒子。沿 z 很长的分成 1.2 米一段（顶点上的室内程度跟着变），只在两头封口
    mutating func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, color: SIMD3<Float>, material: MeshMaterial = .diffuse) {
        let c = { (x: Float, y: Float, z: Float) in SIMD3<Float>(x, y, z) }
        let pieces = max(1, Int(((hi.z - lo.z) / 1.2).rounded(.up)))
        for i in 0..<pieces {
            let za = lo.z + (hi.z - lo.z) * Float(i) / Float(pieces)
            let zb = lo.z + (hi.z - lo.z) * Float(i + 1) / Float(pieces)
            quad(c(lo.x, lo.y, za), c(lo.x, lo.y, zb), c(lo.x, hi.y, zb), c(lo.x, hi.y, za), color: color, material: material)
            quad(c(hi.x, lo.y, zb), c(hi.x, lo.y, za), c(hi.x, hi.y, za), c(hi.x, hi.y, zb), color: color, material: material)
            quad(c(lo.x, hi.y, zb), c(hi.x, hi.y, zb), c(hi.x, hi.y, za), c(lo.x, hi.y, za), color: color, material: material)
            quad(c(lo.x, lo.y, za), c(hi.x, lo.y, za), c(hi.x, lo.y, zb), c(lo.x, lo.y, zb), color: color, material: material)
        }
        quad(c(lo.x, lo.y, hi.z), c(hi.x, lo.y, hi.z), c(hi.x, hi.y, hi.z), c(lo.x, hi.y, hi.z), color: color, material: material)
        quad(c(hi.x, lo.y, lo.z), c(lo.x, lo.y, lo.z), c(lo.x, hi.y, lo.z), c(hi.x, hi.y, lo.z), color: color, material: material)
    }

    /// 有朝向的盒子：中心加减三个半轴
    mutating func orientedBox(center o: SIMD3<Float>, _ x: SIMD3<Float>, _ y: SIMD3<Float>, _ z: SIMD3<Float>,
                              color: SIMD3<Float>, material: MeshMaterial = .diffuse) {
        let p = { (a: Float, b: Float, d: Float) in o + a * x + b * y + d * z }
        quad(p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1), color: color, material: material)
        quad(p(1, -1, -1), p(-1, -1, -1), p(-1, 1, -1), p(1, 1, -1), color: color, material: material)
        quad(p(-1, -1, -1), p(-1, -1, 1), p(-1, 1, 1), p(-1, 1, -1), color: color, material: material)
        quad(p(1, -1, 1), p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), color: color, material: material)
        quad(p(-1, 1, 1), p(1, 1, 1), p(1, 1, -1), p(-1, 1, -1), color: color, material: material)
        quad(p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1), color: color, material: material)
    }

    /// 沿折线扫出来的圆管（平行移动的标架，不扭），每个点一个半径；同一个位置连放两个点、半径不同就是一个台阶
    mutating func tube(_ path: [SIMD3<Float>], radii: [Float], segments: Int = 12,
                       color: SIMD3<Float>, material: MeshMaterial, caps: Bool = true) {
        guard path.count >= 2 else { return }
        func tangent(_ i: Int) -> SIMD3<Float> {
            var a = max(i - 1, 0), b = min(i + 1, path.count - 1)
            while length(path[b] - path[a]) < 1e-6 && (a > 0 || b < path.count - 1) {
                a = max(a - 1, 0); b = min(b + 1, path.count - 1)
            }
            return normalize(path[b] - path[a])
        }
        var u = orthogonalUnit(tangent(0))
        var frames: [(SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<path.count {
            let t = tangent(i)
            u = normalize(u - dot(u, t) * t)
            frames.append((u, cross(t, u)))
        }
        func ring(_ i: Int, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let a = 2 * Float.pi * Float(k) / Float(segments)
            let n = frames[i].0 * cos(a) + frames[i].1 * sin(a)
            return (path[i] + n * radii[i], n)
        }
        for i in 0..<(path.count - 1) {
            for k in 0..<segments {
                let (p0, n0) = ring(i, k), (p1, n1) = ring(i, k + 1)
                let (p2, n2) = ring(i + 1, k + 1), (p3, n3) = ring(i + 1, k)
                quad(p0, p1, p2, p3, normals: (n0, n1, n2, n3), color: color, material: material)
            }
        }
        if caps {
            for (i, sign) in [(0, Float(-1)), (path.count - 1, Float(1))] {
                let axis = tangent(i) * sign
                for k in 0..<segments {
                    vertex(path[i], axis, color, material)
                    vertex(ring(i, k).0, axis, color, material)
                    vertex(ring(i, k + 1).0, axis, color, material)
                }
            }
        }
    }

    mutating func cylinder(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, segments: Int = 12,
                           color: SIMD3<Float>, material: MeshMaterial, caps: Bool = true) {
        // 长的分段（室内程度跟着变）
        let pieces = max(1, Int((length(b - a) / 1.2).rounded(.up)))
        let path = (0...pieces).map { a + (b - a) * Float($0) / Float(pieces) }
        tube(path, radii: [Float](repeating: radius, count: path.count), segments: segments,
             color: color, material: material, caps: caps)
    }

    /// 圆环（轴 axis、主半径 major、管半径 minor）；arc 只画一段（弧度，从 axis 的某个垂直方向量起）
    mutating func torus(center: SIMD3<Float>, axis: SIMD3<Float>, major: Float, minor: Float,
                        segments: Int = 24, sides: Int = 8, arc: (Float, Float) = (0, 2 * .pi),
                        start: SIMD3<Float>? = nil, color: SIMD3<Float>, material: MeshMaterial) {
        let w = normalize(axis)
        let u = start.map { normalize($0 - dot($0, w) * w) } ?? orthogonalUnit(w)
        let v = cross(w, u)
        func point(_ i: Int, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let a = arc.0 + (arc.1 - arc.0) * Float(i) / Float(segments)
            let radial = u * cos(a) + v * sin(a)
            let b = 2 * Float.pi * Float(k) / Float(sides)
            let n = radial * cos(b) + w * sin(b)
            return (center + radial * major + n * minor, n)
        }
        for i in 0..<segments {
            for k in 0..<sides {
                let (p0, n0) = point(i, k), (p1, n1) = point(i + 1, k)
                let (p2, n2) = point(i + 1, k + 1), (p3, n3) = point(i, k + 1)
                quad(p0, p1, p2, p3, normals: (n0, n1, n2, n3), color: color, material: material)
            }
        }
    }

    /// 圆片
    mutating func disc(center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float, segments: Int = 24,
                       color: SIMD3<Float>, material: MeshMaterial) {
        let w = normalize(normal), u = orthogonalUnit(w), v = cross(w, u)
        for k in 0..<segments {
            let a0 = 2 * Float.pi * Float(k) / Float(segments), a1 = 2 * Float.pi * Float(k + 1) / Float(segments)
            vertex(center, w, color, material)
            vertex(center + radius * (u * cos(a0) + v * sin(a0)), w, color, material)
            vertex(center + radius * (u * cos(a1) + v * sin(a1)), w, color, material)
        }
    }

    /// 机身截面上的一段壳：截面圆心 (0, center(z), z)、半径 radius(z)；角度 φ = 0 在圆的正下方，
    /// 按 (sin φ, -cos φ) 绕一圈；angles(z) 给出这一截保留的角度范围。
    mutating func shell(z0: Float, z1: Float, zSteps: Int, segments: Int,
                        center: (Float) -> Float, radius: (Float) -> Float,
                        angles: (Float) -> (Float, Float), color: SIMD3<Float>, material: MeshMaterial = .diffuse) {
        func point(_ z: Float, _ t: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            let (a0, a1) = angles(z)
            let phi = a0 + (a1 - a0) * t
            let r = radius(z)
            let n = SIMD3<Float>(sin(phi), -cos(phi), 0)
            return (SIMD3(r * sin(phi), center(z) - r * cos(phi), z), n)
        }
        for i in 0..<zSteps {
            let za = z0 + (z1 - z0) * Float(i) / Float(zSteps)
            let zb = z0 + (z1 - z0) * Float(i + 1) / Float(zSteps)
            for k in 0..<segments {
                let ta = Float(k) / Float(segments), tb = Float(k + 1) / Float(segments)
                let (p0, n0) = point(za, ta), (p1, n1) = point(za, tb)
                let (p2, n2) = point(zb, tb), (p3, n3) = point(zb, ta)
                quad(p0, p1, p2, p3, normals: (n0, n1, n2, n3), color: color, material: material)
            }
        }
    }
}

enum ProceduralMeshes {
    // MARK: - 飞机

    /// 机身截面：圆心高 1.05 米，半径 1.75 米，地板在 y = 0 处把圆切掉一截（地板宽 2.8 米，舱高 2.8 米）。
    static let fuselageCenter: Float = 1.05
    static let fuselageRadius: Float = 1.75
    /// 跳板铰链（货舱地板到这里结束，往后是放平的跳板）
    static let rampHinge: Float = -4.5
    static let rampEnd: Float = -8.0
    /// 开局你站在跳板上、离跳板末端 2.2 米：飞机原点在你身后这么远（米）
    static let standOnRamp: Double = 5.8
    /// 舱门边的竖扶杆（舞台坐标：你右手边 55 厘米、往前 25 厘米），抓住它游戏开始，松手就跳。
    /// 能握的一段是 barBottom ~ barTop（舞台高度）；杆子本身从跳板一直通到收起来的上舱门
    static let barStage = SIMD2<Float>(0.55, -0.25)
    static let barBottom: Float = 0.25, barTop: Float = 2.3
    /// 收在尾段顶上的上舱门（底面高度），扶杆顶在它上面
    static let upperDoorBottom: Float = 2.5

    /// 加强框（每 0.55 米一个）
    static let frameZ: [Float] = (0..<22).map { -4.2 + 0.55 * Float($0) }
    /// 舱顶的红色夜灯（Shaders/Objects.h 的 CABIN_LAMP_Z、CABIN_LAMP_Y 要一样）
    static let lampZ: [Float] = [-2.275, 0.475, 3.225, 5.975]
    static let lampY: Float = 2.685
    /// 两侧的伞兵门：在两个加强框之间
    static let doorZ: (Float, Float) = (-4.2, -3.1)
    /// 舷窗（两侧对称，在两个框中间）
    static let windowZ: [Float] = [-1.725, 0.475, 2.675, 4.875]
    static let windowY: Float = 1.6
    /// 尾段只剩上半截机身的角度范围；往机尾截面圆心越来越高
    static let tailAngles: (Float, Float) = (0.6 * .pi, 1.4 * .pi)
    static func tailCenter(_ z: Float) -> Float { fuselageCenter + max(rampHinge - z, 0) * 0.18 }

    /// 舱壁上高度 y 处的角度（右边；左边是 2π 减它）。φ = 0 在圆的正下方，点 = (r sin φ, 圆心 - r cos φ)
    static func wallAngle(_ y: Float) -> Float {
        acos(min(max((fuselageCenter - y) / fuselageRadius, -1), 1))
    }
    /// 舱壁上的点，inset：往舱里缩多少（米）
    static func wallPoint(_ phi: Float, z: Float, inset: Float = 0, center: Float = fuselageCenter) -> SIMD3<Float> {
        let r = fuselageRadius - inset
        return SIMD3(r * sin(phi), center - r * cos(phi), z)
    }
    /// 舱壁朝里的法线
    static func wallInward(_ phi: Float) -> SIMD3<Float> { SIMD3(-sin(phi), cos(phi), 0) }
    /// 伞兵门的角度范围（右边，门底 5 厘米到门顶 1.85 米）
    static let doorAngles: (Float, Float) = (wallAngle(0.05), wallAngle(1.85))

    /// 类似 C-130 的运输机。坐标：原点在你起跳时站的地板上；-Z 朝机尾（舱门、你面朝的方向），+Z 朝机头，y 向上。
    /// 扶杆在哪一边：戴表那只手的另一边（表在左手 → 杆在右边，用右手抓，抓着的时候左手腕上的表看得到）
    static func barStage(onLeft: Bool) -> SIMD2<Float> { SIMD2(onLeft ? -barStage.x : barStage.x, barStage.y) }

    static func plane(barOnLeft: Bool = false) -> [MeshVertex] {
        var m = MeshBuilder()
        // ---- 货舱内部（越往机头越暗，舱门附近照得到太阳；舱顶四盏红色夜灯在 shader 里当点光源）----
        m.interiorAt = { p in smoothstepF(-6.8, 1.5, p.z) }
        cabinShell(&m)
        cabinFloor(&m)
        cabinRamp(&m)
        cabinSeats(&m)
        cabinCeiling(&m)
        cabinDoorsAndWindows(&m)
        cabinBulkhead(&m)
        // （舱壁和跳板顶上的红绿跳伞灯去掉了：握着扶杆的时候它们不在视野里，很难注意到变绿。
        // 现在是手腕上的表亮绿灯，见 hudFragment）
        bar(&m, onLeft: barOnLeft)
        // ---- 外壳（出舱以后回头看到的飞机）----
        m.interiorAt = { _ in 0 }
        exterior(&m)
        return m.vertices
    }

    // MARK: 舱壁

    private static func cabinShell(_ m: inout MeshBuilder) {
        let yc = fuselageCenter, R = fuselageRadius
        let floorAngle = acos(yc / R)                     // 地板和圆相交处的 φ
        let insulation = SIMD3<Float>(0.27, 0.30, 0.25)   // 灰绿色的绗缝隔热垫（绗缝在 shader 里画）
        m.shell(z0: rampHinge, z1: 8, zSteps: 25, segments: 48, center: { _ in yc }, radius: { _ in R },
                angles: { _ in (floorAngle, 2 * .pi - floorAngle) }, color: insulation, material: .quilt)
        // 尾段：在跳板上方只剩上半截机身，往机尾越来越高；下面整个敞开（尾舱门放下了）
        m.shell(z0: -8.6, z1: rampHinge, zSteps: 8, segments: 30, center: tailCenter, radius: { _ in R },
                angles: { _ in tailAngles }, color: insulation, material: .quilt)

        // 加强框：T 形截面（从舱壁伸出来 9 厘米的腹板 + 5 厘米宽的内缘），伞兵门那一段断开
        let frameColor = SIMD3<Float>(0.24, 0.26, 0.24)
        let lo = floorAngle + 0.015, hi = 2 * .pi - floorAngle - 0.015
        for z in frameZ {
            var ranges: [(Float, Float)] = [(lo, hi)]
            if z > doorZ.0 + 0.01 && z < doorZ.1 - 0.01 {
                ranges = [(doorAngles.1, 2 * .pi - doorAngles.1)]
            }
            for r in ranges { frameArc(&m, z: z, from: r.0, to: r.1, depth: 0.09, flange: 0.05, color: frameColor) }
        }
        // 跳板铰链上方的一圈大框（尾舱门的门框），尾段里也有几道框
        frameArc(&m, z: rampHinge + 0.045, from: lo, to: hi, depth: 0.15, flange: 0.09, color: frameColor)
        for z: Float in [-5.25, -6.0, -6.75, -7.5, -8.25] {
            frameArc(&m, z: z, from: tailAngles.0 + 0.02, to: tailAngles.1 - 0.02, depth: 0.08, flange: 0.045,
                     color: frameColor, center: tailCenter(z))
        }
        // 尾段敞口：两条边梁 + 最后的一道弧
        for phi in [tailAngles.0, tailAngles.1] {
            let path = stride(from: Float(-8.6), through: rampHinge, by: 0.5).map {
                wallPoint(phi, z: $0, inset: 0.035, center: tailCenter($0))
            }
            m.tube(path, radii: [Float](repeating: 0.042, count: path.count), segments: 10,
                   color: frameColor, material: .painted)
        }
        let arc = (0...16).map { i -> SIMD3<Float> in
            let phi = tailAngles.0 + (tailAngles.1 - tailAngles.0) * Float(i) / 16
            return wallPoint(phi, z: -8.57, inset: 0.035, center: tailCenter(-8.6))
        }
        m.tube(arc, radii: [Float](repeating: 0.05, count: arc.count), segments: 10, color: frameColor, material: .painted)
    }

    /// 一段加强框：腹板（舱壁往里 depth 米的一圈平板）+ 内缘（宽 flange 米、1 厘米厚的弧面）
    private static func frameArc(_ m: inout MeshBuilder, z: Float, from a0: Float, to a1: Float, depth: Float,
                                 flange: Float, color: SIMD3<Float>, center: Float = fuselageCenter) {
        let steps = max(Int(((a1 - a0) / 0.09).rounded(.up)), 2)
        let h = flange / 2
        let dz = SIMD3<Float>(0, 0, h)
        for k in 0..<steps {
            let pa = a0 + (a1 - a0) * Float(k) / Float(steps), pb = a0 + (a1 - a0) * Float(k + 1) / Float(steps)
            let oa = wallPoint(pa, z: z, inset: 0.003, center: center), ob = wallPoint(pb, z: z, inset: 0.003, center: center)
            let ia = wallPoint(pa, z: z, inset: depth, center: center), ib = wallPoint(pb, z: z, inset: depth, center: center)
            m.quad(oa, ob, ib, ia, color: color, material: .painted)                         // 腹板
            let na = wallInward(pa), nb = wallInward(pb)
            m.quad(ia - dz, ib - dz, ib + dz, ia + dz, normals: (na, nb, nb, na), color: color, material: .painted)
            for side in [-dz, dz] {                                                           // 内缘的两条边
                m.quad(ia + side, ib + side, ib + side - nb * 0.01, ia + side - na * 0.01, color: color, material: .painted)
            }
        }
    }

    // MARK: 地板和跳板

    private static func floorStrips(_ m: inout MeshBuilder, x0: Float, x1: Float, z0: Float, z1: Float, y: Float,
                                    steps: Int, color: SIMD3<Float>, material: MeshMaterial) {
        let up = SIMD3<Float>(0, 1, 0)
        for i in 0..<steps {
            let za = z0 + (z1 - z0) * Float(i) / Float(steps), zb = z0 + (z1 - z0) * Float(i + 1) / Float(steps)
            m.quad(SIMD3(x0, y, za), SIMD3(x1, y, za), SIMD3(x1, y, zb), SIMD3(x0, y, zb), normals: (up, up, up, up),
                   color: color, material: material)
        }
    }

    private static func cabinFloor(_ m: inout MeshBuilder) {
        // 地板：防滑涂层，拼缝、螺钉、系留环的凹坑在 shader 里按位置画（和下面系留环的位置一样）
        floorStrips(&m, x0: -1.4, x1: 1.4, z0: rampHinge, z1: 8, y: 0, steps: 25,
                    color: SIMD3(0.075, 0.078, 0.082), material: .tread)
        // 两条滚轮轨道：槽钢 + 每 0.2 米一个铝滚轮
        for x: Float in [-0.55, 0.55] {
            let channel = SIMD3<Float>(0.16, 0.165, 0.17)
            for s: Float in [-1, 1] {
                m.box(SIMD3(x + s * 0.05 - 0.006, 0, rampHinge + 0.12), SIMD3(x + s * 0.05 + 0.006, 0.042, 7.85),
                      color: channel, material: .painted)
            }
            m.box(SIMD3(x - 0.044, 0, rampHinge + 0.12), SIMD3(x + 0.044, 0.005, 7.85),
                  color: SIMD3(0.03, 0.03, 0.032), material: .painted)
            var z = rampHinge + 0.22
            while z < 7.8 {
                m.cylinder(SIMD3(x - 0.04, 0.027, z), SIMD3(x + 0.04, 0.027, z), radius: 0.021, segments: 10,
                           color: SIMD3(0.62, 0.63, 0.64), material: .aluminum)
                z += 0.2
            }
        }
        // 系留环：每 0.5 米一排，左中右三个，平躺在凹坑里（凹坑在 shader 里画）
        for k in 0..<25 {
            for x: Float in [-1, 0, 1] { tieDown(&m, x: x, z: -4.2 + 0.5 * Float(k)) }
        }
    }

    private static func tieDown(_ m: inout MeshBuilder, x: Float, z: Float) {
        m.torus(center: SIMD3(x, 0.004, z + 0.004), axis: normalize(SIMD3(0, 1, 0.14)), major: 0.028, minor: 0.0045,
                segments: 12, sides: 5, color: SIMD3(0.5, 0.5, 0.52), material: .aluminum)
    }

    private static func cabinRamp(_ m: inout MeshBuilder) {
        // 跳板：防滑棱和尾端的黄黑警示条在 shader 里画
        floorStrips(&m, x0: -1.3, x1: 1.3, z0: rampEnd, z1: rampHinge, y: 0, steps: 6,
                    color: SIMD3(0.085, 0.088, 0.092), material: .tread)
        // 跳板的厚度：两侧和底面喷漆，尾端的立面刷黄黑警示条
        let paint = SIMD3<Float>(0.22, 0.235, 0.235)
        for s: Float in [-1, 1] {
            m.quad(SIMD3(s * 1.3, -0.15, rampEnd), SIMD3(s * 1.3, -0.15, rampHinge), SIMD3(s * 1.3, 0, rampHinge),
                   SIMD3(s * 1.3, 0, rampEnd), color: paint, material: .painted)
        }
        m.quad(SIMD3(-1.3, -0.15, rampEnd), SIMD3(1.3, -0.15, rampEnd), SIMD3(1.3, -0.15, rampHinge),
               SIMD3(-1.3, -0.15, rampHinge), color: paint, material: .painted)
        m.quad(SIMD3(-1.3, -0.15, rampEnd), SIMD3(1.3, -0.15, rampEnd), SIMD3(1.3, 0, rampEnd), SIMD3(-1.3, 0, rampEnd),
               color: SIMD3(0.6, 0.42, 0.02), material: .hazard)
        // 两侧的路沿：深灰，顶上一道黄线
        for x: Float in [-1.3, 1.2] {
            m.box(SIMD3(x, 0, rampEnd + 0.02), SIMD3(x + 0.1, 0.1, rampHinge), color: SIMD3(0.12, 0.125, 0.13), material: .painted)
            m.box(SIMD3(x - 0.002, 0.1, rampEnd + 0.02), SIMD3(x + 0.102, 0.106, rampHinge),
                  color: SIMD3(0.55, 0.38, 0.02), material: .painted)
        }
        // 铰链：一节节的钢套筒，上面露出一点
        var path: [SIMD3<Float>] = [], radii: [Float] = []
        var x: Float = -1.3
        var thick = true
        while x < 1.3 - 1e-3 {
            let next = min(x + (thick ? 0.2 : 0.06), 1.3)
            let r: Float = thick ? 0.042 : 0.032
            path += [SIMD3(x, -0.027, rampHinge), SIMD3(next, -0.027, rampHinge)]
            radii += [r, r]
            x = next
            thick.toggle()
        }
        m.tube(path, radii: radii, segments: 14, color: SIMD3(0.42, 0.43, 0.44), material: .aluminum)
        // 跳板上的系留环
        for z: Float in [-7.3, -6.3, -5.3] {
            for x: Float in [-1, 1] { tieDown(&m, x: x, z: z) }
        }
        // 液压作动筒：从舱壁上的支架斜着下到跳板两侧的路沿（外筒喷漆，活塞杆镀铬）
        for s: Float in [-1, 1] {
            let top = SIMD3<Float>(s * 1.40, 0.98, rampHinge + 0.24)
            let bottom = SIMD3<Float>(s * 1.25, 0.17, -6.3)
            let d = normalize(bottom - top)
            let split = top + (bottom - top) * 0.52
            m.cylinder(top - d * 0.04, split, radius: 0.05, segments: 16, color: SIMD3(0.2, 0.21, 0.21), material: .painted)
            m.cylinder(split - d * 0.03, split + d * 0.02, radius: 0.056, segments: 16,
                       color: SIMD3(0.16, 0.17, 0.17), material: .painted)
            m.cylinder(split, bottom, radius: 0.022, segments: 12, color: SIMD3(0.85, 0.86, 0.88), material: .aluminum)
            // 液压管：从外筒两头接到舱壁
            m.tube([top + d * 0.1 + SIMD3(s * 0.05, 0.02, 0), top + SIMD3(s * 0.22, 0.25, 0.1),
                    wallPoint(s > 0 ? wallAngle(1.5) : 2 * .pi - wallAngle(1.5), z: rampHinge + 0.3, inset: 0.05)],
                   radii: [0.009, 0.009, 0.009], segments: 8, color: SIMD3(0.05, 0.05, 0.05), material: .painted)
            // 上面的支架（从舱壁伸出来）和耳环
            let wallX = s * 1.73
            m.box(SIMD3(min(top.x, wallX), top.y - 0.06, top.z - 0.05), SIMD3(max(top.x, wallX), top.y + 0.06, top.z + 0.05),
                  color: SIMD3(0.24, 0.26, 0.24), material: .painted)
            m.cylinder(top - SIMD3(0, 0, 0.065), top + SIMD3(0, 0, 0.065), radius: 0.03, segments: 12,
                       color: SIMD3(0.5, 0.5, 0.52), material: .aluminum)
            // 下面路沿上的耳座
            m.box(SIMD3(s * 1.25 - 0.045, 0.1, -6.36), SIMD3(s * 1.25 + 0.045, 0.19, -6.24),
                  color: SIMD3(0.24, 0.26, 0.24), material: .painted)
            m.cylinder(bottom - SIMD3(0.06, 0, 0), bottom + SIMD3(0.06, 0, 0), radius: 0.016, segments: 10,
                       color: SIMD3(0.5, 0.5, 0.52), material: .aluminum)
        }
        // 收在尾段顶上的上舱门：底面喷漆，下面一道道纵向加强筋，靠机头那头是铰链
        let doorPaint = SIMD3<Float>(0.24, 0.26, 0.25)
        let y0 = upperDoorBottom
        m.box(SIMD3(-0.9, y0, -7.6), SIMD3(0.9, y0 + 0.1, -4.7), color: doorPaint, material: .painted)
        for x in stride(from: Float(-0.76), through: 0.76, by: 0.38) {
            m.box(SIMD3(x - 0.012, y0 - 0.035, -7.55), SIMD3(x + 0.012, y0, -4.75), color: doorPaint, material: .painted)
        }
        m.box(SIMD3(-0.9, y0 - 0.035, -7.6), SIMD3(0.9, y0, -7.55), color: doorPaint, material: .painted)
        m.cylinder(SIMD3(-0.85, y0 + 0.04, -4.68), SIMD3(0.85, y0 + 0.04, -4.68), radius: 0.035, segments: 12,
                   color: SIMD3(0.42, 0.43, 0.44), material: .aluminum)
    }

    // MARK: 座椅

    /// 两侧的红色帆布座椅：编织带的座面和靠背（花纹在 shader 里），铝管架，靠背的吊带拉到舱壁上
    private static func cabinSeats(_ m: inout MeshBuilder) {
        let red = SIMD3<Float>(0.40, 0.045, 0.035)
        let tubeColor = SIMD3<Float>(0.52, 0.54, 0.56)
        let z0: Float = -2.4, z1: Float = 7.5
        let alongZ = { (x: Float, y: Float) -> [SIMD3<Float>] in
            (0...10).map { SIMD3(x, y, z0 + (z1 - z0) * Float($0) / 10) }
        }
        for s: Float in [-1, 1] {
            let back = s * 1.64, edge = s * 1.24
            for i in 0..<10 {
                let za = z0 + (z1 - z0) * Float(i) / 10, zb = z0 + (z1 - z0) * Float(i + 1) / 10
                // 座面：中间往下垂一点
                for k in 0..<4 {
                    let ta = Float(k) / 4, tb = Float(k + 1) / 4
                    let xa = edge + (back - edge) * ta, xb = edge + (back - edge) * tb
                    let ya = 0.45 - 0.018 * sin(.pi * ta), yb = 0.45 - 0.018 * sin(.pi * tb)
                    m.quad(SIMD3(xa, ya, za), SIMD3(xb, yb, za), SIMD3(xb, yb, zb), SIMD3(xa, ya, zb),
                           color: red, material: .seat)
                }
                // 靠背
                m.quad(SIMD3(back, 0.5, za), SIMD3(back, 0.5, zb), SIMD3(back, 1.35, zb), SIMD3(back, 1.35, za),
                       color: red, material: .seat)
            }
            // 管架：座面前沿、后沿，靠背顶上，下面一根纵管
            for (x, y, r) in [(edge, Float(0.44), Float(0.014)), (s * 1.625, 0.455, 0.012),
                              (back + s * 0.008, 1.36, 0.013), (s * 1.2, 0.09, 0.011)] {
                let path = alongZ(x, y)
                m.tube(path, radii: [Float](repeating: r, count: path.count), segments: 10,
                       color: tubeColor, material: .aluminum)
            }
            // 每隔一个加强框：一副腿（带斜撑）、一根靠背吊带拉到舱壁
            for (k, frame) in frameZ.enumerated() where k % 2 == 0 && frame > z0 + 0.2 && frame < z1 {
                let z = frame + 0.06
                m.cylinder(SIMD3(edge, 0.44, z), SIMD3(s * 1.19, 0.005, z), radius: 0.013, segments: 8,
                           color: tubeColor, material: .aluminum)
                m.cylinder(SIMD3(s * 1.2, 0.09, z), SIMD3(s * 1.6, 0.44, z), radius: 0.01, segments: 8,
                           color: tubeColor, material: .aluminum)
                m.box(SIMD3(s * 1.19 - 0.03, 0, z - 0.03), SIMD3(s * 1.19 + 0.03, 0.008, z + 0.03),
                      color: SIMD3(0.3, 0.31, 0.32), material: .aluminum)
                // 吊带
                let phi = s > 0 ? wallAngle(1.98) : 2 * .pi - wallAngle(1.98)
                let top = wallPoint(phi, z: z, inset: 0.03)
                let bottom = SIMD3<Float>(back + s * 0.012, 1.36, z)
                let w = SIMD3<Float>(0, 0, 0.018)
                m.quad(bottom - w, bottom + w, top + w, top - w, color: SIMD3(0.36, 0.04, 0.03), material: .seat)
                let mid = bottom + (top - bottom) * 0.45
                let along = normalize(top - bottom)
                m.orientedBox(center: mid, SIMD3(0, 0, 0.024), along * 0.02, normalize(cross(along, SIMD3(0, 0, 1))) * 0.006,
                              color: SIMD3(0.55, 0.56, 0.58), material: .aluminum)
            }
        }
    }

    // MARK: 舱顶

    private static func cabinCeiling(_ m: inout MeshBuilder) {
        // 开伞拉绳用的钢索（一边一根），每隔四个框一个吊架，机头那头一个花篮螺丝
        let steel = SIMD3<Float>(0.6, 0.6, 0.62)
        for x: Float in [-0.55, 0.55] {
            let path = stride(from: Float(-4.35), through: 7.65, by: 1.0).map { SIMD3(x, 2.45, $0) }
            m.tube(path, radii: [Float](repeating: 0.0055, count: path.count), segments: 8,
                   color: steel, material: .aluminum)
            for (k, z) in frameZ.enumerated() where k % 4 == 1 {
                m.cylinder(SIMD3(x, 2.45, z + 0.05), SIMD3(x, 2.63, z + 0.05), radius: 0.01, segments: 8,
                           color: SIMD3(0.24, 0.26, 0.24), material: .painted)
                m.box(SIMD3(x - 0.018, 2.43, z + 0.02), SIMD3(x + 0.018, 2.47, z + 0.08),
                      color: SIMD3(0.3, 0.31, 0.32), material: .aluminum)
            }
            m.cylinder(SIMD3(x, 2.45, 7.55), SIMD3(x, 2.45, 7.97), radius: 0.012, segments: 10,
                       color: SIMD3(0.45, 0.45, 0.47), material: .aluminum)
        }
        // 两边舱顶的管线：液压管（铝）、氧气管（绿）、黄标的燃油管、黑色的电线套管；每个框一个卡箍
        let pipes: [(Float, Float, SIMD3<Float>, MeshMaterial)] = [
            (-0.035, 0.011, SIMD3(0.62, 0.63, 0.64), .aluminum),
            (0.0, 0.009, SIMD3(0.07, 0.2, 0.08), .painted),
            (0.035, 0.011, SIMD3(0.5, 0.36, 0.03), .painted),
            (0.085, 0.019, SIMD3(0.025, 0.025, 0.027), .painted),
        ]
        for s: Float in [-1, 1] {
            let base: Float = .pi - s * 0.62
            for (offset, r, color, material) in pipes {
                let phi = base - s * offset
                let path = stride(from: Float(-4.4), through: 7.95, by: 1.0).map { wallPoint(phi, z: $0, inset: 0.13) }
                m.tube(path, radii: [Float](repeating: r, count: path.count), segments: 8, color: color, material: material)
            }
            for z in frameZ {
                let phi = base - s * 0.025
                let c = wallPoint(phi, z: z + 0.04, inset: 0.13)
                let tangent = SIMD3<Float>(cos(phi), sin(phi), 0)
                m.orientedBox(center: c, tangent * 0.085, wallInward(phi) * 0.024, SIMD3(0, 0, 0.01),
                              color: SIMD3(0.2, 0.21, 0.2), material: .painted)
            }
        }
        // 夜灯：灯座 + 红色灯罩
        for z in lampZ {
            m.box(SIMD3(-0.22, lampY + 0.015, z - 0.07), SIMD3(0.22, 2.78, z + 0.07),
                  color: SIMD3(0.12, 0.125, 0.13), material: .painted)
            m.box(SIMD3(-0.18, lampY, z - 0.045), SIMD3(0.18, lampY + 0.016, z + 0.045),
                  color: SIMD3(0.35, 0.02, 0.012), material: .emissive)
        }
    }

    // MARK: 门窗

    private static func cabinDoorsAndWindows(_ m: inout MeshBuilder) {
        let doorPaint = SIMD3<Float>(0.21, 0.23, 0.215)
        let frameColor = SIMD3<Float>(0.24, 0.26, 0.24)
        for s: Float in [-1, 1] {
            let side = { (phi: Float) -> Float in s > 0 ? phi : 2 * .pi - phi }
            let (a0, a1) = (side(doorAngles.0), side(doorAngles.1))
            // 伞兵门：贴着舱壁往里 3 厘米的一块弧形门板，上下两道门框
            m.shell(z0: doorZ.0 + 0.03, z1: doorZ.1 - 0.03, zSteps: 2, segments: 14, center: { _ in fuselageCenter },
                    radius: { _ in fuselageRadius - 0.03 }, angles: { _ in (min(a0, a1), max(a0, a1)) },
                    color: doorPaint, material: .painted)
            for phi in [a0, a1] {
                m.cylinder(wallPoint(phi, z: doorZ.0, inset: 0.04), wallPoint(phi, z: doorZ.1, inset: 0.04),
                           radius: 0.028, segments: 10, color: frameColor, material: .painted)
            }
            // 门上的小窗、门把手（一根横杆）
            let mid = (doorZ.0 + doorZ.1) / 2
            let wphi = side(wallAngle(1.32))
            window(&m, center: wallPoint(wphi, z: mid, inset: 0.035), normal: wallInward(wphi), radius: 0.1)
            let hphi = side(wallAngle(1.0))
            let h0 = wallPoint(hphi, z: mid + 0.18, inset: 0.09), h1 = wallPoint(hphi, z: mid + 0.42, inset: 0.09)
            m.cylinder(h0, h1, radius: 0.014, segments: 10, color: SIMD3(0.55, 0.56, 0.58), material: .aluminum)
            for p in [h0, h1] {
                m.cylinder(p, p + (wallPoint(hphi, z: p.z, inset: 0.03) - p), radius: 0.01, segments: 8,
                           color: SIMD3(0.55, 0.56, 0.58), material: .aluminum)
            }
            // 舷窗
            for z in windowZ {
                let phi = side(wallAngle(windowY))
                window(&m, center: wallPoint(phi, z: z, inset: 0.012), normal: wallInward(phi), radius: 0.12)
            }
        }
    }

    /// 圆舷窗：玻璃 + 一圈黑色橡胶的窗框
    private static func window(_ m: inout MeshBuilder, center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float) {
        m.disc(center: center, normal: normal, radius: radius, segments: 28, color: SIMD3(1, 1, 1), material: .window)
        m.torus(center: center + normal * 0.004, axis: normal, major: radius + 0.016, minor: 0.02, segments: 28, sides: 8,
                color: SIMD3(0.045, 0.047, 0.05), material: .painted)
    }

    // MARK: 前端隔板

    private static func cabinBulkhead(_ m: inout MeshBuilder) {
        let yc = fuselageCenter, R = fuselageRadius
        let floorAngle = acos(yc / R)
        let insulation = SIMD3<Float>(0.25, 0.275, 0.23)
        let n = SIMD3<Float>(0, 0, -1)
        let steps = 32
        for k in 0..<steps {
            let a0 = floorAngle + (2 * .pi - 2 * floorAngle) * Float(k) / Float(steps)
            let a1 = floorAngle + (2 * .pi - 2 * floorAngle) * Float(k + 1) / Float(steps)
            m.vertex(SIMD3(0, yc, 8), n, insulation, .quilt)
            m.vertex(SIMD3(R * sin(a0), yc - R * cos(a0), 8), n, insulation, .quilt)
            m.vertex(SIMD3(R * sin(a1), yc - R * cos(a1), 8), n, insulation, .quilt)
        }
        m.vertex(SIMD3(0, yc, 8), n, insulation, .quilt)
        m.vertex(SIMD3(-R * sin(floorAngle), 0, 8), n, insulation, .quilt)
        m.vertex(SIMD3(R * sin(floorAngle), 0, 8), n, insulation, .quilt)
        // 去驾驶舱的门：门板、门框、小窗（里面是暗的驾驶舱）、门把手
        let paint = SIMD3<Float>(0.22, 0.235, 0.22)
        m.box(SIMD3(-0.42, 0.01, 7.955), SIMD3(0.42, 1.95, 7.99), color: paint, material: .painted)
        m.tube([SIMD3(-0.45, 0, 7.95), SIMD3(-0.45, 1.98, 7.95), SIMD3(0.45, 1.98, 7.95), SIMD3(0.45, 0, 7.95)],
               radii: [0.025, 0.025, 0.025, 0.025], segments: 8, color: SIMD3(0.2, 0.21, 0.2), material: .painted)
        m.disc(center: SIMD3(0, 1.5, 7.952), normal: n, radius: 0.09, segments: 24, color: SIMD3(0.012, 0.012, 0.014),
               material: .aluminum)
        m.torus(center: SIMD3(0, 1.5, 7.95), axis: n, major: 0.1, minor: 0.014, segments: 24, sides: 6,
                color: SIMD3(0.045, 0.047, 0.05), material: .painted)
        m.cylinder(SIMD3(0.3, 1.0, 7.9), SIMD3(0.3, 1.0, 7.955), radius: 0.012, segments: 8,
                   color: SIMD3(0.55, 0.56, 0.58), material: .aluminum)
        m.cylinder(SIMD3(0.3, 1.0, 7.9), SIMD3(0.18, 1.0, 7.9), radius: 0.012, segments: 8,
                   color: SIMD3(0.55, 0.56, 0.58), material: .aluminum)
        // 两个红色灭火器：瓶身、瓶头、黑色喷管、卡箍
        for x: Float in [-1.0, 1.0] {
            let c = SIMD3<Float>(x, 0.0, 7.86)
            m.cylinder(c + SIMD3(0, 0.55, 0), c + SIMD3(0, 0.98, 0), radius: 0.07, segments: 18,
                       color: SIMD3(0.42, 0.025, 0.018), material: .painted)
            m.cylinder(c + SIMD3(0, 0.98, 0), c + SIMD3(0, 1.04, 0), radius: 0.025, segments: 10,
                       color: SIMD3(0.06, 0.06, 0.065), material: .painted)
            m.tube([c + SIMD3(0.02, 1.02, 0), c + SIMD3(0.1, 1.02, -0.03), c + SIMD3(0.1, 0.8, -0.075),
                    c + SIMD3(0.09, 0.62, -0.075)], radii: [0.008, 0.008, 0.008, 0.01], segments: 8,
                   color: SIMD3(0.03, 0.03, 0.032), material: .painted)
            for y: Float in [0.66, 0.9] {
                m.torus(center: c + SIMD3(0, y, 0), axis: SIMD3(0, 1, 0), major: 0.072, minor: 0.006, segments: 18,
                        sides: 5, color: SIMD3(0.5, 0.5, 0.52), material: .aluminum)
            }
            m.box(SIMD3(x - 0.04, 0.6, 7.93), SIMD3(x + 0.04, 0.95, 7.955), color: SIMD3(0.2, 0.21, 0.2), material: .painted)
        }
    }

    // MARK: 跳伞灯

    /// 伞兵门旁边各一组（舱壁上），跳板顶上一组（挂在收起来的上舱门下面，你一抬头就看到）：一红一绿两个圆灯
    private static func jumpLights(_ m: inout MeshBuilder) {
        let housing = SIMD3<Float>(0.03, 0.03, 0.032)
        let bezel = SIMD3<Float>(0.6, 0.6, 0.62)
        for s: Float in [-1, 1] {
            // 放在舱壁最鼓的那一段（再往上舱壁往里弯，灯箱会埋进壁里）
            let wall = s * 1.70, face = s * 1.655
            let z0: Float = -2.98, z1: Float = -2.68
            m.box(SIMD3(min(wall, face), 1.05, z0), SIMD3(max(wall, face), 1.41, z1), color: housing, material: .painted)
            let n = SIMD3<Float>(-s, 0, 0)
            for (y, material, color) in [(Float(1.32), MeshMaterial.lampRed, SIMD3<Float>(0.7, 0.025, 0.012)),
                                         (1.14, .lampGreen, SIMD3(0.01, 0.55, 0.05))] {
                let c = SIMD3<Float>(face - s * 0.004, y, (z0 + z1) / 2)
                m.disc(center: c, normal: n, radius: 0.052, segments: 24, color: color, material: material)
                m.torus(center: c, axis: n, major: 0.058, minor: 0.007, segments: 24, sides: 6, color: bezel, material: .aluminum)
            }
        }
        let y0 = upperDoorBottom - 0.035
        m.box(SIMD3(-0.32, y0 - 0.2, -6.75), SIMD3(0.32, y0, -6.62), color: housing, material: .painted)
        let n = SIMD3<Float>(0, 0, 1)
        for (x, material, color) in [(Float(-0.15), MeshMaterial.lampRed, SIMD3<Float>(0.7, 0.025, 0.012)),
                                     (0.15, .lampGreen, SIMD3(0.01, 0.55, 0.05))] {
            let c = SIMD3<Float>(x, y0 - 0.1, -6.615)
            m.disc(center: c, normal: n, radius: 0.07, segments: 28, color: color, material: material)
            m.torus(center: c, axis: n, major: 0.077, minor: 0.008, segments: 28, sides: 6, color: bezel, material: .aluminum)
        }
    }

    // MARK: 扶杆

    /// 舱门边的竖扶杆：喷黄漆的钢管（直径 38 毫米），中段半米长的黑色橡胶握把（一圈圈防滑棱、两头有挡圈），
    /// 上下两头是镀锌的套筒和法兰盘，四颗六角螺栓。开场在你的房间里只有它
    private static func bar(_ m: inout MeshBuilder, onLeft: Bool) {
        let x = barStage(onLeft: onLeft).x, z = barStage.y - Float(standOnRamp)
        let yellow = SIMD3<Float>(0.62, 0.42, 0.015)
        let rubber = SIMD3<Float>(0.045, 0.045, 0.047)
        let zinc = SIMD3<Float>(0.62, 0.63, 0.65)
        let top = upperDoorBottom
        let up = SIMD3<Float>(0, 1, 0)
        let at = { (y: Float) in SIMD3<Float>(x, y, z) }
        m.cylinder(at(0.085), at(top - 0.085), radius: 0.019, segments: 20, color: yellow, material: .bar, caps: false)
        // 握把：0.95 ~ 1.45 米（伸手正好握到的地方），每 12 毫米一道棱
        var path: [SIMD3<Float>] = [], radii: [Float] = []
        let g0: Float = 0.95, g1: Float = 1.45
        let ribs = Int(((g1 - g0) / 0.012).rounded())
        for i in 0...(ribs * 3) {
            let y = g0 + (g1 - g0) * Float(i) / Float(ribs * 3)
            path.append(at(y))
            radii.append(0.0232 + 0.0011 * (0.5 + 0.5 * cos(2 * .pi * Float(i) / 3)))
        }
        m.tube(path, radii: radii, segments: 20, color: rubber, material: .barGrip, caps: false)
        for y in [g0 - 0.012, g1] {
            m.tube([at(y), at(y), at(y + 0.012), at(y + 0.012)], radii: [0.019, 0.026, 0.026, 0.019], segments: 20,
                   color: rubber, material: .barGrip, caps: false)
        }
        // 上下两头：套筒 + 法兰盘 + 四颗螺栓（上面那个倒过来装在上舱门底下）
        for (base, dir) in [(Float(0), Float(1)), (top, Float(-1))] {
            let p = { (h: Float) in at(base + dir * h) }
            m.tube([p(0), p(0), p(0.012), p(0.012), p(0.012), p(0.085), p(0.085), p(0.085)],
                   radii: [0, 0.062, 0.062, 0.03, 0.027, 0.027, 0.027, 0.019], segments: 24,
                   color: zinc, material: .barMetal, caps: false)
            for k in 0..<4 {
                let a = Float.pi / 4 + Float(k) * .pi / 2
                let c = at(base + dir * 0.012) + SIMD3(cos(a), 0, sin(a)) * 0.044
                m.tube([c, c, c + up * dir * 0.007, c + up * dir * 0.007], radii: [0, 0.0085, 0.0085, 0], segments: 6,
                       color: zinc * 0.85, material: .barMetal, caps: false)
            }
            // 套筒上的顶丝
            let screw = at(base + dir * 0.05) + SIMD3(0.027, 0, 0)
            m.cylinder(screw, screw + SIMD3(0.006, 0, 0), radius: 0.0045, segments: 6, color: zinc * 0.7, material: .barMetal)
        }
    }

    // MARK: 外壳

    private static func exterior(_ m: inout MeshBuilder) {
        let yc = fuselageCenter, R = fuselageRadius
        let hull = SIMD3<Float>(0.34, 0.36, 0.36)
        let ro = R + 0.06
        m.shell(z0: rampHinge, z1: 13, zSteps: 20, segments: 32, center: { _ in yc }, radius: { _ in ro },
                angles: { _ in (0.001, 2 * .pi - 0.001) }, color: hull)
        // 机头：几圈越收越小
        let noseRings: [(Float, Float)] = [(13, ro), (14.2, ro * 0.9), (15.2, ro * 0.62), (15.8, ro * 0.25), (16.0, 0.02)]
        for i in 0..<(noseRings.count - 1) {
            let (za, ra) = noseRings[i], (zb, rb) = noseRings[i + 1]
            m.shell(z0: za, z1: zb, zSteps: 1, segments: 32, center: { _ in yc - 0.15 },
                    radius: { z in ra + (rb - ra) * (z - za) / (zb - za) },
                    angles: { _ in (0.001, 2 * .pi - 0.001) }, color: hull)
        }
        // 尾段外壳：往后越来越细、越来越高，下面是敞开的舱门
        m.shell(z0: -12.5, z1: rampHinge, zSteps: 8, segments: 18,
                center: { z in yc + (rampHinge - z) * 0.18 }, radius: { z in ro - (rampHinge - z) * 0.11 },
                angles: { _ in tailAngles }, color: hull)
        // 上单翼、四台发动机、平尾、垂尾
        m.box(SIMD3(-20.2, 2.78, 1.5), SIMD3(20.2, 3.12, 6.0), color: SIMD3(0.37, 0.39, 0.39))
        for x: Float in [-9.8, -5.0, 5.0, 9.8] {
            m.box(SIMD3(x - 0.55, 2.0, 2.8), SIMD3(x + 0.55, 3.0, 9.0), color: SIMD3(0.30, 0.31, 0.31))
            m.box(SIMD3(x - 0.12, 2.35, 9.0), SIMD3(x + 0.12, 2.65, 9.4), color: SIMD3(0.08, 0.08, 0.08))
        }
        m.box(SIMD3(-8.0, 3.35, -12.6), SIMD3(8.0, 3.55, -9.6), color: SIMD3(0.36, 0.38, 0.38))
        m.box(SIMD3(-0.16, 3.5, -12.9), SIMD3(0.16, 10.5, -9.0), color: SIMD3(0.36, 0.38, 0.38))
    }
}

func smoothstepF(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
