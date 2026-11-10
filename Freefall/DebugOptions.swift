import Foundation
import simd

/// 只在 DEBUG 构建或模拟器里生效的启动参数，用来在模拟器里不碰按钮跑完整流程：
///
///     xcrun simctl launch <设备> com.feiyuchang.freefall -autoEnter YES -mute YES -lookDown 45 -startAltitude 9100
///
/// - `-autoEnter YES`：启动后直接跳
/// - `-mute YES`：不出风声（测试一律静音）
/// - `-lookDown <度>` / `-lookUp <度>` / `-turnLeft <度>`：模拟器的头不会动，用它低头 / 抬头 / 左转。
///   参数值不能写负数：UserDefaults 会把 `-30` 当成下一个参数名，所以每个方向各用一个正数参数。
/// - `-startAltitude <米>`：跳过机舱，从这个高度直接开始自由落体
/// - `-timeScale <倍>`：时间快进
enum DebugOptions {
#if DEBUG || targetEnvironment(simulator)
    static let autoEnter = UserDefaults.standard.bool(forKey: "autoEnter")
    static let mute = UserDefaults.standard.bool(forKey: "mute")
    static let pitch = Float(UserDefaults.standard.double(forKey: "lookUp") - UserDefaults.standard.double(forKey: "lookDown"))
    static let yaw = Float(UserDefaults.standard.double(forKey: "turnLeft"))
    static let startAltitude: Double? = UserDefaults.standard.object(forKey: "startAltitude") != nil
        ? UserDefaults.standard.double(forKey: "startAltitude") : nil
    static let timeScale = UserDefaults.standard.object(forKey: "timeScale") != nil
        ? UserDefaults.standard.double(forKey: "timeScale") : 1
#else
    static let autoEnter = false
    static let mute = false
    static let pitch: Float = 0
    static let yaw: Float = 0
    static let startAltitude: Double? = nil
    static let timeScale: Double = 1
#endif

    /// 叠在头部朝向上的旋转（只在模拟器里有用：那里的头不会动）
    static var headRotation: simd_float4x4 {
        let y = simd_float4x4(simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0)))
        let p = simd_float4x4(simd_quatf(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0)))
        return y * p
    }
}
