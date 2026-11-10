import CoreGraphics
import CoreText
import Foundation
import Metal

/// 浮在你面前的提示文字（中文）：用 CoreText 画到一张贴图上，文字变了才重画。
/// 每次重画都换一张新贴图（不改 GPU 可能还在读的那张）。
final class TextPanel: @unchecked Sendable {
    private let device: MTLDevice
    private(set) var texture: MTLTexture?
    private(set) var text = ""
    /// 贴图宽高比（宽 / 高）
    private(set) var aspect: Float = 4

    init(device: MTLDevice) {
        self.device = device
    }

    /// 设置文字；和上次一样就什么都不做。空字符串 = 不显示。
    func set(_ newText: String) {
        guard newText != text else { return }
        text = newText
        guard !newText.isEmpty else { texture = nil; return }

        let lines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let scale: CGFloat = 2
        let fontSize: CGFloat = 30 * scale
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, "zh-Hans" as CFString)
            ?? CTFontCreateWithName("PingFangSC-Medium" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        let widths = ctLines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let lineHeight = fontSize * 1.35
        let padding = fontSize * 0.8
        let width = Int((widths.max() ?? 0) + padding * 2)
        let height = Int(lineHeight * CGFloat(lines.count) + padding * 1.2)
        guard width > 0, height > 0 else { texture = nil; return }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            for (i, line) in ctLines.enumerated() {
                let x = (CGFloat(width) - widths[i]) / 2
                let y = CGFloat(height) - padding * 0.6 - lineHeight * CGFloat(i + 1) + fontSize * 0.3
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                         mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return }
        pixels.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        texture = t
        aspect = Float(width) / Float(height)
    }
}
