import Foundation
import simd

/// 火山这一关的实体模型（见 SceneProps）
enum VolcanoProps {
    static let layout: SkyCity.Layout = build()

    private static func build() -> SkyCity.Layout {
        // 破火山口底上的火山弹和熔岩块：喷出来落在灰地上的黑石头，大的两三米；熔岩流边上、靶周围不放（都不高，不算障碍）
        var b = PropBuilder()
        let spots = PropScatter.spots(scene: .volcano, radius: 1300, spacing: 13, full: 380) { p, h in
            h > 5 && TerrainField.lavaFlowDistance(p) > 30 && simd_length(p - TerrainField.target) > 22
                && simd_length(p - TerrainField.coneCenter) > 200 && TerrainField.slopeDegrees(.volcano, p) < 30
        }
        for s in spots {
            guard b.v.count < 60_000 else { break }
            let r = 0.3 + 1.6 * s.size * s.size * s.size
            let a = 6.28 * TerrainField.hash(s.seed, 5)
            b.blob(center: SIMD3(s.p.x, s.h + r * 0.35, s.p.y), radius: SIMD3(r * (1 + 0.4 * cos(a) * cos(a)), r * 0.8, r * (1 + 0.4 * sin(a) * sin(a))),
                   sides: 6, color: SIMD3(0.035, 0.032, 0.034), material: PropMaterial.plain, phase: a, seed: s.seed)
        }
        return SkyCity.Layout(buildings: b.v)
    }
}
