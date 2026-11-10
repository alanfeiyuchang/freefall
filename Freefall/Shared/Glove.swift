import Foundation
import Metal
import MetalKit
import simd

/// 手套：苹果示例「Animating hand models in visionOS」里的两只手套，换成跳伞配色（转换见 tools/gloves/convert_gloves.py）。
/// 戴手套时把透视进来的真手藏掉（upperLimbVisibility = hidden），手套按手部追踪的 27 个关节蒙皮，
/// 和装备用同一套光（太阳、伞衣的影子、天空反射、舱里的红灯）。
///
/// 网格文件（小端）：
///   "GLV1"、顶点数、索引数、关节数（27）
///   27 × float3 关节在绑定姿势里的位置（米），顺序和 ARKit 手部骨骼一致（= HandJoint）
///   顶点 × 40 字节：float3 位置、float u、float3 法线、float v、uchar4 关节、uchar4 权重（和 255）
///   索引 × uint32
struct GloveMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let albedo: MTLTexture
    /// 绑定姿势里每个关节的坐标系的逆（蒙皮矩阵 = 现在的坐标系 × 它）
    let inverseBindFrames: [simd_float4x4]
}

struct GloveSet {
    let left: GloveMesh
    let right: GloveMesh
    /// 两只共用：切线空间法线；R 粗糙度、G 环境光遮蔽、B 高光强度（sRGB 编码）
    let normal: MTLTexture
    let material: MTLTexture

    /// 从目录读（app 里是 bundle 根目录，离屏测试是仓库里的 Freefall/Resources/Gloves）。缺文件返回 nil。
    init?(device: MTLDevice, directory: URL) {
        let loader = MTKTextureLoader(device: device)
        func texture(_ name: String, srgb: Bool) -> MTLTexture? {
            try? loader.newTexture(URL: directory.appendingPathComponent(name), options: [
                .SRGB: srgb, .generateMipmaps: true, .textureStorageMode: MTLStorageMode.private.rawValue,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            ])
        }
        func mesh(_ side: String) -> GloveMesh? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("Glove\(side).mesh")),
                  data.count > 16, data.prefix(4) == Data("GLV1".utf8),
                  let albedo = texture("Glove\(side)_albedo.png", srgb: true) else { return nil }
            return data.withUnsafeBytes { raw -> GloveMesh? in
                let header = raw.loadUnaligned(fromByteOffset: 4, as: (UInt32, UInt32, UInt32).self)
                let vertexCount = Int(header.0), indexCount = Int(header.1), jointCount = Int(header.2)
                guard jointCount == HandJoint.allCases.count else { return nil }
                let jointsOffset = 16, verticesOffset = jointsOffset + jointCount * 12
                let indicesOffset = verticesOffset + vertexCount * 40
                guard raw.count >= indicesOffset + indexCount * 4,
                      let vb = device.makeBuffer(bytes: raw.baseAddress! + verticesOffset, length: vertexCount * 40,
                                                 options: .storageModeShared),
                      let ib = device.makeBuffer(bytes: raw.baseAddress! + indicesOffset, length: indexCount * 4,
                                                 options: .storageModeShared) else { return nil }
                vb.label = "Glove\(side) vertices"
                var bind: [SIMD3<Float>] = []
                for i in 0..<jointCount {
                    let o = jointsOffset + i * 12
                    bind.append(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                }
                return GloveMesh(vertexBuffer: vb, indexBuffer: ib, indexCount: indexCount, albedo: albedo,
                                 inverseBindFrames: GloveRig.frames(bind).map { $0.inverse })
            }
        }
        guard let left = mesh("Left"), let right = mesh("Right"),
              let normal = texture("Glove_normal.png", srgb: false),
              let material = texture("Glove_material.png", srgb: false) else { return nil }
        self.left = left
        self.right = right
        self.normal = normal
        self.material = material
    }
}

/// 只用关节位置推每个关节的坐标系（骨头方向 + 手掌法线定扭转），绑定姿势和现在的手用同一套推法，
/// 蒙皮矩阵 = 现在的坐标系 × 绑定坐标系的逆。ARKit 给的关节朝向用不上（离屏测试的合成手也只有位置），
/// 手指绕自己轴的扭转按手掌算，误差很小。手比手套大或小时，每节手指跟着真的关节走，中间自然拉伸。
enum GloveRig {
    /// 每根骨头的下一个关节（指尖没有，用上一节的方向）
    private static let child: [Int?] = [
        nil,                         // 腕：用整只手的坐标系
        2, 3, 4, nil,                // 拇指
        6, 7, 8, 9, nil,             // 食指
        11, 12, 13, 14, nil,         // 中指
        16, 17, 18, 19, nil,         // 无名指
        21, 22, 23, 24, nil,         // 小指
        nil, nil,                    // 前臂（腕端、靠肘那端）：沿前臂
    ]

    static func frames(_ p: [SIMD3<Float>]) -> [simd_float4x4] {
        let wrist = p[HandJoint.wrist.rawValue]
        var forward = p[HandJoint.middleKnuckle.rawValue] - wrist
        forward = length(forward) > 1e-5 ? normalize(forward) : SIMD3(0, 0, -1)
        var across = p[HandJoint.indexKnuckle.rawValue] - p[HandJoint.littleKnuckle.rawValue]
        across = length(across) > 1e-5 ? normalize(across) : SIMD3(1, 0, 0)
        var palm = cross(forward, across)
        palm = length(palm) > 1e-5 ? normalize(palm) : SIMD3(0, 1, 0)

        func frame(_ origin: SIMD3<Float>, along d: SIMD3<Float>) -> simd_float4x4 {
            var y = palm - dot(palm, d) * d
            if length(y) < 1e-3 { y = across - dot(across, d) * d }
            y = normalize(y)
            let z = cross(d, y)
            return simd_float4x4(columns: (SIMD4(d, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1)))
        }

        var arm = p[HandJoint.forearmArm.rawValue] - p[HandJoint.forearmWrist.rawValue]
        arm = length(arm) > 1e-4 ? normalize(arm) : -forward

        var result: [simd_float4x4] = []
        result.reserveCapacity(p.count)
        for i in 0..<p.count {
            if i == HandJoint.wrist.rawValue {
                result.append(frame(wrist, along: forward))
            } else if i == HandJoint.forearmWrist.rawValue || i == HandJoint.forearmArm.rawValue {
                result.append(frame(p[i], along: arm))
            } else if let c = child[i] {
                let d = p[c] - p[i]
                result.append(frame(p[i], along: length(d) > 1e-5 ? normalize(d) : forward))
            } else {
                let d = p[i] - p[i - 1]       // 指尖：沿上一节
                result.append(frame(p[i], along: length(d) > 1e-5 ? normalize(d) : forward))
            }
        }
        return result
    }

    /// 27 个蒙皮矩阵（舞台空间）
    static func skinning(_ hand: HandPose, mesh: GloveMesh) -> [simd_float4x4] {
        let current = frames(hand.joints)
        return (0..<current.count).map { current[$0] * mesh.inverseBindFrames[$0] }
    }
}
