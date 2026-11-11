import simd

// 和 Shaders/Common.h 逐字段对应，只用 SIMD4 / float4x4，两边对齐一样。

struct ViewUniforms {
    var viewProjection: simd_float4x4
    var inverseViewProjection: simd_float4x4
    var cameraPosition: SIMD4<Float>
    var viewport: SIMD4<Float>
}

struct FrameUniforms {
    /// xyz 指向太阳
    var sunDirection = SIMD4<Float>(0, 1, 0, 0)
    /// x 舞台 y 加上它 = 海拔（米），y 时间，z 画面亮度，w 有注视点 rate map（SceneRenderer 填）
    var camera = SIMD4<Float>(0, 0, 1, 0)
    /// xz 你在云坐标里的水平位置（米），yw 地面坐标 - 云坐标（JumpTimeline.landShift）
    var ground = SIMD4<Float>(0, 0, 0, 0)
    /// x 云层分辨率比例，y 步长倍数，z 消光系数，w 覆盖率偏移（SceneRenderer 按 settings 填）
    var clouds = SIMD4<Float>(0.5, 1, 0.035, 0)
    /// x 曝光
    var exposure = SIMD4<Float>(3, 0, 0, 0)
    /// 高度表中心（舞台空间），w 宽
    var hudCenter = SIMD4<Float>(0, 0, 0, 0)
    /// 右方向，w 高
    var hudRight = SIMD4<Float>(1, 0, 0, 0)
    /// 上方向，w 不透明度（0 = 不画）
    var hudUp = SIMD4<Float>(0, 1, 0, 0)
    /// 高度数字的字形，每字节一个（0-9、10 逗号、255 结束）
    var hudGlyphs = SIMD4<UInt32>(repeating: 0xFFFF_FFFF)
    /// x 样式（0 前方面板，1 手腕表盘），y 表盘外圈弧的比例，z 报警（0/1/2）
    var hudStyle = SIMD4<Float>(0, 0, 0, 0)
    /// x cos 航向，y sin 航向，z 转弯时的暗边强度
    var heading = SIMD4<Float>(1, 0, 0, 0)
    /// x 场景编号，y 云层整体抬高多少米，z 有地形（SceneRenderer 按场景填）
    var world = SIMD4<Float>(0, 0, 0, 0)
    /// 伞衣的影子（舞台空间）：xyz 伞衣中心，w 影子强度（0 = 没开伞；充气越足越接近 1）
    var canopyCenter = SIMD4<Float>(0, 0, 0, 0)
    /// xyz 展向单位向量（左翼尖 → 右翼尖），w 投影的半展长（米）
    var canopySpan = SIMD4<Float>(1, 0, 0, 0)
    /// xyz 弦向单位向量（前缘 → 后缘），w 半弦长（米）
    var canopyChord = SIMD4<Float>(0, 0, 1, 0)
    /// 身体的影子（舞台空间）：xyz 头顶，w 有没有（0/1）。身体当成一根从头顶竖直垂到脚的胶囊
    var bodyShadow = SIMD4<Float>(0, 0, 0, 0)
    /// xyz 身体的右方向
    var bodyRight = SIMD4<Float>(1, 0, 0, 0)
    /// 左、右手腕（舞台空间），w 有没有：胳膊的影子从肩膀连到这里
    var armShadow = (SIMD4<Float>(0, 0, 0, 0), SIMD4<Float>(0, 0, 0, 0))
    /// 开场的实体化：xyz 起点（舞台空间），w 波前半径（米；-1 = 还在房间里只有扶杆，≥ 1000 = 全部完成）
    var reveal = SIMD4<Float>(0, 0, 0, 1e6)
}

/// 和 Objects.h 的 LineSegment 一样：一段绳子（伞绳、刹车绳），画成朝着眼睛的细长条
struct LineSegment {
    /// xyz 起点，w 半径（米）
    var a: SIMD4<Float>
    /// xyz 终点，w 未用
    var b: SIMD4<Float>
    /// rgb 颜色（反照率），a 未用
    var color: SIMD4<Float>

    init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, color: SIMD3<Float>) {
        self.a = SIMD4(a, radius)
        self.b = SIMD4(b, 0)
        self.color = SIMD4(color, 0)
    }
}

/// 和 Common.h 的 PanelUniforms 一样：提示文字面板
struct PanelUniforms {
    var center: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
}

/// 和 Rain.h 的 RingInstance 一样：自由落体路上的一个光环
struct RingInstance {
    /// xyz 圆心（舞台空间），w 半径（米）
    var center: SIMD4<Float>
    /// rgb 颜色，a 亮度
    var color: SIMD4<Float>
}

/// 和 Rain.h 的 RainUniforms 一样：身边的雨丝
struct RainUniforms {
    /// xyz 雨相对你累计走过的距离（舞台空间，米，按盒子取模），w 强度 0…1
    var offset: SIMD4<Float>
    /// xyz 雨相对你的速度（舞台空间，m/s），w 拖影时长（秒）
    var velocity: SIMD4<Float>
    /// xyz 盒子中心（你的头），w 雨丝总数
    var center: SIMD4<Float>
    /// x 盒子边长（米）
    var box: SIMD4<Float>
}

/// 和 Objects.h 的 ObjectUniforms 一样
struct ObjectUniforms {
    var model: simd_float4x4
    /// x 跳伞灯（0 红 1 绿），y 机舱里的程度
    var params: SIMD4<Float>
}

struct TemporalUniforms {
    /// xy 这一帧重算 2×2 块里的哪个像素，z 帧序号，w 历史有效
    var pattern = SIMD4<Float>(0, 0, 0, 0)
    /// w 有上一帧的 rate map
    var motion = SIMD4<Float>(0, 0, 0, 0)
    /// 这一帧：x、z 你在云坐标里的位置，y 舞台 → 海拔的偏移，w 航向
    var now = SIMD4<Float>(0, 0, 0, 0)
    /// 上一帧，同上
    var prev = SIMD4<Float>(0, 0, 0, 0)
}

/// 和 Common.h 的 AtmosphereConstants 一样大（6 个 float4），只在 GPU 上读写。
let atmosphereConstantsSize = MemoryLayout<SIMD4<Float>>.stride * 6

extension FrameUniforms {
    /// 把高度（英尺，按 10 取整）排成「29,800」这样的字形序列。
    static func glyphs(feet: Int) -> SIMD4<UInt32> {
        let rounded = max(0, (feet + 5) / 10 * 10)
        var digits = String(rounded)
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + digits.suffix(3) + grouped
            digits.removeLast(3)
        }
        grouped = digits + grouped
        var bytes = [UInt8](repeating: 255, count: 16)
        for (i, ch) in grouped.prefix(8).enumerated() {
            bytes[i] = ch == "," ? 10 : UInt8(ch.wholeNumberValue ?? 0)
        }
        func word(_ i: Int) -> UInt32 {
            UInt32(bytes[i * 4]) | UInt32(bytes[i * 4 + 1]) << 8 | UInt32(bytes[i * 4 + 2]) << 16 | UInt32(bytes[i * 4 + 3]) << 24
        }
        return SIMD4(word(0), word(1), word(2), word(3))
    }
}
