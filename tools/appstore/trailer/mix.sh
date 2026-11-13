#!/bin/bash
# 混剪第二版：快开场 + 实录 + 五关快闪 + 落靶，配音乐，片尾标题。≤ 30 秒
# 用法：mix2.sh <音乐文件> <音乐起点秒> <输出名>
set -e
V="$HOME/Movies/Freefall/ScreenRecording_11-11-2026 11.mov"
T=$(cd "$(dirname "$0")/../../.." && pwd)/build/trailer-sim
OUT=$(cd "$(dirname "$0")/../../.." && pwd)/build/trailer-mix
TITLE=$OUT/title.png
MUSIC=$1; MS=$2; NAME=$3
W=3840; H=2160
# 段：dev:起:止:倍速（devd = 同时用插值抹掉开场的提示条）  或  sim:文件:起:秒数:倍速
SEGS="devd:5.7:7.2:1 dev:7.2:9.3:1.5 dev:9.3:10.6:1 dev:18.5:23.0:1 dev:90.8:93.8:1 sim:s0_atoll_canopy:14:2.4:2 sim:s1_grassland_canopy:30:2.4:2 sim:s2_alpine_canopy:32:2.4:2 sim:s5_volcano_down60:28:2.4:2 sim:s6_sky_canopy:22:2.4:2 dev:203.0:210.5:1 dev:211.5:214.5:1"
inputs=(-i "$V"); fc=""; vc=""; ac=""; n=0; k=1; total=0; windpos=150
for s in $SEGS; do IFS=: read typ a b c d <<< "$s"
  if [ $typ = dev ] || [ $typ = devd ]; then st=$a; en=$b; sp=$c; len=$(python3 -c "print(round(($en-$st)/$sp,3))")
    dl=""; [ $typ = devd ] && dl="delogo=x=732:y=754:w=582:h=102:enable='lt(t,6.45)',"
    fc="${fc}[0:v]trim=$st:$en,${dl}setpts=(PTS-STARTPTS)/$sp,fps=30,scale=$W:$H:flags=lanczos,setsar=1[v$n];[0:a]atrim=$st:$en,asetpts=PTS-STARTPTS,atempo=$sp,aresample=48000,afade=t=in:d=0.06,afade=t=out:st=$(python3 -c "print(round($len-0.08,3))"):d=0.08[a$n];"
  else f=$a; st=$b; du=$c; sp=$d; len=$(python3 -c "print(round($du/$sp,3))"); inputs+=(-ss $st -t $du -i "$T/$f.mov")
    fc="${fc}[$k:v]setpts=(PTS-STARTPTS)/$sp,fps=30,scale=$W:$H:flags=lanczos,setsar=1[v$n];[0:a]atrim=$windpos:$(python3 -c "print($windpos+$len)"),asetpts=PTS-STARTPTS,aresample=48000,afade=t=in:d=0.06,afade=t=out:st=$(python3 -c "print(round($len-0.08,3))"):d=0.08[a$n];"
    k=$((k+1)); windpos=$(python3 -c "print($windpos+$len)"); fi
  vc="${vc}[v$n]"; ac="${ac}[a$n]"; n=$((n+1)); total=$(python3 -c "print(round($total+$len,3))"); done
ti=$(python3 -c "print(round($total-3.4,2))"); fo=$(python3 -c "print(round($total-0.7,2))")
inputs+=(-ss $MS -i "$MUSIC" -loop 1 -i "$TITLE")
mi=$k; ti_in=$((k+1))
fc="${fc}${vc}concat=n=$n:v=1:a=0,fade=t=in:d=0.3[cv];${ac}concat=n=$n:v=0:a=1,volume=0.35[ga];"
fc="${fc}[$ti_in:v]format=rgba,fade=t=in:st=$ti:d=0.6:alpha=1,trim=0:$total,setpts=PTS-STARTPTS[tt];[cv][tt]overlay=0:0:shortest=1,fade=t=out:st=$fo:d=0.7,format=yuv420p[vv];"
fc="${fc}[$mi:a]atrim=0:$total,asetpts=PTS-STARTPTS,aresample=48000,afade=t=in:d=0.3,volume=0.85[mm];[ga][mm]amix=inputs=2:duration=first:normalize=0,afade=t=out:st=$(python3 -c "print(round($total-1.2,2))"):d=1.2[aa]"
ffmpeg -v error -y "${inputs[@]}" -filter_complex "$fc" -map "[vv]" -map "[aa]" -t $total -c:v libx264 -profile:v high -level:v 5.1 -preset slow -b:v 11M -maxrate 12M -bufsize 24M -r 30 -c:a aac -b:a 256k -ar 48000 -ac 2 -movflags +faststart "$OUT/$NAME-app-preview-4k.mp4"
ffmpeg -v error -y -i "$OUT/$NAME-app-preview-4k.mp4" -vf scale=1920:1080 -c:v libx264 -preset medium -crf 21 -c:a aac -b:a 192k -movflags +faststart "$OUT/$NAME-1080p.mp4"
echo "$NAME total=$total $(ffprobe -v error -show_entries format=duration,bit_rate -of csv=p=0 "$OUT/$NAME-app-preview-4k.mp4") 1080p=$(du -h "$OUT/$NAME-1080p.mp4" | cut -f1)"
