import CoreGraphics; import CoreText; import Foundation; import ImageIO; import UniformTypeIdentifiers
let W = 3840, H = 2160
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func draw(_ s: String, size: CGFloat, weight: CGFloat, y: CGFloat, alpha: CGFloat, kern: CGFloat) {
  let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "SF Pro Display", kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary), size, nil)
  let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: alpha), .init(kCTKernAttributeName as String): kern]
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
  let w = CTLineGetTypographicBounds(line, nil, nil, nil)
  ctx.setShadow(offset: .zero, blur: 40, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
  ctx.textPosition = CGPoint(x: (CGFloat(W) - CGFloat(w)) / 2, y: y)
  CTLineDraw(line, ctx)
}
draw("FREEFALL", size: 300, weight: 0.4, y: 1120, alpha: 1, kern: 60)
draw("A skydive for Apple Vision Pro", size: 96, weight: 0.0, y: 930, alpha: 0.92, kern: 4)
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
