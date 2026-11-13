import Foundation

/// 游戏里自己选的语言（开始窗口设置条里的「语言」，默认跟随系统）。选了某种语言时，这里是那种语言的 .lproj 目录。
///
/// 为什么要这个：Foundation 的 `String(localized:)` 按 Bundle.main 启动时就定下的语言列表查翻译，
/// 运行中改 `AppleLanguages` 没用，它的 `locale:` 参数也不影响查哪种语言（在 Mac 上试过）；
/// 只有 `bundle:` 参数管用——传一个指向 `fr.lproj` 目录的 Bundle，就从那里查。
/// 所以在这个模块里放一个同名的 `String(localized:)`（下面），模块里所有的调用都先走它，自动带上这个 bundle；
/// 编译器优先选模块里的这个，不会和 Foundation 的那个打架。没选语言（nil）时和原来一模一样。
/// 离屏测试（tools/render-check）不设它：UILANG 照旧靠启动参数里的 AppleLanguages。
enum AppLanguage {
    /// 主线程（开始窗口）写，渲染线程（提示文字）和 HUD 的后台线程读：加锁
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedBundle: Bundle?
    nonisolated(unsafe) private static var storedCode: String?

    static var bundle: Bundle? {
        get { lock.withLock { storedBundle } }
        set { lock.withLock { storedBundle = newValue } }
    }
    /// 选中的语言代码（nil = 跟随系统）：HUD 用 CoreText 画字时按它挑字形
    static var code: String? {
        get { lock.withLock { storedCode } }
        set { lock.withLock { storedCode = newValue } }
    }
}

extension String {
    init(localized value: String.LocalizationValue, comment: StaticString? = nil) {
        self.init(localized: value, table: nil, bundle: AppLanguage.bundle ?? .main, locale: .current, comment: comment)
    }
}
