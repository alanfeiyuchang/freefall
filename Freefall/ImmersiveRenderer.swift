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
    private var revealSent = false
    private var deploySent = false
    private var landingSent = false
    private var resultSent = false

    /// 最近每帧的 GPU 耗时（毫秒），command buffer 完成时写入
    private let gpuTimes = OSAllocatedUnfairLock(initialState: [Double]())
    private var qualityLevel = 0
    private var lastQualityChange: CFTimeInterval = 0
    private var lastStatsLog: CFTimeInterval = 0

    init(_ layerRenderer: LayerRenderer, handsEnabled: Bool, watchOnLeft: Bool, gloves: Bool, snapTurns: Bool,
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
                                  queue: queue, scene: jumpScene, gloveDirectory: Bundle.main.resourceURL)
        panel = TextPanel(device: device)
        helmet = HelmetHUD(device: device)
        audio = DebugOptions.mute ? nil : JumpAudio()
        session = JumpSession(timeline: DebugOptions.startAltitude.map { JumpTimeline(freefallFrom: $0, scene: jumpScene) }
                                  ?? JumpTimeline(scene: jumpScene),
                              realHands: self.handsEnabled,
                              autopilot: DebugOptions.autopilot ? Autopilot(deployFeet: DebugOptions.autoDeployFeet) : nil)
        session.snapTurns = snapTurns
    }

    @MainActor
    static func start(_ layerRenderer: LayerRenderer, handsEnabled: Bool, watchOnLeft: Bool, gloves: Bool,
                      snapTurns: Bool, scene: JumpScene) {
        let renderer: ImmersiveRenderer
        do {
            renderer = try ImmersiveRenderer(layerRenderer, handsEnabled: handsEnabled, watchOnLeft: watchOnLeft,
                                             gloves: gloves, snapTurns: snapTurns, jumpScene: scene)
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
            if let l = Self.handPose(left, stageFromOrigin: stage) { hands.append(l) }
            if let r = Self.handPose(right, stageFromOrigin: stage) { hands.append(r) }
        }

        // 身体（肩带、拉环、操纵环）：朝向按头和两只手猜（伞下锁正前方）；位置跟着脖子走，
        // 只转头的时候眼睛绕着脖子转，身体不跟着平移
        let underCanopy = timeline.phase == .opening || timeline.phase == .canopy
        let yaw = bodyYaw.update(head: head, headForward: headForward, hands: hands, dt: Float(dt), locked: underCanopy)
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
        // 转弯时视野四周收窄压暗（转向是世界绕着你转，余光里的转动最容易晕）；分段转向不连续转，不用压
        let turning = Float(min(abs(timeline.turnRate) / JumpTimeline.maxTurnRate, 1))
        let heading = session.displayHeading
        uniforms.heading = SIMD4(Float(cos(heading)), Float(sin(heading)), session.snapTurns ? 0 : turning * 0.85, 0)
        // 高度表：有手部追踪就戴在选好的那只手腕上（手放下时看不到，抬手才看）；没有就放在前下方
        let watchHand = hands.first(where: { $0.isLeft == watchOnLeft })
        uniforms.placeAltimeter(feet: timeline.altitudeFeet, eyeHeight: eyeHeight, watchHand: watchHand,
                                alarm: timeline.alarmLevel, gloved: gloves)
        if handsEnabled && watchHand == nil { uniforms.hudUp.w = 0 }
        let objects = session.objects(layout: layout, hands: hands, watchOnLeft: watchOnLeft, gloves: gloves, head: head)
        let hudState = session.hudState
        let hudPanels = helmet.update(hudState, head: stageFromDevice)
        var hudDirty = helmet.dirty
        panel.set(hudPanels.isEmpty ? session.hint : "")
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
                scene.encode(commandBuffer,
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
        audioParams.birds = (t.scene == .grassland || t.scene == .alpine) ? (t.phase == .landed ? 1 : low) : 0
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
