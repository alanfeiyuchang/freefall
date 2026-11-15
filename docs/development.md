# 开发：运行、调试、离屏检查、代码结构

编译运行、模拟器启动参数、离屏渲染检查（tools/render-check）、文件结构。

[← 回到 README](../README.md)

需要 Xcode 27 和 visionOS 27 SDK，没装过 Metal Toolchain 的话先装：`xcodebuild -downloadComponent MetalToolchain`。

```bash
xcodegen generate
open Freefall.xcodeproj
```

工程文件不进仓库，由 `project.yml` 生成：加了新的源文件或资源以后要重新跑一次 `xcodegen generate`。

装到头显上（头显开机、解锁，和 Mac 在同一个 Wi-Fi 里）：

```bash
tools/install-device.sh            # 编 Release 并安装
tools/install-device.sh --launch   # 装完直接启动
```

### 模拟器里不点按钮跑完整流程（只在 DEBUG 构建或模拟器里生效）

```bash
xcrun simctl launch <设备> com.feiyuchang.freefall -autoEnter YES -mute YES -autopilot YES -lookDown 30 -timeScale 4
```

| 参数 | 作用 |
|---|---|
| `-autoEnter YES` | 启动直接跳。落完窗口重新打开后会再跳一次 |
| `-mute YES` | 不出声 |
| `-lookDown <度>` / `-lookUp <度>` / `-turnLeft <度>` | 模拟器里头不会动，用这几个参数让它低头、抬头、左转。只能给正数：UserDefaults 会把 `-30` 当成参数名 |
| `-startAltitude <米>` | 跳过机舱，从这个高度直接开始自由落体 |
| `-timeScale <倍>` | 快进 |
| `-autopilot YES` | 自动跳：几秒后抓杆、松手，到 `-autoDeploy <英尺>`（默认 3000）拉伞，伞下自己飞向靶 |
| `-scene <0~6>` | 跳哪一关：0 环礁 1 草原 2 高山 3 雪山 4 海岛 5 火山 6 天空之城（就是开始窗口里的选择，会记住） |

模拟器没有手部追踪，所以高度表在前下方，跳下去一律自动驾驶。

## 离屏渲染检查（不开窗口、不出声）

```bash
tools/render-check/run.sh <输出目录> shots   # 舱门、抓杆、绿灯、出舱、雨云里、看表、报警、拉手、开伞五个阶段、操纵环、靶、落地、摔等 30 个镜头，
                                             # x 开头：装备近景（拉环、伸缩带、操纵环、3 环、表、第三人称正面 / 侧面、快落地时地上的影子）
                                             # v：开场实体化的几个阶段；cab：机舱（扶杆、地板、舱壁、座椅、跳板、舱顶）；w：穿云后湿手套、云里的雾团
SCENE=<0~6> NOHUD=1 tools/render-check/run.sh <目录> shots card   # 开始窗口的卡片截图（伞下朝靶飞），裁成 3:4 放进 Freefall/Resources/Cards/
tools/render-check/run.sh <输出目录> sim     # 不出图：自动驾驶在 3,500 ft ~ 不开伞之间各跳一次，打印结果（PILOT=3000 打印伞下每 2 秒的状态）
tools/render-check/run.sh <输出目录> skins   # 不出图：皮肤的解锁规则（每关 × 每种落地结果）、存进去再读出来（= 重启以后）、落地提示里的那几行
SKINS=all tools/render-check/run.sh <目录> shots xh_canopy,x1_ring   # 每个镜头按默认 + 七套皮肤各画一张（<镜头>_skin<关>.png，-1 是默认）；
                                             # SKIN=<0~6> 整个跑一套，CANOPYSKIN / GLOVESKIN 只换一样。xe：伞下仰头看伞，xh：前上方看伞（皮肤页的缩略图），
                                             # xi：低空看伞投在地上的影子；镜头名过滤可以写几个，逗号隔开
tools/render-check/run.sh <输出目录> hands   # 不出图：用合成的手走真手的抓握逻辑（抓杆、手短暂丢失、松手、提前拉、报警后拉、左右环转向）
tools/render-check/run.sh <输出目录> terrain # 不出图：同一批点上比对 GPU（TerrainField.h）和 CPU（TerrainField.swift）的地形高度和地面类型
tools/render-check/run.sh <输出目录> hazards # 不出图：火山口、熔岩、冰裂缝、冰湖、河、陡坡、烟柱这几个点的判定
SCENE=2 tools/render-check/run.sh <输出目录> shots   # 环境变量 SCENE 选关；地形关有自己的一套镜头（俯瞰、穿云、开伞后看靶、看两边的山、低空、落地）
tools/render-check/run.sh <输出目录> perf    # 按真机分辨率（两只眼各 1888×1792）测 GPU 耗时
tools/render-check/run.sh <输出目录> seq     # 连续下落 + 转头 90 帧，查云层重投影有没有拖影（SEQ=cabin 从机舱开始）
tools/render-check/run.sh <输出目录> film    # 整段跳伞按 90 Hz 跑，存成 30 fps 的预览帧
tools/render-check/run.sh <输出目录> maps    # 天气图、环礁图（叠上伞降路线）、云影图、时间线和大气常量
```

它在 Mac 上用和 Vision Pro 一样的方式（2 层纹理数组 + vertex amplification）跑同一份 `SceneRenderer`、`JumpSession`（输入 → 时间线 → 布料）和 shader，
镜头用自动驾驶从机舱一路跑到那个时刻，所以和真机上的过程一模一样，提示文字也画出来。
手部追踪和透视只有真机有，这里用合成的关节姿态摆手（握扶杆、抓拉手、抓操纵环、看表），画肤色的「替身手」代替真手。

- 环境变量 `EXPOSURE`、`SIGMA`、`STEP`、`CLOUDSCALE` 可以临时改参数。
- 量闪烁（`shots` 模式）：`FLICKER=8` 把头在一个像素以内分 8 步斜着挪过去，每步画一张，量每个像素相邻两步之间最大跳多少，
  存 `<镜头>_flicker.png`（越亮跳得越凶）并打印全图平均和跳变超过 24 的像素占比。抗锯齿好的边一步只变八分之一，
  硬边和不到一个像素宽的东西一步跳满。配 `FOVY=28`（960 行、28° 大约是头显中心每度 34 个像素的密度）和 `YAW=`、`PITCH=`
  换视场角和朝向，例：`SCENE=1 NOHUD=1 FOVY=28 YAW=118 PITCH=0 FLICKER=8 tools/render-check/run.sh <目录> shots td_landed`。
- `METAL_DEFINES="-DPROFILE_SKIP_MARCH"` 关掉云的步进，`"-DPROFILE_FLAT_SCENE"` 关掉天空和海面着色，用来拆开量各个 pass 的耗时。

## 结构

| 文件 | 内容 |
|---|---|
| `Freefall/Shared/JumpTimeline.swift` | 物理和规则：抓杆 → 松手出舱 → 自由落体（重力 + 随高度变的终端速度）→ 报警 → 开伞（先全速再减速）→ 伞下转向 / 刹车 → 落地判定（靶、水、摔、撞山、树林、熔岩、冰裂缝、烟柱）→ 淡出 |
| `Freefall/Shared/JumpScene.swift` | 七关：名字、介绍、着陆区海拔、云层抬多高、地形的海拔范围 |
| `Freefall/Shared/SkyCity.swift` | 天空之城的建筑网格（城堡、柱廊、塔、石环、拱桥、花树、晶石灯）和瀑布，启动时生成一次；撞塔的判定 |
| `Freefall/Shared/Skins.swift` + `Freefall/Shaders/Skins.h` | 皮肤：七套伞、手套和袖子的颜色表、名字、解锁规则（`Skins.earned`）和存档（`SkinUnlocks`、`SkinChoice`）；图案在 shader 里按 uv 现算 |
| `Freefall/SkinPicker.swift` + `Freefall/Resources/Skins/` | 皮肤页（转盘）和卡片上的小徽章；缩略图是离屏渲染裁的（`xh_canopy_front_above`、`x1_ring` 两个镜头，`SKINS=all` 出图后裁成 3:2） |
| `Freefall/Shared/PlayerShadow.swift` | 伞和人的影子：每帧从太阳方向把伞衣（实际网格，透过来的颜色按皮肤的图案算，和伞衣同一个函数）和人（按身形搭的简化人体，手臂跟着手腕）各画进一张剪影贴图，地面、物件、装备着色时顺着阳光查（Common.h 的 canopyShadow / bodyShadow）；离地越高取越模糊的 mip |
| `Freefall/Shared/SceneProps.swift` + `Props<关名>.swift` + `PropBuilder.swift` | 各关立起来的东西：云杉、阔叶树、椰子树、漂木、石头、风向袋。都是启动时算一次的程序网格（从靶往外撒，越远越稀，每关最多约 17 万个顶点），和天空之城的建筑走同一条管线；立在能落的地方的（椰子树、风向袋）带撞击判定 |
| `Freefall/Assets.xcassets` | visionOS 的分层图标（前景降落伞、中景云、后景环礁）；三层原图在 `Design/AppIcon/Final` |
| `Freefall/Shaders/TerrainField.h` + `Freefall/Shared/TerrainField.swift` | 地形的高度和地面类型（同一个程序函数写了 Metal 和 Swift 两份，逐行对应：GPU 画、CPU 判断落地） |
| `Freefall/Shared/TerrainCache.swift` | 地形的光照缓存：一摞以相机为中心的贴图，存算完光照的地面颜色；分层、跟着相机移动、分帧重画（见「性能」） |
| `Freefall/Shared/TerrainLOD.swift` | 地形网格的 LOD（CDLOD 四叉树选块） |
| `Freefall/Shaders/Terrain.h` | 地形网格的顶点 / 片元着色、深度预渲染，启动时生成高度图、山影图、地面类型图 |
| `Freefall/Shaders/Rain.h` | 雨：身边大大小小的水珠、云底下的雨帘、云里往上掠的雾团（按真的云密度） |
| `Freefall/Shared/Interaction.swift` | 真手的抓握判定（握拳 / 捏合，带迟滞）和身上能抓的东西：扶杆、左右两个开伞拉环、两个操纵环；身体的朝向（BodyLayout、BodyYaw：按头和两只手估） |
| `Freefall/Shared/JumpSession.swift` | 每帧的推进（真手 / 自动驾驶 → 时间线 → 布料）、提示文字、提示面板的摆放 |
| `Freefall/Shared/CanopyCloth.swift` | 伞衣的布料模拟（PBD，55×13 个粒子，每个气室 6 列，只限拉伸）：伞包拽出、气室逐个鼓起、后缘抖动、刹车拽下后缘、落地塌下；伞衣投影的形状 |
| `Freefall/Shared/Gear.swift` | 装备的程序网格（照真装备的尺寸）：小臂上的拉环（金属 D 形环 + 红色橡胶握把，拉出来连着钢索）、伸缩带和 3 环、连接环、导向环、操纵环（挂着 / 抓在手里）、滑块扣眼、表壳和表圈、跳伞服袖子；扁带 / 圆管 / 圆环 / 软枕头 / 旋转体几个基本形状 |
| `Freefall/Shared/HelmetHUD.swift` | 头盔 HUD：两侧两块面板 + 底下的提示条，CoreGraphics 画，三张贴图轮着用 |
| `Freefall/Shared/Glove.swift` + `Freefall/Resources/Gloves/` | 手套：读网格和贴图，按手部追踪的关节位置算蒙皮矩阵（`tools/gloves/convert_gloves.py` 从苹果示例的 USDZ 转出来） |
| `Freefall/Shared/Autopilot.swift` | 自动跳（模拟器和离屏测试用），伞下飞着陆航线 |
| `Freefall/Shared/SceneRenderer.swift` | 所有渲染 pass |
| `Freefall/Shared/ProceduralMeshes.swift` | 程序生成的飞机：货舱（T 形加强框、地板和滚轮轨道、系留环、跳板和作动筒、座椅管架、舷窗、伞兵门、舱顶管线、前端隔板和灭火器）、外壳、扶杆（钢管 + 橡胶握把 + 法兰螺栓）、跳伞灯 |
| `Freefall/Shared/SceneObjects.swift` | 每帧摆飞机、伞衣、滑块、伞绳（A、B 排穿前扣眼到前伸缩带，C、D 排到后伸缩带）、刹车绳（分叉 → 滑块 → 导向环 → 操纵环）、装备、表和高度表 |
| `Freefall/Shared/TextPanel.swift` | CoreText 把提示文字画成贴图 |
| `Freefall/StartView.swift` + `Freefall/Resources/Cards/` | 开始窗口：关卡卡片（截图）、最近距离、设置浮条 |
| `Freefall/ImmersiveRenderer.swift` | CompositorServices 渲染循环、头和手的追踪、声音事件、自动画质 |
| `Freefall/WindAudio.swift` | 合成声音 |
| `Freefall/Shaders/` | 大气、云、海、环礁、沙洲和靶、物体、高度表、提示面板 |

坐标约定：
- 你（舞台）始终不动、不转，-Z 是你起跳时面朝的方向（机尾的舱门）。伞下转向是世界绕着你转（航向 `heading`）。
- 飞机、伞跟着舞台坐标走。
- 云按你在「云坐标」里的水平位置平移；海、环礁、靶在「地面坐标」里，地面坐标 = 云坐标 + `landShift`。
  机舱里云照样往后掠，但地面不跟飞机走（`landShift` 抵消），松手以后固定。
- 云相对地面的位置取决于你在舱里等了多久，所以靶周围几百米不落云影（阳光从云缝里照下来），靶总是亮的。
