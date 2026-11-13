import Metal
import simd

/// 和 Objects.h 的 ShadowPassUniforms 一样
struct ShadowPassUniforms {
    /// xyz 贴图的横轴（舞台空间的单位向量，垂直于阳光），w 1 / 半宽（米）
    var u: SIMD4<Float>
    /// xyz 贴图的纵轴
    var v: SIMD4<Float>
    /// xy 贴图中心在（横轴, 纵轴）上的坐标（米）
    var center: SIMD4<Float>
}

/// 伞和人的影子：每帧从太阳的方向把伞衣、人各画进一张小贴图（正交投影的剪影），地面、物件、装备着色时
/// 顺着阳光找到贴图上对应的位置查一下（Common.h 的 canopyShadow / bodyShadow）。
///
/// 之前两个影子都是公式算的：伞是一块圆角长方形的平板、九个气室的透光颜色写死在 shader 里，
/// 人是一根粗细变化的柱子加两根胶囊。换成贴图以后形状是真的（伞衣鼓起来的气室、塌下去的样子、头盔、伞包、两条腿），
/// 伞那张存的是透过伞布的光的颜色，按伞衣的皮肤图案算（Skins.h，和主 pass 的伞衣同一个函数）——换了伞，影子的颜色跟着变。
/// 两张分开：伞一张、人一张，各管各的。
///
/// 离地越高影子越虚（太阳是个 0.53° 的圆盘）：贴图带 mip，按「太阳圆盘投到遮挡物那里有多大」取模糊的那一级。
final class PlayerShadow {
    /// 伞那张 512²（伞衣十米见方，一格两厘米）；人那张 512²（三米多见方，一格不到一厘米：256² 时落地脚下的影子能看出台阶）
    static let canopyMapSize = 512
    static let bodyMapSize = 512

    /// rgb 透过伞布的光（没挡住的地方是 1）
    let canopyMap: MTLTexture
    /// r 没被身体挡住的比例
    let bodyMap: MTLTexture

    /// 这一帧两张贴图的摆法，填进 FrameUniforms
    struct Placement {
        /// xyz 横轴，w 伞那张的半宽（米）
        var u = SIMD4<Float>(1, 0, 0, 1)
        /// xyz 纵轴，w 人那张的半宽
        var v = SIMD4<Float>(0, 0, 1, 1)
        /// xy 伞那张的中心（横轴, 纵轴上的坐标），zw 人那张的
        var centers = SIMD4<Float>(0, 0, 0, 0)
    }

    private let canopyPipeline: MTLRenderPipelineState
    private let bodyPipeline: MTLRenderPipelineState
    private var canopyBuffers: [MTLBuffer] = []
    private var bodyBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private static let maxCanopyVertices = 40_000
    private static let maxBodyVertices = 12_000

    init(device: MTLDevice, library: MTLLibrary) throws {
        func map(_ format: MTLPixelFormat, _ size: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        // 伞：两层布各乘一次透光率，深蓝的那几格透过来的只有万分之几，8 位存不下
        canopyMap = map(.rgba16Float, Self.canopyMapSize)
        bodyMap = map(.r8Unorm, Self.bodyMapSize)

        func pipeline(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat, multiply: Bool) throws -> MTLRenderPipelineState {
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw SceneRenderer.RendererError.missingFunction(vertex)
            }
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = v
            d.fragmentFunction = f
            let c = d.colorAttachments[0]!
            c.pixelFormat = format
            if multiply {
                // 每画一层布，把已经透过来的光再乘上这一层的透光率（上下两层布、叠在一起的褶子都这么算）
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .destinationColor
                c.destinationRGBBlendFactor = .zero
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .zero
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        canopyPipeline = try pipeline("canopyShadowVertex", "canopyShadowFragment", .rgba16Float, multiply: true)
        bodyPipeline = try pipeline("bodyShadowVertex", "bodyShadowFragment", .r8Unorm, multiply: false)
        for _ in 0..<4 {
            canopyBuffers.append(device.makeBuffer(length: MemoryLayout<MeshVertex>.stride * Self.maxCanopyVertices,
                                                   options: .storageModeShared)!)
            bodyBuffers.append(device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * Self.maxBodyVertices,
                                                 options: .storageModeShared)!)
        }
    }

    /// 每帧调一次（主 pass 之前）。sun：指向太阳的方向（舞台空间）。没开伞 / 还在机舱里的那张不画（着色那边按强度是 0 跳过）
    /// skin：伞那张按皮肤的图案算透过来的颜色（和主 pass 的伞衣同一个函数）
    func encode(_ commandBuffer: MTLCommandBuffer, objects: SceneObjects, sun: SIMD3<Float>,
                skin: SkinUniforms = SkinChoice().uniforms) -> Placement {
        var placement = Placement()
        let L = simd_normalize(sun)
        // 贴图的两根轴：垂直于阳光。横轴取水平的那根
        var u = simd_cross(SIMD3<Float>(0, 1, 0), L)
        u = simd_length_squared(u) > 1e-6 ? simd_normalize(u) : SIMD3<Float>(1, 0, 0)
        let v = simd_cross(L, u)
        placement.u = SIMD4(u, 1)
        placement.v = SIMD4(v, 1)
        let slot = bufferIndex
        bufferIndex = (bufferIndex + 1) % canopyBuffers.count
        var drawn: [MTLTexture] = []

        /// 把一堆点框进贴图：中心和半宽（四周留四分之一的边，影子的虚边要地方）。
        /// 半宽按 step 往上取整、中心对齐到纹素网格：每帧按包围盒原样重算的话，纹素网格每帧都在缩放平移，
        /// 剪影的边（尤其是人那张）会在地上一格格地爬（顺着阳光的两根轴只在转向时转，直飞时影子是稳的）
        /// alignTexels：中心对齐到几个纹素的格子（人那张落地时实际取的是第 1 级 mip，按 2 个纹素对齐，mip1 的相位才不跳）
        func fit(_ count: Int, mapSize: Int, step: Float, alignTexels: Float = 1,
                 _ point: (Int) -> SIMD3<Float>) -> (center: SIMD2<Float>, half: Float) {
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for i in 0..<count {
                let p = point(i)
                let q = SIMD2(simd_dot(p, u), simd_dot(p, v))
                lo = simd_min(lo, q)
                hi = simd_max(hi, q)
            }
            let size = hi - lo
            let half = ((max(size.x, size.y) / 2 * 1.25 + 0.15) / step).rounded(.up) * step
            let texel = 2 * half / Float(mapSize) * alignTexels
            return ((((lo + hi) / 2) / texel).rounded(.toNearestOrEven) * texel, half)
        }
        func pass(_ texture: MTLTexture, _ pipeline: MTLRenderPipelineState, _ buffer: MTLBuffer, count: Int,
                  center: SIMD2<Float>, half: Float, label: String) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = texture
            d.colorAttachments[0].loadAction = .clear
            d.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
            d.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: d) else { return }
            enc.label = label
            var uniforms = ShadowPassUniforms(u: SIMD4(u, 1 / half), v: SIMD4(v, 0), center: SIMD4(center.x, center.y, 0, 0))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<ShadowPassUniforms>.stride, index: 1)
            var skin = skin
            enc.setFragmentBytes(&skin, length: MemoryLayout<SkinUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
            enc.endEncoding()
            drawn.append(texture)
        }

        // 伞：伞衣网格里的那一段，原样拷过来（舞台空间）
        if objects.canopyShadow != nil, let range = objects.canopyMeshRange, !range.isEmpty {
            let count = min(range.count, Self.maxCanopyVertices)
            let stride = MemoryLayout<MeshVertex>.stride
            objects.meshVertices.withUnsafeBytes { raw in
                canopyBuffers[slot].contents().copyMemory(from: raw.baseAddress! + range.lowerBound * stride, byteCount: count * stride)
            }
            let box = fit(count, mapSize: Self.canopyMapSize, step: 0.5) { i in
                let p = objects.meshVertices[range.lowerBound + i].position
                return SIMD3(p.x, p.y, p.z)
            }
            placement.u.w = box.half
            placement.centers.x = box.center.x
            placement.centers.y = box.center.y
            pass(canopyMap, canopyPipeline, canopyBuffers[slot], count: count, center: box.center, half: box.half,
                 label: "Canopy shadow map")
        }

        // 人
        if let top = objects.bodyTop {
            let body = Self.body(top: top, right: objects.bodyRight, wrists: objects.wrists)
            let count = min(body.count, Self.maxBodyVertices)
            body.withUnsafeBytes { raw in
                bodyBuffers[slot].contents().copyMemory(from: raw.baseAddress!, byteCount: count * MemoryLayout<SIMD4<Float>>.stride)
            }
            let box = fit(count, mapSize: Self.bodyMapSize, step: 0.25, alignTexels: 2) { i in SIMD3(body[i].x, body[i].y, body[i].z) }
            placement.v.w = box.half
            placement.centers.z = box.center.x
            placement.centers.w = box.center.y
            pass(bodyMap, bodyPipeline, bodyBuffers[slot], count: count, center: box.center, half: box.half,
                 label: "Body shadow map")
        }

        if !drawn.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for t in drawn { blit.generateMipmaps(for: t) }
            blit.endEncoding()
        }
        return placement
    }

    // MARK: - 人的剪影

    /// 标准身高（头顶到脚底，米）：真人头的高度不一样（坐着玩的更矮），竖直方向按「头顶到舞台地板」整体缩放
    private static let standardHeight: Float = 1.72
    /// 肩膀（身体坐标：x 右，y 从头顶往下，z 前）
    private static let shoulder = SIMD3<Float>(0.19, 0.36, 0)

    /// 不动的那部分（头盔、脖子、躯干、伞包、两条腿），身体坐标里的三角形，算一次
    private static let torsoAndLegs: [SIMD3<Float>] = {
        var t: [SIMD3<Float>] = []
        // 头盔
        ellipsoid(&t, center: SIMD3(0, 0.125, 0.01), radii: SIMD3(0.125, 0.135, 0.14))
        // 脖子
        limb(&t, SIMD3(0, 0.22, 0), SIMD3(0, 0.31, 0), 0.058, 0.062)
        // 躯干：一圈圈椭圆，肩宽、胸、腰、胯
        let rings: [(y: Float, rx: Float, rz: Float)] = [
            (0.295, 0.10, 0.08), (0.335, 0.20, 0.105), (0.39, 0.215, 0.12), (0.52, 0.185, 0.128),
            (0.70, 0.155, 0.112), (0.86, 0.175, 0.122), (0.96, 0.165, 0.115),
        ]
        let around = 16
        func ring(_ k: Int, _ j: Int) -> SIMD3<Float> {
            let a = 2 * Float.pi * Float(j % around) / Float(around)
            return SIMD3(cos(a) * rings[k].rx, rings[k].y, sin(a) * rings[k].rz)
        }
        for k in 0..<(rings.count - 1) {
            for j in 0..<around {
                t += [ring(k, j), ring(k + 1, j), ring(k, j + 1), ring(k, j + 1), ring(k + 1, j), ring(k + 1, j + 1)]
            }
        }
        for j in 0..<around {                         // 上下封口
            t += [SIMD3(0, rings[0].y, 0), ring(0, j), ring(0, j + 1)]
            t += [SIMD3(0, rings[rings.count - 1].y, 0), ring(rings.count - 1, j + 1), ring(rings.count - 1, j)]
        }
        // 肩头
        for side: Float in [-1, 1] { ellipsoid(&t, center: SIMD3(side * shoulder.x, shoulder.y + 0.01, 0), radii: SIMD3(repeating: 0.075), rings: 6, around: 10) }
        // 背上的伞包
        ellipsoid(&t, center: SIMD3(0, 0.57, -0.165), radii: SIMD3(0.165, 0.25, 0.085))
        // 两条腿：吊在背带里，膝盖微微往前，脚尖朝前
        for side: Float in [-1, 1] {
            let hip = SIMD3<Float>(side * 0.095, 0.93, 0), knee = SIMD3<Float>(side * 0.11, 1.31, 0.11)
            let ankle = SIMD3<Float>(side * 0.11, 1.65, 0.03)
            limb(&t, hip, knee, 0.088, 0.064)
            limb(&t, knee, ankle, 0.062, 0.046)
            ellipsoid(&t, center: knee, radii: SIMD3(repeating: 0.064), rings: 6, around: 10)
            ellipsoid(&t, center: SIMD3(side * 0.11, 1.685, 0.10), radii: SIMD3(0.052, 0.038, 0.135), rings: 6, around: 10)
        }
        return t
    }()

    /// 这一帧的人（舞台空间）。top：头顶；right：身体的右方向；wrists：左、右手腕（w = 追踪到没有）
    static func body(top: SIMD3<Float>, right: SIMD3<Float>, wrists: (SIMD4<Float>, SIMD4<Float>)) -> [SIMD4<Float>] {
        let r = simd_normalize(SIMD3(right.x, 0, right.z))
        let forward = simd_cross(SIMD3<Float>(0, 1, 0), r)          // 右是 +x 时，前是 -z
        let scale = max(top.y - 0.12, 0.6) / standardHeight
        func place(_ p: SIMD3<Float>) -> SIMD3<Float> { top + r * p.x - SIMD3(0, p.y * scale, 0) + forward * p.z }
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(torsoAndLegs.count + 1600)
        for p in torsoAndLegs { out.append(SIMD4(place(p), 1)) }
        // 两条胳膊：肩膀 → 手腕（手举着操纵环，影子里的胳膊也举着，跟着你的手动），再往前伸出一只手。追踪不到手就不画
        var arms: [SIMD3<Float>] = []
        for (i, wrist) in [wrists.0, wrists.1].enumerated() where wrist.w > 0 {
            let from = place(SIMD3(i == 0 ? -shoulder.x : shoulder.x, shoulder.y, 0))
            let to = SIMD3(wrist.x, wrist.y, wrist.z)
            let span = to - from
            let length = simd_length(span)
            guard length > 0.05 else { continue }
            let direction = span / length
            limb(&arms, from, to, 0.056, 0.042)
            ellipsoid(&arms, center: to + direction * 0.085, radii: SIMD3(repeating: 0.052), rings: 6, around: 10)
        }
        for p in arms { out.append(SIMD4(p, 1)) }
        return out
    }

    private static func ellipsoid(_ t: inout [SIMD3<Float>], center: SIMD3<Float>, radii: SIMD3<Float>, rings: Int = 8, around: Int = 12) {
        func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let theta = Float.pi * Float(i) / Float(rings), phi = 2 * Float.pi * Float(j % around) / Float(around)
            return center + radii * SIMD3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
        }
        for i in 0..<rings {
            for j in 0..<around {
                t += [point(i, j), point(i + 1, j), point(i, j + 1), point(i, j + 1), point(i + 1, j), point(i + 1, j + 1)]
            }
        }
    }

    /// 一段四肢：两头粗细不一样的圆台（接头的地方另外放球）
    private static func limb(_ t: inout [SIMD3<Float>], _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float, around: Int = 10) {
        let axis = simd_normalize(b - a)
        let ref: SIMD3<Float> = abs(axis.y) > 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let x = simd_normalize(simd_cross(axis, ref)), z = simd_cross(axis, x)
        func point(_ end: Bool, _ j: Int) -> SIMD3<Float> {
            let phi = 2 * Float.pi * Float(j % around) / Float(around)
            return (end ? b : a) + (x * cos(phi) + z * sin(phi)) * (end ? rb : ra)
        }
        for j in 0..<around {
            t += [point(false, j), point(true, j), point(false, j + 1), point(false, j + 1), point(true, j), point(true, j + 1)]
        }
    }
}
