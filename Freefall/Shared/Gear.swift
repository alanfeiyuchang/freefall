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

    // MARK: - 3 环（身体坐标）

    /// 3 环释放装置的位置（肩膀前面，伸缩带从这里接出来）。没有背带了（低头会挡视线）：开伞以后伸缩带的下端在这里收成一组 3 环
    static func threeRingPoint(_ side: Float) -> SIMD3<Float> { SIMD3(0.15 * side, -0.19, -0.015) }

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
        v.reserveCapacity(9000)
        for side: Float in [-1, 1] {
            // 3 环：大环、中环、小环依次往上套（伸缩带的下端）
            let base3 = threeRingPoint(side)
            let forward3 = SIMD3<Float>(0.15 * side, 0.1, -1)
            ring(&v, center: base3, axis: forward3, radii: SIMD2(0.021, 0.021), tube: 0.0042, color: metal)
            ring(&v, center: base3 + SIMD3(0.003 * side, 0.024, -0.004), axis: forward3, radii: SIMD2(0.013, 0.013),
                 tube: 0.0035, color: metal)
            ring(&v, center: base3 + SIMD3(0.005 * side, 0.040, -0.007), axis: forward3, radii: SIMD2(0.0075, 0.0075),
                 tube: 0.003, color: metal)
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

    /// 落地以后的伸缩带：没有伞拉着，从 3 环垂到身体两侧（不挡在胸前）。返回左右两个连接环的位置（舞台空间），伞绳从这里拖到地上
    static func slackRisers(_ out: inout [MeshVertex], layout: BodyLayout) -> (SIMD3<Float>, SIMD3<Float>) {
        var ends: [SIMD3<Float>] = []
        for side: Float in [-1, 1] {
            let base = threeRingPoint(side) + SIMD3(0.005 * side, 0.03, -0.01)
            let end = layout.place(SIMD3(0.25 * side, -0.42, -0.07))
            let pts = spline([base, base + SIMD3(0.03 * side, 0.04, -0.03), base + SIMD3(0.07 * side, -0.06, -0.07),
                              SIMD3(0.25 * side, -0.42, -0.07)].map(layout.place), steps: 5)
            ribbon(&out, points: pts, across: pts.map { _ in layout.direction(SIMD3(1, 0, 0)) }, width: 0.025,
                   thickness: 0.008, color: webbing)
            ring(&out, center: end + SIMD3(0, -0.012, 0), axis: layout.direction(SIMD3(1, 0, 0)), radii: SIMD2(0.008, 0.016),
                 tube: 0.0028, color: metal, segments: 20, sides: 7, spin: layout.direction(SIMD3(0, 0, 1)))
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

    /// 开伞拉环：一个金属 D 形环，外半圈套着红色的橡胶握把，立在小臂手背那一侧（缝在袖子上的一小块布片上，环往手腕那边歪一点）。
    /// 拉出来以后，布片和环之间露出一截钢索。at 是拉环现在的位置（舞台空间）
    static func pullRing(_ out: inout [MeshVertex], mount: RingMount, at center: SIMD3<Float>, glow: Float) {
        let up = mount.toward, facing = mount.facing
        let a: Float = 0.028, b: Float = 0.024
        if simd_length(center - mount.rest) > 0.008 {
            // 钢索：布片 → 环的上沿，稍微往下垂一点
            let top = center + up * a
            let mid = (mount.tab + top) * 0.5 + SIMD3(0, -0.008, 0)
            tube(&out, points: spline([mount.tab, mid, top], steps: 6), radius: 0.0012, color: metal, material: .metal,
                 sides: 6)
        }
        // 布片：缝在袖子上（跟着小臂）
        let along = simd_normalize(simd_cross(facing, mount.normal))
        pillow(&out, center: mount.tab, axes: (along, facing, mount.normal), half: SIMD3(0.017, 0.012, 0.0035),
               exponent: 0.25, color: webbing * 1.5, material: .webbing, segments: 16, rings: 8)
        ring(&out, center: center, axis: facing, radii: SIMD2(a, b), tube: 0.0038, color: metal,
             segments: 36, sides: 10, spin: up)
        // 外半圈的红色握把：粗一点的橡胶套
        let e1 = simd_normalize(up - simd_dot(up, facing) * facing), e2 = simd_cross(facing, e1)
        var grip: [SIMD3<Float>] = []
        for k in 0...16 {
            let t = Float.pi * (0.62 + 0.76 * Float(k) / 16)
            grip.append(center + e1 * (cos(t) * a) + e2 * (sin(t) * b))
        }
        tube(&out, points: grip, radius: 0.0075, color: handleRed * glow, material: .rubber, sides: 14)
        let n = grip.count
        for (end, next) in [(grip[0], grip[1]), (grip[n - 1], grip[n - 2])] {
            ring(&out, center: end, axis: simd_normalize(next - end), radii: SIMD2(0.0078, 0.0078), tube: 0.0011,
                 color: housingBlack, material: .plastic, segments: 14, sides: 5)
        }
    }

    /// 操纵环：一圈硬挺的织带围成的椭圆环（黄色），顶上一小块黑色的布片，操纵绳拴在布片上。
    /// center 是环的中间，up 指向布片（操纵绳那头），facing 是环面的法线（手从这个方向穿过去）。返回操纵绳的拴点。
    @discardableResult
    static func toggle(_ out: inout [MeshVertex], center: SIMD3<Float>, up: SIMD3<Float>,
                       facing: SIMD3<Float>) -> SIMD3<Float> {
        let lateral = simd_normalize(simd_cross(up, facing))
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

    /// 没人抓的操纵环：竖着挂，环面朝着人
    @discardableResult
    static func toggle(_ out: inout [MeshVertex], center: SIMD3<Float>, toward anchor: SIMD3<Float>) -> SIMD3<Float> {
        var facing = SIMD3<Float>(anchor.x - center.x, 0, anchor.z - center.z)
        facing = simd_length(facing) > 1e-4 ? simd_normalize(facing) : SIMD3(0, 0, 1)
        return toggle(&out, center: center, up: SIMD3(0, 1, 0), facing: facing)
    }

    /// 抓在手里的操纵环：环套在四根手指的第一节上（手指从环里穿过去），布片在食指那头。
    /// 只按抓握点摆的话，环的中心在手心，整个被拳头包住看不见。
    @discardableResult
    static func heldToggle(_ out: inout [MeshVertex], hand h: HandPose) -> SIMD3<Float> {
        let knuckles: [HandJoint] = [.indexKnuckle, .middleKnuckle, .ringKnuckle, .littleKnuckle]
        let middles: [HandJoint] = [.indexIntermediateBase, .middleIntermediateBase, .ringIntermediateBase,
                                    .littleIntermediateBase]
        var center = SIMD3<Float>(0, 0, 0), along = SIMD3<Float>(0, 0, 0)
        for (k, m) in zip(knuckles, middles) {
            center += (h[k] + h[m]) * 0.5
            along += h[m] - h[k]
        }
        center /= 4
        let up = simd_normalize(h[.indexKnuckle] - h[.littleKnuckle])
        var facing = along - simd_dot(along, up) * up
        facing = simd_length(facing) > 1e-5 ? simd_normalize(facing) : simd_normalize(simd_cross(up, SIMD3(0, 1, 0)))
        // 环的中心比手指的中线往食指那头挪一点（布片露在虎口上面）
        return toggle(&out, center: center + up * 0.008, up: up, facing: facing)
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
    /// 戴手套时表戴在手套袖口外面（袖口半径约 3.9 厘米），表带放大一圈。
    static func watch(_ out: inout [MeshVertex], hand: HandPose, gloved: Bool) {
        let f = SceneObjects.wristFrame(hand)
        let (sideRadius, backRadius) = SceneObjects.strapRadii(gloved: gloved)
        let n = 40
        var pts: [SIMD3<Float>] = [], across: [SIMD3<Float>] = []
        for i in 0..<n {
            let t = 2 * Float.pi * Float(i) / Float(n)
            pts.append(f.center + f.side * (sideRadius * cos(t)) + f.back * (backRadius * sin(t)))
            across.append(f.towardElbow)
        }
        ribbon(&out, points: pts, across: across, width: 0.022, thickness: 0.0035,
               color: SIMD3(0.02, 0.02, 0.022), material: .rubber, closed: true)
        let (faceCenter, _, _, size) = SceneObjects.watchPlacement(hand, gloved: gloved)
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

    /// 跳伞服的袖子（戴手套时）：只有小臂这一截——从手套袖口外面套上去，顺着前臂到手肘，在手肘那里收口。
    /// 手部追踪只给到前臂（腕和前臂的方向），手肘按前臂长 27 厘米往回推。大臂和肩膀没有追踪，以前按身体朝向猜，
    /// 猜错了袖子会横在脸前，所以不画了：只留看得准的小臂和手。
    /// 截面是扁的（横着宽），越往手肘越粗；袖口一圈松紧带，手肘那头布往里卷成一个圆口（不是敞着的管子，看不到里面）。
    static let forearmLength: Float = 0.27

    static func sleeve(_ out: inout [MeshVertex], hand: HandPose) {
        let f = SceneObjects.wristFrame(hand)
        let wrist = hand[.forearmWrist]
        let arm = f.towardElbow
        let side = f.side, back = f.back
        let start: Float = 0.034, end = forearmLength
        let rings = 22, sides = 24
        /// 手肘那头最后 4.5 厘米收成圆口
        let capLength: Float = 0.045
        func point(_ i: Int, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD2<Float>) {
            let s = Float(i) / Float(rings)
            let along = start + (end - start) * s
            let a = 2 * Float.pi * Float(k % sides) / Float(sides)
            let r = 0.045 + 0.013 * smoothstep(0, 1, s)
            // 褶子：顺着袖子的几道长褶 + 绕着袖子的横褶，越靠手肘越松；袖口那头被松紧带收紧，褶子细密
            let loose = smoothstep(0.05, 0.6, s)
            let fold = 1 + (0.018 + 0.03 * loose) * sin(along * 70 + a * 2) * smoothstep(0, 0.08, s)
                + 0.016 * sin(a * 5 + along * 31) + 0.012 * (1 - loose) * sin(a * 14)
            let cuff = 1 - 0.07 * (1 - smoothstep(0, 0.05, s))
            // 收口：最后一段半径按四分之一圆收到 35%，再往里翻
            let c = max(along - (end - capLength), 0) / capLength              // 0…1
            let close = (1 - c * c).squareRoot() * 0.65 + 0.35
            let rs = r * 1.08 * fold * cuff * close, rb = r * 0.92 * fold * cuff * close
            // 法线：侧面的椭圆法线，收口处往手肘方向倒
            let radial = simd_normalize(side * (cos(a) / rs) + back * (sin(a) / rb))
            let normal = simd_normalize(radial * (1 - c * 0.85) + arm * (c * 1.2))
            return (wrist + arm * along + side * (rs * cos(a)) + back * (rb * sin(a)), normal, SIMD2(along, r * a))
        }
        let color = SIMD3<Float>(0.028, 0.034, 0.05)      // 深海军蓝的跳伞服
        for i in 0..<rings {
            for k in 0..<sides {
                let p00 = point(i, k), p10 = point(i + 1, k), p11 = point(i + 1, k + 1), p01 = point(i, k + 1)
                quad(&out, (p00.0, p10.0, p11.0, p01.0), (p00.1, p10.1, p11.1, p01.1),
                     (p00.2, p10.2, p11.2, p01.2), color, .webbing)
            }
        }
        // 圆口里面：一片往里凹的深色圆盖（袖子里是暗的）
        let center = wrist + arm * (end - 0.012)
        for k in 0..<sides {
            let p0 = point(rings, k), p1 = point(rings, k + 1)
            vertex(&out, p0.0, arm, p0.2, color * 0.35, .webbing)
            vertex(&out, center, arm, SIMD2(end, 0), color * 0.2, .webbing)
            vertex(&out, p1.0, arm, p1.2, color * 0.35, .webbing)
        }
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
