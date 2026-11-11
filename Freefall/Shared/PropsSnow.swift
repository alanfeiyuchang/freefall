import Foundation
import simd

/// 雪山这一关的实体模型（见 SceneProps）。现在是空的
enum SnowProps {
    static let layout: SkyCity.Layout = build()

    private static func build() -> SkyCity.Layout {
        SkyCity.Layout()
    }
}
