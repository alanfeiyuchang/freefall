import ARKit
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
            Text("30,000 英尺 · 第一人称 · 约 4 分钟")
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
                Text("· 你会站在运输机的货舱里，面朝放下的尾舱门")
                Text("· 跳伞灯变绿后，捏一下手指跳出去（不捏也会自己跳）")
                Text("· 高度表戴在左手腕上，抬手看；760 米自动开伞")
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
        // 手部追踪：第一次会弹授权。不允许也能玩，只是没有手套，高度表放在前下方
        if HandTrackingProvider.isSupported {
            let result = await ARKitSession().requestAuthorization(for: [.handTracking])
            model.handsAllowed = result[.handTracking] == .allowed
        } else {
            model.handsAllowed = false
        }
        if case .opened = await openImmersiveSpace(id: Self.spaceID) {
            model.isFalling = true
            dismissWindow(id: Self.windowID)
        }
    }
}
