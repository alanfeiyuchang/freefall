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
    /// xz 海面和岛相对你的水平偏移（米）
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
}

struct TemporalUniforms {
    /// xy 这一帧重算 2×2 块里的哪个像素，z 帧序号，w 历史有效
    var pattern = SIMD4<Float>(0, 0, 0, 0)
    /// x 这一帧到上一帧的海拔差，y 有上一帧的 rate map
    var motion = SIMD4<Float>(0, 0, 0, 0)
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
