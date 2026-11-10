// 离屏渲染检查（在 Mac 上跑，不开窗口、不出声、不用戴头显）：
// 用和 Vision Pro 一样的方式——2 层纹理数组 + vertex amplification——跑 SceneRenderer，
// 按几个典型高度和朝向出图，再按真机分辨率量 GPU 耗时。
//
//     tools/render-check/run.sh [输出目录] [shots|perf|maps|all] [只画名字里含这个的镜头]
//
// 出图只存左眼（右眼只差 6.4 cm 视差）。perf 模式的数字是 M 系列 Mac 的，真机（M2 Vision Pro，GPU 10 核）
// 大约要乘 3~4，再和 90 Hz 的 11.1 ms 比。

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
if let v = ProcessInfo.processInfo.environment["EXPOSURE"], let x = Float(v) { renderer.settings.exposure = x }
if let v = ProcessInfo.processInfo.environment["SIGMA"], let x = Float(v) { renderer.settings.cloudExtinction = x }
if let v = ProcessInfo.processInfo.environment["STEP"], let x = Float(v) { renderer.settings.cloudStep = x }
if let v = ProcessInfo.processInfo.environment["CLOUDSCALE"], let x = Float(v) { renderer.settings.cloudScale = x }

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

struct Shot {
    var name: String
    var altitude: Float     // 米（头的海拔）
    var yaw: Float          // 度，正 = 向左转
    var pitch: Float        // 度，负 = 低头
}

let eyeHeight: Float = 1.6

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

/// 画一帧（两只眼），返回 GPU 耗时（毫秒）。云层是时间累积的：同一个镜头连画几帧才收敛。
@discardableResult
func render(_ shot: Shot, color: MTLTexture, depth: MTLTexture, fovY: Float, time: Float = 0,
            brightness: Float = 1) -> Double {
    let width = color.width, height = color.height
    let head = rotation(yaw: shot.yaw, pitch: shot.pitch)
    let proj = projection(fovY: fovY, aspect: Float(width) / Float(height), near: 0.1)
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

    var frame = FrameUniforms()
    frame.camera = SIMD4(shot.altitude - eyeHeight, time, brightness, 0)
    frame.ground = SIMD4(time * 6, 0, 0, 0)
    // 高度表：起跳时头前方 0.5 米、低 0.3 米，面朝眼睛
    let center = SIMD3<Float>(0, eyeHeight - 0.30, -0.50)
    let toEye = normalize(SIMD3<Float>(0, eyeHeight, 0) - center)
    let right = SIMD3<Float>(1, 0, 0)
    let up = cross(toEye, right)
    frame.hudCenter = SIMD4(center, 0.15)
    frame.hudRight = SIMD4(right, 0.05)
    frame.hudUp = SIMD4(up, 1)
    frame.hudGlyphs = FrameUniforms.glyphs(feet: Int(Double(shot.altitude) * 3.28084))

    let cb = queue.makeCommandBuffer()!
    renderer.encodeSky(cb, altitude: shot.altitude)
    let vp = MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1)
    renderer.encode(cb, views: views, viewports: [vp, vp], frame: frame, colorTexture: color, depthTexture: depth,
                    renderTargetArrayLength: 2, rateMap: nil)
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

let shots: [Shot] = [
    Shot(name: "01_exit_down45", altitude: 9100, yaw: 0, pitch: -45),
    Shot(name: "02_exit_horizon", altitude: 9100, yaw: 0, pitch: -8),
    Shot(name: "03_exit_back", altitude: 9100, yaw: 180, pitch: -25),
    Shot(name: "04_exit_straightdown", altitude: 9100, yaw: 0, pitch: -88),
    Shot(name: "05_tower_side", altitude: 6000, yaw: 30, pitch: -10),
    Shot(name: "06_above_deck", altitude: 3700, yaw: 0, pitch: -60),
    Shot(name: "07_in_deck", altitude: 2800, yaw: 0, pitch: -30),
    Shot(name: "08_below_deck", altitude: 2100, yaw: 0, pitch: -40),
    Shot(name: "09_low_ocean", altitude: 1200, yaw: 30, pitch: -20),
    Shot(name: "11_atoll_high", altitude: 9100, yaw: -25, pitch: -40),
    Shot(name: "12_atoll_low", altitude: 1800, yaw: -25, pitch: -35),
    Shot(name: "10_look_up_from_below", altitude: 1500, yaw: 0, pitch: 50),
]

if mode == "shots" || mode == "all" {
    let width = 1280, height = 960
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    for shot in shots where filter.isEmpty || shot.name.contains(filter) {
        renderer.resetHistory()
        for _ in 0..<11 { render(shot, color: color, depth: depth, fovY: 70) }
        let ms = render(shot, color: color, depth: depth, fovY: 70)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&bytes, bytesPerRow: width * 4, bytesPerImage: width * height * 4,
                       from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: 0)
        savePNG(bgra: bytes, width: width, height: height, to: outDir.appendingPathComponent("\(shot.name).png"))
        print(String(format: "%@  %.0f m  %.1f ms", shot.name, shot.altitude, ms))
    }
}

if mode == "seq" || mode == "all" {
    // 连续下落 + 慢慢转头：检查云层重投影（拖影、错位会在这里露馅）
    let width = 1280, height = 960
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    renderer.resetHistory()
    let start = Float(ProcessInfo.processInfo.environment["SEQALT"].flatMap(Float.init) ?? 7200)
    for i in 0..<91 {
        // 90 Hz：每帧掉 0.9 米（81 m/s），头每帧左转 0.5°（每秒 45°，转头不算慢）
        let shot = Shot(name: "seq", altitude: start - Float(i) * 0.9, yaw: 20 + Float(i) * 0.5, pitch: -30)
        render(shot, color: color, depth: depth, fovY: 70, time: Float(i) / 90)
        if [0, 4, 30, 90].contains(i) {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            color.getBytes(&bytes, bytesPerRow: width * 4, bytesPerImage: width * height * 4,
                           from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: 0)
            savePNG(bgra: bytes, width: width, height: height,
                    to: outDir.appendingPathComponent(String(format: "seq_%02d.png", i)))
        }
    }
    print("连续帧已存（seq_00/04/30/90）")
}

if mode == "film" {
    // 预览视频：按 90 Hz 模拟整段下落（时间累积和重投影都和真机一样逐帧跑），每 9 帧存一张 → 30 fps、3 倍速。
    // 头部动作是写死的：大致低头 35°，慢慢左右看。只存左眼。
    let width = 1280, height = 720
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: true)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    renderer.resetHistory()
    var sim = FallSimulation()
    var frame = 0, saved = 0
    let framesDir = outDir.appendingPathComponent("frames")
    try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
    while !sim.isOver {
        sim.step(1.0 / 90)
        let t = Float(sim.time)
        let shot = Shot(name: "film", altitude: Float(sim.altitude),
                        yaw: 28 * sin(t * 2 * .pi / 26) + 8, pitch: -34 + 9 * sin(t * 2 * .pi / 17))
        render(shot, color: color, depth: depth, fovY: 64, time: t, brightness: Float(sim.brightness))
        if frame % 9 == 0 {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            color.getBytes(&bytes, bytesPerRow: width * 4, bytesPerImage: width * height * 4,
                           from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: 0)
            savePNG(bgra: bytes, width: width, height: height,
                    to: framesDir.appendingPathComponent(String(format: "f%05d.png", saved)))
            saved += 1
        }
        frame += 1
    }
    print("预览帧 \(saved) 张（\(frame) 帧模拟）")
}

if mode == "perf" || mode == "all" {
    // Vision Pro 每只眼的渲染目标大约 1888×1792（开注视点渲染后实际着色的像素更少，这里按不开算，偏保守）
    let width = 1888, height = 1792
    let color = makeArray(.bgra8Unorm_srgb, width: width, height: height, shared: false)
    let depth = makeArray(.depth32Float, width: width, height: height, shared: false)
    print("性能（两只眼 \(width)×\(height)，云层比例 \(renderer.settings.cloudScale)，步长倍数 \(renderer.settings.cloudStep)）：")
    for shot in shots where filter.isEmpty || shot.name.contains(filter) {
        for _ in 0..<4 { render(shot, color: color, depth: depth, fovY: 100) }
        var times: [Double] = []
        // 这台 Mac 上别的程序也在用 GPU，单次计时抖得厉害：取 24 次里最快的（最接近不受干扰的耗时）和中位
        for _ in 0..<24 { times.append(render(shot, color: color, depth: depth, fovY: 100)) }
        times.sort()
        print(String(format: "  %@  最快 %.2f ms  中位 %.2f ms", shot.name, times[0], times[times.count / 2]))
    }
}

if mode == "maps" || mode == "all" {
    // 天气图（r 覆盖率、g 云顶、b 云底）和云影图，看云的分布
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
    let a = renderer.atoll
    let atollRGBA = dump(a, bytesPerPixel: 4)
    var atollBGRA = [UInt8](repeating: 0, count: atollRGBA.count)
    for i in stride(from: 0, to: atollRGBA.count, by: 4) {
        // 看图用：陆地黄、植被绿、浪白、水按深浅蓝
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
    savePNG(bgra: atollBGRA, width: a.width, height: a.height, to: outDir.appendingPathComponent("map_atoll.png"))

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
    print("天气图和云影图已存")
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
