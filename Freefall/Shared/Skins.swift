import Foundation
import simd

/// 和 Shaders/Skins.h 的 SkinUniforms 一样（15 个 16 字节）
struct SkinUniforms {
    /// 伞衣的调色板（rgb 反照率），各图案按自己的顺序用
    var canopy0 = SIMD4<Float>(0, 0, 0, 0), canopy1 = SIMD4<Float>(0, 0, 0, 0), canopy2 = SIMD4<Float>(0, 0, 0, 0)
    var canopy3 = SIMD4<Float>(0, 0, 0, 0), canopy4 = SIMD4<Float>(0, 0, 0, 0), canopy5 = SIMD4<Float>(0, 0, 0, 0)
    /// 手套：rgb 布面的颜色 ÷ 原贴图布面的亮度
    var gloveBase = SIMD4<Float>(0, 0, 0, 0)
    /// 橡胶护甲（指节、手背、指尖那些原来黑色的块）
    var gloveArmor = SIMD4<Float>(0, 0, 0, 0)
    /// rgb 点缀的颜色，a 点缀的自发光
    var gloveAccent = SIMD4<Float>(0, 0, 0, 0)
    /// 袖子：底色、手背那一侧的条纹、袖口（a = 1 才画）
    var sleeveBase = SIMD4<Float>(0, 0, 0, 0), sleeveStripe = SIMD4<Float>(0, 0, 0, 0), sleeveCuff = SIMD4<Float>(0, 0, 0, 0)
    /// rgb 滑块（伞绳上那块方布）的颜色
    var slider = SIMD4<Float>(0.8, 0.8, 0.77, 0)
    /// x 条纹边的形状，y 起伏（圈的比例），z 周期（米），w 条纹半宽（圈的比例；0 = 没有条纹）
    var sleeveShape = SIMD4<Float>(0, 0, 0, 0)
    /// x 伞的图案（Skins.h 的 SKIN_*），y 换了手套的颜色（0 = 默认）
    var kind = SIMD4<Int32>(0, 0, 0, 0)
}

/// 皮肤：每关一顶伞、一套手套和袖子（一起解锁、一起换），颜色和图案都从那一关的景物里来。
/// 「默认」（nil）是原来的橙白蓝伞、黑手套橙掌垫、深蓝袖子，一直能用。
///
/// 只是换颜色和图案：伞衣、袖子的图案在 shader 里按 uv 现算（Skins.h），手套在 shader 里把贴图拆成布面和点缀两种颜色再重配，
/// 都不加贴图、不加 pass。伞的影子图（PlayerShadow）用同一个图案函数，影子的颜色跟着伞变。
enum Skins {
    /// 解锁规则：落进降落点（20 米内）解锁这一关的伞；落进黄色靶心（3 米内）再解锁这一关的手套和袖子（靶心也算进靶，两样一起）
    static func earned(by outcome: JumpTimeline.Outcome) -> (canopy: Bool, gloves: Bool) {
        switch outcome {
        case .bullseye: (true, true)
        case .inTarget: (true, false)
        default: (false, false)
        }
    }

    // MARK: 名字

    /// 伞的名字（不带「伞」字）
    static func canopyName(_ scene: JumpScene?) -> String {
        switch scene {
        case nil: String(localized: "经典")
        case .atoll: String(localized: "潟湖")
        case .grassland: String(localized: "拼布田")
        case .alpine: String(localized: "群峰")
        case .snow: String(localized: "冰川")
        case .island: String(localized: "棕榈")
        case .volcano: String(localized: "熔岩")
        case .sky: String(localized: "城堞")
        }
    }

    /// 手套和袖子的名字
    static func glovesName(_ scene: JumpScene?) -> String {
        switch scene {
        case nil: String(localized: "经典")
        case .atoll: String(localized: "白沙")
        case .grassland: String(localized: "麦穗")
        case .alpine: String(localized: "云杉")
        case .snow: String(localized: "雪原")
        case .island: String(localized: "扶桑花")
        case .volcano: String(localized: "黑曜石")
        case .sky: String(localized: "铜绿")
        }
    }

    // MARK: 颜色表（线性反照率）

    /// 滑块的颜色：白色尼龙（和默认伞的白色气室一样），火山那顶是黑的（白的在一片黑里太扎眼）
    static func slider(_ scene: JumpScene?) -> SIMD3<Float> {
        switch scene {
        case .volcano: SIMD3(0.03, 0.028, 0.027)
        case .atoll, .island: SIMD3(0.80, 0.76, 0.62)
        case .sky: SIMD3(0.74, 0.68, 0.53)
        default: SIMD3(0.8, 0.8, 0.77)
        }
    }

    /// 伞：图案编号 + 调色板（顺序见 Skins.h 各图案的注释）
    static func canopy(_ scene: JumpScene?) -> (pattern: Int32, palette: [SIMD3<Float>]) {
        switch scene {
        case nil:
            // 中间一格橙、往外白橙白相间、翼尖海军蓝（和原来顶点颜色的那张表一样）
            (0, [SIMD3(0.85, 0.22, 0.05), SIMD3(0.82, 0.82, 0.80), SIMD3(0.85, 0.22, 0.05),
                 SIMD3(0.82, 0.82, 0.80), SIMD3(0.05, 0.10, 0.32)])
        case .atoll:
            // 白沙洲、潟湖的浅水、礁、碎浪的白线、外海、深海
            (1, [SIMD3(0.80, 0.76, 0.62), SIMD3(0.22, 0.68, 0.66), SIMD3(0.03, 0.46, 0.52),
                 SIMD3(0.86, 0.87, 0.86), SIMD3(0.03, 0.20, 0.46), SIMD3(0.015, 0.06, 0.22)])
        case .grassland:
            // 草、嫩绿的苗、麦子、翻过的土、浅绿，树篱
            (2, [SIMD3(0.14, 0.36, 0.05), SIMD3(0.40, 0.50, 0.07), SIMD3(0.74, 0.53, 0.11),
                 SIMD3(0.30, 0.16, 0.06), SIMD3(0.30, 0.56, 0.16), SIMD3(0.025, 0.08, 0.02)])
        case .alpine:
            // 天、雪、岩石、云杉、林子深处
            (3, [SIMD3(0.30, 0.55, 0.85), SIMD3(0.86, 0.87, 0.89), SIMD3(0.28, 0.28, 0.30),
                 SIMD3(0.05, 0.21, 0.08), SIMD3(0.018, 0.075, 0.03)])
        case .snow:
            // 雪白、冰蓝、深蓝的细线、翼尖的冰川蓝
            (4, [SIMD3(0.86, 0.88, 0.91), SIMD3(0.32, 0.60, 0.86), SIMD3(0.05, 0.20, 0.55),
                 SIMD3(0.03, 0.12, 0.38)])
        case .island:
            // 叶子的深绿、亮绿，扶桑花红，礁坪的翠绿，白沙
            (5, [SIMD3(0.02, 0.18, 0.05), SIMD3(0.20, 0.56, 0.10), SIMD3(0.88, 0.14, 0.20),
                 SIMD3(0.02, 0.46, 0.36), SIMD3(0.83, 0.75, 0.53)])
        case .volcano:
            // 玄武岩的黑，火苗的深红、橙、黄，火山灰
            (6, [SIMD3(0.022, 0.02, 0.02), SIMD3(0.62, 0.04, 0.02), SIMD3(0.93, 0.33, 0.03),
                 SIMD3(0.96, 0.72, 0.14), SIMD3(0.20, 0.19, 0.18)])
        case .sky:
            // 奶白的石头、铜绿、金、柱间的阴影、石板灰
            (7, [SIMD3(0.74, 0.68, 0.53), SIMD3(0.15, 0.44, 0.37), SIMD3(0.82, 0.56, 0.13),
                 SIMD3(0.40, 0.36, 0.28), SIMD3(0.21, 0.23, 0.26)])
        }
    }

    struct GloveColors {
        /// 手套的布面、橡胶护甲（指节、手背）、点缀（base 是 nil = 默认，贴图原样用）
        var base: SIMD3<Float>?
        var armor = SIMD3<Float>(0, 0, 0)
        var accent = SIMD3<Float>(0, 0, 0)
        /// 点缀的自发光（辐亮度，和太阳照度 1 同一套单位）
        var glow: Float = 0
        /// 袖子：底色、条纹、袖口（nil = 没有袖口那一圈）
        var sleeve: SIMD3<Float>
        var stripe = SIMD3<Float>(0, 0, 0)
        var cuff: SIMD3<Float>?
        /// 条纹边的形状（0 直 1 波浪 2 锯齿 3 城垛 4 火苗 5 扇贝）、起伏（圈的比例）、周期（米）、半宽（圈的比例，0 = 没有条纹）
        var shape: Float = 0, amplitude: Float = 0, period: Float = 0.05, halfWidth: Float = 0
    }

    /// 原贴图布面的亮度（白布在原贴图里的亮度约 0.6，炭灰 = 0.6 × 0.075）：手套的布面颜色按它折算
    private static let fabricLuminance: Float = 0.62

    static func gloves(_ scene: JumpScene?) -> GloveColors {
        switch scene {
        case nil:
            GloveColors(sleeve: SIMD3(0.028, 0.034, 0.05))         // 深海军蓝的跳伞服，没有条纹
        case .atoll:
            // 碧蓝的护甲、白沙色的布、白色的点缀；碧蓝的袖子，手背一道白浪，袖口白沙
            GloveColors(base: SIMD3(0.62, 0.58, 0.46), armor: SIMD3(0.02, 0.34, 0.40), accent: SIMD3(0.80, 0.80, 0.78),
                        sleeve: SIMD3(0.03, 0.26, 0.40), stripe: SIMD3(0.80, 0.80, 0.78), cuff: SIMD3(0.62, 0.58, 0.46),
                        shape: 1, amplitude: 0.05, period: 0.06, halfWidth: 0.075)
        case .grassland:
            // 草绿的护甲、麦秆色的布、麦黄的点缀；草绿的袖子，一道麦黄，袖口泥土色
            GloveColors(base: SIMD3(0.55, 0.45, 0.24), armor: SIMD3(0.08, 0.24, 0.04), accent: SIMD3(0.74, 0.52, 0.10),
                        sleeve: SIMD3(0.07, 0.17, 0.03), stripe: SIMD3(0.70, 0.49, 0.10), cuff: SIMD3(0.24, 0.13, 0.05),
                        shape: 0, halfWidth: 0.06)
        case .alpine:
            // 云杉绿的护甲、岩石灰的布、雪白的点缀；深绿的袖子，一道白色锯齿（山峰），袖口岩石灰
            GloveColors(base: SIMD3(0.28, 0.28, 0.29), armor: SIMD3(0.025, 0.10, 0.045), accent: SIMD3(0.78, 0.79, 0.81),
                        sleeve: SIMD3(0.02, 0.075, 0.035), stripe: SIMD3(0.80, 0.81, 0.83), cuff: SIMD3(0.26, 0.26, 0.28),
                        shape: 2, amplitude: 0.07, period: 0.045, halfWidth: 0.075)
        case .snow:
            // 冰蓝的护甲、雪白的布、深蓝的点缀；白袖子，一道深蓝，袖口冰蓝
            GloveColors(base: SIMD3(0.76, 0.78, 0.82), armor: SIMD3(0.20, 0.46, 0.78), accent: SIMD3(0.04, 0.13, 0.40),
                        sleeve: SIMD3(0.74, 0.76, 0.80), stripe: SIMD3(0.04, 0.16, 0.48), cuff: SIMD3(0.30, 0.58, 0.85),
                        shape: 0, halfWidth: 0.045)
        case .island:
            // 叶绿的护甲、白沙色的布、扶桑花红的点缀；叶绿的袖子，一道扇贝边的花红，袖口白沙
            GloveColors(base: SIMD3(0.70, 0.62, 0.44), armor: SIMD3(0.03, 0.26, 0.09), accent: SIMD3(0.86, 0.16, 0.20),
                        sleeve: SIMD3(0.025, 0.20, 0.07), stripe: SIMD3(0.86, 0.16, 0.20), cuff: SIMD3(0.80, 0.72, 0.52),
                        shape: 5, amplitude: 0.05, period: 0.05, halfWidth: 0.07)
        case .volcano:
            // 黑曜石的护甲、火山灰的布、熔岩橙的点缀（微微自己发光）；黑袖子，一道往手肘烧的火苗，袖口暗红
            GloveColors(base: SIMD3(0.15, 0.14, 0.13), armor: SIMD3(0.012, 0.01, 0.012), accent: SIMD3(0.95, 0.30, 0.03),
                        glow: 0.05,
                        sleeve: SIMD3(0.03, 0.027, 0.026), stripe: SIMD3(0.93, 0.36, 0.04), cuff: SIMD3(0.50, 0.04, 0.02),
                        shape: 4, amplitude: 0.10, period: 0.05, halfWidth: 0.08)
        case .sky:
            // 铜绿的护甲、奶白石头色的布、金色的点缀；石头色的袖子，一道城垛边的铜绿，袖口金
            GloveColors(base: SIMD3(0.64, 0.58, 0.45), armor: SIMD3(0.11, 0.38, 0.31), accent: SIMD3(0.80, 0.55, 0.13),
                        sleeve: SIMD3(0.56, 0.51, 0.39), stripe: SIMD3(0.13, 0.40, 0.33), cuff: SIMD3(0.76, 0.52, 0.12),
                        shape: 3, amplitude: 0.05, period: 0.05, halfWidth: 0.075)
        }
    }

    /// 选好的伞和手套 → shader 的参数
    static func uniforms(canopy canopyScene: JumpScene?, gloves glovesScene: JumpScene?) -> SkinUniforms {
        var u = SkinUniforms()
        let c = canopy(canopyScene)
        let p = (0..<6).map { SIMD4(c.palette[min($0, c.palette.count - 1)], 0) }
        (u.canopy0, u.canopy1, u.canopy2, u.canopy3, u.canopy4, u.canopy5) = (p[0], p[1], p[2], p[3], p[4], p[5])
        u.slider = SIMD4(slider(canopyScene), 0)
        let g = gloves(glovesScene)
        if let base = g.base {
            u.gloveBase = SIMD4(base / fabricLuminance, 0)
            u.gloveArmor = SIMD4(g.armor, 0)
            u.gloveAccent = SIMD4(g.accent, g.glow)
        }
        u.sleeveBase = SIMD4(g.sleeve, 0)
        u.sleeveStripe = SIMD4(g.stripe, 0)
        u.sleeveCuff = g.cuff.map { SIMD4($0, 1) } ?? .zero
        u.sleeveShape = SIMD4(g.shape, g.amplitude, g.period, g.halfWidth)
        u.kind = SIMD4(c.pattern, g.base == nil ? 0 : 1, 0, 0)
        return u
    }
}

/// 解锁了哪些皮肤、现在用的是哪套（存在 UserDefaults，和别的设置一样）。
/// 纯数据（离屏测试用一个单独的 UserDefaults 测「重启以后还在」）。
struct SkinUnlocks: Equatable, Sendable {
    var canopies: Set<JumpScene> = []
    var gloves: Set<JumpScene> = []

    /// 一样新解锁的东西
    enum Item: Equatable, Sendable {
        case canopy(JumpScene)
        case gloves(JumpScene)

        /// 「降落伞「潟湖」」这样的一句
        var title: String {
            switch self {
            case .canopy(let s): String(localized: "降落伞「\(Skins.canopyName(s))」")
            case .gloves(let s): String(localized: "手套和袖子「\(Skins.glovesName(s))」")
            }
        }
    }

    /// 这一跳落地以后会新解锁什么（已经有的不算）
    func news(scene: JumpScene, outcome: JumpTimeline.Outcome) -> [Item] {
        let earned = Skins.earned(by: outcome)
        var items: [Item] = []
        if earned.canopy, !canopies.contains(scene) { items.append(.canopy(scene)) }
        if earned.gloves, !gloves.contains(scene) { items.append(.gloves(scene)) }
        return items
    }

    /// 记下这一跳，返回新解锁的
    mutating func record(scene: JumpScene, outcome: JumpTimeline.Outcome) -> [Item] {
        let items = news(scene: scene, outcome: outcome)
        for item in items {
            switch item {
            case .canopy(let s): canopies.insert(s)
            case .gloves(let s): gloves.insert(s)
            }
        }
        return items
    }

    static let canopiesKey = "unlockedCanopies", glovesKey = "unlockedGloves"

    init(canopies: Set<JumpScene> = [], gloves: Set<JumpScene> = []) {
        self.canopies = canopies
        self.gloves = gloves
    }

    init(defaults: UserDefaults) {
        // 存的是整数数组；启动参数（-unlockedCanopies '(0,1,4)'）读出来是字符串数组，两种都认
        func load(_ key: String) -> Set<JumpScene> {
            Set((defaults.array(forKey: key) ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } }
                .compactMap(JumpScene.init(rawValue:)))
        }
        canopies = load(Self.canopiesKey)
        gloves = load(Self.glovesKey)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(canopies.map(\.rawValue).sorted(), forKey: Self.canopiesKey)
        defaults.set(gloves.map(\.rawValue).sorted(), forKey: Self.glovesKey)
    }
}

/// 现在用的是哪套：nil = 默认。存成关的编号（-1 = 默认）
struct SkinChoice: Equatable, Sendable {
    var canopy: JumpScene?
    var gloves: JumpScene?

    static let canopyKey = "canopySkin", glovesKey = "gloveSkin"

    init(canopy: JumpScene? = nil, gloves: JumpScene? = nil) {
        self.canopy = canopy
        self.gloves = gloves
    }

    /// 读出来的选择如果没解锁（比如存档被清过一半），退回默认
    init(defaults: UserDefaults, unlocks: SkinUnlocks) {
        func load(_ key: String) -> JumpScene? {
            defaults.object(forKey: key) == nil ? nil : JumpScene(rawValue: defaults.integer(forKey: key))
        }
        canopy = load(Self.canopyKey).flatMap { unlocks.canopies.contains($0) ? $0 : nil }
        gloves = load(Self.glovesKey).flatMap { unlocks.gloves.contains($0) ? $0 : nil }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(canopy?.rawValue ?? -1, forKey: Self.canopyKey)
        defaults.set(gloves?.rawValue ?? -1, forKey: Self.glovesKey)
    }

    var uniforms: SkinUniforms { Skins.uniforms(canopy: canopy, gloves: gloves) }
}
