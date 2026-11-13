#!/bin/bash
# 离屏渲染 App Store 截图的候选图：3840×2160（visionOS 截图的尺寸），只出左眼。
# 用法：tools/appstore/render_shots.sh [输出目录，默认 build/appstore-shots]
# 文字跟着 UILANG（默认英文；UILANG=zh-Hans 出中文提示，要先编过一次 app，见 tools/render-check/run.sh）。
# 这些是构图和挑镜头用的候选：手是合成的姿势，混合沉浸开场的「房间」离屏画不出来。正式截图用真机录（docs/appstore/screenshots.md）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/build/appstore-shots}
export UILANG=${UILANG:-en}
shot() {  # 关的编号 镜头名
  SHOTW=3840 SHOTH=2160 SCENE=$1 "$ROOT/tools/render-check/run.sh" "$OUT/scene$1" shots "$2" 2>&1 | grep -v -i warning | tail -1
}
shot 0 v7_ready            # 舱门口，绿灯
shot 0 f1_exit_down45      # 刚出舱，往下看环礁
shot 0 f5_handle           # 报警，抓拉环
shot 0 k1_canopy_toggles   # 伞衣在头顶，抓着操纵环，HUD
shot 0 k5_target_near      # 环礁，快落进靶
shot 2 t6_canopy_target    # 高山 U 形谷
shot 6 t6_canopy_target    # 天空之城
# 草原、雪山、海岛：k* 那几个镜头只在环礁出图；火山的 t6 / card 机位看不清烟柱。这几关正式截图用真机拍，
# 或者合并 master 以后再挑别的镜头（tools/render-check/main.swift 的 shots 列表）。
