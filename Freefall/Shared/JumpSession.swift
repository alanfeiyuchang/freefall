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
    /// 落地那一刻身体的位置和朝向：落地以后伞衣塌在那里、伞绳拖在脚边，不再跟着人转
    private var landedLayout: BodyLayout?
    /// 提前拉拉手（还没报警）时，提示一直显示到这个时间
    private var tooEarlyUntil: Double?
    /// 真手抓住拉手、操纵环的次数（给声音用）
    private(set) var grabs = 0
    /// 雨丝相对你累计走过的距离（舞台空间，按盒子取模）
    private var rainOffset = SIMD3<Float>(0, 0, 0)
    static let rainBox: Float = 14
    static let rainDrops: Float = 6000
    /// 雾团：同上，盒子大一些
    private var mistOffset = SIMD3<Float>(0, 0, 0)
    static let mistBox: Float = 44
    static let mistPuffs: Float = 180
    /// 淋湿的程度 0…1：在雨里、云里越来越湿，出来以后被风吹得慢慢干一点
    private(set) var wetness: Double = 0
    /// 戴手套（拉环挂在袖子外面）、高度表戴在哪只手腕上：渲染器开场设一次
    var gloved = true { didSet { interaction.gloved = gloved } }
    var watchOnLeft = true {
        didSet {
            interaction.ringArm = watchOnLeft ? 1 : 0
            timeline.barOnLeft = !watchOnLeft          // 扶杆在戴表那只手的另一边
        }
    }
    /// 开跳时已经解锁的皮肤（渲染器开场设一次）：落地时提示这一跳新解锁了什么（真正记下来在 AppModel.fallEnded，规则同一套）
    var skinUnlocks = SkinUnlocks()
    /// 航线（落地后开始窗口里的俯视回放）：开伞以后每半秒记一个地面位置，最后加上落点
    private(set) var track: [SIMD2<Float>] = []
    private var lastTrackTime = -1.0
    /// 开伞那一刻：地面位置和离着陆区多高（英尺）
    private(set) var deployPoint: SIMD2<Float>?
    private(set) var deployFeet: Int?

    private func recordTrack() {
        let t = timeline
        let p = SIMD2<Float>(Float(t.groundPosition.x), Float(t.groundPosition.y))
        if t.phase == .opening, deployPoint == nil {
            deployPoint = p
            deployFeet = t.altitudeFeet
        }
        guard deployPoint != nil else { return }
        if t.phase == .opening || t.phase == .canopy, t.time - lastTrackTime >= 0.5 {
            track.append(p)
            lastTrackTime = t.time
        } else if t.landedTime != nil, track.last != p {
            track.append(p)          // 落点（落地以后位置不再变）
        }
    }

    /// 头盔 HUD 开没开（两侧的读数和提示）。默认关，点一下手腕上的表开 / 关；舱里开场的提示（握住扶杆、绿灯松手）不管开没开都显示。
    /// 没有手部追踪时点不了表，一直开着
    var hudOn = false {
        didSet { if hudOn != oldValue { hudToggleTime = timeline.time } }
    }
    private var hudToggleTime: Double = -100
    /// 另一只手的食指正碰着表盘（离开 5 厘米以后才能再点一次）
    private var touchingWatch = false
    /// 点了几次表（给声音用）
    private(set) var watchTaps = 0
    /// 按住表（真手）/ 两只手一起捏住不动（系统捏合）从什么时候开始：按满 quitHold 秒退出这一跳
    private var quitHoldStart: Double?
    static let quitHold = 2.0
    /// 按住多久以后才在提示里显示退出的进度（点一下表开关 HUD 不该闪出这一行）
    private static let quitHintDelay = 0.35

    init(timeline: JumpTimeline = JumpTimeline(), realHands: Bool, autopilot: Autopilot?) {
        self.timeline = timeline
        self.realHands = realHands
        self.autopilot = autopilot
        self.hudOn = !realHands
    }

    /// 自动拉平（见 JumpTimeline.autoFlare；开始窗口里「拉平」选手动时关掉）
    var autoFlare: Bool {
        get { timeline.autoFlare }
        set { timeline.autoFlare = newValue }
    }

    /// 伞下拉左 / 右操纵环能不能转向（见 JumpTimeline.toggleSteering）
    var toggleSteering: Bool {
        get { timeline.toggleSteering }
        set { timeline.toggleSteering = newValue }
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
        if handsDriving { checkWatchTap(hands) }
        if autopilot != nil {
            autopilot!.drive(&timeline)
        } else if realHands {
            for event in events { handle(event) }
            timeline.setBrakes(left: Double(interaction.brakeLeft), right: Double(interaction.brakeRight))
            timeline.setDive(left: Double(interaction.diveLeft), right: Double(interaction.diveRight))
        } else {
            pinchControls(began: pinchesBegan, touches: touches)
            if autopilot == nil { checkPinchQuit(touches) }
        }
        // 落地以后捏一下手指：不等了，直接结束
        if pinchesBegan > 0, timeline.phase == .landed { timeline.requestEnd() }
        timeline.setBodyYaw(Double(layout.yaw))

        timeline.step(dt)
        recordTrack()

        let v = timeline.rainVelocity
        rainOffset += SIMD3(Float(v.x), Float(v.y), Float(v.z)) * Float(dt)
        rainOffset -= (rainOffset / Self.rainBox).rounded(.down) * Self.rainBox
        let air = timeline.airVelocity
        mistOffset += SIMD3(Float(air.x), Float(air.y), Float(air.z)) * Float(dt)
        mistOffset -= (mistOffset / Self.mistBox).rounded(.down) * Self.mistBox
        let soak = timeline.rainIntensity * 0.1 + timeline.inCloudDeck * 0.06
        wetness = soak > 0.005 ? min(1, wetness + soak * dt) : max(0, wetness - 0.004 * dt)

        if !handsDriving {
            // 没有真手去拉：拉手开伞后就没了；操纵环按刹车量往下移，看起来是被拉下去的
            if timeline.deployTime != nil, !interaction.handlePulled {
                interaction.handlePulled = true
                interaction.pulledRing = interaction.ringArm
                interaction.rings[interaction.ringArm] = nil
            }
            let rest = layout.toggleRest
            interaction.toggles = (rest.0 - SIMD3(0, Float(timeline.brakeLeft) * 0.32, 0),
                                   rest.1 - SIMD3(0, Float(timeline.brakeRight) * 0.32, 0))
        }
        if let since = timeline.sinceDeploy {
            let landed = timeline.phase == .landed || timeline.phase == .done
            if landed, landedLayout == nil { landedLayout = layout }
            let layout = landedLayout ?? layout
            cloth.step(Float(dt), CanopyCloth.Input(sinceDeploy: since, eyeHeight: layout.anchor.y,
                                                    links: layout.links,
                                                    brakeLeft: Float(timeline.brakeLeft),
                                                    brakeRight: Float(timeline.brakeRight),
                                                    turnRate: Float(timeline.turnRate), landed: landed,
                                                    verticalSpeed: Float(timeline.verticalSpeed),
                                                    yaw: layout.yaw, pivot: layout.anchor))
        }
    }

    /// 点表：另一只手的食指尖碰到表盘（表盘边上 1.5 厘米以内），开 / 关 HUD。表跟着飞机一起长出来，长完才点得到
    private func checkWatchTap(_ hands: [HandPose]) {
        guard timeline.phase != .cabin || timeline.revealProgress >= 1,
              let watch = hands.first(where: { $0.isLeft == watchOnLeft }),
              let finger = hands.first(where: { $0.isLeft != watchOnLeft }) else {
            touchingWatch = false
            return
        }
        let (center, _, _, size) = SceneObjects.watchPlacement(watch, gloved: gloved)
        let d = distance(finger[.indexTip], center)
        let free = (finger.isLeft ? interaction.left : interaction.right).holding == nil
        if !touchingWatch, free, d < size / 2 + 0.015 {
            touchingWatch = true
            hudOn.toggle()
            watchTaps += 1
            quitHoldStart = timeline.time
        } else if touchingWatch, d > size / 2 + 0.05 {
            touchingWatch = false
            quitHoldStart = nil
        }
        // 一直按着表：按满两秒退出这一跳（点一下开关 HUD 的那一下已经切过了，退出时无所谓）
        if touchingWatch, let start = quitHoldStart, timeline.time - start >= Self.quitHold {
            quitHoldStart = nil
            timeline.quit()
        }
    }

    /// 没有手部追踪：两只手一起捏住、不往下拉，两秒退出（舱里不算：捏住就是握着扶杆，等绿灯时常常两只手一起捏）
    private func checkPinchQuit(_ touches: [PinchState.Touch]) {
        let both = touches.contains { $0.isLeft } && touches.contains { !$0.isLeft }
        guard both, touches.allSatisfy({ $0.pull < 0.04 }), timeline.phase != .cabin, timeline.phase != .landed,
              timeline.phase != .done else {
            quitHoldStart = nil
            return
        }
        let start = quitHoldStart ?? timeline.time
        quitHoldStart = start
        if timeline.time - start >= Self.quitHold {
            quitHoldStart = nil
            timeline.quit()
        }
    }

    /// 退出按到哪了：0…1；没在按、或者刚按下去还不到显示的时候是 nil
    var quitProgress: Double? {
        guard let start = quitHoldStart, !timeline.quitting else { return nil }
        let held = timeline.time - start
        guard held >= Self.quitHintDelay else { return nil }
        return min(held / Self.quitHold, 1)
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

    /// 画面用的航向（世界绕你转多少）
    var displayHeading: Double { timeline.heading }

    func objects(layout: BodyLayout, hands: [HandPose], watchOnLeft: Bool,
                 proxyHands: Bool = false, gloves: Bool = false, head: SIMD3<Float>? = nil) -> SceneObjects {
        let layout = landedLayout ?? layout
        var o = SceneObjects.make(SceneObjects.Input(timeline: timeline, eyeHeight: layout.anchor.y, layout: layout,
                                                     interaction: interaction,
                                                     cloth: timeline.sinceDeploy == nil ? nil : cloth,
                                                     hands: hands, watchOnLeft: watchOnLeft, proxyHands: proxyHands,
                                                     gloves: gloves))
        // 开场的实体化（FrameUniforms.reveal）：xyz 起点，w 波前半径（-1 = 只有扶杆，很大 = 全部完成）
        let c = timeline.revealCenter
        let radius = timeline.revealRadius.map { $0.isFinite ? Float($0) : 1e6 } ?? -1
        o.reveal = SIMD4(Float(c.x), Float(c.y), Float(c.z), radius)
        // （没有地形的环礁也给：实体模型要用它换到舞台空间）
        o.terrain = TerrainFrame(scene: timeline.scene, groundOrigin: timeline.groundPosition,
                                 stageToAltitude: timeline.altitude - timeline.eyeHeight, heading: displayHeading)
        let rain = Float(timeline.rainIntensity)
        if rain > 0.005 {
            let v = timeline.rainVelocity
            // 拖影：一帧多一点（90 Hz），雨丝刚好连成一道
            o.rain = RainUniforms(offset: SIMD4(rainOffset, rain),
                                  velocity: SIMD4(Float(v.x), Float(v.y), Float(v.z), 1.2 / 90),
                                  center: SIMD4(head ?? layout.anchor, Self.rainDrops),
                                  box: SIMD4(Self.rainBox, 0, 0, 0))
        }
        if timeline.phase != .cabin, timeline.phase != .exit, timeline.landedTime == nil, timeline.inCloudBand {
            let v = timeline.airVelocity
            o.mist = RainUniforms(offset: SIMD4(mistOffset, 1),
                                  velocity: SIMD4(Float(v.x), Float(v.y), Float(v.z), 0.02),
                                  center: SIMD4(head ?? layout.anchor, Self.mistPuffs),
                                  box: SIMD4(Self.mistBox, 0, 0, 0))
        }
        o.wetness = Float(wetness)
        o.rings = ringInstances()
        return o
    }

    /// 这一帧要画的光环（舞台空间）：迎面过来的前几个，最近的那个最亮；就在眼睛下面一点的高度
    private func ringInstances() -> [RingInstance] {
        let t = timeline
        guard t.phase == .freefall, let epoch = t.ringEpoch else { return [] }
        var out: [RingInstance] = []
        for i in t.nextRing..<min(t.nextRing + 4, t.rings.count) {
            let ring = t.rings[i]
            let ahead = Float((epoch + ring.arrival - t.time) * JumpTimeline.ringClosing)
            guard ahead < 150 else { continue }
            let isNext = i == t.nextRing
            let pulse = isNext ? 1 + 0.2 * sin(Float(t.time) * 7) : 1
            let fade = min(max((150 - ahead) / 30, 0), 1)             // 远处淡入
            out.append(RingInstance(center: SIMD4(Float(ring.x - t.trackX), Float(t.eyeHeight) - 1.1, -ahead,
                                                  Float(JumpTimeline.ringRadius)),
                                    color: SIMD4(0.25, 0.9, 1.0, (isNext ? 1.6 : 0.8) * pulse * fade)))
        }
        // 刚穿过去的那个：在身后来不及看，换成眼前一圈金色的光往外散开（半秒）
        if t.nextRing > 0, let passed = t.rings[t.nextRing - 1].passedTime {
            let k = Float((t.time - passed) / 0.5)
            if k < 1 {
                out.append(RingInstance(center: SIMD4(0, Float(t.eyeHeight) - 1.1, -6 - 10 * k,
                                                      Float(JumpTimeline.ringRadius) * (1 + 1.5 * k)),
                                        color: SIMD4(1.0, 0.75, 0.25, 1.8 * (1 - k))))
            }
        }
        return out
    }

    /// 头盔 HUD 的读数（HelmetHUD）。两侧的读数要 HUD 开着、开场实体化也完成了才开机（0.35 秒的开机动画），关掉时 0.15 秒收回去；
    /// 下沿那一行提示开场就在（舱里的提示一直显示，其他的跟着 HUD 开关）
    var hudState: HelmetHUD.State {
        let t = timeline
        var h = HelmetHUD.State()
        if hudOn {
            // 开场实体化完成以后才开机（直接从空中开始的没有开场）
            let ready = t.barGrabbedTime.map { $0 + JumpTimeline.revealDuration } ?? (t.phase == .cabin ? .infinity : 0)
            // 开机动画 0.35 秒（第一版 1.2 秒：点了表要等一秒多读数才扫完，太慢）
            h.boot = Float((t.time - max(hudToggleTime, ready)) / 0.35)
        } else if t.time - hudToggleTime < 0.15 {
            h.boot = Float(1 - (t.time - hudToggleTime) / 0.15)
        }
        h.hintBoot = Float(min(t.time / 0.3, 1))
        switch t.phase {
        case .cabin: h.phase = t.greenLight ? "READY" : "STANDBY"
        case .exit: h.phase = "EXIT"
        case .freefall: h.phase = "FREEFALL"
        case .opening: h.phase = "DEPLOY"
        case .canopy: h.phase = "CANOPY"
        case .landed, .done: h.phase = "LANDED"
        }
        h.altitudeFeet = t.altitudeFeet
        h.aglMeters = Int(max(t.terrainClearance, 0))
        h.fallSpeedKmh = Int(max(t.verticalSpeed, 0) * 3.6)
        h.alarm = t.alarmLevel
        h.headingDeg = Float(-t.flightHeading * 180 / .pi)
        h.ringsPassed = t.ringsPassed
        h.ringsTotal = t.rings.count
        if t.phase != .cabin {
            let d = t.scene.target - t.groundPosition
            let c = cos(t.flightHeading), sn = sin(t.flightHeading)
            let local = SIMD2(d.x * c - d.y * sn, d.x * sn + d.y * c)
            h.targetBearingDeg = Float(atan2(local.x, -local.y) * 180 / .pi)
            h.targetDistance = Int(length(d))
            // 风从哪边来（和降落点一样换算成相对飞行方向的方位）
            let w = t.wind
            if length(w) > 0.1 {
                let from = -w
                let lw = SIMD2(from.x * c - from.y * sn, from.x * sn + from.y * c)
                h.windFromDeg = Float(atan2(lw.x, -lw.y) * 180 / .pi)
                h.windKmh = Int((length(w) * 3.6).rounded())
            }
        }
        h.groundSpeedKmh = Int(length(t.velocity) * 3.6)
        h.brakes = SIMD2(Float(t.brakeLeft), Float(t.brakeRight))
        h.dive = Float(max(t.diveLeft, t.diveRight))
        h.underCanopy = t.phase == .opening || t.phase == .canopy
        h.inCabin = t.phase == .cabin
        h.greenLight = t.greenLight
        h.hint = hudHint
        h.ringOnRight = watchOnLeft
        h.time = Float(t.time)
        return h
    }

    /// HUD 下沿那一行：舱里的提示（握住扶杆、绿灯松手）一直有。出了舱门：HUD 开着时全部显示；
    /// HUD 关着（真机默认）时只留要动手的和要命的——开伞、拉早了、伞下头 14 秒怎么转向和降落点在哪、快撞山 / 毒烟 / 掉出岛（带方位）、
    /// 落地结果和怎么结束；之后的方位、距离、高度管理这些「仪表」才跟着 HUD 开关（之前全部跟着 HUD，默认关着时新手一句提示都看不到就摔了）。
    /// 「点一下手表，显示高度和降落点方向」在出舱后几秒说一次（点过一次就不提醒）：舱里握着扶杆的正是点表要用的那只手，绿灯后照做就松手跳出去了
    var hudHint: String {
        let t = timeline
        // 正在按住退出：只显示这一行和进度（不管 HUD 开没开）
        if let q = quitProgress {
            let filled = Int((q * 10).rounded(.down))
            let bar = String(repeating: "■", count: filled) + String(repeating: "□", count: 10 - filled)
            return (usesRealHands ? String(localized: "继续按住手表，退出这一跳") : String(localized: "两只手继续捏住，退出这一跳"))
                + "\n" + bar
        }
        var lines: [String] = []
        let text = t.phase == .cabin || hudOn ? hint : hint(full: false)
        if !text.isEmpty { lines.append(text) }
        if !hudOn, handsDriving, watchTaps == 0, t.phase == .freefall, t.alarmLevel == 0, tooEarlyUntil.map({ t.time >= $0 }) ?? true,
           let left = t.leftRampTime, (6..<16).contains(t.time - left) {
            lines.append(String(localized: "点一下手表，显示高度和降落点方向 · 按住两秒退出"))
        }
        return lines.joined(separator: "\n")
    }

    /// 浮在面前的提示（空 = 不显示）
    var hint: String { hint(full: true) }

    /// full = false：HUD 关着时只留要动手的和要命的（见 hudHint）
    func hint(full: Bool) -> String {
        let t = timeline
        switch t.phase {
        case .cabin:
            if t.barGrabbedTime == nil {
                return usesRealHands ? HelmetHUD.barPrompt(left: !watchOnLeft) : String(localized: "捏住手指 = 握住扶杆")
            }
            if !t.greenLight {
                // 飞机正在长出来：别打扰，松手了就提醒再抓住
                return t.holdingBar ? "" : (usesRealHands ? String(localized: "再握住扶杆") : String(localized: "再捏住手指"))
            }
            if t.holdingBar { return usesRealHands ? String(localized: "手表亮绿灯了！松手就跳") : String(localized: "手表亮绿灯了！松开手指就跳") }
            return usesRealHands ? String(localized: "握住扶杆，松手就跳") : String(localized: "捏住手指，松开就跳")
        case .exit, .opening:
            return ""
        case .freefall:
            if let until = tooEarlyUntil, t.time < until { return String(localized: "还没到开伞高度\n等手表报警再拉") }
            if t.alarmLevel > 0 {
                guard usesRealHands else { return String(localized: "开伞！捏一下手指") }
                return watchOnLeft ? String(localized: "开伞！\n用左手抓住右小臂上的红色拉环，往外拉")
                    : String(localized: "开伞！\n用右手抓住左小臂上的红色拉环，往外拉")
            }
            if let left = t.practiceStartTime ?? t.leftRampTime, t.time - left < 6 {
                return String(localized: "手表在 3,500 英尺报警，那时再开伞")
            }
            return ""
        case .canopy:
            let (clock, distance) = t.targetBearing
            let bearing = distance < 25 ? String(localized: "降落点就在你下面")
                : String(localized: "降落点在 \(clock) 点钟方向 · \(Int(distance / 10) * 10) 米")
            // 要命的警告排在最前面（开伞后头 14 秒的教学也让位给它），HUD 关着也说，带上方位（「快飞回岛上」得说岛在哪边）
            // 警告在第一行（白字，最显眼），方位在第二行
            func warn(_ text: String) -> String { text + "\n" + bearing }
            // 手动拉平：快落地了，提醒拉平（只有这一行，方位这时候没用了）
            if !t.autoFlare, t.terrainClearance < 25 {
                let m = max(Int(t.terrainClearance.rounded()), 0)
                return usesRealHands ? String(localized: "离地 \(m) 米：两边操纵环一起拉到底，拉平！")
                    : String(localized: "离地 \(m) 米：两只手一起捏住往下拉，拉平！")
            }
            // 山区：脚下的地面比高度表的读数近得多，快撞上了
            if t.scene.hasTerrain, t.terrainClearance < 150, t.heightAboveGround - t.terrainClearance > 50 {
                return warn(String(localized: "离山坡只有 \(Int(t.terrainClearance)) 米，快转开"))
            }
            if t.scene == .volcano, t.plumeProximity < 2.5 {
                return warn(String(localized: "前面是火山口的毒烟，别过去"))
            }
            // 天空之城：脚下没有岛。已经比岛面还低了就飞不回去了（伞只会往下掉），别再叫人「飞回岛上」「对准降落点直飞」——
            // 那只会把人送进岛边的崖壁
            if t.scene == .sky, t.terrainClearance > t.heightAboveGround + 200 {
                if t.heightAboveGround < 0 { return warn(String(localized: "太低了，回不到岛上了")) }
                if t.heightAboveGround < 90 { return warn(String(localized: "脚下是云海，快飞回岛上")) }
            }
            if let since = t.sinceDeploy, since < 14 {
                let how: String
                if t.toggleSteering {
                    how = usesRealHands ? String(localized: "拉下左 / 右操纵环转向，两边一起拉减速，两手往前推俯冲")
                        : String(localized: "捏住往下拉：左手左转，右手右转")
                } else {
                    // 伞下 BodyYaw 一直慢慢追头的朝向（手不在面前时，每秒 1.1）：转头也会转向。说清楚，
                    // 免得侧头看风景时伞跟着偏了还不知道为什么
                    how = usesRealHands ? String(localized: "伞朝你脸的方向飞：转头、转身都算，看风景就快看快回\n操纵环一起拉减速，两手往前推俯冲")
                        : String(localized: "伞朝你脸的方向飞：转头、转身都算，看风景就快看快回\n捏住往下拉减速")
                }
                // 头 14 秒说怎么转、降落点在哪（HUD 关着也说：不然新手开伞以后根本不知道该往哪飞）
                return how + "\n" + bearing
            }
            guard full else { return "" }
            // 高度管理：直飞还能飞多远（和自动驾驶一样估），比离靶远太多就提醒先飞过去再掉头
            // （有风：按顺着降落点方向的地速算）
            let toLZ = t.scene.target - t.groundPosition
            let groundSpeed = JumpTimeline.crab(toward: length(toLZ) > 1 ? normalize(toLZ) : t.forward,
                                                wind: t.wind).groundSpeed
            let reach = groundSpeed * max(t.heightAboveGround - 6, 0) / JumpTimeline.canopySink + 15
            if distance < 300, reach > distance + 150 {
                // 默认（转头转身）模式下坐着转不了 180° 掉头：叫人左右来回转几下
                let turnBack = t.toggleSteering
                // （捏手指没有俯冲）
                return bearing + "\n" + (!turnBack ? (usesRealHands ? String(localized: "高度还多：两手往前推俯冲，或者左右来回转几下消耗高度")
                                                                     : String(localized: "高度还多：左右来回转几下消耗高度"))
                    : usesRealHands ? String(localized: "高度还多：两手往前推俯冲，或者先飞过降落点再掉头")
                    : String(localized: "高度还多：先飞过降落点，再掉头回来"))
            }
            if reach < distance - 30 { return bearing + "\n" + String(localized: "高度不够了，对准降落点直飞") }
            return bearing
        case .landed, .done:
            let end = t.rings.isEmpty ? String(localized: "捏一下手指结束")
                : String(localized: "穿过光环 \(t.ringsPassed) / \(t.rings.count) · 捏一下手指结束")
            return resultSummary.map { ([$0] + skinLines + [end]).joined(separator: "\n") } ?? ""
        }
    }

    /// 落地提示里皮肤的那几行：这一跳新解锁了什么；没解锁新东西时，提醒这一关还有什么可以解锁
    var skinLines: [String] { timeline.outcome.map(skinLines(for:)) ?? [] }

    func skinLines(for outcome: JumpTimeline.Outcome) -> [String] {
        let scene = timeline.scene
        let news = skinUnlocks.news(scene: scene, outcome: outcome)
        if !news.isEmpty {
            // 第一次落进靶心会一下解锁两样：合成一行（提示条最多三行，分两行会把「捏一下手指结束」挤掉）
            return [String(localized: "解锁了新皮肤：\(news.map(\.title).joined(separator: " · "))")]
        }
        if outcome == .inTarget, !skinUnlocks.gloves.contains(scene) {
            return [String(localized: "落进黄色靶心，还能解锁这一关的手套和袖子")]
        }
        if !Skins.earned(by: outcome).canopy, !skinUnlocks.canopies.contains(scene) {
            return [String(localized: "落进降落点，就能解锁这一关的降落伞")]
        }
        return []
    }

    /// 落地结果（开始窗口里用图标显示）；还没落地是 nil
    var jumpResult: JumpResult? {
        guard let outcome = timeline.outcome else { return nil }
        return JumpResult(scene: timeline.scene, outcome: outcome, distance: timeline.landingDistance,
                          landingSpeed: timeline.landingSpeed, deployed: timeline.deployTime != nil,
                          hardLanding: timeline.hardLanding,
                          track: track, deployPoint: deployPoint, deployFeet: deployFeet,
                          target: SIMD2(Float(timeline.scene.target.x), Float(timeline.scene.target.y)),
                          wind: SIMD2(Float(timeline.wind.x), Float(timeline.wind.y)))
    }

    /// 落地结果（一句话）；还没落地是 nil
    var resultSummary: String? { jumpResult?.summary }
}

extension JumpTimeline {
    /// 舱门边的扶杆（舞台空间）：跟着飞机走，松手往外跑时也跟着往后退
    var bar: Interaction.Bar {
        let o = planeOffset
        return Interaction.Bar(x: ProceduralMeshes.barStage(onLeft: barOnLeft).x + Float(o.x),
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

/// 一跳的结果：开始窗口里显示成一个图标（加离靶心多远），一句话的说明看着它时弹出来
struct JumpResult: Sendable {
    let scene: JumpScene
    let outcome: JumpTimeline.Outcome
    /// 离靶心多远（米）
    let distance: Double
    /// 落地时每秒多少米（摔了的那句里用）
    var landingSpeed: Double = 0
    /// 开了伞没有（摔了的那句里用）
    var deployed = true
    /// 重着陆（手动拉平时没拉平）：结果后面加一句
    var hardLanding = false
    /// 航线：开伞以后每半秒一个地面位置（米），最后一个是落点；开伞的位置、开伞时离着陆区多高（英尺）；靶
    var track: [SIMD2<Float>] = []
    var deployPoint: SIMD2<Float>?
    var deployFeet: Int?
    var target = SIMD2<Float>(380, -620)
    /// 这一跳的风（地面坐标，m/s，空气往哪边走）
    var wind = SIMD2<Float>(0, 0)

    /// 风相对「开伞点 → 靶」这条进场线从哪边来：逆风 / 顺风 / 左、右侧风（取大的那个分量）；风小于 0.5 m/s 是 nil
    var windKind: String? {
        guard simd_length(wind) >= 0.5 else { return nil }
        let a = scene.approach
        let f = SIMD2<Float>(Float(a.x), Float(a.y))
        let right = SIMD2<Float>(-f.y, f.x)                   // 地面坐标 -z 朝前、+x 朝右
        let along = simd_dot(wind, f), side = simd_dot(wind, right)
        if abs(along) >= abs(side) { return along < 0 ? String(localized: "逆风") : String(localized: "顺风") }
        // 空气往右走 = 风从左边来
        return side > 0 ? String(localized: "左侧风") : String(localized: "右侧风")
    }

    /// 落点顺着最后几秒的飞行方向看：长了（正）/ 短了（负）多少米、偏右（正）/ 偏左（负）多少米。航线太短算不出来是 nil
    var landingOffset: (long: Float, right: Float)? {
        guard track.count >= 4, let last = track.last else { return nil }
        let before = track[max(track.count - 9, 0)]          // 大约四秒前
        let along = last - before
        guard simd_length(along) > 2 else { return nil }
        let f = simd_normalize(along)
        let right = SIMD2<Float>(-f.y, f.x)                   // 地面坐标 -z 朝前、+x 朝右
        let o = last - target
        return (simd_dot(o, f), simd_dot(o, right))
    }

    /// 一句话的说明。现算不存：开始窗口里换了语言，上一跳的这句也跟着换
    var summary: String {
        let base = baseSummary
        return hardLanding && landed ? base + " · " + String(localized: "重着陆：没拉平") : base
    }

    private var baseSummary: String {
        let d = distance
        switch outcome {
        case .bullseye: return String(format: String(localized: "正中降落点！离中心 %.1f 米"), d)
        case .inTarget: return String(format: String(localized: "落在降落点上！离中心 %.1f 米"), d)
        case .missed:
            // 说离靶心多远，并说清 20 米内才算进（以前「离降落点还差 28 米」听起来像再飞 28 米才到，其实再近 8 米就进了）
            return scene == .atoll ? String(localized: "落在沙洲上，离靶心 \(Int(d)) 米（20 米内才算进）")
                : String(localized: "平安落地，离靶心 \(Int(d)) 米（20 米内才算进）")
        case .water: return String(localized: "掉进水里了——离降落点 \(Int(d)) 米")
        case .crashed:
            // 根本没拉伞的，告诉他该拉什么（「开伞太晚」对没开伞的人是错的）
            return deployed ? String(format: String(localized: "摔了——落地时每秒 %.0f 米，开伞太晚"), landingSpeed)
                : String(localized: "没开伞——手表报警时，用另一只手拉小臂上的红色拉环")
        case .terrain: return scene == .sky ? String(localized: "撞上了浮岛的岩壁——那里落不了") : String(localized: "撞上山坡了——那里太陡，落不了")
        case .trees: return String(localized: "落进树林，挂在树上了——离降落点 \(Int(d)) 米")
        case .lava: return String(localized: "掉进熔岩里了")
        case .crevasse: return String(localized: "掉进冰裂缝了")
        case .plume: return String(localized: "冲进了火山口的毒烟")
        case .fell: return String(localized: "掉出了浮岛，落进云海——离降落点 \(Int(d)) 米")
        case .ruins: return scene == .sky ? String(localized: "撞上了石头城的塔") : String(localized: "撞上了障碍物")
        }
    }

    var won: Bool { outcome == .bullseye || outcome == .inTarget }
    /// 平安落地（离靶心多远才有意义）
    var landed: Bool { [.bullseye, .inTarget, .missed, .water, .trees].contains(outcome) }

    var symbol: String {
        switch outcome {
        case .bullseye: "scope"
        case .inTarget: "target"
        case .missed: "figure.stand"
        case .water: "water.waves"
        case .crashed: "exclamationmark.triangle.fill"
        case .terrain: "mountain.2.fill"
        case .trees: "tree.fill"
        case .lava: "flame.fill"
        case .crevasse: "snowflake"
        case .plume: "smoke.fill"
        case .fell: "cloud.fill"
        case .ruins: "building.columns.fill"
        }
    }
}
