import Network
import SwiftUI

/// 窗口和沉浸空间之间的状态。跳下去时把开始窗口关掉（不然它会飘在天上），落完再打开。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var isFalling = false
    /// 允许了手部追踪：用真手抓扶杆、拉开伞拉手、拉操纵环，高度表戴在手腕上（不允许就用捏合手势，高度表放在前下方）
    var handsAllowed = false
    /// 高度表戴在左手腕还是右手腕（记住上次的选择）
    var watchOnLeft: Bool = UserDefaults.standard.object(forKey: "watchOnLeft") as? Bool ?? true {
        didSet { UserDefaults.standard.set(watchOnLeft, forKey: "watchOnLeft") }
    }
    /// 戴手套（默认）：真手藏起来，画跳伞手套，和装备一样受太阳、伞衣影子、舱里红灯照；关掉就透视真手（记住上次的选择）
    var gloves: Bool = UserDefaults.standard.object(forKey: "gloves") as? Bool ?? true {
        didSet { UserDefaults.standard.set(gloves, forKey: "gloves") }
    }
    /// 伞下拉左 / 右操纵环转向（记住上次的选择）。默认关：拉环转向时整个世界绕着你转，可能引起晕动症；
    /// 关着时只靠转头、转身，伞跟着你转，操纵环只管减速
    /// 这一跳做性能测试（开伞后自动跑一遍，见 ImmersiveRenderer.runBenchmark）；不记住，每次要手动开
    var perfTest = false {
        didSet {
            // 一打开就连上开发用的 Mac（这时系统会问要不要允许访问本地网络），顺便把上一次存下来的结果发过去
            if perfTest { PerfLink.shared.send("HELLO\n" + perfReport) }
        }
    }
    /// 上一次性能测试的结果（也存在 Documents/perf.txt）：显示在开始窗口里
    var perfReport: String = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let text = try? String(contentsOf: dir.appendingPathComponent("perf.txt"), encoding: .utf8) else { return "" }
        print("PERF 上一次存下来的结果：\n" + text)
        fflush(stdout)
        return text
    }()
    var toggleSteering: Bool = UserDefaults.standard.object(forKey: "toggleSteering") as? Bool ?? false {
        didSet { UserDefaults.standard.set(toggleSteering, forKey: "toggleSteering") }
    }
    /// 真手现在藏没藏起来（戴手套时：开场在房间里还看得到真手，握住扶杆、手套长出来以后才藏，见 FreefallApp）
    var realHandsHidden = false
    /// 跳哪一关（记住上次的选择）
    var scene: JumpScene = JumpScene(rawValue: UserDefaults.standard.integer(forKey: "scene")) ?? .atoll {
        didSet { UserDefaults.standard.set(scene.rawValue, forKey: "scene") }
    }
    /// 上一跳的结果（落地后回到开始窗口时显示）
    var lastResult: JumpResult?
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
        }
        openWindow?(id: StartView.windowID)
        Task { await dismissImmersiveSpace?() }
    }
}

/// 性能测试的结果发回开发用的 Mac（头显不让 devicectl 取文件、也不让接管标准输出）：一条 TCP 连接，一行行发文本。
/// Mac 上 `nc -lk 8765` 收。Mac 的局域网地址写在 `Freefall/Resources/perf-host.txt` 里（一行，不进仓库；
/// 没有这个文件就什么都不发）。
final class PerfLink: @unchecked Sendable {
    static let shared = PerfLink()
    static let host: String = {
        guard let url = Bundle.main.url(forResource: "perf-host", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "perf-link")

    func send(_ text: String) {
        guard !Self.host.isEmpty else { return }
        queue.async {
            if self.connection == nil || self.connection?.state == .cancelled {
                let c = NWConnection(host: NWEndpoint.Host(Self.host), port: 8765, using: .tcp)
                c.stateUpdateHandler = { state in
                    if case .failed = state { c.cancel() }
                }
                c.start(queue: self.queue)
                self.connection = c
            }
            self.connection?.send(content: (text + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }
}
