import Foundation
import simd

/// 草原这一关的实体模型（见 SceneProps）
enum GrasslandProps {
    static let layout: SkyCity.Layout = build()

    private static func build() -> SkyCity.Layout {
        // 树林：一棵棵阔叶树（橡树、白蜡），近处的带树干、两团树冠；远处越来越稀
        var b = PropBuilder()
        let spots = PropScatter.spots(scene: .grassland, radius: 2600, spacing: 9, full: 480) { p, _ in
            TerrainField.grasslandForest(p) > 0.55
        }
        for s in spots {
            guard b.v.count < 170_000 else { break }
            let far = s.distance > 600
            let distant = s.distance > 1100
            let height = (10 + 8 * s.size) * (distant ? 1.5 : far ? 1.2 : 1)
            b.broadleaf(base: SIMD3(s.p.x, s.h - 0.4, s.p.y), height: height, near: !far, seed: s.seed, green: SIMD3(0.034, 0.072, 0.022), distant: distant)
        }
        return SkyCity.Layout(buildings: b.v)
    }
}
