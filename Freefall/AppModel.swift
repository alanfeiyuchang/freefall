import SwiftUI

/// 窗口和沉浸空间之间的状态。跳下去时把开始窗口关掉（不然它会飘在天上），落完再打开。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var isFalling = false
    /// 有手部追踪：用真手抓扶杆、拉开伞拉手、拉操纵环，高度表戴在手腕上。真机上没允许进不了跳伞（HandAccess）；
    /// 只有模拟器是假的，那里自动驾驶，高度表放在前下方
    var handsAllowed = false
    /// 高度表戴在左手腕还是右手腕（记住上次的选择）
    var watchOnLeft: Bool = UserDefaults.standard.object(forKey: "watchOnLeft") as? Bool ?? true {
        didSet { UserDefaults.standard.set(watchOnLeft, forKey: "watchOnLeft") }
    }
    /// 一直戴手套：真手藏起来，画跳伞手套，和装备一样受太阳、伞衣影子、舱里红灯照。
    /// 以前开始窗口里能选「真手」（透视进来的真手），去掉了：真手是房间里的光，和高空对不上，也换不了皮肤。
    /// 渲染器里透视真手那条路还留着（离屏测试 GLOVES=0 画替身手），只是不再让玩家选；以前存的 "gloves" 不再读
    let gloves = true
    /// 界面和提示的语言：空 = 跟随系统（默认），否则是 Localization.languages 里的一个代码（记住）
    var language: String = UserDefaults.standard.string(forKey: Localization.key) ?? "" {
        didSet { Localization.apply(language) }
    }
#if DEV_TOOLS
    /// 这一跳做性能测试（开伞后自动跑一遍，见 ImmersiveRenderer.runBenchmark）；不记住，每次要手动开
    /// （上架版：结果只存在本机、显示在开始窗口里，不发到别处——master 上发回开发用 Mac 的那段在这个分支里删掉了）
    var perfTest = false
    /// 上一次性能测试的结果（也存在 Documents/perf.txt）：显示在开始窗口里
    var perfReport: String = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let text = try? String(contentsOf: dir.appendingPathComponent("perf.txt"), encoding: .utf8) else { return "" }
        print("PERF 上一次存下来的结果：\n" + text)
        fflush(stdout)
        return text
    }()
#endif
    /// 伞下拉左 / 右操纵环转向（记住上次的选择）。默认关：拉环转向时整个世界绕着你转，可能引起晕动症；
    /// 关着时只靠转头、转身，伞跟着你转，操纵环只管减速
    var toggleSteering: Bool = UserDefaults.standard.object(forKey: "toggleSteering") as? Bool ?? false {
        didSet { UserDefaults.standard.set(toggleSteering, forKey: "toggleSteering") }
    }
    /// 伞下快落地时自动拉平（默认，记住）。关掉要自己两边一起拉操纵环拉平，没拉平是重着陆（不给靶心）
    var autoFlare: Bool = UserDefaults.standard.object(forKey: "autoFlare") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoFlare, forKey: "autoFlare") }
    }
    /// 真手现在藏没藏起来（戴手套时：开场在房间里还看得到真手，握住扶杆、手套长出来以后才藏，见 FreefallApp）
    var realHandsHidden = false
    /// 跳哪一关（记住上次的选择）
    var scene: JumpScene = JumpScene(rawValue: UserDefaults.standard.integer(forKey: "scene")) ?? .atoll {
        didSet { UserDefaults.standard.set(scene.rawValue, forKey: "scene") }
    }
    /// 这一跳从开伞前开始（练习；开始窗口里按了「开伞前开始」才是 true，跳完复位）
    var practice = false
    /// 这一关能不能从开伞前开始练：平安落地过一次（bestDistance 里有这一关）
    func practiceAvailable(_ scene: JumpScene) -> Bool { bestDistance[scene.rawValue] != nil }
    /// 上一跳的结果（落地后回到开始窗口时显示）
    var lastResult: JumpResult?
    /// 上一跳新解锁的皮肤（开始窗口里显示一行）
    var lastUnlocks: [SkinUnlocks.Item] = []
    /// 解锁了哪些皮肤（记住）：落进降落点解锁那一关的伞，落进黄色靶心再解锁那一关的手套和袖子
    var skinUnlocks = SkinUnlocks(defaults: .standard) {
        didSet { skinUnlocks.save(to: .standard) }
    }
    /// 现在用的伞、手套和袖子（记住；nil = 默认）
    var skin = SkinChoice(defaults: .standard, unlocks: SkinUnlocks(defaults: .standard)) {
        didSet { skin.save(to: .standard) }
    }
    /// 每关落地时离靶心最近的一次（米，按关的编号；记住）。摔了、撞山、掉进熔岩这种不算
    var bestDistance: [Int: Double] = {
        let stored = UserDefaults.standard.dictionary(forKey: "bestDistance") as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in Int(k).map { ($0, v) } })
    }() {
        didSet {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: bestDistance.map { (String($0.key), $0.value) }),
                                      forKey: "bestDistance")
        }
    }

    /// 所有关里最近的一次（米，哪一关）
    var overallBest: (distance: Double, scene: JumpScene)? {
        bestDistance.compactMap { key, d in JumpScene(rawValue: key).map { (distance: d, scene: $0) } }
            .min { $0.distance < $1.distance }
    }

    /// 开始窗口关掉以后就没有视图能拿到这两个环境动作了，所以先存下来，落完时用。
    var openWindow: OpenWindowAction?
    var dismissImmersiveSpace: DismissImmersiveSpaceAction?

    /// 落完（淡出结束），或者用户按数码表冠提前退出（渲染层失效）时调用。
    func fallEnded(result: JumpResult?) {
        guard isFalling else { return }
        isFalling = false
        if let result {
            lastResult = result
            let key = result.scene.rawValue
            if result.landed, result.distance < bestDistance[key] ?? .infinity { bestDistance[key] = result.distance }
            // 解锁皮肤（和落地时提示里说的是同一套规则：Skins.earned）
            lastUnlocks = skinUnlocks.record(scene: result.scene, outcome: result.outcome)
        } else {
            lastUnlocks = []
        }
        openWindow?(id: StartView.windowID)
        Task { await dismissImmersiveSpace?() }
    }
}
