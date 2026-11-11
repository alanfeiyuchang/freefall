import Foundation
import simd

/// 环礁这一关的实体模型（见 SceneProps）
enum AtollProps {
    static let layout: SkyCity.Layout = build()

    private static func build() -> SkyCity.Layout {
        // 沙洲：两头各一丛歪椰子树，沙上散着漂木和珊瑚石，靶旁边立着风向袋。沙洲是个斜着的椭圆（见 Clouds.h 的 SANDBAR_*）
        var b = PropBuilder()
        var obstacles: [SkyCity.Obstacle] = []
        let center = SIMD2<Float>(405, -640), cosA: Float = 0.87758, sinA: Float = 0.47943
        func ground(_ sl: SIMD2<Float>) -> SIMD3<Float> {
            SIMD3(center.x + sl.x * cosA - sl.y * sinA, 0, center.y + sl.x * sinA + sl.y * cosA)
        }
        func rnd(_ i: Int, _ k: Int32) -> Float { TerrainField.hash(Int32(i) &* 17, k) * 0.5 + 0.5 }
        // 椰子树：两丛，离靶八九十米开外
        for (ci, c) in [SIMD2<Float>(-112, 14), SIMD2<Float>(118, -18), SIMD2<Float>(-70, -52)].enumerated() {
            for i in 0..<(ci == 2 ? 3 : 6) {
                let off = SIMD2<Float>(rnd(i + ci * 10, 1) - 0.5, rnd(i + ci * 10, 2) - 0.5) * SIMD2(34, 22)
                let p = ground(c + off)
                let height = 6 + 4.5 * rnd(i + ci * 10, 3)
                b.palm(base: p, height: height, seed: Int32(i + ci * 10) &* 7)
                obstacles.append(.init(center: SIMD2(Double(p.x), Double(p.z)), radius: 1.6, top: Double(height)))
            }
        }
        // 漂木：晒白了的树干，横七竖八躺在沙上
        for i in 0..<9 {
            let sl = SIMD2<Float>((rnd(i, 11) - 0.5) * 280, (rnd(i, 12) - 0.5) * 130)
            guard simd_length(sl - SIMD2(-25, 20)) > 28 else { continue }
            let p = ground(sl), a = 6.28 * rnd(i, 13), len = 2.5 + 4 * rnd(i, 14)
            let d = SIMD3<Float>(cos(a), 0, sin(a)) * len * 0.5
            b.tube(from: p - d + SIMD3(0, 0.12, 0), to: p + d + SIMD3(0, 0.22 + 0.3 * rnd(i, 15), 0), r0: 0.2, r1: 0.11, sides: 5,
                   color: SIMD3(0.30, 0.27, 0.22), material: PropMaterial.bark)
        }
        // 珊瑚石：半埋在沙里的灰白石头，一小堆一小堆
        for i in 0..<26 {
            let sl = SIMD2<Float>((rnd(i, 21) - 0.5) * 300, (rnd(i, 22) - 0.5) * 150)
            guard simd_length(sl - SIMD2(-25, 20)) > 22 else { continue }
            let r = 0.25 + 0.9 * rnd(i, 23) * rnd(i, 24)
            b.blob(center: ground(sl) + SIMD3(0, r * 0.25, 0), radius: SIMD3(r * 1.3, r * 0.7, r), sides: 6,
                   color: SIMD3(0.22, 0.21, 0.19), material: PropMaterial.rock, phase: 6.28 * rnd(i, 25), seed: Int32(i))
        }
        // 风向袋：靶旁边三十米，一根杆子，袋子红白相间
        let pole = SIMD3<Float>(TerrainField.target.x + 26, 0, TerrainField.target.y + 14)
        b.tube(from: pole, to: pole + SIMD3(0, 6, 0), r0: 0.05, r1: 0.04, sides: 5, color: SIMD3(0.5, 0.5, 0.52), material: PropMaterial.plain)
        let wind = simd_normalize(SIMD3<Float>(0.8, -0.18, 0.6))
        for k in 0..<4 {
            let t0 = Float(k) / 4, t1 = Float(k + 1) / 4
            b.tube(from: pole + SIMD3(0, 5.8, 0) + wind * (2.4 * t0), to: pole + SIMD3(0, 5.8, 0) + wind * (2.4 * t1),
                   r0: 0.34 - 0.2 * t0, r1: 0.34 - 0.2 * t1, sides: 7,
                   color: k % 2 == 0 ? SIMD3(0.75, 0.10, 0.04) : SIMD3(0.8, 0.8, 0.8), material: PropMaterial.plain)
        }
        obstacles.append(.init(center: SIMD2(Double(pole.x), Double(pole.z)), radius: 0.5, top: 6.2))
        return SkyCity.Layout(buildings: b.v, obstacles: obstacles)
    }
}
