import Foundation
import CoreGraphics

/// 所有偏好设置的键和默认值
enum Pref {
    static let style        = "style"         // "unified" 合成一条 | "separate" 分开的胶囊
    static let fontScale    = "fontScale"     // 1.0 = 自动
    static let clockSeconds = "clockSeconds"
    static let clock24h     = "clock24h"
    static let todoMaxChars = "todoMaxChars"
    static let todoTitleChars = "todoTitleChars"
    static let todoHover    = "todoHover"
    static let todoSound    = "todoSound"
    static let todoAutoClear = "todoAutoClear"
    static let pomoFocus    = "pomoFocus"
    static let pomoBreak    = "pomoBreak"
    static let pomoSound    = "pomoSound"
    static let pomoAutoNext = "pomoAutoNext"
    static let alignTop     = "alignTop"      // 贴合 Dock 微调（pt），正数 = 往上
    static let alignBottom  = "alignBottom"
    static let dockGap      = "dockGap"
    static let glassTint    = "glassTint"

    static func register() {
        UserDefaults.standard.register(defaults: [
            style: "merged", fontScale: 1.0,
            clockSeconds: true, clock24h: true,
            todoMaxChars: 20, todoTitleChars: 6, todoHover: true, todoSound: true, todoAutoClear: true,
            pomoFocus: 25, pomoBreak: 5, pomoSound: true, pomoAutoNext: true,
            alignTop: 0.0, alignBottom: 0.0, dockGap: 4.0, glassTint: 0.38,
        ])
    }
}

/// Dock 当前的方向，布局和组件据此切换横排 / 竖排紧凑版
final class DockState: ObservableObject {
    static let shared = DockState()
    @Published var vertical = false     // Dock 在屏幕左右两侧
    @Published var dockOnLeft = false
    @Published var radius: CGFloat = 12   // Dock 玻璃底的圆角
}
