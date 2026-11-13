# 开源前检查（2026-11-13）

对象：GitHub 私有仓库 `alanfeiyuchang/freefall`。公开以后别人能看到的是：远端的 `master`（现在是 `921b9c4`，已合进 PR #1 皮肤那批）、它的全部提交历史、PR #1 的描述和讨论。
本地另外几个分支（`claude/release-d0a64c`、`claude/skins-92ed46`、5 个 `worktree-wf_*`、`refs/wip/finetune-base`）没推送过，不会公开，除非以后推上去。

结论：**可以公开，没有必须先改写历史的问题。** 要做的是补上许可证和第三方声明（已起草，见文末），以及几件需要你定的事。

## 1. git 历史（全部 31 个提交、所有本地分支和远端）

扫了每个提交新增的每一行（约 13.8 万行），以及历史里出现过的每个文件名：

| 查什么 | 结果 |
|---|---|
| 密钥、令牌（GitHub / OpenAI / AWS / Google / Slack 令牌格式、私钥头） | 没有 |
| 证书、描述文件、`.env`、`.p8` / `.p12` / `.mobileprovision` | 没有 |
| `perf-host.txt`（PerfLink 用的局域网地址） | **从来没被提交过**（一直在 .gitignore 里） |
| 局域网 IP（10.x、172.16–31.x、192.168.x） | 没有 |
| 本机路径（`/Users/…`） | 没有 |
| 邮箱 | 文件内容里没有；提交作者里有 16 个提交用的是你的 Gmail（和支持页上公开的是同一个），其余是 GitHub 的 noreply 地址 |
| 姓名、雇主等个人信息 | 没有（"oppo" 的命中全是意大利语 *troppo*） |
| PR #1 描述、Issues | PR 描述只讲改动和验证；没有 Issue；没有评论 |

会公开、但本来就公开或无所谓的：
- Bundle ID `com.feiyuchang.freefall`、开发者 Team ID `5V3HM8L9GT`（在 `project.yml`）。Team ID 本来就写在每个签名的 app 里，不是秘密。
  但别人 clone 下来要改成自己的 Team 才能编；可以保持现状，在 README 里说一句。
- README 里「灵感来自小红书上一段网页作品『THIN AIR』的录屏」：只是说灵感来源，没有用对方的素材。

历史里最大的文件是手套法线贴图（3 MB）、图标原图和手套网格（各 1.5 MB），整个仓库不大，不用清理。

## 2. 第三方素材和代码的许可证

| 东西 | 在哪 | 许可证 | 开源能不能带 | 要做什么 |
|---|---|---|---|---|
| 三段音效 | `Freefall/Resources/Audio/` | CC BY 4.0（Huggy13ear，freesound.org） | 能 | 带署名和改动说明——`CREDITS.txt` 已有，`THIRD_PARTY_NOTICES.md` 里也列了 |
| 手套模型和贴图 | `Freefall/Resources/Gloves/` | Apple 示例代码许可（MIT 式，© 2025 Apple Inc.） | 能 | 保留版权和许可声明——`LICENSE-Apple-sample.txt` 已经在两个目录里 |
| App 图标 | `AppIcon.solidimagestack`、`Design/AppIcon/Final/` | 本机 FLUX.2 klein-4B 生成（模型是 Apache 2.0，商用可以） | 能 | 但建议**不放进 MIT 授权范围**（见第 3 节）。注：我是从本机只装了 klein-4B 推断的，你确认一下当时用的是不是 4B（9B 是非商用许可） |
| 关卡卡片、皮肤缩略图、docs 里的预览图 | `Resources/Cards`、`Resources/Skins`、`docs/` | 游戏自己离屏渲染的 | 能 | — |
| 渲染循环骨架 | `ImmersiveRenderer.swift` | 经 Bubble Dream 来自 MetalSplatter 的 visionOS 示例，MIT（© 2026 Sean Cier，GitHub 上的 LICENSE 原文） | 能 | MIT 要求带上版权和许可声明——之前代码里只有一行注释，**现在补进了 `THIRD_PARTY_NOTICES.md`** |
| 大气散射 | `Shaders/Atmosphere.h` | 照 sebh/UnrealEngineSkyAtmosphere 写，MIT（© 2020 Epic Games, Inc.） | 能 | 同上，已补 |
| 云噪声 | `Shaders/Noise.h` | 照 sebh/TileableVolumeNoise 写，MIT（© 2017 Sébastien Hillaire） | 能 | 同上，已补 |
| 侵蚀 fbm | `Shaders/TerrainField.h` 的 `tEroded` | Inigo Quilez 文章里的技术（5 行的公式，自己写的） | 能 | 只是技术引用，已在声明里致谢；风险很低 |
| pcg3d 哈希 | `Shaders/Noise.h` | Jarzynski & Olano 2020 论文里的算法 | 能 | 已致谢 |
| 字体 | — | 只用系统字体 | — | — |

没有发现 GPL / 非商用（NC）许可的素材或代码，选 MIT 没有冲突。

## 3. 需要你定的事

1. **许可证**：起草的是 MIT（`LICENSE`，版权人 Feiyu Chang）。另一个常见选择是 Apache-2.0（多一条专利授权，对这个项目意义不大）。不要选 GPL：和 App Store 的使用条款有冲突。
2. **名字和图标不放进开源授权**：`LICENSE` 末尾已经写了「Freefall 这个名字和 app 图标不在 MIT 范围内，请别用这个名字和图标发布」。
   这只能防君子；真要防止别人原样上架，靠的是 Apple 审核指南 4.1（抄袭）和 4.3（重复 app），以及你先上架占住名字。
3. **要不要把 `docs/appstore/` 一起公开**：里面是上架文案、审核备注、隐私问卷答案，公开没有坏处（不少开源 app 也这么做），但也可以只留在私有分支里。
4. **打赏**：`.github/FUNDING.yml` 是全部注释掉的草稿，要你填 Venmo 用户名再打开。微信收款码不是网址，建议放到 freefall-support 网站上一个打赏页，这里链过去。
   按上一轮说的：**app 里和商店页面不要放打赏的引导**。

## 4. 公开的步骤（每一步都要你点头）

1. 把 `LICENSE`、`THIRD_PARTY_NOTICES.md`、`.github/FUNDING.yml` 合进 `master`（现在在 release 分支上；release 分支还落后远端 master 一个 PR #1，见下）。
2. README 开头加两行：许可证（MIT，名字和图标除外）、编译前把 `project.yml` 里的 `DEVELOPMENT_TEAM` 和 Bundle ID 换成自己的。
3. 仓库设为公开：`gh repo edit alanfeiyuchang/freefall --visibility public --accept-visibility-change-consequences`。
   公开以后历史就收不回来了；之后想再改私有，fork 和 clone 已经出去了。
4. 选做：仓库描述、topics（visionos、metal、apple-vision-pro）、关掉不用的 Wiki / Projects。

## 附：release 分支和远端 master 的关系

远端 `master` 已经合进 PR #1（皮肤、随机风、航线回放、语言设置，`921b9c4`），release 分支是从合并前的 `3ddce3a` 切出来的，还没合这一批。
上架和开源都要基于合并后的 master，所以下一步要把 `origin/master` 合进 release 分支（会在 `AppModel.swift`、`StartView.swift`、`ImmersiveRenderer.swift`、`tools/l10n/strings.py` 有冲突，按 `docs/appstore/release-vs-master.md` 末尾的办法处理）。
