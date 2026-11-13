import CompositorServices
import SwiftUI

@main
struct FreefallApp: App {
    /// 混合沉浸：开场先透出你的房间，只有那根扶杆；握住以后飞机和天一点点长出来，把整个视野盖满
    /// （盖满以后和完全沉浸看起来一样；不中途切换沉浸方式，免得渲染层被重建）
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var model = AppModel.shared

    init() {
        // 开始窗口里选的语言（默认跟随系统）：在任何文字取翻译之前装好
        Localization.apply(AppModel.shared.language)
    }

    var body: some Scene {
        WindowGroup(id: StartView.windowID) {
            StartView()
                // Text("…") 按环境的 locale 取翻译；id 跟着语言变，整个窗口重建一遍，
                // 用 String(localized:) 算出来的字（关名、介绍）也按新语言重新算
                .environment(\.locale, Localization.locale(model.language))
                .id(model.language)
        }
        .defaultSize(width: 860, height: 720)

        ImmersiveSpace(id: StartView.spaceID) {
            CompositorLayer(configuration: FallLayerConfiguration()) { layerRenderer in
                ImmersiveRenderer.start(layerRenderer, handsEnabled: AppModel.shared.handsAllowed,
                                        watchOnLeft: AppModel.shared.watchOnLeft, gloves: AppModel.shared.gloves,
                                        toggleSteering: AppModel.shared.toggleSteering,
                                        perfTest: AppModel.shared.perfTest,
                                        skin: AppModel.shared.skin, skinUnlocks: AppModel.shared.skinUnlocks,
                                        practice: AppModel.shared.practice, autoFlare: AppModel.shared.autoFlare,
                                        scene: AppModel.shared.scene)
                // 性能测试、练习只管这一跳：渲染器拿到开关以后就复位（中途按表冠退出也不会留着）
                AppModel.shared.perfTest = false
                AppModel.shared.practice = false
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
        // 戴手套：开场在房间里还是真手（只有扶杆），握住扶杆、手套跟着飞机长出来以后，
        // 真手和前臂整个藏起来，只画手套（苹果的手套示例也是这么做的）。
        // 不戴：真手透视出来，按深度和画面合成：表盘比手腕近，就盖在手腕上；伞绳、舱壁比手远，就被手挡住。
        // （.visible 会让手永远盖在最上面，手腕上的表就看不见了）
        .upperLimbVisibility(model.realHandsHidden ? .hidden : .automatic)
        // 看手心时系统会冒出 Home 键（还有翻过手来的控制中心），跳伞时抓扶杆、拉环、拉操纵环全是张着手，
        // 一不小心就点到。整个沉浸空间里都藏起来（和 Wandless 这类手势游戏一样）；按一下数码表冠照样能退出
        .persistentSystemOverlays(.hidden)
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
