#!/bin/bash
# 编 Release、archive，直接上传到 App Store Connect（用 Xcode 里登录的开发者账号、自动签名）。
# 用法：tools/appstore/upload.sh
# 前提：App Store Connect 里已经建好这个 app 的记录（bundle ID com.feiyuchang.freefall），否则会报
#      "App record with bundle identifier … not found"。每次上传前把 project.yml 的 CURRENT_PROJECT_VERSION 加一。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
xcodegen generate >/dev/null
rm -rf build/Freefall.xcarchive build/export
xcodebuild -project Freefall.xcodeproj -scheme Freefall -configuration Release \
  -destination 'generic/platform=visionOS' -archivePath build/Freefall.xcarchive -allowProvisioningUpdates archive \
  | grep -E "error:|ARCHIVE" || true
APP=build/Freefall.xcarchive/Products/Applications/Freefall.app
# 上架版不能带开发功能（见 docs/appstore/release-vs-master.md）
if plutil -p "$APP/Info.plist" | grep -q NSLocalNetworkUsageDescription || strings "$APP/Freefall" | grep -q -E "NWConnection|PERF "; then
  echo "包里还有性能测试 / 本地网络的东西：这不是 release 分支的版本？不上传。"; exit 1
fi
xcodebuild -exportArchive -archivePath build/Freefall.xcarchive -exportOptionsPlist tools/appstore/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates 2>&1 | grep -v "^\s*$" | grep -i -E "error|upload|succeeded|failed" || true
