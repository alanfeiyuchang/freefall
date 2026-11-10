import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// 头盔上的 HUD（钢铁侠那种）：视野左右两侧各一块发光的读数，下沿一行提示，跟着头走（头锁定）。
/// 视野中间 ±24° 完全空着，不挡你看外面；底色是透明的，只有细线、刻度和字，背后垫一圈很淡的暗晕保证在白云前面也看得清。
///
/// 读数用 CoreGraphics 画到贴图上（一秒 15 次，三张贴图轮流用），GPU 上再加发光（取模糊的 mip）、扫描线、
/// 开机时从上往下一行行亮起来的动画（Freefall.metal 的 helmetHudFragment）。
///
/// - 左边：阶段、高度（英尺，大字）、离地高度、下落速度、一条随高度滚动的高度带（3,500 ft 以下橙色、2,000 ft 以下红色）
/// - 右边：航向罗盘（N/E/S/W 跟着你转），靶的方位（橙色菱形）和距离、地速；伞下还有左右操纵环拉了多少；舱里是跳伞灯
/// - 报警时左边一块「PULL」一闪一闪，指向两边大臂上的拉环
final class HelmetHUD: @unchecked Sendable {
    struct State {
        /// 开场实体化完成以后才开机：0…1 开机动画，< 0 不显示
        var boot: Float = -1
        var phase = "STANDBY"
        var altitudeFeet = 0
        var aglMeters = 0
        var fallSpeedKmh = 0
        var alarm = 0
        var headingDeg: Float = 0
        /// 靶相对正前方的方向（度，正 = 偏右）和距离（米）
        var targetBearingDeg: Float?
        var targetDistance: Int?
        var groundSpeedKmh = 0
        var brakes = SIMD2<Float>(0, 0)
        var underCanopy = false
        var inCabin = false
        var greenLight = false
        var hint = ""
        var time: Float = 0
    }

    /// 一块面板：贴图 + 在头上的位置（偏航、俯仰，度）+ 大小（米）
    struct Panel {
        var texture: MTLTexture
        var uniforms: PanelUniforms
    }

    private let device: MTLDevice
    private static let distance: Float = 1.25
    // 贴图尺寸（像素）和在 1.25 米外的大小（米）：一个像素约 0.66 毫米，和头显的像素差不多一比一
    private static let sideSize = (width: 512, height: 600, meters: SIMD2<Float>(0.34, 0.40))
    private static let hintSize = (width: 1200, height: 150, meters: SIMD2<Float>(0.80, 0.10))

    private var leftTextures: [MTLTexture] = [], rightTextures: [MTLTexture] = [], hintTextures: [MTLTexture] = []
    private var slot = 0
    private var lastDraw: Float = -1
    private var lastHint = ""
    private(set) var dirty: [MTLTexture] = []
    private var state = State()

    init(device: MTLDevice) {
        self.device = device
        func make(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
            d.usage = [.shaderRead]
            return device.makeTexture(descriptor: d)!
        }
        for _ in 0..<3 {
            leftTextures.append(make(Self.sideSize.width, Self.sideSize.height))
            rightTextures.append(make(Self.sideSize.width, Self.sideSize.height))
            hintTextures.append(make(Self.hintSize.width, Self.hintSize.height))
        }
    }

    /// 更新读数（一秒最多重画 15 次；提示文字变了马上重画）。返回要画的面板（头锁定，按 headFromStage 摆）。
    func update(_ s: State, head: simd_float4x4) -> [Panel] {
        state = s
        guard s.boot >= 0 else { return [] }
        if s.time - lastDraw >= 1.0 / 15 || s.hint != lastHint || lastDraw < 0 {
            lastDraw = s.time
            lastHint = s.hint
            slot = (slot + 1) % 3
            drawLeft(leftTextures[slot])
            drawRight(rightTextures[slot])
            drawHint(hintTextures[slot])
            dirty = [leftTextures[slot], rightTextures[slot], hintTextures[slot]]
        } else {
            dirty = []
        }
        let boot = min(max(s.boot, 0), 1)
        return [
            Panel(texture: leftTextures[slot], uniforms: place(head, yaw: -31, pitch: -4, size: Self.sideSize.meters, boot: boot)),
            Panel(texture: rightTextures[slot], uniforms: place(head, yaw: 31, pitch: -4, size: Self.sideSize.meters, boot: boot)),
            Panel(texture: hintTextures[slot], uniforms: place(head, yaw: 0, pitch: -27, size: Self.hintSize.meters, boot: boot)),
        ]
    }

    /// 头锁定：面板中心在头前方（偏航、俯仰）1.25 米处，正对着眼睛
    private func place(_ head: simd_float4x4, yaw: Float, pitch: Float, size: SIMD2<Float>, boot: Float) -> PanelUniforms {
        let position = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let right = normalize(SIMD3(head.columns.0.x, head.columns.0.y, head.columns.0.z))
        let up = normalize(SIMD3(head.columns.1.x, head.columns.1.y, head.columns.1.z))
        let forward = -normalize(SIMD3(head.columns.2.x, head.columns.2.y, head.columns.2.z))
        let y = yaw * .pi / 180, p = pitch * .pi / 180
        let d = normalize(forward * (cos(p) * cos(y)) + right * (cos(p) * sin(y)) + up * sin(p))
        let panelRight = normalize(cross(d, up))
        let panelUp = cross(panelRight, d)
        return PanelUniforms(center: SIMD4(position + d * Self.distance, size.x), right: SIMD4(panelRight, size.y),
                             up: SIMD4(panelUp, boot))
    }

    // MARK: - 画

    private static let cyan = CGColor(red: 0.42, green: 0.88, blue: 1.0, alpha: 1)
    private static let cyanDim = CGColor(red: 0.42, green: 0.88, blue: 1.0, alpha: 0.45)
    private static let white = CGColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1)
    private static let amber = CGColor(red: 1.0, green: 0.62, blue: 0.16, alpha: 1)
    private static let red = CGColor(red: 1.0, green: 0.27, blue: 0.2, alpha: 1)
    private static let green = CGColor(red: 0.35, green: 1.0, blue: 0.55, alpha: 1)

    private func font(_ size: CGFloat, mono: Bool = false, bold: Bool = true) -> CTFont {
        if mono { return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!.withTraits(bold) }
        return CTFontCreateWithName((bold ? "AvenirNextCondensed-DemiBold" : "AvenirNextCondensed-Medium") as CFString,
                                    size, nil)
    }

    /// 在左上角为原点（y 向下）的坐标里画字；anchor 0 左对齐、0.5 居中、1 右对齐。返回宽度。
    @discardableResult
    private func text(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor,
                      mono: Bool = false, bold: Bool = true, anchor: CGFloat = 0, tracking: CGFloat = 0,
                      height: Int) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, mono: mono, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if tracking != 0 { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: x - width * anchor, y: CGFloat(height) - y)
        CTLineDraw(line, ctx)
        return width
    }

    private func withContext(_ texture: MTLTexture, _ draw: (CGContext, Int, Int) -> Void) {
        let w = texture.width, h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setLineCap(.round)
            draw(ctx, w, h)
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: w * 4)
        }
    }

    /// y 向下的线段
    private func line(_ ctx: CGContext, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, h: Int,
                      color: CGColor, width: CGFloat = 2) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: CGPoint(x: x0, y: CGFloat(h) - y0))
        ctx.addLine(to: CGPoint(x: x1, y: CGFloat(h) - y1))
        ctx.strokePath()
    }

    private var accent: CGColor {
        switch state.alarm {
        case 2: return Self.red
        case 1: return Self.amber
        default: return Self.cyan
        }
    }

    private var blink: Bool { state.alarm == 0 || sin(state.time * (state.alarm == 2 ? 18 : 7)) > -0.2 }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private func drawLeft(_ texture: MTLTexture) {
        let s = state
        withContext(texture) { ctx, w, h in
            let a = accent
            // 阶段：一个小方块 + 字距拉开的英文
            ctx.setFillColor(a)
            ctx.fill(CGRect(x: 40, y: CGFloat(h) - 52, width: 10, height: 10))
            text(ctx, s.phase, x: 60, y: 52, size: 26, color: a, tracking: 4, height: h)
            line(ctx, 40, 70, 330, 70, h: h, color: Self.cyanDim, width: 1.5)
            line(ctx, 40, 70, 90, 70, h: h, color: a, width: 3)
            // 高度
            text(ctx, "ALT", x: 40, y: 104, size: 22, color: Self.cyanDim, tracking: 3, height: h)
            let alt = Self.grouped(s.altitudeFeet)
            let wNum = text(ctx, alt, x: 40, y: 190, size: 80, color: s.alarm > 0 && !blink ? a : Self.white, mono: true,
                            height: h)
            text(ctx, "FT", x: 48 + wNum, y: 186, size: 26, color: Self.cyan, tracking: 2, height: h)
            // 离地高度、下落速度
            text(ctx, "AGL", x: 40, y: 240, size: 22, color: Self.cyanDim, tracking: 3, height: h)
            text(ctx, Self.grouped(s.aglMeters) + " M", x: 100, y: 242, size: 30, color: Self.white, mono: true, height: h)
            text(ctx, "V/S", x: 40, y: 290, size: 22, color: Self.cyanDim, tracking: 3, height: h)
            text(ctx, "▼ \(s.fallSpeedKmh) KM/H", x: 100, y: 292, size: 30, color: Self.white, mono: true, height: h)
            // 下落速度条（0…300 km/h）
            let speedFrac = CGFloat(min(Float(s.fallSpeedKmh) / 300, 1))
            line(ctx, 40, 310, 330, 310, h: h, color: Self.cyanDim, width: 1)
            line(ctx, 40, 310, 40 + 290 * speedFrac, 310, h: h, color: Self.cyan, width: 4)

            // 滚动的高度带：当前高度在中间（y = 320），上下各 4,000 ft，每 500 ft 一格
            let tapeX: CGFloat = 400, top: CGFloat = 90, bottom: CGFloat = 550
            let mid = (top + bottom) / 2
            let feetPerPixel: CGFloat = 8000 / (bottom - top)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: tapeX - 30, y: CGFloat(h) - bottom, width: 120, height: bottom - top))
            let current = CGFloat(s.altitudeFeet)
            var mark = (Int(current) - 4000) / 500 * 500
            while CGFloat(mark) <= current + 4000 {
                if mark >= 0 {
                    let y = mid - (CGFloat(mark) - current) / feetPerPixel
                    let major = mark % 1000 == 0
                    let color: CGColor = mark <= 2000 ? Self.red : (mark <= 3500 ? Self.amber : Self.cyan)
                    line(ctx, tapeX, y, tapeX + (major ? 26 : 14), y, h: h, color: color, width: major ? 2.5 : 1.5)
                    if mark % 2000 == 0 {
                        text(ctx, "\(mark / 1000)K", x: tapeX + 34, y: y + 8, size: 20, color: Self.cyanDim, mono: true,
                             height: h)
                    }
                }
                mark += 500
            }
            // 开伞高度、决断高度的色带
            for (feet, color) in [(CGFloat(3500), Self.amber), (CGFloat(2000), Self.red)] {
                let y = mid - (feet - current) / feetPerPixel
                ctx.setFillColor(color.copy(alpha: 0.3) ?? color)
                ctx.fill(CGRect(x: tapeX - 6, y: CGFloat(h) - min(y + 400, bottom), width: 5,
                                height: max(min(y + 400, bottom) - max(y, top), 0)))
            }
            ctx.restoreGState()
            line(ctx, tapeX - 8, top, tapeX - 8, bottom, h: h, color: Self.cyanDim, width: 1.5)
            // 指针：一个朝右的三角
            ctx.setFillColor(a)
            ctx.move(to: CGPoint(x: tapeX - 30, y: CGFloat(h) - mid - 9))
            ctx.addLine(to: CGPoint(x: tapeX - 12, y: CGFloat(h) - mid))
            ctx.addLine(to: CGPoint(x: tapeX - 30, y: CGFloat(h) - mid + 9))
            ctx.fillPath()

            // 报警：PULL 一闪一闪，两个箭头指向两边大臂上的拉环
            if s.alarm > 0, s.phase == "FREEFALL" {
                if blink {
                    ctx.setStrokeColor(a)
                    ctx.setLineWidth(3)
                    ctx.stroke(CGRect(x: 40, y: CGFloat(h) - 470, width: 290, height: 110))
                    text(ctx, "PULL", x: 185, y: 448, size: 64, color: a, anchor: 0.5, tracking: 10, height: h)
                }
                text(ctx, "◀ 大臂上的拉环 ▶", x: 185, y: 512, size: 26, color: a, bold: false, anchor: 0.5, height: h)
            } else {
                text(ctx, "DEPLOY 3,500 FT", x: 40, y: 400, size: 22, color: Self.cyanDim, tracking: 2, height: h)
                line(ctx, 40, 414, 330, 414, h: h, color: Self.cyanDim, width: 1)
                if s.phase == "FREEFALL", s.altitudeFeet > 3500, s.fallSpeedKmh > 10 {
                    let seconds = Float(s.altitudeFeet - 3500) / 3.281 / (Float(s.fallSpeedKmh) / 3.6)
                    text(ctx, String(format: "T-%02d S", Int(seconds)), x: 40, y: 460, size: 34, color: Self.white,
                         mono: true, height: h)
                }
            }
        }
    }

    private func drawRight(_ texture: MTLTexture) {
        let s = state
        withContext(texture) { ctx, w, h in
            let a = accent
            text(ctx, "NAV", x: 470, y: 52, size: 26, color: a, anchor: 1, tracking: 4, height: h)
            ctx.setFillColor(a)
            ctx.fill(CGRect(x: 476, y: CGFloat(h) - 52, width: 10, height: 10))
            line(ctx, 180, 70, 472, 70, h: h, color: Self.cyanDim, width: 1.5)
            line(ctx, 422, 70, 472, 70, h: h, color: a, width: 3)
            let heading = (Int(s.headingDeg.rounded()) % 360 + 360) % 360
            text(ctx, String(format: "HDG %03d°", heading), x: 470, y: 108, size: 28, color: Self.white, mono: true,
                 anchor: 1, height: h)

            // 罗盘：刻度、N E S W 跟着航向转，顶上一个固定的指示
            let cx: CGFloat = 300, cy: CGFloat = 300, r: CGFloat = 150
            let cgCy = CGFloat(h) - cy
            ctx.setStrokeColor(Self.cyanDim)
            ctx.setLineWidth(1.5)
            ctx.addArc(center: CGPoint(x: cx, y: cgCy), radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()
            for deg in stride(from: 0, to: 360, by: 10) {
                let rel = (CGFloat(deg) - CGFloat(s.headingDeg)) * .pi / 180
                let major = deg % 30 == 0
                let r0 = r - (major ? 16 : 8)
                let x0 = cx + sin(rel) * r0, y0 = cy - cos(rel) * r0
                let x1 = cx + sin(rel) * r, y1 = cy - cos(rel) * r
                line(ctx, x0, y0, x1, y1, h: h, color: major ? Self.cyan : Self.cyanDim, width: major ? 2.5 : 1.5)
                if deg % 90 == 0 {
                    let label = ["N", "E", "S", "W"][deg / 90]
                    text(ctx, label, x: cx + sin(rel) * (r - 36), y: cy - cos(rel) * (r - 36) + 10, size: 26,
                         color: deg == 0 ? a : Self.white, anchor: 0.5, height: h)
                }
            }
            ctx.setFillColor(Self.white)
            ctx.move(to: CGPoint(x: cx - 9, y: cgCy + r + 18))
            ctx.addLine(to: CGPoint(x: cx + 9, y: cgCy + r + 18))
            ctx.addLine(to: CGPoint(x: cx, y: cgCy + r + 4))
            ctx.fillPath()
            // 靶：圈外一个橙色菱形 + 一条虚线指过去；圈里是距离
            if let bearing = s.targetBearingDeg, let distance = s.targetDistance {
                let rel = CGFloat(bearing) * .pi / 180
                let tx = cx + sin(rel) * (r + 16), ty = cy - cos(rel) * (r + 16)
                ctx.setFillColor(Self.amber)
                ctx.move(to: CGPoint(x: tx, y: CGFloat(h) - ty + 12))
                ctx.addLine(to: CGPoint(x: tx + 9, y: CGFloat(h) - ty))
                ctx.addLine(to: CGPoint(x: tx, y: CGFloat(h) - ty - 12))
                ctx.addLine(to: CGPoint(x: tx - 9, y: CGFloat(h) - ty))
                ctx.fillPath()
                ctx.setLineDash(phase: 0, lengths: [6, 7])
                line(ctx, cx + sin(rel) * 40, cy - cos(rel) * 40, cx + sin(rel) * (r - 22), cy - cos(rel) * (r - 22),
                     h: h, color: Self.amber.copy(alpha: 0.7) ?? Self.amber, width: 2)
                ctx.setLineDash(phase: 0, lengths: [])
                text(ctx, "TGT", x: cx, y: cy - 10, size: 22, color: Self.amber, anchor: 0.5, tracking: 3, height: h)
                text(ctx, distance >= 1000 ? String(format: "%.1f KM", Float(distance) / 1000) : "\(distance) M",
                     x: cx, y: cy + 28, size: 32, color: Self.white, mono: true, anchor: 0.5, height: h)
            }

            // 下面：地速；伞下有左右操纵环拉了多少；舱里是跳伞灯
            text(ctx, "GS", x: 180, y: 506, size: 22, color: Self.cyanDim, tracking: 3, height: h)
            text(ctx, "\(s.groundSpeedKmh) KM/H", x: 470, y: 508, size: 30, color: Self.white, mono: true, anchor: 1,
                 height: h)
            line(ctx, 180, 522, 472, 522, h: h, color: Self.cyanDim, width: 1)
            if s.underCanopy {
                for (i, label) in ["L", "R"].enumerated() {
                    let x: CGFloat = 250 + CGFloat(i) * 130
                    let frac = CGFloat(i == 0 ? s.brakes.x : s.brakes.y)
                    ctx.setStrokeColor(Self.cyanDim)
                    ctx.setLineWidth(1.5)
                    ctx.stroke(CGRect(x: x, y: CGFloat(h) - 584, width: 90, height: 16))
                    ctx.setFillColor(Self.cyan)
                    ctx.fill(CGRect(x: x + 2, y: CGFloat(h) - 582, width: 86 * frac, height: 12))
                    text(ctx, label, x: x - 12, y: 582, size: 22, color: Self.cyan, anchor: 1, height: h)
                }
            } else if s.inCabin {
                ctx.setFillColor(s.greenLight ? Self.green : Self.red)
                ctx.fillEllipse(in: CGRect(x: 182, y: CGFloat(h) - 580, width: 18, height: 18))
                text(ctx, s.greenLight ? "JUMP  GO" : "JUMP  HOLD", x: 212, y: 578, size: 26,
                     color: s.greenLight ? Self.green : Self.red, tracking: 3, height: h)
            }
        }
    }

    private func drawHint(_ texture: MTLTexture) {
        let s = state
        withContext(texture) { ctx, w, h in
            let lines = s.hint.split(separator: "\n").map(String.init)
            guard !lines.isEmpty else { return }
            // 两端一对括号，中间一行字（两行时上下排）
            let size: CGFloat = lines.count > 1 ? 40 : 46
            let font = CTFontCreateUIFontForLanguage(.system, size, "zh-Hans" as CFString)!
            var widths: [CGFloat] = []
            for (i, l) in lines.prefix(2).enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): i == 0 ? Self.white : Self.cyan,
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: attributes))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                widths.append(width)
                let y = lines.count > 1 ? (i == 0 ? 66 : 122) : 92
                ctx.textPosition = CGPoint(x: (CGFloat(w) - width) / 2, y: CGFloat(h) - CGFloat(y))
                CTLineDraw(line, ctx)
            }
            let half = (widths.max() ?? 0) / 2 + 40
            let c = CGFloat(w) / 2
            for sign: CGFloat in [-1, 1] {
                let x = c + sign * half
                line(ctx, x, 24, x, CGFloat(h) - 24, h: h, color: accent, width: 3)
                line(ctx, x, 24, x - sign * 18, 24, h: h, color: accent, width: 3)
                line(ctx, x, CGFloat(h) - 24, x - sign * 18, CGFloat(h) - 24, h: h, color: accent, width: 3)
            }
        }
    }
}

private extension CTFont {
    func withTraits(_ bold: Bool) -> CTFont {
        guard bold else { return self }
        return CTFontCreateCopyWithSymbolicTraits(self, 0, nil, .traitBold, .traitBold) ?? self
    }
}
