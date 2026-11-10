import Foundation
import simd

/// 身上能抓的东西在舞台空间里的位置。身体跟着头的水平位置走，朝向固定朝前（伞和背带一直朝前飞）。
struct BodyLayout {
    /// (头的 x, 起跳时的眼高, 头的 z)
    var anchor: SIMD3<Float>

    /// 开伞拉手：右胸前的红色小枕头（插在主承重带上的口袋里，见 Gear.handleRest）
    var handleRest: SIMD3<Float> { anchor + Gear.handleRest }
    /// 左右操纵环：挂在后背带上，垂到下巴两侧前方
    var toggleRest: (SIMD3<Float>, SIMD3<Float>) {
        (anchor + SIMD3(-0.27, -0.07, -0.15), anchor + SIMD3(0.27, -0.07, -0.15))
    }
    var shoulders: (SIMD3<Float>, SIMD3<Float>) {
        (anchor + SIMD3(-0.17, -0.22, 0.04), anchor + SIMD3(0.17, -0.22, 0.04))
    }
    /// 背带上端（伞绳汇到这里）
    var links: (SIMD3<Float>, SIMD3<Float>) {
        (anchor + SIMD3(-0.21, 0.38, -0.06), anchor + SIMD3(0.21, 0.38, -0.06))
    }
}

/// 手的抓握判定和「手里抓着什么」。真机上每帧用 ARKit 的手更新；离屏测试直接摆状态。
struct Interaction {
    enum Target: Equatable { case bar, handle, leftToggle, rightToggle }

    enum Event: Equatable {
        case grabbedBar, releasedBar
        case grabbedHandle, pulledHandle, pulledTooEarly
        case grabbedToggle
    }

    struct Hand {
        var grasping = false
        var point = SIMD3<Float>(0, 0, 0)
        var holding: Target?
        /// 连续几帧没追踪到。手偶尔会跑出追踪范围一下：抓着扶杆时手一丢就算松手，会莫名其妙跳下去，所以等半秒
        var lostFrames = 0
    }

    /// 手丢了多少帧（90 Hz）以后才算松手
    static let lostFrameLimit = 45

    var left = Hand()
    var right = Hand()
    /// 开伞拉手现在的位置（被抓着时跟着手；拉出来以后 nil = 扔掉了）
    var handle: SIMD3<Float>?
    var handlePulled = false
    private var warnedTooEarly = false
    /// 两个操纵环现在的位置（松手后弹回去）
    var toggles: (SIMD3<Float>, SIMD3<Float>)?
    var brakeLeft: Float = 0
    var brakeRight: Float = 0

    /// 手是不是在抓：捏住（拇指尖碰食指尖）或者握拳，带一点迟滞避免抖动。返回抓的点。
    static func grasp(_ h: HandPose, wasGrasping: Bool) -> (Bool, SIMD3<Float>) {
        let palm = h[.wrist] + (h[.middleKnuckle] - h[.wrist]) * 0.55
        let pinch = distance(h[.thumbTip], h[.indexTip])
        let tips: [HandJoint] = [.indexTip, .middleTip, .ringTip, .littleTip]
        let curl = tips.map { distance(h[$0], palm) }.reduce(0, +) / Float(tips.count)
        let grasping = wasGrasping ? (pinch < 0.035 || curl < 0.08) : (pinch < 0.022 || curl < 0.065)
        let point = pinch < 0.04 ? (h[.thumbTip] + h[.indexTip]) * 0.5 : palm
        return (grasping, point)
    }

    /// 扶杆在舞台空间里的竖线（跟着飞机走）
    struct Bar {
        var x: Float, z: Float, bottom: Float, top: Float
    }

    mutating func update(hands: [HandPose], layout: BodyLayout, bar: Bar?, timeline: JumpTimeline) -> [Event] {
        var events: [Event] = []
        let rest = layout.handleRest
        if handle == nil && !handlePulled { handle = rest }
        let restToggles = layout.toggleRest
        if toggles == nil { toggles = restToggles }

        for isLeft in [true, false] {
            var hand = isLeft ? left : right
            guard let pose = hands.first(where: { $0.isLeft == isLeft }) else {
                hand.lostFrames += 1
                if hand.lostFrames > Self.lostFrameLimit || hand.holding == nil {
                    if hand.holding == .bar { events.append(.releasedBar) }
                    hand = Hand(lostFrames: hand.lostFrames)
                }
                if isLeft { left = hand } else { right = hand }
                continue
            }
            hand.lostFrames = 0
            let (grasping, point) = Self.grasp(pose, wasGrasping: hand.grasping)
            let started = grasping && !hand.grasping
            hand.grasping = grasping
            hand.point = point

            if started, hand.holding == nil {
                if let bar, timeline.phase == .cabin,
                   simd_length(SIMD2(point.x - bar.x, point.z - bar.z)) < 0.1,
                   point.y > bar.bottom, point.y < bar.top {
                    hand.holding = .bar
                    events.append(.grabbedBar)
                } else if let handle, timeline.phase == .freefall, distance(point, handle) < 0.1 {
                    hand.holding = .handle
                    events.append(.grabbedHandle)
                } else if let toggles, timeline.phase == .opening || timeline.phase == .canopy {
                    let dl = distance(point, toggles.0), dr = distance(point, toggles.1)
                    if min(dl, dr) < 0.12 {
                        hand.holding = dl < dr ? .leftToggle : .rightToggle
                        events.append(.grabbedToggle)
                    }
                }
            } else if !grasping, let holding = hand.holding {
                if holding == .bar { events.append(.releasedBar) }
                hand.holding = nil
            }

            switch hand.holding {
            case .handle:
                let pull = distance(point, rest)
                if pull > 0.2 {
                    if timeline.canDeploy {
                        handle = point
                        if !handlePulled { handlePulled = true; events.append(.pulledHandle) }
                    } else {
                        // 还没到开伞高度：拉手拉不动
                        handle = rest + simd_normalize(point - rest) * 0.04
                        if !warnedTooEarly { warnedTooEarly = true; events.append(.pulledTooEarly) }
                    }
                } else {
                    handle = handlePulled ? point : rest + (point - rest) * 0.25
                }
            case .leftToggle:
                toggles?.0 = point
            case .rightToggle:
                toggles?.1 = point
            default:
                break
            }
            if isLeft { left = hand } else { right = hand }
        }

        // 松手：拉手拉出来以后扔掉；没拉出来弹回原位；操纵环弹回去
        if left.holding != .handle && right.holding != .handle {
            if handlePulled { handle = nil } else { handle = rest; warnedTooEarly = false }
        }
        if var t = toggles {
            if left.holding != .leftToggle && right.holding != .leftToggle { t.0 += (restToggles.0 - t.0) * 0.25 }
            if left.holding != .rightToggle && right.holding != .rightToggle { t.1 += (restToggles.1 - t.1) * 0.25 }
            toggles = t
            // 往下拉 32 厘米 = 拉到底
            brakeLeft = min(max((restToggles.0.y - t.0.y) / 0.32, 0), 1)
            brakeRight = min(max((restToggles.1.y - t.1.y) / 0.32, 0), 1)
        }
        return events
    }

    var holdingBar: Bool { left.holding == .bar || right.holding == .bar }
}
