import CoreGraphics
import CoreText
import Foundation
@preconcurrency import Metal
import simd

/// 头盔上的 HUD（钢铁侠那种）：视野左右两侧各一块发光的读数，下沿一行提示，跟着头走（头锁定）。
/// 两块读数在左右 17° 处（第一版放在 31°，太靠外，眼睛转过去还在镜片糊的地方），视野中间 ±10° 空着不挡；
/// 每块背后垫一层很淡的暗底，在白云前面也看得清。默认关着，点一下手腕上的表开 / 关；下沿的提示开场就有。
///
/// 读数用 CoreGraphics 按两倍分辨率画到贴图上（一秒 15 次，三张贴图轮流用；在后台线程画，一次 4~5 毫秒，
/// 放在渲染线程上会让那一帧超时），GPU 上按 mip 采样（不闪），
/// 加一点发光、开机时从上往下扫出来的动画（Freefall.metal 的 helmetHudFragment）。
///
/// - 左边：阶段、高度（英尺，大字）、离地高度、下落速度、一条随高度滚动的高度带（3,500 ft 以下橙色、2,000 ft 以下红色）
/// - 右边：航向罗盘（N/E/S/W 跟着你转），靶的方位（橙色菱形）和距离、地速；伞下还有左右操纵环拉了多少；舱里是跳伞灯
/// - 报警时左边一块「PULL」一闪一闪，写着拉环在哪只小臂上
final class HelmetHUD: @unchecked Sendable {
    struct State {
        /// 两侧的读数：0…1 开机动画，< 0 不显示（HUD 关着，或者开场还没长完）
        var boot: Float = -1
        /// 下沿的提示：0…1 开场的淡入，< 0 不显示
        var hintBoot: Float = -1
        var phase = "STANDBY"
        var altitudeFeet = 0
        var aglMeters = 0
        var fallSpeedKmh = 0
        var alarm = 0
        var headingDeg: Float = 0
        /// 靶相对正前方的方向（度，正 = 偏右）和距离（米）
        var targetBearingDeg: Float?
        /// 风从哪个方向来（相对飞行方向，度，正 = 右边）和多大（km/h）；没风是 nil
        var windFromDeg: Float?
        var windKmh = 0
        var targetDistance: Int?
        var groundSpeedKmh = 0
        var brakes = SIMD2<Float>(0, 0)
        /// 往前推（俯冲）了多少，0…1
        var dive: Float = 0
        var underCanopy = false
        var inCabin = false
        var greenLight = false
        var hint = ""
        /// 自由落体路上穿过了几个光环 / 一共几个（0 = 这一跳没有光环）
        var ringsPassed = 0
        var ringsTotal = 0
        /// 实时帧率（每秒实际提交了几帧）、GPU 一帧的耗时（毫秒）、自动画质的档位；fps < 0 不显示
        var fps = -1
        var gpuMs: Float = 0
        var qualityLevel = 0
        var time: Float = 0
    }

    /// 一块面板：贴图 + 在头上的位置（偏航、俯仰，度）+ 大小（米）
    struct Panel {
        var texture: MTLTexture
        var uniforms: PanelUniforms
    }

    private let device: MTLDevice
    private static let distance: Float = 1.2
    /// 画图用的坐标（逻辑像素）和在 1.2 米外的大小（米）；贴图按 scale 倍画，比头显的像素密一些，按 mip 采样
    private static let sideSize = (width: 512, height: 600, meters: SIMD2<Float>(0.27, 0.316))
    private static let hintSize = (width: 1200, height: 150, meters: SIMD2<Float>(0.76, 0.095))
    private static let scale = 2
    /// 两块读数的位置（度）：左右偏多少、往下多少；提示在正前方往下多少
    /// 两侧的读数开着时，提示往下让 2.5°：提示条比两块读数之间的空当宽，不让的话它的两头被读数的下沿挡住
    private static let sideYaw: Float = 17, sidePitch: Float = -6, hintPitch: Float = -15, hintPitchWithSides: Float = -17.5
    /// 开场握扶杆的提示（右边画一串往右跳的箭头，指向扶杆）
    static func barPrompt(left: Bool) -> String {
        left ? String(localized: "握住左边扶杆") : String(localized: "握住右边扶杆")
    }

    private var leftTextures: [MTLTexture] = [], rightTextures: [MTLTexture] = [], hintTextures: [MTLTexture] = []
    /// 现在显示的是哪一组贴图
    private var slot = 0
    private var lastDraw: Float = -1
    private var lastHint = ""
    private var lastSides = false
    private(set) var dirty: [MTLTexture] = []
    /// 后台画图：一次只画一组；画好的那一组下一帧换上来
    private let drawQueue = DispatchQueue(label: "com.feiyuchang.freefall.hud", qos: .userInitiated)
    private let lock = NSLock()
    private var drawing = false
    private var finished: (slot: Int, sides: Bool, hint: Bool)?
    /// 每一组贴图里画没画过东西（刚建的贴图内容不确定；这一组没画提示就别把上一次的旧提示显示出来）
    private var sidesValid = [false, false, false], hintValid = [false, false, false]

    init(device: MTLDevice) {
        self.device = device
        func make(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
            d.usage = [.shaderRead]
            return device.makeTexture(descriptor: d)!
        }
        for _ in 0..<3 {
            leftTextures.append(make(Self.sideSize.width * Self.scale, Self.sideSize.height * Self.scale))
            rightTextures.append(make(Self.sideSize.width * Self.scale, Self.sideSize.height * Self.scale))
            hintTextures.append(make(Self.hintSize.width * Self.scale, Self.hintSize.height * Self.scale))
        }
    }

    /// 更新读数（一秒最多重画 15 次；提示文字变了、开关了马上重画，都在后台画）。返回要画的面板（头锁定，按 headFromStage 摆）。
    /// dirty 是这一帧刚换上来的贴图（渲染器给它们生成 mipmap）
    func update(_ s: State, head: simd_float4x4) -> [Panel] {
        let sides = s.boot >= 0
        let hint = s.hintBoot >= 0 && !s.hint.isEmpty
        dirty = []
        lock.lock()
        let done = finished
        finished = nil
        let busy = drawing
        lock.unlock()
        if let done {
            slot = done.slot
            sidesValid[slot] = done.sides
            hintValid[slot] = done.hint
            if done.sides { dirty += [leftTextures[slot], rightTextures[slot]] }
            if done.hint { dirty.append(hintTextures[slot]) }
        }
        guard sides || hint else { return [] }
        let due = s.time - lastDraw >= 1.0 / 15 || s.hint != lastHint || sides != lastSides || lastDraw < 0
        if due, !busy {
            lastDraw = s.time
            lastHint = s.hint
            lastSides = sides
            // 画进下一组（三组轮着用：GPU 可能还在读刚换下去的那组）
            let next = (slot + 1) % 3
            let (left, right, hintTexture) = (leftTextures[next], rightTextures[next], hintTextures[next])
            lock.lock()
            drawing = true
            lock.unlock()
            drawQueue.async { [self] in
                if sides {
                    drawLeft(left, s)
                    drawRight(right, s)
                }
                if hint { drawHint(hintTexture, s) }
                lock.lock()
                finished = (next, sides, hint)
                drawing = false
                lock.unlock()
            }
        }
        var panels: [Panel] = []
        if sides, sidesValid[slot] {
            let boot = min(s.boot, 1)
            panels.append(Panel(texture: leftTextures[slot], uniforms: place(head, yaw: -Self.sideYaw, pitch: Self.sidePitch,
                                                                              size: Self.sideSize.meters, boot: boot)))
            panels.append(Panel(texture: rightTextures[slot], uniforms: place(head, yaw: Self.sideYaw, pitch: Self.sidePitch,
                                                                               size: Self.sideSize.meters, boot: boot)))
        }
        if hint, hintValid[slot] {
            let down = min(max(s.boot, 0), 1)
            let pitch = Self.hintPitch + (Self.hintPitchWithSides - Self.hintPitch) * down * down * (3 - 2 * down)
            panels.append(Panel(texture: hintTextures[slot], uniforms: place(head, yaw: 0, pitch: pitch,
                                                                              size: Self.hintSize.meters,
                                                                              boot: min(s.hintBoot, 1))))
        }
        return panels
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

    /// 按 scale 倍分辨率画：画图代码里用的是逻辑像素（贴图尺寸 ÷ scale）
    private func withContext(_ texture: MTLTexture, _ draw: (CGContext, Int, Int) -> Void) {
        let w = texture.width, h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setLineCap(.round)
            ctx.scaleBy(x: CGFloat(Self.scale), y: CGFloat(Self.scale))
            draw(ctx, w / Self.scale, h / Self.scale)
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: w * 4)
        }
    }

    /// 面板的底：很淡的暗色圆角矩形 + 一圈细边（y 向下的坐标）
    /// alpha：暗底有多不透明（落地时字常常压在白色伞布上，加深一些）
    private func plate(_ ctx: CGContext, _ rect: CGRect, h: Int, alpha: CGFloat = 0.42) {
        let r = CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height)
        let path = CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.0, green: 0.025, blue: 0.05, alpha: alpha))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 0.42, green: 0.88, blue: 1.0, alpha: 0.22))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
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

    private func accent(_ s: State) -> CGColor {
        switch s.alarm {
        case 2: return Self.red
        case 1: return Self.amber
        default: return Self.cyan
        }
    }

    private func blink(_ s: State) -> Bool { s.alarm == 0 || sin(s.time * (s.alarm == 2 ? 18 : 7)) > -0.2 }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private func drawLeft(_ texture: MTLTexture, _ s: State) {
        withContext(texture) { ctx, w, h in
            let a = accent(s)
            let blink = blink(s)
            plate(ctx, CGRect(x: 18, y: 18, width: 476, height: 564), h: h)
            // 阶段：一个小方块 + 字距拉开的英文
            ctx.setFillColor(a)
            ctx.fill(CGRect(x: 40, y: CGFloat(h) - 56, width: 12, height: 12))
            text(ctx, s.phase, x: 62, y: 56, size: 30, color: a, tracking: 4, height: h)
            line(ctx, 40, 74, 330, 74, h: h, color: Self.cyanDim, width: 1.5)
            line(ctx, 40, 74, 90, 74, h: h, color: a, width: 3)
            // 高度
            text(ctx, "ALT", x: 40, y: 108, size: 24, color: Self.cyanDim, tracking: 3, height: h)
            let alt = Self.grouped(s.altitudeFeet)
            let wNum = text(ctx, alt, x: 36, y: 196, size: 88, color: s.alarm > 0 && !blink ? a : Self.white, mono: true,
                            height: h)
            text(ctx, "FT", x: 42 + wNum, y: 192, size: 28, color: Self.cyan, tracking: 2, height: h)
            // 离地高度、下落速度
            text(ctx, "AGL", x: 40, y: 246, size: 24, color: Self.cyanDim, tracking: 3, height: h)
            text(ctx, Self.grouped(s.aglMeters) + " M", x: 104, y: 249, size: 36, color: Self.white, mono: true, height: h)
            text(ctx, "V/S", x: 40, y: 298, size: 24, color: Self.cyanDim, tracking: 3, height: h)
            text(ctx, "▼ \(s.fallSpeedKmh) KM/H", x: 104, y: 301, size: 36, color: Self.white, mono: true, height: h)
            // 下落速度条（0…300 km/h）
            let speedFrac = CGFloat(min(Float(s.fallSpeedKmh) / 300, 1))
            line(ctx, 40, 318, 330, 318, h: h, color: Self.cyanDim, width: 1)
            line(ctx, 40, 318, 40 + 290 * speedFrac, 318, h: h, color: Self.cyan, width: 4)

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
                        text(ctx, "\(mark / 1000)K", x: tapeX + 32, y: y + 9, size: 24, color: Self.cyan, mono: true,
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

            // 报警：PULL 一闪一闪（拉哪只小臂的拉环，下沿提示条里有）
            if s.alarm > 0, s.phase == "FREEFALL" {
                if blink {
                    ctx.setStrokeColor(a)
                    ctx.setLineWidth(3)
                    ctx.stroke(CGRect(x: 40, y: CGFloat(h) - 474, width: 290, height: 114))
                    text(ctx, "PULL", x: 185, y: 452, size: 70, color: a, anchor: 0.5, tracking: 10, height: h)
                }
            } else {
                text(ctx, "DEPLOY 3,500 FT", x: 40, y: 404, size: 24, color: Self.cyan, tracking: 2, height: h)
                line(ctx, 40, 420, 330, 420, h: h, color: Self.cyanDim, width: 1)
                if s.phase == "FREEFALL", s.altitudeFeet > 3500, s.fallSpeedKmh > 10 {
                    let seconds = Float(s.altitudeFeet - 3500) / 3.281 / (Float(s.fallSpeedKmh) / 3.6)
                    text(ctx, String(format: "T-%02d S", Int(seconds)), x: 40, y: 470, size: 42, color: Self.white,
                         mono: true, height: h)
                }
                if s.ringsTotal > 0, s.phase == "FREEFALL" || s.phase == "EXIT" {
                    text(ctx, "RINGS", x: 40, y: 530, size: 24, color: Self.cyanDim, tracking: 3, height: h)
                    text(ctx, "\(s.ringsPassed) / \(s.ringsTotal)", x: 128, y: 533, size: 36, color: Self.white, mono: true,
                         height: h)
                }
            }
        }
    }

    private func drawRight(_ texture: MTLTexture, _ s: State) {
        withContext(texture) { ctx, w, h in
            let a = accent(s)
            plate(ctx, CGRect(x: 18, y: 18, width: 476, height: 564), h: h)
            text(ctx, "NAV", x: 452, y: 56, size: 30, color: a, anchor: 1, tracking: 4, height: h)
            ctx.setFillColor(a)
            ctx.fill(CGRect(x: 460, y: CGFloat(h) - 56, width: 12, height: 12))
            line(ctx, 150, 74, 472, 74, h: h, color: Self.cyanDim, width: 1.5)
            line(ctx, 422, 74, 472, 74, h: h, color: a, width: 3)
            let heading = (Int(s.headingDeg.rounded()) % 360 + 360) % 360
            text(ctx, String(format: "HDG %03d°", heading), x: 470, y: 114, size: 34, color: Self.white, mono: true,
                 anchor: 1, height: h)
#if DEV_TOOLS
            // 左上角：实时帧率、GPU 一帧的耗时、画质档位。掉到 80 帧以下变橙，70 以下变红（只在开发版里画）
            if s.fps >= 0 {
                let c = s.fps >= 80 ? Self.white : s.fps >= 70 ? CGColor(red: 1, green: 0.62, blue: 0.15, alpha: 1)
                                                                : CGColor(red: 1, green: 0.25, blue: 0.2, alpha: 1)
                text(ctx, "\(s.fps) FPS", x: 44, y: 58, size: 36, color: c, mono: true, height: h)
                text(ctx, String(format: "%.1f MS  Q%d", s.gpuMs, s.qualityLevel), x: 44, y: 98, size: 26, color: Self.cyanDim,
                     mono: true, height: h)
            }
#endif

            // 罗盘：刻度、N E S W 跟着航向转，顶上一个固定的指示
            let cx: CGFloat = 290, cy: CGFloat = 310, r: CGFloat = 145
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
                    text(ctx, label, x: cx + sin(rel) * (r - 38), y: cy - cos(rel) * (r - 38) + 11, size: 30,
                         color: deg == 0 ? a : Self.white, anchor: 0.5, height: h)
                }
            }
            ctx.setFillColor(Self.white)
            ctx.move(to: CGPoint(x: cx - 9, y: cgCy + r + 18))
            ctx.addLine(to: CGPoint(x: cx + 9, y: cgCy + r + 18))
            ctx.addLine(to: CGPoint(x: cx, y: cgCy + r + 4))
            ctx.fillPath()
            // 降落点（LZ）：圈外一个橙色菱形 + 一条虚线指过去；圈里是距离
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
                text(ctx, "LZ", x: cx, y: cy - 12, size: 24, color: Self.amber, anchor: 0.5, tracking: 3, height: h)
                // 风：罗盘圈里从上风那一侧往圈心指的青色箭头，圈里下方写风速
                if let from = s.windFromDeg, s.windKmh > 0 {
                    let wr = CGFloat(from) * .pi / 180
                    let ox = cx + sin(wr) * (r - 14), oy = cy - cos(wr) * (r - 14)      // 箭尾（上风）
                    let ix = cx + sin(wr) * (r - 58), iy = cy - cos(wr) * (r - 58)      // 箭头（往下风）
                    line(ctx, ox, oy, ix, iy, h: h, color: Self.cyan, width: 3)
                    let dx = ix - ox, dy = iy - oy, len = max(hypot(dx, dy), 1)
                    let ux = dx / len, uy = dy / len
                    ctx.setFillColor(Self.cyan)
                    ctx.move(to: CGPoint(x: ix + ux * 10, y: CGFloat(h) - (iy + uy * 10)))
                    ctx.addLine(to: CGPoint(x: ix - uy * 8, y: CGFloat(h) - (iy + ux * 8)))
                    ctx.addLine(to: CGPoint(x: ix + uy * 8, y: CGFloat(h) - (iy - ux * 8)))
                    ctx.fillPath()
                    text(ctx, "WIND \(s.windKmh)", x: cx, y: cy + 66, size: 22, color: Self.cyan, anchor: 0.5,
                         tracking: 2, height: h)
                }
                text(ctx, distance >= 1000 ? String(format: "%.1f KM", Float(distance) / 1000) : "\(distance) M",
                     x: cx, y: cy + 32, size: 40, color: Self.white, mono: true, anchor: 0.5, height: h)
            }

            // 下面：地速；伞下有左右操纵环拉了多少；舱里是跳伞灯
            text(ctx, "GS", x: 150, y: 508, size: 24, color: Self.cyanDim, tracking: 3, height: h)
            text(ctx, "\(s.groundSpeedKmh) KM/H", x: 470, y: 511, size: 36, color: Self.white, mono: true, anchor: 1,
                 height: h)
            line(ctx, 150, 526, 472, 526, h: h, color: Self.cyanDim, width: 1)
            if s.underCanopy {
                if s.dive > 0.05 {
                    text(ctx, "DIVE", x: 150, y: 484, size: 28, color: Self.amber, tracking: 3, height: h)
                    ctx.setFillColor(Self.amber)
                    ctx.fill(CGRect(x: 230, y: CGFloat(h) - 478, width: 70 * CGFloat(min(s.dive, 1)), height: 10))
                }
                for (i, label) in ["L", "R"].enumerated() {
                    let x: CGFloat = 250 + CGFloat(i) * 130
                    let frac = CGFloat(i == 0 ? s.brakes.x : s.brakes.y)
                    ctx.setStrokeColor(Self.cyanDim)
                    ctx.setLineWidth(1.5)
                    ctx.stroke(CGRect(x: x, y: CGFloat(h) - 568, width: 90, height: 18))
                    ctx.setFillColor(Self.cyan)
                    ctx.fill(CGRect(x: x + 2, y: CGFloat(h) - 566, width: 86 * frac, height: 14))
                    text(ctx, label, x: x - 12, y: 567, size: 26, color: Self.cyan, anchor: 1, height: h)
                }
            } else if s.inCabin {
                ctx.setFillColor(s.greenLight ? Self.green : Self.red)
                ctx.fillEllipse(in: CGRect(x: 152, y: CGFloat(h) - 570, width: 20, height: 20))
                text(ctx, s.greenLight ? "JUMP  GO" : "JUMP  HOLD", x: 184, y: 569, size: 30,
                     color: s.greenLight ? Self.green : Self.red, tracking: 3, height: h)
            }
        }
    }

    private func drawHint(_ texture: MTLTexture, _ s: State) {
        withContext(texture) { ctx, w, h in
            let accent = accent(s)
            var lines = s.hint.split(separator: "\n").map(String.init)
            guard !lines.isEmpty else { return }
            // 两端一对括号，中间一行字（两三行时上下排），背后垫一层暗底。
            // 三行只有落地时会有：结果、这一跳解锁的皮肤、怎么结束
            let promptLeft = s.hint == Self.barPrompt(left: true)        // 扶杆在左边（表戴在右手）：箭头朝左
            let prompt = s.hint == Self.barPrompt(left: false) || promptLeft
            let extra: CGFloat = prompt ? 120 : 0
            func build(_ size: CGFloat) -> [(CTLine, CGFloat)] { build(lines, size) }
            func build(_ lines: [String], _ size: CGFloat) -> [(CTLine, CGFloat)] {
                // 字体按游戏里选的语言（汉字的字形：简中、繁中、日文各不一样）；跟随系统时是 nil
                let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, AppLanguage.code as CFString?)!
                return lines.prefix(3).enumerated().map { i, l in
                    let attributes: [NSAttributedString.Key: Any] = [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): i == 0 ? Self.white : Self.cyan,
                    ]
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: attributes))
                    return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
                }
            }
            let room = CGFloat(w) - 150 - extra * 2
            // 太长的一行（德、法、意文常见）整块等比缩会缩到一半大小：还不满三行时，先在冒号（没有就分号）处把最长的那行折成两行
            if lines.count < 3 {
                let widths = build(lines, lines.count > 1 ? 42 : 50).map(\.1)
                if let i = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[i] * 0.75 > room,
                   let r = ["：", ": ", " : ", "；", "; "].lazy.compactMap({ lines[i].range(of: $0) }).first {
                    let head = String(lines[i][..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                    let tail = String(lines[i][r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !head.isEmpty, !tail.isEmpty { lines.replaceSubrange(i...i, with: [head, tail]) }
                }
            }
            // 长的提示（伞下那句操作说明）按面板宽度缩字号，不然两头被裁掉
            let size: CGFloat = lines.count > 2 ? 32 : lines.count > 1 ? 42 : 50
            var built = build(size)
            if let widest = built.map(\.1).max(), widest > room { built = build(size * room / widest) }
            let half = (built.map(\.1).max() ?? 0) / 2 + 40
            let c = CGFloat(w) / 2
            plate(ctx, CGRect(x: c - half - 30 - (promptLeft ? extra : 0), y: 10, width: 2 * half + 60 + extra,
                              height: CGFloat(h) - 20), h: h, alpha: s.phase == "LANDED" ? 0.7 : 0.42)
            for (i, (line, width)) in built.enumerated() {
                // 三行：基线 46 / 84 / 122（底板在 10…140，第三行的下伸部分也在板里）
                let y = lines.count > 2 ? 46 + 38 * i : lines.count > 1 ? (i == 0 ? 68 : 124) : 94
                ctx.textPosition = CGPoint(x: (CGFloat(w) - width) / 2, y: CGFloat(h) - CGFloat(y))
                CTLineDraw(line, ctx)
            }
            if prompt {
                // 开场：扶杆那一边一串朝它跳的箭头
                let dir: CGFloat = promptLeft ? -1 : 1
                for k in 0..<3 {
                    let alpha = 0.25 + 0.75 * max(0, sin(CGFloat(s.time) * 6 - CGFloat(k) * 0.9))
                    let x = c + dir * (half + 14 + CGFloat(k) * 34)
                    ctx.setStrokeColor(Self.amber.copy(alpha: alpha) ?? Self.amber)
                    ctx.setLineWidth(6)
                    ctx.setLineJoin(.round)
                    ctx.move(to: CGPoint(x: x, y: CGFloat(h) / 2 + 20))
                    ctx.addLine(to: CGPoint(x: x + dir * 18, y: CGFloat(h) / 2))
                    ctx.addLine(to: CGPoint(x: x, y: CGFloat(h) / 2 - 20))
                    ctx.strokePath()
                }
            }
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
