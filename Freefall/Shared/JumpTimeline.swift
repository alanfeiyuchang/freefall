import Foundation
import simd

/// 一次跳伞的全过程：机舱 → 出舱 → 自由落体 → 开伞 → 伞降 → 淡出。
///
/// 坐标约定：你（舞台）不动、不转——VR 里镜头自己转最容易晕。飞机、伞衣跟着「你」的舞台坐标走；
/// 云、海、环礁按你在「云坐标」里的水平位置 `position` 平移（云坐标原点就是天气图中心）。
/// 你面朝舞台 -Z = 机尾的舱门方向；飞机往 +Z（你背后）飞。开伞后伞往 -Z（你面朝的方向）飞。
struct JumpTimeline {
    enum Phase: Int, Sendable { case cabin, exit, freefall, opening, canopy, done }

    // 飞机：在 30,000 ft 平飞，放人时的空速约 70 m/s（136 节）
    static let planeAltitude: Double = 9144
    static let planeSpeed: Double = 70
    /// 舱门旁的跳伞灯由红变绿的时间
    static let greenLightTime: Double = 6
    /// 绿灯后不捏手指，到这个时间自动跳
    static let autoExitTime: Double = 11
    /// 从站的位置往舱门跑出去，加速着跑，正好在这个时间离开跳板
    static let exitDuration: Double = 2.2
    /// 站的位置到跳板末端的距离（米）
    static let rampEnd: Double = 6.2
    /// 出舱后水平速度（相对空气）按这个时间常数衰减
    static let throwTimeConstant: Double = 3.5
    // 开伞
    static let deployAltitude: Double = 760          // 2,500 ft
    static let openingDuration: Double = 3.5
    /// 伞降的下沉速度：真实的伞约 5 m/s，这里快一点，伞降段压在一分半钟左右
    static let canopySink: Double = 7.5
    static let canopySpeed: Double = 10
    static let fadeAltitude: Double = 45
    static let fadeInDuration: Double = 1.5
    static let fadeOutDuration: Double = 3
    /// 起跳时你在云坐标里的 z：舱里随飞机走、出舱后惯性滑行，总共往 +Z 走一千米上下，停在原点附近
    static let startZ: Double = -1000
    static let feetPerMeter = 3.28084

    private(set) var phase: Phase = .cabin
    private(set) var time: Double = 0
    private(set) var altitude: Double = planeAltitude
    /// 向下为正（m/s）
    private(set) var verticalSpeed: Double = 0
    /// 你在云坐标里的水平位置 (x, z)
    private(set) var position = SIMD2<Double>(0, startZ)
    /// 相对空气的水平速度 (x, z)
    private(set) var velocity = SIMD2<Double>(0, planeSpeed)
    /// 机舱地板原点相对舞台原点的位置
    private(set) var planeOffset = SIMD3<Double>(0, 0, 0)
    private(set) var exitTime: Double?
    private(set) var leftRampTime: Double?
    private(set) var deployTime: Double?
    private(set) var fadeTime: Double?
    private var glide: Double = 0
    private var exitRequested = false
    private var openingStartVertical: Double = 0

    init() {}

    /// 调试用：跳过机舱，从某个高度直接开始自由落体（已经是终端速度）。
    init(freefallFrom startAltitude: Double) {
        phase = .freefall
        time = 20                       // 跳过开头的淡入
        altitude = startAltitude
        verticalSpeed = Self.terminalVelocity(at: startAltitude)
        position = SIMD2(0, 0)
        velocity = SIMD2(0, 0)
        exitTime = 10
        leftRampTime = 12
        planeOffset = SIMD3(0, Self.planeAltitude - startAltitude + 5000, 5000)
    }

    /// 终端速度（m/s）：∝ 1/√空气密度，密度按 8.5 km 标高指数衰减
    static func terminalVelocity(at altitude: Double) -> Double {
        54 * exp(altitude / 17000)
    }

    /// 捏一下手指：绿灯亮了才算
    mutating func requestExit() {
        if phase == .cabin, time >= Self.greenLightTime { exitRequested = true }
    }

    mutating func step(_ dt: Double) {
        guard dt > 0, phase != .done else { return }
        time += dt
        switch phase {
        case .cabin:
            position += velocity * dt                   // 跟着飞机走
            if exitRequested || time >= Self.autoExitTime {
                phase = .exit
                exitTime = time
            }
        case .exit:
            // 加速跑向舱门（s² 曲线），离开跳板时相对飞机约 5.6 m/s
            let s = min((time - exitTime!) / Self.exitDuration, 1)
            let newGlide = Self.rampEnd * s * s
            let glideSpeed = (newGlide - glide) / dt
            glide = newGlide
            velocity = SIMD2(0, Self.planeSpeed - glideSpeed)
            position += velocity * dt
            planeOffset.z = glide
            if s >= 1 {
                leftRampTime = time
                phase = .freefall
            }
        case .freefall:
            fall(dt)
            velocity *= exp(-dt / Self.throwTimeConstant)
            position += velocity * dt
            if altitude <= Self.deployAltitude {
                phase = .opening
                deployTime = time
                openingStartVertical = verticalSpeed
            }
        case .opening:
            let s = min((time - deployTime!) / Self.openingDuration, 1)
            let e = Self.smoothstep(s)
            verticalSpeed = openingStartVertical + (Self.canopySink - openingStartVertical) * e
            velocity = SIMD2(0, -Self.canopySpeed * e)
            altitude -= verticalSpeed * dt
            position += velocity * dt
            if s >= 1 { phase = .canopy }
        case .canopy:
            verticalSpeed = Self.canopySink
            velocity = SIMD2(0, -Self.canopySpeed)
            altitude -= verticalSpeed * dt
            position += velocity * dt
            if fadeTime == nil, altitude <= Self.fadeAltitude { fadeTime = time }
            if let fadeTime, time - fadeTime >= Self.fadeOutDuration { phase = .done }
        case .done:
            break
        }
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

    // MARK: - 给渲染和声音用的量

    var isOver: Bool { phase == .done }
    var greenLight: Bool { time >= Self.greenLightTime }
    var altitudeFeet: Int { Int(altitude * Self.feetPerMeter) }

    /// 画面亮度：开头淡入，最后淡出
    var brightness: Double {
        let fadeIn = Self.smoothstep(min(time / Self.fadeInDuration, 1))
        guard let fadeTime else { return fadeIn }
        return fadeIn * (1 - Self.smoothstep(min((time - fadeTime) / Self.fadeOutDuration, 1)))
    }

    /// 还在机舱里的程度（手套的光照用：舱里是红灯，出去以后是太阳）
    var inCabin: Double {
        guard let leftRampTime else { return 1 }
        return 1 - Self.smoothstep(min((time - leftRampTime) / 0.6, 1))
    }

    /// 伞衣张开的程度 0…1（开伞前 0）
    var canopyOpen: Double {
        guard let deployTime else { return 0 }
        return Self.smoothstep(min((time - deployTime) / (Self.openingDuration * 0.75), 1))
    }

    /// 飞机离你多远（米）
    var planeDistance: Double { length(planeOffset) }

    /// 风有多大（m/s）：舱里是舱门灌进来的风，自由落体是下落速度，伞下是往前飞的速度
    var windSpeed: Double {
        switch phase {
        case .cabin, .exit: return 35
        case .freefall: return verticalSpeed
        case .opening, .canopy, .done: return max(verticalSpeed, Self.canopySpeed)
        }
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
