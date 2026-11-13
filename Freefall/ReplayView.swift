import SwiftUI

/// 上一跳的航线（开始窗口里「上一跳」那一行旁边的「航线」）：从上往下看，左边是开伞以后的全程，右边放大靶附近；
/// 下面说开伞时多高、离靶多远，落点顺着最后几秒的飞行方向看是长了还是短了、偏左还是偏右多少米。
/// 3 米的靶心靠的是最后二三十秒的修正：没有这张图，没打中只知道「差 9 米」，不知道下一跳该早点刹车还是该往哪边偏。
/// 航线是 JumpSession 每半秒记的地面位置（JumpResult.track）。地面坐标 -z 朝前（开伞时面朝的方向），图上朝上。
struct ReplayView: View {
    let result: JumpResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(result.summary)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                HStack(alignment: .top, spacing: 22) {
                    panel("全程") { TrackMap(result: result, zoom: false) }
                    panel("靠近靶的最后一段") { TrackMap(result: result, zoom: true) }
                }
                VStack(spacing: 6) {
                    ForEach(statLines, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        legend(color: .white.opacity(0.75), text: String(localized: "全程"))
                        legend(color: .orange, text: String(localized: "最后 20 秒"))
                        legend(color: Color(red: 0.35, green: 0.75, blue: 1), text: String(localized: "开伞"))
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .navigationTitle("航线")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 640)
    }

    private func panel<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            content()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 18, height: 4)
            Text(verbatim: text)
        }
    }

    /// 开伞时多高、离靶多远；落点顺着最后的飞行方向看偏了多少
    private var statLines: [String] {
        var lines: [String] = []
        if let feet = result.deployFeet, let d = result.deployPoint {
            let toTarget = Int(simd_length(result.target - d).rounded())
            lines.append(String(localized: "开伞时离地 \(feet) 英尺，离靶 \(toTarget) 米"))
        } else {
            lines.append(String(localized: "没开伞"))
        }
        if let kind = result.windKind {
            let kmh = Int((simd_length(result.wind) * 3.6).rounded())
            lines.append(String(localized: "风 \(kmh) km/h，\(kind)"))
        } else {
            lines.append(String(localized: "几乎没风"))
        }
        if let o = result.landingOffset {
            var parts: [String] = []
            let long = Int(o.long.rounded()), right = Int(o.right.rounded())
            if long > 0 { parts.append(String(localized: "落长 \(long) 米")) }
            if long < 0 { parts.append(String(localized: "落短 \(-long) 米")) }
            if right > 0 { parts.append(String(localized: "偏右 \(right) 米")) }
            if right < 0 { parts.append(String(localized: "偏左 \(-right) 米")) }
            let text = parts.isEmpty ? String(localized: "正中") : parts.joined(separator: " · ")
            lines.append(String(localized: "落点（顺着最后几秒飞的方向看）：\(text)"))
        }
        return lines
    }
}

/// 一张俯视图。zoom = false：整条航线（开伞点到落点，加上靶）；true：以靶为中心 ±60 米，看最后怎么进的靶
struct TrackMap: View {
    let result: JumpResult
    let zoom: Bool

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.08, green: 0.13, blue: 0.12)))
            let track = result.track
            let target = result.target
            // 视野：地面坐标的中心和半宽（米）
            var center = target, half: Float = 60
            if !zoom {
                var lo = target, hi = target
                for p in track { lo = simd_min(lo, p); hi = simd_max(hi, p) }
                if let d = result.deployPoint { lo = simd_min(lo, d); hi = simd_max(hi, d) }
                center = (lo + hi) / 2
                half = max(max(hi.x - lo.x, hi.y - lo.y) / 2 * 1.15, 80)
            }
            let scale = Float(min(size.width, size.height)) / (2 * half)
            func screen(_ p: SIMD2<Float>) -> CGPoint {
                // x 朝右；地面 -z 朝前，画在上面
                CGPoint(x: CGFloat((p.x - center.x) * scale) + size.width / 2,
                        y: CGFloat((p.y - center.y) * scale) + size.height / 2)
            }
            // 网格：全程 100 米一格，放大的 10 米一格
            let step: Float = zoom ? 10 : 100
            var grid = Path()
            var g = ((center.x - half) / step).rounded(.down) * step
            while g <= center.x + half {
                grid.move(to: screen(SIMD2(g, center.y - half))); grid.addLine(to: screen(SIMD2(g, center.y + half))); g += step
            }
            g = ((center.y - half) / step).rounded(.down) * step
            while g <= center.y + half {
                grid.move(to: screen(SIMD2(center.x - half, g))); grid.addLine(to: screen(SIMD2(center.x + half, g))); g += step
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 1)

            // 靶：20 米的红白圈、3 米的黄色靶心（全程图里太小，起码画几个像素看得见）
            let c = screen(target)
            func circle(_ r: Float, min px: CGFloat) -> Path {
                let rr = max(CGFloat(r * scale), px)
                return Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            }
            ctx.fill(circle(Float(JumpTimeline.targetRadius), min: 5), with: .color(Color(red: 0.85, green: 0.2, blue: 0.18).opacity(0.75)))
            ctx.stroke(circle(Float(JumpTimeline.targetRadius), min: 5), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            ctx.fill(circle(Float(JumpTimeline.bullseyeRadius), min: 2), with: .color(.yellow))

            // 航线：全程淡白，最后 20 秒（40 个点）橙色
            if track.count >= 2 {
                var all = Path()
                all.move(to: screen(track[0]))
                for p in track.dropFirst() { all.addLine(to: screen(p)) }
                ctx.stroke(all, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                let tail = Array(track.suffix(40))
                var last = Path()
                last.move(to: screen(tail[0]))
                for p in tail.dropFirst() { last.addLine(to: screen(p)) }
                ctx.stroke(last, with: .color(.orange), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                // 落点：一个叉
                let e = screen(track[track.count - 1])
                var x = Path()
                x.move(to: CGPoint(x: e.x - 7, y: e.y - 7)); x.addLine(to: CGPoint(x: e.x + 7, y: e.y + 7))
                x.move(to: CGPoint(x: e.x + 7, y: e.y - 7)); x.addLine(to: CGPoint(x: e.x - 7, y: e.y + 7))
                ctx.stroke(x, with: .color(.white), lineWidth: 3)
            }
            // 开伞点
            if let d = result.deployPoint {
                let p = screen(d)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                         with: .color(Color(red: 0.35, green: 0.75, blue: 1)))
            }
            // 风：右上角一个箭头，指向空气走的方向（全程图才画）
            if !zoom, simd_length(result.wind) >= 0.5 {
                let dir = simd_normalize(result.wind)
                let o = CGPoint(x: size.width - 30, y: 30)
                let tip = CGPoint(x: o.x + CGFloat(dir.x) * 16, y: o.y + CGFloat(dir.y) * 16)
                let tail = CGPoint(x: o.x - CGFloat(dir.x) * 16, y: o.y - CGFloat(dir.y) * 16)
                let side = CGPoint(x: CGFloat(-dir.y) * 6, y: CGFloat(dir.x) * 6)
                let back = CGPoint(x: tip.x - CGFloat(dir.x) * 9, y: tip.y - CGFloat(dir.y) * 9)
                var arrow = Path()
                arrow.move(to: tail); arrow.addLine(to: tip)
                arrow.move(to: CGPoint(x: back.x + side.x, y: back.y + side.y)); arrow.addLine(to: tip)
                arrow.addLine(to: CGPoint(x: back.x - side.x, y: back.y - side.y))
                ctx.stroke(arrow, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ctx.draw(Text(verbatim: "WIND").font(.caption2).foregroundStyle(.white.opacity(0.7)),
                         at: CGPoint(x: o.x, y: o.y + 26))
            }
            // 比例尺
            let barMeters: Float = zoom ? 10 : 100
            let bar = CGFloat(barMeters * scale)
            var scaleBar = Path()
            scaleBar.move(to: CGPoint(x: 16, y: size.height - 18)); scaleBar.addLine(to: CGPoint(x: 16 + bar, y: size.height - 18))
            ctx.stroke(scaleBar, with: .color(.white.opacity(0.8)), lineWidth: 2)
            ctx.draw(Text(verbatim: "\(Int(barMeters)) m").font(.caption2).foregroundStyle(.white.opacity(0.8)),
                     at: CGPoint(x: 16 + bar / 2, y: size.height - 30))
        }
    }
}
