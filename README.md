# Freefall

Apple Vision Pro 上的第一人称高空跳伞小游戏：从一万八千英尺的运输机尾舱门跳出去，穿过下着雨的云层，手表报警时自己拉开伞，
拉着操纵环飞到地上的降落点（铺在地上的红白圆圈）里才算赢。七关：环礁、草原、高山、雪山、海岛、火山、天空之城。
开场在你自己的房间里，握住扶杆以后，飞机和高空从你手边一点点长出来。

灵感来自小红书上一段网页作品「THIN AIR」的录屏。除了手套，所有东西都是程序实时生成的：飞机、伞、装备、云、海、声音。
手套是苹果示例代码里的手套模型（MIT 式许可），换成了跳伞配色，跟着你的真手动；用真手抓扶杆、拉开伞拉手、拉操纵环，
高度表戴在手腕上（左右手开始窗口里选）；点一下手表，头盔里像钢铁侠那样的 HUD 出现在视野两侧。

![预览](docs/preview-contact.jpg)

## 怎么玩（一跳约 4 分钟）

1. 开始窗口里左右滑卡片选一关，点「跳」。游戏只能用真手玩，第一次会请你允许手部追踪。
2. 你还在自己的房间里，身边立着一根黄色扶杆。**握住它**，运输机的货舱从你手边长出来，舱门外是高空。
3. 跳伞灯变绿，**松手**就跳出去了。自由落体一分多钟，中途穿过一层正在下雨的云。
4. 手表在 3,500 英尺报警：**用戴表的手抓住另一只小臂上的红色拉环，往外拉**，开伞。拉得太晚就摔了。
5. 伞下**转头、转身来转向**，伞跟着你转；抓住头两侧的操纵环，两边一起拉是减速，往前推是俯冲。
6. **落进地上红白相间的圆圈就赢**，正中的黄色靶心是完美着陆。点一下手腕上的表开关头盔 HUD，按住两秒退出这一跳。

每一跳的风都不一样；落进靶解锁这一关的降落伞，落进靶心再解锁手套和袖子；平安落地过的关可以从 5,000 英尺开始练；
跳完能看俯视的航线回放。完整的玩法和设计细节见 [docs/gameplay.md](docs/gameplay.md)。

## 七关

| 关 | 着陆区 | 要躲开的 |
|---|---|---|
| 环礁 | 潟湖里的白沙洲 | 水 |
| 草原 | 缓丘和农田 | 河、树林 |
| 高山 | U 形谷的草甸 | 岩壁、林子 |
| 雪山 | 海拔 2,750 米的雪坡 | 太陡的坡；空气稀，要早开伞 |
| 海岛 | 沙滩后面的草地 | 海、雨林 |
| 火山 | 破火山口 | 熔岩、火山口、烟柱 |
| 天空之城 | 云海上浮岛的石头城 | 掉出岛外、撞塔和城堡 |

## 舒适

建议坐着、戴耳机，不需要走动。默认靠转头、转身转向，世界不会绕着你转；「伞下转向」里的「加拉环」会让世界转起来，打开前有晕动提示。
转弯时视野四周压暗，头盔 HUD 跟着头走、是一个不动的参照物。

## 编译运行

需要 Xcode 27、visionOS 27 SDK 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。工程文件由 `project.yml` 生成，不进仓库。

```bash
xcodegen generate && open Freefall.xcodeproj
tools/install-device.sh --launch   # 编 Release 装到 Vision Pro 上并启动
```

模拟器启动参数、离屏渲染检查（`tools/render-check`，在 Mac 上出图、量性能、跑自动驾驶测试）、代码结构见 [docs/development.md](docs/development.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/gameplay.md](docs/gameplay.md) | 玩法和设计细节：风、七关、手和高度表、头盔 HUD、语言、声音、防晕 |
| [docs/development.md](docs/development.md) | 编译运行、模拟器启动参数、离屏渲染检查、文件结构 |
| [docs/rendering.md](docs/rendering.md) | 渲染：大气、体积云、地形、雨、开场的实体化、天空之城 |
| [docs/performance.md](docs/performance.md) | 性能优化记录和头显上的实测 |
| [docs/known-issues.md](docs/known-issues.md) | 已知的不足和下一步 |

## 致谢

- 手套模型来自 Apple 示例代码「[Animating hand models in visionOS](https://developer.apple.com/documentation/visionos/animating-hand-models-in-visionos)」，许可见 `Freefall/Resources/Gloves/LICENSE-Apple-sample.txt`。
- 风声、开伞、伞衣抖动三段音效来自 freesound.org 的 Huggy13ear，CC BY 4.0，详见 `Freefall/Resources/Audio/CREDITS.txt`。
