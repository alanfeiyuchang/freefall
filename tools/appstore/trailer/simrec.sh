#!/bin/bash
# 用法：simrec.sh <关> <起跳海拔米> <低头度> <录多少秒> <输出文件> [额外参数...]
D=5F836736-3541-470A-B575-E0F8EE406EC5
APP=$(cd "$(dirname "$0")/../../.." && pwd)/build/sim/Build/Products/Release-xrsimulator/Freefall.app
scene=$1; alt=$2; look=$3; secs=$4; out=$5; shift 5
xcrun simctl terminate $D com.feiyuchang.freefall 2>/dev/null
xcrun simctl install $D "$APP"
xcrun simctl launch $D com.feiyuchang.freefall -scene $scene -autoEnter YES -autopilot YES -mute YES -startAltitude $alt -lookDown $look -AppleLanguages "(en)" "$@" >/dev/null
sleep 6
xcrun simctl io $D recordVideo --codec=h264 --force "$out" 2>/dev/null &
REC=$!
sleep $secs
kill -INT $REC; wait $REC 2>/dev/null
xcrun simctl terminate $D com.feiyuchang.freefall 2>/dev/null
echo "$out $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")"
