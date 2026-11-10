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
    /// 跳哪一关（记住上次的选择）
    var scene: JumpScene = JumpScene(rawValue: UserDefaults.standard.integer(forKey: "scene")) ?? .atoll {
        didSet { UserDefaults.standard.set(scene.rawValue, forKey: "scene") }
    }
    /// 上一跳的结果（落地后回到开始窗口时显示）
    var lastResult: String?

    /// 开始窗口关掉以后就没有视图能拿到这两个环境动作了，所以先存下来，落完时用。
    var openWindow: OpenWindowAction?
    var dismissImmersiveSpace: DismissImmersiveSpaceAction?

    /// 落完（淡出结束），或者用户按数码表冠提前退出（渲染层失效）时调用。
    func fallEnded(result: String?) {
        guard isFalling else { return }
        isFalling = false
        if let result { lastResult = result }
        openWindow?(id: StartView.windowID)
        Task { await dismissImmersiveSpace?() }
    }
}
