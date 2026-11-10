import ARKit
import CompositorServices
import Metal
import os
import QuartzCore
import simd
import SwiftUI

// 渲染循环的骨架来自 Bubble Dream（再往上是 MetalSplatter 的 visionOS 示例，MIT，© Sean Cier）。

/// 每帧：推进下落 → 拿头部位姿 → 天空视图表 → 每个 drawable 画云层 + 天空海面 + 高度表。
final class ImmersiveRenderer: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.feiyuchang.freefall", category: "Renderer")
    private static let maxFramesInFlight = 3
    /// 模拟器的头部锚点永远在原点（相当于趴在地板上），抬到 1.6 米；真机拿不到锚点时也用它。
    private static let fallbackEyeHeight: Float = 1.6

    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let queue: MTLCommandQueue
    let scene: SceneRenderer

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let inFlight = DispatchSemaphore(value: maxFramesInFlight)
    private let wind: WindAudio?

    private var simulation = FallSimulation(startAltitude: DebugOptions.startAltitude)
    private var lastFrameTime: CFTimeInterval?
    /// ImmersiveSpace 原点 → 舞台（跳的那一刻脚下、面朝的方向）。拿到头部位姿的第一帧定下来。
    private var stageFromOrigin: simd_float4x4?
    /// 舞台空间里起跳那一刻眼睛的高度：海拔就对准这个高度
    private var eyeHeight = fallbackEyeHeight
    private var ended = false
    private var frameCount = 0

    /// 最近每帧的 GPU 耗时（毫秒），command buffer 完成时写入
    private let gpuTimes = OSAllocatedUnfairLock(initialState: [Double]())
    private var qualityLevel = 0
    private var lastQualityChange: CFTimeInterval = 0
    private var lastStatsLog: CFTimeInterval = 0

    init(_ layerRenderer: LayerRenderer) throws {
        self.layerRenderer = layerRenderer
        device = layerRenderer.device
        queue = device.makeCommandQueue()!
        guard let library = device.makeDefaultLibrary() else {
            throw SceneRenderer.RendererError.missingFunction("default library")
        }
        scene = try SceneRenderer(device: device, library: library,
                                  colorFormat: layerRenderer.configuration.colorFormat,
                                  depthFormat: layerRenderer.configuration.depthFormat,
                                  maxViewCount: layerRenderer.properties.viewCount,
                                  queue: queue)
        wind = DebugOptions.mute ? nil : WindAudio()
    }

    @MainActor
    static func start(_ layerRenderer: LayerRenderer) {
        let renderer: ImmersiveRenderer
        do {
            renderer = try ImmersiveRenderer(layerRenderer)
        } catch {
            log.error("无法创建渲染器：\(error.localizedDescription)")
            return
        }
        Task(executorPreference: RendererTaskExecutor.shared) {
            do {
                try await renderer.arSession.run([renderer.worldTracking])
            } catch {
                log.error("ARKit 启动失败：\(error.localizedDescription)")
            }
            renderer.renderLoop()
        }
    }

    private static func headPose(_ anchor: DeviceAnchor?) -> simd_float4x4 {
        var lifted = matrix_identity_float4x4
        lifted.columns.3 = SIMD4(0, fallbackEyeHeight, 0, 1)
        guard let anchor else { return lifted }
#if targetEnvironment(simulator)
        return lifted * anchor.originFromAnchorTransform
#else
        return anchor.originFromAnchorTransform
#endif
    }

    /// 舞台：原点在头正下方的地板上，-Z 是头的水平朝向（忽略低头抬头和歪头）
    private static func stage(facing originFromHead: simd_float4x4) -> simd_float4x4 {
        let p = originFromHead.columns.3
        var forward = -SIMD3<Float>(originFromHead.columns.2.x, 0, originFromHead.columns.2.z)
        if length(forward) < 1e-3 { forward = SIMD3(0, 0, -1) }
        forward = normalize(forward)
        let yaw = atan2(-forward.x, -forward.z)
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(p.x, 0, p.z, 1)
        return m
    }

    // MARK: - 渲染循环

    private func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                Self.log.info("Layer invalidated")
                wind?.stop()
                Task { @MainActor in AppModel.shared.fallEnded() }
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                lastFrameTime = nil      // 暂停的时间不算下落
                scene.resetHistory()
                continue
            }
            autoreleasepool {
                renderFrame()
            }
        }
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        let now = CACurrentMediaTime()
        let dt = lastFrameTime.map { min(now - $0, 0.1) } ?? 0
        lastFrameTime = now
        // 等对齐好头部朝向再开始掉（第一帧之前时间不走）
        if stageFromOrigin != nil {
            simulation.step(dt * DebugOptions.timeScale)
        }
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        _ = inFlight.wait(timeout: .distantFuture)
        frame.startSubmission()

        let presentation = LayerRenderer.Clock.Instant.epoch.duration(to: drawables[0].frameTiming.presentationTime)
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: presentation.timeInterval)
        let originFromDevice = Self.headPose(deviceAnchor) * DebugOptions.headRotation

        // 系统 ImmersiveSpace 原点的朝向不一定是你看的方向，按第一帧的头部位姿把太阳和高度表摆好
        if stageFromOrigin == nil, deviceAnchor != nil || Self.isSimulator {
            stageFromOrigin = Self.stage(facing: originFromDevice).inverse
            eyeHeight = ((stageFromOrigin ?? matrix_identity_float4x4) * originFromDevice).columns.3.y
        }
        let stageFromDevice = (stageFromOrigin ?? matrix_identity_float4x4) * originFromDevice
        let headY = stageFromDevice.columns.3.y

        var uniforms = FrameUniforms()
        let stageToAltitude = Float(simulation.altitude) - eyeHeight
        uniforms.camera = SIMD4(stageToAltitude, Float(simulation.time), Float(simulation.brightness), 0)
        // 你随风漂，海面相对你往后退（云也随风漂，相对你不动）
        uniforms.ground = SIMD4(Float(simulation.time) * 6, 0, 0, 0)
        // 高度表：起跳时头前方 0.5 米、低 0.3 米，面朝眼睛
        let center = SIMD3<Float>(0, eyeHeight - 0.30, -0.50)
        let toEye = normalize(SIMD3<Float>(0, eyeHeight, 0) - center)
        let right = SIMD3<Float>(1, 0, 0)
        uniforms.hudCenter = SIMD4(center, 0.15)
        uniforms.hudRight = SIMD4(right, 0.05)
        uniforms.hudUp = SIMD4(cross(toEye, right), 1)
        uniforms.hudGlyphs = FrameUniforms.glyphs(feet: simulation.altitudeFeet)

#if DEBUG || targetEnvironment(simulator)
        frameCount += 1
        if frameCount % 90 == 0 {
            Self.log.notice("t=\(self.simulation.time, format: .fixed(precision: 1)) alt=\(self.simulation.altitude, format: .fixed(precision: 0)) v=\(self.simulation.velocity, format: .fixed(precision: 1)) anchor=\(deviceAnchor != nil) drawables=\(drawables.count) views=\(drawables[0].views.count) color=\(drawables[0].colorTextures[0].width)x\(drawables[0].colorTextures[0].height) rateMaps=\(drawables[0].rasterizationRateMaps.count)")
        }
#endif

        for (index, drawable) in drawables.enumerated() {
            guard let commandBuffer = queue.makeCommandBuffer() else {
                fatalError("无法创建 command buffer")
            }
            drawable.deviceAnchor = deviceAnchor
            if index == 0 {
                scene.encodeSky(commandBuffer, altitude: stageToAltitude + headY)
            }
            if index == drawables.count - 1 {
                let semaphore = inFlight
                let gpuTimes = self.gpuTimes
                commandBuffer.addCompletedHandler { cb in
                    let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    if ms > 0, ms < 100 {
                        gpuTimes.withLock {
                            $0.append(ms)
                            if $0.count > 90 { $0.removeFirst($0.count - 90) }
                        }
                    }
                    semaphore.signal()
                }
            }

            // 按目标纹理分组：分层布局（开注视点渲染时）两只眼在同一张纹理数组的两层里，一组画完；
            // 独立布局每只眼一张纹理，各成一组。组内第 i 个视图对应第 i 层、第 i 个视口。
            let groups = Dictionary(grouping: drawable.views.indices, by: { drawable.views[$0].textureMap.textureIndex })
            for textureIndex in groups.keys.sorted() {
                let viewIndices = groups[textureIndex]!
                var views: [ViewUniforms] = []
                var viewports: [MTLViewport] = []
                for viewIndex in viewIndices {
                    let view = drawable.views[viewIndex]
                    let stageFromCamera = stageFromDevice * view.transform
                    let viewProjection = drawable.computeProjection(viewIndex: viewIndex) * stageFromCamera.inverse
                    let vp = view.textureMap.viewport
                    views.append(ViewUniforms(viewProjection: viewProjection,
                                              inverseViewProjection: viewProjection.inverse,
                                              cameraPosition: stageFromCamera.columns.3,
                                              viewport: SIMD4(Float(vp.originX), Float(vp.originY),
                                                              Float(vp.width), Float(vp.height))))
                    viewports.append(vp)
                }
                let rateMaps = drawable.rasterizationRateMaps
                let rateMap = rateMaps.isEmpty ? nil : rateMaps[min(textureIndex, rateMaps.count - 1)]
                scene.encode(commandBuffer,
                             views: views,
                             viewports: viewports,
                             frame: uniforms,
                             colorTexture: drawable.colorTextures[textureIndex],
                             depthTexture: drawable.depthTextures[textureIndex],
                             renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? viewIndices.count : 1,
                             rateMap: rateMap,
                             group: textureIndex)
            }

            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }

        frame.endSubmission()

        adjustQuality(now: now)
        wind?.update(speed: Float(simulation.velocity), gain: Float(simulation.brightness))
        if simulation.isOver, !ended {
            ended = true
            wind?.stop()
            Task { @MainActor in AppModel.shared.fallEnded() }
        }
    }

    /// 自动画质：90 Hz 一帧 11.1 ms，系统合成还要用一些 GPU，给自己留 7 ms。
    /// 超了就降一档（云层分辨率 / 步长），很宽裕时再慢慢升回来。换档会重置云层历史，所以不频繁换。
    private func adjustQuality(now: CFTimeInterval) {
        let recent = gpuTimes.withLock { Array($0.suffix(45)) }
        guard recent.count >= 30 else { return }
        let average = recent.reduce(0, +) / Double(recent.count)
        if now - lastStatsLog > 2 {
            lastStatsLog = now
            Self.log.notice("GPU \(average, format: .fixed(precision: 2)) ms/帧，画质档位 \(self.qualityLevel)")
        }
        let maxLevel = SceneRenderer.qualityLevels.count - 1
        if average > 7.0, qualityLevel < maxLevel, now - lastQualityChange > 1.5 {
            qualityLevel += 1
        } else if average < 4.0, qualityLevel > 0, now - lastQualityChange > 5 {
            qualityLevel -= 1
        } else {
            return
        }
        lastQualityChange = now
        scene.setQuality(qualityLevel)
        gpuTimes.withLock { $0.removeAll() }
        Self.log.notice("画质换到 \(self.qualityLevel) 档（GPU 平均 \(average, format: .fixed(precision: 2)) ms）")
    }

    private static var isSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + nanoseconds / TimeInterval(NSEC_PER_SEC)
    }
}

/// 让渲染循环跑在自己的高优先级串行队列上（同 MetalSplatter 示例）。
final class RendererTaskExecutor: TaskExecutor {
    static let shared = RendererTaskExecutor()
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
