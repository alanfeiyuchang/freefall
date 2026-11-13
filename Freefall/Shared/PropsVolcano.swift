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
            // 每块不一样：压扁的程度、长短轴的方向和比例、埋进灰里多深、颜色（黑、深灰、带一点氧化红的）。
            // 以前只有一个模子（同样的扁、几乎一样圆、同一个黑），从高处看是一地黑馒头
            let h1 = TerrainField.hash(s.seed, 5), h2 = TerrainField.hash(s.seed, 11), h3 = TerrainField.hash(s.seed, 17)
            let a = 3.14 * h1
            let stretch = 1.0 + 0.45 * h2                       // 0.55 … 1.45：长的一边
            let flat = 0.62 + 0.28 * h3                         // 0.34 … 0.9：高度比
            let ra = r * stretch, rb = r / stretch
            let radius = SIMD3(abs(cos(a)) * ra + abs(sin(a)) * rb, r * flat, abs(sin(a)) * ra + abs(cos(a)) * rb)
            let sink = 0.15 + 0.25 * (0.5 + 0.5 * h1)           // 埋进去 15% ~ 40% 的高度
            let tint = 0.5 + 0.5 * h2
            let color = SIMD3<Float>(0.03 + 0.03 * tint * tint, 0.028 + 0.008 * tint, 0.03) * (0.8 + 0.4 * (0.5 + 0.5 * h3))
            b.blob(center: SIMD3(s.p.x, s.h + radius.y * (1 - 2 * sink), s.p.y), radius: radius,
                   sides: 6, color: color, material: PropMaterial.plain, phase: 6.28 * h1, seed: s.seed)
        }
        return SkyCity.Layout(buildings: b.v)
    }
}
