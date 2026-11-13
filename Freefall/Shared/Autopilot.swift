import Foundation
import simd

/// 自动跳：模拟器里没有手，离屏测试也要跑完整流程。几秒后抓杆 → 松手 → 到高度拉伞 → 伞下飞向靶。
struct Autopilot {
    /// 在多少英尺拉伞（手表 3,500 ft 报警，低于这个才拉得动）
    var deployFeet: Double = 3000
    var grabAt: Double = 2.5
    /// 亮绿灯以后再抓多久才松手
    var holdFor: Double = 1.5
    /// 伞下不自己转向，一直按这个刹车量（测试用）
    var hold: (left: Double, right: Double)?

    /// 手动拉平时忘了拉（测试重着陆）
    var skipFlare = false

    /// 伞下正背着靶往外飞（消高度）
    private var awayLeg = false

    mutating func drive(_ t: inout JumpTimeline) {
        switch t.phase {
        case .cabin:
            if t.barGrabbedTime == nil, t.time >= grabAt { t.grabBar() }
            if t.greenLight, let grabbed = t.barGrabbedTime,
               t.time - grabbed >= JumpTimeline.revealDuration + JumpTimeline.greenDelay + holdFor { t.releaseBar() }
        case .freefall:
            if Double(t.altitudeFeet) <= deployFeet, t.heightAboveGround > 0.5 { t.requestDeploy() }
        case .canopy:
            var b = hold ?? steer(t)
            // 手动拉平：离地 9 米以内两边一起拉到底
            if !t.autoFlare, !skipFlare, t.terrainClearance < 9 { b = (1, 1) }
            t.setBrakes(left: b.left, right: b.right)
        default:
            break
        }
    }

    /// 伞下像跳伞员飞着陆航线：先对着靶飞；到了靶附近高度还富余，就背着靶飞出去把高度消掉，
    /// 剩下的高度刚好够掉头、对着靶直飞时再转回来。
    private mutating func steer(_ t: JumpTimeline) -> (left: Double, right: Double) {
        let toTargetGround = t.scene.target - t.groundPosition
        let d = length(toTargetGround)
        // 有风：朝侧风修正以后的方向飞（空速 + 风正好指向靶），地速按顺着靶的方向算
        let crab = JumpTimeline.crab(toward: d > 1 ? toTargetGround / d : t.forward, wind: t.wind)
        let v = crab.air
        let f = t.forward
        // 靶偏在前进方向的哪边：正 = 左边（往左转 = heading 增大）
        let toTarget = atan2(-(f.x * v.y - f.y * v.x), dot(f, v))
        // 直飞还能飞多远：拉平前按正常的下沉，最后 6 米拉平再往前飘一段
        let reach = crab.groundSpeed * max(t.heightAboveGround - 6, 0) / JumpTimeline.canopySink + 15
        let excess = reach - d
        // 掉头一次要花掉的距离：转 180° 约 7 秒，这段路几乎没往靶靠近，转弯时下沉也更快
        let turnBack = 115.0
        if !awayLeg, d < 250, excess > turnBack + 60 { awayLeg = true }
        if awayLeg, excess < turnBack { awayLeg = false }
        let angle = awayLeg ? (toTarget > 0 ? toTarget - .pi : toTarget + .pi) : toTarget
        let turn = min(max(angle * 1.5, -1), 1)
        // 对着靶飞、高度富余又不够飞出去掉头一趟：两边一起刹（前进慢四成多、下沉慢四分之一，滑翔变陡；
        // 逆风时地速掉得更多，几乎是往下落），刹到「直飞刚好够」为止（每帧重算，是个反馈：多留多少就落长多少）。离地 12 米以下松开（再低两边一起拉就算拉平了）
        var brake = 0.0
        if !awayLeg, t.heightAboveGround > 12, excess > 15 {
            let dir = d > 1 ? toTargetGround / d : t.forward
            for k in stride(from: 1.0, through: 0.0, by: -0.1) {
                let gs = JumpTimeline.crab(toward: dir, wind: t.wind, airspeed: JumpTimeline.canopySpeed * (1 - 0.45 * k)).groundSpeed
                let r = gs * max(t.heightAboveGround - 6, 0) / (JumpTimeline.canopySink * (1 - 0.25 * k)) + 15
                if r >= d + 5 { brake = k; break }
            }
        }
        // 刹车加在两边，转向靠两边的差：差不能被拉到底截掉
        brake = min(brake, 1 - abs(turn))
        return (max(turn, 0) + brake, max(-turn, 0) + brake)
    }
}
