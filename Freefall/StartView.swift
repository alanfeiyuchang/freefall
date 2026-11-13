import ARKit
import SwiftUI
import UIKit

/// 开始窗口：左右滑的关卡卡片（每关一张截图），顶上是这一关和所有关落地离降落点最近的一次，设置在窗口下面的浮条里（文字）。
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
    /// 皮肤选择页开着
    @State private var showingSkins = false
    /// 上一跳的航线开着
    @State private var showingReplay = false

    private let cardSize = CGSize(width: 264, height: 352)

    var body: some View {
        VStack(spacing: 16) {
            header
            carousel
            pageDots
            HStack(spacing: 18) {
                skinsButton
                jumpButton
                practiceButton
            }
            .padding(.top, 6)
            if !model.practiceAvailable(currentScene) {
                Text("这一关平安落地一次以后，可以从开伞前开始练")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 28)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            settingsBar
                .padding(.top, 18)
        }
        .sheet(isPresented: $showingSkins) {
            SkinPicker(model: model)
        }
        .sheet(isPresented: $showingReplay) {
            if let result = model.lastResult { ReplayView(result: result) }
        }
        .alert("拉环转向可能引起晕动症", isPresented: $confirmingSteering) {
            Button("打开") { model.toggleSteering = true }
            Button("不打开", role: .cancel) {}
        } message: {
            Text("打开以后，伞下拉左、右操纵环会让整个世界绕着你转，有些人会头晕、恶心。不舒服就停下来，回到这里关掉。\n关着的时候靠转头、转身来转向，伞跟着你转，不容易晕。")
        }
        .onAppear {
            selection = model.scene.id
            // 调试：假装刚落进靶心（在存下打开窗口的动作之前，免得又开一个窗口）
            if let scene = DebugOptions.demoBullseye, model.lastResult == nil {
                model.isFalling = true
                model.fallEnded(result: JumpResult(scene: scene, outcome: .bullseye, distance: 1.4))
            }
            model.openWindow = openWindow
            model.dismissImmersiveSpace = dismissImmersiveSpace
            if DebugOptions.showSkins { showingSkins = true }
            // 调试：CPU 上用自动驾驶跳一次，看航线页
            if let scene = DebugOptions.demoReplay {
                let s = JumpSession(timeline: JumpTimeline(scene: scene), realHands: false,
                                    autopilot: Autopilot(deployFeet: DebugOptions.autoDeployFeet))
                let layout = BodyLayout(anchor: SIMD3(0, 1.6, 0), yaw: 0)
                var steps = 0
                while s.timeline.landedTime == nil, steps < 200_000 { s.step(dt: 1.0 / 30, hands: [], layout: layout); steps += 1 }
                model.lastResult = s.jumpResult
                showingReplay = true
            }
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
                record("全部最近", model.overallBest.map { "\(Self.meters($0.distance)) · \($0.scene.name)" } ?? "—")
            }
            if let result = model.lastResult {
                HStack(spacing: 12) {
                    Text("上一跳（\(result.scene.name)）：\(result.summary)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // 俯视回放：开伞以后的航线、落点偏了多少（ReplayView）
                    if result.track.count >= 2 {
                        Button {
                            showingReplay = true
                        } label: {
                            Label("航线", systemImage: "map")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            if !model.lastUnlocks.isEmpty {
                // 这一跳新解锁的皮肤：点一下直接打开皮肤页
                Button {
                    showingSkins = true
                } label: {
                    Label(String(localized: "解锁了新皮肤：\(model.lastUnlocks.map(\.title).joined(separator: " · "))"),
                          systemImage: "sparkles")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func record(_ label: LocalizedStringKey, _ value: String) -> some View {
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
                        SceneCard(scene: scene, size: cardSize, selected: selection == scene.id,
                                  canopyUnlocked: model.skinUnlocks.canopies.contains(scene),
                                  glovesUnlocked: model.skinUnlocks.gloves.contains(scene))
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

    // MARK: 跳、皮肤

    private var skinsButton: some View {
        Button {
            showingSkins = true
        } label: {
            Label("皮肤", systemImage: "paintpalette.fill")
                .font(.title3.weight(.semibold))
                .padding(.vertical, 6)
        }
        .disabled(model.isFalling)
    }

    /// 卡片转到的这一关
    private var currentScene: JumpScene { JumpScene(rawValue: selection ?? model.scene.rawValue) ?? model.scene }

    /// 练习：跳过机舱和七十秒的自由落体，从离着陆区 5,000 英尺开始（这一关平安落地过一次以后才能点）
    private var practiceButton: some View {
        Button {
            model.practice = true
            Task { await jump() }
        } label: {
            Label("开伞前开始", systemImage: "forward.end.fill")
                .font(.title3.weight(.semibold))
                .padding(.vertical, 6)
        }
        .disabled(model.isFalling || !model.practiceAvailable(currentScene))
    }

    private var jumpButton: some View {
        Button {
            Task { await jump() }
        } label: {
            Text(model.lastResult == nil ? LocalizedStringKey("跳") : LocalizedStringKey("再跳一次"))
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
                    .fixedSize()
                }
                // 伞下怎么转向：默认只靠转头、转身（伞跟着你转）；要加上拉操纵环转向得先确认（世界绕着你转，可能会晕）
                setting("伞下转向") {
                    Picker("伞下转向", selection: Binding(get: { model.toggleSteering }, set: { on in
                        if on { confirmingSteering = true } else { model.toggleSteering = false }
                    })) {
                        Text("转头转身").tag(false)
                        Text("加拉环").tag(true)
                    }
                    .fixedSize()
                }
                // 拉平：默认自动（离地 6 米自己拉平）；手动要自己两边一起拉操纵环，没拉平是重着陆、不给靶心
                setting("拉平") {
                    Picker("拉平", selection: $model.autoFlare) {
                        Text("自动").tag(true)
                        Text("手动").tag(false)
                    }
                    .fixedSize()
                }
                // 性能测试：开伞后自动轮流关掉画面的各个部分量耗时（约半分钟，画面会一段一段变），结果存进文件
                setting("性能测试") {
                    Picker("性能测试", selection: $model.perfTest) {
                        Text("关").tag(false)
                        Text("这一跳测").tag(true)
                    }
                    .fixedSize()
                }
                // 语言（放在最右边）：默认跟随系统；点一下弹出菜单，十种语言各用自己的写法
                setting("语言") {
                    Picker("语言", selection: $model.language) {
                        Text("跟随系统").tag("")
                        Divider()
                        ForEach(Localization.languages, id: \.code) { language in
                            Text(verbatim: language.name).tag(language.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .pickerStyle(.segmented)
            if !model.perfReport.isEmpty {
                // 上一次性能测试的结果（从 Mac 收不到输出时，可以在这里看 / 截图）
                ScrollView {
                    Text(model.perfReport)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 150)
                .padding(.horizontal, 24)
            }
            Text("建议坐着、戴耳机 · 点一下手腕上的表开关 HUD，按住两秒退出这一跳")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .glassBackgroundEffect()
    }

    private func setting<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        // 标题和选择器都按内容撑开（写死宽度时英文、加了性能测试以后的中文都会被截成「…」）
        HStack(spacing: 10) {
            Text(label)
                .fixedSize()
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
        } else {
            model.practice = false
        }
    }
}

/// 一关的卡片：截图和关名（别的字都不放：介绍只留给旁白）
struct SceneCard: View {
    let scene: JumpScene
    let size: CGSize
    let selected: Bool
    /// 这一关的伞、手套和袖子解锁了没有（卡片右上角两个小徽章）
    var canopyUnlocked = false
    var glovesUnlocked = false

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
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                SkinBadge(kind: .canopy, unlocked: canopyUnlocked)
                SkinBadge(kind: .gloves, unlocked: glovesUnlocked)
            }
            .padding(12)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(selected ? 0.85 : 0.14), lineWidth: selected ? 3 : 1) }
        .shadow(color: .black.opacity(0.35), radius: selected ? 16 : 6, y: 6)
        .contentShape(.hoverEffect, shape)
        .hoverEffect()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(scene.name)：\(scene.blurb)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
