import CompositorServices
import SwiftUI

@main
struct FreefallApp: App {
    @State private var immersionStyle: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup(id: StartView.windowID) {
            StartView()
        }
        .defaultSize(width: 720, height: 660)

        ImmersiveSpace(id: StartView.spaceID) {
            CompositorLayer(configuration: FallLayerConfiguration()) { layerRenderer in
                ImmersiveRenderer.start(layerRenderer, handsEnabled: AppModel.shared.handsAllowed,
                                        watchOnLeft: AppModel.shared.watchOnLeft, scene: AppModel.shared.scene)
            }
        }
        // full：整个视野都是天空，看不到房间
        .immersionStyle(selection: $immersionStyle, in: .full)
        // 真手透视出来，按深度和画面合成：表盘比手腕近，就盖在手腕上；伞绳、舱壁比手远，就被手挡住。
        // （.visible 会让手永远盖在最上面，手腕上的表就看不见了）
        .upperLimbVisibility(.automatic)
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
