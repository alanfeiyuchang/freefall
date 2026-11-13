import Foundation

/// 游戏里自己选语言（开始窗口设置条里的「语言」）：默认跟随系统，也可以指定十种之一，选了马上生效、不用重开。
/// - 代码里的 `String(localized:)`（关名、HUD、落地提示……）：查选中语言的 .lproj（见 Shared/AppLanguage.swift）。
/// - SwiftUI 的 `Text("…")`：按环境里的 locale 取翻译，FreefallApp 在窗口最外层设 `.environment(\.locale, …)`。
/// - 不写这个 app 的 `AppleLanguages`：写了以后 Bundle.main 下次启动就定在那种语言上，再选回「跟随系统」也回不去系统语言了。
///   代价是系统自己画的东西（比如手部追踪的授权弹窗）还是系统语言。
enum Localization {
    static let key = "appLanguage"

    /// 支持的语言（和 tools/l10n/strings.py 一样），菜单里每种用它自己的写法
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"), ("ko", "한국어"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"), ("pt-BR", "Português (Brasil)"),
    ]

    /// 启动时调一次（FreefallApp.init），之后每次换语言调。空 = 跟随系统
    static func apply(_ code: String) {
        UserDefaults.standard.set(code, forKey: key)
        AppLanguage.bundle = code.isEmpty ? nil
            : Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        AppLanguage.code = code.isEmpty ? nil : code
    }

    /// 给 SwiftUI 的环境用：跟随系统时是系统的 locale
    static func locale(_ code: String) -> Locale { code.isEmpty ? .autoupdatingCurrent : Locale(identifier: code) }
}
