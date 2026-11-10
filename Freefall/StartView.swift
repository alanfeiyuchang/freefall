import ARKit
import SwiftUI

struct StartView: View {
    static let windowID = "start"
    static let spaceID = "fall"

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @Bindable private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 20) {
            Text("FREEFALL")
                .font(.extraLargeTitle2)
                .tracking(14)
            Text("30,000 英尺 · 第一人称 · 落到靶上才算赢")
                .font(.title3)
                .foregroundStyle(.secondary)

            if let result = model.lastResult {
                Text("上一跳：\(result)")
                    .font(.headline)
            }

            Button {
                Task { await jump() }
            } label: {
                Text(model.lastResult == nil ? "跳" : "再跳一次")
                    .font(.title)
                    .frame(minWidth: 160)
            }
            .disabled(model.isFalling)
            .padding(.top, 4)

            HStack(spacing: 14) {
                Text("高度表戴在")
                Picker("高度表戴在", selection: $model.watchOnLeft) {
                    Text("左手腕").tag(true)
                    Text("右手腕").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("· 建议坐着，戴上耳机")
                Text("· 你站在运输机放下的尾舱门上。抓住右手边的黄色扶杆，跳伞灯变绿；松手就跳")
                Text("· 手表在 3,500 英尺报警，这时右手抓住胸前的红色拉手往外拉，开伞")
                Text("· 伞下伸手抓头两侧的黄色操纵环：拉左边左转，拉右边右转")
                Text("· 落进沙洲上的红白靶子才算赢。开伞太晚会摔")
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
        // 手部追踪：第一次会弹授权。用来抓扶杆、拉伞、拉操纵环，把高度表戴在手腕上。
        // 不允许也能玩：捏住手指抓扶杆、松开跳，报警后捏一下开伞，捏住往下拉转向
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
