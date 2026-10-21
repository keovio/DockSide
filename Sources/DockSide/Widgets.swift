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

// MARK: - 通用外观：定时刷新的毛玻璃胶囊
struct Ticking<Content: View>: View {
    let every: TimeInterval
    @ViewBuilder var content: () -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: every)) { _ in
            content()
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - 一侧的组件排布
struct SideView: View {
    @ObservedObject var store: WidgetStore
    let side: Side
    var body: some View {
        HStack(spacing: 10) {
            ForEach(store.selected[side] ?? [], id: \.self) { id in
                allWidgets.first { $0.id == id }?.make()
            }
        }
        // 左侧靠近 Dock 右对齐，右侧左对齐
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: side == .left ? .trailing : .leading)
    }
}
