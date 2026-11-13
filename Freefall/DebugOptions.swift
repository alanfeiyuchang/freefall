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
/// - `-autopilot YES`：自动跳（模拟器里没有手）：几秒后抓杆、松手，到 `-autoDeploy <英尺>`（默认 3000）拉伞，伞下飞向靶
/// - `-showSkins YES`：开始窗口一打开就弹出皮肤页（`-skinsTab 1` 停在手套和袖子那一组）
/// - `-demoBullseye <0~6>`：假装刚在这一关落进靶心（开始窗口里显示结果和新解锁的皮肤，会真的解锁）
/// - `-demoReplay <0~6>`：开始窗口一打开就在 CPU 上用自动驾驶跳这一关一次（`-autoDeploy` 英尺开伞），打开航线页
/// - `-demoHandAccess denied|undetermined`：假装手部追踪被拒绝了 / 还没问过，看开始窗口上的引导弹窗（模拟器本来没有手部追踪，算允许）
/// - 模拟器里没有手部追踪，跳下去一律自动驾驶（不用另给 `-autopilot`）
/// - 解锁状态存在 UserDefaults 的 `unlockedCanopies` / `unlockedGloves`（关的编号数组），
///   截图时可以直接给：`-unlockedCanopies '(0,1,4)'`
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
    static let autopilot = UserDefaults.standard.bool(forKey: "autopilot")
    static let autoDeployFeet = UserDefaults.standard.object(forKey: "autoDeploy") != nil
        ? UserDefaults.standard.double(forKey: "autoDeploy") : 3000
    static let showSkins = UserDefaults.standard.bool(forKey: "showSkins")
    static let skinsTab = UserDefaults.standard.integer(forKey: "skinsTab")
    static let demoBullseye: JumpScene? = UserDefaults.standard.object(forKey: "demoBullseye") != nil
        ? JumpScene(rawValue: UserDefaults.standard.integer(forKey: "demoBullseye")) : nil
    static let demoReplay: JumpScene? = UserDefaults.standard.object(forKey: "demoReplay") != nil
        ? JumpScene(rawValue: UserDefaults.standard.integer(forKey: "demoReplay")) : nil
    static let demoHandAccess: HandAccess? = switch UserDefaults.standard.string(forKey: "demoHandAccess") {
    case "denied": .refused(canAskAgain: false)
    case "undetermined": .refused(canAskAgain: true)
    default: nil
    }
    /// -cleanView YES：不画头盔 HUD、提示条和前下方的高度表，只留画面（录预告片用）
    static let cleanView = UserDefaults.standard.bool(forKey: "cleanView")
#else
    static let autoEnter = false
    static let mute = false
    static let pitch: Float = 0
    static let yaw: Float = 0
    static let startAltitude: Double? = nil
    static let timeScale: Double = 1
    static let autopilot = false
    static let autoDeployFeet: Double = 3000
    static let showSkins = false
    static let skinsTab = 0
    static let demoBullseye: JumpScene? = nil
    static let demoReplay: JumpScene? = nil
    static let demoHandAccess: HandAccess? = nil
    static let cleanView = false
#endif

    /// 叠在头部朝向上的旋转（只在模拟器里有用：那里的头不会动）
    static var headRotation: simd_float4x4 {
        let y = simd_float4x4(simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0)))
        let p = simd_float4x4(simd_quatf(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0)))
        return y * p
    }
}
