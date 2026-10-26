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
    // 日程
    static let scheduleTitleChars        = "scheduleTitleChars"
    static let scheduleHover             = "scheduleHover"
    static let scheduleWindow            = "scheduleWindow"        // "today" | "24h" | "3d"
    static let scheduleShowAllDay        = "scheduleShowAllDay"
    static let schedule24h               = "schedule24h"
    static let scheduleShowCalendarColor = "scheduleShowCalendarColor"
    static let scheduleSound             = "scheduleSound"
    static let scheduleCalendars         = "scheduleCalendars"     // 逗号分隔，空 = 全部
    static let scheduleSource            = "scheduleSource"        // "auto"
    static let scheduleLastRung          = "scheduleLastRung"
    static let scheduleLastImport        = "scheduleLastImport"    // 上次导入时间
    static let scheduleDismissDeniedTip  = "scheduleDismissDeniedTip"
    static let alignTop     = "alignTop"      // 贴合 Dock 微调（pt），正数 = 往上
    static let alignBottom  = "alignBottom"
    static let dockGap      = "dockGap"
    static let glassTint    = "glassTint"
    static let musicTitleChars = "musicTitleChars"
    static let countdownChars = "countdownChars"
    // 组件显示内容（只影响横排；竖排紧凑版不变）
    static let clockDate        = "clockDate"
    static let clockWeekday     = "clockWeekday"
    static let metricIcon       = "metricIcon"
    static let todoShowRing     = "todoShowRing"
    static let todoShowTitle    = "todoShowTitle"
    static let todoShowCheck    = "todoShowCheck"
    static let scheduleShowTime   = "scheduleShowTime"
    static let scheduleShowDay    = "scheduleShowDay"
    static let scheduleShowTitle  = "scheduleShowTitle"
    static let scheduleShowRemain = "scheduleShowRemain"
    static let pomoShowRing     = "pomoShowRing"
    static let pomoShowLabel    = "pomoShowLabel"
    static let pomoShowTime     = "pomoShowTime"
    static let musicShowCover   = "musicShowCover"
    static let musicShowArtist  = "musicShowArtist"
    static let musicShowButtons = "musicShowButtons"
    static let countdownShowName  = "countdownShowName"
    static let countdownShowLabel = "countdownShowLabel"
    // AI 用量
    static let aiShowDeepSeek   = "aiShowDeepSeek"
    static let aiShowGLM        = "aiShowGLM"
    static let aiShowToday      = "aiShowToday"
    static let aiGLMRegion      = "aiGLMRegion"       // "cn" | "intl"
    static let aiRefreshMinutes = "aiRefreshMinutes"
    static let aiDSDay          = "aiDSDay"           // 今日花费的起点：日期+币种
    static let aiDSDayStart     = "aiDSDayStart"      // 今日起点余额

    static func register() {
        UserDefaults.standard.register(defaults: [
            style: "merged", fontScale: 1.0,
            clockSeconds: true, clock24h: true,
            todoMaxChars: 20, todoTitleChars: 6, todoHover: true, todoSound: true, todoAutoClear: true,
            pomoFocus: 25, pomoBreak: 5, pomoSound: true, pomoAutoNext: true,
            scheduleTitleChars: 6, scheduleHover: true, scheduleWindow: "today",
            scheduleShowAllDay: true, schedule24h: true, scheduleShowCalendarColor: true,
            scheduleSound: false, scheduleCalendars: "", scheduleSource: "auto",
            scheduleLastRung: "", scheduleLastImport: "", scheduleDismissDeniedTip: false,
            alignTop: 0.0, alignBottom: 0.0, dockGap: 4.0, glassTint: 0.38,
            musicTitleChars: 7, countdownChars: 5,
            clockDate: false, clockWeekday: false, metricIcon: true,
            todoShowRing: true, todoShowTitle: true, todoShowCheck: true,
            scheduleShowTime: true, scheduleShowDay: true, scheduleShowTitle: true, scheduleShowRemain: true,
            pomoShowRing: true, pomoShowLabel: true, pomoShowTime: true,
            musicShowCover: true, musicShowArtist: true, musicShowButtons: true,
            countdownShowName: true, countdownShowLabel: true,
            aiShowDeepSeek: true, aiShowGLM: true, aiShowToday: true, aiGLMRegion: "cn", aiRefreshMinutes: 5,
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
