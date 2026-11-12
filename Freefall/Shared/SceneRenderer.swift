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
        /// 动态分辨率：整帧的长宽各乘这个比例画（< 1 时先画进中间缓冲再放大），见 encodeScaled
        var renderScale: Float = 1
        /// 头显上性能测试用的开关（位）：1 云不步进，2 地形不着色，4 不画树和物件，8 不画地形深度预渲染，
        /// 16 树不着色，32 不画装备和伞，64 天空不着色；地形着色里再拆：128 地表函数换成常数，256 不采两层细节噪声，
        /// 512 不采树冠噪声，1024 不算伞和人的影子，2048 不算空气透视，4096 不用光照缓存（照旧现算，做对照），16384 被云挡住的地形也照算（关掉优化做对照）
        var debugFlags = 0
        /// 云的消光系数（每米）：越大云越实、边越硬
        var cloudExtinction: Float = 0.035
        var coverageBias: Float = 0
        /// 大气外的太阳照度记为 1。白云大约 0.1~0.3，海平面的蓝天大约 0.02，像照片那样让天空落在中间调
        var exposure: Float = 8
    }

    /// 画质档位（真机上按 GPU 耗时自动升降，见 ImmersiveRenderer）。0 最好。
    /// 画质档位：先降云（分辨率、步长），再降视线中心的分辨率（注视点渲染给的比例封顶到这个数，四周不动）
    static let qualityLevels: [(cloudScale: Float, cloudStep: Float, renderScale: Float)] = [
        (0.5, 1.0, 1), (0.5, 1.35, 1), (0.42, 1.35, 1), (0.36, 1.7, 1),
        (0.5, 1.35, 0.86), (0.5, 1.35, 0.74), (0.5, 1.35, 0.64), (0.5, 1.35, 0.56),
    ]

    /// 自动画质最多降到第几档。动态分辨率那几档（4 以后）在头显上试过：帧率能上去，但中心发糊、树和靶的边有锯齿，
    /// 先不自动用，等把固定开销砍下来再说
    /// （只用降云的四档；按实际帧率换，见 ImmersiveRenderer.adjustQuality。有了光照缓存以后伞下用不着降，
    /// 高空云占满画面的那一段才会降一两档）
    static let maxAutoQuality = 3

    func setQuality(_ level: Int) {
        let q = Self.qualityLevels[max(0, min(level, Self.qualityLevels.count - 1))]
        settings.cloudScale = q.cloudScale
        settings.cloudStep = q.cloudStep
        settings.renderScale = q.renderScale
    }

    /// 太阳（世界方向，指向太阳）。
    /// 环礁：仰角 32°，在起跳那一刻你面朝方向的左前方 25°（迎光看云有亮边，回头看是顺光的白云）。
    /// 地形关：仰角 50°，从山谷上游的左后方顺着谷照下来——低的太阳横着照进山谷，两边的山会把整个谷底挡在影子里。
    static func sunDirection(for scene: JumpScene) -> SIMD3<Float> {
        if scene.hasTerrain {
            let elevation: Float = 50 * .pi / 180
            let horizontal = SIMD2<Float>(-0.888, 0.460)
            return normalize(SIMD3(horizontal.x * cos(elevation), sin(elevation), horizontal.y * cos(elevation)))
        }
        let elevation: Float = 32 * .pi / 180
        let azimuth: Float = -25 * .pi / 180
        return normalize(SIMD3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation)))
    }

    var sunDirection: SIMD3<Float> { Self.sunDirection(for: scene) }

    enum RendererError: Error { case missingFunction(String) }

    let device: MTLDevice
    var settings = Settings()
    /// 这一关（地形、云层高度都按它；换关要新建一个 SceneRenderer）
    let scene: JumpScene

    let baseNoise: MTLTexture
    /// 地形细节层用的噪声：值加上预先算好的差分（见 Terrain.h 的 generateTerrainDetail）
    let terrainDetail: MTLTexture
    let detailNoise: MTLTexture
    let weather: MTLTexture
    let cloudShadow: MTLTexture
    let cloudTopMax: MTLTexture
    let atoll: MTLTexture
    /// 地形高度图（地面坐标 ±32 km，给云被山挡住、山影用）和山影图（r 太阳、g 环境光遮蔽）
    let terrainHeightMap: MTLTexture
    /// 靶周围 2 米一格的精细高度图（顶点着色器取高度用，见 Terrain.h 的 terrainVertexHeight）
    let terrainFineHeight: MTLTexture
    let terrainShade: MTLTexture
    /// 地面类型图（树林、水和熔岩的边、冰碛、农田……启动时预算，着色时只查一次）
    let surfaceMap: MTLTexture
    private let terrainPipeline: MTLRenderPipelineState
    /// 开场实体化那几秒用的管线（片元着色器带遮罩，会丢弃还没出现的片元）：天空海面、地形、网格
    private let revealPipelines: (scene: MTLRenderPipelineState, terrain: MTLRenderPipelineState,
                                  mesh: MTLRenderPipelineState, glove: MTLRenderPipelineState)
    private let terrainDepthPipeline: MTLRenderPipelineState
    /// 这一关的实体模型（SceneProps：树、石头、房子、塔、瀑布……没有的关是 nil）
    private struct City {
        var pipeline: MTLRenderPipelineState
        var revealPipeline: MTLRenderPipelineState
        var depthPipeline: MTLRenderPipelineState
        var waterfallPipeline: MTLRenderPipelineState
        var buildings: MTLBuffer
        var buildingCount: Int
        var waterfalls: MTLBuffer
        var waterfallCount: Int
    }
    private let city: City?
    /// 没有地形时绑给云层 pass 的占位深度
    private let emptyTerrainDepth: MTLTexture
    private let patchIndices: MTLBuffer
    private let patchIndexCount: Int
    private var nodeBuffers: [MTLBuffer] = []
    private var nodeBufferIndex = 0
    private var selectedNodes: [(SIMD2<Double>, Double, Int)] = []
    /// 上一帧画了多少块地形（离屏测试打印用）
    private(set) var lastTerrainNodeCount = 0
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
    private let resolvePipeline: MTLRenderPipelineState
    /// 伞和人的影子：每帧从太阳方向各画一张剪影贴图
    let playerShadow: PlayerShadow
    /// 光照缓存（地形关才开；天空之城的岛有顶面底面两套，先不缓存）
    let terrainCache: TerrainCache
    private let hudPipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let conePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let planeMesh: MTLBuffer
    private let planeVertexCount: Int
    /// 每帧重建的网格（伞衣、滑块、拉手、操纵环、表）：GPU 可能还在读前几帧的，轮流用几块
    private var meshBuffers: [MTLBuffer] = []
    private var meshBufferIndex = 0
    private static let maxMeshVertices = 40_000
    /// 身上不动的装备（背带、伸缩带）：启动时生成一次，画的时候平移到身体的位置
    private let risersMesh: MTLBuffer
    private let risersVertexCount: Int
    /// 手套（苹果示例的模型，换成跳伞配色）；资源缺了就是 nil，戴手套时什么都不画
    private let gloves: GloveSet?
    private let glovePipeline: MTLRenderPipelineState
    /// 绳子，每帧重写
    private var lineBuffers: [MTLBuffer] = []
    private var lineBufferIndex = 0
    private static let maxLines = 512
    private let panelPipeline: MTLRenderPipelineState
    private let helmetHudPipeline: MTLRenderPipelineState
    /// 背带和表带的胶囊，每帧重写；GPU 可能还在读前几帧的，轮流用
    private var coneBuffers: [MTLBuffer] = []
    private var coneBufferIndex = 0
    private static let maxCones = 160
    private let alwaysWriteDepth: MTLDepthStencilState
    private let nearerDepth: MTLDepthStencilState
    /// 只做深度测试、不写深度（雨丝：被伞、手挡住，但不挡别的）
    private let testDepth: MTLDepthStencilState
    private let rainPipeline: MTLRenderPipelineState
    private let mistPipeline: MTLRenderPipelineState
    /// 自由落体路上的光环：一张单位圆环的网格，按实例画
    private let ringPipeline: MTLRenderPipelineState
    private let ringMesh: MTLBuffer
    private let ringVertexCount: Int
    private static let maxRings = 16


    /// 没有 rate map 时绑给 shader 的占位缓冲（shader 不会读它）
    private let emptyRateMapBuffer: MTLBuffer
    /// rate map 参数缓冲的环：GPU 可能还在用前几帧的，轮流用
    private var rateMapBuffers: [MTLBuffer] = []
    private var rateMapBufferIndex = 0

    /// - Parameter gloveDirectory: 手套的网格和贴图所在的目录（app 里是 bundle 根目录）
    init(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
         maxViewCount: Int, queue: MTLCommandQueue, scene: JumpScene = .atoll, gloveDirectory: URL? = nil,
         barOnLeft: Bool = false) throws {
        self.device = device
        self.scene = scene
        // 雪山：满眼是太阳直射的雪，按别的关的曝光整片雪面都顶到纯白、看不出起伏。像拍雪景一样收小光圈，天也跟着更蓝
        if scene == .snow { settings.exposure = 5.6 }

        /// 用到函数常量的函数必须带常量值特化以后才能建管线：平时 revealConstant = false（不带开场遮罩）
        func specialized(_ name: String, reveal: Bool) throws -> MTLFunction {
            guard library.functionNames.contains(name) else { throw RendererError.missingFunction(name) }
            let constants = MTLFunctionConstantValues()
            var on = reveal
            constants.setConstantValue(&on, type: .bool, index: 10)
            return try library.makeFunction(name: name, constantValues: constants)
        }
        func function(_ name: String) throws -> MTLFunction { try specialized(name, reveal: false) }
        /// 带「开场实体化」遮罩的版本（Common.h 的函数常量 revealConstant）
        func revealFunction(_ name: String) throws -> MTLFunction { try specialized(name, reveal: true) }
        func texture(_ type: MTLTextureType, _ format: MTLPixelFormat, _ width: Int, _ height: Int,
                     _ depth: Int = 1, mipmapped: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = type
            d.pixelFormat = format
            d.width = width
            d.height = height
            d.depth = depth
            if mipmapped { d.mipmapLevelCount = Int(log2(Double(max(width, height, depth)))) + 1 }
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        func renderPipeline(_ vertex: String, _ fragment: String, colors: [MTLPixelFormat],
                            depth: MTLPixelFormat, blend: Bool, reveal: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = reveal ? fragment + " (reveal)" : fragment
            d.vertexFunction = try function(vertex)
            d.fragmentFunction = try reveal ? revealFunction(fragment) : function(fragment)
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

        // 带 mip：地形拿它的一层当细节噪声，中远处一个像素盖十几个纹素，不按 mip 取的话又闪又慢（每次采样都不在缓存里）。
        // 云的步进还是取第 0 级
        baseNoise = texture(.type3D, .rgba8Unorm, 128, 128, 128, mipmapped: true)
        terrainDetail = texture(.type3D, .rgba16Unorm, 128, 128, 128, mipmapped: true)
        detailNoise = texture(.type3D, .rgba8Unorm, 32, 32, 32)
        weather = texture(.type2D, .rgba8Unorm, 1024, 1024)
        cloudShadow = texture(.type2D, .r16Float, 2048, 2048)
        cloudTopMax = texture(.type2D, .r8Unorm, 256, 256)
        atoll = texture(.type2D, .rgba8Unorm, 2048, 2048)
        let terrainSize = scene.hasTerrain ? 2048 : 4
        terrainHeightMap = texture(.type2D, .r16Float, terrainSize, terrainSize)
        terrainFineHeight = texture(.type2D, .r32Float, terrainSize, terrainSize)
        terrainShade = texture(.type2D, .rg8Unorm, terrainSize, terrainSize)
        surfaceMap = texture(.type2D, .rgba8Unorm, terrainSize, terrainSize, mipmapped: true)
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
        scenePipeline = try renderPipeline("skyVertex", "sceneFragment", colors: [colorFormat],
                                           depth: depthFormat, blend: false)
        resolvePipeline = try renderPipeline("skyVertex", "resolveFragment", colors: [colorFormat],
                                             depth: depthFormat, blend: false)
        playerShadow = try PlayerShadow(device: device, library: library)
        terrainCache = try TerrainCache(device: device, library: library, enabled: scene.hasTerrain && scene != .sky)
        terrainPipeline = try renderPipeline("terrainVertex", "terrainFragment", colors: [colorFormat],
                                             depth: depthFormat, blend: false)
        revealPipelines = (
            scene: try renderPipeline("skyVertex", "sceneFragment", colors: [colorFormat], depth: depthFormat,
                                      blend: false, reveal: true),
            terrain: try renderPipeline("terrainVertex", "terrainFragment", colors: [colorFormat], depth: depthFormat,
                                        blend: false, reveal: true),
            mesh: try renderPipeline("meshVertex", "objectFragment", colors: [colorFormat], depth: depthFormat,
                                     blend: false, reveal: true),
            glove: try renderPipeline("gloveVertex", "gloveFragment", colors: [colorFormat], depth: depthFormat,
                                      blend: false, reveal: true))
        let depthOnly = MTLRenderPipelineDescriptor()
        depthOnly.label = "terrain depth"
        depthOnly.vertexFunction = try function("terrainDepthVertex")
        depthOnly.depthAttachmentPixelFormat = .depth32Float
        depthOnly.maxVertexAmplificationCount = maxViewCount
        depthOnly.inputPrimitiveTopology = .triangle
        terrainDepthPipeline = try device.makeRenderPipelineState(descriptor: depthOnly)
        let layout = SceneProps.layout(for: scene)
        if !layout.buildings.isEmpty || !layout.waterfalls.isEmpty {
            // （空的网格也给一个顶点大小的缓冲：长度为 0 的缓冲建不出来）
            let stride = MemoryLayout<MeshVertex>.stride
            let cityDepth = MTLRenderPipelineDescriptor()
            cityDepth.label = "city depth"
            cityDepth.vertexFunction = try function("cityDepthVertex")
            cityDepth.depthAttachmentPixelFormat = .depth32Float
            cityDepth.maxVertexAmplificationCount = maxViewCount
            cityDepth.inputPrimitiveTopology = .triangle
            city = City(
                pipeline: try renderPipeline("cityVertex", "cityFragment", colors: [colorFormat], depth: depthFormat, blend: false),
                revealPipeline: try renderPipeline("cityVertex", "cityFragment", colors: [colorFormat], depth: depthFormat,
                                                   blend: false, reveal: true),
                depthPipeline: try device.makeRenderPipelineState(descriptor: cityDepth),
                waterfallPipeline: try renderPipeline("cityVertex", "waterfallFragment", colors: [colorFormat],
                                                      depth: depthFormat, blend: true),
                buildings: layout.buildings.isEmpty ? device.makeBuffer(length: stride, options: .storageModeShared)!
                    : device.makeBuffer(bytes: layout.buildings, length: stride * layout.buildings.count,
                                        options: .storageModeShared)!,
                buildingCount: layout.buildings.count,
                waterfalls: layout.waterfalls.isEmpty ? device.makeBuffer(length: stride, options: .storageModeShared)!
                    : device.makeBuffer(bytes: layout.waterfalls, length: stride * layout.waterfalls.count,
                                        options: .storageModeShared)!,
                waterfallCount: layout.waterfalls.count)
        } else {
            city = nil
        }
        let empty = MTLTextureDescriptor()
        empty.textureType = .type2DArray
        empty.pixelFormat = .depth32Float
        empty.width = 1
        empty.height = 1
        empty.arrayLength = 2
        empty.usage = [.shaderRead, .renderTarget]
        empty.storageMode = .private
        emptyTerrainDepth = device.makeTexture(descriptor: empty)!
        let indices = TerrainLOD.patchIndices()
        patchIndexCount = indices.count
        patchIndices = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.stride * indices.count,
                                         options: .storageModeShared)!
        for _ in 0..<8 {
            nodeBuffers.append(device.makeBuffer(length: MemoryLayout<TerrainNode>.stride * TerrainLOD.maxNodes,
                                                 options: .storageModeShared)!)
        }
        hudPipeline = try renderPipeline("hudVertex", "hudFragment", colors: [colorFormat],
                                         depth: depthFormat, blend: true)
        meshPipeline = try renderPipeline("meshVertex", "objectFragment", colors: [colorFormat],
                                          depth: depthFormat, blend: false)
        conePipeline = try renderPipeline("roundConeVertex", "objectFragment", colors: [colorFormat],
                                          depth: depthFormat, blend: false)
        glovePipeline = try renderPipeline("gloveVertex", "gloveFragment", colors: [colorFormat],
                                           depth: depthFormat, blend: false)
        gloves = gloveDirectory.flatMap { GloveSet(device: device, directory: $0) }
        // 绳子：朝着眼睛的细长条，边缘按覆盖率半透明（预乘 alpha 叠上去）
        linePipeline = try renderPipeline("lineVertex", "lineFragment", colors: [colorFormat],
                                          depth: depthFormat, blend: true)
        // 雨丝：叠加上去（不影响 alpha）
        let rainDescriptor = MTLRenderPipelineDescriptor()
        rainDescriptor.label = "rain"
        rainDescriptor.vertexFunction = try function("rainVertex")
        rainDescriptor.fragmentFunction = try function("rainFragment")
        rainDescriptor.colorAttachments[0].pixelFormat = colorFormat
        rainDescriptor.colorAttachments[0].isBlendingEnabled = true
        rainDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        rainDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        rainDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        rainDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        rainDescriptor.depthAttachmentPixelFormat = depthFormat
        rainDescriptor.maxVertexAmplificationCount = maxViewCount
        rainDescriptor.inputPrimitiveTopology = .triangle
        rainPipeline = try device.makeRenderPipelineState(descriptor: rainDescriptor)
        // 光环：和雨丝一样叠加上去
        rainDescriptor.label = "rings"
        rainDescriptor.vertexFunction = try function("ringVertex")
        rainDescriptor.fragmentFunction = try function("ringFragment")
        ringPipeline = try device.makeRenderPipelineState(descriptor: rainDescriptor)
        var ringVertices: [MeshVertex] = []
        Gear.ring(&ringVertices, center: SIMD3(0, 0, 0), axis: SIMD3(0, 0, 1), radii: SIMD2(1, 1), tube: 0.035,
                  color: SIMD3(1, 1, 1), segments: 72, sides: 8)
        ringVertexCount = ringVertices.count
        ringMesh = device.makeBuffer(bytes: ringVertices, length: MemoryLayout<MeshVertex>.stride * ringVertices.count,
                                     options: .storageModeShared)!
        mistPipeline = try renderPipeline("mistVertex", "mistFragment", colors: [colorFormat], depth: depthFormat,
                                          blend: true)

        let plane = ProceduralMeshes.plane(barOnLeft: barOnLeft)
        planeVertexCount = plane.count
        planeMesh = device.makeBuffer(bytes: plane, length: MemoryLayout<MeshVertex>.stride * plane.count,
                                      options: .storageModeShared)!
        for _ in 0..<8 {
            meshBuffers.append(device.makeBuffer(length: MemoryLayout<MeshVertex>.stride * Self.maxMeshVertices,
                                                 options: .storageModeShared)!)
            lineBuffers.append(device.makeBuffer(length: MemoryLayout<LineSegment>.stride * Self.maxLines,
                                                 options: .storageModeShared)!)
        }
        let risers = Gear.risers
        risersVertexCount = risers.count
        risersMesh = device.makeBuffer(bytes: risers, length: MemoryLayout<MeshVertex>.stride * risers.count,
                                       options: .storageModeShared)!
        panelPipeline = try renderPipeline("panelVertex", "panelFragment", colors: [colorFormat],
                                           depth: depthFormat, blend: true)
        helmetHudPipeline = try renderPipeline("panelVertex", "helmetHudFragment", colors: [colorFormat],
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
        let test = MTLDepthStencilDescriptor()
        test.depthCompareFunction = .greaterEqual
        test.isDepthWriteEnabled = false
        testDepth = device.makeDepthStencilState(descriptor: test)!

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
        var sun = SIMD4<Float>(sunDirection, 0)

        enc.setTexture(baseNoise, index: 0)
        dispatch(enc, try kernel("generateBaseNoise"), MTLSize(width: 128, height: 128, depth: 128))
        enc.setTexture(terrainDetail, index: 0)
        enc.setTexture(baseNoise, index: 1)
        dispatch(enc, try kernel("generateTerrainDetail"), MTLSize(width: 128, height: 128, depth: 128))
        enc.setTexture(detailNoise, index: 0)
        dispatch(enc, try kernel("generateDetailNoise"), MTLSize(width: 32, height: 32, depth: 32))
        enc.setTexture(weather, index: 0)
        dispatch(enc, try kernel("generateWeather"), MTLSize(width: 1024, height: 1024, depth: 1))

        enc.setTexture(atoll, index: 0)
        dispatch(enc, try kernel("generateAtoll"), MTLSize(width: 2048, height: 2048, depth: 1))

        enc.setTexture(cloudTopMax, index: 0)
        enc.setTexture(weather, index: 1)
        dispatch(enc, try kernel("computeCloudTopMax"), MTLSize(width: 256, height: 256, depth: 1))

        var cloudOffset = Float(scene.cloudOffset)
        enc.setTexture(cloudShadow, index: 0)
        enc.setTexture(baseNoise, index: 1)
        enc.setTexture(weather, index: 2)
        enc.setBytes(&sun, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setBytes(&cloudOffset, length: MemoryLayout<Float>.stride, index: 1)
        dispatch(enc, try kernel("computeCloudShadow"), MTLSize(width: 2048, height: 2048, depth: 1))

        if scene.hasTerrain {
            var sceneIndex = Int32(scene.rawValue)
            enc.setTexture(terrainHeightMap, index: 0)
            enc.setBytes(&sceneIndex, length: MemoryLayout<Int32>.stride, index: 0)
            dispatch(enc, try kernel("generateTerrainHeight"), MTLSize(width: 2048, height: 2048, depth: 1))
            enc.setTexture(terrainFineHeight, index: 0)
            dispatch(enc, try kernel("generateFineHeight"), MTLSize(width: 2048, height: 2048, depth: 1))
            enc.setTexture(terrainShade, index: 0)
            enc.setTexture(terrainHeightMap, index: 1)
            enc.setBytes(&sun, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch(enc, try kernel("computeTerrainShadow"), MTLSize(width: 2048, height: 2048, depth: 1))
            enc.setTexture(surfaceMap, index: 0)
            enc.setBytes(&sceneIndex, length: MemoryLayout<Int32>.stride, index: 0)
            dispatch(enc, try kernel("generateSurfaceMap"), MTLSize(width: 2048, height: 2048, depth: 1))
        }

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
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: baseNoise)
            blit.generateMipmaps(for: terrainDetail)
            if scene.hasTerrain { blit.generateMipmaps(for: surfaceMap) }
            blit.endEncoding()
        }
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
        var sun = SIMD4<Float>(sunDirection, 0)
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
        f.sunDirection = SIMD4(sunDirection, 0)
        f.clouds = SIMD4(settings.cloudScale, settings.cloudStep, settings.cloudExtinction, settings.coverageBias)
        f.exposure.x = settings.exposure
        f.world = scene.worldUniform
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
                hud: [HelmetHUD.Panel] = [], hudDirty: [MTLTexture] = [],
                group: Int = 0) {
        // 头盔 HUD 的贴图刚重画过的，先生成 mip（发光取模糊的那几级）
        if !hudDirty.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for t in hudDirty { blit.generateMipmaps(for: t) }
            blit.endEncoding()
        }
        let viewCount = views.count
        var views = views
        var frame = complete(frame)
        frame.camera.w = rateMap == nil ? 0 : 1
        frame.exposure.z = Float(settings.debugFlags)
        // 伞衣和身体的影子（地形、海面、装备、绳子都要用）
        if let shadow = objects.canopyShadow {
            frame.canopyCenter = shadow.center
            frame.canopySpan = shadow.span
            frame.canopyChord = shadow.chord
        }
        if let top = objects.bodyTop {
            frame.bodyShadow = SIMD4(top, 1)
            frame.bodyRight = SIMD4(objects.bodyRight, 0)
            frame.armShadow = objects.wrists
        }
        // 两张剪影贴图：从太阳的方向（转到舞台空间，和 shader 的 stageSunDirection 一样）画伞衣和人
        let sun = frame.sunDirection, heading = frame.heading
        let placement = playerShadow.encode(commandBuffer, objects: objects,
                                            sun: SIMD3(sun.x * heading.x - sun.z * heading.y, sun.y,
                                                       sun.x * heading.y + sun.z * heading.x))
        frame.shadowU = placement.u
        frame.shadowV = placement.v
        frame.shadowCenters = placement.centers
        // 开场的实体化：还在进行时换成带遮罩的管线，没出现的像素不画（混合沉浸里透出房间）
        frame.reveal = objects.reveal
        let revealing = objects.reveal.w < 1000
        let rateBuffer = rateMap.map(rateMapBuffer(for:)) ?? emptyRateMapBuffer

        // 0. 地形：先选块，画一遍深度（云层按它截断）
        var terrainDraw: TerrainDraw?
        var terrainDepth = emptyTerrainDepth
        if scene.hasTerrain || city != nil, let terrain = objects.terrain, let draw = prepareTerrain(terrain, views: views) {
            terrainDraw = draw
            terrainCache.update(commandBuffer, camera: SIMD2(Double(draw.uniforms.origin.z), Double(draw.uniforms.origin.w)),
                                scene: scene, frame: frame, atmosphere: atmosphereConstants, noise: baseNoise,
                                surfaceMap: surfaceMap, detail: terrainDetail, skySeaLUT: skySeaLUT,
                                cloudShadow: cloudShadow, terrainShade: terrainShade)
            if settings.debugFlags & 8 == 0 {
                frame.exposure.y = 1
                terrainDepth = terrainDepthTexture(group: group, like: colorTexture, layers: max(viewCount, 1))
                encodeTerrainDepth(commandBuffer, draw, target: terrainDepth, views: &views, frame: &frame,
                                   viewports: viewports, renderTargetArrayLength: renderTargetArrayLength, rateMap: rateMap)
            }
        }

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
            enc.setFragmentTexture(terrainDepth, index: 7)
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
        // 混合沉浸：没画到的像素是全透明的（系统在那里透出房间），所以要清成 (0, 0, 0, 0)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        pass.renderTargetArrayLength = renderTargetArrayLength
        pass.rasterizationRateMap = rateMap
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Scene"
        // 伞和人的剪影：这个 pass 里的地形、海面、物件、装备、绳子都从这两个槽位取
        enc.setFragmentTexture(playerShadow.canopyMap, index: 14)
        enc.setFragmentTexture(playerShadow.bodyMap, index: 15)
        enc.setViewports(viewports)
        amplify(enc)

        // 地形先画（写深度），天空 pass 再按深度只填地形没盖住的像素
        if let terrainDraw {
            encodeTerrain(enc, terrainDraw, views: &views, frame: &frame, rateBuffer: rateBuffer,
                          cloud: history.history[writeIndex], revealing: revealing)
        }

        enc.setRenderPipelineState(revealing ? revealPipelines.scene : scenePipeline)
        enc.setDepthStencilState(nearerDepth)
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

        // 瀑布：半透明，叠在浮岛和天空上面（片元的缓冲和贴图沿用上面天空 pass 绑的）
        if let city, city.waterfallCount > 0, let terrainDraw, !revealing {
            var cu = terrainDraw.city
            enc.setRenderPipelineState(city.waterfallPipeline)
            enc.setDepthStencilState(testDepth)
            enc.setVertexBuffer(city.waterfalls, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 1)
            enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            enc.setVertexBytes(&cu, length: MemoryLayout<CityUniforms>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: city.waterfallCount)
        }

        // 光环：叠加的光，只测深度；后面画的飞机、手、装备会盖住它
        if !objects.rings.isEmpty, !revealing {
            var rings = Array(objects.rings.prefix(Self.maxRings))
            enc.setRenderPipelineState(ringPipeline)
            enc.setDepthStencilState(testDepth)
            enc.setVertexBuffer(ringMesh, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 1)
            enc.setVertexBytes(&rings, length: MemoryLayout<RingInstance>.stride * rings.count, index: 2)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ringVertexCount, instanceCount: rings.count)
        }

        if settings.debugFlags & 32 == 0 {
            encodeObjects(enc, objects: objects, views: &views, frame: &frame, revealing: revealing)
        }

        // 身边的雾团（在雨丝后面画：雨丝是叠加上去的亮线）
        if var mist = objects.mist {
            enc.setRenderPipelineState(mistPipeline)
            enc.setDepthStencilState(testDepth)
            enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
            enc.setVertexBytes(&mist, length: MemoryLayout<RainUniforms>.stride, index: 1)
            enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            enc.setVertexTexture(weather, index: 0)
            enc.setVertexTexture(baseNoise, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBuffer(atmosphereConstants, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Int(mist.center.w))
        }

        if var rain = objects.rain {
            let count = Int(rain.center.w * min(rain.offset.w, 1))
            if count > 0 {
                enc.setRenderPipelineState(rainPipeline)
                enc.setDepthStencilState(testDepth)
                enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
                enc.setVertexBytes(&rain, length: MemoryLayout<RainUniforms>.stride, index: 1)
                enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                enc.setFragmentBuffer(atmosphereConstants, offset: 0, index: 2)
                enc.setFragmentBytes(&rain, length: MemoryLayout<RainUniforms>.stride, index: 3)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            }
        }

        // 高度表：开场时等实体化的波前走到手腕上才出现
        let hudCenter = SIMD3(frame.hudCenter.x, frame.hudCenter.y, frame.hudCenter.z)
        let revealCenter = SIMD3(objects.reveal.x, objects.reveal.y, objects.reveal.z)
        let hudShown = !revealing || (objects.reveal.w >= 0 && distance(hudCenter, revealCenter) < objects.reveal.w - 0.1)
        if frame.hudUp.w > 0, hudShown {
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
        // 头盔 HUD：最后画，测深度（手伸到它前面会挡住它），也写深度。（试过永远画在最前面：远的东西盖在近的手上，看着别扭，改回来了）
        // 要写：混合沉浸里系统按深度把画面和透视合成。开场房间里那行提示后面什么都没画（深度还是清屏的 0 = 无穷远），
        // 之前只有颜色没有深度，真机上看不到；同一帧里写了深度的扶杆看得到。（推断出来的原因，离屏测试里两种都画得出来）
        for p in hud {
            var u = p.uniforms
            enc.setRenderPipelineState(helmetHudPipeline)
            enc.setDepthStencilState(nearerDepth)
            enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * viewCount, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            enc.setFragmentTexture(p.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    /// 这一帧要画的地形块（深度预渲染和主 pass 共用）
    private struct TerrainDraw {
        var buffer: MTLBuffer
        var count: Int
        var uniforms: TerrainUniforms
        /// 建筑网格用的：地面坐标原点相对舞台原点的偏移
        var city = CityUniforms(origin: SIMD4(0, 0, 0, 0))
    }

    /// 地形：选块（视锥裁剪）→ 写进这一帧的块缓冲
    private func prepareTerrain(_ terrain: TerrainFrame, views: [ViewUniforms]) -> TerrainDraw? {
        let viewCount = views.count
        // 头（两只眼的中点）在舞台空间和地面坐标里的位置
        var head = SIMD3<Float>(0, 0, 0)
        for v in views { head += SIMD3(v.cameraPosition.x, v.cameraPosition.y, v.cameraPosition.z) }
        head /= Float(max(viewCount, 1))
        // 没有地形的关（环礁）：不选地形块，只为了画实体模型（它也要走深度预渲染和地形那套片元绑定）
        guard scene.hasTerrain else {
            return TerrainDraw(buffer: nodeBuffers[0], count: 0,
                               uniforms: TerrainUniforms(camera: SIMD4(head, Float(scene.rawValue)), lod: SIMD4(0, 0, 0, 0)),
                               city: CityUniforms(origin: SIMD4(Float(-terrain.groundOrigin.x), Float(-terrain.groundOrigin.y), 0, 0)))
        }
        let c = cos(terrain.heading), s = sin(terrain.heading)
        let hx = Double(head.x), hz = Double(head.z)
        let camera = SIMD3(terrain.groundOrigin.x + hx * c + hz * s, Double(head.y) + terrain.stageToAltitude,
                           terrain.groundOrigin.y - hx * s + hz * c)
        // 视锥的四个侧面（每只眼一组）
        var planes: [[SIMD4<Float>]] = []
        for v in views {
            let m = v.viewProjection
            let r0 = SIMD4(m[0][0], m[1][0], m[2][0], m[3][0]), r1 = SIMD4(m[0][1], m[1][1], m[2][1], m[3][1])
            let r3 = SIMD4(m[0][3], m[1][3], m[2][3], m[3][3])
            planes.append([r3 + r0, r3 - r0, r3 + r1, r3 - r1].map { $0 / simd_length(SIMD3($0.x, $0.y, $0.z)) })
        }
        let origin = terrain.groundOrigin, stageToAltitude = terrain.stageToAltitude
        // 天空之城：只有浮岛上有地形，四叉树只往碰得到岛的块里走（岛按谷坐标里的椭圆，放大一圈当包围圆）
        let islands: [(SIMD2<Double>, Double)] = scene == .sky ? TerrainField.skyIslandShape.map {
            (SIMD2<Double>(TerrainField.skyGround(SIMD2($0.x, $0.y))), Double(max($0.z, $0.w)) * 1.3)
        } : []
        TerrainLOD.select(camera: camera, heightRange: scene.heightRange, visible: { center, radius in
            if !islands.isEmpty {
                // 块的包围球里含了竖直方向的半高，水平上偏大一点，不要紧
                let c = SIMD2(center.x, center.z)
                guard islands.contains(where: { simd_length(c - $0.0) < radius + $0.1 }) else { return false }
            }
            let rx = center.x - origin.x, rz = center.z - origin.y
            let d2 = rx * rx + rz * rz
            let p = SIMD3<Float>(Float(rx * c - rz * s), Float(center.y - stageToAltitude - d2 / (2 * 6_360_000)),
                                 Float(rx * s + rz * c))
            let r = Float(radius)
            return planes.contains { side in side.allSatisfy { simd_dot(SIMD3($0.x, $0.y, $0.z), p) + $0.w >= -r } }
        }, into: &selectedNodes)
        lastTerrainNodeCount = selectedNodes.count
        guard !selectedNodes.isEmpty else { return nil }

        let buffer = nodeBuffers[nodeBufferIndex]
        nodeBufferIndex = (nodeBufferIndex + 1) % nodeBuffers.count
        let pointer = buffer.contents().bindMemory(to: TerrainNode.self, capacity: TerrainLOD.maxNodes)
        for (i, node) in selectedNodes.enumerated() {
            let rel = node.0 - origin
            pointer[i] = TerrainNode(origin: SIMD4(Float(node.0.x), Float(node.0.y), Float(node.1), Float(node.2)),
                                     relative: SIMD4(Float(rel.x), Float(rel.y), 0, 0))
        }
        // 海岛、火山的海：海面以下的地形按海平面画（海岛第一版没开，海面画在 -44 米的海床上，海天交界多出一条黑线）
        let seaLevel: Float = scene == .volcano || scene == .island ? 1 : 0
        let range = scene.heightRange
        let above = Float(max(range.0 - camera.y, 0, camera.y - range.1))
        let uniforms = TerrainUniforms(camera: SIMD4(head, Float(scene.rawValue)),
                                       lod: SIMD4(Float(TerrainLOD.range0), seaLevel, 0, above),
                                       origin: SIMD4(Float(origin.x), Float(origin.y), Float(camera.x), Float(camera.z)))
        return TerrainDraw(buffer: buffer, count: selectedNodes.count, uniforms: uniforms,
                           city: CityUniforms(origin: SIMD4(Float(-origin.x), Float(-origin.y), 0, 0)))
    }

    /// 地形的深度预渲染：和主 pass 同样的视口、rate map，只写深度。云层 pass 按它截断视线（山后面的云不算）
    private func encodeTerrainDepth(_ commandBuffer: MTLCommandBuffer, _ draw: TerrainDraw, target: MTLTexture,
                                    views: inout [ViewUniforms], frame: inout FrameUniforms, viewports: [MTLViewport],
                                    renderTargetArrayLength: Int, rateMap: MTLRasterizationRateMap?) {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = target
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        pass.renderTargetArrayLength = renderTargetArrayLength
        pass.rasterizationRateMap = rateMap
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Terrain depth"
        enc.setViewports(viewports)
        if views.count > 1 {
            var mappings = (0..<views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            enc.setVertexAmplificationCount(views.count, viewMappings: &mappings)
        }
        var tu = draw.uniforms
        enc.setRenderPipelineState(terrainDepthPipeline)
        enc.setDepthStencilState(nearerDepth)
        enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * views.count, index: 0)
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setVertexBuffer(draw.buffer, offset: 0, index: 2)
        enc.setVertexBytes(&tu, length: MemoryLayout<TerrainUniforms>.stride, index: 3)
        enc.setVertexTexture(terrainHeightMap, index: 0)
        enc.setVertexTexture(terrainFineHeight, index: 1)
        if draw.count > 0 {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: patchIndexCount, indexType: .uint16,
                                      indexBuffer: patchIndices, indexBufferOffset: 0, instanceCount: draw.count)
            if scene == .sky {
                // 浮岛的底面
                tu.lod.z = 1
                enc.setVertexBytes(&tu, length: MemoryLayout<TerrainUniforms>.stride, index: 3)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: patchIndexCount, indexType: .uint16,
                                          indexBuffer: patchIndices, indexBufferOffset: 0, instanceCount: draw.count)
            }
        }
        if let city, city.buildingCount > 0, settings.debugFlags & 4 == 0 {
            // 实体模型（云不能盖到它们前面）
            var cu = draw.city
            enc.setRenderPipelineState(city.depthPipeline)
            enc.setVertexBuffer(city.buildings, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: MemoryLayout<ViewUniforms>.stride * views.count, index: 1)
            enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            enc.setVertexBytes(&cu, length: MemoryLayout<CityUniforms>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: city.buildingCount)
        }
        enc.endEncoding()
    }

    /// 地形的主 pass：一次实例化画完（着色、空气透视、叠云都在片元里）
    private func encodeTerrain(_ enc: MTLRenderCommandEncoder, _ draw: TerrainDraw, views: inout [ViewUniforms],
                               frame: inout FrameUniforms, rateBuffer: MTLBuffer, cloud: MTLTexture,
                               revealing: Bool) {
        var tu = draw.uniforms
        let viewsLength = MemoryLayout<ViewUniforms>.stride * views.count
        enc.setRenderPipelineState(revealing ? revealPipelines.terrain : terrainPipeline)
        enc.setDepthStencilState(nearerDepth)
        enc.setVertexBytes(&views, length: viewsLength, index: 0)
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setVertexBuffer(draw.buffer, offset: 0, index: 2)
        enc.setVertexBytes(&tu, length: MemoryLayout<TerrainUniforms>.stride, index: 3)
        enc.setVertexTexture(terrainHeightMap, index: 0)
        enc.setVertexTexture(terrainFineHeight, index: 1)
        enc.setFragmentBytes(&views, length: viewsLength, index: 0)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBuffer(rateBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(atmosphereConstants, offset: 0, index: 3)
        enc.setFragmentBytes(&tu, length: MemoryLayout<TerrainUniforms>.stride, index: 4)
        enc.setFragmentTexture(transmittanceLUT, index: 0)
        enc.setFragmentTexture(skyViewLUT, index: 1)
        enc.setFragmentTexture(skySeaLUT, index: 2)
        enc.setFragmentTexture(cloud, index: 3)
        enc.setFragmentTexture(cloudShadow, index: 4)
        enc.setFragmentTexture(terrainShade, index: 5)
        enc.setFragmentTexture(baseNoise, index: 6)
        enc.setFragmentTexture(surfaceMap, index: 7)
        enc.setFragmentTexture(terrainDetail, index: 8)
        enc.setFragmentBuffer(terrainCache.uniforms, offset: 0, index: 5)
        enc.setFragmentTexture(terrainCache.color, index: 9)
        enc.setFragmentTexture(terrainCache.info, index: 10)
        if draw.count > 0 {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: patchIndexCount, indexType: .uint16,
                                      indexBuffer: patchIndices, indexBufferOffset: 0, instanceCount: draw.count)
            if scene == .sky {
                tu.lod.z = 1
                enc.setVertexBytes(&tu, length: MemoryLayout<TerrainUniforms>.stride, index: 3)
                enc.setFragmentBytes(&tu, length: MemoryLayout<TerrainUniforms>.stride, index: 4)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: patchIndexCount, indexType: .uint16,
                                          indexBuffer: patchIndices, indexBufferOffset: 0, instanceCount: draw.count)
            }
        }
        if let city, city.buildingCount > 0, settings.debugFlags & 4 == 0 {
            // 实体模型：片元的缓冲和贴图和地形绑的是同一套
            var cu = draw.city
            enc.setRenderPipelineState(revealing ? city.revealPipeline : city.pipeline)
            enc.setVertexBuffer(city.buildings, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 2)
            enc.setVertexBytes(&cu, length: MemoryLayout<CityUniforms>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: city.buildingCount)
        }
    }

    /// 每组视图一张地形深度（和颜色纹理一样大）
    private var terrainDepthTextures: [Int: MTLTexture] = [:]

    private func terrainDepthTexture(group: Int, like color: MTLTexture, layers: Int) -> MTLTexture {
        if let t = terrainDepthTextures[group], t.width == color.width, t.height == color.height,
           t.arrayLength >= layers {
            return t
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .depth32Float
        d.width = color.width
        d.height = color.height
        d.arrayLength = layers
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        terrainDepthTextures[group] = t
        return t
    }

    /// 飞机、伞衣和伞绳、身上的装备、手腕上的表。都在天空和云之后画，正常做深度测试（真手按这个深度和画面合成）。
    private func encodeObjects(_ enc: MTLRenderCommandEncoder, objects: SceneObjects,
                               views: inout [ViewUniforms], frame: inout FrameUniforms, revealing: Bool) {
        let viewCount = views.count
        let viewsLength = MemoryLayout<ViewUniforms>.stride * viewCount
        enc.setDepthStencilState(nearerDepth)
        enc.setFragmentBytes(&views, length: viewsLength, index: 0)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBuffer(atmosphereConstants, offset: 0, index: 2)
        enc.setFragmentTexture(skyViewLUT, index: 0)      // 金属、塑料反射的天空

        func uniforms(_ model: simd_float4x4) -> ObjectUniforms {
            ObjectUniforms(model: model, params: SIMD4(objects.jumpLightGreen ? 1 : 0, objects.inCabin, objects.wetness, 0))
        }
        func draw(_ buffer: MTLBuffer, count: Int, model: simd_float4x4) {
            var u = uniforms(model)
            enc.setRenderPipelineState(revealing ? revealPipelines.mesh : meshPipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }

        if let plane = objects.planeTransform { draw(planeMesh, count: planeVertexCount, model: plane) }
        if let model = objects.risersTransform { draw(risersMesh, count: risersVertexCount, model: model) }

        if !objects.meshVertices.isEmpty {
            let count = min(objects.meshVertices.count, Self.maxMeshVertices)
            let buffer = meshBuffers[meshBufferIndex]
            meshBufferIndex = (meshBufferIndex + 1) % meshBuffers.count
            objects.meshVertices.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: MemoryLayout<MeshVertex>.stride * count)
            }
            draw(buffer, count: count, model: matrix_identity_float4x4)
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

        // 手套：按这只手的关节算 27 个蒙皮矩阵，GPU 上蒙皮
        if let gloves, !objects.gloveHands.isEmpty {
            var u = uniforms(matrix_identity_float4x4)
            enc.setRenderPipelineState(revealing ? revealPipelines.glove : glovePipeline)
            enc.setDepthStencilState(nearerDepth)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<ObjectUniforms>.stride, index: 3)
            enc.setFragmentTexture(gloves.normal, index: 2)
            enc.setFragmentTexture(gloves.material, index: 3)
            for hand in objects.gloveHands {
                let mesh = hand.isLeft ? gloves.left : gloves.right
                var skin = GloveRig.skinning(hand, mesh: mesh)
                enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&skin, length: MemoryLayout<simd_float4x4>.stride * skin.count, index: 2)
                enc.setFragmentTexture(mesh.albedo, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
                                          indexBuffer: mesh.indexBuffer, indexBufferOffset: 0)
            }
        }

        // 绳子最后画（半透明的边，只测深度不写深度）
        let lines = objects.lines.prefix(Self.maxLines)
        if !lines.isEmpty {
            let buffer = lineBuffers[lineBufferIndex]
            lineBufferIndex = (lineBufferIndex + 1) % lineBuffers.count
            let pointer = buffer.contents().bindMemory(to: LineSegment.self, capacity: Self.maxLines)
            for (i, l) in lines.enumerated() { pointer[i] = l }
            enc.setRenderPipelineState(linePipeline)
            enc.setDepthStencilState(testDepth)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&views, length: viewsLength, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
        }
    }

    /// 和 Objects.h 的 CONE_VERTICES 一致：(10 圈 - 1) × 12 × 6
    private static let coneVertexCount = 9 * 12 * 6

    // MARK: - 动态分辨率

    private struct ScaledTarget {
        var color: MTLTexture
        var depth: MTLTexture
        var colorArray: MTLTexture
        var depthArray: MTLTexture
        var map: MTLRasterizationRateMap
        var rates: [Float]
    }
    private var scaledTargets: [Int: ScaledTarget] = [:]
    private var resolveRateBuffers: [MTLBuffer] = []
    private var resolveRateIndex = 0

    /// 和 encode 一样，但整帧按 settings.renderScale 缩小了画：GPU 吃紧时用（M2 的 Vision Pro 上，地形关往下看
    /// 原生分辨率只有五十几帧）。做法：按系统给的 rate map 造一张「每处都再缩小 renderScale 倍」的 rate map，
    /// 场景照常画进一张小的中间缓冲（所有 shader 不用改：它们本来就按 rate map 把物理像素换回屏幕坐标），
    /// 最后一个全屏 pass 把颜色和深度放大回系统的画面。renderScale ≥ 1 时直接画，不走这条路。
    func encodeScaled(_ commandBuffer: MTLCommandBuffer,
                      views: [ViewUniforms],
                      viewports: [MTLViewport],
                      frame: FrameUniforms,
                      colorTexture: MTLTexture,
                      depthTexture: MTLTexture,
                      renderTargetArrayLength: Int,
                      rateMap: MTLRasterizationRateMap?,
                      objects: SceneObjects = SceneObjects(),
                      panel: (texture: MTLTexture, uniforms: PanelUniforms)? = nil,
                      hud: [HelmetHUD.Panel] = [], hudDirty: [MTLTexture] = [],
                      group: Int = 0) {
        let scale = settings.renderScale
        guard scale < 0.99, let target = scaledTarget(group: group, color: colorTexture, depth: depthTexture,
                                                       rateMap: rateMap, scale: scale) else {
            encode(commandBuffer, views: views, viewports: viewports, frame: frame, colorTexture: colorTexture,
                   depthTexture: depthTexture, renderTargetArrayLength: renderTargetArrayLength, rateMap: rateMap,
                   objects: objects, panel: panel, hud: hud, hudDirty: hudDirty, group: group)
            return
        }
        encode(commandBuffer, views: views, viewports: viewports, frame: frame, colorTexture: target.color,
               depthTexture: target.depth, renderTargetArrayLength: renderTargetArrayLength, rateMap: target.map,
               objects: objects, panel: panel, hud: hud, hudDirty: hudDirty, group: group)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .dontCare
        pass.depthAttachment.storeAction = .store
        pass.renderTargetArrayLength = renderTargetArrayLength
        pass.rasterizationRateMap = rateMap
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Resolve"
        enc.setViewports(viewports)
        if views.count > 1 {
            var mappings = (0..<views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            enc.setVertexAmplificationCount(views.count, viewMappings: &mappings)
        }
        enc.setRenderPipelineState(resolvePipeline)
        enc.setDepthStencilState(alwaysWriteDepth)
        // 两张 rate map 的参数各拷一份（场景那一遍用的缓冲是轮换的，这里另开一组，免得被覆盖）
        func parameters(_ map: MTLRasterizationRateMap) -> MTLBuffer {
            let size = map.parameterDataSizeAndAlign.size
            if resolveRateBuffers.count < 8 {
                resolveRateBuffers.append(device.makeBuffer(length: max(size, 512), options: .storageModeShared)!)
                resolveRateIndex = resolveRateBuffers.count - 1
            } else if resolveRateBuffers[resolveRateIndex].length < size {
                resolveRateBuffers[resolveRateIndex] = device.makeBuffer(length: size, options: .storageModeShared)!
            }
            let buffer = resolveRateBuffers[resolveRateIndex]
            resolveRateIndex = (resolveRateIndex + 1) % 8
            map.copyParameterData(buffer: buffer, offset: 0)
            return buffer
        }
        enc.setFragmentBuffer(rateMap.map(parameters) ?? emptyRateMapBuffer, offset: 0, index: 2)
        enc.setFragmentBuffer(parameters(target.map), offset: 0, index: 4)
        var info = SIMD4<Float>(1 / Float(target.color.width), 1 / Float(target.color.height), rateMap == nil ? 0 : 1, 0)
        enc.setFragmentBytes(&info, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
        enc.setFragmentTexture(target.colorArray, index: 0)
        enc.setFragmentTexture(target.depthArray, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// 中间缓冲和它的 rate map。rate map：把系统那张在横竖各 32 个点上采样（屏幕坐标 → 物理坐标的斜率就是那里的比例），
    /// 每处的比例封顶到 scale：只有视线中心那一块（系统给的比例高于 scale 的地方）变粗，四周原样不动。
    /// 第一版是每处都再乘 scale：四周本来就被注视点渲染压到三四成，再乘一次只剩一两成，戴上能看到一圈糊得很厉害。
    /// 系统的图没变（比例一样）就接着用上一帧造的。
    private func scaledTarget(group: Int, color: MTLTexture, depth: MTLTexture, rateMap: MTLRasterizationRateMap?,
                              scale: Float) -> ScaledTarget? {
        let samples = 32
        let layerCount = max(rateMap?.layerCount ?? 1, 1)
        let screen = rateMap?.screenSize ?? MTLSize(width: color.width, height: color.height, depth: 0)
        var rates: [Float] = [scale]
        var layers: [MTLRasterizationRateLayerDescriptor] = []
        for layer in 0..<layerCount {
            var horizontal = [Float](repeating: scale, count: samples), vertical = horizontal
            if let rateMap {
                func physical(_ x: Double, _ y: Double) -> MTLCoordinate2D {
                    rateMap.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: Float(x), y: Float(y)), layer: layer)
                }
                let w = Double(screen.width), h = Double(screen.height)
                for i in 0..<samples {
                    let a = Double(i) / Double(samples), b = Double(i + 1) / Double(samples)
                    let dx = physical(b * w, h / 2).x - physical(a * w, h / 2).x
                    let dy = physical(w / 2, b * h).y - physical(w / 2, a * h).y
                    horizontal[i] = min(max(dx / Float(w / Double(samples)), 0.02), scale)
                    vertical[i] = min(max(dy / Float(h / Double(samples)), 0.02), scale)
                }
            }
            rates += horizontal + vertical
            layers.append(MTLRasterizationRateLayerDescriptor(horizontal: horizontal, vertical: vertical))
        }
        if let cached = scaledTargets[group], cached.rates == rates,
           cached.color.arrayLength == color.arrayLength, cached.color.textureType == color.textureType {
            return cached
        }
        let descriptor = MTLRasterizationRateMapDescriptor(screenSize: screen, layers: layers)
        guard let map = device.makeRasterizationRateMap(descriptor: descriptor) else { return nil }
        // 中间缓冲要装得下每一层的物理尺寸；留一点余量，注视点跟着眼睛动、尺寸小幅变的时候不用每帧重新分配
        var needWidth = 0, needHeight = 0
        for layer in 0..<layerCount {
            let size = map.physicalSize(layer: layer)
            needWidth = max(needWidth, size.width)
            needHeight = max(needHeight, size.height)
        }
        if var cached = scaledTargets[group], cached.color.arrayLength == color.arrayLength,
           cached.color.textureType == color.textureType,
           cached.color.width >= needWidth, cached.color.width <= needWidth + 160,
           cached.color.height >= needHeight, cached.color.height <= needHeight + 160 {
            cached.map = map
            cached.rates = rates
            scaledTargets[group] = cached
            return cached
        }
        let width = (needWidth / 32 + 2) * 32, height = (needHeight / 32 + 2) * 32
        func make(_ like: MTLTexture) -> (MTLTexture, MTLTexture)? {
            let d = MTLTextureDescriptor()
            d.textureType = like.textureType
            d.pixelFormat = like.pixelFormat
            d.width = width
            d.height = height
            d.arrayLength = like.arrayLength
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            if t.textureType == .type2DArray { return (t, t) }
            guard let view = t.makeTextureView(pixelFormat: t.pixelFormat, textureType: .type2DArray, levels: 0..<1,
                                               slices: 0..<1) else { return nil }
            return (t, view)
        }
        guard let c = make(color), let z = make(depth) else { return nil }
        let target = ScaledTarget(color: c.0, depth: z.0, colorArray: c.1, depthArray: z.1, map: map, rates: rates)
        scaledTargets[group] = target
        return target
    }

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
