import Foundation
import simd

/// 跳伞装备的网格：背带（主承重带、胸带和卡扣、3 环释放装置）、开伞拉手（软枕头 + 钢索 + 软管）、
/// 伸缩带和连接环、操纵绳导向环、操纵环、滑块的金属扣眼、手表（表壳、表圈、表带）。
/// 都是程序生成的光滑网格，尺寸照真的装备（之前是一段段胶囊拼的，近看棱角很明显）。
/// 不动的部分（背带、3 环、伸缩带）只算一次（身体坐标），每帧平移到身体的位置；跟着手、伞走的每帧重建。
///
/// 身体坐标：原点是眼睛（BodyLayout.anchor），-Z 朝前，+X 朝右。躯干微微前倾，胸口前表面在眼睛前方 6 ~ 10 厘米。
enum Gear {
    // MARK: - 颜色

    static let webbing = SIMD3<Float>(0.022, 0.022, 0.025)      // 黑色尼龙织带
    static let metal = SIMD3<Float>(0.72, 0.72, 0.70)           // 不锈钢 / 镀镍
    static let handleRed = SIMD3<Float>(0.52, 0.035, 0.025)
    static let toggleYellow = SIMD3<Float>(0.80, 0.56, 0.03)
    static let housingBlack = SIMD3<Float>(0.03, 0.03, 0.032)
    static let lineWhite = SIMD3<Float>(0.72, 0.72, 0.69)       // 伞绳（HMA / Vectran，浅灰白）
    static let brakeOrange = SIMD3<Float>(0.78, 0.30, 0.04)

    // MARK: - 基本形状

    @inline(__always)
    static func vertex(_ out: inout [MeshVertex], _ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>,
                       _ color: SIMD3<Float>, _ material: MeshMaterial) {
        out.append(MeshVertex(position: SIMD4(p, uv.x), normal: SIMD4(n, uv.y), color: SIMD4(color, material.rawValue)))
    }

    /// 四边形（p0 p1 p2 p3 逆时针），各顶点自己的法线和 uv
    @inline(__always)
    static func quad(_ out: inout [MeshVertex], _ p: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
                     _ n: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
                     _ uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
                     _ color: SIMD3<Float>, _ material: MeshMaterial) {
        vertex(&out, p.0, n.0, uv.0, color, material); vertex(&out, p.1, n.1, uv.1, color, material)
        vertex(&out, p.2, n.2, uv.2, color, material)
        vertex(&out, p.0, n.0, uv.0, color, material); vertex(&out, p.2, n.2, uv.2, color, material)
        vertex(&out, p.3, n.3, uv.3, color, material)
    }

    /// 和 axis 垂直的两个单位向量
    static func basis(_ axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let helper: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let e1 = simd_normalize(simd_cross(axis, helper))
        return (e1, simd_cross(axis, e1))
    }

    /// 扁带：沿一串点走，每个点给出带子的宽度方向。截面是 width × thickness 的扁矩形（上下两面 + 两条边）。
    /// uv：u 沿带子长度（米），v 横过带子（米，-width/2 … width/2），shader 拿来画编织纹和包边。
    static func ribbon(_ out: inout [MeshVertex], points: [SIMD3<Float>], across: [SIMD3<Float>],
                       width: Float, thickness: Float, color: SIMD3<Float>, material: MeshMaterial = .webbing,
                       closed: Bool = false) {
        let n = points.count
        guard n >= 2 else { return }
        var u: [Float] = [0]
        for i in 1..<n { u.append(u[i - 1] + simd_length(points[i] - points[i - 1])) }
        func frame(_ i: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let next = closed ? points[(i + 1) % n] : points[min(i + 1, n - 1)]
            let prev = closed ? points[(i - 1 + n) % n] : points[max(i - 1, 0)]
            let tangent = simd_normalize(next - prev)
            var w = across[i] - simd_dot(across[i], tangent) * tangent
            w = simd_normalize(w)
            return (w, simd_cross(tangent, w))
        }
        let hw = width / 2, ht = thickness / 2
        let segments = closed ? n : n - 1
        let total = u[n - 1] + (closed ? simd_length(points[0] - points[n - 1]) : 0)
        for i in 0..<segments {
            let j = (i + 1) % n
            let (w0, t0) = frame(i), (w1, t1) = frame(j)
            let p0 = points[i], p1 = points[j]
            let u0 = u[i], u1 = j == 0 ? total : u[j]
            quad(&out, (p0 - w0 * hw + t0 * ht, p0 + w0 * hw + t0 * ht, p1 + w1 * hw + t1 * ht, p1 - w1 * hw + t1 * ht),
                 (t0, t0, t1, t1), (SIMD2(u0, -hw), SIMD2(u0, hw), SIMD2(u1, hw), SIMD2(u1, -hw)), color, material)
            quad(&out, (p0 + w0 * hw - t0 * ht, p0 - w0 * hw - t0 * ht, p1 - w1 * hw - t1 * ht, p1 + w1 * hw - t1 * ht),
                 (-t0, -t0, -t1, -t1), (SIMD2(u0, hw), SIMD2(u0, -hw), SIMD2(u1, -hw), SIMD2(u1, hw)), color, material)
            // 两条边：法线在宽度方向，稍微往上下偏一点，边看起来是圆的
            for side: Float in [-1, 1] {
                let a0 = p0 + w0 * (hw * side), a1 = p1 + w1 * (hw * side)
                let n0 = simd_normalize(w0 * side), n1 = simd_normalize(w1 * side)
                quad(&out, (a0 - t0 * ht, a0 + t0 * ht, a1 + t1 * ht, a1 - t1 * ht),
                     (simd_normalize(n0 - t0 * 0.6), simd_normalize(n0 + t0 * 0.6),
                      simd_normalize(n1 + t1 * 0.6), simd_normalize(n1 - t1 * 0.6)),
                     (SIMD2(u0, hw * side), SIMD2(u0, hw * side), SIMD2(u1, hw * side), SIMD2(u1, hw * side)),
                     color, material)
            }
        }
    }

    /// 圆管：沿一串点走（平行移动标架，不扭），sides 边
    static func tube(_ out: inout [MeshVertex], points: [SIMD3<Float>], radius: Float, color: SIMD3<Float>,
                     material: MeshMaterial, sides: Int = 10) {
        let n = points.count
        guard n >= 2 else { return }
        var frames: [(SIMD3<Float>, SIMD3<Float>)] = []
        var tangent = simd_normalize(points[1] - points[0])
        var (e1, _) = basis(tangent)
        for i in 0..<n {
            let t = simd_normalize(points[min(i + 1, n - 1)] - points[max(i - 1, 0)])
            // 把上一个标架转到新的切线上
            e1 = simd_normalize(e1 - simd_dot(e1, t) * t)
            tangent = t
            frames.append((e1, simd_cross(tangent, e1)))
        }
        var u: Float = 0
        for i in 0..<(n - 1) {
            let du = simd_length(points[i + 1] - points[i])
            for k in 0..<sides {
                let a0 = 2 * Float.pi * Float(k) / Float(sides), a1 = 2 * Float.pi * Float(k + 1) / Float(sides)
                func dir(_ f: (SIMD3<Float>, SIMD3<Float>), _ a: Float) -> SIMD3<Float> { f.0 * cos(a) + f.1 * sin(a) }
                let d00 = dir(frames[i], a0), d01 = dir(frames[i], a1), d10 = dir(frames[i + 1], a0), d11 = dir(frames[i + 1], a1)
                quad(&out, (points[i] + d00 * radius, points[i] + d01 * radius, points[i + 1] + d11 * radius,
                            points[i + 1] + d10 * radius),
                     (d00, d01, d11, d10),
                     (SIMD2(u, a0 * radius), SIMD2(u, a1 * radius), SIMD2(u + du, a1 * radius), SIMD2(u + du, a0 * radius)),
                     color, material)
            }
            u += du
        }
    }

    /// 圆环（金属环、扣眼）：环面法线 axis，椭圆的两个半径 (a, b)，管半径 r
    static func ring(_ out: inout [MeshVertex], center: SIMD3<Float>, axis: SIMD3<Float>, radii: SIMD2<Float>,
                     tube r: Float, color: SIMD3<Float>, material: MeshMaterial = .metal,
                     segments: Int = 24, sides: Int = 8, spin: SIMD3<Float>? = nil) {
        var (e1, e2) = basis(simd_normalize(axis))
        if let spin {
            e1 = simd_normalize(spin - simd_dot(spin, simd_normalize(axis)) * simd_normalize(axis))
            e2 = simd_cross(simd_normalize(axis), e1)
        }
        let ax = simd_normalize(axis)
        func point(_ i: Int, _ j: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let t = 2 * Float.pi * Float(i % segments) / Float(segments)
            let s = 2 * Float.pi * Float(j % sides) / Float(sides)
            let onRing = e1 * (cos(t) * radii.x) + e2 * (sin(t) * radii.y)
            let outward = simd_normalize(e1 * (cos(t) / radii.x) + e2 * (sin(t) / radii.y))
            let n = outward * cos(s) + ax * sin(s)
            return (center + onRing + n * r, n)
        }
        for i in 0..<segments {
            for j in 0..<sides {
                let (p00, n00) = point(i, j), (p10, n10) = point(i + 1, j)
                let (p11, n11) = point(i + 1, j + 1), (p01, n01) = point(i, j + 1)
                let uv = SIMD2<Float>(0, 0)
                quad(&out, (p00, p10, p11, p01), (n00, n10, n11, n01), (uv, uv, uv, uv), color, material)
            }
        }
    }

    @inline(__always)
    static func signedPow(_ x: Float, _ e: Float) -> Float { x < 0 ? -pow(-x, e) : pow(x, e) }

    /// 圆角的软枕头 / 圆角块（超椭球）：三个轴方向和半尺寸，exponent 越小越方（0.3 左右像缝出来的枕头）
    static func pillow(_ out: inout [MeshVertex], center: SIMD3<Float>, axes: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
                       half: SIMD3<Float>, exponent e: Float = 0.3, color: SIMD3<Float>, material: MeshMaterial,
                       segments: Int = 20, rings: Int = 10) {
        func point(_ i: Int, _ j: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD2<Float>) {
            let phi = -Float.pi + 2 * Float.pi * Float(i) / Float(segments)
            let theta = -Float.pi / 2 + Float.pi * Float(j) / Float(rings)
            let ct = cos(theta), st = sin(theta), cp = cos(phi), sp = sin(phi)
            let x = half.x * signedPow(ct, e) * signedPow(cp, e)
            let y = half.y * signedPow(ct, e) * signedPow(sp, e)
            let z = half.z * signedPow(st, e)
            var n = SIMD3<Float>(signedPow(ct, 2 - e) * signedPow(cp, 2 - e) / half.x,
                                 signedPow(ct, 2 - e) * signedPow(sp, 2 - e) / half.y,
                                 signedPow(st, 2 - e) / half.z)
            n = simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3(0, 0, st >= 0 ? 1 : -1)
            let p = center + axes.0 * x + axes.1 * y + axes.2 * z
            let nw = simd_normalize(axes.0 * n.x + axes.1 * n.y + axes.2 * n.z)
            // uv：大面上的平面坐标（米），织纹在正面、背面是直的（按绕一圈的弧长展开，顶上会汇成放射状）
            return (p, nw, SIMD2(x, y))
        }
        for i in 0..<segments {
            for j in 0..<rings {
                let a = point(i, j), b = point(i + 1, j), c = point(i + 1, j + 1), d = point(i, j + 1)
                quad(&out, (a.0, b.0, c.0, d.0), (a.1, b.1, c.1, d.1), (a.2, b.2, c.2, d.2), color, material)
            }
        }
    }

    /// 旋转体：沿 axis 的剖面 (半径, 高度) 绕一圈（表壳、表圈）
    static func lathe(_ out: inout [MeshVertex], base: SIMD3<Float>, axis: SIMD3<Float>, profile: [SIMD2<Float>],
                      color: SIMD3<Float>, material: MeshMaterial, segments: Int = 40) {
        let (e1, e2) = basis(axis)
        let m = profile.count
        func normal2D(_ j: Int) -> SIMD2<Float> {
            let a = profile[max(j - 1, 0)], b = profile[min(j + 1, m - 1)]
            let t = simd_normalize(b - a)
            return SIMD2(t.y, -t.x)       // 剖面往外的法线（半径方向, 高度方向）
        }
        for i in 0..<segments {
            let a0 = 2 * Float.pi * Float(i) / Float(segments), a1 = 2 * Float.pi * Float(i + 1) / Float(segments)
            let r0 = e1 * cos(a0) + e2 * sin(a0), r1 = e1 * cos(a1) + e2 * sin(a1)
            for j in 0..<(m - 1) {
                let p = profile[j], q = profile[j + 1]
                let np = normal2D(j), nq = normal2D(j + 1)
                let uv = SIMD2<Float>(0, 0)
                quad(&out, (base + r0 * p.x + axis * p.y, base + r1 * p.x + axis * p.y,
                            base + r1 * q.x + axis * q.y, base + r0 * q.x + axis * q.y),
                     (simd_normalize(r0 * np.x + axis * np.y), simd_normalize(r1 * np.x + axis * np.y),
                      simd_normalize(r1 * nq.x + axis * nq.y), simd_normalize(r0 * nq.x + axis * nq.y)),
                     (uv, uv, uv, uv), color, material)
            }
        }
    }

    /// 平滑的样条（Catmull-Rom），控制点之间各插 steps 段
    static func spline(_ c: [SIMD3<Float>], steps: Int) -> [SIMD3<Float>] {
        guard c.count >= 2 else { return c }
        var out: [SIMD3<Float>] = []
        for i in 0..<(c.count - 1) {
            let p0 = c[max(i - 1, 0)], p1 = c[i], p2 = c[i + 1], p3 = c[min(i + 2, c.count - 1)]
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                let t2 = t * t, t3 = t2 * t
                out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                                  + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
            }
        }
        out.append(c[c.count - 1])
        return out
    }

    // MARK: - 身上的背带（不动，身体坐标里算一次）

    /// 主承重带（左右各一条，从肩膀上方顺着胸口往下到胯）的控制点
    static func mainLiftWeb(_ side: Float) -> [SIMD3<Float>] {
        [SIMD3(0.13 * side, -0.16, 0.06), SIMD3(0.135 * side, -0.21, -0.02), SIMD3(0.127 * side, -0.30, -0.085),
         SIMD3(0.12 * side, -0.40, -0.115), SIMD3(0.117 * side, -0.50, -0.128), SIMD3(0.12 * side, -0.60, -0.122),
         SIMD3(0.127 * side, -0.72, -0.10)]
    }

    /// 3 环释放装置的位置（肩膀前面，伸缩带从这里接出来）
    static func threeRingPoint(_ side: Float) -> SIMD3<Float> { SIMD3(0.15 * side, -0.19, -0.015) }

    /// 开伞拉手平时的位置：右边主承重带上、胸口下面（BodyLayout.handleRest）
    static let handleRest = SIMD3<Float>(0.125, -0.50, -0.15)

    /// 钢索软管：从拉手上沿出来，贴着右边的主承重带往上，过 3 环旁边绕到肩后（伞包在背上）
    static let housingPath: [SIMD3<Float>] = spline([
        SIMD3(0.10, -0.476, -0.141), SIMD3(0.108, -0.43, -0.131), SIMD3(0.113, -0.36, -0.113),
        SIMD3(0.12, -0.28, -0.083), SIMD3(0.128, -0.21, -0.03), SIMD3(0.135, -0.17, 0.03),
    ], steps: 5)

    /// 背带：两条主承重带、胸带和卡扣（拉紧后多出来的一截垂在左边）、肩上的 3 环（大中小三个环套在一起）
    static let harness: [MeshVertex] = {
        var v: [MeshVertex] = []
        v.reserveCapacity(12000)
        for side: Float in [-1, 1] {
            let pts = spline(mainLiftWeb(side), steps: 4)
            ribbon(&v, points: pts, across: pts.map { _ in SIMD3(1, 0, 0) }, width: 0.044, thickness: 0.004,
                   color: webbing)
            // 3 环：大环套在背带的环扣上，中环、小环依次往上套
            let base = threeRingPoint(side)
            let forward = SIMD3<Float>(0.15 * side, 0.1, -1)
            ring(&v, center: base, axis: forward, radii: SIMD2(0.021, 0.021), tube: 0.0042, color: metal)
            ring(&v, center: base + SIMD3(0.003 * side, 0.024, -0.004), axis: forward, radii: SIMD2(0.013, 0.013),
                 tube: 0.0035, color: metal)
            ring(&v, center: base + SIMD3(0.005 * side, 0.040, -0.007), axis: forward, radii: SIMD2(0.0075, 0.0075),
                 tube: 0.003, color: metal)
        }
        // 胸带：横过胸口，稍微往前拱
        let chest = spline([SIMD3(-0.125, -0.345, -0.103), SIMD3(-0.06, -0.35, -0.114), SIMD3(0, -0.352, -0.118),
                            SIMD3(0.06, -0.35, -0.114), SIMD3(0.125, -0.345, -0.103)], steps: 4)
        ribbon(&v, points: chest, across: chest.map { _ in SIMD3(0, 1, 0) }, width: 0.038, thickness: 0.004,
               color: webbing)
        // 卡扣（摩擦调节扣）：一块圆角的金属，中间压着带子
        pillow(&v, center: SIMD3(-0.072, -0.35, -0.118), axes: (SIMD3(1, 0, -0.15), SIMD3(0, 1, 0), SIMD3(0.15, 0, 1)),
               half: SIMD3(0.012, 0.024, 0.005), exponent: 0.25, color: metal, material: .metal, segments: 16, rings: 8)
        // 拉紧以后多出来的那截：从卡扣往左下垂
        let tail = spline([SIMD3(-0.08, -0.35, -0.122), SIMD3(-0.108, -0.358, -0.121), SIMD3(-0.13, -0.39, -0.122),
                           SIMD3(-0.138, -0.44, -0.128)], steps: 4)
        ribbon(&v, points: tail, across: tail.map { _ in SIMD3(0, 0.3, 1) }, width: 0.036, thickness: 0.004,
               color: webbing)
        // 拉手的口袋：主承重带上缝的一块织带，拉手塞在里面（拉出来以后还在）
        pillow(&v, center: handleRest + SIMD3(0.002, -0.004, 0.013), axes: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
               half: SIMD3(0.047, 0.027, 0.0065), exponent: 0.22, color: webbing * 1.4, material: .webbing,
               segments: 20, rings: 8)
        // 钢索软管（黑色）：口上一圈金属箍
        tube(&v, points: housingPath, radius: 0.0045, color: housingBlack, material: .plastic, sides: 12)
        // 软管两头的金属箍
        let n = housingPath.count
        for (end, next) in [(housingPath[0], housingPath[1]), (housingPath[n - 1], housingPath[n - 2])] {
            let dir = simd_normalize(next - end)
            ring(&v, center: end + dir * 0.004, axis: dir, radii: SIMD2(0.0047, 0.0047), tube: 0.0016,
                 color: metal, segments: 14, sides: 6)
            lathe(&v, base: end - dir * 0.0005, axis: dir, profile: [SIMD2(0.0002, 0), SIMD2(0.0045, 0.0003)],
                  color: housingBlack, material: .plastic, segments: 12)
        }
        return v
    }()

    // MARK: - 伸缩带和连接环（开伞后才有，身体坐标）

    /// 连接环的位置：每边前后两个（A、B 排的伞绳挂在前面，C、D 排挂在后面）
    static func linkPoint(_ side: Float, front: Bool) -> SIMD3<Float> {
        SIMD3(0.205 * side, 0.38, front ? -0.10 : -0.02)
    }

    /// 伞绳汇到连接环的地方（环的上端）
    static func lineJoin(_ side: Float, front: Bool) -> SIMD3<Float> { linkPoint(side, front: front) + SIMD3(0, 0.026, 0) }

    /// 后伸缩带外侧的操纵绳导向环（环面水平，刹车绳竖着穿过去）
    static func guideRingPoint(_ side: Float) -> SIMD3<Float> { SIMD3(0.211 * side, 0.25, -0.02) }

    static let risers: [MeshVertex] = {
        var v: [MeshVertex] = []
        v.reserveCapacity(8000)
        for side: Float in [-1, 1] {
            // 伸缩带的根：一段双层织带，下端缝着中环（穿过背带上的大环），往上 7 厘米分成前后两根
            let rings = threeRingPoint(side)
            let root = [rings + SIMD3(0.003 * side, 0.02, -0.006), rings + SIMD3(0.004 * side, 0.045, -0.008),
                        rings + SIMD3(0.005 * side, 0.07, -0.008)]
            ribbon(&v, points: root, across: root.map { _ in SIMD3(0, 0, 1) }, width: 0.026, thickness: 0.007,
                   color: webbing)
            let base = rings + SIMD3(0.005 * side, 0.065, -0.008)
            for front in [true, false] {
                let top = linkPoint(side, front: front)
                let pts = spline([base + SIMD3(0, 0, front ? -0.006 : 0.006), base + SIMD3(0.012 * side, 0.06, front ? -0.02 : 0.008),
                                  base + SIMD3(0.025 * side, 0.15, front ? -0.04 : 0.002), top - SIMD3(0, 0.06, 0), top], steps: 4)
                // 伸缩带宽的一面朝里朝外（宽度方向是前后），从下面往上看是一条扁带
                ribbon(&v, points: pts, across: pts.map { _ in SIMD3(0, 0, 1) }, width: 0.025, thickness: 0.004,
                       color: webbing)
                // 连接环：竖着的椭圆金属环
                ring(&v, center: top + SIMD3(0, 0.012, 0), axis: SIMD3(1, 0, 0), radii: SIMD2(0.008, 0.016),
                     tube: 0.0028, color: metal, segments: 20, sides: 7, spin: SIMD3(0, 0, 1))
            }
            ring(&v, center: guideRingPoint(side), axis: SIMD3(0, 1, 0), radii: SIMD2(0.0075, 0.0075), tube: 0.0021,
                 color: metal, segments: 16, sides: 6)
            // 导向环缝在一小段织带上，织带缝在伸缩带外侧
            pillow(&v, center: guideRingPoint(side) - SIMD3(0.0085 * side, 0, 0), axes: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                   half: SIMD3(0.004, 0.009, 0.006), exponent: 0.3, color: webbing, material: .webbing, segments: 10, rings: 6)
        }
        return v
    }()

    /// 落地以后的伸缩带：没有伞拉着，从 3 环垂到胸前。返回左右两个连接环的位置（舞台空间），伞绳从这里拖到地上
    static func slackRisers(_ out: inout [MeshVertex], anchor: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        var ends: [SIMD3<Float>] = []
        for side: Float in [-1, 1] {
            let base = anchor + threeRingPoint(side) + SIMD3(0.005 * side, 0.03, -0.01)
            let end = anchor + SIMD3(0.17 * side, -0.36, -0.2)
            let pts = spline([base, base + SIMD3(0.02 * side, 0.05, -0.05), base + SIMD3(0.025 * side, -0.02, -0.14), end],
                             steps: 5)
            ribbon(&out, points: pts, across: pts.map { _ in SIMD3(1, 0, 0) }, width: 0.025, thickness: 0.008,
                   color: webbing)
            ring(&out, center: end + SIMD3(0, -0.012, 0), axis: SIMD3(1, 0, 0), radii: SIMD2(0.008, 0.016),
                 tube: 0.0028, color: metal, segments: 20, sides: 7, spin: SIMD3(0, 0, 1))
            ends.append(end + SIMD3(0, -0.026, 0))
        }
        return (ends[0], ends[1])
    }

    /// 身体坐标的网格平移到身体的位置，追加到 out
    static func append(_ mesh: [MeshVertex], at anchor: SIMD3<Float>, into out: inout [MeshVertex]) {
        let offset = SIMD4<Float>(anchor, 0)
        for v in mesh {
            var w = v
            w.position += offset
            out.append(w)
        }
    }

    // MARK: - 跟着手、伞走的（每帧）

    /// 开伞拉手：一个红色的软枕头（真的学员装备就是这种），背面连着钢索，钢索穿在软管里（软管是背带的一部分）。
    /// 拉出来以后钢索从软管口露出来一截。handle 是拉手现在的位置（舞台空间），anchor 是身体原点。
    static func handle(_ out: inout [MeshVertex], at handle: SIMD3<Float>, anchor: SIMD3<Float>, glow: Float) {
        let rest = anchor + handleRest
        let mouth = anchor + housingPath[0]
        if simd_length(handle - rest) > 0.008 {
            // 钢索：软管口 → 拉手背面，稍微往下垂一点
            let back = handle + SIMD3(-0.02, 0.012, 0.008)
            let mid = (mouth + back) * 0.5 + SIMD3(0, -0.006, 0)
            tube(&out, points: spline([mouth, mid, back], steps: 6), radius: 0.0012, color: metal,
                 material: .metal, sides: 6)
        }
        // 枕头：Cordura 布面，四周一圈压线（uv.v 接近上下边的地方，shader 里画不出来，用略深的颜色带过）
        pillow(&out, center: handle, axes: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)),
               half: SIMD3(0.04, 0.022, 0.012), exponent: 0.32, color: handleRed * glow, material: .webbing,
               segments: 28, rings: 14)
    }

    /// 操纵环：一圈硬挺的织带围成的椭圆环（黄色），顶上一小块黑色的布片，操纵绳拴在布片上。
    /// center 是手握的地方（环的中间），环面朝着人。返回操纵绳的拴点。
    @discardableResult
    static func toggle(_ out: inout [MeshVertex], center: SIMD3<Float>, toward anchor: SIMD3<Float>) -> SIMD3<Float> {
        var facing = SIMD3<Float>(anchor.x - center.x, 0, anchor.z - center.z)
        facing = simd_length(facing) > 1e-4 ? simd_normalize(facing) : SIMD3(0, 0, 1)
        let up = SIMD3<Float>(0, 1, 0)
        let lateral = simd_cross(up, facing)
        let n = 40
        var pts: [SIMD3<Float>] = [], across: [SIMD3<Float>] = []
        for i in 0..<n {
            let t = 2 * Float.pi * Float(i) / Float(n)
            // 上窄下宽的水滴形：高 9.5 厘米，宽 4.6 厘米
            let x = 0.023 * sin(t) * (0.82 + 0.18 * (1 - cos(t)) * 0.5)
            let y = 0.0475 * cos(t)
            pts.append(center + lateral * x + up * y)
            across.append(facing)
        }
        ribbon(&out, points: pts, across: across, width: 0.017, thickness: 0.006, color: toggleYellow,
               material: .webbing, closed: true)
        let top = center + up * 0.0475
        pillow(&out, center: top + up * 0.011, axes: (lateral, up, facing), half: SIMD3(0.011, 0.013, 0.0055),
               exponent: 0.3, color: SIMD3(0.025, 0.025, 0.028), material: .webbing, segments: 14, rings: 8)
        return top + up * 0.024
    }

    /// 滑块的扣眼（四个角的金属圈）和中间那块布：布面朝上微微鼓起
    static func slider(_ out: inout [MeshVertex], grommets g: [SIMD3<Float>]) {
        let normal = simd_normalize(simd_cross(g[1] - g[0], g[2] - g[0]))
        let up = normal.y >= 0 ? normal : -normal
        for p in g {
            ring(&out, center: p, axis: up, radii: SIMD2(0.019, 0.019), tube: 0.0055, color: metal,
                 segments: 18, sides: 7)
        }
        // 布：6 × 5 格，四边贴着扣眼连线，中间往上鼓 3 厘米
        let nx = 6, nz = 5
        func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let s = Float(i) / Float(nx), t = Float(j) / Float(nz)
            let a = g[0] + (g[1] - g[0]) * s, b = g[2] + (g[3] - g[2]) * s
            let bulge = 0.03 * sin(Float.pi * s) * sin(Float.pi * t)
            return a + (b - a) * t + up * bulge
        }
        let color = SIMD3<Float>(0.8, 0.8, 0.77)          // 白色尼龙（和伞衣的白色气室一样）
        for i in 0..<nx {
            for j in 0..<nz {
                let p00 = point(i, j), p10 = point(i + 1, j), p11 = point(i + 1, j + 1), p01 = point(i, j + 1)
                let n0 = simd_normalize(simd_cross(p10 - p00, p01 - p00))
                let nn = simd_dot(n0, up) >= 0 ? n0 : -n0
                let uv = { (x: Int, z: Int) in SIMD2<Float>(Float(x) * 0.12 + 0.2, Float(z) * 0.11 + 0.03) }
                quad(&out, (p00, p10, p11, p01), (nn, nn, nn, nn), (uv(i, j), uv(i + 1, j), uv(i + 1, j + 1), uv(i, j + 1)),
                     color, .fabric)
            }
        }
    }

    /// 手表：表带（一圈扁的橡胶带绕着手腕）+ 表壳（黑色，侧面微鼓）+ 金属表圈。表盘本身由 HUD pass 画在表壳顶上。
    static func watch(_ out: inout [MeshVertex], hand: HandPose) {
        let f = SceneObjects.wristFrame(hand)
        let n = 36
        var pts: [SIMD3<Float>] = [], across: [SIMD3<Float>] = []
        for i in 0..<n {
            let t = 2 * Float.pi * Float(i) / Float(n)
            pts.append(f.center + f.side * (0.037 * cos(t)) + f.back * (0.030 * sin(t)))
            across.append(f.towardElbow)
        }
        ribbon(&out, points: pts, across: across, width: 0.022, thickness: 0.0035,
               color: SIMD3(0.02, 0.02, 0.022), material: .rubber, closed: true)
        let (faceCenter, _, _, size) = SceneObjects.watchPlacement(hand)
        let axis = f.back
        let r = size / 2
        // 表壳剖面：从表带上起，侧面微鼓，顶上收进表圈（表盘在最上面那一圈里面，比表圈低一点点）
        let caseBase = faceCenter - axis * 0.0135
        lathe(&out, base: caseBase, axis: axis,
              profile: [SIMD2(r * 0.86, 0), SIMD2(r * 1.04, 0.002), SIMD2(r * 1.10, 0.006), SIMD2(r * 1.08, 0.010),
                        SIMD2(r * 1.02, 0.0125)],
              color: SIMD3(0.03, 0.03, 0.033), material: .plastic)
        ring(&out, center: faceCenter - axis * 0.0002, axis: axis, radii: SIMD2(r * 1.03, r * 1.03), tube: 0.0018,
             color: metal, segments: 40, sides: 8)
    }
}
