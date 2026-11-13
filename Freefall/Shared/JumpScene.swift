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

    /// 设计的开伞点在地面坐标里挪多少（米）。默认开伞点在 (0, -102)，靶在右前方 643 米：七关原来是同一道题，
    /// 危险都离航线很远。靶挪不动（地形都是围着它摆的），挪开伞点，让这一关的危险落在要飞的路上：
    /// - 草原：开伞点 (300, 150)，靶在正前方 770 米，照直飞的最后 400 米有四成是河和河边的林子——落短了掉河里、挂树上，
    ///   高度又富余，得管住（俯冲或者左右来回转）
    /// - 火山：开伞点 (-575, -675)，在火山锥上方、紧挨着烟柱（从出舱到地面这一整竖离烟柱都有 1.3 个半径以上），靶在右手边 960 米：
    ///   开伞以后得马上往右飞离烟柱，往左偏几十米就进毒烟，开晚了飞不到
    /// 高山、雪山试过（tools 里按地形搜过一遍）：靶前面整片是开阔的草甸 / 雪坡、谷壁挡不住直线，挪了也没有题，不动。
    /// 环礁、海岛、天空之城本来就是「落短了掉水里 / 掉出岛外」
    var openShift: SIMD2<Double> {
        switch self {
        case .grassland: SIMD2(300, 252)
        case .volcano: SIMD2(-575, -573)
        default: .zero
        }
    }

    /// 出舱点在地面坐标里挪多少：设计的开伞点再往上风挪「出舱到手表报警这段被风吹走的距离」，
    /// 按时报警开伞时正好还在设计的开伞点上（风每跳不一样，出舱点跟着变，像真的跳伞按当天的高空风定出舱点）
    func exitShift(wind: SIMD2<Double>) -> SIMD2<Double> {
        openShift - wind * JumpTimeline.freefallDuration(scene: self)
    }

    /// 从设计的开伞点飞向靶的方向（地面坐标的单位向量）：「逆风」「顺风」都是相对它说的
    var approach: SIMD2<Double> {
        let open = SIMD2<Double>(0, -102) + openShift
        return simd_normalize(target - open)
    }

    /// 这一关的风可以是什么样（地面坐标，空气往哪边走）：
    /// center 是风去的方向，spread 是左右最多偏多少（弧度，.pi = 哪个方向都行），bothWays 是 center 和反过来都行；
    /// speed 风速范围（m/s）；maxHead 是逆风分量的上限（超了按比例把风速压下来，方向不变）——
    /// 逆风太大时按时开伞也飞不到靶（render-check 的 wind 模式按每关的最坏情况用自动驾驶跳过）
    struct WindRange {
        var center: SIMD2<Double>
        var spread: Double
        var bothWays = false
        var speed: ClosedRange<Double>
        var maxHead: Double
    }

    /// 每关的风：
    /// - 环礁：顺着风向袋（靶旁边那根，袋子朝 (0.8, 0.6) 飘）±20°，1~3 m/s。教学关，风小，风向袋也不会指错
    /// - 草原：开阔的缓丘，哪个方向都行，0.5~4 m/s
    /// - 草原逆风最多 2.5（4 m/s 逆风按时开伞也飞不到），雪山逆风最多 3（海拔高、谷底往靶那边是上坡）
    /// - 高山、雪山：U 形谷里两边是两千多米的山墙，横风被挡住，风只顺着山谷走：上谷或下谷，±15°，1~4 m/s
    /// - 海岛：四面是海，哪个方向都行，海风大一点 2~5 m/s，逆风最多 4
    /// - 火山：0.5~2 m/s，从横风到斜着的顺风。这一关按时开伞离靶 960 米、一点富余都没有（无风时自动驾驶正好飞到），
    ///   1 m/s 的逆风就差六七十米，所以不能有逆风；烟柱是固定往进场的反方向倒的（TerrainField.plumeDrift），
    ///   真按烟柱定风就全是逆风。退一步：风的横向分量和烟柱倒的那一侧一致，顺风的那一点和烟柱对不上（要对上得让烟柱跟着风倒，另说）
    /// - 天空之城：云海上空，哪个方向都行，0.5~3.5 m/s，逆风最多 3
    var windRange: WindRange {
        let valley = SIMD2<Double>(Double(TerrainField.valleyDir.x), Double(TerrainField.valleyDir.y))
        let deg = Double.pi / 180
        switch self {
        case .atoll: return WindRange(center: simd_normalize(SIMD2(0.8, 0.6)), spread: 20 * deg, speed: 1...3, maxHead: 3)
        case .grassland: return WindRange(center: approach, spread: .pi, speed: 0.5...3.5, maxHead: 2.5)
        case .alpine: return WindRange(center: valley, spread: 15 * deg, bothWays: true, speed: 1...4, maxHead: 4)
        case .snow: return WindRange(center: valley, spread: 15 * deg, bothWays: true, speed: 1...4, maxHead: 3)
        case .island: return WindRange(center: approach, spread: .pi, speed: 2...5, maxHead: 4)
        case .volcano:
            // 进场线的左右两个垂直方向里取和烟柱倒向（TerrainField.plumeDrift）同一侧的那个，再往顺风偏 25°：
            // 范围是「正横风」到「斜着 50° 的顺风」，一点逆风都不带
            let drift = SIMD2<Double>(Double(TerrainField.plumeDrift.x), Double(TerrainField.plumeDrift.y))
            var side = SIMD2(-approach.y, approach.x)
            if simd_dot(side, drift) < 0 { side = -side }
            let center = simd_normalize(side * cos(25 * deg) + approach * sin(25 * deg))
            return WindRange(center: center, spread: 25 * deg, speed: 0.5...2, maxHead: 0.05)
        case .sky: return WindRange(center: approach, spread: .pi, speed: 0.5...3.5, maxHead: 3)
        }
    }

    /// 按范围里的 (方向 0…1, 风速 0…1, 上谷还是下谷) 取一个风
    func wind(direction u: Double, speed v: Double, reversed: Bool = false) -> SIMD2<Double> {
        let r = windRange
        let a = (u * 2 - 1) * r.spread
        var dir = SIMD2(r.center.x * cos(a) - r.center.y * sin(a), r.center.x * sin(a) + r.center.y * cos(a))
        if r.bothWays, reversed { dir = -dir }
        var w = dir * (r.speed.lowerBound + (r.speed.upperBound - r.speed.lowerBound) * v)
        let head = -simd_dot(w, approach)
        if head > r.maxHead { w *= r.maxHead / head }
        return w
    }

    /// 这一跳的风：每次开跳抽一个
    func randomWind() -> SIMD2<Double> {
        wind(direction: Double.random(in: 0...1), speed: Double.random(in: 0...1), reversed: Bool.random())
    }

    /// 固定的风：render-check 的镜头、自动测试和调试用，每次一样（和原来写死的风一样：草原逆风 2.5、海岛左边横风 3.5，别的关没风）
    var designWind: SIMD2<Double> {
        switch self {
        case .grassland: SIMD2(-0.26, 2.49)
        case .island: SIMD2(2.84, 2.06)
        default: .zero
        }
    }

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
