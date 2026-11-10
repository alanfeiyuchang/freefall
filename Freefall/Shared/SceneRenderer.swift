import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// 画整片天：大气、体积云、海面、高度表。只依赖 Metal，Mac 上的离屏测试（tools/render-check）用的是同一份。
/// shader 见 Shaders/Freefall.metal。
final class SceneRenderer: @unchecked Sendable {
    struct Settings: Sendable {
        /// 云层 pass 相对实际渲染分辨率的比例（0.5 = 长宽各一半，像素数四分之一）
        var cloudScale: Float = 0.5
        /// 云的步长倍数，越大越快、越粗
        var cloudStep: Float = 1
        /// 云的消光系数（每米）：越大云越实、边越硬
        var cloudExtinction: Float = 0.035
        var coverageBias: Float = 0
        /// 大气外的太阳照度记为 1。白云大约 0.1~0.3，海平面的蓝天大约 0.02，像照片那样让天空落在中间调
        var exposure: Float = 8
    }

    /// 画质档位（真机上按 GPU 耗时自动升降，见 ImmersiveRenderer）。0 最好。
    static let qualityLevels: [(cloudScale: Float, cloudStep: Float)] = [
        (0.5, 1.0), (0.5, 1.35), (0.42, 1.35), (0.36, 1.7),
    ]

    func setQuality(_ level: Int) {
        let q = Self.qualityLevels[max(0, min(level, Self.qualityLevels.count - 1))]
        settings.cloudScale = q.cloudScale
        settings.cloudStep = q.cloudStep
    }

    /// 太阳：仰角 32°，在起跳那一刻你面朝方向的左前方 25°（迎光看云有亮边，回头看是顺光的白云）。
    static let sunDirection: SIMD3<Float> = {
        let elevation: Float = 32 * .pi / 180
        let azimuth: Float = -25 * .pi / 180
        return normalize(SIMD3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)))
    }()

    enum RendererError: Error { case missingFunction(String) }

    let device: MTLDevice
    var settings = Settings()

    let baseNoise: MTLTexture
    let detailNoise: MTLTexture
    let weather: MTLTexture
    let cloudShadow: MTLTexture
    let cloudTopMax: MTLTexture
    let atoll: MTLTexture
    private let transmittanceLUT: MTLTexture
    private let multiScatLUT: MTLTexture
    private let skyViewLUT: MTLTexture
    private let skySeaLUT: MTLTexture
    private let glyphAtlas: MTLTexture
    let atmosphereConstants: MTLBuffer

    private let skyViewPipeline: MTLComputePipelineState
    private let cloudFreshPipeline: MTLRenderPipelineState
    private let cloudResolvePipeline: MTLRenderPipelineState
    private let scenePipeline: MTLRenderPipelineState
    private let hudPipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let conePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let planeMesh: MTLBuffer
    private let planeVertexCount: Int
    /// 伞衣网格每帧由布料模拟重建：GPU 可能还在读前几帧的，轮流用几块
    private var canopyBuffers: [MTLBuffer] = []
    private var canopyBufferIndex = 0
    private static let maxCanopyVertices = 8000
    private let panelPipeline: MTLRenderPipelineState
    /// 背带和表带的胶囊，每帧重写；GPU 可能还在读前几帧的，轮流用
    private var coneBuffers: [MTLBuffer] = []
    private var coneBufferIndex = 0
    private static let maxCones = 160
    private let alwaysWriteDepth: MTLDepthStencilState
    private let nearerDepth: MTLDepthStencilState


    /// 没有 rate map 时绑给 shader 的占位缓冲（shader 不会读它）
    private let emptyRateMapBuffer: MTLBuffer
    /// rate map 参数缓冲的环：GPU 可能还在用前几帧的，轮流用
    private var rateMapBuffers: [MTLBuffer] = []
    private var rateMapBufferIndex = 0

    init(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
         maxViewCount: Int, queue: MTLCommandQueue) throws {
        self.device = device

        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return f
        }
        func texture(_ type: MTLTextureType, _ format: MTLPixelFormat, _ width: Int, _ height: Int,
                     _ depth: Int = 1) -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = type
            d.pixelFormat = format
            d.width = width
            d.height = height
            d.depth = depth
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        func renderPipeline(_ vertex: String, _ fragment: String, colors: [MTLPixelFormat],
                            depth: MTLPixelFormat, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = try function(vertex)
            d.fragmentFunction = try function(fragment)
            for (i, format) in colors.enumerated() {
                d.colorAttachments[i].pixelFormat = format
            }
            d.depthAttachmentPixelFormat = depth
            d.maxVertexAmplificationCount = maxViewCount
            d.inputPrimitiveTopology = .triangle
            if blend {   // 预乘 alpha，盖在上面
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        baseNoise = texture(.type3D, .rgba8Unorm, 128, 128, 128)
        detailNoise = texture(.type3D, .rgba8Unorm, 32, 32, 32)
        weather = texture(.type2D, .rgba8Unorm, 1024, 1024)
        cloudShadow = texture(.type2D, .r16Float, 2048, 2048)
        cloudTopMax = texture(.type2D, .r8Unorm, 256, 256)
        atoll = texture(.type2D, .rgba8Unorm, 2048, 2048)
        transmittanceLUT = texture(.type2D, .rgba16Float, 256, 64)
        multiScatLUT = texture(.type2D, .rgba16Float, 32, 32)
        skyViewLUT = texture(.type2D, .rgba16Float, 192, 108)
        skySeaLUT = texture(.type2D, .rgba16Float, 192, 108)
        glyphAtlas = Self.makeGlyphAtlas(device: device)
        atmosphereConstants = device.makeBuffer(length: atmosphereConstantsSize, options: .storageModePrivate)!
        emptyRateMapBuffer = device.makeBuffer(length: 256, options: .storageModeShared)!

        skyViewPipeline = try device.makeComputePipelineState(function: try function("computeSkyViewLUT"))
        cloudFreshPipeline = try renderPipeline("fullscreenVertex", "cloudFreshFragment",
                                                colors: [.rgba16Float, .r16Float], depth: .invalid, blend: false)
        cloudResolvePipeline = try renderPipeline("fullscreenVertex", "cloudResolveFragment",
                                                  colors: [.rgba16Float, .r16Float], depth: .invalid, blend: false)
        scenePipeline = try renderPipeline("fullscreenVertex", "sceneFragment", colors: [colorFormat],
                                           depth: depthFormat, blend: false)
        hudPipeline = try renderPipeline("hudVertex", "hudFragment", colors: [colorFormat],
                                         depth: depthFormat, blend: true)
        meshPipeline = try renderPipeline("meshVertex", "objectFragment", colors: [colorFormat],
                                          depth: depthFormat, blend: false)
        conePipeline = try renderPipeline("roundConeVertex", "objectFragment", colors: [colorFormat],
                                          depth: depthFormat, blend: false)
        let lineDescriptor = MTLRenderPipelineDescriptor()
        lineDescriptor.label = "lines"
        lineDescriptor.vertexFunction = try function("lineVertex")
        lineDescriptor.fragmentFunction = try function("lineFragment")
        lineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        lineDescriptor.depthAttachmentPixelFormat = depthFormat
        lineDescriptor.maxVertexAmplificationCount = maxViewCount
        lineDescriptor.inputPrimitiveTopology = .line
        linePipeline = try device.makeRenderPipelineState(descriptor: lineDescriptor)

        let plane = ProceduralMeshes.plane()
        planeVertexCount = plane.count
        planeMesh = device.makeBuffer(bytes: plane, length: MemoryLayout<MeshVertex>.stride * plane.count,
                                      options: .storageModeShared)!
        for _ in 0..<8 {
            canopyBuffers.append(device.makeBuffer(length: MemoryLayout<MeshVertex>.stride * Self.maxCanopyVertices,
                                                   options: .storageModeShared)!)
        }
        panelPipeline = try renderPipeline("panelVertex", "panelFragment", colors: [colorFormat],
                                           depth: depthFormat, blend: true)
        for _ in 0..<8 {
            coneBuffers.append(device.makeBuffer(length: MemoryLayout<RoundCone>.stride * Self.maxCones,
                                                 options: .storageModeShared)!)
        }

        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = true
        alwaysWriteDepth = device.makeDepthStencilState(descriptor: always)!
        let nearer = MTLDepthStencilDescriptor()
        nearer.depthCompareFunction = .greaterEqual     // reverse-Z
        nearer.isDepthWriteEnabled = true
        nearerDepth = device.makeDepthStencilState(descriptor: nearer)!

        try precompute(library: library, queue: queue)
    }

    // MARK: - 启动时一次

    private func precompute(library: MTLLibrary, queue: MTLCommandQueue) throws {
        func kernel(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
            return try device.makeComputePipelineState(function: f)
        }
        let cb = queue.makeCommandBuffer()!
        cb.label = "Freefall precompute"
        let enc = cb.makeComputeCommandEncoder()!   // 串行派发：前一个写完后一个才读
        var sun = SIMD4<Float>(Self.sunDirection, 0)

        enc.setTexture(baseNoise, index: 0)
        dispatch(enc, try kernel("generateBaseNoise"), MTLSize(width: 128, height: 128, depth: 128))
        enc.setTexture(detailNoise, index: 0)
        dispatch(enc, try kernel("generateDetailNoise"), MTLSize(width: 32, height: 32, depth: 32))
        enc.setTexture(weather, index: 0)
        dispatch(enc, try kernel("generateWeather"), MTLSize(width: 1024, height: 1024, depth: 1))

        enc.setTexture(atoll, index: 0)
        dispatch(enc, try kernel("generateAtoll"), MTLSize(width: 2048, height: 2048, depth: 1))

        enc.setTexture(cloudTopMax, index: 0)
        enc.setTexture(weather, index: 1)
        dispatch(enc, try kernel("computeCloudTopMax"), MTLSize(width: 256, height: 256, depth: 1))

        enc.setTexture(cloudShadow, index: 0)
        enc.setTexture(baseNoise, index: 1)
        enc.setTexture(weather, index: 2)
        enc.setBytes(&sun, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        dispatch(enc, try kernel("computeCloudShadow"), MTLSize(width: 2048, height: 2048, depth: 1))

        enc.setTexture(transmittanceLUT, index: 0)
        dispatch(enc, try kernel("computeTransmittanceLUT"), MTLSize(width: 256, height: 64, depth: 1))
        enc.setTexture(multiScatLUT, index: 0)
        enc.setTexture(transmittanceLUT, index: 1)
        dispatch(enc, try kernel("computeMultiScatLUT"), MTLSize(width: 32, height: 32, depth: 1))

        enc.setBuffer(atmosphereConstants, offset: 0, index: 0)
        enc.setBytes(&sun, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.setTexture(transmittanceLUT, index: 0)
        enc.setTexture(multiScatLUT, index: 1)
        dispatch(enc, try kernel("computeAtmosphereConstants"), MTLSize(width: 1, height: 1, depth: 1))

        encodeSkyView(enc, into: skySeaLUT, viewHeightKm: 6360.002)
        enc.endEncoding()
        cb.commit()
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ size: MTLSize) {
        enc.setComputePipelineState(pipeline)
        let group: MTLSize
        if size.depth > 1 {
            group = MTLSize(width: 8, height: 8, depth: 4)
        } else if size.height > 1 {
            group = MTLSize(width: 16, height: 16, depth: 1)
        } else {
            group = MTLSize(width: 1, height: 1, depth: 1)
        }
        enc.dispatchThreads(size, threadsPerThreadgroup: group)
    }

    private func encodeSkyView(_ enc: MTLComputeCommandEncoder, into target: MTLTexture, viewHeightKm: Float) {
        var sun = SIMD4<Float>(Self.sunDirection, 0)
        var height = viewHeightKm
        enc.setTexture(target, index: 0)
        enc.setTexture(transmittanceLUT, index: 1)
        enc.setTexture(multiScatLUT, index: 2)
        enc.setBytes(&sun, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setBytes(&height, length: MemoryLayout<Float>.stride, index: 1)
        dispatch(enc, skyViewPipeline, MTLSize(width: 192, height: 108, depth: 1))
    }

    // MARK: - 每帧

    /// 每帧一次（在画任何一只眼之前）：按头的海拔重算天空视图表。
    func encodeSky(_ commandBuffer: MTLCommandBuffer, altitude: Float) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "Sky view LUT"
        encodeSkyView(enc, into: skyViewLUT, viewHeightKm: 6360 + max(altitude, 1) / 1000)
        enc.endEncoding()
    }

    /// 补全 FrameUniforms 里由渲染器决定的字段（太阳、云和曝光设置）。
    func complete(_ frame: FrameUniforms) -> FrameUniforms {
        var f = frame
        f.sunDirection = SIMD4(Self.sunDirection, 0)
        f.clouds = SIMD4(settings.cloudScale, settings.cloudStep, settings.cloudExtinction, settings.coverageBias)
        f.exposure.x = settings.exposure
        return f
    }

    /// 云层的时间累积状态。每组视图（同一张目标纹理）一份：分层布局只有一组，独立布局每只眼一组。
    private final class CloudHistory {
        let width: Int, height: Int, layers: Int
        let fresh: MTLTexture          // 四分之一大小：这一帧新算的样本
        let freshDepth: MTLTexture
        let history: [MTLTexture]      // 云层分辨率，两张轮流（读上一帧、写这一帧）
        let depth: MTLTexture
        var current = 0
        var frameIndex: UInt32 = 0
        var previousViews: [ViewUniforms]?
        var previousState = SIMD4<Float>(0, 0, 0, 0)
        var previousRateMap: MTLBuffer?

        init(device: MTLDevice, width: Int, height: Int, layers: Int) {
            self.width = width
            self.height = height
            self.layers = layers
            func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
                let d = MTLTextureDescriptor()
                d.textureType = .type2DArray
                d.pixelFormat = format
                d.width = w
                d.height = h
                d.arrayLength = layers
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)!
            }
            let fw = (width + 1) / 2, fh = (height + 1) / 2
            fresh = make(.rgba16Float, fw, fh)
            freshDepth = make(.r16Float, fw, fh)
            history = [make(.rgba16Float, width, height), make(.rgba16Float, width, height)]
            depth = make(.r16Float, width, height)
        }
    }

    private var cloudHistories: [Int: CloudHistory] = [:]

    /// 丢掉云层的历史（比如暂停后继续：画面可能已经跳了）
    func resetHistory() {
        for h in cloudHistories.values { h.previousViews = nil }
    }

    /// 2×2 块里轮流重算的像素顺序（对角先走，四帧盖满一块）
    private static let pattern: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 1)]

    /// 画一组共用一张目标纹理的视图（分层布局：两只眼一组；独立布局：每只眼一组）。
    /// - Parameters:
    ///   - viewports: 主 pass 的视口（有 rate map 时是屏幕坐标）。
    ///   - renderTargetArrayLength: 分层布局 = 视图数，独立布局 = 1。
    ///   - group: 这组视图的编号（同一组每帧用同一个，云层历史按它存）。
    func encode(_ commandBuffer: MTLCommandBuffer,
                views: [ViewUniforms],
                viewports: [MTLViewport],
                frame: FrameUniforms,
                colorTexture: MTLTexture,
                depthTexture: MTLTexture,
                renderTargetArrayLength: Int,
                rateMap: MTLRasterizationRateMap?,
                objects: SceneObjects = SceneObjects(),
                panel: (texture: MTLTexture, uniforms: PanelUniforms)? = nil,
                group: Int = 0) {
        let viewCount = views.count
        var views = views
        var frame = complete(frame)
        frame.camera.w = rateMap == nil ? 0 : 1
        let rateBuffer = rateMap.map(rateMapBuffer(for:)) ?? emptyRateMapBuffer

        let cloudWidth = Int((Float(colorTexture.width) * settings.cloudScale).rounded(.up))
        let cloudHeight = Int((Float(colorTexture.height) * settings.cloudScale).rounded(.up))
        let layers = max(viewCount, 2)
        var state = cloudHistories[group]
        if state == nil || state!.width != cloudWidth || state!.height != cloudHeight || state!.layers < layers {
            state = CloudHistory(device: device, width: cloudWidth, height: cloudHeight, layers: layers)
            cloudHistories[group] = state
        }
        let history = state!

        var temporal = TemporalUniforms()
        let p = Self.pattern[Int(history.frameIndex % 4)]
        let hasHistory = history.previousViews?.count == viewCount
        temporal.pattern = SIMD4(p.x, p.y, Float(history.frameIndex % 1024), hasHistory ? 1 : 0)
        temporal.motion = SIMD4(0, 0, 0, history.previousRateMap != nil ? 1 : 0)
        temporal.now = SIMD4(frame.ground.x, frame.camera.x, frame.ground.z, atan2(frame.heading.y, frame.heading.x))
        temporal.prev = hasHistory ? history.previousState : temporal.now
        var previousViews = history.previousViews ?? views
        let previousRateBuffer = history.previousRateMap ?? emptyRateMapBuffer
        let readIndex = history.current, writeIndex = 1 - history.current

        func amplify(_ enc: MTLRenderCommandEncoder) {
            guard viewCount > 1 else { return }
            var mappings = (0..<viewCount).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            enc.setVertexAmplificationCount(viewCount, viewMappings: &mappings)
        }
        func cloudPass(_ color: MTLTexture, _ depth: MTLTexture, label: String) -> MTLRenderCommandEncoder? {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[1].texture = depth
            pass.colorAttachments[1].loadAction = .dontCare
            pass.colorAttachments[1].storeAction = .store
            pass.renderTargetArrayLength = viewCount
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            enc.label = label
            let vp = MTLViewport(originX: 0, originY: 0, width: Double(color.width), height: Double(color.height),
                                 znear: 0, zfar: 1)
            enc.setViewports(Array(repeating: vp, count: viewCount))
            amplify(enc)
            return enc
        }

        // 1. 这一帧新算的四分之一云样本（不用 rate map：每个像素自己换算回屏幕坐标）
        if let enc = cloudPass(history.fresh, history.freshDepth, label: "Clouds (fresh)") {
            enc.setRenderPipelineState(cloudFreshPipeline)
            enc.setFragmentBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBuffer(rateBuffer, offset: 0, index: 2)
            enc.setFragmentBuffer(atmosphereConstants, offset: 0, index: 3)
            enc.setFragmentBytes(&temporal, length: MemoryLayout<TemporalUniforms>.stride, index: 4)
            enc.setFragmentTexture(transmittanceLUT, index: 0)
            enc.setFragmentTexture(skyViewLUT, index: 1)
            enc.setFragmentTexture(baseNoise, index: 2)
            enc.setFragmentTexture(detailNoise, index: 3)
            enc.setFragmentTexture(weather, index: 4)
            enc.setFragmentTexture(multiScatLUT, index: 5)
            enc.setFragmentTexture(cloudTopMax, index: 6)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 2. 和上一帧的结果合起来，得到完整的云层
        if let enc = cloudPass(history.history[writeIndex], history.depth, label: "Clouds (resolve)") {
            enc.setRenderPipelineState(cloudResolvePipeline)
            enc.setFragmentBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBuffer(rateBuffer, offset: 0, index: 2)
            enc.setFragmentBytes(&previousViews, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 3)
            enc.setFragmentBytes(&temporal, length: MemoryLayout<TemporalUniforms>.stride, index: 4)
            enc.setFragmentBuffer(previousRateBuffer, offset: 0, index: 5)
            enc.setFragmentTexture(history.fresh, index: 0)
            enc.setFragmentTexture(history.freshDepth, index: 1)
            enc.setFragmentTexture(history.history[readIndex], index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        history.current = writeIndex
        history.frameIndex &+= 1
        history.previousViews = views
        history.previousState = temporal.now
        history.previousRateMap = rateMap == nil ? nil : rateBuffer

        // 3. 天空、海面，合成云层；4. 高度表
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        pass.renderTargetArrayLength = renderTargetArrayLength
        pass.rasterizationRateMap = rateMap
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Scene"
        enc.setViewports(viewports)
        amplify(enc)

        enc.setRenderPipelineState(scenePipeline)
        enc.setDepthStencilState(alwaysWriteDepth)
        enc.setFragmentBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBuffer(rateBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(atmosphereConstants, offset: 0, index: 3)
        enc.setFragmentTexture(transmittanceLUT, index: 0)
        enc.setFragmentTexture(skyViewLUT, index: 1)
        enc.setFragmentTexture(skySeaLUT, index: 2)
        enc.setFragmentTexture(history.history[writeIndex], index: 3)
        enc.setFragmentTexture(cloudShadow, index: 4)
        enc.setFragmentTexture(atoll, index: 5)
        enc.setFragmentTexture(baseNoise, index: 6)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encodeObjects(enc, objects: objects, views: &views, frame: &frame)

        if frame.hudUp.w > 0 {
            enc.setRenderPipelineState(hudPipeline)
            enc.setDepthStencilState(nearerDepth)
            enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
            enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentTexture(glyphAtlas, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if let panel {
            var u = panel.uniforms
            enc.setRenderPipelineState(panelPipeline)
            enc.setDepthStencilState(nearerDepth)
            enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            enc.setFragmentTexture(panel.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    /// 飞机、伞衣和伞绳、背带和表带。都在天空和云之后画，正常做深度测试（真手按这个深度和画面合成）。
    private func encodeObjects(_ enc: MTLRenderCommandEncoder, objects: SceneObjects,
                               views: inout [ViewUniforms], frame: inout FrameUniforms) {
        let viewCount = views.count
        let viewsLength = MemoryLayout<ViewUniforms>.stride * viewCount
        enc.setDepthStencilState(nearerDepth)
        enc.setFragmentBytes(&views, length: viewsLength, index: 0)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBuffer(atmosphereConstants, offset: 0, index: 2)

        func uniforms(_ model: simd_float4x4) -> ObjectUniforms {
            ObjectUniforms(model: model, params: SIMD4(objects.jumpLightGreen ? 1 : 0, objects.inCabin, 0, 0))
        }

        if let plane = objects.planeTransform {
            var u = uniforms(plane)
            enc.setRenderPipelineState(meshPipeline)
            enc.setVertexBuffer(planeMesh, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: planeVertexCount)
        }

        if !objects.canopyVertices.isEmpty {
            let count = min(objects.canopyVertices.count, Self.maxCanopyVertices)
            let buffer = canopyBuffers[canopyBufferIndex]
            canopyBufferIndex = (canopyBufferIndex + 1) % canopyBuffers.count
            objects.canopyVertices.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: MemoryLayout<MeshVertex>.stride * count)
            }
            var u = uniforms(matrix_identity_float4x4)
            enc.setRenderPipelineState(meshPipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }

        if !objects.lines.isEmpty {
            // 伞绳、刹车绳、钢索：一像素宽的线（一次最多 4 KB 的顶点）
            var points = Array(objects.lines.prefix(250))
            enc.setRenderPipelineState(linePipeline)
            enc.setVertexBytes(&points, length: MemoryLayout<SIMD4<Float>>.stride * points.count, index: 0)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: points.count)
        }

        let cones = objects.roundCones.prefix(Self.maxCones)
        if !cones.isEmpty {
            let buffer = coneBuffers[coneBufferIndex]
            coneBufferIndex = (coneBufferIndex + 1) % coneBuffers.count
            let pointer = buffer.contents().bindMemory(to: RoundCone.self, capacity: Self.maxCones)
            for (i, c) in cones.enumerated() { pointer[i] = c }
            var u = uniforms(matrix_identity_float4x4)
            enc.setRenderPipelineState(conePipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.coneVertexCount,
                               instanceCount: cones.count)
        }
    }

    /// 和 Objects.h 的 CONE_VERTICES 一致：(10 圈 - 1) × 12 × 6
    private static let coneVertexCount = 9 * 12 * 6

    private static let rateMapBufferCount = 6

    /// 把 rate map 的参数拷进一块缓冲，给 shader 把物理坐标换回屏幕坐标
    private func rateMapBuffer(for rateMap: MTLRasterizationRateMap) -> MTLBuffer {
        let size = rateMap.parameterDataSizeAndAlign.size
        if rateMapBuffers.count < Self.rateMapBufferCount || rateMapBuffers[rateMapBufferIndex].length < size {
            let buffer = device.makeBuffer(length: max(size, 256), options: .storageModeShared)!
            if rateMapBuffers.count < Self.rateMapBufferCount {
                rateMapBuffers.append(buffer)
                rateMapBufferIndex = rateMapBuffers.count - 1
            } else {
                rateMapBuffers[rateMapBufferIndex] = buffer
            }
        }
        let buffer = rateMapBuffers[rateMapBufferIndex]
        rateMapBufferIndex = (rateMapBufferIndex + 1) % Self.rateMapBufferCount
        rateMap.copyParameterData(buffer: buffer, offset: 0)
        return buffer
    }

    // MARK: - 字形图集

    /// 12 格：0-9、逗号、「ft」，每格 88×128，白字黑底（单通道）。
    private static func makeGlyphAtlas(device: MTLDevice) -> MTLTexture {
        let cellW = 88, cellH = 128, cells = 12
        let width = cellW * cells
        var pixels = [UInt8](repeating: 0, count: width * cellH)
        let big = CTFontCreateUIFontForLanguage(.system, 104, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 104, nil)
        let small = CTFontCreateUIFontForLanguage(.system, 50, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 50, nil)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: cellH, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            let glyphs = (0...9).map(String.init) + [",", "ft"]
            for (i, text) in glyphs.enumerated() {
                let font = i == 11 ? small : big
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                let x = Double(i * cellW) + (Double(cellW) - lineWidth) / 2
                ctx.textPosition = CGPoint(x: x, y: 26)   // 基线离底 26 像素
                CTLineDraw(line, ctx)
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: cellH,
                                                         mipmapped: false)
        d.usage = .shaderRead
        let texture = device.makeTexture(descriptor: d)!
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, cellH), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width)
        }
        return texture
    }
}
