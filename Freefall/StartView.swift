import ARKit
import SwiftUI
import UIKit

/// 开始窗口：左右滑的关卡卡片（每关一张截图），玩法是一排轮流亮起来的图标，设置在窗口下面的浮条里。
/// 字尽量少：说明都放在悬停提示里（看着图标一会儿就弹出来）。
struct StartView: View {
    static let windowID = "start"
    static let spaceID = "fall"

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @Bindable private var model = AppModel.shared
    @State private var selection: Int?

    private let cardSize = CGSize(width: 264, height: 352)

    var body: some View {
        VStack(spacing: 16) {
            header
            carousel
            pageDots
            HowToStrip()
                .padding(.top, 4)
            jumpButton
        }
        .padding(.vertical, 28)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            settingsBar
                .padding(.top, 18)
        }
        .onAppear {
            selection = model.scene.id
            model.openWindow = openWindow
            model.dismissImmersiveSpace = dismissImmersiveSpace
        }
        .onChange(of: selection) { _, id in
            if let id, let scene = JumpScene(rawValue: id), scene != model.scene { model.scene = scene }
        }
        .task {
            guard DebugOptions.autoEnter, !model.isFalling else { return }
            await jump()
        }
    }

    // MARK: 标题和上一跳

    private var header: some View {
        HStack(spacing: 18) {
            Text("FREEFALL")
                .font(.largeTitle.weight(.heavy))
                .tracking(12)
            if let result = model.lastResult {
                HStack(spacing: 8) {
                    Image(systemName: result.symbol)
                        .foregroundStyle(result.won ? Color.yellow : Color.orange)
                        .symbolEffect(.bounce, value: result.summary)
                    if result.landed {
                        Text(Self.meters(result.distance))
                            .monospacedDigit()
                    }
                }
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.18), in: Capsule())
                .help(result.summary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(result.summary)
            }
        }
    }

    static func meters(_ d: Double) -> String { d < 10 ? String(format: "%.1f m", d) : "\(Int(d.rounded())) m" }

    // MARK: 卡片

    private var carousel: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 28) {
                    ForEach(JumpScene.allCases) { scene in
                        SceneCard(scene: scene, size: cardSize, selected: selection == scene.id,
                                  best: model.bestDistance[scene.rawValue])
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                let k = min(abs(phase.value), 1)
                                return content
                                    .scaleEffect(1 - 0.17 * k)
                                    .opacity(1 - 0.5 * k)
                                    .offset(y: 14 * k)
                            }
                            .id(scene.id)
                            .onTapGesture { withAnimation(.snappy) { selection = scene.id } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selection, anchor: .center)
            .safeAreaPadding(.horizontal, max((geo.size.width - cardSize.width) / 2, 0))
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .frame(height: cardSize.height + 20)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(JumpScene.allCases) { scene in
                Capsule()
                    .fill(.white.opacity(scene.id == selection ? 0.95 : 0.3))
                    .frame(width: scene.id == selection ? 22 : 8, height: 8)
            }
        }
        .animation(.snappy, value: selection)
        .accessibilityHidden(true)
    }

    // MARK: 跳

    private var jumpButton: some View {
        Button {
            Task { await jump() }
        } label: {
            Image(systemName: "figure.fall")
                .font(.system(size: 46, weight: .semibold))
                .symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 1.6)))
                .frame(width: 104, height: 104)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(.orange)
        .disabled(model.isFalling)
        .help(model.lastResult == nil ? "跳" : "再跳一次")
        .accessibilityLabel(model.lastResult == nil ? "跳" : "再跳一次")
    }

    // MARK: 设置（窗口下面的浮条）

    private var settingsBar: some View {
        HStack(spacing: 20) {
            IconPicker(selection: $model.watchOnLeft, options: [
                IconOption(value: true, symbol: "hand.raised.fill", mirrored: true, badge: "applewatch",
                           help: "高度表戴在左手腕"),
                IconOption(value: false, symbol: "hand.raised.fill", badge: "applewatch", help: "高度表戴在右手腕"),
            ])
            IconPicker(selection: $model.gloves, options: [
                IconOption(value: true, symbol: "hand.raised.fill", tint: Color(red: 0.98, green: 0.55, blue: 0.16),
                           help: "戴跳伞手套（真手藏起来）"),
                IconOption(value: false, symbol: "hand.raised.fingers.spread.fill",
                           tint: Color(red: 0.96, green: 0.8, blue: 0.66), help: "用真手"),
            ])
            IconPicker(selection: $model.snapTurns, options: [
                IconOption(value: false, symbol: "point.topleft.down.to.point.bottomright.curvepath",
                           help: "伞下平滑转向"),
                IconOption(value: true, symbol: "stairs", help: "伞下分段转向：一次转 15°，不容易晕"),
            ])
            Divider()
                .frame(height: 38)
            HStack(spacing: 16) {
                Image(systemName: "figure.seated.side")
                    .help("建议坐着玩")
                Image(systemName: "headphones")
                    .help("戴上耳机")
                Image(systemName: "digitalcrown.press.fill")
                    .help("按一下数码表冠，随时退出")
            }
            .font(.title2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    private func jump() async {
        model.openWindow = openWindow
        model.dismissImmersiveSpace = dismissImmersiveSpace
        // 手部追踪：第一次会弹授权。用来抓扶杆、拉伞、拉操纵环，把高度表戴在手腕上。
        // 不允许也能玩：捏住手指抓扶杆、松开跳，报警后捏一下开伞，捏住往下拉转向
        if HandTrackingProvider.isSupported {
            let result = await ARKitSession().requestAuthorization(for: [.handTracking])
            model.handsAllowed = result[.handTracking] == .allowed
        } else {
            model.handsAllowed = false
        }
        model.realHandsHidden = false
        if case .opened = await openImmersiveSpace(id: Self.spaceID) {
            model.isFalling = true
            dismissWindow(id: Self.windowID)
        }
    }
}

/// 一关的卡片：截图、关名、要躲开的东西（图标），落进过靶的话右上角是最好成绩
struct SceneCard: View {
    let scene: JumpScene
    let size: CGSize
    let selected: Bool
    let best: Double?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 30, style: .continuous) }

    var body: some View {
        ZStack {
            if let image = UIImage(named: "card_\(scene.key).jpg") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                Text(scene.name)
                    .font(.title.weight(.bold))
                HStack(spacing: 12) {
                    ForEach(scene.hazardSymbols, id: \.self) { Image(systemName: $0) }
                }
                .font(.title3)
                .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.5))
            }
            .padding(.top, 50)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
        }
        .overlay(alignment: .topTrailing) {
            if let best {
                HStack(spacing: 5) {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(.yellow)
                    Text(StartView.meters(best))
                        .monospacedDigit()
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(14)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(selected ? 0.85 : 0.14), lineWidth: selected ? 3 : 1) }
        .shadow(color: .black.opacity(0.35), radius: selected ? 16 : 6, y: 6)
        .contentShape(.hoverEffect, shape)
        .hoverEffect()
        .help(scene.blurb)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(scene.name)：\(scene.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 玩法：六个步骤的图标连成一排，轮流亮起来（图标跳一下），下面只有一行很短的字跟着换
struct HowToStrip: View {
    private struct Step {
        let symbol: String
        let tint: Color
        let caption: String
        var bar = false
    }

    private let steps: [Step] = [
        Step(symbol: "hand.raised.fill", tint: .yellow, caption: "握住黄色扶杆", bar: true),
        Step(symbol: "light.beacon.max.fill", tint: .green, caption: "绿灯，松手"),
        Step(symbol: "figure.fall", tint: .cyan, caption: "自由落体"),
        Step(symbol: "record.circle.fill", tint: .red, caption: "报警：拉大臂上的拉环"),
        Step(symbol: "arrow.left.arrow.right", tint: .orange, caption: "拉操纵环转向"),
        Step(symbol: "scope", tint: .pink, caption: "落进靶心"),
    ]
    private let period = 1.8

    var body: some View {
        TimelineView(.periodic(from: .now, by: period)) { context in
            let active = Int(context.date.timeIntervalSinceReferenceDate / period) % steps.count
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    ForEach(steps.indices, id: \.self) { i in
                        if i > 0 {
                            Capsule()
                                .fill(.white.opacity(i <= active ? 0.6 : 0.15))
                                .frame(width: 30, height: 3)
                        }
                        icon(steps[i], active: i == active)
                    }
                }
                Text(steps[active].caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .id(active)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .animation(.spring(duration: 0.5), value: active)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(steps.map(\.caption).joined(separator: "，"))
    }

    private func icon(_ step: Step, active: Bool) -> some View {
        ZStack {
            Circle()
                .fill(active ? step.tint.opacity(0.28) : .white.opacity(0.07))
            if step.bar {
                Capsule()
                    .fill(.yellow.opacity(active ? 1 : 0.4))
                    .frame(width: 5, height: 30)
                    .offset(x: 7)
            }
            Image(systemName: step.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(active ? step.tint : .secondary)
                .symbolEffect(.bounce, value: active)
        }
        .frame(width: 50, height: 50)
        .scaleEffect(active ? 1.16 : 1)
    }
}

/// 图标版的分段选择：两三个图标放在一个胶囊里，选中的亮、背景高亮；说明在悬停提示里
struct IconOption<Value: Hashable>: Identifiable {
    let value: Value
    let symbol: String
    var mirrored = false
    var badge: String?
    var tint: Color?
    let help: String

    var id: Value { value }
}

struct IconPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [IconOption<Value>]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let on = option.value == selection
                Button {
                    withAnimation(.snappy) { selection = option.value }
                } label: {
                    ZStack(alignment: .bottom) {
                        Image(systemName: option.symbol)
                            .font(.title2)
                            .scaleEffect(x: option.mirrored ? -1 : 1, y: 1)
                            .foregroundStyle(option.tint ?? .primary)
                            .frame(maxHeight: .infinity)
                        if let badge = option.badge {
                            Image(systemName: badge)
                                .font(.caption.weight(.bold))
                                .padding(.bottom, 1)
                        }
                    }
                    .frame(width: 58, height: 48)
                    .opacity(on ? 1 : 0.4)
                    .background(.white.opacity(on ? 0.2 : 0), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect()
                .help(option.help)
                .accessibilityLabel(option.help)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.black.opacity(0.14), in: Capsule())
    }
}
