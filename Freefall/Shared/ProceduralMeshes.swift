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

    mutating func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, color: SIMD3<Float>, material: MeshMaterial = .diffuse) {
        let c = { (x: Float, y: Float, z: Float) in SIMD3<Float>(x, y, z) }
        quad(c(lo.x, lo.y, hi.z), c(hi.x, lo.y, hi.z), c(hi.x, hi.y, hi.z), c(lo.x, hi.y, hi.z), color: color, material: material)
        quad(c(hi.x, lo.y, lo.z), c(lo.x, lo.y, lo.z), c(lo.x, hi.y, lo.z), c(hi.x, hi.y, lo.z), color: color, material: material)
        quad(c(lo.x, lo.y, lo.z), c(lo.x, lo.y, hi.z), c(lo.x, hi.y, hi.z), c(lo.x, hi.y, lo.z), color: color, material: material)
        quad(c(hi.x, lo.y, hi.z), c(hi.x, lo.y, lo.z), c(hi.x, hi.y, lo.z), c(hi.x, hi.y, hi.z), color: color, material: material)
        quad(c(lo.x, hi.y, hi.z), c(hi.x, hi.y, hi.z), c(hi.x, hi.y, lo.z), c(lo.x, hi.y, lo.z), color: color, material: material)
        quad(c(lo.x, lo.y, lo.z), c(hi.x, lo.y, lo.z), c(hi.x, lo.y, hi.z), c(lo.x, lo.y, hi.z), color: color, material: material)
    }

    /// 机身截面上的一段壳：截面圆心 (0, center(z), z)、半径 radius(z)；角度 φ = 0 在圆的正下方，
    /// 按 (sin φ, -cos φ) 绕一圈；angles(z) 给出这一截保留的角度范围。
    mutating func shell(z0: Float, z1: Float, zSteps: Int, segments: Int,
                        center: (Float) -> Float, radius: (Float) -> Float,
                        angles: (Float) -> (Float, Float), color: SIMD3<Float>) {
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
                quad(p0, p1, p2, p3, normals: (n0, n1, n2, n3), color: color)
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
    /// 舱门边的竖扶杆（舞台坐标：你右手边 55 厘米、往前 25 厘米），抓住它游戏开始，松手就跳
    static let barStage = SIMD2<Float>(0.55, -0.25)
    static let barBottom: Float = 0.25, barTop: Float = 2.3

    /// 类似 C-130 的运输机。坐标：原点在你起跳时站的地板上；-Z 朝机尾（舱门、你面朝的方向），+Z 朝机头，y 向上。
    static func plane() -> [MeshVertex] {
        var m = MeshBuilder()
        let yc = fuselageCenter, R = fuselageRadius
        let floorAngle = acos(yc / R)                     // 地板和圆相交处的 φ

        // ---- 货舱内部（越往机头越暗，舱门附近照得到太阳）----
        m.interiorAt = { p in smoothstepF(-6.8, 1.5, p.z) }
        let insulation = SIMD3<Float>(0.26, 0.29, 0.24)   // 灰绿色的隔热垫
        let frame = SIMD3<Float>(0.17, 0.18, 0.17)
        m.shell(z0: rampHinge, z1: 8, zSteps: 25, segments: 28, center: { _ in yc }, radius: { _ in R },
                angles: { _ in (floorAngle, 2 * .pi - floorAngle) }, color: insulation)
        // 尾段：在跳板上方只剩上半截机身，往机尾越来越高；下面整个敞开（尾舱门放下了）
        let tailAngles: (Float) -> (Float, Float) = { _ in (0.6 * .pi, 1.4 * .pi) }
        m.shell(z0: -8.6, z1: rampHinge, zSteps: 6, segments: 18,
                center: { z in yc + (rampHinge - z) * 0.18 }, radius: { _ in R },
                angles: tailAngles, color: insulation)
        // 一圈圈的加强框
        var z: Float = -4.2
        while z < 7.8 {
            m.shell(z0: z - 0.035, z1: z + 0.035, zSteps: 1, segments: 28, center: { _ in yc },
                    radius: { _ in R - 0.07 }, angles: { _ in (floorAngle + 0.06, 2 * .pi - floorAngle - 0.06) },
                    color: frame)
            z += 0.55
        }
        // 地板、滚轮轨道、跳板
        m.box(SIMD3(-1.4, -0.12, rampHinge), SIMD3(1.4, 0, 8), color: SIMD3(0.10, 0.10, 0.11))
        for x: Float in [-0.55, 0.55] {
            m.box(SIMD3(x - 0.07, 0, rampHinge + 0.1), SIMD3(x + 0.07, 0.045, 7.8), color: SIMD3(0.30, 0.30, 0.31))
        }
        m.box(SIMD3(-1.3, -0.15, rampEnd), SIMD3(1.3, 0, rampHinge), color: SIMD3(0.20, 0.21, 0.22))
        for x: Float in [-1.3, 1.2] {
            m.box(SIMD3(x, 0, rampEnd + 0.1), SIMD3(x + 0.1, 0.12, rampHinge), color: SIMD3(0.14, 0.14, 0.15))
        }
        // 两侧的红色帆布座椅
        let red = SIMD3<Float>(0.40, 0.045, 0.035)
        for side: Float in [-1, 1] {
            let back = side * 1.66, edge = side * 1.24
            m.quad(SIMD3(back, 0.45, -3.6), SIMD3(back, 0.45, 7.5), SIMD3(back, 1.3, 7.5), SIMD3(back, 1.3, -3.6), color: red)
            m.quad(SIMD3(back, 0.45, -3.6), SIMD3(edge, 0.45, -3.6), SIMD3(edge, 0.45, 7.5), SIMD3(back, 0.45, 7.5), color: red)
            // 座椅的管子：前沿一根横管
            m.box(SIMD3(min(edge, edge + side * 0.04), 0.42, -3.6), SIMD3(max(edge, edge + side * 0.04), 0.47, 7.5),
                  color: SIMD3(0.35, 0.36, 0.37))
            // 头顶的钢索（挂开伞拉绳用）
            m.box(SIMD3(side * 0.55 - 0.015, 2.5, -4.2), SIMD3(side * 0.55 + 0.015, 2.53, 7.6), color: SIMD3(0.4, 0.4, 0.42))
            // 舱门旁的跳伞灯：一块黑底板，上面一红一绿两个灯。放在眼睛高度：再往上舱壁往里弯，灯会埋进壁里
            let wall = side * 1.64
            let board = (min(wall, wall - side * 0.04), max(wall, wall - side * 0.04))
            let lamp = (min(wall - side * 0.04, wall - side * 0.09), max(wall - side * 0.04, wall - side * 0.09))
            m.box(SIMD3(board.0, 1.28, -4.05), SIMD3(board.1, 1.64, -3.75), color: SIMD3(0.03, 0.03, 0.03))
            m.box(SIMD3(lamp.0, 1.49, -4.0), SIMD3(lamp.1, 1.60, -3.8),
                  color: SIMD3(0.7, 0.025, 0.012), material: .lampRed)
            m.box(SIMD3(lamp.0, 1.32, -4.0), SIMD3(lamp.1, 1.43, -3.8),
                  color: SIMD3(0.01, 0.55, 0.05), material: .lampGreen)
        }
        // 顶上的红色夜灯
        var lz: Float = -2.5
        while lz < 7.5 {
            m.box(SIMD3(-0.25, 2.66, lz), SIMD3(0.25, 2.70, lz + 0.12), color: SIMD3(0.35, 0.02, 0.012), material: .emissive)
            lz += 2.6
        }
        // 前端隔板
        let bulkhead = SIMD3<Float>(0.18, 0.19, 0.18)
        let steps = 24
        for k in 0..<steps {
            let a0 = floorAngle + (2 * .pi - 2 * floorAngle) * Float(k) / Float(steps)
            let a1 = floorAngle + (2 * .pi - 2 * floorAngle) * Float(k + 1) / Float(steps)
            let p0 = SIMD3<Float>(R * sin(a0), yc - R * cos(a0), 8), p1 = SIMD3<Float>(R * sin(a1), yc - R * cos(a1), 8)
            let c = SIMD3<Float>(0, yc, 8)
            m.vertex(c, SIMD3(0, 0, -1), bulkhead, .diffuse)
            m.vertex(p0, SIMD3(0, 0, -1), bulkhead, .diffuse)
            m.vertex(p1, SIMD3(0, 0, -1), bulkhead, .diffuse)
        }
        let lFloor = SIMD3<Float>(-R * sin(floorAngle), 0, 8), rFloor = SIMD3<Float>(R * sin(floorAngle), 0, 8)
        m.vertex(SIMD3(0, yc, 8), SIMD3(0, 0, -1), bulkhead, .diffuse)
        m.vertex(lFloor, SIMD3(0, 0, -1), bulkhead, .diffuse)
        m.vertex(rFloor, SIMD3(0, 0, -1), bulkhead, .diffuse)
        // 收在顶上的上舱门
        m.box(SIMD3(-1.15, 2.55, -7.6), SIMD3(1.15, 2.62, -4.7), color: insulation)
        // 舱门边的黄色竖扶杆，和门口上方的一组跳伞灯（抓住扶杆变绿）
        let barX = barStage.x, barZ = barStage.y - Float(standOnRamp)
        m.box(SIMD3(barX - 0.02, barBottom - 0.25, barZ - 0.02), SIMD3(barX + 0.02, barTop + 0.3, barZ + 0.02),
              color: SIMD3(0.62, 0.48, 0.04))
        for y: Float in [barBottom - 0.25, barTop + 0.26] {
            m.box(SIMD3(barX - 0.05, y, barZ - 0.05), SIMD3(barX + 0.05, y + 0.04, barZ + 0.05), color: SIMD3(0.2, 0.2, 0.21))
        }
        m.box(SIMD3(-0.32, 2.3, -6.75), SIMD3(0.32, 2.52, -6.62), color: SIMD3(0.03, 0.03, 0.03))
        m.box(SIMD3(-0.25, 2.34, -6.62), SIMD3(-0.05, 2.48, -6.58), color: SIMD3(0.7, 0.025, 0.012), material: .lampRed)
        m.box(SIMD3(0.05, 2.34, -6.62), SIMD3(0.25, 2.48, -6.58), color: SIMD3(0.01, 0.55, 0.05), material: .lampGreen)

        // ---- 外壳（出舱以后回头看到的飞机）----
        m.interiorAt = { _ in 0 }
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
                angles: tailAngles, color: hull)
        // 上单翼、四台发动机、平尾、垂尾
        m.box(SIMD3(-20.2, 2.78, 1.5), SIMD3(20.2, 3.12, 6.0), color: SIMD3(0.37, 0.39, 0.39))
        for x: Float in [-9.8, -5.0, 5.0, 9.8] {
            m.box(SIMD3(x - 0.55, 2.0, 2.8), SIMD3(x + 0.55, 3.0, 9.0), color: SIMD3(0.30, 0.31, 0.31))
            m.box(SIMD3(x - 0.12, 2.35, 9.0), SIMD3(x + 0.12, 2.65, 9.4), color: SIMD3(0.08, 0.08, 0.08))
        }
        m.box(SIMD3(-8.0, 3.35, -12.6), SIMD3(8.0, 3.55, -9.6), color: SIMD3(0.36, 0.38, 0.38))
        m.box(SIMD3(-0.16, 3.5, -12.9), SIMD3(0.16, 10.5, -9.0), color: SIMD3(0.36, 0.38, 0.38))
        return m.vertices
    }
}

func smoothstepF(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}
