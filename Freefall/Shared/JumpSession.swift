import Foundation
import simd

/// 系统捏合手势的状态（看着哪里都行，捏住、拖动、松开）
struct PinchState: Sendable {
    struct Touch: Sendable {
        var isLeft: Bool
        var startY: Double
        /// 捏住以后手往下拉了多少（米）
        var pull: Double = 0
    }
    var touches: [Int: Touch] = [:]
    /// 新开始的捏合次数（渲染线程取走后清零）
    var began = 0
}

/// 一次跳伞的状态和每帧的推进：输入（真手 / 系统捏合 / 自动驾驶）→ 时间线 → 伞衣布料；还有给你看的提示文字。
/// app 和离屏测试共用这一份，测试里跑的就是真机上的逻辑。
final class JumpSession {
    private(set) var timeline: JumpTimeline
    private(set) var interaction = Interaction()
    let cloth = CanopyCloth()
    var autopilot: Autopilot?
    /// 用真手抓（允许了手部追踪）；否则用系统的捏合手势
    let realHands: Bool
    /// 提前拉拉手（还没报警）时，提示一直显示到这个时间
    private var tooEarlyUntil: Double?
    /// 真手抓住拉手、操纵环的次数（给声音用）
    private(set) var grabs = 0
    /// 雨丝相对你累计走过的距离（舞台空间，按盒子取模）
    private var rainOffset = SIMD3<Float>(0, 0, 0)
    static let rainBox: Float = 14
    static let rainDrops: Float = 6000

    init(timeline: JumpTimeline = JumpTimeline(), realHands: Bool, autopilot: Autopilot?) {
        self.timeline = timeline
        self.realHands = realHands
        self.autopilot = autopilot
    }

    /// 舞台空间里起跳那一刻眼睛的高度（落地时脚踩在地上）
    func setEyeHeight(_ eyeHeight: Float) {
        timeline.eyeHeight = Double(eyeHeight)
    }

    /// 提示里说「抓」「拉」还是「捏」
    var usesRealHands: Bool { realHands }
    /// 真手在操作（没开自动驾驶）
    private var handsDriving: Bool { realHands && autopilot == nil }

    /// 推进一帧
    func step(dt: Double, hands: [HandPose], pinchesBegan: Int = 0, touches: [PinchState.Touch] = [],
              layout: BodyLayout) {
        let events = interaction.update(hands: realHands ? hands : [], layout: layout, bar: timeline.bar,
                                        timeline: timeline)
        if autopilot != nil {
            autopilot!.drive(&timeline)
        } else if realHands {
            for event in events { handle(event) }
            timeline.setBrakes(left: Double(interaction.brakeLeft), right: Double(interaction.brakeRight))
        } else {
            pinchControls(began: pinchesBegan, touches: touches)
        }
        // 落地以后捏一下手指：不等了，直接结束
        if pinchesBegan > 0, timeline.phase == .landed { timeline.requestEnd() }

        timeline.step(dt)

        let v = timeline.rainVelocity
        rainOffset += SIMD3(Float(v.x), Float(v.y), Float(v.z)) * Float(dt)
        rainOffset -= (rainOffset / Self.rainBox).rounded(.down) * Self.rainBox

        if !handsDriving {
            // 没有真手去拉：拉手开伞后就没了；操纵环按刹车量往下移，看起来是被拉下去的
            if timeline.deployTime != nil {
                interaction.handlePulled = true
                interaction.handle = nil
            }
            let rest = layout.toggleRest
            interaction.toggles = (rest.0 - SIMD3(0, Float(timeline.brakeLeft) * 0.32, 0),
                                   rest.1 - SIMD3(0, Float(timeline.brakeRight) * 0.32, 0))
        }
        if let since = timeline.sinceDeploy {
            let landed = timeline.phase == .landed || timeline.phase == .done
            cloth.step(Float(dt), CanopyCloth.Input(sinceDeploy: since, eyeHeight: layout.anchor.y,
                                                    links: layout.links,
                                                    brakeLeft: Float(timeline.brakeLeft),
                                                    brakeRight: Float(timeline.brakeRight),
                                                    turnRate: Float(timeline.turnRate), landed: landed,
                                                    verticalSpeed: Float(timeline.verticalSpeed)))
        }
    }

    /// 真手：抓扶杆、松手、拉开伞拉手
    private func handle(_ event: Interaction.Event) {
        switch event {
        case .grabbedBar:
            // 实体化从抓住扶杆的那只手开始蔓延
            let hand = interaction.left.holding == .bar ? interaction.left : interaction.right
            timeline.grabBar(at: hand.point)
        case .releasedBar:
            // 两只手都松开才算松手
            if !interaction.holdingBar { timeline.releaseBar() }
        case .pulledHandle:
            timeline.requestDeploy()
        case .pulledTooEarly:
            tooEarlyUntil = timeline.time + 3
        case .grabbedHandle, .grabbedToggle:
            grabs += 1
        }
    }

    /// 没有手部追踪时用系统的捏合：捏住 = 抓扶杆、松开 = 跳；报警后捏一下 = 开伞；伞下捏住往下拉 = 拉那一侧的操纵环
    private func pinchControls(began: Int, touches: [PinchState.Touch]) {
        switch timeline.phase {
        case .cabin:
            if !touches.isEmpty, !timeline.holdingBar {
                timeline.grabBar()
            } else if touches.isEmpty, timeline.holdingBar {
                timeline.releaseBar()
            }
        case .freefall:
            if began > 0, !timeline.requestDeploy() {
                tooEarlyUntil = timeline.time + 3
            }
        case .opening, .canopy:
            var left = 0.0, right = 0.0
            for touch in touches {
                let pull = touch.pull / 0.25
                if touch.isLeft { left = max(left, pull) } else { right = max(right, pull) }
            }
            timeline.setBrakes(left: left, right: right)
        default:
            break
        }
    }

    // MARK: - 给画面用

    func objects(layout: BodyLayout, hands: [HandPose], watchOnLeft: Bool, proxyHands: Bool = false,
                 gloves: Bool = false, head: SIMD3<Float>? = nil) -> SceneObjects {
        var o = SceneObjects.make(SceneObjects.Input(timeline: timeline, eyeHeight: layout.anchor.y, layout: layout,
                                                     interaction: interaction,
                                                     cloth: timeline.sinceDeploy == nil ? nil : cloth,
                                                     hands: hands, watchOnLeft: watchOnLeft, proxyHands: proxyHands,
                                                     gloves: gloves))
        // 开场的实体化（FrameUniforms.reveal）：xyz 起点，w 波前半径（-1 = 只有扶杆，很大 = 全部完成）
        let c = timeline.revealCenter
        let radius = timeline.revealRadius.map { $0.isFinite ? Float($0) : 1e6 } ?? -1
        o.reveal = SIMD4(Float(c.x), Float(c.y), Float(c.z), radius)
        if timeline.scene.hasTerrain {
            o.terrain = TerrainFrame(scene: timeline.scene, groundOrigin: timeline.groundPosition,
                                     stageToAltitude: timeline.altitude - timeline.eyeHeight, heading: timeline.heading)
        }
        let rain = Float(timeline.rainIntensity)
        if rain > 0.005 {
            let v = timeline.rainVelocity
            // 拖影：一帧多一点（90 Hz），雨丝刚好连成一道
            o.rain = RainUniforms(offset: SIMD4(rainOffset, rain),
                                  velocity: SIMD4(Float(v.x), Float(v.y), Float(v.z), 1.2 / 90),
                                  center: SIMD4(head ?? layout.anchor, Self.rainDrops),
                                  box: SIMD4(Self.rainBox, 0, 0, 0))
        }
        return o
    }

    /// 浮在面前的提示（空 = 不显示）
    var hint: String {
        let t = timeline
        switch t.phase {
        case .cabin:
            if t.barGrabbedTime == nil {
                return usesRealHands ? "伸出右手，握住右边的黄色扶杆" : "捏住手指 = 握住扶杆"
            }
            if !t.greenLight {
                // 飞机正在长出来：别打扰，松手了就提醒再抓住
                return t.holdingBar ? "" : (usesRealHands ? "再握住扶杆" : "再捏住手指")
            }
            if t.holdingBar { return usesRealHands ? "绿灯！松手就跳" : "绿灯！松开手指就跳" }
            return usesRealHands ? "握住扶杆，松手就跳" : "捏住手指，松开就跳"
        case .exit, .opening:
            return ""
        case .freefall:
            if let until = tooEarlyUntil, t.time < until { return "还没到开伞高度\n等手表报警再拉" }
            if t.alarmLevel > 0 {
                return usesRealHands ? "开伞！\n右手抓住胸前的红色拉手，往外拉" : "开伞！捏一下手指"
            }
            if let left = t.leftRampTime, t.time - left < 6 { return "手表在 3,500 英尺报警，那时再开伞" }
            return ""
        case .canopy:
            let (clock, distance) = t.targetBearing
            let bearing = distance < 25 ? "靶就在你下面" : "靶在 \(clock) 点钟方向 · \(Int(distance / 10) * 10) 米"
            if let since = t.sinceDeploy, since < 14 {
                let how = usesRealHands ? "拉下左 / 右操纵环转向，两边一起拉减速" : "捏住往下拉：左手左转，右手右转"
                return how + "\n" + bearing
            }
            // 山区：脚下的地面比高度表的读数近得多，快撞上了
            if t.scene.hasTerrain, t.terrainClearance < 150, t.heightAboveGround - t.terrainClearance > 50 {
                return bearing + "\n离山坡只有 \(Int(t.terrainClearance)) 米，快转开"
            }
            if t.scene == .volcano, t.plumeProximity < 2.5 {
                return bearing + "\n前面是火山口的毒烟，别过去"
            }
            // 高度管理：直飞还能飞多远（和自动驾驶一样估），比离靶远太多就提醒先飞过去再掉头
            let reach = JumpTimeline.canopySpeed * max(t.heightAboveGround - 6, 0) / JumpTimeline.canopySink + 15
            if distance < 300, reach > distance + 150 { return bearing + "\n高度还多：先飞过靶，再掉头回来" }
            if reach < distance - 30 { return bearing + "\n高度不够了，对准靶直飞" }
            return bearing
        case .landed, .done:
            return resultSummary.map { $0 + "\n捏一下手指结束" } ?? ""
        }
    }

    /// 落地结果（一句话）；还没落地是 nil
    var resultSummary: String? {
        let t = timeline
        let d = t.landingDistance
        switch t.outcome {
        case .bullseye: return String(format: "正中靶心！离靶心 %.1f 米", d)
        case .inTarget: return String(format: "进靶了！离靶心 %.1f 米", d)
        case .missed:
            return t.scene == .atoll ? "落在沙洲上，离靶心 \(Int(d)) 米——没进靶" : "平安落地，离靶心 \(Int(d)) 米——没进靶"
        case .water: return "掉进水里了——离靶心 \(Int(d)) 米"
        case .crashed: return String(format: "摔了——落地时每秒 %.0f 米，开伞太晚", t.landingSpeed)
        case .terrain: return "撞上山坡了——那里太陡，落不了"
        case .trees: return "落进树林，挂在树上了——离靶心 \(Int(d)) 米"
        case .lava: return "掉进熔岩里了"
        case .crevasse: return "掉进冰裂缝了"
        case .plume: return "冲进了火山口的毒烟"
        case nil: return nil
        }
    }
}

extension JumpTimeline {
    /// 舱门边的扶杆（舞台空间）：跟着飞机走，松手往外跑时也跟着往后退
    var bar: Interaction.Bar {
        let o = planeOffset
        return Interaction.Bar(x: ProceduralMeshes.barStage.x + Float(o.x),
                               z: ProceduralMeshes.barStage.y + Float(o.z - ProceduralMeshes.standOnRamp),
                               bottom: ProceduralMeshes.barBottom + Float(o.y),
                               top: ProceduralMeshes.barTop + Float(o.y))
    }
}

/// 提示面板的位置：在视线下方一点、1.2 米外。转头 20° 以内不动，超过了再慢慢跟过来（一直粘在视线上很烦）。
struct PanelPlacer {
    static let distance: Float = 1.2
    /// 每个像素多少米（30 号字在 1.2 米外约 1.3°）
    static let metersPerPixel: Float = 0.00045

    private var yaw: Float?
    private var pitch: Float = 0
    private var following = false

    mutating func place(head: SIMD3<Float>, forward: SIMD3<Float>, dt: Float, width: Int, height: Int,
                        opacity: Float = 1) -> PanelUniforms {
        let targetYaw = atan2(-forward.x, -forward.z)
        let targetPitch = min(max(asin(min(max(forward.y, -1), 1)) - 0.17, -1.0), 0.15)
        if yaw == nil {
            yaw = targetYaw
            pitch = targetPitch
        }
        let dyaw = remainder(targetYaw - yaw!, 2 * .pi)
        let dpitch = targetPitch - pitch
        let off = (dyaw * dyaw + dpitch * dpitch).squareRoot()
        if off > 0.35 { following = true }
        if following {
            let k = min(dt * 4, 1)
            yaw! += dyaw * k
            pitch += dpitch * k
            if off < 0.04 { following = false }
        }
        let cy = cos(yaw!), sy = sin(yaw!), cp = cos(pitch), sp = sin(pitch)
        let direction = SIMD3<Float>(-sy * cp, sp, -cy * cp)
        let right = normalize(cross(direction, SIMD3(0, 1, 0)))
        let up = cross(right, direction)
        return PanelUniforms(center: SIMD4(head + direction * Self.distance, Float(width) * Self.metersPerPixel),
                             right: SIMD4(right, Float(height) * Self.metersPerPixel), up: SIMD4(up, opacity))
    }
}
