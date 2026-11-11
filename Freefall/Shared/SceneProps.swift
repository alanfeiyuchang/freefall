import Foundation
import simd

/// 各关的实体模型：树、石头、房子、塔……都是程序生成的网格，启动时算一次（SkyCity.Layout：
/// buildings 不透明的网格，waterfalls 半透明叠加的瀑布，obstacles 伞撞上会出事的圆柱形包围）。
/// 画法见 SceneRenderer 里的 city：也画进深度预渲染（云不会盖到它前面），片元里叠云和空气透视。
/// 每关一个文件（Props<关名>.swift），顶点在地面坐标里（x、海拔、z）；高度按 TerrainField 的地形函数取。
enum SceneProps {
    typealias Layout = SkyCity.Layout

    static func layout(for scene: JumpScene) -> Layout {
        switch scene {
        case .atoll: AtollProps.layout
        case .grassland: GrasslandProps.layout
        case .alpine: AlpineProps.layout
        case .snow: SnowProps.layout
        case .island: IslandProps.layout
        case .volcano: VolcanoProps.layout
        case .sky: SkyCity.layout
        }
    }

    /// 这一点（地面坐标、脚的海拔）是不是撞进了哪个障碍
    static func hits(_ scene: JumpScene, _ p: SIMD2<Double>, altitude: Double) -> Bool {
        layout(for: scene).obstacles.contains {
            altitude < $0.top && simd_length_squared(p - $0.center) < $0.radius * $0.radius
        }
    }
}
