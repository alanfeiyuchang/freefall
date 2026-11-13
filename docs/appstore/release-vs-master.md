# release 分支和 master 的差别

release 分支（上架版）= master + 下面这几处。原则：**开发功能用一个编译条件 `DEV_TOOLS` 统一控制**，
release 分支不定义它；只有本地网络那一项（PerfLink）是真删，不只是不编译。

## 差别清单

| # | 内容 | master（开发） | release（上架） | 改在哪 |
|---|---|---|---|---|
| 1 | HUD 右侧面板左上角的帧率、GPU 毫秒、画质档位 | 显示 | **不画**（帧率照样量，自动画质要用） | `Shared/HelmetHUD.swift`、`ImmersiveRenderer.swift`（`#if DEV_TOOLS`） |
| 2 | 开始窗口设置条里的「性能测试」和下面上次测试结果的那块文字 | 有 | **没有** | `StartView.swift`（`#if DEV_TOOLS`） |
| 3 | 性能测试逻辑：`runBenchmark`、`benchConfigs`、`Documents/perf.txt` 的读写、`perfTest` / `perfReport` | 有 | **不编译** | `ImmersiveRenderer.swift`、`AppModel.swift`、`FreefallApp.swift`（`#if DEV_TOOLS`） |
| 4 | GPU 统计日志（每 2 秒一条）、换画质档位的日志 | 有 | **不编译**（只留「无法创建渲染器」「ARKit 启动失败」两条错误日志） | `ImmersiveRenderer.swift` |
| 5 | `PerfLink`：TCP 把测试结果发回开发用的 Mac（`import Network`、`NWConnection`、端口 8765、读 `perf-host.txt` 里的局域网地址） | 有 | **删掉**，连同渲染器创建失败时发回 Mac 的那一行 | `AppModel.swift`、`ImmersiveRenderer.swift` |
| 6 | 本地网络权限说明 `NSLocalNetworkUsageDescription` 和它的十种语言翻译 | 有 | **删掉**（不会再弹本地网络权限） | `project.yml`、`tools/l10n/strings.py` → 重新生成的 `InfoPlist.xcstrings` |
| 7 | `Freefall/Resources/perf-host.txt`（gitignore 的本机文件） | 在就会打进包 | **排除**：就算本机有这个文件也不打进包 | `project.yml` 的 `excludes` |
| 8 | 「性能测试」「关」「这一跳测」三条界面文字 | 有 | 删掉 | `tools/l10n/strings.py` → `Localizable.xcstrings` |
| 9 | 隐私清单 `PrivacyInfo.xcprivacy`（不追踪、不收集；声明 UserDefaults CA92.1、系统开机时间 35F9.1） | **没有** | 新加 | `Freefall/PrivacyInfo.xcprivacy` |
| 10 | 出口合规 `ITSAppUsesNonExemptEncryption = NO` | 没有 | 新加（上传 build 时不再问加密） | `project.yml` |

9、10 两项对开发版也没坏处，建议一起合回 master。

## 本来就进不了上架版的（没改，核对过）

- `DebugOptions.swift` 的启动参数（`-autoEnter`、`-mute`、`-startAltitude`、`-autopilot`、`-timeScale`、`-lookDown` 等）：
  `#if DEBUG || targetEnvironment(simulator)`，真机 Release 版里全是常量（不读启动参数）。
- 模拟器专用路径（头部抬到 1.6 米、`isSimulator`）：`#if targetEnvironment(simulator)`。
- 每 90 帧一条的状态日志：`#if DEBUG || targetEnvironment(simulator)`。
- 着色器调试开关：`SceneRenderer.Settings.debugFlags` → `F.exposure.z` 只有性能测试会改（release 里性能测试不编译，永远是 0）；
  `PROFILE_SKIP_MARCH` / `PROFILE_FLAT_SCENE` / `PROFILE_TERRAIN_FLAT` / `DEBUG_TERRAIN_DEPTH` 只有 `tools/render-check/run.sh`
  传 `METAL_DEFINES` 才会定义，Xcode 工程里没有。
- 动态分辨率（`renderScale` < 1、`encodeScaled` 的缩小路径）：只有画质 4~7 档会用，自动画质封顶在 3 档
  （`SceneRenderer.maxAutoQuality`），存下来的档位读回来时也按它截断；性能测试的配置也都是 `scale: 1`。
- `tools/` 下的离屏渲染、性能脚本、手套转换脚本：不在 app target 的 sources 里，不进包。

## 怎么验证的（2026-11-13，基于 master 3ddce3a）

- `xcodegen generate` 后 `xcodebuild -configuration Release -destination 'generic/platform=visionOS'` 编过（无签名编译）。
- 编出来的 `Freefall.app`：
  - `Info.plist` 里只有 `NSHandsTrackingUsageDescription`、`NSWorldSensingUsageDescription` 两条权限说明，
    `ITSAppUsesNonExemptEncryption = false`；没有 `NSLocalNetworkUsageDescription`。
  - `otool -L` 没有链接 Network 框架；`strings` 搜不到 `NWConnection`、`8765`、局域网地址、`PERF`。
  - 各 `.lproj` 里搜不到本地网络说明和「性能测试」；包里没有 `perf-host.txt`、有 `PrivacyInfo.xcprivacy`。
- 全仓库（`Freefall/`、`project.yml`）搜不到 `PerfLink`（除了 `project.yml` 一行注释）、`NWConnection`、`URLSession`、`import Network`、局域网地址。
- 离屏渲染同一个镜头（`FPS=1 tools/render-check/run.sh … shots handle`，f5_handle），一次不带、一次带 `-D DEV_TOOLS`：
  带的那张 HUD 右侧面板左上角有「90 FPS / 6.4 MS Q1」，不带的没有，其余像素完全一样。
  对比图：[`release-check/hud-master-dev.jpg`](release-check/hud-master-dev.jpg)、[`release-check/hud-release.jpg`](release-check/hud-release.jpg)。

## 以后从 master 合并

- 建议把 1~4 的 `#if DEV_TOOLS` 包裹、9、10 合回 master，并在 master 的 `project.yml` 里加
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) DEV_TOOLS`（`tools/render-check/run.sh` 的 swiftc 也加 `-D DEV_TOOLS`，
  不然离屏渲染 `FPS=1` 看不到帧率）。PerfLink 在 master 上挪进单独的 `Freefall/PerfLink.swift`，整个文件包在 `#if DEV_TOOLS` 里。
  这样两边的差别就只剩：`project.yml` 一行开关、`PerfLink.swift` 一个文件、本地网络说明一条。
- 合并时冲突大概率出在 `AppModel.swift`、`StartView.swift`、`ImmersiveRenderer.swift`、`tools/l10n/strings.py`：
  原则是 master 新加的东西照收，开发用的东西重新包进 `#if DEV_TOOLS`，然后跑 `python3 tools/l10n/make.py` 重新生成 xcstrings。
- 合完再跑一遍上面「怎么验证的」：尤其是 `strings` 搜 `NWConnection` / `8765`、`Info.plist` 里没有本地网络说明。
