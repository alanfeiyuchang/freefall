import Foundation
import simd

/// 海岛这一关的实体模型（见 SceneProps）
enum IslandProps {
    static let layout: SkyCity.Layout = build()

    private static func build() -> SkyCity.Layout {
        // 雨林：一棵棵高矮不一的阔叶树；沙滩和草地上零星的椰子树（椰子树立在能落的地方，算障碍）
        var b = PropBuilder()
        var obstacles: [SkyCity.Obstacle] = []
        let palms = PropScatter.spots(scene: .island, radius: 750, spacing: 11, full: 2000, salt: 41) { p, h in
            h > 1.4 && h < 9 && TerrainField.islandForest(p) < 0.3 && simd_length(p - TerrainField.target) > 75
                && TerrainField.hash(Int32(p.x), Int32(p.y)) > 0.84
        }
        for s in palms.prefix(70) {
            let height = 6.5 + 4 * s.size
            b.palm(base: SIMD3(s.p.x, s.h, s.p.y), height: height, seed: s.seed)
            obstacles.append(.init(center: SIMD2(Double(s.p.x), Double(s.p.y)), radius: 1.6, top: Double(s.h + height)))
        }
        let spots = PropScatter.spots(scene: .island, radius: 2400, spacing: 9, full: 480) { p, h in
            h > 1 && TerrainField.islandForest(p) > 0.55 && TerrainField.slopeDegrees(.island, p) < 40
        }
        var farBatch = PropBuilder()       // 一公里开外的：朝镜头的片，单独一批
        for s in spots {
            guard b.v.count + farBatch.v.count < 170_000 else { break }
            let far = s.distance > 600
            let emergent: Float = s.size > 0.86 ? 1.6 : 1          // 隔几棵有一棵高出一头的大树
            let distant = s.distance > 1100
            let height = (9 + 9 * s.size) * emergent * (distant ? 1.5 : far ? 1.2 : 1)
            if distant {
                farBatch.broadleaf(base: SIMD3(s.p.x, s.h - 0.4, s.p.y), height: height, near: !far, seed: s.seed, green: SIMD3(0.017, 0.056, 0.020), distant: distant)
            } else {
                b.broadleaf(base: SIMD3(s.p.x, s.h - 0.4, s.p.y), height: height, near: !far, seed: s.seed, green: SIMD3(0.017, 0.056, 0.020), distant: distant)
            }
        }
        return SkyCity.Layout(buildings: b.v, farTrees: farBatch.farTreesBackToFront, obstacles: obstacles)
    }
}
