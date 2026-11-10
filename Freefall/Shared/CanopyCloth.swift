import Foundation
import simd

/// 伞衣的布料模拟（位置约束 PBD，CPU 上跑，715 个粒子）。
///
/// 只模拟上表面一张 55×13 的粒子网格（9 个气室 × 6 + 1 列，前缘到后缘 13 行）；下表面按翼型厚度沿法线往下推，
/// 厚度乘上每列的「充气程度」——没充起来时上下两层贴在一起，就是一块软布。
/// 布的约束只限制拉伸、不限制压缩：挤在一起时会自然起皱、翻折。
///
/// 开伞的几个阶段（τ = 开伞后的秒数）：
///   0 ~ 0.5   引导伞把伞包从背后拽上去，伞绳一路抽出（整团布跟着伞包走）
///   0.5 ~ 0.8 伞绳拉直
///   0.8 ~     伞包打开，布被往上的气流吹开、被伞绳兜住；中间的气室先鼓起来，往两边一格格鼓开（形状弹簧逐渐变硬）
///   3.5 ~     飞行：形状基本定住，后缘一直有点抖；拉环拉下去，那一侧的后缘被拽下来
/// 落地以后形状弹簧松掉，伞塌下来盖在地上。
final class CanopyCloth: @unchecked Sendable {
    static let columns = 55
    static let rows = 13
    /// 每个气室几列
    static let columnsPerCell = 6
    static let span: Float = 8.4
    static let chord: Float = 3.0
    static let cells = 9

    /// 伞衣（充好气时）相对舞台的位置：头顶 4.1 米、略靠前，前缘朝 -Z 往下压 8°
    static func canopyFrame(eyeHeight: Float, bank: Float) -> simd_float4x4 {
        translation(SIMD3(0, eyeHeight + 4.1, -0.9))
            * simd_float4x4(simd_quatf(angle: -8 * .pi / 180, axis: SIMD3(1, 0, 0)))
            * simd_float4x4(simd_quatf(angle: bank, axis: SIMD3(0, 0, -1)))
    }

    private(set) var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    /// 充好气时上表面每个粒子在伞衣坐标里的位置
    private let rest: [SIMD3<Float>]
    /// 布的约束：粒子对和最大长度
    private let links: [(Int, Int, Float)]
    /// 每个粒子在伞包里的随机位置（打包时的一团）
    private let packed: [SIMD3<Float>]
    private(set) var normals: [SIMD3<Float>]
    /// 每列的充气程度 0…1
    private(set) var inflation: [Float]
    private(set) var active = false
    private var seed: UInt32 = 0x1234_5678
    private var clock: Float = 0

    init() {
        let n = Self.columns * Self.rows
        var rest: [SIMD3<Float>] = []
        rest.reserveCapacity(n)
        for j in 0..<Self.rows {
            for i in 0..<Self.columns {
                rest.append(Self.restPoint(column: i, row: j))
            }
        }
        self.rest = rest
        var links: [(Int, Int, Float)] = []
        func add(_ a: Int, _ b: Int) { links.append((a, b, length(rest[a] - rest[b]) * 1.02)) }
        for j in 0..<Self.rows {
            for i in 0..<Self.columns {
                let k = j * Self.columns + i
                if i + 1 < Self.columns { add(k, k + 1) }
                if j + 1 < Self.rows { add(k, k + Self.columns) }
                if i + 1 < Self.columns, j + 1 < Self.rows {
                    add(k, k + Self.columns + 1)
                    add(k + 1, k + Self.columns)
                }
            }
        }
        self.links = links
        var packed: [SIMD3<Float>] = []
        var s: UInt32 = 0x9E37_79B9
        func rand() -> Float {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            return Float(s) / Float(UInt32.max) * 2 - 1
        }
        for _ in 0..<n { packed.append(SIMD3(rand() * 0.16, rand() * 0.12, rand() * 0.1)) }
        self.packed = packed
        positions = Array(repeating: .zero, count: n)
        previous = positions
        normals = Array(repeating: SIMD3(0, 1, 0), count: n)
        inflation = Array(repeating: 0, count: Self.columns)
    }

    /// 充好气的上表面：NACA 翼型（相对厚度 15%）上半，每个气室鼓起来，展向一条弧（翼尖下垂）
    static func restPoint(column i: Int, row j: Int) -> SIMD3<Float> {
        let x = -span / 2 + span * Float(i) / Float(columns - 1)
        let s = chordParameter(j)
        let cellPos = (x / span + 0.5) * Float(cells)
        let bulge = 0.05 * sin(.pi * (cellPos - floor(cellPos)))
        let y = thickness(s) * 1.3 + bulge * (1 - s * 0.6) - (x * x) / (2 * 7.0)
        return SIMD3(x, y, -chord / 2 + s * chord)
    }

    static func chordParameter(_ j: Int) -> Float { (1 - cos(.pi * Float(j) / Float(rows - 1))) / 2 }

    static func thickness(_ s: Float) -> Float {
        let r = s.squareRoot()
        return 5 * 0.15 * chord * (0.2969 * r - 0.126 * s - 0.3516 * s * s + 0.2843 * s * s * s - 0.1015 * s * s * s * s)
    }

    func reset() {
        active = false
    }

    private func noise() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    // MARK: - 推进

    struct Input {
        var sinceDeploy: Double          // 开伞后的秒数
        var eyeHeight: Float
        var links: (SIMD3<Float>, SIMD3<Float>)   // 伞绳汇到的左右两点（背带上端）
        var brakeLeft: Float
        var brakeRight: Float
        var turnRate: Float
        var landed: Bool
        var verticalSpeed: Float
    }

    func step(_ dt: Float, _ input: Input) {
        let n = positions.count
        let frame = Self.canopyFrame(eyeHeight: input.eyeHeight, bank: -input.turnRate * 0.55)
        let tau = Float(input.sinceDeploy)
        // 伞包：从背后被拽上去，0.8 秒到伞绳拉直的位置
        let bagStart = SIMD3<Float>(0, input.eyeHeight - 0.15, 0.28)
        let bagEnd = (frame * SIMD4(0, -0.4, 0.6, 1)).xyz
        let bagT = min(max(tau / 0.8, 0), 1)
        let bag = bagStart + (bagEnd - bagStart) * (bagT * bagT * (3 - 2 * bagT))

        if !active {
            active = true
            for k in 0..<n {
                positions[k] = bag + packed[k]
                previous[k] = positions[k]
            }
        }

        if tau < 0.8 && !input.landed {
            // 还在伞包里：整团跟着伞包走
            for k in 0..<n {
                let p = bag + packed[k] * (1 + tau)
                previous[k] = positions[k]
                positions[k] = p
            }
            updateNormals()
            for i in 0..<Self.columns { inflation[i] = 0 }
            return
        }

        // 每列的充气程度：中间先鼓，往两边一格格鼓开
        for i in 0..<Self.columns {
            let fromCenter = abs(Float(i) - Float(Self.columns - 1) / 2) / (Float(Self.columns - 1) / 2)
            let start: Float = 1.0 + 0.9 * fromCenter
            let t = min(max((tau - start) / 1.2, 0), 1)
            inflation[i] = input.landed ? max(inflation[i] - dt * 1.4, 0) : t * t * (3 - 2 * t)
        }

        let substeps = 3
        let h = min(dt, 1.0 / 45) / Float(substeps)
        clock += h * Float(substeps)
        // 相对空气：自由落体时风从下往上灌，开好以后主要是往前飞的迎面风
        let updraft = input.landed ? 0 : min(input.verticalSpeed, 60) * 0.9
        // 抖动：沿弦向、展向传播的几道波（布的抖动是成片的波，不是每个点各抖各的），开伞时猛，飞行时只剩后缘轻轻抖
        let flutter: Float = input.landed ? 0.0 : 1.5 + 30 * max(0, 1 - (tau - 0.8) / 2.6)
        let damping = 1 - (input.landed ? 5 : 2.5) * h
        for _ in 0..<substeps {
            for k in 0..<n {
                let i = k % Self.columns, j = k / Self.columns
                let target = targetPoint(column: i, row: j, frame: frame, input: input)
                let stiffness: Float = input.landed ? 0 : inflation[i] * 70 + 3
                var force = (target - positions[k]) * stiffness
                force.y += updraft * (1 - inflation[i]) * 0.6
                if input.landed { force.y -= 4.5; force.z -= 1.2 }      // 塌下来，被风往前带一点
                let edge = Float(j) / Float(Self.rows - 1)
                let x = Float(i) / Float(Self.columns - 1)
                let wave = sin(clock * 9.0 - edge * 7.0 + x * 3.0) + 0.6 * sin(clock * 13.7 + x * 11.0 - edge * 4.0)
                let amp = flutter * (0.25 + 0.75 * edge * edge) * (1.2 - inflation[i] * 0.7)
                force.y += wave * amp
                force += SIMD3(noise(), noise(), noise()) * (amp * 0.3)
                let velocity = (positions[k] - previous[k]) * damping
                previous[k] = positions[k]
                positions[k] += velocity + force * h * h
            }
            for _ in 0..<4 { solveLinks() }
            if !input.landed { solveLines(input: input, frame: frame) }
            if input.landed {
                for k in 0..<n where positions[k].y < 0.03 { positions[k].y = 0.03 }
            }
        }
        updateNormals()
    }

    /// 形状弹簧拉向的位置：充好气的形状，拉环拉下去那一侧的后缘往下拽
    private func targetPoint(column i: Int, row j: Int, frame: simd_float4x4, input: Input) -> SIMD3<Float> {
        var p = rest[j * Self.columns + i]
        let s = Self.chordParameter(j)
        let side = Float(i) / Float(Self.columns - 1)              // 0 左翼尖 … 1 右翼尖
        let brake = side < 0.5 ? input.brakeLeft * (1 - side * 2) : input.brakeRight * (side * 2 - 1)
        let trailing = max(0, (s - 0.45) / 0.55)
        p.y -= brake * 0.75 * trailing * trailing
        p.z -= brake * 0.15 * trailing
        return (frame * SIMD4(p, 1)).xyz
    }

    private func solveLinks() {
        for (a, b, maxLength) in links {
            let d = positions[b] - positions[a]
            let len = length(d)
            if len > maxLength, len > 1e-6 {
                let correction = d * ((len - maxLength) / len * 0.5)
                positions[a] += correction
                positions[b] -= correction
            }
        }
    }

    /// 伞绳只能拉直不能伸长：挂点到背带上端的距离不超过伞绳长
    private func solveLines(input: Input, frame: simd_float4x4) {
        for (k, attach) in lineAttachmentIndices.enumerated() {
            let link = lineIsLeft[k] ? input.links.0 : input.links.1
            let restAttach = (frame * SIMD4(rest[attach] - SIMD3(0, Self.thickness(Self.chordParameter(attach / Self.columns)) * 1.6, 0), 1)).xyz
            let maxLength = length(restAttach - link) * 1.01
            let d = positions[attach] - link
            let len = length(d)
            if len > maxLength { positions[attach] = link + d * (maxLength / len) }
        }
    }

    /// 伞绳挂在每道肋（每 6 列）的 A/B/C/D 四排上
    private let lineAttachmentIndices: [Int] = {
        var result: [Int] = []
        for rib in 0...CanopyCloth.cells {
            for row in [0, 4, 7, 11] { result.append(row * CanopyCloth.columns + rib * CanopyCloth.columnsPerCell) }
        }
        return result
    }()

    private let lineIsLeft: [Bool] = {
        var result: [Bool] = []
        for rib in 0...CanopyCloth.cells {
            for _ in 0..<4 { result.append(rib * CanopyCloth.columnsPerCell < CanopyCloth.columns / 2) }
        }
        return result
    }()

    private func updateNormals() {
        let c = Self.columns, r = Self.rows
        for j in 0..<r {
            for i in 0..<c {
                let k = j * c + i
                let tx = positions[j * c + min(i + 1, c - 1)] - positions[j * c + max(i - 1, 0)]
                let tz = positions[min(j + 1, r - 1) * c + i] - positions[max(j - 1, 0) * c + i]
                let n = cross(tz, tx)
                let l = length(n)
                normals[k] = l > 1e-6 ? n / l : SIMD3(0, 1, 0)
            }
        }
    }

    // MARK: - 给渲染用

    /// 下表面的点：上表面沿法线往下推翼型厚度 × 充气程度
    func bottomPoint(_ k: Int) -> SIMD3<Float> {
        let i = k % Self.columns, j = k / Self.columns
        let t = Self.thickness(Self.chordParameter(j)) * 1.6 * (0.08 + 0.92 * inflation[i])
        return positions[k] - normals[k] * t
    }

    /// 伞绳的两端：（挂点，是不是左边一组）
    var lineAttachments: [(SIMD3<Float>, Bool)] {
        lineAttachmentIndices.enumerated().map { (bottomPoint($0.element), lineIsLeft[$0.offset]) }
    }

    /// 后缘外侧几道肋上的点：刹车绳（左、右各 3 根）挂在这里
    var brakeAttachments: (left: [SIMD3<Float>], right: [SIMD3<Float>]) {
        let row = (Self.rows - 1) * Self.columns
        let k = Self.columnsPerCell, last = Self.columns - 1
        return ([0, k, 2 * k].map { bottomPoint(row + $0) }, [last - 2 * k, last - k, last].map { bottomPoint(row + $0) })
    }

    /// 伞衣投在地上、身上的影子的形状：一块平板（中心、展向、弦向），强度 = 平均充气程度
    struct ShadowShape {
        /// xyz 中心，w 强度
        var center: SIMD4<Float>
        /// xyz 展向单位向量（左翼尖 → 右翼尖），w 半展长
        var span: SIMD4<Float>
        /// xyz 弦向单位向量（前缘 → 后缘），w 半弦长
        var chord: SIMD4<Float>
    }

    func shadowShape() -> ShadowShape {
        let c = Self.columns, r = Self.rows
        var center = SIMD3<Float>(0, 0, 0)
        for p in positions { center += p }
        center /= Float(positions.count)
        var left = SIMD3<Float>(0, 0, 0), right = left, lead = left, trail = left
        for j in 0..<r { left += positions[j * c]; right += positions[j * c + c - 1] }
        for i in 0..<c { lead += positions[i]; trail += positions[(r - 1) * c + i] }
        let spanVector = (right - left) / Float(r)
        let spanLength = length(spanVector)
        let ex = spanLength > 1e-3 ? spanVector / spanLength : SIMD3<Float>(1, 0, 0)
        var chordVector = (trail - lead) / Float(c)
        chordVector -= dot(chordVector, ex) * ex
        let chordLength = length(chordVector)
        let ez = chordLength > 1e-3 ? chordVector / chordLength : SIMD3<Float>(0, 0, 1)
        let strength = inflation.reduce(0, +) / Float(inflation.count)
        return ShadowShape(center: SIMD4(center, strength), span: SIMD4(ex, spanLength / 2),
                           chord: SIMD4(ez, chordLength / 2))
    }

    /// 伞顶中间（引导伞的连接点）
    var topCenter: SIMD3<Float> { positions[2 * Self.columns + Self.columns / 2] }

    /// 网格：上表面、下表面、两侧翼尖封口。前缘不封（冲压翼伞的进气口），能看到气室里面。
    /// 伞布颜色按气室条纹；position.w = 展向坐标（米）、normal.w = 弦向坐标（米），给 shader 画缝线。
    func buildMesh(into out: inout [MeshVertex]) {
        let c = Self.columns, r = Self.rows
        let palette: [SIMD3<Float>] = [
            SIMD3(0.05, 0.10, 0.32), SIMD3(0.85, 0.22, 0.05), SIMD3(0.82, 0.82, 0.80),
            SIMD3(0.85, 0.22, 0.05), SIMD3(0.82, 0.82, 0.80), SIMD3(0.85, 0.22, 0.05),
            SIMD3(0.82, 0.82, 0.80), SIMD3(0.85, 0.22, 0.05), SIMD3(0.05, 0.10, 0.32),
        ]
        var bottom = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for k in 0..<positions.count { bottom[k] = bottomPoint(k) }
        func uv(_ k: Int) -> (Float, Float) {
            let i = k % c, j = k / c
            return (Self.span * Float(i) / Float(c - 1), Self.chord * Self.chordParameter(j))
        }
        func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ k: Int, _ color: SIMD3<Float>) {
            let (u, v) = uv(k)
            out.append(MeshVertex(position: SIMD4(p, u), normal: SIMD4(n, v),
                                  color: SIMD4(color, MeshMaterial.fabric.rawValue)))
        }
        for j in 0..<(r - 1) {
            for i in 0..<(c - 1) {
                let color = palette[min(i / Self.columnsPerCell, Self.cells - 1)]
                let k00 = j * c + i, k10 = k00 + 1, k01 = k00 + c, k11 = k01 + 1
                for (pts, sign) in [(positions, Float(1)), (bottom, Float(-1))] {
                    let n00 = normals[k00] * sign, n10 = normals[k10] * sign
                    let n01 = normals[k01] * sign, n11 = normals[k11] * sign
                    vertex(pts[k00], n00, k00, color); vertex(pts[k10], n10, k10, color); vertex(pts[k11], n11, k11, color)
                    vertex(pts[k00], n00, k00, color); vertex(pts[k11], n11, k11, color); vertex(pts[k01], n01, k01, color)
                }
            }
        }
        // 翼尖封口
        for i in [0, c - 1] {
            let color = palette[i == 0 ? 0 : Self.cells - 1]
            for j in 0..<(r - 1) {
                let a = j * c + i, b = a + c
                let side = normalize(positions[min(i + 1, c - 1) + j * c] - positions[max(i - 1, 0) + j * c])
                vertex(positions[a], side, a, color); vertex(positions[b], side, b, color); vertex(bottom[b], side, b, color)
                vertex(positions[a], side, a, color); vertex(bottom[b], side, b, color); vertex(bottom[a], side, a, color)
            }
        }
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
