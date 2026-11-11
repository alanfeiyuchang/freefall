import ARKit
import SwiftUI
import UIKit

/// 开始窗口：左右滑的关卡卡片（每关一张截图），顶上是这一关和所有关落地离靶心最近的一次，设置在窗口下面的浮条里（文字）。
struct StartView: View {
    static let windowID = "start"
    static let spaceID = "fall"

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @Bindable private var model = AppModel.shared
    @State private var selection: Int?
    /// 正在问「拉环转向可能会晕，确定打开吗」
    @State private var confirmingSteering = false

    private let cardSize = CGSize(width: 264, height: 352)

    var body: some View {
        VStack(spacing: 16) {
            header
            carousel
            pageDots
            jumpButton
                .padding(.top, 6)
        }
        .padding(.vertical, 28)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            settingsBar
                .padding(.top, 18)
        }
        .alert("拉环转向可能引起晕动症", isPresented: $confirmingSteering) {
            Button("打开") { model.toggleSteering = true }
            Button("不打开", role: .cancel) {}
        } message: {
            Text("打开以后，伞下拉左、右操纵环会让整个世界绕着你转，有些人会头晕、恶心。不舒服就停下来，回到这里关掉。\n关着的时候靠转头、转身来转向，伞跟着你转，不容易晕。")
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

    // MARK: 标题、最近距离、上一跳

    private var header: some View {
        VStack(spacing: 10) {
            Text("FREEFALL")
                .font(.largeTitle.weight(.heavy))
                .tracking(12)
            HStack(spacing: 28) {
                record("本关最近", model.bestDistance[selection ?? model.scene.rawValue].map(Self.meters) ?? "—")
                record("全部最近", model.overallBest.map { "\(Self.meters($0.distance))（\($0.scene.name)）" } ?? "—")
            }
            if let result = model.lastResult {
                Text("上一跳（\(result.scene.name)）：\(result.summary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func record(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.title3)
        .contentTransition(.numericText())
        .animation(.snappy, value: value)
    }

    static func meters(_ d: Double) -> String { d < 10 ? String(format: "%.1f m", d) : "\(Int(d.rounded())) m" }

    // MARK: 卡片

    private var carousel: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 28) {
                    ForEach(JumpScene.allCases) { scene in
                        SceneCard(scene: scene, size: cardSize, selected: selection == scene.id)
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
            Text(model.lastResult == nil ? "跳" : "再跳一次")
                .font(.title.weight(.bold))
                .frame(minWidth: 160)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(model.isFalling)
    }

    // MARK: 设置（窗口下面的浮条）

    private var settingsBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 26) {
                setting("高度表戴在") {
                    Picker("高度表戴在", selection: $model.watchOnLeft) {
                        Text("左手腕").tag(true)
                        Text("右手腕").tag(false)
                    }
                    .frame(width: 170)
                }
                setting("手") {
                    Picker("手", selection: $model.gloves) {
                        Text("跳伞手套").tag(true)
                        Text("真手").tag(false)
                    }
                    .frame(width: 170)
                }
                // 伞下怎么转向：默认只靠转头、转身（伞跟着你转）；要加上拉操纵环转向得先确认（世界绕着你转，可能会晕）
                setting("伞下转向") {
                    Picker("伞下转向", selection: Binding(get: { model.toggleSteering }, set: { on in
                        if on { confirmingSteering = true } else { model.toggleSteering = false }
                    })) {
                        Text("转头转身").tag(false)
                        Text("加拉环").tag(true)
                    }
                    .frame(width: 190)
                }
            }
            .pickerStyle(.segmented)
            Text("建议坐着、戴耳机 · 点手腕上的表开关 HUD · 按数码表冠随时退出")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .glassBackgroundEffect()
    }

    private func setting<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
            content()
        }
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

/// 一关的卡片：截图和关名（别的字都不放：介绍只留给旁白）
struct SceneCard: View {
    let scene: JumpScene
    let size: CGSize
    let selected: Bool

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
            Text(scene.name)
                .font(.title.weight(.bold))
                .padding(.top, 50)
                .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(selected ? 0.85 : 0.14), lineWidth: selected ? 3 : 1) }
        .shadow(color: .black.opacity(0.35), radius: selected ? 16 : 6, y: 6)
        .contentShape(.hoverEffect, shape)
        .hoverEffect()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(scene.name)：\(scene.blurb)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
