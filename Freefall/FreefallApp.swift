import CompositorServices
import SwiftUI

@main
struct FreefallApp: App {
    @State private var immersionStyle: ImmersionStyle = .full
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup(id: StartView.windowID) {
            StartView()
        }
        .defaultSize(width: 560, height: 460)

        ImmersiveSpace(id: StartView.spaceID) {
            CompositorLayer(configuration: FallLayerConfiguration()) { layerRenderer in
                ImmersiveRenderer.start(layerRenderer, handsEnabled: AppModel.shared.handsAllowed)
            }
        }
        // full：整个视野都是天空，看不到房间
        .immersionStyle(selection: $immersionStyle, in: .full)
        // 允许手部追踪时，系统不显示你的真手，换成画出来的跳伞手套；不允许就照常显示真手
        .upperLimbVisibility(model.handsAllowed ? .hidden : .visible)
    }
}

struct FallLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb

        // 注视点渲染：看的地方高分辨率，余光处低分辨率。shader 会用 rate map 把压缩后的像素坐标换回屏幕坐标。
        let foveation = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveation

        let layouts = capabilities.supportedLayouts(options: foveation ? [.foveationEnabled] : [])
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
    }
}
