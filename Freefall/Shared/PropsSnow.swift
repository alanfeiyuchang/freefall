import Foundation
import simd

/// 雪山这一关的实体模型（见 SceneProps）
enum SnowProps {
    static let layout: SkyCity.Layout = build()

    private static func build() -> SkyCity.Layout {
        // 露岩上散着的石块：大大小小，朝上的面积着雪（都不高，不算障碍）
        var b = PropBuilder()
        let spots = PropScatter.spots(scene: .snow, radius: 1100, spacing: 7, full: 420) { p, _ in
            TerrainField.snowOutcrop(p) > 0.385 && simd_length(p - TerrainField.target) > 150
                && TerrainField.slopeDegrees(.snow, p) < 35
        }
        for s in spots {
            guard b.v.count < 60_000 else { break }
            let r = 0.35 + 1.5 * s.size * s.size
            let a = 6.28 * TerrainField.hash(s.seed, 5)
            b.blob(center: SIMD3(s.p.x, s.h + r * 0.3, s.p.y), radius: SIMD3(r * (1 + 0.5 * cos(a) * cos(a)), r * 0.75, r * (1 + 0.5 * sin(a) * sin(a))),
                   sides: 6, color: SIMD3(0.085, 0.08, 0.08), material: PropMaterial.snowy, phase: a, seed: s.seed)
        }
        return SkyCity.Layout(buildings: b.v)
    }
}
