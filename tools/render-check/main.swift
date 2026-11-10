// 离屏渲染检查（在 Mac 上跑，不开窗口、不出声、不用戴头显）：
// 用和 Vision Pro 一样的方式——2 层纹理数组 + vertex amplification——跑 SceneRenderer，
// 按时间线上的几个时刻和朝向出图，按真机分辨率量 GPU 耗时，或者把整段跳伞渲成预览帧。
//
//     tools/render-check/run.sh [输出目录] [shots|perf|seq|film|maps|all] [只画名字里含这个的镜头]
//
// 出图只存左眼（右眼只差 6.4 cm 视差）。perf 的数字是 M 系列 Mac 的，真机（M2 Vision Pro，GPU 10 核）大约要乘 4。
// 手部追踪只有真机有，这里用合成的关节姿态（syntheticHand）检查手套和手腕高度表的样子。

import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/freefall-render")
let mode = args.count > 3 ? args[3] : "shots"
let filter = args.count > 4 ? args[4] : ""
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: args[1]))
let queue = device.makeCommandQueue()!
let renderer = try SceneRenderer(device: device, library: library, colorFormat: .bgra8Unorm_srgb,
                                 depthFormat: .depth32Float, maxViewCount: 2, queue: queue)
let env = ProcessInfo.processInfo.environment
if let v = env["EXPOSURE"], let x = Float(v) { renderer.settings.exposure = x }
if let v = env["SIGMA"], let x = Float(v) { renderer.settings.cloudExtinction = x }
if let v = env["STEP"], let x = Float(v) { renderer.settings.cloudStep = x }
if let v = env["CLOUDSCALE"], let x = Float(v) { renderer.settings.cloudScale = x }

let eyeHeight: Float = 1.6

/// 右手系、reverse-Z、无穷远平面（和 CompositorServices 一样：近平面深度 1，无穷远 0）
func projection(fovY: Float, aspect: Float, near: Float) -> simd_float4x4 {
    let f = 1 / tan(fovY * .pi / 360)
    return simd_float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                                   SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
}

func rotation(yaw: Float, pitch: Float) -> simd_float4x4 {
    let y = simd_float4x4(simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0)))
    let p = simd_float4x4(simd_quatf(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0)))
    return y * p
}

func makeArray(_ format: MTLPixelFormat, width: Int, height: Int, shared: Bool) -> MTLTexture {
    let d = MTLTextureDescriptor()
    d.textureType = .type2DArray
    d.pixelFormat = format
    d.width = width
    d.height = height
    d.arrayLength = 2
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = shared ? .shared : .private
    return device.makeTexture(descriptor: d)!
}

// MARK: - 合成的手

/// 按手腕位置、手指朝向、手心朝向摆一只放松微屈的手（27 个关节，顺序同 HandJoint）。
func syntheticHand(left: Bool, wrist: SIMD3<Float>, forward: SIMD3<Float>, palm: SIMD3<Float>,
                   curl: Float = 0.28) -> HandPose {
    let F = normalize(forward)
    let P = normalize(palm - dot(palm, F) * F)
    let S = left ? cross(P, F) : cross(F, P)          // 拇指那一侧
    var j = [SIMD3<Float>](repeating: .zero, count: HandJoint.allCases.count)
    func set(_ joint: HandJoint, _ p: SIMD3<Float>) { j[joint.rawValue] = p }
    set(.wrist, wrist)
    set(.forearmWrist, wrist - F * 0.015)
    set(.forearmArm, wrist - F * 0.24)
    let fingers: [(HandJoint, SIMD2<Float>, SIMD2<Float>, [Float])] = [
        (.indexMetacarpal, SIMD2(0.025, 0.02), SIMD2(0.092, 0.024), [0.04, 0.024, 0.021]),
        (.middleMetacarpal, SIMD2(0.027, 0.005), SIMD2(0.097, 0.005), [0.044, 0.028, 0.022]),
        (.ringMetacarpal, SIMD2(0.025, -0.01), SIMD2(0.092, -0.014), [0.041, 0.026, 0.022]),
        (.littleMetacarpal, SIMD2(0.022, -0.024), SIMD2(0.083, -0.031), [0.032, 0.019, 0.019]),
    ]
    for (meta, m, k, lengths) in fingers {
        let base = meta.rawValue
        set(meta, wrist + F * m.x + S * m.y)
        var p = wrist + F * k.x + S * k.y
        set(HandJoint(rawValue: base + 1)!, p)
        var angle = curl * 0.5
        for (i, l) in lengths.enumerated() {
            p += (F * cos(angle) + P * sin(angle)) * l
            set(HandJoint(rawValue: base + 2 + i)!, p)
            angle += curl
        }
    }
    var tp = wrist + F * 0.022 + S * 0.03 + P * 0.008
    set(.thumbKnuckle, tp)
    var td = normalize(F * 0.7 + S * 0.6 + P * 0.25)
    for (i, l) in [Float(0.038), 0.031, 0.026].enumerated() {
        tp += td * l
        set(HandJoint(rawValue: HandJoint.thumbIntermediateBase.rawValue + i)!, tp)
        td = normalize(td + P * curl * 0.5 - S * 0.15)
    }
    return HandPose(joints: j, isLeft: left)
}

enum Hands { case none, arch, watch }

/// 自由落体的「弓身」姿势：两手在头两侧前方；看表：左手横在胸前、手心朝下（表面朝上）
func hands(_ pose: Hands) -> [HandPose] {
    let archLeft = syntheticHand(left: true, wrist: SIMD3(-0.33, eyeHeight - 0.1, -0.36),
                                 forward: SIMD3(-0.35, 0.22, -1), palm: SIMD3(0, -1, -0.3))
    let archRight = syntheticHand(left: false, wrist: SIMD3(0.33, eyeHeight - 0.1, -0.36),
                                  forward: SIMD3(0.35, 0.22, -1), palm: SIMD3(0, -1, -0.3))
    switch pose {
    case .none: return []
    case .arch: return [archLeft, archRight]
    case .watch:
        return [syntheticHand(left: true, wrist: SIMD3(-0.07, eyeHeight - 0.3, -0.32),
                              forward: SIMD3(1, 0.12, 0.08), palm: SIMD3(0, -1, 0.15)), archRight]
    }
}

// MARK: - 画一帧

/// 画一帧（两只眼），返回 GPU 耗时（毫秒）。云层是时间累积的：同一个画面连画几帧才收敛。
@discardableResult
func render(_ timeline: JumpTimeline, yaw: Float, pitch: Float, hands handPoses: [HandPose],
            color: MTLTexture, depth: MTLTexture, fovY: Float) -> Double {
    let width = color.width, height = color.height
    let head = rotation(yaw: yaw, pitch: pitch)
    let proj = projection(fovY: fovY, aspect: Float(width) / Float(height), near: 0.05)
    var views: [ViewUniforms] = []
    for dx in [Float(-0.032), 0.032] {
        var stageFromCamera = head
        let offset = head * SIMD4(dx, 0, 0, 0)
        stageFromCamera.columns.3 = SIMD4(offset.x, eyeHeight + offset.y, offset.z, 1)
        let vp = proj * stageFromCamera.inverse
        views.append(ViewUniforms(viewProjection: vp, inverseViewProjection: vp.inverse,
                                  cameraPosition: stageFromCamera.columns.3,
                                  viewport: SIMD4(0, 0, Float(width), Float(height))))
    }

    let altitude = Float(timeline.altitude)
    var frame = FrameUniforms()
    frame.camera = SIMD4(altitude - eyeHeight, Float(timeline.time), Float(timeline.brightness), 0)
    frame.ground = SIMD4(Float(timeline.position.x), 0, Float(timeline.position.y), 0)
    frame.placeAltimeter(feet: timeline.altitudeFeet, eyeHeight: eyeHeight,
                         leftHand: handPoses.first(where: { $0.isLeft }))
    let objects = SceneObjects.make(timeline: timeline, eyeHeight: eyeHeight, hands: handPoses)

    let cb = queue.makeCommandBuffer()!
    renderer.encodeSky(cb, altitude: altitude)
    let vp = MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1)
    renderer.encode(cb, views: views, viewports: [vp, vp], frame: frame, colorTexture: color, depthTexture: depth,
                    renderTargetArrayLength: 2, rateMap: nil, objects: objects)
    cb.commit()
    cb.waitUntilCompleted()
    if let error = cb.error { print("GPU 错误：\(error)") }
    return (cb.gpuEndTime - cb.gpuStartTime) * 1000
}

func savePNG(bgra: [UInt8], width: Int, height: Int, to url: URL) {
    let provider = CGDataProvider(data: Data(bgra) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                 | CGImageAlphaInfo.noneSkipFirst.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func saveLeftEye(_ color: MTLTexture, to url: URL) {
    let width = color.width, height = color.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    color.getBytes(&bytes, bytesPerRow: width * 4, bytesPerImage: width * height * 4,
                   from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: 0)
    savePNG(bgra: bytes, width: width, height: height, to: url)
}

// MARK: - 时间线上的时刻

/// 从头按 90 Hz 跑到时刻 t（不捏手指，第 11 秒自动跳）
func timeline(at t: Double) -> JumpTimeline {
    var tl = JumpTimeline()
    while tl.time < t, !tl.isOver { tl.step(1.0 / 90) }
    return tl
}

/// 开伞那一刻（时间线时间）
let deployTime: Double = {
    var tl = JumpTimeline()
    while tl.deployTime == nil, !tl.isOver { tl.step(1.0 / 90) }
    return tl.deployTime ?? 0
}()

struct Shot {
    var name: String
    var timeline: JumpTimeline
    var yaw: Float          // 度，正 = 向左转
    var pitch: Float        // 度，负 = 低头
    var hands: Hands = .none
    var fovY: Float = 70
}

func freefall(_ altitude: Double) -> JumpTimeline { JumpTimeline(freefallFrom: altitude) }

let shots: [Shot] = [
    Shot(name: "c1_cabin_ramp", timeline: timeline(at: 3), yaw: 0, pitch: -12),
    Shot(name: "c2_cabin_front", timeline: timeline(at: 3), yaw: 180, pitch: -8),
    Shot(name: "c3_green_light", timeline: timeline(at: 8), yaw: -18, pitch: 0),
    Shot(name: "c4_exit", timeline: timeline(at: 12.4), yaw: 0, pitch: -10),
    Shot(name: "c5_plane_leaving", timeline: timeline(at: 16), yaw: 175, pitch: 22),
    Shot(name: "c6_plane_far", timeline: timeline(at: 24), yaw: 175, pitch: 32),
    Shot(name: "01_exit_down45", timeline: freefall(9100), yaw: 0, pitch: -45, hands: .arch),
    Shot(name: "02_exit_horizon", timeline: freefall(9100), yaw: 0, pitch: -8),
    Shot(name: "05_tower_side", timeline: freefall(6000), yaw: 30, pitch: -10, hands: .arch),
    Shot(name: "g1_watch", timeline: freefall(6500), yaw: 0, pitch: -50, hands: .watch),
    Shot(name: "g2_watch_zoom", timeline: freefall(6500), yaw: 22, pitch: -38, hands: .watch, fovY: 22),
    Shot(name: "07_in_deck", timeline: freefall(2800), yaw: 0, pitch: -30),
    Shot(name: "08_below_deck", timeline: freefall(2100), yaw: 0, pitch: -40, hands: .arch),
    Shot(name: "p1_deploy", timeline: timeline(at: deployTime + 1.0), yaw: 0, pitch: 70),
    Shot(name: "p2_canopy_up", timeline: timeline(at: deployTime + 8), yaw: 15, pitch: 62),
    Shot(name: "p3_canopy_view", timeline: timeline(at: deployTime + 20), yaw: 0, pitch: -32),
    Shot(name: "p4_canopy_reef", timeline: timeline(at: deployTime + 60), yaw: 10, pitch: -28),
    Shot(name: "p5_canopy_low", timeline: timeline(at: deployTime + 85), yaw: 0, pitch: -22, hands: .watch),
]

if mode == "shots" || mode == "all" {
    let width = 1280, height = 960
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    for shot in shots where filter.isEmpty || shot.name.contains(filter) {
        renderer.resetHistory()
        let h = hands(shot.hands)
        for _ in 0..<11 {
            render(shot.timeline, yaw: shot.yaw, pitch: shot.pitch, hands: h, color: color, depth: depth, fovY: shot.fovY)
        }
        let ms = render(shot.timeline, yaw: shot.yaw, pitch: shot.pitch, hands: h, color: color, depth: depth,
                        fovY: shot.fovY)
        saveLeftEye(color, to: outDir.appendingPathComponent("\(shot.name).png"))
        print(String(format: "%@  t=%.1f s  %.0f m  %@  %.1f ms", shot.name, shot.timeline.time,
                     shot.timeline.altitude, String(describing: shot.timeline.phase), ms))
    }
}

if mode == "seq" || mode == "all" {
    // 连续下落 + 慢慢转头：检查云层重投影（拖影、错位会在这里露馅）
    let width = 1280, height = 960
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    renderer.resetHistory()
    // SEQ=cabin：从机舱阶段开始（飞机以 70 m/s 掠过云层，查水平方向的重投影）
    var tl = env["SEQ"] == "cabin" ? JumpTimeline() : freefall(Double(env["SEQALT"].flatMap(Float.init) ?? 7200))
    for i in 0..<91 {
        tl.step(1.0 / 90)
        render(tl, yaw: 20 + Float(i) * 0.5, pitch: -30, hands: [], color: color, depth: depth, fovY: 70)
        if [0, 4, 30, 90].contains(i) {
            saveLeftEye(color, to: outDir.appendingPathComponent(String(format: "seq_%02d.png", i)))
        }
    }
    print("连续帧已存（seq_00/04/30/90）")
}

if mode == "film" {
    // 预览视频：从机舱开始按 90 Hz 跑完整段（时间累积和重投影都和真机一样逐帧跑），存成 30 fps。
    // 机舱、出舱、开伞这几段按原速，自由落体和伞降按 3 倍速。头部动作和手是写死的。只存左眼。
    let width = 1280, height = 720
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    renderer.resetHistory()
    var tl = JumpTimeline()
    var saved = 0
    var videoTime = 0.0, nextFrame = 0.0
    var yaw: Float = 0, pitch: Float = -10
    let framesDir = outDir.appendingPathComponent("frames")
    try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
    while !tl.isOver {
        tl.step(1.0 / 90)
        let t = Float(tl.time)
        var targetYaw: Float = 0, targetPitch: Float = -10
        var pose: Hands = .none
        var speed = 3.0
        let sinceRamp = tl.leftRampTime.map { tl.time - $0 } ?? -1
        let sinceDeploy = tl.deployTime.map { tl.time - $0 } ?? -1
        switch tl.phase {
        case .cabin:
            speed = 1
            targetYaw = 5 * sin(t / 2)
            targetPitch = -9
            if tl.time > 5.5 && tl.time < 9 { targetYaw = -20; targetPitch = 0 }   // 看跳伞灯变绿
        case .exit:
            speed = 1
            targetPitch = -12
        case .freefall:
            pose = .arch
            if sinceRamp < 7 {
                speed = 1
                if sinceRamp > 1.5 { targetYaw = 170; targetPitch = 25 }   // 回头看飞机飞走
            } else {
                targetYaw = 28 * sin(t * 2 * .pi / 26) + 8
                targetPitch = -34 + 9 * sin(t * 2 * .pi / 17)
                if fmod(tl.time, 30) < 4 { pose = .watch; targetPitch = -50; targetYaw = 0 }   // 看一眼手腕
            }
        case .opening:
            speed = 1
            targetPitch = 65
        case .canopy, .done:
            if sinceDeploy < 10 {
                speed = 1
                targetPitch = 62
                targetYaw = 12
            } else {
                targetYaw = 20 * sin(t * 2 * .pi / 30)
                targetPitch = -28 + 6 * sin(t * 2 * .pi / 19)
            }
        }
        // 头转得平滑一点（时间常数 0.4 秒），换镜头不会跳
        let k = Float(1 - exp(-1.0 / 90 / 0.4))
        yaw += (targetYaw - yaw) * k
        pitch += (targetPitch - pitch) * k
        render(tl, yaw: yaw, pitch: pitch, hands: hands(pose), color: color, depth: depth, fovY: 64)
        videoTime += 1.0 / 90 / speed
        if videoTime >= nextFrame {
            nextFrame += 1.0 / 30
            saveLeftEye(color, to: framesDir.appendingPathComponent(String(format: "f%05d.png", saved)))
            saved += 1
        }
    }
    print("预览帧 \(saved) 张（时间线 \(String(format: "%.1f", tl.time)) 秒）")
}

if mode == "perf" || mode == "all" {
    // Vision Pro 每只眼的渲染目标大约 1888×1792（开注视点渲染后实际着色的像素更少，这里按不开算，偏保守）
    let width = 1888, height = 1792
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: false)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    print("性能（两只眼 \(width)×\(height)，云层比例 \(renderer.settings.cloudScale)，步长倍数 \(renderer.settings.cloudStep)）：")
    for shot in shots where filter.isEmpty || shot.name.contains(filter) {
        let h = hands(shot.hands)
        for _ in 0..<4 {
            render(shot.timeline, yaw: shot.yaw, pitch: shot.pitch, hands: h, color: color, depth: depth, fovY: 100)
        }
        var times: [Double] = []
        // 这台 Mac 上别的程序也在用 GPU，单次计时抖得厉害：取 24 次里最快的（最接近不受干扰的耗时）和中位
        for _ in 0..<24 {
            times.append(render(shot.timeline, yaw: shot.yaw, pitch: shot.pitch, hands: h,
                                color: color, depth: depth, fovY: 100))
        }
        times.sort()
        print(String(format: "  %@  最快 %.2f ms  中位 %.2f ms", shot.name, times[0], times[times.count / 2]))
    }
}

if mode == "maps" || mode == "all" {
    // 天气图（r 覆盖率、g 云顶、b 云底）、环礁图、云影图、时间线路线、大气常量
    func dump(_ texture: MTLTexture, bytesPerPixel: Int) -> [UInt8] {
        let w = texture.width, h = texture.height
        let buffer = device.makeBuffer(length: w * h * bytesPerPixel, options: .storageModeShared)!
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: w * bytesPerPixel, destinationBytesPerImage: w * h * bytesPerPixel)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt8.self, capacity: w * h * bytesPerPixel),
                                         count: w * h * bytesPerPixel))
    }
    let w = renderer.weather
    let rgba = dump(w, bytesPerPixel: 4)
    var bgra = [UInt8](repeating: 0, count: rgba.count)
    for i in stride(from: 0, to: rgba.count, by: 4) {
        bgra[i] = rgba[i + 2]; bgra[i + 1] = rgba[i + 1]; bgra[i + 2] = rgba[i]; bgra[i + 3] = 255
    }
    savePNG(bgra: bgra, width: w.width, height: w.height, to: outDir.appendingPathComponent("map_weather.png"))

    // 环礁图，叠上时间线的水平路线（红点：自由落体，黄点：伞降），看伞降会不会飞过礁和沙洲
    let a = renderer.atoll
    let atollRGBA = dump(a, bytesPerPixel: 4)
    var atollBGRA = [UInt8](repeating: 0, count: atollRGBA.count)
    for i in stride(from: 0, to: atollRGBA.count, by: 4) {
        let land = Float(atollRGBA[i]) / 255, depth = Float(atollRGBA[i + 1]) / 255
        let veg = Float(atollRGBA[i + 2]) / 255, surf = Float(atollRGBA[i + 3]) / 255
        var r = 0.05 + 0.3 * (1 - depth), g = 0.2 + 0.6 * (1 - depth), b = 0.5 + 0.4 * (1 - depth)
        r = r * (1 - land) + land * (0.9 * (1 - veg) + 0.1 * veg)
        g = g * (1 - land) + land * (0.8 * (1 - veg) + 0.5 * veg)
        b = b * (1 - land) + land * (0.5 * (1 - veg) + 0.1 * veg)
        r += surf; g += surf; b += surf
        atollBGRA[i] = UInt8(min(255, b * 255)); atollBGRA[i + 1] = UInt8(min(255, g * 255))
        atollBGRA[i + 2] = UInt8(min(255, r * 255)); atollBGRA[i + 3] = 255
    }
    var tl = JumpTimeline()
    var path: [String] = []
    let atollCenter = SIMD2<Double>(Double(env["ATOLLX"].flatMap(Float.init) ?? 0),
                                    Double(env["ATOLLZ"].flatMap(Float.init) ?? 0))
    while !tl.isOver {
        tl.step(1.0 / 90)
        let step = Int((tl.time * 90).rounded())
        if step % 90 == 0 {
            // 地面坐标 → 环礁图像素（图 16 km 见方，2048 像素）
            let uv = (tl.position - atollCenter) / 16000 + 0.5
            let px = Int(uv.x * Double(a.width)), py = Int(uv.y * Double(a.height))
            let canopy = tl.phase == .canopy || tl.phase == .opening
            for dy in -3...3 { for dx in -3...3 {
                let x = px + dx, y = py + dy
                if x >= 0, y >= 0, x < a.width, y < a.height {
                    let i = (y * a.width + x) * 4
                    atollBGRA[i] = 0; atollBGRA[i + 1] = canopy ? 230 : 0; atollBGRA[i + 2] = 255
                }
            } }
        }
        if step % (90 * 10) == 0 {
            path.append(String(format: "t=%.0f %@ alt=%.0f x=%.0f z=%.0f", tl.time, String(describing: tl.phase),
                               tl.altitude, tl.position.x, tl.position.y))
        }
    }
    savePNG(bgra: atollBGRA, width: a.width, height: a.height, to: outDir.appendingPathComponent("map_atoll.png"))
    print("时间线（每 10 秒）：\n  " + path.joined(separator: "\n  "))

    let s = renderer.cloudShadow
    let half = dump(s, bytesPerPixel: 2)
    var gray = [UInt8](repeating: 255, count: s.width * s.height * 4)
    half.withUnsafeBytes { raw in
        let values = raw.bindMemory(to: Float16.self)
        for i in 0..<(s.width * s.height) {
            let t = exp(-Float(values[i]) * renderer.settings.cloudExtinction * 0.5)
            let v = UInt8(max(0, min(255, t * 255)))
            gray[i * 4] = v; gray[i * 4 + 1] = v; gray[i * 4 + 2] = v
        }
    }
    savePNG(bgra: gray, width: s.width, height: s.height, to: outDir.appendingPathComponent("map_shadow.png"))

    // 大气常量（太阳照度记为 1）
    let constants = device.makeBuffer(length: atmosphereConstantsSize, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: renderer.atmosphereConstants, sourceOffset: 0, to: constants, destinationOffset: 0,
              size: atmosphereConstantsSize)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let v = constants.contents().bindMemory(to: SIMD4<Float>.self, capacity: 6)
    for (i, name) in ["sunAtCloudBase", "sunAtCloudTop", "sunAtSea", "skyRadianceAvg", "skyIrradianceSea", "groundBounce"].enumerated() {
        print(String(format: "  %@  %.4f %.4f %.4f", name, v[i].x, v[i].y, v[i].z))
    }
}
