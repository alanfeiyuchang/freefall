import Foundation
import simd

/// 身上能抓的东西在舞台空间里的位置。身体原点跟着头的水平位置走，朝向（yaw）由 BodyYaw 按头和两只手猜。
/// 身体坐标：原点是身体朝正前方时眼睛的位置，-Z 朝前，+X 朝右。
struct BodyLayout {
    /// (头的 x, 起跳时的眼高, 头的 z)：身体朝正前方时眼睛的位置
    var anchor: SIMD3<Float>
    /// 身体朝向（弧度，0 = 舞台的 -Z，正 = 往左转）
    var yaw: Float = 0

    /// 身体坐标 → 舞台空间
    func place(_ local: SIMD3<Float>) -> SIMD3<Float> { anchor + direction(local) }
    /// 只转方向
    func direction(_ local: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(local.x * c + local.z * s, local.y, -local.x * s + local.z * c)
    }
    /// 身体 → 舞台的矩阵（不动的装备网格用）
    var transform: simd_float4x4 {
        translation(anchor) * simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
    }

    /// 开伞拉环：左右大臂前面各一个（side -1 左、1 右），拉哪个都行（见 Gear.ringRest）
    func ringRest(_ side: Float) -> SIMD3<Float> { place(Gear.ringRest(side)) }
    /// 左右操纵环：挂在后背带上，垂到下巴两侧前方
    var toggleRest: (SIMD3<Float>, SIMD3<Float>) {
        (place(SIMD3(-0.27, -0.07, -0.15)), place(SIMD3(0.27, -0.07, -0.15)))
    }
    var shoulders: (SIMD3<Float>, SIMD3<Float>) {
        (place(SIMD3(-0.17, -0.22, 0.04)), place(SIMD3(0.17, -0.22, 0.04)))
    }
    /// 背带上端（伞绳汇到这里）
    var links: (SIMD3<Float>, SIMD3<Float>) {
        (place(SIMD3(-0.21, 0.38, -0.06)), place(SIMD3(0.21, 0.38, -0.06)))
    }
}

/// 身体朝哪：身体没有追踪，只能按头和手猜。
/// - 只转头的时候身体不动；头转出去超过 40°，身体被带着转到 40° 以内；头一直偏着，身体几秒内慢慢跟过去。
/// - 两只手都在面前时，身体大致朝着两只手中间（手一般在身体前面），跟得快一些，也不按头的角度硬拽。
/// - 伞下身体挂在伞绳上，锁回正前方（和伞同一个朝向）。
struct BodyYaw {
    private(set) var yaw: Float = 0
    private var started = false

    private static func wrap(_ a: Float) -> Float { remainder(a, 2 * .pi) }

    mutating func update(head: SIMD3<Float>, headForward: SIMD3<Float>, hands: [HandPose], dt: Float,
                         locked: Bool) -> Float {
        if locked {
            yaw += Self.wrap(-yaw) * min(dt / 0.6, 1)
            return yaw
        }
        let flat = SIMD2(headForward.x, headForward.z)
        // 低头看脚、抬头看天时，头的水平朝向不可靠：身体不动
        guard simd_length(flat) > 0.35 else { return yaw }
        let headYaw = atan2(-flat.x, -flat.y)
        if !started { yaw = headYaw; started = true }
        var target = headYaw, rate: Float = 0.3, deadZone: Float = 40 * .pi / 180
        if let l = hands.first(where: { $0.isLeft }), let r = hands.first(where: { !$0.isLeft }) {
            let neck = head - SIMD3(flat.x, 0, flat.y) / simd_length(flat) * 0.09
            let mid = (l[.wrist] + r[.wrist]) * 0.5
            let v = SIMD2(mid.x - neck.x, mid.z - neck.z)
            if simd_length(v) > 0.18, mid.y < head.y - 0.1 {
                let handsYaw = atan2(-v.x, -v.y)
                target = handsYaw + Self.wrap(headYaw - handsYaw) * 0.35
                rate = 2.0
                deadZone = 75 * .pi / 180
            }
        }
        let off = Self.wrap(headYaw - yaw)
        if abs(off) > deadZone { yaw += off - (off > 0 ? deadZone : -deadZone) }
        yaw = Self.wrap(yaw + Self.wrap(target - yaw) * min(dt * rate, 1))
        return yaw
    }
}

/// 手的抓握判定和「手里抓着什么」。真机上每帧用 ARKit 的手更新；离屏测试直接摆状态。
struct Interaction {
    /// handle(0) 左大臂的拉环，handle(1) 右大臂的
    enum Target: Equatable { case bar, handle(Int), leftToggle, rightToggle }

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
    /// 两个开伞拉环现在的位置（0 左、1 右；被抓着时跟着手；拉出来的那个松手后是 nil = 扔掉了）
    var rings: [SIMD3<Float>?] = [nil, nil]
    var handlePulled = false
    /// 拉开伞的是哪个环
    var pulledRing: Int?
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
        let rests = [layout.ringRest(-1), layout.ringRest(1)]
        for i in 0..<2 where rings[i] == nil && pulledRing != i { rings[i] = rests[i] }
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
                } else if timeline.phase == .freefall,
                          let i = (0..<2).min(by: { a, b in
                              (rings[a].map { distance(point, $0) } ?? .infinity) < (rings[b].map { distance(point, $0) } ?? .infinity)
                          }), let ring = rings[i], distance(point, ring) < 0.1 {
                    hand.holding = .handle(i)
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
            case .handle(let i):
                let rest = rests[i]
                let pull = distance(point, rest)
                if pull > 0.2 {
                    if timeline.canDeploy {
                        rings[i] = point
                        if !handlePulled { handlePulled = true; pulledRing = i; events.append(.pulledHandle) }
                    } else {
                        // 还没到开伞高度：拉环拉不动
                        rings[i] = rest + simd_normalize(point - rest) * 0.04
                        if !warnedTooEarly { warnedTooEarly = true; events.append(.pulledTooEarly) }
                    }
                } else {
                    rings[i] = pulledRing == i ? point : rest + (point - rest) * 0.25
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

        // 松手：拉开伞的那个环扔掉；另一个（或者没拉出来的）弹回原位；操纵环弹回去
        for i in 0..<2 where left.holding != .handle(i) && right.holding != .handle(i) {
            rings[i] = pulledRing == i ? nil : rests[i]
        }
        if !(0..<2).contains(where: { left.holding == .handle($0) || right.holding == .handle($0) }) {
            warnedTooEarly = false
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
