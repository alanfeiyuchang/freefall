import Foundation
import simd

/// 一关：在哪里跳。编号和 Shaders/TerrainField.h 的 SCENE_* 一致。
/// 所有关的靶都在地面坐标 (380, -620)，开伞点大约在 (0, -100)；地形顺着这个方向摆（见 TerrainField.h）。
enum JumpScene: Int, CaseIterable, Sendable, Identifiable {
    case atoll, grassland, alpine, snow, island, volcano, sky

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .atoll: String(localized: "环礁")
        case .grassland: String(localized: "草原")
        case .alpine: String(localized: "高山")
        case .snow: String(localized: "雪山")
        case .island: String(localized: "海岛")
        case .volcano: String(localized: "火山")
        case .sky: String(localized: "天空之城")
        }
    }

    /// 资源文件名里用的名字（开始窗口的卡片截图 card_<key>.jpg，render-check 的 card 镜头渲的）
    var key: String {
        switch self {
        case .atoll: "atoll"
        case .grassland: "grassland"
        case .alpine: "alpine"
        case .snow: "snow"
        case .island: "island"
        case .volcano: "volcano"
        case .sky: "sky"
        }
    }

    /// 卡片上关名下面的一行：落在哪、要躲开什么
    var tagline: String {
        switch self {
        case .atoll: String(localized: "潟湖里的白沙洲 · 别落水")
        case .grassland: String(localized: "农田 · 别掉进河和树林")
        case .alpine: String(localized: "U 形谷 · 别撞岩壁")
        case .snow: String(localized: "高原雪坡 · 太陡的落不了")
        case .island: String(localized: "热带小岛 · 别落海、别进雨林")
        case .volcano: String(localized: "破火山口 · 躲开熔岩和毒烟")
        case .sky: String(localized: "云海上的浮岛 · 别掉出岛外")
        }
    }

    /// 开始窗口里的一句话介绍（看着卡片时弹出来）
    var blurb: String {
        switch self {
        case .atoll: String(localized: "潟湖里一片白沙洲。别落进水里")
        case .grassland: String(localized: "缓丘、农田、一条河和几片树林。别掉进河里、别挂在树上")
        case .alpine: String(localized: "开伞时两边的山比你还高。顺着山谷飞到草甸上，别撞上岩壁、别落进林子")
        case .snow: String(localized: "海拔 2,750 米的雪坡，四周是五千米的雪峰。坡太陡的地方落不了")
        case .island: String(localized: "四面环海的热带小岛：从海上飞过去，降落点在沙滩后面的草地上。落短了掉海里，往里是雨林")
        case .volcano: String(localized: "破火山口里一座正在喷的火山锥：别靠近火山口和烟柱，别踩到熔岩")
        case .sky: String(localized: "云海上面浮着一群岛，岛上是废弃的石头城：落在主岛的草坪上。飞过头掉出岛外就进云海了，别撞上塔和城堡")
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
        case .island: 3.5
        case .volcano: 620
        case .sky: 3300
        }
    }

    /// 飞机的高度（起跳的海拔）。着陆区上方 5,600 米（约 18,400 英尺）：到穿进那层雨云大约半分钟，
    /// 整个自由落体一分钟出头。第一版所有关都从 9,144 米（30,000 英尺）跳，光是到云层就要一分多钟，中间没什么事可做。
    /// 天空之城这一关云在岛下面、路上不穿云，再低一些
    var exitAltitude: Double { dzElevation + (self == .sky ? 3400 : 5300) }

    var hasTerrain: Bool { self != .atoll }

    /// 云层整体抬高多少米：按着陆区的海拔抬，下雨的云层总在着陆区上空两三千米。
    /// 天空之城不抬：那层云（云顶 3,200 米）正好在岛下面，是一片云海；这一关下落不穿雨云
    // （整层再压低 300 米，出舱高度跟着降 300：出云到手表报警那一段短了五六秒，进云之前的时间不变。
    // 试过压 600 米：到报警高度人还在云底的雾里，看不见地面）
    var cloudOffset: Double { self == .sky ? 0 : dzElevation - 300 }

    /// 地形下面还有海（天空之城：岛是浮着的，地形网格只画岛，岛外往下看是云海和海面）
    var seaBelow: Bool { self == .sky }

    /// 地形的海拔范围（米），给 LOD 选块和裁剪用：宁大勿小
    var heightRange: (Double, Double) {
        switch self {
        case .atoll: (0, 10)
        case .grassland: (150, 400)
        case .alpine: (700, 5800)
        case .snow: (2300, 7000)
        case .island: (-60, 700)
        case .volcano: (-60, 1400)
        case .sky: (2850, 3650)
        }
    }

    /// 地面海拔（米）
    func groundHeight(at p: SIMD2<Double>) -> Double {
        hasTerrain ? Double(TerrainField.height(self, SIMD2(Float(p.x), Float(p.y)))) : 0
    }

    /// 给 shader 的 FrameUniforms.world
    var worldUniform: SIMD4<Float> {
        SIMD4(Float(rawValue), Float(cloudOffset), hasTerrain ? 1 : 0, seaBelow ? 1 : 0)
    }
}
