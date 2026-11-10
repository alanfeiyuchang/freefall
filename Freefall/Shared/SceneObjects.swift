import Foundation
import simd

/// 手部关节，顺序和 ARKit 的 HandSkeleton.JointName 一一对应（app 里按名字映射，见 ImmersiveRenderer）。
enum HandJoint: Int, CaseIterable {
    case wrist
    case thumbKnuckle, thumbIntermediateBase, thumbIntermediateTip, thumbTip
    case indexMetacarpal, indexKnuckle, indexIntermediateBase, indexIntermediateTip, indexTip
    case middleMetacarpal, middleKnuckle, middleIntermediateBase, middleIntermediateTip, middleTip
    case ringMetacarpal, ringKnuckle, ringIntermediateBase, ringIntermediateTip, ringTip
    case littleMetacarpal, littleKnuckle, littleIntermediateBase, littleIntermediateTip, littleTip
    case forearmWrist, forearmArm
}

/// 一只手：27 个关节在舞台空间的位置
struct HandPose: Sendable {
    var joints: [SIMD3<Float>]
    var isLeft: Bool

    subscript(_ j: HandJoint) -> SIMD3<Float> { joints[j.rawValue] }
}

/// 和 Shaders/Objects.h 的 RoundCone 一样：两端半径不同的胶囊（背带、表带）
struct RoundCone {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var color: SIMD4<Float>

    init(_ a: SIMD3<Float>, _ ra: Float, _ b: SIMD3<Float>, _ rb: Float, _ color: SIMD3<Float>,
         _ material: MeshMaterial = .soft) {
        self.a = SIMD4(a, ra)
        self.b = SIMD4(b, rb)
        self.color = SIMD4(color, material.rawValue)
    }
}

/// 这一帧场景里的实体：飞机、伞衣和伞绳、背带、手腕上的表带、高度表的位置。
/// app 和离屏测试都用 `make` 从时间线算出来，两边画的东西一模一样。
/// 手是真机透视出来的真手（upperLimbVisibility = automatic，系统按深度把手和画面合成），这里不画；
/// 离屏测试没有透视，用 `proxyHands` 画两只肤色的手代替，方便看表戴得对不对。
struct SceneObjects {
    /// 飞机 → 舞台（nil 不画：太远了）
    var planeTransform: simd_float4x4?
    var jumpLightGreen = false
    /// 还在机舱里的程度（背带、表带的光照）
    var inCabin: Float = 0
    /// 伞衣（布料模拟出来的网格，舞台空间；空 = 还没开伞）
    var canopyVertices: [MeshVertex] = []
    /// 线：伞绳、刹车绳、拉手的钢索（每两个点一段，舞台空间）
    var lines: [SIMD4<Float>] = []
    /// 背带、拉手、操纵环、表带（离屏测试里还有代替真手的手）
    var roundCones: [RoundCone] = []
    /// 身边的雨丝（不下雨是 nil）
    var rain: RainUniforms?

    static let strapColor = SIMD3<Float>(0.035, 0.035, 0.04)
    static let webbingColor = SIMD3<Float>(0.09, 0.09, 0.1)
    static let skinColor = SIMD3<Float>(0.42, 0.27, 0.2)
    static let handleColor = SIMD3<Float>(0.62, 0.05, 0.035)
    static let toggleColor = SIMD3<Float>(0.75, 0.55, 0.03)

    struct Input {
        var timeline: JumpTimeline
        var eyeHeight: Float
        var layout: BodyLayout
        var interaction: Interaction
        var cloth: CanopyCloth?
        var hands: [HandPose]
        /// 高度表戴在哪只手上
        var watchOnLeft = true
        var proxyHands = false
    }

    static func make(_ input: Input) -> SceneObjects {
        let timeline = input.timeline
        var o = SceneObjects()
        o.jumpLightGreen = timeline.greenLight
        o.inCabin = Float(timeline.inCabin)
        if timeline.planeDistance < 4000 {
            let offset = timeline.planeOffset
            o.planeTransform = translation(SIMD3(Float(offset.x), Float(offset.y), Float(offset.z)))
        }
        let layout = input.layout

        // 背带：两条肩带 + 胸带。落地以前一直在（低头看得到）
        if timeline.phase != .done {
            let (ls, rs) = layout.shoulders
            let a = layout.anchor
            o.roundCones.append(RoundCone(ls, 0.012, a + SIMD3(-0.13, -0.66, -0.12), 0.012, webbingColor))
            o.roundCones.append(RoundCone(rs, 0.012, a + SIMD3(0.13, -0.66, -0.12), 0.012, webbingColor))
            o.roundCones.append(RoundCone(a + SIMD3(-0.14, -0.4, -0.13), 0.01, a + SIMD3(0.14, -0.4, -0.13), 0.01,
                                          webbingColor))
        }

        // 开伞拉手：报警时一闪一闪；被拉出来以后连着一截钢索
        if let handle = input.interaction.handle, timeline.phase.rawValue <= JumpTimeline.Phase.opening.rawValue {
            let glow: Float = timeline.alarmLevel > 0 ? 1 + 1.6 * max(0, sin(Float(timeline.time) * 12)) : 1
            o.roundCones.append(RoundCone(handle - SIMD3(0.035, 0, 0), 0.016, handle + SIMD3(0.035, 0, 0), 0.016,
                                          handleColor * glow))
            if input.interaction.handlePulled || distance(handle, layout.handleRest) > 0.02 {
                o.lines.append(SIMD4(layout.handleRest, 1))
                o.lines.append(SIMD4(handle, 1))
            }
        }

        // 伞衣：布料模拟的网格 + 滑块；伞绳、背带、刹车绳和两个操纵环
        if let cloth = input.cloth, cloth.active, timeline.outcome != .crashed {
            cloth.buildMesh(into: &o.canopyVertices)
            let landed = timeline.phase == .landed || timeline.phase == .done
            let (ls, rs) = layout.shoulders
            // 落地以后伞绳松了：背带上端垂到肩膀前面，伞绳从地上拖过来
            let (leftLink, rightLink) = landed ? (ls + SIMD3(0.02, 0.1, -0.08), rs + SIMD3(-0.02, 0.1, -0.08))
                                               : layout.links
            o.roundCones.append(RoundCone(ls, 0.0065, leftLink, 0.005, webbingColor))
            o.roundCones.append(RoundCone(rs, 0.0065, rightLink, 0.005, webbingColor))
            let attachments = cloth.lineAttachments
            // 滑块：一块方布，四个角的扣眼各穿一组伞绳。开伞时它顶在伞衣下面，伞衣张开时沿着伞绳滑下来，减缓张开的冲击
            let s = Float(min(max(((timeline.sinceDeploy ?? 0) - 1.0) / 2.2, 0), 1))
            let grommets = landed ? nil : sliderGrommets(attachments: attachments, links: (leftLink, rightLink),
                                                         slide: s * s * (3 - 2 * s))
            for (k, (point, isLeft)) in attachments.enumerated() {
                let link = isLeft ? leftLink : rightLink
                o.lines.append(SIMD4(point, 1))
                if landed {
                    // 挂点 → 拖在地上 → 脚前面 → 背带
                    let onGround = SIMD3<Float>(point.x * 0.35 + link.x * 0.65, 0.02, min(point.z * 0.4, -0.35))
                    o.lines.append(SIMD4(onGround, 1))
                    o.lines.append(SIMD4(onGround, 1))
                } else if let grommets {
                    // 伞绳：挂点 → 滑块的扣眼（每道肋的 A、B 排走前面的扣眼，C、D 排走后面的）→ 背带上端
                    let g = grommets[(isLeft ? 0 : 1) + (k % 4 < 2 ? 0 : 2)]
                    o.lines.append(SIMD4(g, 1))
                    o.lines.append(SIMD4(g, 1))
                }
                o.lines.append(SIMD4(link, 1))
            }
            if let grommets { appendSlider(to: &o.canopyVertices, grommets: grommets) }
            if let toggles = input.interaction.toggles, !landed {
                // 刹车绳也穿过后面的扣眼
                let brakes = cloth.brakeAttachments
                for (points, toggle, back) in [(brakes.left, toggles.0, grommets?[2]), (brakes.right, toggles.1, grommets?[3])] {
                    for p in points {
                        o.lines.append(SIMD4(p, 1))
                        if let back {
                            o.lines.append(SIMD4(back, 1))
                            o.lines.append(SIMD4(back, 1))
                        }
                        o.lines.append(SIMD4(toggle, 1))
                    }
                }
                o.roundCones += toggleLoop(at: toggles.0)
                o.roundCones += toggleLoop(at: toggles.1)
            }
        }

        for hand in input.hands {
            if input.proxyHands { o.roundCones += proxyHandCones(hand) }
            if hand.isLeft == input.watchOnLeft { o.roundCones += watchStrap(hand) }
        }
        return o
    }

    /// 操纵环：一个黄色的小圈，竖着挂
    static func toggleLoop(at center: SIMD3<Float>) -> [RoundCone] {
        let n = 10, r: Float = 0.032
        var points: [SIMD3<Float>] = []
        for i in 0..<n {
            let t = 2 * Float.pi * Float(i) / Float(n)
            points.append(center + SIMD3(cos(t) * r, sin(t) * r * 1.3, 0))
        }
        return (0..<n).map { RoundCone(points[$0], 0.007, points[($0 + 1) % n], 0.007, toggleColor) }
    }

    /// 滑块四个扣眼的位置：[左前, 右前, 左后, 右后]。滑块是一块 0.7 × 0.55 米的布，从伞绳汇在伞衣下面的地方
    /// 滑到背带上端上方一米左右（真的滑块会一直滑到连接环上，在头顶上挡住看伞衣的视线，这里停高一点）。
    static func sliderGrommets(attachments: [(SIMD3<Float>, Bool)], links: (SIMD3<Float>, SIMD3<Float>),
                               slide: Float) -> [SIMD3<Float>]? {
        guard !attachments.isEmpty else { return nil }
        let top = attachments.reduce(SIMD3<Float>(0, 0, 0)) { $0 + $1.0 } / Float(attachments.count)
        let bottom = (links.0 + links.1) * 0.5 + SIMD3(0, 0.95, 0)
        let center = top + (bottom - top) * slide
        let x = normalize(links.1 - links.0) * 0.35
        let z = SIMD3<Float>(0, 0, 0.275)
        return [center - x - z, center + x - z, center - x + z, center + x + z]
    }

    static func appendSlider(to vertices: inout [MeshVertex], grommets g: [SIMD3<Float>]) {
        let n = normalize(cross(g[1] - g[0], g[2] - g[0]))
        let color = SIMD3<Float>(0.06, 0.06, 0.07)        // 深色，和伞衣的颜色分得开
        // uv 给 shader 画缝线：四周一圈加强带
        let uv: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.7, 0), SIMD2(0, 0.55), SIMD2(0.7, 0.55)]
        for idx in [0, 1, 3, 0, 3, 2] {
            vertices.append(MeshVertex(position: SIMD4(g[idx], uv[idx].x + 0.2), normal: SIMD4(n, uv[idx].y + 0.03),
                                       color: SIMD4(color, MeshMaterial.fabric.rawValue)))
        }
    }

    /// 离屏测试里代替真手：每节手指一段胶囊，手掌是从手腕扇形散开的几段，再加一截前臂。肤色。
    static func proxyHandCones(_ h: HandPose) -> [RoundCone] {
        var c: [RoundCone] = []
        let fingers: [(HandJoint, HandJoint, HandJoint, HandJoint, Float)] = [
            (.indexKnuckle, .indexIntermediateBase, .indexIntermediateTip, .indexTip, 1.0),
            (.middleKnuckle, .middleIntermediateBase, .middleIntermediateTip, .middleTip, 1.03),
            (.ringKnuckle, .ringIntermediateBase, .ringIntermediateTip, .ringTip, 0.98),
            (.littleKnuckle, .littleIntermediateBase, .littleIntermediateTip, .littleTip, 0.86),
        ]
        for (k, b, t, tip, s) in fingers {
            c.append(RoundCone(h[k], 0.0098 * s, h[b], 0.009 * s, skinColor, .soft))
            c.append(RoundCone(h[b], 0.009 * s, h[t], 0.0083 * s, skinColor, .soft))
            c.append(RoundCone(h[t], 0.0083 * s, h[tip], 0.0075 * s, skinColor, .soft))
        }
        c.append(RoundCone(h[.thumbKnuckle], 0.012, h[.thumbIntermediateBase], 0.011, skinColor, .soft))
        c.append(RoundCone(h[.thumbIntermediateBase], 0.011, h[.thumbIntermediateTip], 0.0098, skinColor, .soft))
        c.append(RoundCone(h[.thumbIntermediateTip], 0.0098, h[.thumbTip], 0.0088, skinColor, .soft))
        let w = h[.wrist]
        c.append(RoundCone(w, 0.017, h[.indexKnuckle], 0.012, skinColor, .soft))
        c.append(RoundCone(w, 0.018, h[.middleKnuckle], 0.0125, skinColor, .soft))
        c.append(RoundCone(w, 0.017, h[.ringKnuckle], 0.012, skinColor, .soft))
        c.append(RoundCone(w, 0.016, h[.littleKnuckle], 0.011, skinColor, .soft))
        c.append(RoundCone(h[.indexKnuckle], 0.011, h[.littleKnuckle], 0.0105, skinColor, .soft))
        c.append(RoundCone(w, 0.018, h[.thumbKnuckle], 0.013, skinColor, .soft))
        c.append(RoundCone(h[.forearmWrist], 0.024, h[.forearmArm], 0.032, skinColor, .soft))
        return c
    }

    /// 手腕上的一个局部坐标系：表戴在腕关节往手肘方向 3 厘米处；back 指向手背，side 指向手腕侧面。
    static func wristFrame(_ h: HandPose) -> (center: SIMD3<Float>, back: SIMD3<Float>, side: SIMD3<Float>,
                                               towardElbow: SIMD3<Float>) {
        let fw = h[.forearmWrist], wrist = h[.wrist]
        let towardElbow = normalize(h[.forearmArm] - fw)
        // 食指根 → 小指根 叉乘：左手得到手背方向，右手得到手心方向（要反过来）
        var back = normalize(cross(h[.indexKnuckle] - wrist, h[.littleKnuckle] - wrist)) * (h.isLeft ? 1 : -1)
        back = normalize(back - dot(back, towardElbow) * towardElbow)
        return (fw + towardElbow * 0.03, back, cross(towardElbow, back), towardElbow)
    }

    /// 表带：绕手腕一圈的椭圆环（手腕横截面是扁的：宽约 6 厘米、厚约 4 厘米，环比手腕再大一圈）。
    /// 系统按深度合成真手：环在手腕前面的半圈露出来，转到手腕后面的半圈被手挡住，看起来就是戴在手上。
    static func watchStrap(_ h: HandPose) -> [RoundCone] {
        let f = wristFrame(h)
        let n = 20
        var points: [SIMD3<Float>] = []
        for i in 0..<n {
            let t = 2 * Float.pi * Float(i) / Float(n)
            points.append(f.center + f.side * (0.039 * cos(t)) + f.back * (0.031 * sin(t)))
        }
        return (0..<n).map { RoundCone(points[$0], 0.0055, points[($0 + 1) % n], 0.0055, strapColor, .soft) }
    }

    /// 左手腕上的高度表：表盘在表带上方、手背那一侧（离皮肤约 2 厘米，深度在手前面，真手不会盖住它）。
    /// 第一版离手腕太近，真机上被手腕「切」掉一块，所以表带圈和表盘都往外放了、表也做大了。
    /// 表面朝手背外。左手：3 点钟指向手；右手反过来（3 点钟指向手肘），这样抬起哪只手看，字都是正的。
    /// 返回 (中心, 右, 上, 直径)。
    static func watchPlacement(_ h: HandPose) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float) {
        let f = wristFrame(h)
        let center = f.center + f.back * 0.043
        let right = h.isLeft ? -f.towardElbow : f.towardElbow
        let up = cross(f.back, right)
        return (center, right, up, 0.056)
    }
}

func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(t, 1)
    return m
}

func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(s, 1))
}

extension FrameUniforms {
    /// 高度表：追踪到戴表的那只手就戴在手腕上（圆表盘），否则是起跳时头前下方的一块面板。
    mutating func placeAltimeter(feet: Int, eyeHeight: Float, watchHand: HandPose?, alarm: Int) {
        hudGlyphs = FrameUniforms.glyphs(feet: feet)
        if let watchHand {
            let (center, right, up, size) = SceneObjects.watchPlacement(watchHand)
            hudCenter = SIMD4(center, size)
            hudRight = SIMD4(right, size)
            hudUp = SIMD4(up, 1)
            hudStyle = SIMD4(1, min(max(Float(feet) / 30000, 0), 1), Float(alarm), 0)
        } else {
            let center = SIMD3<Float>(0, eyeHeight - 0.30, -0.50)
            let toEye = normalize(SIMD3<Float>(0, eyeHeight, 0) - center)
            let right = SIMD3<Float>(1, 0, 0)
            hudCenter = SIMD4(center, 0.15)
            hudRight = SIMD4(right, 0.05)
            hudUp = SIMD4(cross(toEye, right), 1)
            hudStyle = SIMD4(0, 0, Float(alarm), 0)
        }
    }
}
