# 隐私：政策要点、App 隐私问卷、权限说明

结论：**Freefall 上架版不收集任何数据**。依据是对 release 分支代码的核查（2026-11-13，基于 master 3ddce3a + 本分支的改动）：

| 查的东西 | 结果 |
|---|---|
| 联网代码（`URLSession`、`Network` / `NWConnection`、`CFNetwork`、WebKit、socket） | 没有。`PerfLink` 在 release 分支已删掉；编出来的二进制没有链接 Network 框架，`strings` 搜不到相关符号 |
| 第三方 SDK、统计、广告、崩溃上报 | 没有（只用 Apple 的 SwiftUI、ARKit、CompositorServices、Metal、AVFoundation） |
| 账号、登录、Game Center、iCloud、内购 | 没有 |
| 存在设备上的东西 | `UserDefaults`：选哪一关、高度表戴哪只手、手套 / 拉环转向 / 拉平这些设置、每关最近的落点距离、自动画质档位；合并皮肤那批改动后还有皮肤解锁状态和语言选择。都只在本机 |
| 手部追踪（ARKit `HandTrackingProvider`） | 每帧读 27 个关节位置，用来抓扶杆、拉拉环和操纵环、摆手套和手腕上的高度表；只在内存里，不写盘、不离开设备 |
| 头部位姿（ARKit `WorldTrackingProvider` 的设备锚点） | 每帧读，用来摆机舱、伞和 HUD；只在内存里 |
| 眼动 | visionOS 不给 app 眼睛看哪里的数据，游戏也没用 |
| 性能测试写的 `Documents/perf.txt` | 上架版里这段代码不编译，不会写 |

> 合并 master 上那批皮肤 / 回放 / 语言改动以后，再按上表核一遍：尤其是有没有新的联网、新的权限说明、新的 Required Reason API（比如读文件的创建 / 修改时间）。

## App 隐私问卷（App Store Connect → App 隐私）

- **Data Collection**：选 **No, we do not collect data from this app**。之后的问题都不用答。
  - 依据：Apple 的定义是「collect」= 把数据传出设备、并且保存超过实时处理所需的时间；
    原文要点 "Data that is processed only on device is not 'collected' and does not need to be disclosed."
    手、头的数据只在设备上逐帧处理，不算收集，visionOS 的 Body（Hands、Head）、Surroundings 两类也不用勾。
  - 出处：<https://developer.apple.com/app-store/app-privacy-details/>、
    <https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/>
- **Privacy Policy URL**：必填（Manage app privacy 页写的是 "A privacy policy URL is required for all apps"）。
  现在还没有，见下面「支持页和隐私页」。
- **隐私清单** `Freefall/PrivacyInfo.xcprivacy`（release 分支已加，需要合回 master）：不追踪、不收集；
  声明 `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`（只读写本 app 自己的数据）。
  另外按 Wandless 的做法保守声明了 `NSPrivacyAccessedAPICategorySystemBootTime` / `35F9.1`（量 app 内两件事之间的间隔）：
  Apple 的列表只点名 `ProcessInfo.systemUptime` 和 `mach_absolute_time()`，没有点名游戏用的 `CACurrentMediaTime()`，
  多声明不扣分、少声明上传时会收到 ITMS-91053 警告。
  用了 UserDefaults 就必须有隐私清单，和联不联网无关（2024-05-01 起不声明会被拒收）。
  出处：<https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>

## 两条权限说明

| 键 | 现在的文字（英文 / 简中，十种语言齐全） | 结论 |
|---|---|---|
| `NSHandsTrackingUsageDescription` | Lets you grab the bar, pull the deployment handle and toggles with your hands, and wear the altimeter on your wrist. / 用来让你用手抓扶杆、拉开伞拉手和操纵环，并把高度表戴在你的手腕上。 | 到位：说清了用途，和玩法一致。合并后「真手」选项没了，这句话仍然准确 |
| `NSWorldSensingUsageDescription` | Tracks the position and direction of your head. / 用来跟踪你头部的位置和朝向。 | 文字没问题。**需要在头显上确认一件事**：游戏只用 `WorldTrackingProvider` 拿头部位姿，按我的理解这不需要世界感知授权，所以这个弹窗可能永远不会出现。真机首次启动时看一下：不弹就说明这条说明用不上，留着无害；弹了就说明它是需要的 |
| ~~`NSLocalNetworkUsageDescription`~~ | 性能测试发回开发用 Mac | release 分支已删 |

- `project.yml` 里写的是简体中文原文，十种语言都由 `InfoPlist.xcstrings` 覆盖（编出来的包里每个 `.lproj/InfoPlist.strings` 都有这两条）；系统语言不在十种里时显示英文（`CFBundleDevelopmentRegion` 是 en）。
- 不允许手部追踪时游戏仍能玩（改用捏合手势），审核员拒绝授权也能走完一跳。

## 应用内必须能找到隐私政策（缺口，需要改代码）

审核指南 5.1.1(i)："All apps must include a link to their privacy policy in the App Store Connect metadata field
**and within the app in an easily accessible manner**."（<https://developer.apple.com/app-store/review/guidelines/>，页面标注 2026-10-16 更新）

**现在游戏里没有这个链接。** 建议照 Wandless 的做法：在开始窗口（设置条下面那行「建议坐着、戴耳机……」旁边）放
「隐私政策 · 支持 · 致谢」三个链接（链接只放在窗口里，不放进沉浸空间）；「致谢」同时解决下面音频 CC BY 署名的问题。
`StartView.swift` 正好是皮肤那批改动也改了的文件，所以建议**合并 master 之后**再加，免得冲突。

## 支持页和隐私页（缺口，需要你决定）

App Store Connect 要 Support URL 和 Privacy Policy URL。Wandless 用的是一个单独的 GitHub Pages 仓库（`wandless-support`：
`index.html` 支持页 + `privacy.html` 隐私页，中英两种语言）。Freefall 的草稿已经做好，在 [support-site/](support-site/)（`index.html` 支持页含致谢、`privacy.html` 隐私页），内容就是下面的草稿。
建仓库、开 Pages、推送都是对外发布的动作，要你点头再做；里面的联系邮箱由你自己填（文档里一律写 `<联系邮箱>`）。

## 隐私政策草稿

### English

> **Freefall — Privacy Policy**
> Last updated: `<date>`
>
> Freefall does not collect, store, transmit or share any personal data. The game contains no networking code, no
> analytics, no advertising and no tracking, and it does not require an account. Nothing you do in the game leaves your device.
>
> **Hand tracking.** With your permission, Freefall reads the positions of your hands and fingers through Apple's ARKit so
> you can grab the bar, pull the handle and the toggles, and wear the altimeter on your wrist. This happens on your Apple
> Vision Pro, frame by frame, in memory. Hand data is never recorded, stored or transmitted. If you don't allow hand
> tracking, you can play with pinch gestures instead.
>
> **Head position.** The game uses the position and direction of your head, provided by visionOS, to place the plane, the
> canopy and the helmet display around you. It is used only while you play and is never stored or transmitted.
>
> **Where you look.** visionOS does not give apps information about where your eyes are looking, and Freefall never receives it.
>
> **Game progress and settings.** Your settings, your closest landing in each world and the gear you have unlocked are saved
> in the game's own private storage on your device. Freefall does not upload them anywhere. If you use iCloud Backup, they
> may be included in your device's backup, which Apple manages.
>
> **Diagnostics.** The game sends no crash reports or usage data. If you have chosen in your device's settings to share
> analytics with app developers, Apple may share anonymous crash reports with the developer; that is Apple's setting, and
> you can turn it off at any time.
>
> **Children.** Freefall collects no data from anyone, including children.
>
> **Deleting your data.** Everything the game stores lives inside the app. Deleting Freefall removes all of it.
>
> **Changes.** If this policy ever changes, the updated version will be posted on this page with a new date.
>
> **Contact.** `<联系邮箱>`

### 简体中文

> **Freefall 隐私政策**
> 最后更新：`<日期>`
>
> Freefall 不收集、不存储、不传输、也不分享任何个人数据。游戏里没有任何联网代码，没有统计分析、广告或追踪，也不需要账号。
> 你在游戏里做的任何事都不会离开你的设备。
>
> **手部追踪**：经你允许后，游戏通过 Apple 的 ARKit 读取双手和手指的位置，让你能抓扶杆、拉开伞拉手和操纵环，并把高度表戴在手腕上。
> 这些都在你的 Apple Vision Pro 上逐帧在内存中完成，手部数据不会被记录、存储或传输。不允许手部追踪时，可以改用捏合手势来玩。
>
> **头部位置**：游戏使用 visionOS 提供的头部位置和朝向，把飞机、降落伞和头盔显示摆在你周围。只在游玩时使用，不会被存储或传输。
>
> **你看向哪里**：visionOS 不向任何 app 提供眼睛注视的位置，Freefall 也从未获得这类信息。
>
> **游戏进度和设置**：你的设置、每一关最近的落点和已解锁的装备保存在设备上游戏自己的私有存储里，Freefall 不会把它们上传到任何地方。
> 如果你开启了 iCloud 云备份，它们可能包含在由 Apple 管理的设备备份中。
>
> **诊断信息**：游戏不发送崩溃报告或使用数据。如果你在设备设置中选择了与 app 开发者共享分析数据，Apple 可能会把匿名的崩溃报告提供给开发者；
> 这是 Apple 的设置，你可以随时关闭。
>
> **儿童**：Freefall 不收集任何人的数据，包括儿童。
>
> **删除数据**：游戏存储的一切都在 app 里面，删除 Freefall 就会全部删除。
>
> **变更**：如果本政策有变化，更新后的版本会发布在这个页面上，并标注新的日期。
>
> **联系**：`<联系邮箱>`

（其余八种语言的产品页不强制要求隐私页本地化；Wandless 的隐私页也只有中英两种。）
