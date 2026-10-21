import SwiftUI

// MARK: - 组件注册表（加新组件 = 在这里加一行）
struct WidgetDef {
    let id: String
    let name: String
    let make: () -> AnyView
}

let allWidgets: [WidgetDef] = [
    WidgetDef(id: "clock",   name: "时钟") { AnyView(Ticking(every: 1)  { Text(Date(), format: .dateTime.hour().minute().second()) }) },
    WidgetDef(id: "date",    name: "日期") { AnyView(Ticking(every: 60) { Text(Date(), format: .dateTime.month().day().weekday(.wide)) }) },
    WidgetDef(id: "cpu",     name: "CPU")  { AnyView(Ticking(every: 2)  { Label("\(Int(Metrics.cpu.usage() * 100))%", systemImage: "cpu") }) },
    WidgetDef(id: "memory",  name: "内存") { AnyView(Ticking(every: 5)  { Label("\(Int(Metrics.memoryUsage() * 100))%", systemImage: "memorychip") }) },
    WidgetDef(id: "battery", name: "电量") { AnyView(Ticking(every: 30) { Label(Metrics.batteryLevel().map { "\($0)%" } ?? "—", systemImage: "battery.75") }) },
]

// MARK: - 字号随 Dock 高度自动调整
private struct WidgetFontSizeKey: EnvironmentKey { static let defaultValue: CGFloat = 16 }
extension EnvironmentValues {
    var widgetFontSize: CGFloat {
        get { self[WidgetFontSizeKey.self] }
        set { self[WidgetFontSizeKey.self] = newValue }
    }
}

// MARK: - 通用外观：定时刷新的毛玻璃胶囊（尺寸跟随字号）
struct Ticking<Content: View>: View {
    let every: TimeInterval
    @ViewBuilder var content: () -> Content
    @Environment(\.widgetFontSize) private var size

    var body: some View {
        TimelineView(.periodic(from: .now, by: every)) { _ in
            content()
                .font(.system(size: size, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()                       // 文字永不截断
                .foregroundStyle(.white)
                .padding(.horizontal, size * 0.8)
                .padding(.vertical, size * 0.45)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

private struct ContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 一侧的组件排布：按 Dock 高度定字号，放不下就整体等比缩小
struct SideView: View {
    @ObservedObject var store: WidgetStore
    let side: Side
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let fontSize = max(10, h * 0.26)
            let anchor: UnitPoint = side == .left ? .trailing : .leading
            let scale = contentWidth > 0 ? min(1, geo.size.width / contentWidth) : 1

            HStack(spacing: fontSize * 0.5) {
                ForEach(store.selected[side] ?? [], id: \.self) { id in
                    allWidgets.first { $0.id == id }?.make()
                }
            }
            .environment(\.widgetFontSize, fontSize)
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentWidthKey.self, value: g.size.width)
            })
            .scaleEffect(scale, anchor: anchor)
            // 左侧贴近 Dock 右对齐，右侧左对齐
            .frame(width: geo.size.width, height: h, alignment: side == .left ? .trailing : .leading)
        }
        .onPreferenceChange(ContentWidthKey.self) { contentWidth = $0 }
    }
}
