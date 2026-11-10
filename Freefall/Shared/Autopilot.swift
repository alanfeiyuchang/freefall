import Foundation
import simd

/// 自动跳：模拟器里没有手，离屏测试也要跑完整流程。几秒后抓杆 → 松手 → 到高度拉伞 → 伞下飞向靶。
struct Autopilot {
    /// 在多少英尺拉伞（手表 3,500 ft 报警，低于这个才拉得动）
    var deployFeet: Double = 3000
    var grabAt: Double = 2.5
    var holdFor: Double = 2.5
    /// 伞下不自己转向，一直按这个刹车量（测试用）
    var hold: (left: Double, right: Double)?

    /// 伞下正背着靶往外飞（消高度）
    private var awayLeg = false

    mutating func drive(_ t: inout JumpTimeline) {
        switch t.phase {
        case .cabin:
            if t.barGrabbedTime == nil, t.time >= grabAt { t.grabBar() }
            if let grabbed = t.barGrabbedTime, t.time - grabbed >= holdFor { t.releaseBar() }
        case .freefall:
            if Double(t.altitudeFeet) <= deployFeet, t.heightAboveGround > 0.5 { t.requestDeploy() }
        case .canopy:
            let b = hold ?? steer(t)
            t.setBrakes(left: b.left, right: b.right)
        default:
            break
        }
    }

    /// 伞下像跳伞员飞着陆航线：先对着靶飞；到了靶附近高度还富余，就背着靶飞出去把高度消掉，
    /// 剩下的高度刚好够掉头、对着靶直飞时再转回来。
    private mutating func steer(_ t: JumpTimeline) -> (left: Double, right: Double) {
        let v = t.scene.target - t.groundPosition
        let d = length(v)
        let f = t.forward
        // 靶偏在前进方向的哪边：正 = 左边（往左转 = heading 增大）
        let toTarget = atan2(-(f.x * v.y - f.y * v.x), dot(f, v))
        // 直飞还能飞多远：拉平前按正常的下沉，最后 6 米拉平再往前飘一段
        let reach = JumpTimeline.canopySpeed * max(t.heightAboveGround - 6, 0) / JumpTimeline.canopySink + 15
        let excess = reach - d
        // 掉头一次要花掉的距离：转 180° 约 7 秒，这段路几乎没往靶靠近，转弯时下沉也更快
        let turnBack = 115.0
        if !awayLeg, d < 250, excess > turnBack + 60 { awayLeg = true }
        if awayLeg, excess < turnBack { awayLeg = false }
        let angle = awayLeg ? (toTarget > 0 ? toTarget - .pi : toTarget + .pi) : toTarget
        let turn = min(max(angle * 1.5, -1), 1)
        return (max(turn, 0), max(-turn, 0))
    }
}
