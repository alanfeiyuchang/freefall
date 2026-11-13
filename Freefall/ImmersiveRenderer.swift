import ARKit
import CompositorServices
import Metal
import os
import QuartzCore
import simd
import SwiftUI

// 渲染循环的骨架来自 Bubble Dream（再往上是 MetalSplatter 的 visionOS 示例，MIT，© Sean Cier）。

/// 每帧：拿头和手的位姿 → 手的抓握 / 捏合推动时间线、伞衣布料 → 天空视图表 →
/// 每个 drawable 画云层 + 天空海面 + 飞机 / 伞 / 背带 / 表带 + 高度表 + 提示文字。
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
    private let handTracking = HandTrackingProvider()
    /// 允许了手部追踪：用真手抓；否则用系统的捏合手势操作
    private let handsEnabled: Bool
    private let watchOnLeft: Bool
    /// 戴手套：真手藏起来（FreefallApp 里 upperLimbVisibility = hidden），画手套和跳伞服袖子
    private let gloves: Bool
    private let inFlight = DispatchSemaphore(value: maxFramesInFlight)
    private let audio: JumpAudio?
    /// 系统捏合手势：主线程上来，渲染线程每帧取
    private let pinches = OSAllocatedUnfairLock(initialState: PinchState())

    private let session: JumpSession
    private var timeline: JumpTimeline { session.timeline }
    private let panel: TextPanel
    private var panelPlacer = PanelPlacer()
    /// 头盔 HUD（开机以后提示文字也在它下沿，前面那块浮动面板只在开机以前用）
    private let helmet: HelmetHUD
    private var lastFrameTime: CFTimeInterval?
    /// ImmersiveSpace 原点 → 舞台（跳的那一刻脚下、面朝的方向）。拿到头部位姿的第一帧定下来。
    private var stageFromOrigin: simd_float4x4?
    /// 舞台空间里起跳那一刻眼睛的高度：海拔就对准这个高度
    private var eyeHeight = fallbackEyeHeight
    private var ended = false
    private var frameCount = 0

    // 声音：一次性的事件按状态变化触发
    private var audioParams = JumpAudio.Params()
    private var wasHoldingBar = false
    private var grabsHeard = 0
    private var dingSent = false
    private var bodyYaw = BodyYaw()
    /// 每只手最后一次追踪到的姿势和时刻。一只手伸到另一只小臂上（拉拉环）时两只手在摄像头里叠在一起，
    /// ARKit 会把被挡住的那只丢掉一阵：手套、拉环跟着一起消失，第一下就拉不到。丢了以后先按最后的姿势留着
    private var lastHands: [Bool: (pose: HandPose, time: CFTimeInterval)] = [:]
    private var tapsHeard = 0
    private var ringsHeard = 0
    private var revealSent = false
    private var deploySent = false
    private var landingSent = false
    private var resultSent = false

    /// 最近每帧的 GPU 耗时（毫秒），command buffer 完成时写入
    private let gpuTimes = OSAllocatedUnfairLock(initialState: [Double]())
    private var qualityLevel = 0
    private var lastQualityChange: CFTimeInterval = 0
    private var lastQualityRaise: CFTimeInterval = -100
    private var raiseBackoffUntil: CFTimeInterval = 0
    private var lastStatsLog: CFTimeInterval = 0

#if DEV_TOOLS
    // 性能测试（开始窗口里打开）：从出舱到落地，一遍一遍轮流关掉画面的各个部分，每种 1.6 秒，量 GPU 一帧的耗时和帧率
    // （一遍约 20 秒：高空、穿云、出云、伞下各能量到一两遍）。结果一行行打到标准输出（从 Mac 用 devicectl --console
    // 启动应用就能收到），也存进 Documents/perf.txt、显示在开始窗口里。测的时候自动画质停掉。
    private var perfTest = false
    private var benchIndex = -1
    private var benchStart: CFTimeInterval = 0
    private var benchFrames = 0
    private var benchCycle = 0
    private var benchText = ""
    private var benchFinished = false
    private static let benchConfigs: [(name: String, flags: Int, scale: Float, cloudScale: Float, cloudStep: Float)] = [
        ("基准", 0, 1, 0.5, 1),
        ("不用光照缓存（现算）", 4096, 1, 0.5, 1),
        ("地形不着色", 2, 1, 0.5, 1),
        ("地表函数换成常数", 128, 1, 0.5, 1),
        ("不采两层细节噪声", 256, 1, 0.5, 1),
        ("不采树冠噪声", 512, 1, 0.5, 1),
        ("不算伞和人的影子", 1024, 1, 0.5, 1),
        ("不算空气透视", 2048, 1, 0.5, 1),
        ("地表常数+无细节+无树冠+无影子+无透视", 128 | 256 | 512 | 1024 | 2048, 1, 0.5, 1),
        ("云不步进", 1, 1, 0.5, 1),
        ("云最低档", 0, 1, 0.36, 1.7),
        ("云和地形都不着色", 1 | 2, 1, 0.5, 1),
    ]

    private func benchEmit(_ line: String) {
        print("PERF " + line)
        fflush(stdout)
        benchText += line + "\n"
    }

    private func benchSave() {
        guard !benchText.isEmpty,
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("perf.txt")
        try? benchText.write(to: url, atomically: true, encoding: .utf8)
        let text = benchText
        let finished = benchFinished
        Task { @MainActor in
            AppModel.shared.perfReport = text
            // 只测这一跳：测完自己关掉。之前选上以后一直开着，后面每一跳都在轮流关云、换云的档位（云一段段变糊、漏洞）
            if finished { AppModel.shared.perfTest = false }
        }
    }

    /// 返回要显示的提示（测试进行中），没有就 nil
    private func runBenchmark(now: CFTimeInterval) -> String? {
        guard perfTest, !benchFinished else { return nil }
        let phase = timeline.phase
        if phase == .landed || phase == .done {
            benchFinished = true
            scene.settings.debugFlags = 0
            scene.setQuality(qualityLevel)
            benchEmit("END")
            benchSave()
            return nil
        }
        guard phase == .freefall || phase == .opening || phase == .canopy else { return nil }
        if benchIndex < 0 {
            benchIndex = 0
            benchStart = 0
            benchEmit("START 场景 \(scene.scene) \(Date())")
        }
        let config = Self.benchConfigs[benchIndex]
        if benchStart == 0 {
            benchStart = now
            benchFrames = 0
            scene.settings.debugFlags = config.flags
            scene.settings.renderScale = config.scale
            scene.settings.cloudScale = config.cloudScale
            scene.settings.cloudStep = config.cloudStep
        }
        let elapsed = now - benchStart
        if elapsed < 0.5 {
            gpuTimes.withLock { $0.removeAll() }       // 换配置后的头半秒不算
            benchFrames = 0
        } else {
            benchFrames += 1
        }
        if elapsed >= 1.6 {
            let samples = gpuTimes.withLock { $0 }
            let gpu = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
            let fps = Double(benchFrames) / (elapsed - 0.5)
            benchEmit(String(format: "%d|%@|离地%.0f|雨%.2f|%@|gpu %.2f|fps %.0f", benchCycle, String(describing: phase),
                             timeline.heightAboveGround, timeline.rainIntensity, config.name, gpu, fps))
            benchIndex += 1
            benchStart = 0
            if benchIndex >= Self.benchConfigs.count {
                benchIndex = 0
                benchCycle += 1
                benchSave()
            }
        }
        return "性能测试 第 \(benchCycle + 1) 遍 \(benchIndex + 1) / \(Self.benchConfigs.count)\n往下看着地面（画面一段一段变是正常的）"
    }
#endif
    private static func qualityKey(_ scene: JumpScene) -> String { "qualityLevel.\(scene.rawValue)" }
    /// HUD 上的实时帧率：最近一秒里提交了几帧（每半秒更新一次显示的数）
    private var frameStamps: [CFTimeInterval] = []
    private var shownFPS = -1
    private var shownGPU: Float = 0
    private var lastFPSUpdate: CFTimeInterval = 0

    init(_ layerRenderer: LayerRenderer, handsEnabled: Bool, watchOnLeft: Bool, gloves: Bool, toggleSteering: Bool,
         perfTest: Bool = false,
         jumpScene: JumpScene) throws {
        self.layerRenderer = layerRenderer
        self.handsEnabled = handsEnabled && HandTrackingProvider.isSupported
        self.watchOnLeft = watchOnLeft
        self.gloves = gloves
        device = layerRenderer.device
        queue = device.makeCommandQueue()!
        guard let library = device.makeDefaultLibrary() else {
            throw SceneRenderer.RendererError.missingFunction("default library")
        }
        scene = try SceneRenderer(device: device, library: library,
                                  colorFormat: layerRenderer.configuration.colorFormat,
                                  depthFormat: layerRenderer.configuration.depthFormat,
                                  maxViewCount: layerRenderer.properties.viewCount,
                                  queue: queue, scene: jumpScene, gloveDirectory: Bundle.main.resourceURL,
                                  barOnLeft: !watchOnLeft)
        // 从上一跳这一关用到的画质档位开始（回退一档试试能不能更好）
        qualityLevel = max(0, min(UserDefaults.standard.integer(forKey: Self.qualityKey(jumpScene)) - 1,
                                  SceneRenderer.maxAutoQuality))
        scene.setQuality(qualityLevel)
        panel = TextPanel(device: device)
        helmet = HelmetHUD(device: device)
        audio = DebugOptions.mute ? nil : JumpAudio()
        session = JumpSession(timeline: DebugOptions.startAltitude.map { JumpTimeline(freefallFrom: $0, scene: jumpScene) }
                                  ?? JumpTimeline(scene: jumpScene),
                              realHands: self.handsEnabled,
                              autopilot: DebugOptions.autopilot ? Autopilot(deployFeet: DebugOptions.autoDeployFeet) : nil)
        session.gloved = gloves
        session.watchOnLeft = watchOnLeft
        // 拉环转向按开始窗口里的选项（默认关）；自动驾驶靠拉环转向，一直开
        session.toggleSteering = toggleSteering || DebugOptions.autopilot
#if DEV_TOOLS
        self.perfTest = perfTest
#endif
    }

    @MainActor
    static func start(_ layerRenderer: LayerRenderer, handsEnabled: Bool, watchOnLeft: Bool, gloves: Bool, toggleSteering: Bool,
                      perfTest: Bool = false,
                      scene: JumpScene) {
        let renderer: ImmersiveRenderer
        do {
            renderer = try ImmersiveRenderer(layerRenderer, handsEnabled: handsEnabled, watchOnLeft: watchOnLeft,
                                             gloves: gloves, toggleSteering: toggleSteering, perfTest: perfTest, jumpScene: scene)
        } catch {
            log.error("无法创建渲染器：\(error.localizedDescription)")
            return
        }
        layerRenderer.onSpatialEvent = { [pinches = renderer.pinches] events in
            // 事件不是 Sendable，先拆成简单的值再进锁
            let updates = events.map { event in
                (id: event.id.hashValue, isLeft: event.chirality == .left,
                 y: event.inputDevicePose?.pose3D.position.y ?? 0, active: event.phase == .active)
            }
            pinches.withLock { s in
                for u in updates {
                    if u.active {
                        var touch = s.touches[u.id] ?? PinchState.Touch(isLeft: u.isLeft, startY: u.y)
                        if s.touches[u.id] == nil { s.began += 1 }
                        touch.pull = max(0, touch.startY - u.y)
                        s.touches[u.id] = touch
                    } else {
                        s.touches[u.id] = nil
                    }
                }
            }
        }
        Task(executorPreference: RendererTaskExecutor.shared) {
            do {
                var providers: [any DataProvider] = [renderer.worldTracking]
                if renderer.handsEnabled { providers.append(renderer.handTracking) }
                try await renderer.arSession.run(providers)
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

    /// ARKit 的手 → 舞台空间里的 27 个关节
    private static func handPose(_ anchor: HandAnchor?, stageFromOrigin: simd_float4x4) -> HandPose? {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let stageFromAnchor = stageFromOrigin * anchor.originFromAnchorTransform
        var joints = [SIMD3<Float>](repeating: .zero, count: HandJoint.allCases.count)
        for joint in HandJoint.allCases {
            let m = stageFromAnchor * skeleton.joint(joint.arkitName).anchorFromJointTransform
            joints[joint.rawValue] = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        return HandPose(joints: joints, isLeft: anchor.chirality == .left)
    }

    // MARK: - 渲染循环

    private func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                Self.log.info("Layer invalidated")
                audio?.stop()
                let result = session.jumpResult
                Task { @MainActor in AppModel.shared.fallEnded(result: result) }
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                lastFrameTime = nil      // 暂停的时间不算
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

        // 系统 ImmersiveSpace 原点的朝向不一定是你看的方向，按第一帧的头部位姿把机舱、太阳、云摆好
        if stageFromOrigin == nil, deviceAnchor != nil || Self.isSimulator {
            stageFromOrigin = Self.stage(facing: originFromDevice).inverse
            eyeHeight = ((stageFromOrigin ?? matrix_identity_float4x4) * originFromDevice).columns.3.y
            session.setEyeHeight(eyeHeight)
        }
        let stage = stageFromOrigin ?? matrix_identity_float4x4
        let stageFromDevice = stage * originFromDevice
        let head = stageFromDevice.columns.3.xyz
        let headForward = -stageFromDevice.columns.2.xyz

        // 手：按这一帧显示的时刻预测，抓杆、表才跟得上手
        var hands: [HandPose] = []
        if handsEnabled, handTracking.state == .running {
            let (left, right) = handTracking.handAnchors(at: presentation.timeInterval)
            for (isLeft, anchor) in [(true, left), (false, right)] {
                if let pose = Self.handPose(anchor, stageFromOrigin: stage) {
                    lastHands[isLeft] = (pose, now)
                    hands.append(pose)
                } else if let last = lastHands[isLeft] {
                    // 挂着拉环的那只小臂在自由落体时多留一会儿（另一只手正盖在上面拉）；别的情况留一秒
                    let ringArm = isLeft != watchOnLeft && timeline.phase == .freefall
                    if now - last.time < (ringArm ? 4.0 : 1.0) { hands.append(last.pose) }
                }
            }
        }

        // 身体（操纵环、连接环）：朝向按头和两只手猜；位置跟着脖子走，
        // 只转头的时候眼睛绕着脖子转，身体不跟着平移
        // 伞下也跟着人转：人在椅子上转过去，伞、操纵环跟着转到正前方，飞的方向也跟着变
        let underCanopy = timeline.phase == .opening || timeline.phase == .canopy
        let yaw = bodyYaw.update(head: head, headForward: headForward, hands: hands, dt: Float(dt), locked: false,
                                 canopy: underCanopy)
        var flatForward = SIMD3<Float>(headForward.x, 0, headForward.z)
        flatForward = length(flatForward) > 1e-3 ? normalize(flatForward) : SIMD3(0, 0, -1)
        let neck = SIMD3<Float>(head.x, eyeHeight, head.z) - flatForward * 0.09
        let bodyForward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
        let layout = BodyLayout(anchor: neck + bodyForward * 0.09, yaw: yaw)
        // 等对齐好头部朝向再开始（第一帧之前时间不走）
        if stageFromOrigin != nil {
            let (began, touches) = pinches.withLock { s -> (Int, [PinchState.Touch]) in
                let b = s.began
                s.began = 0
                return (b, Array(s.touches.values))
            }
            session.step(dt: dt * DebugOptions.timeScale, hands: hands, pinchesBegan: began, touches: touches,
                         layout: layout)
        }

        var uniforms = FrameUniforms()
        let stageToAltitude = Float(timeline.altitude) - eyeHeight
        uniforms.camera = SIMD4(stageToAltitude, Float(timeline.time), Float(timeline.brightness), 0)
        uniforms.ground = SIMD4(Float(timeline.position.x), Float(timeline.landShift.x),
                                Float(timeline.position.y), Float(timeline.landShift.y))
        // 转弯时视野四周收窄压暗（转向是世界绕着你转，余光里的转动最容易晕）
        let turning = Float(min(abs(timeline.turnRate) / JumpTimeline.maxTurnRate, 1))
        let heading = session.displayHeading
        uniforms.heading = SIMD4(Float(cos(heading)), Float(sin(heading)), turning * 0.85, 0)
        // 高度表：有手部追踪就戴在选好的那只手腕上（手放下时看不到，抬手才看）；没有就放在前下方
        let watchHand = hands.first(where: { $0.isLeft == watchOnLeft })
        uniforms.placeAltimeter(feet: timeline.altitudeFeet, eyeHeight: eyeHeight, watchHand: watchHand,
                                alarm: timeline.alarmLevel, gloved: gloves,
                                go: timeline.phase == .cabin && timeline.greenLight)
        if handsEnabled && watchHand == nil { uniforms.hudUp.w = 0 }
        let objects = session.objects(layout: layout, hands: hands, watchOnLeft: watchOnLeft,
                                      gloves: gloves, head: head)
        var hudState = session.hudState
#if DEV_TOOLS
        if let note = runBenchmark(now: now) {
            hudState.hint = note
            if hudState.hintBoot < 0 { hudState.hintBoot = 1 }
        }
#endif
        frameStamps.append(now)
        if let first = frameStamps.firstIndex(where: { now - $0 <= 1 }), first > 0 { frameStamps.removeFirst(first) }
        if now - lastFPSUpdate > 0.5, frameStamps.count >= 2, let oldest = frameStamps.first, now - oldest > 0.3 {
            lastFPSUpdate = now
            shownFPS = Int((Double(frameStamps.count - 1) / (now - oldest)).rounded())
            let recent = gpuTimes.withLock { Array($0.suffix(45)) }
            if !recent.isEmpty { shownGPU = Float(recent.reduce(0, +) / Double(recent.count)) }
        }
#if DEV_TOOLS
        // HUD 右侧面板左上角的帧率、GPU 毫秒、画质档位（上架版不显示；帧率照样量，自动画质要用）
        hudState.fps = shownFPS
        hudState.gpuMs = shownGPU
        hudState.qualityLevel = qualityLevel
#endif
        let hudPanels = helmet.update(hudState, head: stageFromDevice)
        var hudDirty = helmet.dirty
        // 提示都在头盔 HUD 的下沿（HUD 关着时只有舱里开场的提示），老的浮动面板不用了
        panel.set("")
        let panelDraw = panel.texture.map {
            (texture: $0, uniforms: panelPlacer.place(head: head, forward: headForward, dt: Float(dt),
                                                      width: $0.width, height: $0.height))
        }

#if DEBUG || targetEnvironment(simulator)
        frameCount += 1
        if frameCount % 90 == 0 {
            Self.log.notice("t=\(self.timeline.time, format: .fixed(precision: 1)) \(String(describing: self.timeline.phase)) alt=\(self.timeline.altitude, format: .fixed(precision: 0)) v=\(self.timeline.verticalSpeed, format: .fixed(precision: 1)) hands=\(hands.count) anchor=\(deviceAnchor != nil) views=\(drawables[0].views.count) color=\(drawables[0].colorTextures[0].width)x\(drawables[0].colorTextures[0].height) rateMaps=\(drawables[0].rasterizationRateMaps.count)")
        }
#endif

        for (index, drawable) in drawables.enumerated() {
            guard let commandBuffer = queue.makeCommandBuffer() else {
                fatalError("无法创建 command buffer")
            }
            drawable.deviceAnchor = deviceAnchor
            if index == 0 {
                scene.encodeSky(commandBuffer, altitude: stageToAltitude + head.y)
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
                scene.encodeScaled(commandBuffer,
                             views: views,
                             viewports: viewports,
                             frame: uniforms,
                             colorTexture: drawable.colorTextures[textureIndex],
                             depthTexture: drawable.depthTextures[textureIndex],
                             renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? viewIndices.count : 1,
                             rateMap: rateMap,
                             objects: objects,
                             panel: panelDraw,
                             hud: hudPanels, hudDirty: hudDirty,
                             group: textureIndex)
                hudDirty = []           // mip 只生成一次
            }

            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }

        frame.endSubmission()

        adjustQuality(now: now)
        updateRealHands()
        updateAudio()
        if timeline.isOver, !ended {
            ended = true
            audio?.stop()
            let result = session.jumpResult
            Task { @MainActor in AppModel.shared.fallEnded(result: result) }
        }
    }

    // MARK: - 声音

    /// 戴手套时，握住扶杆（手套开始长出来）以后把真手藏起来
    private var handsHiddenSent = false

    private func updateRealHands() {
        guard gloves, handsEnabled, !handsHiddenSent, timeline.barGrabbedTime != nil else { return }
        handsHiddenSent = true
        Task { @MainActor in AppModel.shared.realHandsHidden = true }
    }

    private func updateAudio() {
        guard let audio else { return }
        let t = timeline
        if t.holdingBar && !wasHoldingBar { audioParams.grabs += 1 }
        wasHoldingBar = t.holdingBar
        audioParams.grabs += session.grabs - grabsHeard        // 抓住拉手、操纵环
        grabsHeard = session.grabs
        audioParams.taps += session.watchTaps - tapsHeard        // 点表开关 HUD
        tapsHeard = session.watchTaps
        audioParams.chimes += t.ringsPassed - ringsHeard        // 穿过一个光环
        ringsHeard = t.ringsPassed
        if t.barGrabbedTime != nil && !revealSent {        // 握住扶杆：飞机开始长出来
            revealSent = true
            audioParams.reveals += 1
        }
        if t.greenLight && !dingSent {                     // 绿灯
            dingSent = true
            audioParams.dings += 1
        }
        if t.deployTime != nil && !deploySent {            // 拉手撕开 + 开伞
            deploySent = true
            audioParams.rips += 1
            audioParams.deploys += 1
        }
        if let landedTime = t.landedTime, let outcome = t.outcome {
            if !landingSent {
                landingSent = true
                switch outcome {
                case .crashed: audioParams.crashes += 1
                case .water: audioParams.splashes += 1
                default: audioParams.thuds += 1
                }
            }
            if !resultSent, t.time - landedTime > 0.7 {
                resultSent = true
                if t.won { audioParams.wins += 1 } else { audioParams.fails += 1 }
            }
        }
        let underCanopy = t.phase == .opening || t.phase == .canopy
        // 开场还在房间里：没有发动机、没有风。握住扶杆以后很快响起来，但先是闷的（像隔着墙），
        // 飞机长出来的那几秒里慢慢变清楚
        let p = Float(t.revealProgress)
        let rise = min(p / 0.4, 1)
        let cabinLevel = t.phase == .cabin ? rise * rise * (3 - 2 * rise) : 1
        audioParams.muffle = t.phase == .cabin ? 1 - p * p * (3 - 2 * p) : 0
        audioParams.speed = Float(t.windSpeed) * cabinLevel
        audioParams.gain = Float(t.brightness)
        audioParams.engine = (t.leftRampTime == nil ? 1 : Float(25 / (25 + t.planeDistance))) * cabinLevel
        audioParams.alarm = t.alarmLevel
        audioParams.canopy = underCanopy ? 1 : 0
        // 海浪和海鸥：伞下离地 300 米以内渐渐听到，落地以后最响（只有海边的两关）
        let near = Float(min(max((300 - t.terrainClearance) / 250, 0), 1))
        let seaside: Float = t.scene == .atoll ? 1 : 0
        audioParams.ambience = (t.phase == .landed || t.phase == .done ? 1 : near) * seaside
        audioParams.turn = Float(min(abs(t.turnRate) / JumpTimeline.maxTurnRate, 1))
        audioParams.rain = Float(t.rainIntensity)
        // 草原、高山：离地 150 米以内听得到林子里的鸟；火山：离火山锥 3 km 以内越来越响的轰鸣
        let low = Float(min(max((150 - t.terrainClearance) / 120, 0), 1))
        audioParams.birds = (t.scene == .grassland || t.scene == .alpine || t.scene == .sky)
            ? (t.phase == .landed ? 1 : low) : 0
        if t.scene == .volcano {
            let d = Float(length(t.groundPosition - SIMD2<Double>(TerrainField.coneCenter)))
            audioParams.rumble = 1 - min(max((d - 400) / 2600, 0), 1)
        } else {
            audioParams.rumble = 0
        }
        audio.update(audioParams)
    }

    /// 自动画质：90 Hz 一帧 11.1 ms，系统合成还要用一些 GPU，给自己留 7 ms。
    /// 超了就降一档（云层分辨率 / 步长），很宽裕时再慢慢升回来。换档会重置云层历史，所以不频繁换。
    private func adjustQuality(now: CFTimeInterval) {
        let recent = gpuTimes.withLock { Array($0.suffix(45)) }
        guard recent.count >= 30 else { return }
        let average = recent.reduce(0, +) / Double(recent.count)
#if DEV_TOOLS
        if now - lastStatsLog > 2 {
            lastStatsLog = now
            Self.log.notice("GPU \(average, format: .fixed(precision: 2)) ms/帧，画质档位 \(self.qualityLevel)")
        }
        // 性能测试进行中不自动换档（它自己在换配置）
        if perfTest, benchIndex >= 0, !benchFinished { return }
#endif
        let maxLevel = min(SceneRenderer.qualityLevels.count - 1, SceneRenderer.maxAutoQuality)
        // 按实际帧率换档（头显上量过：GPU 这个读数到 14 毫秒上下还是满 90 帧，之前按「超过 7 毫秒就降」，
        // 等于永远压在最低档）。掉到 86 帧以下降一档云；满帧、GPU 还有余量时试着升回去——
        // 升完又掉帧就降回来，并且半分钟内不再试（高空云多的那一段会这样）
        let slow = shownFPS >= 0 && shownFPS < 86
        let roomy = shownFPS >= 89 && average < 12.5
        if slow, qualityLevel < maxLevel, now - lastQualityChange > 1.2 {
            if now - lastQualityRaise < 8 { raiseBackoffUntil = now + 30 }
            qualityLevel += 1
        } else if roomy, qualityLevel > 0, now - lastQualityChange > 5, now > raiseBackoffUntil {
            qualityLevel -= 1
            lastQualityRaise = now
        } else {
            return
        }
        lastQualityChange = now
        // 记住这一关用到的档位：下一跳直接从这一档开始，不用每次开头再卡几秒慢慢降
        UserDefaults.standard.set(qualityLevel, forKey: Self.qualityKey(scene.scene))
        scene.setQuality(qualityLevel)
        gpuTimes.withLock { $0.removeAll() }
#if DEV_TOOLS
        Self.log.notice("画质换到 \(self.qualityLevel) 档（GPU 平均 \(average, format: .fixed(precision: 2)) ms）")
#endif
    }

    private static var isSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }
}

extension HandJoint {
    var arkitName: HandSkeleton.JointName {
        switch self {
        case .wrist: .wrist
        case .thumbKnuckle: .thumbKnuckle
        case .thumbIntermediateBase: .thumbIntermediateBase
        case .thumbIntermediateTip: .thumbIntermediateTip
        case .thumbTip: .thumbTip
        case .indexMetacarpal: .indexFingerMetacarpal
        case .indexKnuckle: .indexFingerKnuckle
        case .indexIntermediateBase: .indexFingerIntermediateBase
        case .indexIntermediateTip: .indexFingerIntermediateTip
        case .indexTip: .indexFingerTip
        case .middleMetacarpal: .middleFingerMetacarpal
        case .middleKnuckle: .middleFingerKnuckle
        case .middleIntermediateBase: .middleFingerIntermediateBase
        case .middleIntermediateTip: .middleFingerIntermediateTip
        case .middleTip: .middleFingerTip
        case .ringMetacarpal: .ringFingerMetacarpal
        case .ringKnuckle: .ringFingerKnuckle
        case .ringIntermediateBase: .ringFingerIntermediateBase
        case .ringIntermediateTip: .ringFingerIntermediateTip
        case .ringTip: .ringFingerTip
        case .littleMetacarpal: .littleFingerMetacarpal
        case .littleKnuckle: .littleFingerKnuckle
        case .littleIntermediateBase: .littleFingerIntermediateBase
        case .littleIntermediateTip: .littleFingerIntermediateTip
        case .littleTip: .littleFingerTip
        case .forearmWrist: .forearmWrist
        case .forearmArm: .forearmArm
        }
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
