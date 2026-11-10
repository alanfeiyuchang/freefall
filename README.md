# Freefall

Apple Vision Pro 上的第一人称高空跳伞：从 30,000 英尺的运输机货舱里跳出去，穿过积云，开伞，滑翔到一座环礁的潟湖上空。
完全沉浸，没有房间，只有天。

灵感来自小红书上一段网页作品「THIN AIR」的录屏。这里所有东西都是程序实时生成的：飞机、伞、云、海、声音，都没有用任何贴图、模型或音频素材。
你的手是透视出来的真手，左手腕上戴着一块高度表。

![预览](docs/preview-contact.jpg)

## 体验流程（约 4 分钟）

1. 开始窗口点「跳」。第一次会弹手部追踪授权：只用来把高度表戴在你的左手腕上。
2. 你站在运输机货舱里，面朝已经放下的尾舱门。
   - 舱里是红色夜灯，发动机在轰鸣，舱门外是高空和云海。
   - 飞机以 70 m/s 平飞，云层在下面往后退。
3. 第 6 秒，舱门两侧的跳伞灯由红变绿，响一声「叮」。
4. 捏一下手指就往外跑，滑出跳板。不捏的话，第 11 秒会自己跳。
5. 出舱后飞机在你身后爬高飞远。你的水平惯性在几秒内消失，然后开始自由落体：速度从 0 加到约 90 m/s；高空空气稀薄，越往下越慢。
6. 下落途中：
   - 左前方有一座浓积云塔，前半段从它旁边经过。
   - 3,200 → 2,400 米穿过一层碎积云，四周一片白。
   - 穿出云底后，前方是环礁。
7. 760 米（2,500 英尺）开伞。
   - 3.5 秒内从约 55 m/s 减到 7.5 m/s，抬头能看到九个气室的翼伞和伞绳。
   - 伞往前飞，中途越过礁缘和白浪，最后在潟湖上空。
8. 接近水面时淡出，开始窗口重新出现。

**手和高度表**：
- 手是透视进来的真手（`upperLimbVisibility(.automatic)`）。系统按 app 写的深度把真手和画面合成：比手远的东西（舱壁、伞绳）被手挡住，比手近的东西盖在手上面。
- 高度表戴在左手腕上：一圈表带，手背那一侧一块圆表盘。表盘离皮肤约 1 厘米，深度在手前面，所以显示在手腕上；表带转到手腕后面的半圈被手挡住，看起来就是戴着的。
- 表盘上数字是高度，外圈的橙色弧按高度 / 30,000 英尺扫过去。
- 没有手部追踪时（不允许，或者在模拟器里），高度表改成前下方的一块面板。
- 不能用 `.visible`：那样真手永远盖在最上面，手腕上的表就看不见了（[WWDC24 10092](https://developer.apple.com/videos/play/wwdc2024/10092/?time=275)）。

**声音**都是实时合成的：
- 风：棕噪声加带通噪声，速度越快越大、越尖。
- 发动机：四台螺旋桨的叶片通过频率略微失谐，出舱后随距离变小。
- 绿灯亮时的提示音。
- 开伞时的扫频呼声和伞衣抖动声。

**为了不晕：**
- 镜头不会自己转，想看哪里就转头。
- 出舱是两秒的加速滑出。
- 开伞减速分摊在 3.5 秒里。
- 开头从黑场淡入，结尾淡出。
- 建议坐着体验。

## 运行

需要 Xcode 27 和 visionOS 27 SDK，没装过 Metal Toolchain 的话先装：`xcodebuild -downloadComponent MetalToolchain`。

```bash
xcodegen generate
open Freefall.xcodeproj
```

装到头显上（头显开机、解锁，和 Mac 在同一个 Wi-Fi 里）：

```bash
tools/install-device.sh            # 编 Release 并安装
tools/install-device.sh --launch   # 装完直接启动
```

### 模拟器里不点按钮跑完整流程（只在 DEBUG 构建或模拟器里生效）

```bash
xcrun simctl launch <设备> com.feiyuchang.freefall -autoEnter YES -mute YES -lookDown 12 -timeScale 2
```

| 参数 | 作用 |
|---|---|
| `-autoEnter YES` | 启动直接跳。落完窗口重新打开后会再跳一次 |
| `-mute YES` | 不出声 |
| `-lookDown <度>` / `-lookUp <度>` / `-turnLeft <度>` | 模拟器里头不会动，用这几个参数让它低头、抬头、左转。只能给正数：UserDefaults 会把 `-30` 当成参数名 |
| `-startAltitude <米>` | 跳过机舱，从这个高度直接开始自由落体 |
| `-timeScale <倍>` | 快进 |

模拟器没有手部追踪，所以高度表在前下方。

## 离屏渲染检查（不开窗口、不出声）

```bash
tools/render-check/run.sh <输出目录> shots   # 机舱、出舱、自由落体、看表、开伞、伞降等 18 个镜头
tools/render-check/run.sh <输出目录> perf    # 按真机分辨率（两只眼各 1888×1792）测 GPU 耗时
tools/render-check/run.sh <输出目录> seq     # 连续下落 + 转头 90 帧，查云层重投影有没有拖影（SEQ=cabin 从机舱开始）
tools/render-check/run.sh <输出目录> film    # 整段跳伞按 90 Hz 跑，存成 30 fps 的预览帧
tools/render-check/run.sh <输出目录> maps    # 天气图、环礁图（叠上伞降路线）、云影图、时间线和大气常量
```

它在 Mac 上用和 Vision Pro 一样的方式（2 层纹理数组 + vertex amplification）跑同一份 `SceneRenderer`、时间线和 shader。
手部追踪和透视只有真机有，这里用合成的关节姿态摆手，画两只肤色的「替身手」代替真手，检查表戴得对不对。

- 环境变量 `EXPOSURE`、`SIGMA`、`STEP`、`CLOUDSCALE` 可以临时改参数。
- `METAL_DEFINES="-DPROFILE_SKIP_MARCH"` 关掉云的步进，`"-DPROFILE_FLAT_SCENE"` 关掉天空和海面着色，用来拆开量各个 pass 的耗时。

## 结构

| 文件 | 内容 |
|---|---|
| `Freefall/Shared/JumpTimeline.swift` | 整个过程的时间线：舱里随飞机走 → 出舱 → 自由落体（重力 + 随高度变的终端速度）→ 开伞 → 伞降 → 淡出 |
| `Freefall/Shared/SceneRenderer.swift` | 所有渲染 pass |
| `Freefall/Shared/ProceduralMeshes.swift` | 程序生成的飞机（货舱内部 + 外壳）和伞衣 |
| `Freefall/Shared/SceneObjects.swift` | 每帧按时间线摆飞机、伞、伞绳、背带、表带和高度表 |
| `Freefall/ImmersiveRenderer.swift` | CompositorServices 渲染循环、头和左手腕的追踪、捏手指、自动画质 |
| `Freefall/WindAudio.swift` | 合成声音 |
| `Freefall/Shaders/` | 大气、云、海、环礁、物体、高度表 |

坐标约定：
- 你（舞台）始终不动、不转，-Z 是你起跳时面朝的方向（机尾的舱门）。
- 飞机和伞跟着舞台坐标走。
- 云、海、环礁按你在「云坐标」里的水平位置平移。

## 渲染

**启动时算一次**
- 云的噪声：形状噪声 128³（Perlin-Worley），细节噪声 32³（Worley）。
- 天气图：64 km 平铺，存覆盖率、云顶、云底、柱状程度。
- 云顶上限图：步进时跳过空段。
- 云影图：海面朝太阳方向穿过云层的光学深度。
- 环礁图。
- 大气：透射率表、多次散射表、海平面的天空表，以及几个常量。
- 飞机和伞衣的网格。

**每帧**
1. 按头部海拔重算天空视图表（192×108）。
2. 新算云样本（四分之一大小）：云层分辨率是渲染分辨率的一半，每帧只重算 2×2 块里的一个像素。起步抖动每帧换。
3. 云层合成：其余三个像素用刚算出的云深度投到上一帧取历史，再夹到周围新样本的范围里，避免拖影。你的下落和水平移动都算在重投影里。
4. 主 pass：
   - 天空和太阳；
   - 海面：噪声高度场的浪，加上 Beckmann 统计粗糙度的太阳倒影；
   - 环礁：浅水按深度吸收红光，沙洲用双三次采样加细节噪声，近看边缘不糊；
   - 合成云层，ACES 色调映射，抖动。
5. 实体：
   - 飞机：舱门附近照得到太阳，越往里越暗、红灯越明显。
   - 伞衣：两面都画，逆光时透光。
   - 伞绳：一像素宽的线。
   - 背带和表带：一段段两端半径不同的胶囊。表带是绕手腕的椭圆环，按 ARKit 的腕关节和手背方向摆。
   - 光照和天空同一套单位，最后同样曝光和色调映射。
   - 深度都按真实距离写：系统靠它把透视的真手合成进来。
6. 高度表：CoreText 生成的字形图集，表盘或面板两种样式。

**参考**
- 大气：Hillaire 2020《A Scalable and Production Ready Sky and Atmosphere Rendering Technique》，写法照 [sebh/UnrealEngineSkyAtmosphere](https://github.com/sebh/UnrealEngineSkyAtmosphere)（MIT）。
- 云：Schneider《GPU Pro 7: Real-Time Volumetric Cloudscapes》（Nubis），噪声照 sebh 的 TileableVolumeNoise；多次散射用 Wrenninge 的八度近似；每步内的解析积分照 Hillaire 2016。
- 渲染循环骨架来自 Bubble Dream（再往上是 [MetalSplatter](https://github.com/scier/MetalSplatter) 的 visionOS 示例，MIT）。

## 性能

M3 Max（30 核 GPU）上两只眼 1888×1792、不开注视点渲染，整帧 1.3~2.8 ms（取 24 次里最快的一次）。最贵的是 9 km 高空低头看积云场。飞机、伞、表带的网格几乎不占时间。

M2 Vision Pro 的 GPU 大约慢 4 倍，估计 5~11 ms，最坏的视角贴着 90 Hz 的预算。所以真机上有自动画质兜底：

- 每帧读 GPU 耗时，平均超过 7 ms 就降一档，很宽裕时再慢慢升回来。
- 一共四档，从（云层比例 0.5，步长 1.0）到（0.36，1.7）。
- 换档和每 2 秒的耗时都会打日志（subsystem `com.feiyuchang.freefall`）。

**还没在真机上跑过。**

## 已知的不足 / 下一步

- 没有落地：伞降到接近水面就淡出。环礁图一格 7.8 米，站在沙滩上看会太粗。
- 真手是房间里的光照，和舱里的红灯、高空的太阳对不上。
- 伞衣不会摆动，也不能拉操纵带转向。
- 环礁是平的（真实的环礁也只高出海面几米），没有高岛和山。
