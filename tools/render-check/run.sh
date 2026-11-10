#!/bin/bash
# 编译 shader 和渲染器，在 Mac 上离屏出图 / 量性能。不开窗口、不出声。
# 用法：tools/render-check/run.sh [输出目录] [shots|perf|maps|all] [镜头名过滤]
# 环境变量可临时改参数：EXPOSURE、SIGMA（云消光）、STEP（云步长倍数）、CLOUDSCALE（云层分辨率比例）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-/tmp/freefall-render}
WORK=$(mktemp -d)
# METAL_DEFINES 可以传 -DPROFILE_SKIP_MARCH（云不步进）/ -DPROFILE_FLAT_SCENE（主 pass 不算天空海面），拆开量各 pass
xcrun -sdk macosx metal ${METAL_DEFINES:-} -c "$ROOT/Freefall/Shaders/Freefall.metal" -I "$ROOT/Freefall/Shaders" -o "$WORK/Freefall.air"
xcrun -sdk macosx metallib "$WORK/Freefall.air" -o "$WORK/Freefall.metallib"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15 \
  "$ROOT/tools/render-check/main.swift" \
  "$ROOT/Freefall/Shared/"*.swift \
  -o "$WORK/render-check"
GLOVES_DIR="$ROOT/Freefall/Resources/Gloves" "$WORK/render-check" "$WORK/Freefall.metallib" "$OUT" "${@:2}"
rm -rf "$WORK"
