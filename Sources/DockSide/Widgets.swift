import SwiftUI

// MARK: - 组件注册表（加新组件 = 在这里加一行 + 写一个 View）
struct WidgetDef {
    let id: String
    let name: String
    let symbol: String
    let make: () -> AnyView
}

let allWidgets: [WidgetDef] = [
    WidgetDef(id: "clock",    name: "时钟",   symbol: "clock")       { AnyView(ClockWidget()) },
    WidgetDef(id: "date",     name: "日期",   symbol: "calendar")    { AnyView(DateWidget()) },
    WidgetDef(id: "cpu",      name: "CPU",    symbol: "cpu")         { AnyView(CPUWidget()) },
    WidgetDef(id: "memory",   name: "内存",   symbol: "memorychip")  { AnyView(MemoryWidget()) },
    WidgetDef(id: "battery",  name: "电量",   symbol: "battery.75")  { AnyView(BatteryWidget()) },
    WidgetDef(id: "todo",     name: "待办",   symbol: "checklist")   { AnyView(TodoWidget()) },
    WidgetDef(id: "pomodoro", name: "番茄钟", symbol: "timer")       { AnyView(PomodoroWidget()) },
]

func widgetDef(_ id: String) -> WidgetDef? { allWidgets.first { $0.id == id } }

// MARK: - 环境：字号、是否竖排紧凑版
private struct WidgetFontSizeKey: EnvironmentKey { static let defaultValue: CGFloat = 16 }
private struct CompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var widgetFontSize: CGFloat {
        get { self[WidgetFontSizeKey.self] }
        set { self[WidgetFontSizeKey.self] = newValue }
    }
    /// Dock 在左右两侧时为 true，组件显示竖排紧凑版
    var compact: Bool {
        get { self[CompactKey.self] }
        set { self[CompactKey.self] = newValue }
    }
}

/// 组件统一的文字样式
struct WidgetText: ViewModifier {
    @Environment(\.widgetFontSize) private var size
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.white)
    }
}

extension View {
    /// 深色毛玻璃底
    func glass<S: InsettableShape>(_ shape: S) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.28))
                shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

/// 进度环
struct ProgressRing<Label: View>: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat
    var color: Color = Color(red: 0.36, green: 0.82, blue: 0.55)
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label()
        }
        .frame(width: size, height: size)
    }
}

private struct ContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - 一侧的组件排布
/// 横向 Dock：左组在 Dock 左边、右组在右边；竖向 Dock：左组在上方、右组在下方（紧凑版）。
/// 字号按 Dock 粗细自动计算，放不下就整体等比缩小。
struct SideView: View {
    @ObservedObject var store: WidgetStore
    let side: Side
    @ObservedObject private var dock = DockState.shared
    @AppStorage(Pref.style) private var style = "unified"
    @AppStorage(Pref.fontScale) private var fontScale = 1.0
    @State private var contentSize: CGSize = .zero
    @State private var available: CGSize = .zero
    /// 实在放不下时只显示前几个（缩放低于 minScale 就去掉最后一个）
    @State private var limit = Int.max
    private let minScale: CGFloat = 0.7

    var body: some View {
        GeometryReader { geo in
            let vertical = dock.vertical
            let base = vertical ? geo.size.width * 0.2 : geo.size.height * 0.26
            let fontSize = max(9, base * fontScale)
            let all = (store.selected[side] ?? []).filter { widgetDef($0) != nil }
            let ids = Array(all.prefix(limit))
            let scale: CGFloat = vertical
                ? (contentSize.height > 0 ? min(1, geo.size.height / contentSize.height) : 1)
                : (contentSize.width > 0 ? min(1, geo.size.width / contentSize.width) : 1)
            let nearDock: Alignment = vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)
            let anchor: UnitPoint = vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)

            row(ids: ids, vertical: vertical, size: fontSize)
                .environment(\.widgetFontSize, fontSize)
                .environment(\.compact, vertical)
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentSizeKey.self, value: g.size)
                })
                .scaleEffect(scale, anchor: anchor)
                .frame(width: geo.size.width, height: geo.size.height, alignment: nearDock)
                .onAppear { available = geo.size }
                .onChange(of: geo.size) { available = $0; limit = Int.max }
                .onChange(of: all) { _ in limit = Int.max }
                .onChange(of: dock.vertical) { _ in limit = Int.max }
        }
        .onPreferenceChange(ContentSizeKey.self) { size in
            contentSize = size
            let need = dock.vertical ? size.height / max(available.height, 1) : size.width / max(available.width, 1)
            let shown = min(limit, (store.selected[side] ?? []).count)
            if need > 0, 1 / need < minScale, shown > 1 { limit = shown - 1 }
        }
    }

    @ViewBuilder
    private func row(ids: [String], vertical: Bool, size: CGFloat) -> some View {
        if ids.isEmpty {
            EmptyView()
        } else if style == "unified" {
            // 合成一条：一个玻璃底，组件之间细线分隔
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    widgetDef(id)!.make()
                        .padding(vertical ? .vertical : .horizontal, size * 0.55)
                    if i < ids.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: vertical ? size * 1.6 : 1, height: vertical ? 1 : size * 1.2)
                    }
                }
            }
            .padding(vertical ? .vertical : .horizontal, size * 0.4)
            .padding(vertical ? .horizontal : .vertical, size * 0.45)
            .glass(RoundedRectangle(cornerRadius: vertical ? size * 0.9 : size * 3, style: .continuous))
        } else {
            // 分开的胶囊
            let layout = vertical ? AnyLayout(VStackLayout(spacing: size * 0.4)) : AnyLayout(HStackLayout(spacing: size * 0.5))
            layout {
                ForEach(ids, id: \.self) { id in
                    widgetDef(id)!.make()
                        .padding(.horizontal, size * (vertical ? 0.45 : 0.8))
                        .padding(.vertical, size * 0.45)
                        .glass(RoundedRectangle(cornerRadius: vertical ? size * 0.9 : size * 3, style: .continuous))
                }
            }
        }
    }
}
