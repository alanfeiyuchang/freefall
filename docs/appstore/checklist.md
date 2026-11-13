# 上架前检查清单

> **2026-11-13 进度**：App Store Connect 里已建好 app「Freefall: Skydive」（Apple ID 6834571083，bundle ID com.feiyuchang.freefall，visionOS）。
> 已上传 build 1.0 (1)（`tools/appstore/upload.sh`）；十种语言 + 墨西哥西语的名称、副标题、隐私政策网址、描述、关键词、推广文本、支持网址已填；
> 类别 Games › Simulation + Sports；版权「2026 Feiyu Chang」；9 张 3840×2160 截图（7 张取自头显实录、2 张离屏渲染）；审核备注已填。
> 还没做：选 build（Apple 还在处理）、App Motion Information、年龄分级、App 隐私问卷、价格与销售范围（去掉中国大陆）、内容版权、审核联系人信息，然后才能提交。

✅ 已在 release 分支上做好 · ⬜ 还要做 · 🔶 要你决定 / 要你在 App Store Connect 或头显上操作

## 代码和工程（release 分支）

- ✅ 调试 / 开发功能都藏掉了，PerfLink 和本地网络权限删掉了（[release-vs-master.md](release-vs-master.md)）
- ✅ 隐私清单 `Freefall/PrivacyInfo.xcprivacy`（UserDefaults `CA92.1`，系统开机时间 `35F9.1`）
- ✅ `ITSAppUsesNonExemptEncryption = NO`（`project.yml`）
- ✅ 版本号：`MARKETING_VERSION` 从 0.1 改成 **1.0**；build 号 `CURRENT_PROJECT_VERSION` 是 **1**。
  以后每上传一次 build 号都要加一（同一个版本号下 build 号不能重复）。
- ✅ Bundle ID `com.feiyuchang.freefall`、Team `5V3HM8L9GT`（`project.yml`，和 Wandless 同一个开发者账号）
- ⬜ **把皮肤那批改动合进来**：等它们在 master 上提交后，把 master 合进 release 分支，按 release-vs-master.md 末尾的步骤处理冲突、重跑验证。
  上架文案是按合并后的功能写的（皮肤、练习、航线回看、自动 / 手动拉平、游戏内选语言）。
- ✅ **App 内的隐私政策链接**（审核指南 5.1.1(i)）：开始窗口设置条最下面一行「隐私政策 · 支持 · 致谢」，十种语言，点了用系统浏览器打开 freefall-support 网站（`StartView.swift` 的 `SiteLinks`）
- ✅ **App 内的音频署名**：「致谢」链到支持页的 Credits 一节（音效 CC BY 4.0 署名、手套模型来源）
- 🔶 头显上用 Release 包完整过一遍七关，确认：HUD 上没有帧率；开始窗口里没有「性能测试」；第一次启动只弹手部追踪授权（看世界感知授权弹不弹，见 privacy.md）；从没有弹过本地网络授权。
- ⬜ Archive：Xcode → Product → Archive（Release），Organizer 里 Distribute → App Store Connect 上传。**上传要你来做或者明确让我做。**

## 图标

- ✅ `Freefall/Assets.xcassets/AppIcon.solidimagestack`：前 / 中 / 后三层，各 1024×1024，后层不透明（无 alpha），前两层带透明，符合 visionOS 的分层图标要求；
  编出来的 Info.plist 里有 `CFBundlePrimaryIcon = AppIcon`，编译没有图标警告。
- 🔶 在头显主屏幕上看一眼图标的立体分层效果（App Store 产品页用的是同一套图）。

## 授权

- **音频**（`Freefall/Resources/Audio/CREDITS.txt`）：三段音效都是 Huggy13ear 在 freesound.org 上的作品，**CC BY 4.0**：
  wind 2（风声循环）、parachute 2（开伞）、nylon flapping 1（伞衣抖动）。CC BY 要求「以合理的方式」署名：作者、作品名、许可证和链接、是否修改过。
  - ✅ 十种语言的描述末尾都加了一行署名（作品名、作者、freesound.org、CC BY 4.0）。
  - ✅ app 里的「致谢」链接打开支持页的 Credits 一节，那里有作品名、作者、原链接、许可证链接和改动说明。
    包里现在只有 CREDITS.txt 这个文件，玩家看不到，单靠它不算「合理的方式」。
  - 改动说明（转 AAC、响度归一、首尾交叉淡化成循环、随速度变调滤波）CREDITS.txt 里已经写了，致谢页带上即可。
- **手套模型**（`Freefall/Resources/Gloves/`，来自 Apple 示例代码「Animating hand models in visionOS」）：
  `LICENSE-Apple-sample.txt` 是 MIT 式许可（© 2025 Apple Inc.），条件是「副本中保留版权声明和许可声明」。
  - ✅ 许可文件已经随包分发（编出来的 `Freefall.app` 里有 `LICENSE-Apple-sample.txt`），满足条件。
  - ✅ 支持页的 Credits 一节列了手套模型的来源和许可。
- 程序生成的其它内容（飞机、伞、云、地形、合成音效）都是自己写的，没有别的第三方素材。字体用的是系统字体。

## 出口合规

- ✅ Info.plist 里 `ITSAppUsesNonExemptEncryption = NO`。上传 build 后 App Store Connect 不会再问加密问题。
- 依据：Apple 的说明是，app 和它链接的库「不使用加密，或者只使用豁免于出口文件要求的加密」时可以设 NO；
  操作系统自带的加密通常属于豁免（<https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>）。
  Freefall 上架版不联网、不带任何加密库，不在 app 层面使用加密。
- 如果 ASC 仍然弹问卷：「Does your app use encryption?」选 **No**。

## App Store Connect 里要填的

| 项 | 填什么 | 状态 |
|---|---|---|
| App 名称 | 每种语言见 `metadata/*.md` 的 `name`。**「Freefall」单独几乎肯定已被占用**（名称在每个语言里全局唯一），所以文案用的是「Freefall: Skydive」这类带后缀的名字；建 app 记录时先试，被占了就换后缀 | 🔶 |
| 副标题、推广文本、描述、关键词、此版本新增 | `metadata/*.md`（十种语言），`python3 tools/appstore/check_metadata.py` 检查长度 | ✅ 草稿 |
| 主语言 | English (U.S.) | 🔶 |
| 西班牙语 | 同一份 es-ES 也填进 **Spanish (Mexico)**：拉美大部分国家默认看 es-MX，西班牙才看 es-ES | 🔶 |
| 法语 | 同一份也可填 French (Canada) | 可选 |
| 类别 | Games → Simulation + Sports（[review-and-rating.md](review-and-rating.md)） | 🔶 |
| 年龄分级 | 预计 4+（恐怖选「偶尔」则 9+）；2026-11-16 新增的两题答「否」 | 🔶 |
| App Motion Information | **Yes, contains high motion** | 🔶 |
| App 隐私 | Data Not Collected（[privacy.md](privacy.md)） | 🔶 |
| Support URL | `https://alanfeiyuchang.github.io/freefall-support/`（仓库 alanfeiyuchang/freefall-support，2026-11-13 已发布） | ✅ |
| Privacy Policy URL | `https://alanfeiyuchang.github.io/freefall-support/privacy.html` | ✅ |
| Marketing URL | 可不填 | — |
| 版权（Copyright） | `2026 <你的名字或公司名>`（文档里不写你的名字，由你自己填） | 🔶 |
| 价格、销售范围 | 价格由你定。**取消勾选中国大陆**：在中国大陆上架游戏要国家新闻出版署的游戏版号（ISBN 核发单），没有的话 App 在中国大陆不可用，ASC 会显示 "Missing Game registration number"。Wandless 也是除中国大陆外全部地区 | 🔶 |
| 付费 App | 如果收费：要先签 Paid Apps Agreement、填税务和银行信息；在欧盟上架还要申报 DSA 交易商（trader）身份 | 🔶 |
| 截图、预览视频 | [screenshots.md](screenshots.md) | ⬜ |
| 审核备注 | [review-and-rating.md](review-and-rating.md) 里的英文段落；联系人信息你来填；不需要演示账号 | ✅ 草稿 |
| 内容版权（Content Rights） | 「是否包含第三方内容」：**是**（CC BY 音效、Apple 示例的手套模型），并确认有使用权 | 🔶 |

出处：中国大陆版号 <https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/>（"Availability in China mainland"）；
名称唯一 <https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/>。

## 文案里遵守的 Apple 规定

- 不把它叫 VR / AR / XR / MR 游戏（Apple 要求称为 spatial computing app，<https://developer.apple.com/visionos/submit/>）；描述和关键词里都没有这些词。
- 「Apple Vision Pro」不进 App 名称，只在描述里出现；前面不加冠词（不写 the Apple Vision Pro），不翻译；visionOS 小写 v。
- 关键词按 **100 字节**准备（App Store Connect Help 写的是 "up to 100 bytes"；中日韩一个字 3 字节），不重复名称里的词，逗号后不加空格。
- 不写价格、不提其他 App 和平台。
