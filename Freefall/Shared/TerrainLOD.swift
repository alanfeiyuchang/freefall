import Foundation
import simd

/// 和 Terrain.h 的 TerrainNode 一样：一块地形网格
struct TerrainNode {
    /// xy 块一角的地面坐标（绝对），z 边长（米），w LOD 级别
    var origin: SIMD4<Float>
    /// xy 同一角相对舞台原点的地面坐标（双精度算好再转 float：近处的顶点不会因为 float 精度抖）
    var relative: SIMD4<Float>
}

/// 和 Terrain.h 的 TerrainUniforms 一样
struct TerrainUniforms {
    /// xyz 头在舞台空间的位置，w 场景编号
    var camera: SIMD4<Float>
    /// x 0 级块用到的距离，y 海面以下按海画（1/0）
    var lod: SIMD4<Float>
}

/// 地形网格的 LOD（CDLOD，Strugar 2009）：一棵很大的四叉树（根 1,048 km 见方，盖过地平线），
/// 按每块到头的距离往下分，选出来的块都画成同一张 16×16 格的网格，越远的块越大、格越粗。
/// 顶点着色器里按到头的距离把块外圈的顶点往粗一级的网格上靠（morph），相邻两级之间没有缝。
/// 块的角都在 32 米的整数倍上，float 能精确表示，取噪声不抖。
enum TerrainLOD {
    static let grid = 16
    /// 0 级块边长（米）：格距 2 米
    static let leafSize: Double = 32
    static let levels = 15
    /// 0 级块用到多远；往上每一级翻倍
    static let range0: Double = 160
    static let maxNodes = 2500

    /// 选块。camera：头在地面坐标里的 (x, 海拔, z)；visible：块的包围球（地面坐标里的球心 x/海拔/z，半径）在不在视野里
    static func select(camera: SIMD3<Double>, heightRange: (Double, Double),
                       visible: (SIMD3<Double>, Double) -> Bool, into nodes: inout [(SIMD2<Double>, Double, Int)]) {
        nodes.removeAll(keepingCapacity: true)
        let rootSize = leafSize * Double(1 << levels)
        visit(origin: SIMD2(-rootSize / 2, -rootSize / 2), size: rootSize, level: levels, camera: camera,
              heightRange: heightRange, visible: visible, nodes: &nodes)
    }

    private static func visit(origin: SIMD2<Double>, size: Double, level: Int, camera: SIMD3<Double>,
                              heightRange: (Double, Double), visible: (SIMD3<Double>, Double) -> Bool,
                              nodes: inout [(SIMD2<Double>, Double, Int)]) {
        guard nodes.count < maxNodes else { return }
        let midH = (heightRange.0 + heightRange.1) / 2
        let center = SIMD3(origin.x + size / 2, midH, origin.y + size / 2)
        let radius = (size * size / 2 + (heightRange.1 - heightRange.0) * (heightRange.1 - heightRange.0) / 4).squareRoot()
        guard visible(center, radius) else { return }
        if level == 0 || distance(camera, origin: origin, size: size, heightRange: heightRange)
            > range0 * Double(1 << (level - 1)) {
            nodes.append((origin, size, level))
            return
        }
        let half = size / 2
        for (dx, dz) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            visit(origin: origin + SIMD2(dx, dz) * half, size: half, level: level - 1, camera: camera,
                  heightRange: heightRange, visible: visible, nodes: &nodes)
        }
    }

    /// 头到块的包围盒（高度取场景的海拔范围）的距离
    static func distance(_ camera: SIMD3<Double>, origin: SIMD2<Double>, size: Double,
                         heightRange: (Double, Double)) -> Double {
        let dx = max(origin.x - camera.x, 0, camera.x - (origin.x + size))
        let dz = max(origin.y - camera.z, 0, camera.z - (origin.y + size))
        let dy = max(heightRange.0 - camera.y, 0, camera.y - heightRange.1)
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// 一块 16×16 格网格的索引（顶点按行排，(16+1)² 个，下标在顶点着色器里换算成格子坐标）
    static func patchIndices() -> [UInt16] {
        var indices: [UInt16] = []
        let n = grid + 1
        for j in 0..<grid {
            for i in 0..<grid {
                let a = UInt16(j * n + i), b = a + 1, c = a + UInt16(n), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return indices
    }
}

/// 这一帧地形要用的信息（JumpSession 填，SceneRenderer 选块用）
struct TerrainFrame {
    var scene: JumpScene
    /// 舞台原点在地面坐标里的位置（双精度）
    var groundOrigin: SIMD2<Double>
    /// 舞台 y + 它 = 海拔
    var stageToAltitude: Double
    /// 航向（弧度）
    var heading: Double
}
