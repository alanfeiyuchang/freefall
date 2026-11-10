import Foundation

/// 下落过程：从 30,000 英尺出舱，竖直方向受重力和空气阻力，速度趋近终端速度。
/// 高空空气稀薄，终端速度更快（约 90 m/s），越往下越慢（海平面约 54 m/s）。
/// 只有竖直运动、不转镜头：VR 里镜头自己转是最容易晕的。
struct FallSimulation {
    static let startAltitude: Double = 9144      // 30,000 ft
    /// 到这里开始淡出（以后接开伞）
    static let endAltitude: Double = 1000
    static let fadeInDuration: Double = 1.5
    static let fadeOutDuration: Double = 3
    static let feetPerMeter = 3.28084

    private(set) var altitude: Double
    private(set) var velocity: Double = 0
    private(set) var time: Double = 0
    private(set) var endTime: Double?

    init(startAltitude: Double = Self.startAltitude) {
        altitude = startAltitude
    }

    /// 终端速度（m/s）：∝ 1/√空气密度，密度按 8.5 km 标高指数衰减
    static func terminalVelocity(at altitude: Double) -> Double {
        54 * exp(altitude / 17000)
    }

    mutating func step(_ dt: Double) {
        guard dt > 0 else { return }
        time += dt
        let vt = Self.terminalVelocity(at: altitude)
        velocity += 9.81 * (1 - (velocity / vt) * (velocity / vt)) * dt
        altitude -= velocity * dt
        if endTime == nil, altitude <= Self.endAltitude {
            endTime = time
        }
    }

    /// 画面亮度：开头淡入，到了结束高度淡出
    var brightness: Double {
        let fadeIn = smoothstep(min(time / Self.fadeInDuration, 1))
        guard let endTime else { return fadeIn }
        return fadeIn * (1 - smoothstep(min((time - endTime) / Self.fadeOutDuration, 1)))
    }

    var isOver: Bool {
        guard let endTime else { return false }
        return time - endTime >= Self.fadeOutDuration
    }

    var altitudeFeet: Int { Int(altitude * Self.feetPerMeter) }

    private func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
