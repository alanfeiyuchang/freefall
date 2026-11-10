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

/// 和 Shaders/Objects.h 的 RoundCone 一样：两端半径不同的胶囊
struct RoundCone {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var color: SIMD4<Float>

    init(_ a: SIMD3<Float>, _ ra: Float, _ b: SIMD3<Float>, _ rb: Float, _ color: SIMD3<Float>,
         _ material: MeshMaterial = .glove) {
        self.a = SIMD4(a, ra)
        self.b = SIMD4(b, rb)
        self.color = SIMD4(color, material.rawValue)
    }
}

/// 这一帧场景里的实体：飞机、伞衣和伞绳、手套和背带、高度表的位置。
/// app 和离屏测试都用 `make` 从时间线算出来，两边画的东西一模一样。
struct SceneObjects {
    /// 飞机 → 舞台（nil 不画：太远了）
    var planeTransform: simd_float4x4?
    var jumpLightGreen = false
    /// 还在机舱里的程度（手套和背带的光照）
    var inCabin: Float = 0
    /// 伞衣 → 舞台（nil 还没开伞）
    var canopyTransform: simd_float4x4?
    /// 伞绳汇到的两个点（左右背带的上端）
    var canopyLinks = (SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0))
    /// 手套和背带
    var roundCones: [RoundCone] = []

    // 手套的颜色：深灰的布面，袖口一圈橙色（照原视频）
    static let gloveColor = SIMD3<Float>(0.038, 0.038, 0.044)
    static let cuffColor = SIMD3<Float>(0.05, 0.05, 0.056)
    static let bandColor = SIMD3<Float>(0.62, 0.17, 0.025)
    static let webbingColor = SIMD3<Float>(0.09, 0.09, 0.1)

    static func make(timeline: JumpTimeline, eyeHeight: Float, hands: [HandPose]) -> SceneObjects {
        var o = SceneObjects()
        o.jumpLightGreen = timeline.greenLight
        o.inCabin = Float(timeline.inCabin)
        if timeline.planeDistance < 4000 {
            let offset = timeline.planeOffset
            o.planeTransform = translation(SIMD3(Float(offset.x), Float(offset.y), Float(offset.z)))
        }

        let open = Float(timeline.canopyOpen)
        if open > 0 {
            // 伞衣在头顶上方 4 米、略靠前，前缘朝 -Z 往下压 8°。张开过程：从一小团变大、升高、鼓起来
            let lift = 1.6 + 2.5 * open
            let spanScale = 0.15 + 0.85 * open, chordScale = 0.35 + 0.65 * open, inflate = 0.3 + 0.7 * open
            o.canopyTransform = translation(SIMD3(0, eyeHeight + lift, -0.9))
                * simd_float4x4(simd_quatf(angle: -8 * .pi / 180, axis: SIMD3(1, 0, 0)))
                * scale(SIMD3(spanScale, inflate, chordScale))
            // 背带：从肩膀往上到伞绳汇合的连接环
            let leftShoulder = SIMD3<Float>(-0.17, eyeHeight - 0.22, 0.04)
            let rightShoulder = SIMD3<Float>(0.17, eyeHeight - 0.22, 0.04)
            let leftLink = SIMD3<Float>(-0.21, eyeHeight + 0.38, -0.06)
            let rightLink = SIMD3<Float>(0.21, eyeHeight + 0.38, -0.06)
            o.canopyLinks = (leftLink, rightLink)
            o.roundCones.append(RoundCone(leftShoulder, 0.008, leftLink, 0.006, webbingColor))
            o.roundCones.append(RoundCone(rightShoulder, 0.008, rightLink, 0.006, webbingColor))
        }

        for hand in hands {
            o.roundCones += gloveCones(hand)
        }
        return o
    }

    /// 手套：每节手指一段胶囊，手掌是从手腕扇形散开的几段粗胶囊，手腕一截袖口加一圈橙色。
    /// 关节就是骨骼，不用重定向；手套比手粗一圈，所以半径比真手指大 2 毫米左右。
    static func gloveCones(_ h: HandPose) -> [RoundCone] {
        var c: [RoundCone] = []
        let fingers: [(HandJoint, HandJoint, HandJoint, HandJoint, Float)] = [
            (.indexKnuckle, .indexIntermediateBase, .indexIntermediateTip, .indexTip, 1.0),
            (.middleKnuckle, .middleIntermediateBase, .middleIntermediateTip, .middleTip, 1.03),
            (.ringKnuckle, .ringIntermediateBase, .ringIntermediateTip, .ringTip, 0.98),
            (.littleKnuckle, .littleIntermediateBase, .littleIntermediateTip, .littleTip, 0.86),
        ]
        for (k, b, t, tip, s) in fingers {
            c.append(RoundCone(h[k], 0.0115 * s, h[b], 0.0106 * s, gloveColor))
            c.append(RoundCone(h[b], 0.0106 * s, h[t], 0.0098 * s, gloveColor))
            c.append(RoundCone(h[t], 0.0098 * s, h[tip], 0.009 * s, gloveColor))
        }
        c.append(RoundCone(h[.thumbKnuckle], 0.0138, h[.thumbIntermediateBase], 0.0127, gloveColor))
        c.append(RoundCone(h[.thumbIntermediateBase], 0.0127, h[.thumbIntermediateTip], 0.0116, gloveColor))
        c.append(RoundCone(h[.thumbIntermediateTip], 0.0116, h[.thumbTip], 0.0104, gloveColor))
        // 手掌
        let w = h[.wrist]
        c.append(RoundCone(w, 0.02, h[.indexKnuckle], 0.0145, gloveColor))
        c.append(RoundCone(w, 0.021, h[.middleKnuckle], 0.015, gloveColor))
        c.append(RoundCone(w, 0.02, h[.ringKnuckle], 0.0145, gloveColor))
        c.append(RoundCone(w, 0.019, h[.littleKnuckle], 0.013, gloveColor))
        c.append(RoundCone(h[.indexKnuckle], 0.0135, h[.littleKnuckle], 0.0125, gloveColor))
        c.append(RoundCone(w, 0.021, h[.thumbKnuckle], 0.0155, gloveColor))
        // 袖口和橙色的一圈
        let fw = h[.forearmWrist]
        let arm = normalize(h[.forearmArm] - fw)
        c.append(RoundCone(fw - arm * 0.005, 0.03, fw + arm * 0.075, 0.032, cuffColor))
        c.append(RoundCone(fw + arm * 0.035, 0.0336, fw + arm * 0.056, 0.0338, bandColor))
        return c
    }

    /// 左手腕上的高度表：贴在袖口手背那一侧，3 点钟指向手，表面朝手背外。
    /// 返回 (中心, 右, 上, 直径)。
    static func watchPlacement(_ h: HandPose) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float) {
        let fw = h[.forearmWrist], wrist = h[.wrist]
        let towardElbow = normalize(h[.forearmArm] - fw)
        // 左手：食指根 → 小指根 叉乘出来的是手背方向（右手是手心，这里只给左手用）
        var back = normalize(cross(h[.indexKnuckle] - wrist, h[.littleKnuckle] - wrist))
        back = normalize(back - dot(back, towardElbow) * towardElbow)
        let center = fw + towardElbow * 0.045 + back * 0.0345
        let right = -towardElbow
        let up = cross(back, right)
        return (center, right, up, 0.046)
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
    /// 高度表：追踪到左手就戴在左手腕上（圆表盘），否则是起跳时头前下方的一块面板。
    mutating func placeAltimeter(feet: Int, eyeHeight: Float, leftHand: HandPose?) {
        hudGlyphs = FrameUniforms.glyphs(feet: feet)
        if let leftHand {
            let (center, right, up, size) = SceneObjects.watchPlacement(leftHand)
            hudCenter = SIMD4(center, size)
            hudRight = SIMD4(right, size)
            hudUp = SIMD4(up, 1)
            hudStyle = SIMD4(1, min(max(Float(feet) / 30000, 0), 1), 0, 0)
        } else {
            let center = SIMD3<Float>(0, eyeHeight - 0.30, -0.50)
            let toEye = normalize(SIMD3<Float>(0, eyeHeight, 0) - center)
            let right = SIMD3<Float>(1, 0, 0)
            hudCenter = SIMD4(center, 0.15)
            hudRight = SIMD4(right, 0.05)
            hudUp = SIMD4(cross(toEye, right), 1)
            hudStyle = SIMD4(0, 0, 0, 0)
        }
    }
}
