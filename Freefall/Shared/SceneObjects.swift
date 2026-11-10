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

/// 这一帧场景里的实体：飞机、伞衣和伞绳、身上的装备、手腕上的表、高度表的位置。
/// app 和离屏测试都用 `make` 从时间线算出来，两边画的东西一模一样。
/// 手是真机透视出来的真手（upperLimbVisibility = automatic，系统按深度把手和画面合成），这里不画；
/// 离屏测试没有透视，用 `proxyHands` 画两只肤色的手代替，方便看表戴得对不对。
struct SceneObjects {
    /// 飞机 → 舞台（nil 不画：太远了）
    var planeTransform: simd_float4x4?
    var jumpLightGreen = false
    /// 还在机舱里的程度（装备的光照）
    var inCabin: Float = 0
    /// 每帧重建的网格（舞台空间）：伞衣（布料模拟）、滑块、拉手、操纵环、表、落地后垂下来的伸缩带
    var meshVertices: [MeshVertex] = []
    /// 伸缩带、连接环、导向环（Gear.risers）：开伞以后、落地以前
    var risersTransform: simd_float4x4?
    /// 绳子：伞绳、刹车绳
    var lines: [LineSegment] = []
    /// 离屏测试里代替真手的手（不戴手套时）
    var roundCones: [RoundCone] = []
    /// 戴手套的手（Glove.swift 按关节蒙皮）
    var gloveHands: [HandPose] = []
    /// 身边的雨丝（不下雨是 nil）
    var rain: RainUniforms?
    /// 身边往上掠过的雾团（不在有云的高度是 nil；格式同雨丝，见 Rain.h 的 mistVertex）
    var mist: RainUniforms?
    /// 手套、袖子、背带淋湿的程度 0…1（ObjectUniforms.params.z）
    var wetness: Float = 0
    /// 地形（环礁没有）
    var terrain: TerrainFrame?
    /// 伞衣的影子（FrameUniforms.canopyCenter / Span / Chord）；没开伞是 nil
    var canopyShadow: CanopyCloth.ShadowShape?
    /// 身体的影子：头顶（舞台空间）；在机舱里是 nil
    var bodyTop: SIMD3<Float>?
    /// 开场的实体化（FrameUniforms.reveal）：xyz 起点，w 波前半径（-1 = 还在房间里只有扶杆，1e6 = 全部完成）
    var reveal = SIMD4<Float>(0, 0, 0, 1e6)

    static let skinColor = SIMD3<Float>(0.42, 0.27, 0.2)

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
        /// 戴手套（真手藏起来，画手套和跳伞服的小臂袖子）
        var gloves = false
    }

    /// 伞绳半径：主伞绳 1.8 毫米粗，刹车绳上段细、下段粗一点
    static let lineRadius: Float = 0.0009
    static let brakeUpperRadius: Float = 0.0008
    static let brakeLowerRadius: Float = 0.0013

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
        let anchor = layout.anchor
        o.meshVertices.reserveCapacity(24_000)

        // 没有背带（低头会挡视线）。出了舱门身体才在阳光下投影子
        if timeline.phase != .cabin { o.bodyTop = layout.place(SIMD3(0, 0.1, 0.05)) }

        // 开伞拉环（左右小臂各一个，用另一只手拉）：报警时红色握把一闪一闪；拉出来的那个连着一截钢索，松手就扔掉了
        if timeline.phase != .done {
            let glow: Float = timeline.alarmLevel > 0 ? 1 + 1.6 * max(0, sin(Float(timeline.time) * 12)) : 1
            let ia = input.interaction
            for i in 0..<2 {
                // 挂的位置按这一帧的手算（离屏测试的手没经过交互也画得出来）；手追踪不到时用交互里留下的
                let arm = input.hands.first { $0.isLeft == (i == 0) }
                guard let mount = arm.map({ ringMount($0, gloved: input.gloves) }) ?? ia.mounts[i] else { continue }
                let held = ia.left.holding == .handle(i) || ia.right.holding == .handle(i)
                // 被抓着、拉出来了：跟着交互里的位置（拉出来扔掉了是 nil）；平时挂在小臂上
                let position = held || ia.pulledRing == i ? ia.rings[i] : mount.rest
                if let position { Gear.pullRing(&o.meshVertices, mount: mount, at: position, glow: glow) }
            }
        }

        // 伞衣：布料模拟的网格 + 滑块；伞绳、伸缩带、刹车绳和两个操纵环
        if let cloth = input.cloth, cloth.active, timeline.outcome != .crashed {
            cloth.buildMesh(into: &o.meshVertices)
            o.canopyShadow = cloth.shadowShape()
            let landed = timeline.phase == .landed || timeline.phase == .done
            let attachments = cloth.lineAttachments
            if landed {
                // 落地以后伞绳松了：伸缩带从 3 环垂到胸前，伞绳从那里拖到地上，再拖到塌在地上的伞衣
                let (leftEnd, rightEnd) = Gear.slackRisers(&o.meshVertices, layout: layout)
                for (point, isLeft) in attachments {
                    let end = isLeft ? leftEnd : rightEnd
                    let onGround = SIMD3<Float>(point.x * 0.35 + end.x * 0.65, 0.02, min(point.z * 0.4, -0.35))
                    o.lines.append(LineSegment(point, onGround, radius: lineRadius, color: Gear.lineWhite))
                    o.lines.append(LineSegment(onGround, end, radius: lineRadius, color: Gear.lineWhite))
                }
            } else {
                o.risersTransform = layout.transform
                // 滑块：一块方布，四个角的扣眼各穿一组伞绳。开伞时它顶在伞衣下面，伞衣张开时沿着伞绳滑下来，减缓张开的冲击
                let s = Float(min(max(((timeline.sinceDeploy ?? 0) - 1.0) / 2.2, 0), 1))
                let joins = (left: layout.place((Gear.lineJoin(-1, front: true) + Gear.lineJoin(-1, front: false)) * 0.5),
                             right: layout.place((Gear.lineJoin(1, front: true) + Gear.lineJoin(1, front: false)) * 0.5))
                let grommets = sliderGrommets(attachments: attachments, links: (joins.left, joins.right),
                                              slide: s * s * (3 - 2 * s))
                // 伞绳：挂点 → 滑块的扣眼（A、B 排走前面的扣眼，C、D 排走后面的）→ 前 / 后伸缩带的连接环。
                // 扣眼以下一组十根挤成一束，画成一根粗一点的
                for (k, (point, isLeft)) in attachments.enumerated() {
                    let front = k % 4 < 2
                    let g = grommets.map { $0[(isLeft ? 0 : 1) + (front ? 0 : 2)] }
                    let link = layout.place(Gear.lineJoin(isLeft ? -1 : 1, front: front))
                    o.lines.append(LineSegment(point, g ?? link, radius: lineRadius, color: Gear.lineWhite))
                }
                if let grommets {
                    for (i, g) in grommets.enumerated() {
                        let link = layout.place(Gear.lineJoin(i % 2 == 0 ? -1 : 1, front: i < 2))
                        o.lines.append(LineSegment(g, link, radius: 0.0026, color: Gear.lineWhite * 0.92))
                    }
                    Gear.slider(&o.meshVertices, grommets: grommets)
                }
                if let toggles = input.interaction.toggles {
                    // 刹车绳：后缘三个挂点汇到一根（分叉点），穿过滑块后面的扣眼、后伸缩带的导向环，拴在操纵环顶上
                    let brakes = cloth.brakeAttachments
                    for (points, toggle, side) in [(brakes.left, toggles.0, Float(-1)), (brakes.right, toggles.1, Float(1))] {
                        // 被哪只手抓着：环套在那只手的手指上；没人抓就竖着挂
                        let target: Interaction.Target = side < 0 ? .leftToggle : .rightToggle
                        let holder = input.hands.first { hand in
                            (hand.isLeft ? input.interaction.left : input.interaction.right).holding == target
                        }
                        let tab = holder.map { Gear.heldToggle(&o.meshVertices, hand: $0) }
                            ?? Gear.toggle(&o.meshVertices, center: toggle, toward: anchor)
                        let guide = layout.place(Gear.guideRingPoint(side))
                        let rear = grommets?[side < 0 ? 2 : 3]
                        let mean = points.reduce(SIMD3<Float>(0, 0, 0), +) / Float(points.count)
                        let cascade = mean + ((rear ?? guide) - mean) * 0.35
                        for p in points {
                            o.lines.append(LineSegment(p, cascade, radius: brakeUpperRadius, color: Gear.brakeOrange))
                        }
                        let path = [cascade] + (rear.map { [$0] } ?? []) + [guide + SIMD3(0, 0.004, 0), guide - SIMD3(0, 0.004, 0), tab]
                        for i in 0..<(path.count - 1) {
                            o.lines.append(LineSegment(path[i], path[i + 1], radius: brakeLowerRadius, color: Gear.brakeOrange))
                        }
                    }
                }
            }
        }

        for hand in input.hands {
            if input.gloves {
                o.gloveHands.append(hand)
                Gear.sleeve(&o.meshVertices, hand: hand)
            } else if input.proxyHands {
                o.roundCones += proxyHandCones(hand)
            }
            if hand.isLeft == input.watchOnLeft { Gear.watch(&o.meshVertices, hand: hand, gloved: input.gloves) }
        }
        return o
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

    /// 开伞拉环挂在小臂上的位置：腕关节往手肘 13 厘米、手背那一侧（袖子外面，或者真手的皮肤外面）
    static func ringMount(_ hand: HandPose, gloved: Bool) -> RingMount {
        let f = wristFrame(hand)
        let surface: Float = gloved ? 0.045 : 0.03
        let tab = f.center + f.towardElbow * 0.10 + f.back * (surface + 0.004)
        // 环立在布片上，往手腕那边歪 30°（另一只手的手指从手腕那头勾进去）
        let toward = normalize(-f.back * 0.87 + f.towardElbow * 0.5)
        return RingMount(rest: tab - toward * (0.028 + 0.004), toward: toward, facing: f.side, tab: tab, normal: f.back)
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

    /// 表带圈的半径（侧向, 手背方向）：真手手腕宽约 6 厘米、厚约 4 厘米，表带比它大一圈；
    /// 戴手套时套在手套袖口外面（袖口半径约 3.9 厘米）
    static func strapRadii(gloved: Bool) -> (Float, Float) {
        gloved ? (0.047, 0.044) : (0.037, 0.030)
    }

    /// 高度表：表盘在表带上方、手背那一侧（离皮肤约 2 厘米，深度在手前面，真手不会盖住它）。
    /// 第一版离手腕太近，真机上被手腕「切」掉一块，所以表带圈和表盘都往外放了、表也做大了。
    /// 表面朝手背外。左手：3 点钟指向手；右手反过来（3 点钟指向手肘），这样抬起哪只手看，字都是正的。
    /// 返回 (中心, 右, 上, 直径)。
    static func watchPlacement(_ h: HandPose, gloved: Bool) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float) {
        let f = wristFrame(h)
        let center = f.center + f.back * (strapRadii(gloved: gloved).1 + 0.013)
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
    mutating func placeAltimeter(feet: Int, eyeHeight: Float, watchHand: HandPose?, alarm: Int, gloved: Bool) {
        hudGlyphs = FrameUniforms.glyphs(feet: feet)
        if let watchHand {
            let (center, right, up, size) = SceneObjects.watchPlacement(watchHand, gloved: gloved)
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
