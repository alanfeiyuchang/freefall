import SwiftUI

struct StartView: View {
    static let windowID = "start"
    static let spaceID = "fall"

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private let model = AppModel.shared

    var body: some View {
        VStack(spacing: 22) {
            Text("FREEFALL")
                .font(.extraLargeTitle2)
                .tracking(14)
            Text("30,000 英尺 · 第一人称 · 约 2 分钟")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button {
                Task { await jump() }
            } label: {
                Text("跳")
                    .font(.title)
                    .frame(minWidth: 160)
            }
            .disabled(model.isFalling)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("· 建议坐着，戴上耳机")
                Text("· 低头看高度表；想看哪里就转头")
                Text("· 按一下数码表冠随时退出")
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
        .padding(40)
        .onAppear {
            model.openWindow = openWindow
            model.dismissImmersiveSpace = dismissImmersiveSpace
        }
        .task {
            guard DebugOptions.autoEnter, !model.isFalling else { return }
            await jump()
        }
    }

    private func jump() async {
        model.openWindow = openWindow
        model.dismissImmersiveSpace = dismissImmersiveSpace
        if case .opened = await openImmersiveSpace(id: Self.spaceID) {
            model.isFalling = true
            dismissWindow(id: Self.windowID)
        }
    }
}
