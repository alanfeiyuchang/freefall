# 预告片 / App Store 预览视频

2026-11-13 做的 26 秒混剪（定稿：`build/trailer-mix/FINAL-freefall-trailer-app-preview-4k.mp4`，不进仓库）。

## 素材

- **头显实录**：`~/Movies/Freefall/ScreenRecording_11-11-2026 11.mov`（11-11 在 Vision Pro 上录的环礁一整跳，1920×1080 30 fps，带声音）。
  只用没有 HUD 面板和提示条的片段；手表上的高度数字、房间里的字不算。
- **模拟器风景**：`simrec.sh` 在 visionOS 模拟器里开自动驾驶录（3840×2160，没有声音），存到 `build/trailer-sim/`。
  要先编模拟器版（`build/sim/`），启动参数 `-cleanView YES` 关掉 HUD、提示条和高度表（只在模拟器 / 调试版生效）。
  模拟器的 UDID 写死在脚本里，换模拟器要改。
  用到的几段：`s0_atoll_canopy`、`s1_grassland_canopy`、`s2_alpine_canopy`、`s5_volcano_down60`（自由落体时低头 60° 看火山口和烟柱）、`s6_sky_canopy`。
- **片尾标题**：`title.swift` 生成 3840×2160 的透明 PNG（「FREEFALL / A skydive for Apple Vision Pro」），放到 `build/trailer-mix/title.png`。

## 剪辑（`mix.sh <音乐> <音乐起点秒> <输出名>`）

1. 开场 2 秒：实录 6.4–10.0 秒，1.8 倍速（握住扶杆，房间变成机舱）
2. 自由落体 4.5 秒、拉伞开伞 3 秒（实录）
3. 五关快闪，每关 1.2 秒（模拟器，2 倍速）
4. 落进靶心 7.5 秒、伞衣塌下来 3 秒，最后 3.4 秒叠标题（实录）

游戏原声压到 35% 垫在音乐下面。输出两份：App Store 预览视频规格的 4K（3840×2160、30 fps、H.264 约 11.6 Mbps、AAC 256 kbps 48 kHz）和 1080p。
App Store 要求 15–30 秒，现在 26 秒。

## 音乐（都不进仓库，在 `build/trailer-mix/music/`）

| 用了 | 曲子 | 作者 | 许可 | 来源 |
|---|---|---|---|---|
| ✅ 定稿 | High-Energy Adventure Theme（`fulltheme.ogg`，从 50 秒起） | SRG774 | CC0 | <https://opengameart.org/comment/112784> |
| 试过，太欢快 | Joyfully（loop 版） | MintoDog | CC0 | <https://opengameart.org/content/joyfully> |
| 试过，太欢快 | Rhythm Factory | Zane Little Music | CC0 | <https://opengameart.org/content/rhythm-factory> |
| 试过，太慢 | Epic Endgame Cinematic | cynicmusic | CC0 | Wandless 里的 `music_credits.m4a` |

CC0 不要求署名。
