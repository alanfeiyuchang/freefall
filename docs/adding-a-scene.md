# 怎么加一个新场景

*Adding a world to Freefall. The project's docs are in Chinese; the code identifiers, commands and file
names below are what you need — a translator handles the rest.*

这份说明对应 master `921b9c4`（合并了皮肤、随机风那一批之后）。行号会变，下面只写文件和符号名，用搜索找。
提交前请先看 [CONTRIBUTING.md](../CONTRIBUTING.md) 的贡献条款。

## 先了解：一关是什么

- 一关是 `Freefall/Shared/JumpScene.swift` 里 `enum JumpScene` 的一个 case，着色器里对应 `Freefall/Shaders/TerrainField.h` 的 `SCENE_*` 宏，两边用同一个编号（`rawValue`）。
- **所有关共用一个靶**：地面坐标 `(380, -620)`（`JumpScene.target`、`LZ_TARGET`），默认开伞点约在 `(0, -102)`，从开伞点到靶的方向是 `VALLEY_DIR`。
  新地形要**围着这个靶摆**：靶上要能落、开伞以后顺着飞得到。靶不能挪；想让这一关换个进场，挪开伞点（`openShift`）。
- 地形是**程序生成的高度函数**，没有高度图文件。GPU（`TerrainField.h`）画网格、生成高度图和山影；
  CPU（`Freefall/Shared/TerrainField.swift`）是**逐行照抄的同一份**，用来判断落地、撞山、落水、挂树。两边必须一致。
- 地形以外的东西（树、石头、风向袋、建筑）是 `Freefall/Shared/Props*.swift` 启动时生成的网格。
- 新关请做成**有地形的关**（`hasTerrain` 为 true，这是默认）。环礁那种「只有海和沙洲」的关走的是一条写死的路径，不适合复用。

## 编号：只能加在末尾

新关的 `rawValue` 必须是 **7**（下一个是 8……），不能插到中间。很多东西按编号存在玩家设备上，插在中间会全部错位：

- `UserDefaults`：上次选的关（`scene`）、每关最好成绩（`bestDistance`）、已解锁的皮肤（`unlockedCanopies` / `unlockedGloves`）、
  当前用的皮肤（`canopySkin` / `gloveSkin`）、每关的画质档位（`qualityLevel.<编号>`）；
- 着色器里的 `SCENE_*`、`F.world.x`、地形缓存的烘焙参数都直接用编号。

想让新关在开始窗口的转盘里排在中间：给 enum 写显式的 raw value，按想要的显示顺序声明，新关写 `case foo = 7`。
`allCases` 按声明顺序排，存的编号不变。转盘、页面圆点、皮肤页都遍历 `allCases`，会自动多出一项。

## 编译器会帮你找的，和不会的

加了 case 以后，**穷举的 switch 会编译报错**，照着补就行：

| 文件 | 符号 |
|---|---|
| `JumpScene.swift` | `name`、`key`、`tagline`、`blurb`、`windRange`、`dzElevation`、`heightRange` |
| `TerrainField.swift` | `height`、`hazard` |
| `SceneProps.swift` | `layout(for:)` |
| `Skins.swift` | `canopyName`、`glovesName`、`canopy()`、`gloves()` |

**下面这些不会报错，最容易漏**（用 `default` 或 `==` 判断；Metal 里的 switch 不全也不报错）：

| 位置 | 不改会怎样 |
|---|---|
| `TerrainField.h` 的 `terrainHeight`、`terrainHazard` | **GPU 上地面是平的 0 米、永远「没事」**，而 CPU 按真地形判落地 |
| `Terrain.h` 的 `terrainSurface`：一串 if / else-if，**最后的 `else` 是火山** | **新关会画成火山**（灰土、熔岩堤，低处判成水） |
| `Objects.h` 的 `sceneGroundAlbedo`：写的是数字 `case 1…6`，不是宏 | 装备朝下的一面按海面的反光算，偏暗 |
| `SceneRenderer.swift` 的 `seaLevel`（只认火山、海岛） | 有海的话，海画在海床上，海天交界多一条黑线 |
| `Freefall.metal` 的 `weatherStyle` | 用环礁那套云 |
| `JumpScene` 的 `openShift`、`designWind`、`exitAltitude`、`cloudOffset` | 用默认值（多数情况可以） |
| `Skins.swift` 的 `slider` | 皮肤页的滑块是白色 |
| `ImmersiveRenderer.updateAudio` 的环境声（`seaside`、`birds`、`rumble`） | 没有环境声 |
| render-check 用 `SCENE=7` 时 `JumpScene(rawValue:) ?? .atoll` | 忘了加 case 就**静默跑成环礁** |

## 第一步：能跑起来

1. **`JumpScene.swift`**：末尾加 `case xxx`，按编译错误把穷举 switch 补齐。
   - `key`：资源文件名用的英文小写名（`card_<key>.jpg`、`skin_*_<key>.jpg`）。
   - `name`、`tagline`、`blurb`：写 `String(localized: "中文原文")`，翻译在后面第 11 步加。
   - `dzElevation`：着陆区海拔，高度表在这里归零，**必须等于地形函数在靶上的高度**（第 5 步会验证）。
   - `heightRange`：地形的最低、最高海拔，给 LOD 和裁剪用，**宁大勿小**（写小了地形会缺块）。第 5 步会打印实际值。
   - `windRange`：先照一个地形相近的关抄，第 6 步再调。
2. **`SceneProps.swift`** 的 `layout(for:)`：先返回 `SkyCity.Layout()`（空的），第 8 步再做道具。
3. **`Skins.swift`**：`canopyName`、`glovesName`、`canopy()`、`gloves()` 先抄一套现有的，第 10 步再做自己的。
4. **地形，两边各写一份：**
   - `TerrainField.h`：加 `#define SCENE_XXX 7`；写 `xxxHeight(float2 p)`（可以用文件里现成的 `tFbm`、`tEroded`、`tRidged`、`valleyCoords`）；
     在 `terrainHeight` 和 `terrainHazard` 里各加一个 case（**没有危险也要写一个返回 0 的 case**）。
   - `TerrainField.swift`：把同样的函数**逐行照抄**成 Swift，在 `height` 和 `hazard` 里加 case。
     超越函数和 GPU 的 `precise::` 要对得上，参照文件里已有的写法。
   - `Terrain.h` 的 `terrainSurface`：在火山的 `else` **之前**加 `else if (scene == SCENE_XXX) { … }`，按高度、坡度、噪声决定颜色和材质（`s.material`）。
     有水边或树林的话，同时在 `generateSurfaceMap` 里写 r（水边）、g（树林）通道。
5. 跑 `xcodegen generate`（新加了源文件就要跑），编译，然后跑下面的 **terrain** 检查：两边一致、靶的高度等于 `dzElevation`，再按打印的范围定 `heightRange`。
6. 跑 `SCENE=7 … sim` 和 `… wind`，调 `windRange`；进场的路线不对就调 `openShift`，测试用的固定风是 `designWind`。

到这里新关就能玩了：有地形、能落地、会判输赢。

## 第二步：做完整

7. **画面**：`weatherStyle`（这一关的云：种子、云塔位置、多少）、`sceneGroundAlbedo` 加 `case 7`、
   满屏雪这种很亮的关在 `SceneRenderer` 里调曝光、有海的话加进 `seaLevel`，以及 `Terrain.h` 里水、树冠、陡壁岩层这些细节分支（搜 `SCENE_ALPINE`、`SCENE_ISLAND` 看别的关怎么做）。
8. **道具**：新建 `Freefall/Shared/PropsXxx.swift`，参照 `PropsAlpine.swift` 或 `PropsSnow.swift`，用 `PropScatter.spots(scene:…)` 撒点，
   会撞的东西放进 `obstacles`。**文件要放在 `Freefall/Shared/`**：离屏工具只编译这个目录。
9. **新的危险**（地面类型 `MAT_*`、落地结果 `Outcome`）：
   - 地面类型编号两边必须一样：`TerrainField.h` 的 `MAT_*` 和 `TerrainField.swift` 的 `enum Material`，**只加在末尾**。
   - 只用现有的危险（水、树林、熔岩、岛外）：在 `terrainHazard` / `hazard` 里返回对应类型就够了。
   - 一种新的失败方式要改这几处，其中后五处不会报错：
     `JumpTimeline` 的 `Outcome`（加 case）、`JumpSession` 的 `baseSummary` 和 `symbol`（会报错）；
     `JumpTimeline.isFatal`、`JumpSession` 里的 `landed` 列表、`JumpTimeline.touchDown` 那串判断（不加这一步，新危险永远不会触发）、
     `ImmersiveRenderer` 的落地音效、render-check skins 模式里手写的结果列表。
   - 想在空中提示（像火山的毒烟、天空之城的「脚下是云海」）：`JumpSession` 里加一句。
10. **皮肤**：`Skins.swift` 的 `canopy()` 返回图案编号和最多 6 个颜色（线性反照率），`gloves()` 返回手套、护甲、袖子的颜色和条纹。
    要新的伞面图案：在 `Shaders/Skins.h` 加 `SKIN_*` 宏和 `canopySkinAlbedo` 里的一个 case（图案编号和关的编号无关）。
    颜色和图案请从这一关的景物里取，和现有七关一样。
11. **文字，十种语言**：在 `tools/l10n/strings.py` 的「关卡」段加关名、tagline、blurb，「皮肤」段加伞名和手套名，
    还有新提示、新结果说明；然后 `python3 tools/l10n/make.py`。
    make.py 只检查每行十种语言齐不齐、占位符对不对，**不会扫代码**：漏了的 `String(localized:)` 不报错，所有语言都显示中文原文。
12. **卡片图和皮肤缩略图**（缺了不报错，显示一块灰色）：
    - 关卡卡片：`SCENE=7 NOHUD=1 tools/render-check/run.sh <目录> shots card` → 裁成 3:4、540×720 → `Freefall/Resources/Cards/card_<key>.jpg`。
      默认低头 30° 朝靶看；要别的角度，改 `tools/render-check/main.swift` 里 `card` 镜头的 `pitch`。
    - 皮肤缩略图：`SKINS=7 tools/render-check/run.sh <目录> shots xh_canopy,x1_ring` → 裁成 3:2、800×534 →
      `Freefall/Resources/Skins/skin_canopy_<key>.jpg`、`skin_gloves_<key>.jpg`。
13. **环境声**：`ImmersiveRenderer.updateAudio` 里按关给 `ambience`（海浪海鸥）、`birds`（鸟）、`rumble`（轰鸣）。
    要一种新的环境声，得在 `WindAudio.swift` 的 `Params` 加字段并在渲染循环里合成。
14. README 和注释里写死的「七关」「0~6」改一下（只是文字）。

## Verify

离屏工具在 Mac 上跑，不用头显（`tools/render-check/run.sh <输出目录> <模式>`）：

| 模式 | 查什么 | 新关要看到 |
|---|---|---|
| `terrain` | 每个有地形的关随机取几千个点，GPU 和 CPU 各算一遍高度和地面类型 | 高度差约 0、类型不一致 0 个、靶的高度 = `dzElevation`；打印的最低 / 最高用来定 `heightRange` |
| `wind` | 每关取风的范围的边角，自动驾驶 3,000 英尺开伞各跳一次 | 全部进靶（`WINDTRACE=<key>` 打印伞下轨迹，帮你调） |
| `SCENE=7 … sim` | 不同高度开伞、练习起点、手动拉平 | 按时开伞能进靶，太晚开伞要摔 |
| `skins` | 解锁规则和存档读写 | 通过 |
| `hazards` | 写死的几个检查点 | 给新关加几个点（河里、林子里、悬崖上） |
| `SCENE=7 … shots`、`perf` | 出图、量 GPU 耗时 | 看画面；耗时和别的地形关差不多 |

最后在 Xcode 里编 visionOS 的 Release，能上头显的话真机跳一次。PR 里附几张 `shots` 的图。
