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
        case missed         // 落在沙洲上但没进靶
        case water          // 落水
        case crashed        // 落地速度太快（开伞太晚或没开）
    }

    // 飞机：在 30,000 ft 平飞，放人时的空速约 70 m/s（136 节）
    static let planeAltitude: Double = 9144
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

    /// 这一关的着陆区：靶心位置（云坐标）和地面高度
    var scene = LandingZone.atoll

    private(set) var phase: Phase = .cabin
    private(set) var time: Double = 0
    private(set) var altitude: Double = planeAltitude
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
    private(set) var turnRate: Double = 0
    /// 机舱地板原点相对舞台原点的位置：你站在跳板上，飞机原点在你身后
    private(set) var planeOffset = SIMD3<Double>(0, 0, ProceduralMeshes.standOnRamp)
    private(set) var barGrabbedTime: Double?
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
    private var glide: Double = 0
    private var openingStartVertical: Double = 0
    /// 左右操纵环拉下去多少（0…1）
    private(set) var brakeLeft: Double = 0
    private(set) var brakeRight: Double = 0
    /// 舞台地板在眼睛下面多少（渲染器在对齐头部时设）：落地时你的脚踩在地上
    var eyeHeight: Double = 1.6

    init() {}

    /// 调试用：跳过机舱，从某个高度直接开始自由落体（已经是终端速度）。
    init(freefallFrom startAltitude: Double) {
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
        planeOffset = SIMD3(0, Self.planeAltitude - startAltitude + 5000, 5000)
    }

    /// 终端速度（m/s）：∝ 1/√空气密度，密度按 8.5 km 标高指数衰减
    static func terminalVelocity(at altitude: Double) -> Double {
        54 * exp(altitude / 17000)
    }

    // MARK: - 输入

    /// 抓住舱门边的扶杆：游戏开始，跳伞灯变绿
    mutating func grabBar() {
        guard phase == .cabin else { return }
        holdingBar = true
        if barGrabbedTime == nil { barGrabbedTime = time }
    }

    /// 松开扶杆：跳
    mutating func releaseBar() {
        guard phase == .cabin, holdingBar else { return }
        holdingBar = false
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
            if fadeTime == nil, let landedTime, time - landedTime >= (outcome == .crashed ? 1.2 : Self.landedHold) {
                fadeTime = time
            }
        case .done:
            break
        }
        if phase == .freefall || phase == .opening || phase == .canopy, heightAboveGround <= 0 {
            touchDown()
        }
        if let fadeTime, time - fadeTime >= fadeDuration { phase = .done }
        // 离开跳板以后，飞机按自己的速度飞走、高度不变
        if leftRampTime != nil {
            planeOffset.z += (Self.planeSpeed - velocity.y) * dt
            planeOffset.x -= velocity.x * dt
            planeOffset.y = Self.planeAltitude - altitude
        }
    }

    private mutating func fall(_ dt: Double) {
        let vt = Self.terminalVelocity(at: altitude)
        verticalSpeed += 9.81 * (1 - (verticalSpeed / vt) * (verticalSpeed / vt)) * dt
        altitude -= verticalSpeed * dt
    }

    /// 伞下：两边拉环的差决定转向，一起拉减速（快落地时自动拉平飘一下）
    private mutating func fly(_ dt: Double) {
        let both = min(brakeLeft, brakeRight)
        let targetTurn = Self.maxTurnRate * (brakeLeft - brakeRight)       // 拉左边往左转（heading 增大）
        turnRate += (targetTurn - turnRate) * min(dt / 0.6, 1)             // 伞转起来有个过程
        heading += turnRate * dt
        var speed = Self.canopySpeed * (1 - 0.45 * both)
        var sink = Self.canopySink * (1 - 0.25 * both) + abs(turnRate) / Self.maxTurnRate * 2.5
        // 离地 6 米以内自动拉平：下沉和前进都慢下来，落地是轻轻一顿
        let flare = 1 - min(max(heightAboveGround / 6, 0), 1)
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
        if verticalSpeed > Self.crashSpeed {
            outcome = .crashed
        } else if !scene.isLand(groundPosition) {
            outcome = .water
        } else if landingDistance <= Self.bullseyeRadius {
            outcome = .bullseye
        } else if landingDistance <= Self.targetRadius {
            outcome = .inTarget
        } else {
            outcome = .missed
        }
        altitude = scene.groundElevation + eyeHeight
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
    var greenLight: Bool { barGrabbedTime != nil }
    /// 你的脚离地面多高（米）
    var heightAboveGround: Double { altitude - eyeHeight - scene.groundElevation }
    /// 高度表的读数：按着陆区归零（英尺）
    var altitudeFeet: Int { Int(max(heightAboveGround, 0) * Self.feetPerMeter) }
    var canDeploy: Bool { heightAboveGround <= Self.alertAGL }

    /// 手表报警：0 不响，1 可以开伞了（三声一组），2 低于决断高度（急促）
    var alarmLevel: Int {
        guard phase == .freefall else { return 0 }
        if heightAboveGround <= Self.hardDeckAGL { return 2 }
        return heightAboveGround <= Self.alertAGL ? 1 : 0
    }

    /// 航向对应的前方（云坐标）
    var forward: SIMD2<Double> { SIMD2(-sin(heading), -cos(heading)) }

    private var fadeDuration: Double { outcome == .crashed ? 0.6 : Self.fadeOutDuration }

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
        // 世界方向 → 舞台方向：反转航向
        let c = cos(heading), s = sin(heading)
        let local = SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
        var angle = atan2(local.x, -local.y)            // 0 = 正前方，顺时针为正
        if angle < 0 { angle += 2 * .pi }
        var clock = Int((angle / (2 * .pi) * 12).rounded())
        if clock == 0 { clock = 12 }
        return (clock, distance)
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 一关的着陆区。现在只有环礁：潟湖里一片白沙洲，靶铺在沙洲上（和 shader 里的 SANDBAR_* 一致）。
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
