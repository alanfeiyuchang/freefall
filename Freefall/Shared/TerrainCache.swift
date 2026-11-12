import Metal
import simd

/// 光照缓存（见 Terrain.h 的「光照缓存」）：一摞以相机为中心的地面贴图，存地形算完光照以后的颜色。
/// 一共 levels 层，每层 size² 个纹素，纹素边长从 texel0 起一层层翻倍。相机离某一层的中心超过两成半宽，
/// 就按新的中心重画这一层：画进一张备用的贴图层，每帧只画一条（strips 帧画完），画完和原来那层对调——
/// 画的过程中片元一直用旧的那层，没有半新半旧的时候，也不会哪一帧突然多出一大笔开销。
final class TerrainCache {
    static let levels = 10
    static let texel0: Double = 0.03125
    /// 一层分几帧画完
    static let strips = 16

    let size: Int
    /// 颜色（开方以后存 10 位，见 Terrain.h 的 cacheEncode）
    let color: MTLTexture
    /// r 这里是水（不用缓存，现算），g 颜色里太阳直射占多少
    let info: MTLTexture
    let uniforms: MTLBuffer
    private let pipeline: MTLComputePipelineState?
    private let enabled: Bool
    /// 每一层：现在用的中心对应的角（nil = 还没画好）、存在贴图数组的第几层
    private var origins: [SIMD2<Double>?]
    /// 每一层烘焙时云影图相对地面的位置（机舱里地面不跟着飞机走，云影在地上滑；滑远了要重画）
    private var shifts: [SIMD2<Float>]
    private var slices: [Int]
    private var spare: Int
    private var job: (level: Int, origin: SIMD2<Double>, shift: SIMD2<Float>, row: Int)?
    /// 离屏测试用：一帧里把所有该重画的层都画完（测试每个镜头只画几帧，等不了后台慢慢画）
    var immediate = false

    init(device: MTLDevice, library: MTLLibrary, enabled: Bool) throws {
        self.enabled = enabled
        let side = enabled ? 2048 : 4
        size = side
        func array(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = format
            d.width = side
            d.height = side
            d.arrayLength = enabled ? Self.levels + 1 : 1
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        color = array(.rgb10a2Unorm)
        info = array(.rg8Unorm)
        uniforms = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * (Self.levels + 1), options: .storageModeShared)!
        origins = Array(repeating: nil, count: Self.levels)
        shifts = Array(repeating: .zero, count: Self.levels)
        slices = Array(0..<Self.levels)
        spare = Self.levels
        if enabled {
            guard let f = library.makeFunction(name: "bakeTerrainCache") else {
                throw SceneRenderer.RendererError.missingFunction("bakeTerrainCache")
            }
            pipeline = try device.makeComputePipelineState(function: f)
        } else {
            pipeline = nil
        }
        writeUniforms()
    }

    private func texel(_ level: Int) -> Double { Self.texel0 * Double(1 << level) }

    private func writeUniforms() {
        let p = uniforms.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.levels + 1)
        for i in 0..<Self.levels {
            if let o = origins[i], enabled {
                p[i] = SIMD4(Float(o.x), Float(o.y), Float(texel(i)), Float(slices[i]))
            } else {
                p[i] = SIMD4(0, 0, Float(texel(i)), -1)
            }
        }
        p[Self.levels] = SIMD4(enabled ? Float(size) : 0, Float(Self.texel0), 0, 0)
    }

    /// 每帧调一次（地形 pass 之前）。camera：相机在地面坐标里的位置
    func update(_ commandBuffer: MTLCommandBuffer, camera: SIMD2<Double>, scene: JumpScene, frame: FrameUniforms,
                atmosphere: MTLBuffer, noise: MTLTexture, surfaceMap: MTLTexture, detail: MTLTexture,
                skySeaLUT: MTLTexture, cloudShadow: MTLTexture, terrainShade: MTLTexture) {
        guard enabled, let pipeline else { return }
        let shift = SIMD2<Float>(frame.ground.y, frame.ground.w)
        var frame = frame
        var budget = immediate ? Self.levels * Self.strips : 1
        var encoder: MTLComputeCommandEncoder?
        while budget > 0 {
            if job == nil {
                // 先画还没有的层（从粗到细：粗的先有，细的没画好时片元还能退到粗的），再画相机走远了的层（从细到粗）
                var pick: Int?
                for level in stride(from: Self.levels - 1, through: 0, by: -1) where origins[level] == nil { pick = level; break }
                if pick == nil {
                    for level in 0..<Self.levels {
                        let half = texel(level) * Double(size) / 2
                        let center = origins[level]! + SIMD2(half, half)
                        if max(abs(camera.x - center.x), abs(camera.y - center.y)) > 0.2 * half
                            || simd_length(shift - shifts[level]) > 40 { pick = level; break }
                    }
                }
                guard let level = pick else { break }
                // 新的角：相机在中间，对齐到 32 个纹素的整数倍（重画以后纹素还落在原来的格点上，内容不跳）
                let t = texel(level), snap = t * 32
                let corner = camera - SIMD2(t * Double(size) / 2, t * Double(size) / 2)
                job = (level, SIMD2((corner.x / snap).rounded() * snap, (corner.y / snap).rounded() * snap), shift, 0)
            }
            guard var current = job else { break }
            if encoder == nil {
                encoder = commandBuffer.makeComputeCommandEncoder()
                encoder?.label = "Terrain cache"
                encoder?.setComputePipelineState(pipeline)
                encoder?.setTexture(color, index: 0)
                encoder?.setTexture(info, index: 1)
                encoder?.setTexture(noise, index: 2)
                encoder?.setTexture(surfaceMap, index: 3)
                encoder?.setTexture(detail, index: 4)
                encoder?.setTexture(skySeaLUT, index: 5)
                encoder?.setTexture(cloudShadow, index: 6)
                encoder?.setTexture(terrainShade, index: 7)
                encoder?.setBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder?.setBuffer(atmosphere, offset: 0, index: 2)
            }
            let rows = size / Self.strips
            var bake = (SIMD4<Float>(Float(current.origin.x), Float(current.origin.y), Float(texel(current.level)), Float(spare)),
                        SIMD4<Int32>(Int32(current.row), Int32(scene.rawValue), 0, 0))
            encoder?.setBytes(&bake, length: MemoryLayout.stride(ofValue: bake), index: 0)
            encoder?.dispatchThreadgroups(MTLSize(width: size / 16, height: rows / 16, depth: 1),
                                          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            current.row += rows
            budget -= 1
            if current.row >= size {
                // 画完：和原来那层对调（这一帧的片元在这个 compute 之后才跑，用的已经是新的）
                let old = slices[current.level]
                slices[current.level] = spare
                spare = old
                origins[current.level] = current.origin
                shifts[current.level] = current.shift
                job = nil
            } else {
                job = current
            }
        }
        encoder?.endEncoding()
        writeUniforms()
    }
}
