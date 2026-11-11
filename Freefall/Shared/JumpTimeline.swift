import Foundation
import simd

/// 一次跳伞的全过程：舱门边抓扶杆 → 松手跳出 → 自由落体 → 手表报警后自己拉开伞 → 操纵伞落到靶上 → 判定。
///
/// 坐标约定：你（舞台）不动；VR 里镜头自己转最容易晕，所以「转向」是世界绕着你转（heading）。
/// 飞机、伞衣、背带跟着舞台坐标走；云、海、环礁、靶按你在「云坐标」里的水平位置 `position`
/// 和航向 `heading` 换算（云坐标原点就是天气图中心）。
/// 你面朝舞台 -Z = 机尾的舱门方向；飞机往 +Z（你背后）飞。开伞后伞往舞台 -Z（你面朝的方向）飞，转向时世界转。
struct JumpTimeline {
    enum Phase: Int, Sendable { case cabin, exit, freefall, opening, canopy, landed, done }

    enum Outcome: Sendable, Equatable {
        case bullseye       // 靶心（3 米内）
        case inTarget       // 进靶（20 米内）
        case missed         // 平安落地但没进靶
        case water          // 落水（海、河、湖）
        case crashed        // 落地速度太快（开伞太晚或没开）
        case terrain        // 撞上太陡的山坡 / 岩壁
        case trees          // 落进树林，挂在树上了
        case lava           // 落进熔岩 / 火山口
        case crevasse       // 掉进冰裂缝
        case plume          // 冲进火山口的毒烟
        case fell           // 天空之城：掉出浮岛，落进云海
        case ruins          // 撞上实体模型里的障碍（天空之城的塔 / 城堡，别的关的房子、大石头……）
    }

    // 飞机：平飞，放人时的空速约 70 m/s（136 节）。高度每关不一样（JumpScene.exitAltitude）
    var planeAltitude: Double { scene.exitAltitude }
    static let planeSpeed: Double = 70
    /// 你站在跳板上，离跳板末端 2.2 米；松开扶杆后加速跑出去
    static let rampEnd: Double = 2.2
    static let exitDuration: Double = 1.3
    /// 出舱后水平速度（相对空气）按这个时间常数衰减
    static let throwTimeConstant: Double = 3.5
    // 开伞（离着陆区地面的高度，像真的高度表一样按着陆区归零）
    static let alertAGL: Double = 1067           // 3,500 ft：手表报警，可以开伞了
    static let hardDeckAGL: Double = 610         // 2,000 ft：急促报警，再不开就来不及了
    /// 拉开以后：引导伞拽出伞包、伞绳拉直这一秒还是全速往下掉，然后伞衣张开减速，4.5 秒飞稳。
    /// 整个过程掉 160 多米，低于 600 英尺左右才拉，伞还没张开就到地面了
    static let snatchTime: Double = 1.0
    static let openingDuration: Double = 4.5
    // 伞：真实的伞下沉约 5 m/s，这里快一点，伞降段一两分钟
    static let canopySink: Double = 8.5
    static let canopySpeed: Double = 11.5
    /// 单边拉到底的转向角速度（弧度/秒，约 26°/s；再快容易晕）
    static let maxTurnRate: Double = 0.45
    // 落地
    static let crashSpeed: Double = 8            // 落地时下沉速度超过这个就是摔了
    static let maxLandingSlope: Float = 32       // 坡度超过这个（度）落不了，算撞山
    static let targetRadius: Double = 20
    static let bullseyeRadius: Double = 3
    static let fadeInDuration: Double = 1.5
    static let fadeOutDuration: Double = 2.5
    static let landedHold: Double = 10
    /// 起跳时你在云坐标里的 z：舱里随飞机走、出舱后惯性滑行
    static let startZ: Double = -700
    /// 地面（环礁、靶）在云坐标里的起始偏移：出舱、惯性滑行完，开伞点离靶 600 多米、在靶的左后方
    static let landShiftStart = SIMD2<Double>(0, 264)
    static let feetPerMeter = 3.28084
    // 会下雨的碎积云层（云坐标里的椭圆，和 Clouds.h 的 DECK_CENTER / DECK_AXES 一致）
    static let deckCenter = SIMD2<Double>(-450, 400)
    static let deckAxes = SIMD2<Double>(800, 1700)
    /// 雨滴下落速度（m/s）
    static let rainFallSpeed: Double = 8.5

    /// 这一关
    let scene: JumpScene

    private(set) var phase: Phase = .cabin
    private(set) var time: Double = 0
    private(set) var altitude: Double = 0
    /// 向下为正（m/s）
    private(set) var verticalSpeed: Double = 0
    /// 你在云坐标里的水平位置 (x, z)
    private(set) var position = SIMD2<Double>(0, startZ)
    /// 地面坐标 = 云坐标 + landShift。机舱里地面不跟着飞机走（云照样从舱门外掠过，像顶着大风），
    /// 不管在舱里等多久再跳，出舱点都在地面的同一个地方；松手以后就固定了。
    private(set) var landShift = landShiftStart
    /// 相对空气的水平速度 (x, z)
    private(set) var velocity = SIMD2<Double>(0, planeSpeed)
    /// 航向（弧度）：0 = 起跳时面朝的方向，正 = 往左转
    private(set) var heading: Double = 0
    /// 伞下身体相对舞台正前方转了多少（弧度，正 = 往左）：人在椅子上转过去，伞跟着转，飞的方向是 heading + bodyYaw。
    /// heading 是世界绕着你转了多少（拉操纵环）；身体转是你自己真的转了，世界不用跟着转
    private(set) var bodyYaw: Double = 0
    /// 伞下拉左 / 右操纵环能不能转向。能：拉哪边往哪边转（世界绕着你转，容易晕）。
    /// 不能（app 里默认）：只靠转头、转身，伞跟着你转（bodyYaw）；操纵环只管减速，一边拉算一半。
    /// 自动驾驶和离屏测试靠拉环转向，所以这里默认开，app 按开始窗口里的选项设
    var toggleSteering = true
    /// 自由落体时用手控制的横移：输入（-1 左 … 1 右）、现在横移的速度（m/s）、离正路线偏了多少（米，右为正）
    private var trackInput: Double = 0
    private(set) var trackVelocity: Double = 0
    private(set) var trackX: Double = 0
    /// 自由落体路上迎面过来的一串光环
    private(set) var rings: [SkyRing] = []
    private(set) var ringsPassed = 0
    /// 下一个还没到的光环
    private(set) var nextRing = 0
    /// 开始自由落体的时刻：光环的到达时间从这里算
    private(set) var ringEpoch: Double?
    private(set) var turnRate: Double = 0
    /// 转向的中间级（两级滞后，见 fly）
    private var turnRateMid: Double = 0
    /// 机舱地板原点相对舞台原点的位置：你站在跳板上，飞机原点在你身后
    private(set) var planeOffset = SIMD3<Double>(0, 0, ProceduralMeshes.standOnRamp)
    /// 第一次抓住扶杆的时刻：开场的「实体化」从这时开始，结束后再过一会儿亮绿灯
    private(set) var barGrabbedTime: Double?
    /// 实体化从哪里开始蔓延（舞台坐标：抓住扶杆的那只手）
    private(set) var revealCenter = SIMD3<Double>(Double(ProceduralMeshes.barStage.x), 1.25,
                                                   Double(ProceduralMeshes.barStage.y))
    private(set) var exitTime: Double?
    private(set) var leftRampTime: Double?
    private(set) var deployTime: Double?
    private(set) var landedTime: Double?
    private(set) var fadeTime: Double?
    private(set) var outcome: Outcome?
    /// 落地点离靶心多远（米）
    private(set) var landingDistance: Double = 0
    private(set) var landingSpeed: Double = 0
    private(set) var holdingBar = false
    /// 脚下地面的海拔（地形场景每步按地形算；环礁是海平面）
    private(set) var groundHeight: Double = 0
    private var glide: Double = 0
    private var openingStartVertical: Double = 0
    /// 左右操纵环拉下去多少（0…1）
    private(set) var brakeLeft: Double = 0
    private(set) var brakeRight: Double = 0
    /// 左右往前推了多少（0…1）：像拉前组伸缩带，伞头往下栽，俯冲
    private(set) var diveLeft: Double = 0
    private(set) var diveRight: Double = 0
    /// 舞台地板在眼睛下面多少（渲染器在对齐头部时设）：落地时你的脚踩在地上
    var eyeHeight: Double = 1.6

    init(scene: JumpScene = .atoll) {
        self.scene = scene
        altitude = scene.exitAltitude
        groundHeight = scene.groundHeight(at: groundPosition)
    }

    /// 调试用：跳过机舱，从某个高度直接开始自由落体（已经是终端速度）。
    init(freefallFrom startAltitude: Double, scene: JumpScene = .atoll) {
        self.scene = scene
        phase = .freefall
        time = 20                       // 跳过开头的淡入
        altitude = startAltitude
        verticalSpeed = Self.terminalVelocity(at: startAltitude)
        position = SIMD2(0, 0)
        landShift = .zero
        velocity = SIMD2(0, 0)
        barGrabbedTime = 5
        exitTime = 10
        leftRampTime = 12
        planeOffset = SIMD3(0, scene.exitAltitude - startAltitude + 5000, 5000)
        groundHeight = scene.groundHeight(at: groundPosition)
    }

    /// 终端速度（m/s）：∝ 1/√空气密度，密度按 8.5 km 标高指数衰减
    static func terminalVelocity(at altitude: Double) -> Double {
        54 * exp(altitude / 17000)
    }

    // MARK: - 输入

    /// 抓住扶杆。第一次抓住时开场的「实体化」从抓的地方开始（at：手在舞台里的位置；没有就按胸口高度）
    mutating func grabBar(at point: SIMD3<Float>? = nil) {
        guard phase == .cabin else { return }
        holdingBar = true
        if barGrabbedTime == nil {
            barGrabbedTime = time
            if let point { revealCenter = SIMD3(Double(point.x), Double(point.y), Double(point.z)) }
            else { revealCenter.y = eyeHeight - 0.35 }
        }
    }

    /// 松开扶杆：亮了绿灯才算跳，之前松手只是放开（再抓住就行）
    mutating func releaseBar() {
        guard phase == .cabin, holdingBar else { return }
        holdingBar = false
        guard greenLight else { return }
        phase = .exit
        exitTime = time
    }

    /// 拉开伞把手。手表报警以后才拉得动；返回是否开了伞。
    @discardableResult
    mutating func requestDeploy() -> Bool {
        guard phase == .freefall, canDeploy else { return false }
        phase = .opening
        deployTime = time
        return true
    }

    /// 左右操纵环拉下去多少（0…1）
    mutating func setBrakes(left: Double, right: Double) {
        brakeLeft = min(max(left, 0), 1)
        brakeRight = min(max(right, 0), 1)
    }

    /// 左右往前推了多少（0…1）
    mutating func setDive(left: Double, right: Double) {
        diveLeft = min(max(left, 0), 1)
        diveRight = min(max(right, 0), 1)
    }

    /// 伞下身体的朝向（JumpSession 每帧按头和手估的给进来）
    mutating func setBodyYaw(_ yaw: Double) {
        bodyYaw = phase == .opening || phase == .canopy ? yaw : 0
    }

    /// 自由落体的横移：两只手往左、往右伸，人就往那边飘（-1 左 … 1 右）
    mutating func setTrack(_ input: Double) {
        trackInput = min(max(input, -1), 1)
    }

    static let trackSpeed: Double = 14
    /// 光环的半径（米）、迎面过来的速度（m/s）、第一个什么时候到（离开跳板后几秒）、之后每隔几秒一个
    static let ringRadius: Double = 5.5
    static let ringClosing: Double = 18
    static let ringFirst: Double = 11
    static let ringPeriod: Double = 3.6

    /// 摆光环。自由落体一分多钟，往下看只有很远的云和海，没什么事可做：路上放一串立着的光环，
    /// 和你一起往下掉、迎面一个个过来（就在眼前的高度，不用低头找），左右飘着对准了穿过去。
    /// 只有左右是真的在挪（离正路线不超过三十米，开伞点不会被带偏）；光环迎面过来只是它自己在动。
    /// 个数按这一跳自由落体有多长定：把时间线往后模拟一遍（抓杆、亮绿灯就松手、不开伞），到手表报警前一秒半为止。
    /// steerable：能用手控制横移时光环左右错开；不能的话都在正前方，直直地穿过去
    mutating func layRings(steerable: Bool) {
        var t = self
        var guardSteps = 0
        if t.phase == .cabin {
            t.grabBar()
            while !t.greenLight, guardSteps < 20_000 { t.step(1.0 / 30); guardSteps += 1 }
            t.releaseBar()
        }
        while t.phase == .exit, guardSteps < 40_000 { t.step(1.0 / 60); guardSteps += 1 }
        let start = t.time
        while t.phase == .freefall, !t.canDeploy, guardSteps < 60_000 { t.step(1.0 / 30); guardSteps += 1 }
        let duration = t.time - start
        var result: [SkyRing] = []
        var arrival = Self.ringFirst
        while arrival < duration - 1.5 {
            let k = result.count
            // 左右错开：一开始小（先学会），后面到二十多米；方向来回换，不规则一点
            let reach = min(6 + Double(k) * 2.2, 24)
            let x = steerable && k > 0 ? reach * sin(Double(k) * 1.9 + 0.6) : 0
            result.append(SkyRing(x: x, arrival: arrival))
            arrival += Self.ringPeriod
        }
        rings = result
        ringsPassed = 0
        nextRing = 0
    }

    /// 落地以后捏一下手指：提前结束
    mutating func requestEnd() {
        if phase == .landed, fadeTime == nil { fadeTime = time }
    }

    // MARK: - 推进

    mutating func step(_ dt: Double) {
        guard dt > 0, phase != .done else { return }
        time += dt
        switch phase {
        case .cabin:
            position += velocity * dt                   // 跟着飞机走（云往后掠）
            landShift -= velocity * dt                  // 地面不动
        case .exit:
            // 加速跑向跳板末端（s² 曲线），离开时相对飞机约 3.4 m/s
            let s = min((time - exitTime!) / Self.exitDuration, 1)
            let newGlide = Self.rampEnd * s * s
            let glideSpeed = (newGlide - glide) / dt
            glide = newGlide
            velocity = SIMD2(0, Self.planeSpeed - glideSpeed)
            position += velocity * dt
            planeOffset.z = ProceduralMeshes.standOnRamp + glide
            if s >= 1 {
                leftRampTime = time
                phase = .freefall
            }
        case .freefall:
            fall(dt)
            velocity *= exp(-dt / Self.throwTimeConstant)
            position += velocity * dt
            // 用手控制的横移（只有左右）：半秒跟上，离正路线最多 30 米
            if ringEpoch == nil { ringEpoch = time }
            trackVelocity += (trackInput * Self.trackSpeed - trackVelocity) * min(dt / 0.5, 1)
            let moved = min(max(trackX + trackVelocity * dt, -30), 30) - trackX
            trackX += moved
            position += SIMD2(cos(heading), -sin(heading)) * moved
            // 光环到跟前了：对准了就算穿过去
            while nextRing < rings.count, let epoch = ringEpoch, time >= epoch + rings[nextRing].arrival {
                if abs(trackX - rings[nextRing].x) < Self.ringRadius {
                    rings[nextRing].passedTime = time
                    ringsPassed += 1
                } else {
                    rings[nextRing].missed = true
                }
                nextRing += 1
            }
        case .opening:
            // 伞包、伞绳先拉出来（还是全速往下掉），然后伞衣张开、减速。地面来得比伞快就摔了
            let since = time - deployTime!
            let s = min(max((since - Self.snatchTime) / (Self.openingDuration - Self.snatchTime), 0), 1)
            let e = Self.smoothstep(s)
            if since < Self.snatchTime {
                fall(dt)
                openingStartVertical = verticalSpeed
            } else {
                verticalSpeed = openingStartVertical + (Self.canopySink - openingStartVertical) * e
                altitude -= verticalSpeed * dt
            }
            velocity = forward * (Self.canopySpeed * e)
            position += velocity * dt
            if since >= Self.openingDuration { phase = .canopy }
        case .canopy:
            fly(dt)
        case .landed:
            if fadeTime == nil, let landedTime, time - landedTime >= (isFatal ? 1.2 : Self.landedHold) {
                fadeTime = time
            }
        case .done:
            break
        }
        if phase == .freefall || phase == .opening || phase == .canopy {
            if scene.hasTerrain { groundHeight = scene.groundHeight(at: groundPosition) }
            if terrainClearance <= 0 {
                touchDown()
            } else if SceneProps.hits(scene, groundPosition, altitude: altitude - eyeHeight) {
                // 撞上塔 / 城堡 / 别的障碍（SceneProps 的 obstacles）：人停在撞上的地方，画面很快暗下去
                outcome = .ruins
                landingDistance = length(groundPosition - scene.target)
                verticalSpeed = 0
                velocity = .zero
                turnRate = 0
                phase = .landed
                landedTime = time
            } else if scene == .volcano,
                      TerrainField.plumeDensity(SIMD2(Float(groundPosition.x), Float(groundPosition.y)),
                                                altitude: Float(altitude)) > 0.4 {
                // 冲进烟柱：毒烟、高温，直接失败（人停在半空，画面很快暗下去）
                outcome = .plume
                verticalSpeed = 0
                velocity = .zero
                turnRate = 0
                phase = .landed
                landedTime = time
            }
        }
        if let fadeTime, time - fadeTime >= fadeDuration { phase = .done }
        // 离开跳板以后，飞机按自己的速度飞走、高度不变
        if leftRampTime != nil {
            planeOffset.z += (Self.planeSpeed - velocity.y) * dt
            planeOffset.x -= velocity.x * dt
            planeOffset.y = planeAltitude - altitude
        }
    }

    private mutating func fall(_ dt: Double) {
        let vt = Self.terminalVelocity(at: altitude)
        verticalSpeed += 9.81 * (1 - (verticalSpeed / vt) * (verticalSpeed / vt)) * dt
        altitude -= verticalSpeed * dt
    }

    /// 伞下：两边拉环的差决定转向，一起拉减速；两手往前推（真的跳伞是拉下两根前组伸缩带）伞头往下栽，
    /// 下沉和前进都变快，用来在高度太多时掉得快一点，不用一直滑翔；只推一边是往那边俯冲着转（快落地时自动拉平飘一下）
    private mutating func fly(_ dt: Double) {
        let both = toggleSteering ? min(brakeLeft, brakeRight) : (brakeLeft + brakeRight) / 2
        let dive = toggleSteering ? min(diveLeft, diveRight) : (diveLeft + diveRight) / 2
        let targetTurn = toggleSteering
            ? Self.maxTurnRate * (brakeLeft - brakeRight)       // 拉左边往左转（heading 增大）
                + Self.maxTurnRate * 0.7 * (diveLeft - diveRight)
            : 0
        // 伞转起来、停下来都有个过程：两级一阶滞后（S 形），角加速度是慢慢起来的，不会一拉就猛地开始转。
        // VR 里转向晕主要来自角加速度的突变，转得匀不怎么晕
        let k = min(dt / 0.32, 1)
        turnRateMid += (targetTurn - turnRateMid) * k
        turnRate += (turnRateMid - turnRate) * k
        heading += turnRate * dt
        var speed = Self.canopySpeed * (1 - 0.45 * both) * (1 + 0.3 * dive)
        var sink = Self.canopySink * (1 - 0.25 * both) * (1 + 0.8 * dive) + abs(turnRate) / Self.maxTurnRate * 2.5
            + (toggleSteering ? abs(diveLeft - diveRight) * 2 : 0)
        // 离地 6 米以内自动拉平：下沉和前进都慢下来，落地是轻轻一顿
        let flare = 1 - min(max(terrainClearance / 6, 0), 1)
        sink += (1.5 - sink) * flare
        speed += (4 - speed) * flare
        verticalSpeed = sink
        velocity = forward * speed
        altitude -= sink * dt
        position += velocity * dt
    }

    private mutating func touchDown() {
        landingSpeed = verticalSpeed
        landingDistance = length(groundPosition - scene.target)
        let p = SIMD2<Float>(Float(groundPosition.x), Float(groundPosition.y))
        let hazard = scene.hasTerrain ? TerrainField.hazard(scene, p, Float(groundHeight)) : nil
        // 浮岛：从侧面飞进来、比岛面低一大截，是撞在岛边的崖壁上（不能把人搬到岛顶上去）
        let hitCliff = scene == .sky && hazard != .void && terrainClearance < -12
        if hazard == .void {
            outcome = .fell
        } else if hitCliff {
            outcome = .terrain
        } else if verticalSpeed > Self.crashSpeed {
            outcome = .crashed
        } else if scene == .atoll ? !LandingZone.atoll.isLand(groundPosition) : hazard == .water {
            outcome = .water
        } else if hazard == .forest {
            outcome = .trees
        } else if hazard == .lava {
            outcome = .lava
        } else if hazard == .crevasse {
            outcome = .crevasse
        } else if scene.hasTerrain, TerrainField.slopeDegrees(scene, p) > Self.maxLandingSlope {
            outcome = .terrain
        } else if landingDistance <= Self.bullseyeRadius {
            outcome = .bullseye
        } else if landingDistance <= Self.targetRadius {
            outcome = .inTarget
        } else {
            outcome = .missed
        }
        if !hitCliff { altitude = groundHeight + eyeHeight }
        verticalSpeed = 0
        velocity = .zero
        turnRate = 0
        phase = .landed
        landedTime = time
    }

    // MARK: - 给渲染、声音和提示用的量

    var isOver: Bool { phase == .done }
    /// 你在地面坐标（环礁、靶）里的水平位置
    var groundPosition: SIMD2<Double> { position + landShift }
    /// 赢了：落进靶里
    var won: Bool { outcome == .bullseye || outcome == .inTarget }
    /// 开场：你先站在自己的房间里，只看得到那根扶杆；抓住以后飞机从手边开始一点点长出来（波前越走越快），
    /// 走过 7 米左右舱门外的天和云也出现，16 米时全部完成。之后再过一秒亮绿灯
    static let revealDoneRadius = 16.0
    static let revealDuration = pow(revealDoneRadius / 1.6, 1 / 1.5)      // 约 4.6 秒
    static let greenDelay = 1.0
    /// 实体化的波前走到离起点多远（米）：还没抓扶杆是 nil（只有扶杆），完成以后是 .infinity
    var revealRadius: Double? {
        guard let start = barGrabbedTime else { return nil }
        let r = 1.6 * pow(max(time - start, 0), 1.5)
        return r >= Self.revealDoneRadius ? .infinity : r
    }
    /// 实体化进行到哪了（0…1，声音跟着它渐渐起来）
    var revealProgress: Double {
        guard let start = barGrabbedTime else { return 0 }
        return min(max((time - start) / Self.revealDuration, 0), 1)
    }
    var greenLight: Bool {
        barGrabbedTime.map { time - $0 >= Self.revealDuration + Self.greenDelay } ?? false
    }
    /// 高度表的读数（米）：你的脚离着陆区的高度（真的高度表也是在着陆区归零的）
    var heightAboveGround: Double { altitude - eyeHeight - scene.dzElevation }
    /// 你的脚离正下方地面多高（米）：山区里可能比高度表的读数小得多
    var terrainClearance: Double { altitude - eyeHeight - groundHeight }
    /// 摔了、撞山、掉进岩浆 / 冰裂缝、冲进毒烟：画面很快暗下去
    var isFatal: Bool {
        switch outcome {
        case .crashed, .terrain, .lava, .crevasse, .plume, .ruins: return true
        default: return false
        }
    }
    /// 高度表的读数：按着陆区归零（英尺）
    var altitudeFeet: Int { Int(max(heightAboveGround, 0) * Self.feetPerMeter) }
    var canDeploy: Bool { heightAboveGround <= Self.alertAGL }

    /// 手表报警：0 不响，1 可以开伞了（三声一组），2 低于决断高度（急促）
    var alarmLevel: Int {
        guard phase == .freefall else { return 0 }
        if heightAboveGround <= Self.hardDeckAGL { return 2 }
        return heightAboveGround <= Self.alertAGL ? 1 : 0
    }

    /// 伞朝着的方向 = 飞的方向：世界转过的航向 + 身体自己转过的角度
    var flightHeading: Double { heading + bodyYaw }
    /// 前进的方向（云坐标）
    var forward: SIMD2<Double> { SIMD2(-sin(flightHeading), -cos(flightHeading)) }

    private var fadeDuration: Double { isFatal ? 0.6 : Self.fadeOutDuration }

    /// 画面亮度：开头淡入，最后淡出
    var brightness: Double {
        let fadeIn = Self.smoothstep(min(time / Self.fadeInDuration, 1))
        guard let fadeTime else { return fadeIn }
        return fadeIn * (1 - Self.smoothstep(min((time - fadeTime) / fadeDuration, 1)))
    }

    /// 还在机舱里的程度（背带、表带的光照：舱里是红灯，出去以后是太阳）
    var inCabin: Double {
        guard let leftRampTime else { return 1 }
        return 1 - Self.smoothstep(min((time - leftRampTime) / 0.6, 1))
    }

    /// 开伞以后过了多久（秒，没开伞是 nil）
    var sinceDeploy: Double? { deployTime.map { time - $0 } }

    /// 飞机离你多远（米）
    var planeDistance: Double { length(planeOffset) }

    /// 风有多大（m/s）：舱门口灌进来的风，自由落体是下落速度，伞下是相对空气的速度
    var windSpeed: Double {
        switch phase {
        case .cabin, .exit: return 30
        case .freefall: return verticalSpeed
        case .opening, .canopy: return length(velocity) + verticalSpeed * 0.5
        case .landed, .done: return 3
        }
    }

    /// 靶相对你的方位：钟点（12 = 正前方）和距离（米）
    var targetBearing: (clock: Int, distance: Double) {
        let d = scene.target - groundPosition
        let distance = length(d)
        // 世界方向 → 相对你（和伞）正对的方向：反转航向
        let c = cos(flightHeading), s = sin(flightHeading)
        let local = SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
        var angle = atan2(local.x, -local.y)            // 0 = 正前方，顺时针为正
        if angle < 0 { angle += 2 * .pi }
        var clock = Int((angle / (2 * .pi) * 12).rounded())
        if clock == 0 { clock = 12 }
        return (clock, distance)
    }

    /// 某处的雨有多大（0…1）：碎积云层的范围 × 高度分布（云里就开始下，云底以下最大，到 1,500 米蒸发完）。
    /// 和 Clouds.h 的 deckMask × rainProfile 一样。
    static func rain(at cloudXZ: SIMD2<Double>, altitude: Double) -> Double {
        let d = (cloudXZ - deckCenter) / deckAxes
        let top = smoothstep((3200 - altitude) / 600)
        let bottom = smoothstep((altitude - 1500) / 600)
        return exp(-dot(d, d)) * top * bottom
    }

    /// 你离火山烟柱有多近：到烟柱中轴的距离 ÷ 烟柱半径（不在烟柱的高度范围里是很大的数）
    var plumeProximity: Double {
        guard scene == .volcano else { return .infinity }
        let above = altitude - Double(TerrainField.coneTop - 40)
        guard above > -200, above < 3200 else { return .infinity }
        let axis = SIMD2<Double>(TerrainField.coneCenter) + SIMD2<Double>(TerrainField.plumeDrift) * max(above, 0)
        return length(groundPosition - axis) / (90 + 0.22 * max(above, 0))
    }

    /// 你这里的雨有多大
    var rainIntensity: Double { Self.rain(at: position, altitude: altitude - scene.cloudOffset) }

    /// 你是不是在那层碎积云里（0…1，粗估：和 Freefall.metal 天气图里的 inDeck 一样按 deckMask 算，高度在云底和云顶之间）。
    /// 只用来算身上淋湿得多快；身边的雾团按真的云密度在 GPU 上算
    var inCloudDeck: Double {
        let d = (position - Self.deckCenter) / Self.deckAxes
        let inDeck = Self.smoothstep((exp(-dot(d, d)) - 0.15) / 0.4)
        let h = altitude - scene.cloudOffset
        return inDeck * Self.smoothstep((h - 2350) / 150) * Self.smoothstep((3250 - h) / 150)
    }

    /// 你在有云的那几千米里（云层底到顶，含整体抬高的部分）：身边才可能有雾团
    var inCloudBand: Bool {
        let h = altitude - scene.cloudOffset
        return h > 900 && h < 8700
    }

    /// 空气相对你的速度（舞台空间，m/s）：云和你一起随风漂，所以只是你自己速度的反方向（往下掉 → 雾往上掠）
    var airVelocity: SIMD3<Double> {
        let relative = SIMD3<Double>(-velocity.x, verticalSpeed, -velocity.y)
        let c = cos(heading), s = sin(heading)
        return SIMD3(relative.x * c - relative.z * s, relative.y, relative.x * s + relative.z * c)
    }

    /// 雨相对你的速度（舞台空间，m/s）：雨往下落（顺风稍微斜一点），你掉得比它快得多，所以雨是往上走的
    var rainVelocity: SIMD3<Double> {
        let relative = SIMD3<Double>(1.5 - velocity.x, verticalSpeed - Self.rainFallSpeed, 0.8 - velocity.y)
        // 云坐标 → 舞台：反转航向
        let c = cos(heading), s = sin(heading)
        return SIMD3(relative.x * c - relative.z * s, relative.y, relative.x * s + relative.z * c)
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 环礁的着陆区：潟湖里一片白沙洲，靶铺在沙洲上（和 shader 里的 SANDBAR_* 一致）。
struct LandingZone: Sendable {
    var target: SIMD2<Double>
    var groundElevation: Double
    /// 沙洲：椭圆，中心、半轴（米）、长轴朝向（弧度）
    var sandCenter: SIMD2<Double>
    var sandAxes: SIMD2<Double>
    var sandAngle: Double

    static let atoll = LandingZone(target: SIMD2(380, -620), groundElevation: 0,
                                   sandCenter: SIMD2(405, -640), sandAxes: SIMD2(170, 95), sandAngle: 0.5)

    /// 这一点是不是陆地（沙洲）
    func isLand(_ p: SIMD2<Double>) -> Bool {
        let d = p - sandCenter
        let c = cos(sandAngle), s = sin(sandAngle)
        let local = SIMD2(d.x * c + d.y * s, -d.x * s + d.y * c) / sandAxes
        return length(local) <= 1
    }
}

/// 自由落体路上的一个光环：立着的一圈，迎面过来，从中间穿过去
struct SkyRing: Sendable {
    /// 离正路线多远（米，右为正）
    var x: Double
    /// 开始自由落体后第几秒到你跟前
    var arrival: Double
    /// 穿过去的时刻（没穿过是 nil）
    var passedTime: Double?
    var missed = false
}
