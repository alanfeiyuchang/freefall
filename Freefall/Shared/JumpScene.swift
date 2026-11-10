import Foundation
import simd

/// 一关：在哪里跳。编号和 Shaders/TerrainField.h 的 SCENE_* 一致。
/// 所有关的靶都在地面坐标 (380, -620)，开伞点大约在 (0, -100)；地形顺着这个方向摆（见 TerrainField.h）。
enum JumpScene: Int, CaseIterable, Sendable, Identifiable {
    case atoll, grassland, alpine, snow, glacier, volcano

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .atoll: "环礁"
        case .grassland: "草原"
        case .alpine: "高山"
        case .snow: "雪山"
        case .glacier: "冰川"
        case .volcano: "火山"
        }
    }

    /// 开始窗口里的一句话介绍
    var blurb: String {
        switch self {
        case .atoll: "潟湖里一片白沙洲。别落进水里"
        case .grassland: "缓丘、农田、一条河和几片树林。别掉进河里、别挂在树上"
        case .alpine: "开伞时两边的山比你还高。顺着山谷飞到草甸上，别撞上岩壁、别落进林子"
        case .snow: "海拔 2,750 米的雪坡，四周是五千米的雪峰。坡太陡的地方落不了"
        case .glacier: "落在冰川上。冰瀑和冰川边上全是裂缝，下游是冰湖"
        case .volcano: "破火山口里一座正在喷的火山锥：别靠近火山口和烟柱，别踩到熔岩"
        }
    }

    /// 靶在地面坐标里的位置
    var target: SIMD2<Double> { SIMD2(380, -620) }

    /// 着陆区（靶）的海拔：高度表按它归零
    var dzElevation: Double {
        switch self {
        case .atoll: 0
        case .grassland: 240
        case .alpine: 1150
        case .snow: 2750
        case .glacier: 1935
        case .volcano: 620
        }
    }

    var hasTerrain: Bool { self != .atoll }

    /// 云层整体抬高多少米：按着陆区的海拔抬，下雨的云层总在着陆区上空两三千米
    var cloudOffset: Double { dzElevation }

    /// 地形的海拔范围（米），给 LOD 选块和裁剪用：宁大勿小
    var heightRange: (Double, Double) {
        switch self {
        case .atoll: (0, 10)
        case .grassland: (150, 400)
        case .alpine: (700, 5800)
        case .snow: (2300, 7000)
        case .glacier: (1350, 6800)
        case .volcano: (-60, 1400)
        }
    }

    /// 地面海拔（米）
    func groundHeight(at p: SIMD2<Double>) -> Double {
        hasTerrain ? Double(TerrainField.height(self, SIMD2(Float(p.x), Float(p.y)))) : 0
    }

    /// 给 shader 的 FrameUniforms.world
    var worldUniform: SIMD4<Float> { SIMD4(Float(rawValue), Float(cloudOffset), hasTerrain ? 1 : 0, 0) }
}
