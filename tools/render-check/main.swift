// 离屏渲染检查（在 Mac 上跑，不开窗口、不出声、不用戴头显）：
// 用和 Vision Pro 一样的方式——2 层纹理数组 + vertex amplification——跑 SceneRenderer，
// 用 app 里同一套 JumpSession（自动驾驶抓杆、松手、拉伞、转向）跑到某个时刻和朝向出图，按真机分辨率量 GPU 耗时，
// 或者把整段跳伞渲成预览帧。
//
//     tools/render-check/run.sh [输出目录] [shots|perf|seq|film|maps|sim|hands|all] [只画名字里含这个的镜头]
//
//   sim    不出图：自动驾驶在不同高度开伞各跳一次，打印结果（太晚开伞要摔、正常开伞要能飞进靶）
//   hands  不出图：用合成的手走真手的抓握逻辑（抓杆、松手、提前拉、报警后拉伞、拉操纵环转向），打印每一步
//
// 出图只存左眼（右眼只差 6.4 cm 视差）。perf 的数字是 M 系列 Mac 的，真机（M2 Vision Pro，GPU 10 核）大约要乘 4。
// 手部追踪和透视只有真机有，这里用合成的关节姿态（syntheticHand）摆手，画肤色的手代替真手。

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

let env = ProcessInfo.processInfo.environment
/// 跳哪一关：SCENE=0 环礁（默认）1 草原 2 高山 3 雪山 4 冰川 5 火山
let jumpScene = JumpScene(rawValue: Int(env["SCENE"] ?? "0") ?? 0) ?? .atoll
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: args[1]))
let queue = device.makeCommandQueue()!
/// 戴手套（默认，和 app 一样）；GLOVES=0 画肤色的替身手（代替真机上透视进来的真手）
let useGloves = env["GLOVES"] != "0"
let renderer = try SceneRenderer(device: device, library: library, colorFormat: .bgra8Unorm_srgb,
                                 depthFormat: .depth32Float, maxViewCount: 2, queue: queue, scene: jumpScene,
                                 gloveDirectory: env["GLOVES_DIR"].map { URL(fileURLWithPath: $0) })
if let v = env["EXPOSURE"], let x = Float(v) { renderer.settings.exposure = x }
if let v = env["SIGMA"], let x = Float(v) { renderer.settings.cloudExtinction = x }
if let v = env["STEP"], let x = Float(v) { renderer.settings.cloudStep = x }
if let v = env["CLOUDSCALE"], let x = Float(v) { renderer.settings.cloudScale = x }

let eyeHeight: Float = 1.6
let layout = BodyLayout(anchor: SIMD3(0, eyeHeight, 0))
let textPanel = TextPanel(device: device)
var panelPlacer = PanelPlacer()

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

/// 按手腕位置、手指朝向、手心朝向摆一只手（27 个关节，顺序同 HandJoint）。curl 0.3 放松微屈，1.5 握拳。
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

/// 让一只手「握住」某一点：手心中心（手腕往中指根 55%）落在这一点，手指朝 forward 方向
func grip(left: Bool, at point: SIMD3<Float>, forward: SIMD3<Float>, palm: SIMD3<Float>, curl: Float) -> HandPose {
    let wrist = point - normalize(forward) * 0.053
    return syntheticHand(left: left, wrist: wrist, forward: forward, palm: palm, curl: curl)
}

enum Hands { case none, arch, watch, watchRight, barOpen, bar, handle, toggles }

/// 摆手：弓身（两手在头两侧）、看表（手横在胸前）、握扶杆、抓拉手、抓操纵环
func hands(_ pose: Hands, _ session: JumpSession) -> [HandPose] {
    let archLeft = syntheticHand(left: true, wrist: SIMD3(-0.33, eyeHeight - 0.1, -0.36),
                                 forward: SIMD3(-0.35, 0.22, -1), palm: SIMD3(0, -1, -0.3))
    let archRight = syntheticHand(left: false, wrist: SIMD3(0.33, eyeHeight - 0.1, -0.36),
                                  forward: SIMD3(0.35, 0.22, -1), palm: SIMD3(0, -1, -0.3))
    let bar = session.timeline.bar
    let barPoint = SIMD3<Float>(bar.x, eyeHeight - 0.22, bar.z)
    switch pose {
    case .none: return []
    case .arch: return [archLeft, archRight]
    case .watch:
        return [syntheticHand(left: true, wrist: SIMD3(-0.07, eyeHeight - 0.3, -0.32),
                              forward: SIMD3(1, 0.12, 0.08), palm: SIMD3(0, -1, 0.15))]
    case .watchRight:
        return [syntheticHand(left: false, wrist: SIMD3(0.07, eyeHeight - 0.3, -0.32),
                              forward: SIMD3(-1, 0.12, 0.08), palm: SIMD3(0, -1, 0.15))]
    case .barOpen, .bar:
        // 右手从侧面握住竖杆：手指朝前绕过杆，手心朝右（朝着杆）
        return [grip(left: false, at: barPoint + SIMD3(-0.035, 0, 0.02), forward: SIMD3(0.25, -0.1, -1),
                     palm: SIMD3(1, 0, 0), curl: pose == .bar ? 1.5 : 0.35)]
    case .handle:
        let h = session.interaction.handle ?? layout.handleRest
        return [grip(left: false, at: h, forward: SIMD3(-0.4, -0.2, -1), palm: SIMD3(0, -0.3, 1), curl: 1.5)]
    case .toggles:
        let t = session.interaction.toggles ?? layout.toggleRest
        return [grip(left: true, at: t.0, forward: SIMD3(0.3, 1, -0.2), palm: SIMD3(1, 0, 0), curl: 1.5),
                grip(left: false, at: t.1, forward: SIMD3(-0.3, 1, -0.2), palm: SIMD3(-1, 0, 0), curl: 1.5)]
    }
}

// MARK: - 跑模拟

func autoSession(from timeline: JumpTimeline = JumpTimeline(scene: jumpScene), deployFeet: Double = 3000) -> JumpSession {
    let s = JumpSession(timeline: timeline, realHands: true, autopilot: Autopilot(deployFeet: deployFeet))
    s.setEyeHeight(eyeHeight)
    return s
}

/// 按 90 Hz 往前跑，直到 stop 返回 true（或者跳完）
func run(_ session: JumpSession, until stop: (JumpTimeline) -> Bool) {
    while !stop(session.timeline), !session.timeline.isOver {
        session.step(dt: 1.0 / 90, hands: [], layout: layout)
    }
}

func run(_ session: JumpSession, for seconds: Double) {
    let end = session.timeline.time + seconds
    run(session) { $0.time >= end }
}

/// 从机舱开始自动跳，跑到某个状态
func at(deployFeet: Double = 3000, _ stop: (JumpTimeline) -> Bool) -> JumpSession {
    let s = autoSession(deployFeet: deployFeet)
    run(s, until: stop)
    return s
}

func freefall(_ altitude: Double) -> JumpSession { autoSession(from: JumpTimeline(freefallFrom: altitude, scene: jumpScene)) }
/// 着陆区上空多少米开始自由落体（地形场景的着陆区不在海平面）
func freefallAbove(_ height: Double) -> JumpSession { freefall(jumpScene.dzElevation + height) }

/// 某个时刻之后过了多少秒（还没到是 -1）
func since(_ moment: Double?, _ t: JumpTimeline) -> Double { moment.map { t.time - $0 } ?? -1 }

extension JumpSession {
    /// 两只手先张开放到操纵环上，再握拳：抓握判定按「刚握上」算，这样操纵环才算被手抓着
    func grabbingToggles() -> JumpSession {
        let t = interaction.toggles ?? layout.toggleRest
        let open = [grip(left: true, at: t.0, forward: SIMD3(0.3, 1, -0.2), palm: SIMD3(1, 0, 0), curl: 0.2),
                    grip(left: false, at: t.1, forward: SIMD3(-0.3, 1, -0.2), palm: SIMD3(-1, 0, 0), curl: 0.2)]
        step(dt: 1.0 / 90, hands: open, layout: layout)
        step(dt: 1.0 / 90, hands: hands(.toggles, self), layout: layout)
        return self
    }
}

/// 开伞后多少秒
func deployed(_ seconds: Double) -> JumpSession { at { ($0.sinceDeploy ?? -1) >= seconds } }

/// 看向靶的朝向（度）
func lookAtTarget(_ t: JumpTimeline) -> (yaw: Float, pitch: Float) {
    let d = t.scene.target - t.groundPosition
    let c = cos(t.heading), s = sin(t.heading)
    let local = SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
    let yaw = atan2(-local.x, -local.y) * 180 / .pi
    let pitch = atan2(-t.heightAboveGround - Double(eyeHeight), length(local)) * 180 / .pi
    return (Float(yaw), Float(pitch))
}

/// 看向云坐标里某一点、某个高度的朝向（度）
func look(atCloud point: SIMD2<Double>, altitude: Double, from t: JumpTimeline) -> (yaw: Float, pitch: Float) {
    let d = point - t.position
    let c = cos(t.heading), s = sin(t.heading)
    let local = SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
    let yaw = atan2(-local.x, -local.y) * 180 / .pi
    let pitch = atan2(altitude - t.altitude, length(local)) * 180 / .pi
    return (Float(yaw), Float(pitch))
}

// MARK: - 画一帧

/// 画一帧（两只眼），返回 GPU 耗时（毫秒）。云层是时间累积的：同一个画面连画几帧才收敛。
@discardableResult
func render(_ session: JumpSession, yaw: Float, pitch: Float, hands handPoses: [HandPose],
            color: MTLTexture, depth: MTLTexture, fovY: Float, handTracking: Bool = true,
            watchOnLeft: Bool = true, panel showPanel: Bool = true, eye: SIMD3<Float>? = nil) -> Double {
    let width = color.width, height = color.height
    let head = rotation(yaw: yaw, pitch: pitch)
    // 第三人称看自己身上的装备：相机挪到 eye（相对眼睛），身体留在原地
    let eyeOffset = eye ?? SIMD3<Float>(0, 0, 0)
    let proj = projection(fovY: fovY, aspect: Float(width) / Float(height), near: 0.05)
    var views: [ViewUniforms] = []
    for dx in [Float(-0.032), 0.032] {
        var stageFromCamera = head
        let offset = head * SIMD4(dx, 0, 0, 0)
        stageFromCamera.columns.3 = SIMD4(offset.x + eyeOffset.x, eyeHeight + offset.y + eyeOffset.y, offset.z + eyeOffset.z, 1)
        let vp = proj * stageFromCamera.inverse
        views.append(ViewUniforms(viewProjection: vp, inverseViewProjection: vp.inverse,
                                  cameraPosition: stageFromCamera.columns.3,
                                  viewport: SIMD4(0, 0, Float(width), Float(height))))
    }

    let t = session.timeline
    let altitude = Float(t.altitude)
    var frame = FrameUniforms()
    frame.camera = SIMD4(altitude - eyeHeight, Float(t.time), Float(t.brightness), 0)
    frame.ground = SIMD4(Float(t.position.x), Float(t.landShift.x), Float(t.position.y), Float(t.landShift.y))
    let turning = Float(min(abs(t.turnRate) / JumpTimeline.maxTurnRate, 1))
    frame.heading = SIMD4(Float(cos(t.heading)), Float(sin(t.heading)), turning * 0.55, 0)
    let watchHand = handPoses.first(where: { $0.isLeft == watchOnLeft })
    frame.placeAltimeter(feet: t.altitudeFeet, eyeHeight: eyeHeight, watchHand: watchHand, alarm: t.alarmLevel,
                         gloved: useGloves)
    // 和真机一样：允许了手部追踪时只有手腕上的表，戴表的手不在视野里就没有高度表
    if handTracking && watchHand == nil { frame.hudUp.w = 0 }
    var objects = session.objects(layout: layout, hands: handPoses, watchOnLeft: watchOnLeft, proxyHands: !useGloves,
                                  gloves: useGloves, head: SIMD3(0, eyeHeight, 0))
    if env["NOLINES"] != nil { objects.lines = [] }
    if env["NOMESH"] != nil { objects.meshVertices = [] }
    if env["NOSHADOW"] != nil { objects.canopyShadow = nil; objects.bodyTop = nil }
    textPanel.set(showPanel ? session.hint : "")
    let forward = (head * SIMD4<Float>(0, 0, -1, 0)).xyz
    let panel = textPanel.texture.map {
        (texture: $0, uniforms: panelPlacer.place(head: SIMD3(0, eyeHeight, 0), forward: forward, dt: 1.0 / 90,
                                                  width: $0.width, height: $0.height))
    }

    let cb = queue.makeCommandBuffer()!
    renderer.encodeSky(cb, altitude: altitude)
    let vp = MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1)
    renderer.encode(cb, views: views, viewports: [vp, vp], frame: frame, colorTexture: color, depthTexture: depth,
                    renderTargetArrayLength: 2, rateMap: nil, objects: objects, panel: panel)
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

// MARK: - 镜头

struct Shot {
    var name: String
    var session: () -> JumpSession
    var yaw: Float          // 度，正 = 向左转
    var pitch: Float        // 度，负 = 低头
    var hands: Hands = .none
    var fovY: Float = 70
    var watchOnLeft = true
    /// 按靶的方向看（覆盖 yaw / pitch）
    var lookAtTarget = false
    /// 看向雨区（碎积云层中心、这个高度；覆盖 yaw / pitch）
    var lookAtRain: Double?
    /// 第三人称：相机相对眼睛的位置（看自己身上的装备）
    var eye: SIMD3<Float>?
    /// 背对太阳看（自己的影子在前面），再往左转多少度（正对着影子时会被右边的伸缩带挡住），pitch 照用
    var lookAwayFromSun: Float?
}

/// 背对太阳的朝向（度）：太阳在世界坐标里，舞台按航向转
func yawAwayFromSun(_ t: JumpTimeline) -> Float {
    let sun = SceneRenderer.sunDirection(for: t.scene)
    let d = SIMD2<Double>(-Double(sun.x), -Double(sun.z))
    let c = cos(t.heading), s = sin(t.heading)
    let local = SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
    return Float(atan2(-local.x, -local.y) * 180 / .pi)
}

let alarmFeet = { (feet: Int) in at { $0.altitudeFeet <= feet } }

/// 装备近景：背带、拉手、3 环、伸缩带、操纵环、滑块、表；快落地时地上自己的影子
let gearShots: [Shot] = [
    Shot(name: "x1_chest", session: { alarmFeet(3600) }, yaw: 0, pitch: -68, fovY: 62),
    Shot(name: "x2_handle_pull", session: { alarmFeet(3300) }, yaw: -12, pitch: -60, hands: .handle, fovY: 55),
    Shot(name: "x3_risers", session: { deployed(12) }, yaw: 0, pitch: 48, fovY: 75),
    Shot(name: "x4_toggle", session: { deployed(12) }, yaw: -61, pitch: -13, fovY: 30),
    Shot(name: "x5_three_ring", session: { deployed(12) }, yaw: -78, pitch: -50, fovY: 40),
    Shot(name: "x6_toggles_held", session: { deployed(12).grabbingToggles() }, yaw: -50, pitch: -8, hands: .toggles,
         fovY: 60),
    // 第三人称：从前面看自己（自由落体时、开伞后）
    Shot(name: "x9_front_freefall", session: { alarmFeet(3600) }, yaw: 180, pitch: -12, fovY: 50,
         eye: SIMD3(0, 0.0, -1.1)),
    Shot(name: "xa_front_canopy", session: { deployed(12) }, yaw: 180, pitch: 4, fovY: 60, eye: SIMD3(0, -0.05, -1.3)),
    Shot(name: "xb_side_canopy", session: { deployed(12) }, yaw: -90, pitch: 2, fovY: 60, eye: SIMD3(-1.2, 0.0, -0.1)),
    Shot(name: "x7_watch", session: { freefall(6500) }, yaw: 22, pitch: -38, hands: .watch, fovY: 30),
    Shot(name: "x8_shadow", session: { at { $0.phase == .canopy && $0.heightAboveGround < 14 } }, yaw: 0,
         pitch: -40, fovY: 80, lookAwayFromSun: 28),
    Shot(name: "xc_shadow_60m", session: { at { $0.phase == .canopy && $0.heightAboveGround < 60 } }, yaw: 0,
         pitch: -32, fovY: 60, lookAwayFromSun: 14),
    Shot(name: "xd_flare_front", session: { at { $0.phase == .canopy && $0.heightAboveGround < 14 } }, yaw: 180,
         pitch: 4, fovY: 60, eye: SIMD3(0, -0.05, -1.3)),
]

let atollShots: [Shot] = [
    Shot(name: "d1_door_start", session: { at { $0.time >= 1.5 } }, yaw: 0, pitch: -12),
    Shot(name: "d2_bar_reach", session: { at { $0.time >= 1.5 } }, yaw: -48, pitch: -16, hands: .barOpen, fovY: 80),
    Shot(name: "d3_holding_bar", session: { at { $0.holdingBar && $0.time >= 3.5 } }, yaw: -30, pitch: 4,
         hands: .bar, fovY: 84),
    Shot(name: "d4_door_light", session: { at { $0.holdingBar && $0.time >= 3.5 } }, yaw: 0, pitch: 30, fovY: 80),
    Shot(name: "d5_exit", session: { at { $0.phase == .exit && $0.time - ($0.exitTime ?? 0) > 0.8 } }, yaw: 0,
         pitch: -10),
    Shot(name: "c5_plane_leaving", session: { at { since($0.leftRampTime, $0) >= 3.5 } },
         yaw: 175, pitch: 22),
    Shot(name: "f1_exit_down45", session: { freefall(9100) }, yaw: 0, pitch: -45, hands: .arch),
    Shot(name: "f2_tower_side", session: { freefall(6000) }, yaw: 30, pitch: -10, hands: .arch),
    Shot(name: "g2_watch_zoom", session: { freefall(6500) }, yaw: 22, pitch: -38, hands: .watch, fovY: 22),
    Shot(name: "g3_watch_right", session: { freefall(6500) }, yaw: -22, pitch: -38, hands: .watchRight, fovY: 22,
         watchOnLeft: false),
    Shot(name: "f3_below_deck", session: { freefall(2100) }, yaw: 0, pitch: -40, hands: .arch),
    Shot(name: "r1_rain_in_deck", session: { freefall(2800) }, yaw: 0, pitch: -25),
    Shot(name: "r2_rain_below", session: { freefall(2050) }, yaw: 20, pitch: -12),
    Shot(name: "r3_rain_curtains", session: { deployed(8) }, yaw: 0, pitch: 0, fovY: 80, lookAtRain: 2000),
    Shot(name: "r4_rain_from_above", session: { freefall(4300) }, yaw: 0, pitch: 0, fovY: 80, lookAtRain: 1500),
    Shot(name: "f4_alarm_watch", session: { alarmFeet(3400) }, yaw: 0, pitch: -50, hands: .watch, fovY: 60),
    Shot(name: "f5_handle", session: { alarmFeet(3300) }, yaw: -10, pitch: -62, hands: .handle, fovY: 80),
    Shot(name: "o1_bag", session: { deployed(0.4) }, yaw: 0, pitch: 72, fovY: 90),
    Shot(name: "o2_lines", session: { deployed(0.9) }, yaw: 0, pitch: 72, fovY: 90),
    Shot(name: "o3_inflate", session: { deployed(1.6) }, yaw: 0, pitch: 70, fovY: 90),
    Shot(name: "o4_open", session: { deployed(2.6) }, yaw: 0, pitch: 66, fovY: 90),
    Shot(name: "o5_full", session: { deployed(4.5) }, yaw: 0, pitch: 62, fovY: 90),
    Shot(name: "k1_canopy_toggles", session: { deployed(12) }, yaw: 0, pitch: 40, hands: .toggles, fovY: 90),
    Shot(name: "k2_left_brake", session: {
        let s = deployed(15)
        s.autopilot?.hold = (1, 0)
        run(s, for: 2.5)
        return s
    }, yaw: 0, pitch: 55, hands: .toggles, fovY: 90),
    Shot(name: "k3_canopy_view", session: { deployed(25) }, yaw: 0, pitch: -32),
    Shot(name: "k4_target_far", session: { at { $0.phase == .canopy && $0.heightAboveGround < 300 } }, yaw: 0, pitch: 0,
         lookAtTarget: true),
    Shot(name: "k5_target_near", session: { at { $0.phase == .canopy && $0.heightAboveGround < 40 } }, yaw: 0,
         pitch: 0, fovY: 80, lookAtTarget: true),
    Shot(name: "l1_landed_down", session: { at { since($0.landedTime, $0) >= 2 } }, yaw: 0,
         pitch: -55, fovY: 80),
    Shot(name: "l2_landed_canopy", session: { at { since($0.landedTime, $0) >= 6 } }, yaw: 0,
         pitch: -20, fovY: 80),
    Shot(name: "l3_crash", session: { at(deployFeet: 200) { $0.landedTime != nil } }, yaw: 0, pitch: -30),
] + gearShots


/// 地形场景的镜头：高空俯瞰、穿过云层、报警时、开伞后看靶、看两边的山、低空、落地
let terrainShots: [Shot] = [
    Shot(name: "t1_door", session: { at { $0.time >= 1.5 } }, yaw: 0, pitch: -14),
    Shot(name: "t2_high_down", session: { freefallAbove(5500) }, yaw: 0, pitch: -55, fovY: 80),
    Shot(name: "t3_high_horizon", session: { freefallAbove(5500) }, yaw: 30, pitch: -12, fovY: 80),
    Shot(name: "t4_rain", session: { freefallAbove(2400) }, yaw: 0, pitch: -30),
    Shot(name: "t5_alarm", session: { alarmFeet(3400) }, yaw: 0, pitch: -45, hands: .watch, fovY: 70),
    Shot(name: "t6_canopy_target", session: { deployed(12) }, yaw: 0, pitch: 0, fovY: 80, lookAtTarget: true),
    Shot(name: "t7_canopy_left", session: { deployed(14) }, yaw: 75, pitch: 5, fovY: 80),
    Shot(name: "t8_canopy_right", session: { deployed(14) }, yaw: -75, pitch: 5, fovY: 80),
    Shot(name: "t9_canopy_back", session: { deployed(16) }, yaw: 180, pitch: -5, fovY: 80),
    Shot(name: "ta_low", session: { at { $0.phase == .canopy && $0.terrainClearance < 120 } }, yaw: 0, pitch: 0,
         fovY: 80, lookAtTarget: true),
    Shot(name: "tb_near", session: { at { $0.phase == .canopy && $0.terrainClearance < 25 } }, yaw: 0, pitch: -25,
         fovY: 80),
    Shot(name: "tc_landed", session: { at { since($0.landedTime, $0) >= 3 } }, yaw: 0, pitch: -20, fovY: 80),
    Shot(name: "td_landed_around", session: { at { since($0.landedTime, $0) >= 3 } }, yaw: 120, pitch: 8, fovY: 80),
] + gearShots

let shots = jumpScene == .atoll ? atollShots : terrainShots

if mode == "terrain" {
    // CPU（TerrainField.swift）和 GPU（TerrainField.h）的地形高度、地面类型逐点比对
    var points: [SIMD2<Float>] = []
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<4096 {
        points.append(SIMD2(Float.random(in: -6000...6000, using: &rng), Float.random(in: -6000...6000, using: &rng)))
    }
    for i in 0..<512 {   // 着陆区附近密一点
        let a = Float(i) * 0.618 * 2 * .pi, r = Float(i) * 0.8
        points.append(TerrainField.target + SIMD2(cos(a), sin(a)) * r)
    }
    let pointBuffer = device.makeBuffer(bytes: points, length: MemoryLayout<SIMD2<Float>>.stride * points.count,
                                        options: .storageModeShared)!
    let outBuffer = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * points.count, options: .storageModeShared)!
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "sampleTerrain")!)
    for scene in JumpScene.allCases where scene.hasTerrain {
        var sceneIndex = Int32(scene.rawValue)
        var count = UInt32(points.count)
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(pointBuffer, offset: 0, index: 0)
        enc.setBuffer(outBuffer, offset: 0, index: 1)
        enc.setBytes(&sceneIndex, length: 4, index: 2)
        enc.setBytes(&count, length: 4, index: 3)
        enc.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let gpu = outBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: points.count)
        var maxDiff: Float = 0, hazardMismatch = 0, minH: Float = 1e9, maxH: Float = -1e9
        var worst = SIMD2<Float>(0, 0)
        for (i, p) in points.enumerated() {
            let h = TerrainField.height(scene, p)
            let diff = abs(h - gpu[i].x)
            if diff > maxDiff { maxDiff = diff; worst = p }
            let hz = TerrainField.hazard(scene, p, h)?.rawValue ?? 0
            if hz != Int(gpu[i].y) { hazardMismatch += 1 }
            minH = min(minH, h); maxH = max(maxH, h)
        }
        let dz = TerrainField.height(scene, TerrainField.target)
        print(String(format: "  %@：高度差最大 %.4f 米（在 %.0f, %.0f），地面类型不一致 %d / %d；高度 %.0f ~ %.0f，靶 %.1f（应为 %.0f）",
                     scene.name, maxDiff, worst.x, worst.y, hazardMismatch, points.count, minH, maxH, dz,
                     scene.dzElevation))
    }
}

if mode == "hazards" {
    // 几个已知位置的地面判定：火山口、熔岩流、冰裂缝、冰湖、河、树林、陡坡、烟柱
    func check(_ scene: JumpScene, _ name: String, _ p: SIMD2<Float>) {
        let h = TerrainField.height(scene, p)
        let hz = TerrainField.hazard(scene, p, h).map { "\($0)" } ?? "没事"
        print(String(format: "  %@ %@：海拔 %.0f，坡度 %.0f°，%@", scene.name, name, h, TerrainField.slopeDegrees(scene, p), hz))
    }
    check(.volcano, "火山口中间", TerrainField.coneCenter)
    check(.volcano, "熔岩流上", SIMD2(-150, -1080))
    check(.volcano, "靶", TerrainField.target)
    check(.volcano, "火山锥坡上", TerrainField.coneCenter + SIMD2(300, 0))
    let plume = TerrainField.plumeDensity(TerrainField.coneCenter + TerrainField.plumeDrift * 500, altitude: TerrainField.coneTop + 460)
    print(String(format: "  火山 烟柱里（火山口上方 500 米）：浓度 %.2f（> 0.4 算冲进去）", plume))
    for s in stride(from: Float(-1600), through: -1200, by: 50) {
        let p = TerrainField.target + TerrainField.valleyDir * s
        if TerrainField.hazard(.glacier, p, TerrainField.height(.glacier, p)) == .crevasse { check(.glacier, "冰瀑区（找到的第一条裂缝）", p); break }
    }
    check(.glacier, "冰湖", TerrainField.target + TerrainField.valleyDir * 1730)
    check(.glacier, "靶", TerrainField.target)
    check(.grassland, "河中间", SIMD2(0, -390 + 110 * sin(0.4) + 45 * sin(2.1)))
    check(.grassland, "池塘", TerrainField.pondCenter)
    check(.alpine, "谷壁上（横向 1.2 km）", TerrainField.target + TerrainField.valleySide * 1200)
    check(.snow, "谷壁上（横向 1.4 km）", TerrainField.target + TerrainField.valleySide * 1400)
}

if mode == "shots" || mode == "all" {
    let width = 1280, height = 960
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    for shot in shots where filter.isEmpty || shot.name.contains(filter) {
        renderer.resetHistory()
        panelPlacer = PanelPlacer()
        let session = shot.session()
        let h = hands(shot.hands, session)
        var yaw = shot.yaw, pitch = shot.pitch
        if shot.lookAtTarget { (yaw, pitch) = lookAtTarget(session.timeline) }
        if let offset = shot.lookAwayFromSun { yaw = yawAwayFromSun(session.timeline) + offset }
        if let h = shot.lookAtRain {
            (yaw, pitch) = look(atCloud: JumpTimeline.deckCenter, altitude: h, from: session.timeline)
        }
        for _ in 0..<11 {
            render(session, yaw: yaw, pitch: pitch, hands: h, color: color, depth: depth, fovY: shot.fovY,
                   watchOnLeft: shot.watchOnLeft, eye: shot.eye)
        }
        let ms = render(session, yaw: yaw, pitch: pitch, hands: h, color: color, depth: depth, fovY: shot.fovY,
                        watchOnLeft: shot.watchOnLeft, eye: shot.eye)
        saveLeftEye(color, to: outDir.appendingPathComponent("\(shot.name).png"))
        let t = session.timeline
        print(String(format: "%@  t=%.1f s  %.0f m（离地 %.0f）  %@  雨 %.2f  %.1f ms  「%@」", shot.name, t.time,
                     t.altitude, t.heightAboveGround, String(describing: t.phase), t.rainIntensity, ms,
                     session.hint.replacingOccurrences(of: "\n", with: " / ")))
    }
}

if mode == "sim" || mode == "all" {
    // 不同高度开伞：太晚要摔；正常开伞自动驾驶要能飞进靶（自动驾驶飞得进，人才有机会）
    print("开伞高度 → 结果：")
    for feet in [3500.0, 3000, 2500, 2000, 1500, 1000, 600, 300, -1] {
        let s = autoSession(deployFeet: feet)
        var openAt = SIMD2<Double>(0, 0), openHAG = 0.0
        run(s) { t in
            if t.phase == .opening, t.sinceDeploy ?? 1 < 0.02 { openAt = t.groundPosition; openHAG = t.heightAboveGround }
            return t.landedTime != nil
        }
        let t = s.timeline
        let toTarget = length(t.scene.target - openAt)
        if env["PILOT"] == String(Int(feet)) {
            // 再跑一遍，打印伞下每 2 秒的状态
            let d = autoSession(deployFeet: feet)
            run(d) { $0.phase == .canopy }
            while d.timeline.landedTime == nil {
                let tl = d.timeline
                if Int((tl.time * 90).rounded()) % 180 == 0 {
                    let v = tl.scene.target - tl.groundPosition
                    let reach = JumpTimeline.canopySpeed * max(tl.heightAboveGround - 6, 0) / JumpTimeline.canopySink + 15
                    print(String(format: "    t=%5.1f 离地 %5.0f  离靶 %5.0f  能飞 %5.0f  富余 %5.0f  刹车 %.2f/%.2f  航向 %6.0f°  地面 (%.0f, %.0f)",
                                 tl.time, tl.heightAboveGround, length(v), reach, reach - length(v), tl.brakeLeft,
                                 tl.brakeRight, tl.heading * 180 / .pi, tl.groundPosition.x, tl.groundPosition.y))
                }
                d.step(dt: 1.0 / 90, hands: [], layout: layout)
            }
        }
        print(String(format: "  %@  开伞时离地 %4.0f m、离靶 %4.0f m → %@  离靶心 %.1f m  落地 %.1f m/s  （t=%.0f s）",
                     feet < 0 ? "  不开伞" : String(format: "%5.0f ft", feet), openHAG, toTarget,
                     String(describing: t.outcome!), t.landingDistance, t.landingSpeed, t.time))
    }
}

if mode == "hands" || mode == "all" {
    // 真手的抓握逻辑：不开自动驾驶，用合成的手一步步做（握拳 = 抓）
    let s = JumpSession(timeline: JumpTimeline(scene: jumpScene), realHands: true, autopilot: nil)
    s.setEyeHeight(eyeHeight)
    func step(_ seconds: Double, _ makeHands: () -> [HandPose]) {
        let end = s.timeline.time + seconds
        while s.timeline.time < end, !s.timeline.isOver {
            s.step(dt: 1.0 / 90, hands: makeHands(), layout: layout)
        }
    }
    func report(_ what: String) {
        let t = s.timeline
        print(String(format: "  %@ → %@  抓杆 %@  离地 %.0f m  拉手 %@  刹车 %.2f/%.2f  航向 %.1f°  「%@」", what,
                     String(describing: t.phase), t.holdingBar ? "是" : "否", t.heightAboveGround,
                     s.interaction.handlePulled ? "已拉" : "没拉", t.brakeLeft, t.brakeRight, t.heading * 180 / .pi,
                     s.hint.replacingOccurrences(of: "\n", with: " / ")))
    }
    print("真手流程：")
    let bar = s.timeline.bar
    let barPoint = SIMD3<Float>(bar.x, eyeHeight - 0.22, bar.z)
    func barHand(_ curl: Float) -> [HandPose] {
        [grip(left: false, at: barPoint + SIMD3(-0.035, 0, 0.02), forward: SIMD3(0.25, -0.1, -1), palm: SIMD3(1, 0, 0),
              curl: curl)]
    }
    step(1.0) { barHand(0.35) }
    report("张开手放到杆边上")
    step(1.0) { barHand(1.5) }
    report("握拳")
    step(0.2) { [] }
    report("手丢了 0.2 秒（应该还算抓着）")
    step(2.0) { barHand(1.5) }
    step(0.3) { barHand(0.35) }
    report("松开")
    run(s) { $0.phase == .freefall && $0.heightAboveGround < 1500 }
    // 还没报警就去拉：拉不动
    var reach: Float = 0
    func handleHand(_ pull: Float, _ curl: Float) -> [HandPose] {
        let p = layout.handleRest + normalize(SIMD3<Float>(0.3, 0.1, -1)) * pull
        return [grip(left: false, at: p, forward: SIMD3(-0.4, -0.2, -1), palm: SIMD3(0, -0.3, 1), curl: curl)]
    }
    step(0.3) { handleHand(0, 0.35) }
    step(0.3) { handleHand(0, 1.5) }
    step(0.5) { reach = min(reach + 0.01, 0.3); return handleHand(reach, 1.5) }
    report("报警前拉拉手")
    step(0.3) { handleHand(0, 0.35) }
    run(s) { $0.alarmLevel >= 1 }
    report("手表报警")
    reach = 0
    step(0.3) { handleHand(0, 0.35) }
    step(0.3) { handleHand(0, 1.5) }
    step(0.5) { reach = min(reach + 0.01, 0.3); return handleHand(reach, 1.5) }
    report("报警后拉拉手")
    step(0.5) { [] }
    run(s) { $0.phase == .canopy }
    func toggleHands(_ leftPull: Float, _ rightPull: Float) -> [HandPose] {
        let r = layout.toggleRest
        return [grip(left: true, at: r.0 - SIMD3(0, leftPull, 0), forward: SIMD3(0.3, 1, -0.2), palm: SIMD3(1, 0, 0),
                     curl: 1.5),
                grip(left: false, at: r.1 - SIMD3(0, rightPull, 0), forward: SIMD3(-0.3, 1, -0.2),
                     palm: SIMD3(-1, 0, 0), curl: 1.5)]
    }
    step(0.5) { toggleHands(0, 0) }
    report("抓住两个操纵环")
    let h0 = s.timeline.heading
    var pull: Float = 0
    step(3.0) { pull = min(pull + 0.004, 0.25); return toggleHands(pull, 0) }
    report(String(format: "拉左环 3 秒（航向变了 %+.1f°，应该往左 = 正）", (s.timeline.heading - h0) * 180 / .pi))
    let h1 = s.timeline.heading
    step(3.0) { toggleHands(0, 0.25) }
    report(String(format: "拉右环 3 秒（航向变了 %+.1f°，应该往右 = 负）", (s.timeline.heading - h1) * 180 / .pi))
    step(0.5) {
        let r = layout.toggleRest
        return [grip(left: true, at: r.0 - SIMD3(0, 0.1, 0), forward: SIMD3(0.3, 1, -0.2), palm: SIMD3(1, 0, 0), curl: 0.3),
                grip(left: false, at: r.1 - SIMD3(0, 0.1, 0), forward: SIMD3(-0.3, 1, -0.2), palm: SIMD3(-1, 0, 0),
                     curl: 0.3)]
    }
    report("张开手（操纵环弹回）")
}

if mode == "seq" || mode == "all" {
    // 连续下落 + 慢慢转头：检查云层重投影（拖影、错位会在这里露馅）
    let width = 1280, height = 960
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    renderer.resetHistory()
    // SEQ=cabin：从机舱阶段开始（飞机以 70 m/s 掠过云层，查水平方向的重投影）；SEQ=turn：伞下拉着左环转弯
    let session: JumpSession
    switch env["SEQ"] {
    case "cabin": session = autoSession()
    case "turn":
        session = deployed(15)
        session.autopilot?.hold = (1, 0)
    default: session = freefall(Double(env["SEQALT"].flatMap(Float.init) ?? 7200))
    }
    for i in 0..<91 {
        session.step(dt: 1.0 / 90, hands: [], layout: layout)
        render(session, yaw: 20 + Float(i) * 0.5, pitch: -30, hands: [], color: color, depth: depth, fovY: 70,
               panel: false)
        if [0, 4, 30, 90].contains(i) {
            saveLeftEye(color, to: outDir.appendingPathComponent(String(format: "seq_%02d.png", i)))
        }
    }
    print("连续帧已存（seq_00/04/30/90）")
}

if mode == "film" {
    // 预览视频：从机舱开始按 90 Hz 跑完整段（时间累积和重投影都和真机一样逐帧跑），存成 30 fps。
    // 机舱、出舱、开伞这几段按原速，自由落体和伞降按 3 倍速。头部动作是写死的。只存左眼。
    let width = 1280, height = 720
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    renderer.resetHistory()
    let session = autoSession()
    var saved = 0
    var videoTime = 0.0, nextFrame = 0.0
    var yaw: Float = 0, pitch: Float = -10
    let framesDir = outDir.appendingPathComponent("frames")
    try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
    while !session.timeline.isOver {
        session.step(dt: 1.0 / 90, hands: [], layout: layout)
        let tl = session.timeline
        let t = Float(tl.time)
        var targetYaw: Float = 0, targetPitch: Float = -10
        var pose: Hands = .none
        var speed = 3.0
        let sinceRamp = tl.leftRampTime.map { tl.time - $0 } ?? -1
        let sinceDeploy = tl.sinceDeploy ?? -1
        switch tl.phase {
        case .cabin:
            speed = 1
            targetYaw = tl.holdingBar ? -15 : 5 * sin(t / 2)
            targetPitch = -9
            if tl.holdingBar { pose = .bar }
        case .exit:
            speed = 1
            targetPitch = -12
        case .freefall:
            if sinceRamp < 7 {
                speed = 1
                if sinceRamp > 1.5 { targetYaw = 170; targetPitch = 25 }   // 回头看飞机飞走
            } else if tl.alarmLevel > 0 {
                speed = 1
                targetPitch = -55
                pose = .handle
            } else {
                targetYaw = 28 * sin(t * 2 * .pi / 26) + 8
                targetPitch = -34 + 9 * sin(t * 2 * .pi / 17)
                if fmod(tl.time, 30) < 4 { pose = .watch; targetPitch = -50; targetYaw = 0 }   // 看一眼手腕
            }
        case .opening:
            speed = 1
            targetPitch = 65
        case .canopy:
            pose = .toggles
            if sinceDeploy < 10 {
                speed = 1
                targetPitch = 55
                targetYaw = 8
            } else {
                let look = lookAtTarget(tl)
                targetYaw = look.yaw * 0.6
                targetPitch = max(look.pitch, -60) * 0.8
            }
        case .landed, .done:
            speed = 1
            targetPitch = -40
        }
        // 头转得平滑一点（时间常数 0.4 秒），换镜头不会跳
        let k = Float(1 - exp(-1.0 / 90 / 0.4))
        yaw += (targetYaw - yaw) * k
        pitch += (targetPitch - pitch) * k
        render(session, yaw: yaw, pitch: pitch, hands: hands(pose, session), color: color, depth: depth, fovY: 64)
        videoTime += 1.0 / 90 / speed
        if videoTime >= nextFrame {
            nextFrame += 1.0 / 30
            saveLeftEye(color, to: framesDir.appendingPathComponent(String(format: "f%05d.png", saved)))
            saved += 1
        }
    }
    print("预览帧 \(saved) 张（时间线 \(String(format: "%.1f", session.timeline.time)) 秒）")
}

if mode == "perf" || mode == "all" {
    // Vision Pro 每只眼的渲染目标大约 1888×1792（开注视点渲染后实际着色的像素更少，这里按不开算，偏保守）
    let width = 1888, height = 1792
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: false)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    print("性能（两只眼 \(width)×\(height)，云层比例 \(renderer.settings.cloudScale)，步长倍数 \(renderer.settings.cloudStep)）：")
    for shot in shots where filter.isEmpty || shot.name.contains(filter) {
        panelPlacer = PanelPlacer()
        let session = shot.session()
        let h = hands(shot.hands, session)
        for _ in 0..<4 {
            render(session, yaw: shot.yaw, pitch: shot.pitch, hands: h, color: color, depth: depth, fovY: 100)
        }
        var times: [Double] = []
        // 这台 Mac 上别的程序也在用 GPU，单次计时抖得厉害：取 24 次里最快的（最接近不受干扰的耗时）和中位
        for _ in 0..<24 {
            times.append(render(session, yaw: shot.yaw, pitch: shot.pitch, hands: h, color: color, depth: depth,
                                fovY: 100))
        }
        times.sort()
        print(String(format: "  %@  最快 %.2f ms  中位 %.2f ms", shot.name, times[0], times[times.count / 2]))
    }
    // CPU：伞衣布料每帧的耗时（真机在渲染线程上跑）
    let s = deployed(5)
    let start = Date()
    for _ in 0..<900 { s.step(dt: 1.0 / 90, hands: [], layout: layout) }
    print(String(format: "  伞衣布料 + 时间线：每帧 %.3f ms（CPU）", Date().timeIntervalSince(start) / 900 * 1000))
    // CPU：每帧组装网格（伞衣、滑块、装备、表）和绳子
    let handPoses = hands(.toggles, s) + hands(.watch, s)
    let start2 = Date()
    var vertexCount = 0, lineCount = 0
    for _ in 0..<300 {
        let o = s.objects(layout: layout, hands: handPoses, watchOnLeft: true, proxyHands: false, gloves: useGloves,
                          head: SIMD3(0, eyeHeight, 0))
        vertexCount = o.meshVertices.count; lineCount = o.lines.count
    }
    print(String(format: "  组装网格：每帧 %.3f ms（CPU），%d 个顶点、%d 段绳子", Date().timeIntervalSince(start2) / 300 * 1000,
                 vertexCount, lineCount))
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

    // 环礁图，叠上自动驾驶的水平路线（红点：自由落体，黄点：伞降，白点：靶），看伞降会不会飞过礁和沙洲
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
    // 环礁图的中心和大小（和 Clouds.h 的 ATOLL_CENTER / ATOLL_SIZE 一致）
    let atollCenter = SIMD2<Double>(Double(env["ATOLLX"].flatMap(Float.init) ?? 1800),
                                    Double(env["ATOLLZ"].flatMap(Float.init) ?? -3350))
    let atollSize = Double(env["ATOLLSIZE"].flatMap(Float.init) ?? 16000)
    func plot(_ p: SIMD2<Double>, _ color: (UInt8, UInt8, UInt8), radius: Int = 3) {
        let uv = (p - atollCenter) / atollSize + 0.5
        let px = Int(uv.x * Double(a.width)), py = Int(uv.y * Double(a.height))
        for dy in -radius...radius { for dx in -radius...radius {
            let x = px + dx, y = py + dy
            if x >= 0, y >= 0, x < a.width, y < a.height {
                let i = (y * a.width + x) * 4
                atollBGRA[i] = color.2; atollBGRA[i + 1] = color.1; atollBGRA[i + 2] = color.0
            }
        } }
    }
    let s = autoSession()
    var path: [String] = []
    while !s.timeline.isOver {
        s.step(dt: 1.0 / 90, hands: [], layout: layout)
        let tl = s.timeline
        let step = Int((tl.time * 90).rounded())
        if step % 45 == 0 {
            let canopy = tl.phase == .canopy || tl.phase == .opening
            plot(tl.groundPosition, canopy ? (255, 230, 0) : (255, 0, 0), radius: 1)
        }
        if step % (90 * 10) == 0 {
            path.append(String(format: "t=%.0f %@ 离地=%.0f 地面 x=%.0f z=%.0f", tl.time, String(describing: tl.phase),
                               tl.heightAboveGround, tl.groundPosition.x, tl.groundPosition.y))
        }
    }
    plot(s.timeline.scene.target, (255, 255, 255), radius: 2)
    savePNG(bgra: atollBGRA, width: a.width, height: a.height, to: outDir.appendingPathComponent("map_atoll.png"))
    // 着陆区放大：以靶为中心 2 km 见方
    let zoom = 512
    var crop = [UInt8](repeating: 0, count: zoom * zoom * 4)
    let tuv = (s.timeline.scene.target - atollCenter) / atollSize + 0.5
    let cx = Int(tuv.x * Double(a.width)), cy = Int(tuv.y * Double(a.height))
    let span = Int(2000 / atollSize * Double(a.width))
    for y in 0..<zoom { for x in 0..<zoom {
        let sx = min(max(cx - span / 2 + x * span / zoom, 0), a.width - 1)
        let sy = min(max(cy - span / 2 + y * span / zoom, 0), a.height - 1)
        for c in 0..<4 { crop[(y * zoom + x) * 4 + c] = atollBGRA[(sy * a.width + sx) * 4 + c] }
    } }
    savePNG(bgra: crop, width: zoom, height: zoom, to: outDir.appendingPathComponent("map_landing.png"))
    print("时间线（每 10 秒）：\n  " + path.joined(separator: "\n  "))
    print("结果：\(s.resultSummary ?? "没落地")")

    let shadow = renderer.cloudShadow
    let half = dump(shadow, bytesPerPixel: 2)
    var gray = [UInt8](repeating: 255, count: shadow.width * shadow.height * 4)
    half.withUnsafeBytes { raw in
        let values = raw.bindMemory(to: Float16.self)
        for i in 0..<(shadow.width * shadow.height) {
            let t = exp(-Float(values[i]) * renderer.settings.cloudExtinction * 0.5)
            let v = UInt8(max(0, min(255, t * 255)))
            gray[i * 4] = v; gray[i * 4 + 1] = v; gray[i * 4 + 2] = v
        }
    }
    savePNG(bgra: gray, width: shadow.width, height: shadow.height, to: outDir.appendingPathComponent("map_shadow.png"))

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
