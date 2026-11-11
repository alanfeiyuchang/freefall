import Foundation
import simd

/// 高山这一关的实体模型（见 SceneProps）
enum AlpineProps {
    static let layout: SkyCity.Layout = build()

    private static func build() -> SkyCity.Layout {
        // 林子：谷两边坡上的云杉。近处每棵都立起来，远处越来越稀（地面上画的林子接着）；顶点有上限，从近往远种
        var b = PropBuilder()
        let spots = PropScatter.spots(scene: .alpine, radius: 1500, spacing: 8.5, full: 520) { p, h in
            TerrainField.alpineForest(p, h) > 0.55 && TerrainField.slopeDegrees(.alpine, p) < 42
        }
        for s in spots {
            guard b.v.count < 170_000 else { break }
            let far = s.distance > 650
            let height = (13 + 11 * s.size) * (far ? 1.25 : 1)
            b.conifer(base: SIMD3(s.p.x, s.h - 0.6, s.p.y), height: height, near: !far, seed: s.seed)
        }
        return SkyCity.Layout(buildings: b.v)
    }
}
