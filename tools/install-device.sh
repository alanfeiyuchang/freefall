#!/bin/bash
# 编 Release 装到 Vision Pro 上（头显要开着、解锁、和 Mac 在同一个网络里）。
# 用法：tools/install-device.sh [--launch]
#   --launch  装完直接启动（要戴着头显）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# 名字里有空格（Apple Vision Pro），按列切不可靠，读 JSON
LIST=$(mktemp)
xcrun devicectl list devices --json-output "${LIST}" >/dev/null 2>&1 || true
DEVICE=$(python3 - "${LIST}" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("productType", "").startswith("RealityDevice") and hw.get("reality") == "physical" \
            and conn.get("tunnelState") != "unavailable" and d.get("visibilityClass") != "hidden":
        print(d["identifier"])
        break
PY
)
rm -f "${LIST}"
if [ -z "${DEVICE}" ]; then
  echo "找不到在线的 Vision Pro。确认头显开机、解锁，和这台 Mac 在同一个 Wi-Fi 里（xcrun devicectl list devices）。"
  exit 1
fi

xcodegen generate >/dev/null
xcodebuild -project Freefall.xcodeproj -scheme Freefall -configuration Release \
  -destination 'generic/platform=visionOS' -derivedDataPath build/device -allowProvisioningUpdates build \
  | grep -E "error|BUILD" || true

APP=build/device/Build/Products/Release-xros/Freefall.app
xcrun devicectl device install app --device "${DEVICE}" "${APP}"
if [ "${1:-}" = "--launch" ]; then
  xcrun devicectl device process launch --device "${DEVICE}" com.feiyuchang.freefall
fi
