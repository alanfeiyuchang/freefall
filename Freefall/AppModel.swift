import SwiftUI

/// 窗口和沉浸空间之间的状态。跳下去时把开始窗口关掉（不然它会飘在天上），落完再打开。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var isFalling = false

    /// 开始窗口关掉以后就没有视图能拿到这两个环境动作了，所以先存下来，落完时用。
    var openWindow: OpenWindowAction?
    var dismissImmersiveSpace: DismissImmersiveSpaceAction?

    /// 落完（淡出结束），或者用户按数码表冠提前退出（渲染层失效）时调用。
    func fallEnded() {
        guard isFalling else { return }
        isFalling = false
        openWindow?(id: StartView.windowID)
        Task { await dismissImmersiveSpace?() }
    }
}
