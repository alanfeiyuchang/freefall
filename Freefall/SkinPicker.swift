import SwiftUI
import UIKit

/// 皮肤页（开始窗口里点「皮肤」打开）：上面切「降落伞 / 手套和袖子」，下面一个转盘——中间一张大的，
/// 两边露出上一张和下一张；左右滑的时候每张卡绕竖轴转，从一边滑到另一边正好转半圈。
/// 转盘里是默认 + 七关各一样：解锁了的点「换上」，没解锁的去色、带一把锁，下面写怎么解锁。
/// 缩略图是离屏渲染的截图（tools/render-check 的 xh_canopy_front_above、x1_ring 两个镜头裁的，放在 Resources/Skins/）。
struct SkinPicker: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Kind: Hashable { case canopy, gloves }

    @State private var kind: Kind = DebugOptions.skinsTab == 1 ? .gloves : .canopy
    /// 转盘中间那一张：-1 默认，0~6 关的编号
    @State private var focused: Int?
    /// 转盘现在滚到第几张（连续的：滑到两张中间是 x.5），每张卡按「自己是第几张 − 它」转
    @State private var scrolled: CGFloat = 0

    private static let items = [-1] + JumpScene.allCases.map(\.rawValue)
    private let cardSize = CGSize(width: 390, height: 260)

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Picker("皮肤", selection: $kind) {
                    Text("降落伞").tag(Kind.canopy)
                    Text("手套和袖子").tag(Kind.gloves)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                carousel
                details
                Text("落进降落点，解锁那一关的降落伞；落进正中的黄色靶心，再解锁那一关的手套和袖子。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }
            .padding(.bottom, 28)
            .navigationTitle("皮肤")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 660)
        // 打开时、切换两组时，转盘转到现在用的那一样
        .onAppear { focused = equipped(kind) }
        .onChange(of: kind) { _, k in focused = equipped(k) }
    }

    // MARK: 转盘

    private var carousel: some View {
        GeometryReader { geo in
            let width = geo.size.width, step = cardSize.width + 24
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(Self.items.enumerated()), id: \.element) { index, i in
                        let scene = JumpScene(rawValue: i)
                        SkinCard(kind: kind, scene: scene, unlocked: isUnlocked(kind, scene),
                                 equipped: equipped(kind) == i)
                            .frame(width: cardSize.width, height: cardSize.height)
                            .padding(.horizontal, 12)
                            // 离中间几张卡：每一张转 45°，相邻的斜着朝向中间，再远一张转到侧面；
                            // 从一边滑到另一边一共转半圈（90° → -90°），滑的时候跟着手连续地转
                            .rotation3DEffect(.degrees(-tilt(index) * 45), axis: (x: 0, y: 1, z: 0),
                                              anchor: .center, perspective: 0.45)
                            .scaleEffect(1 - 0.12 * abs(tilt(index)))
                            .opacity(1 - 0.3 * abs(tilt(index)))
                            .id(i)
                            .onTapGesture { withAnimation(.snappy) { focused = i } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focused, anchor: .center)
            // 滚动偏移 + 左边的留白 = 中间那张卡的左边，除以一张卡占的宽度就是滚到第几张
            .onScrollGeometryChange(for: CGFloat.self) { g in
                (g.contentOffset.x + g.contentInsets.leading) / step
            } action: { _, value in
                scrolled = value
            }
            .safeAreaPadding(.horizontal, max((width - step) / 2, 0))
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .frame(height: cardSize.height + 24)
    }

    // MARK: 中间那张的名字、状态、换上

    private var details: some View {
        let i = focused ?? -1
        let scene = JumpScene(rawValue: i)
        let unlocked = isUnlocked(kind, scene)
        let isEquipped = equipped(kind) == i
        let name = kind == .canopy ? Skins.canopyName(scene) : Skins.glovesName(scene)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.title.weight(.bold))
                Text(scene?.name ?? String(localized: "默认"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Group {
                if !unlocked {
                    Label(kind == .canopy ? LocalizedStringKey("落进降落点解锁") : LocalizedStringKey("落进黄色靶心解锁"),
                          systemImage: "lock.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else if isEquipped {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 12)
                } else {
                    Button {
                        withAnimation(.snappy) {
                            if kind == .canopy { model.skin.canopy = scene } else { model.skin.gloves = scene }
                        }
                    } label: {
                        Text("换上")
                            .font(.headline)
                            .frame(minWidth: 120)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .frame(minHeight: 52)
            // 七关里解锁了几样（小圆点：亮的是解锁了的，白圈是转盘中间这一张）
            HStack(spacing: 8) {
                ForEach(Self.items, id: \.self) { j in
                    Circle()
                        .fill(isUnlocked(kind, JumpScene(rawValue: j)) ? Color.orange : .white.opacity(0.25))
                        .frame(width: 9, height: 9)
                        .overlay { if j == i { Circle().stroke(.white, lineWidth: 2).frame(width: 15, height: 15) } }
                        .frame(width: 16, height: 16)
                }
            }
            .animation(.snappy, value: i)
            .accessibilityHidden(true)
        }
        .animation(.snappy, value: i)
    }

    /// 第 index 张离转盘中间几张（-2…2）
    private func tilt(_ index: Int) -> CGFloat { max(-2, min(CGFloat(index) - scrolled, 2)) }

    private func isUnlocked(_ kind: Kind, _ scene: JumpScene?) -> Bool {
        guard let scene else { return true }
        return kind == .canopy ? model.skinUnlocks.canopies.contains(scene) : model.skinUnlocks.gloves.contains(scene)
    }

    private func equipped(_ kind: Kind) -> Int {
        (kind == .canopy ? model.skin.canopy : model.skin.gloves)?.rawValue ?? -1
    }
}

/// 转盘里的一张卡：缩略图，左上角是哪一关，现在用着的右上角一个对勾。没解锁的去色、压暗，中间一把锁
struct SkinCard: View {
    let kind: SkinPicker.Kind
    let scene: JumpScene?
    let unlocked: Bool
    let equipped: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 26, style: .continuous) }

    var body: some View {
        let file = "skin_\(kind == .canopy ? "canopy" : "gloves")_\(scene?.key ?? "default").jpg"
        ZStack {
            if let image = UIImage(named: file) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.4)
            }
        }
        .saturation(unlocked ? 1 : 0)
        .brightness(unlocked ? 0 : -0.28)
        .overlay {
            if !unlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 6)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(scene?.name ?? String(localized: "默认"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            if equipped {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
                    .padding(12)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(equipped ? 0.9 : 0.15), lineWidth: equipped ? 3 : 1) }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .contentShape(.hoverEffect, shape)
        .hoverEffect()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(scene?.name ?? String(localized: "默认")) · "
            + (kind == .canopy ? Skins.canopyName(scene) : Skins.glovesName(scene))))
        .accessibilityValue(Text(unlocked ? LocalizedStringKey("已解锁") : LocalizedStringKey("未解锁")))
        .accessibilityAddTraits(equipped ? .isSelected : [])
    }
}

/// 卡片右上角的小徽章：伞或手套的小图形，解锁了是亮的，没解锁是暗的带一把小锁
struct SkinBadge: View {
    let kind: SkinPicker.Kind
    let unlocked: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(unlocked ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.black.opacity(0.45)))
            Group {
                if kind == .canopy {
                    CanopyGlyph()
                        .fill(.white)
                        .frame(width: 20, height: 12)
                } else {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .opacity(unlocked ? 1 : 0.55)
            if !unlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(.black.opacity(0.7)))
                    .offset(x: 11, y: 11)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityElement()
        .accessibilityLabel(Text(kind == .canopy ? LocalizedStringKey("降落伞") : LocalizedStringKey("手套和袖子")))
        .accessibilityValue(Text(unlocked ? LocalizedStringKey("已解锁") : LocalizedStringKey("未解锁")))
    }
}

/// 冲压翼伞的小图形：一道拱起来的弧形伞衣（上沿是弧，下沿是浅一点的弧）
struct CanopyGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.9))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.1, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.1, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.15))
        p.closeSubpath()
        return p
    }
}
