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
private struct InkKey: EnvironmentKey { static let defaultValue = Color.white }
extension EnvironmentValues {
    var widgetFontSize: CGFloat {
        get { self[WidgetFontSizeKey.self] }
        set { self[WidgetFontSizeKey.self] = newValue }
    }
    /// 文字颜色：深色玻璃上用白色，融进 Dock 时跟随系统深浅色
    var widgetInk: Color {
        get { self[InkKey.self] }
        set { self[InkKey.self] = newValue }
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
    @Environment(\.widgetInk) private var ink
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(ink)
    }
}

extension View {
    /// 深色毛玻璃底
    func glass<S: InsettableShape>(_ shape: S) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.14))
                shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
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
    @Environment(\.widgetInk) private var ink

    var body: some View {
        ZStack {
            Circle().stroke(ink.opacity(0.2), lineWidth: lineWidth)
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
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        // 同级的分隔线、留白会带来默认的 0，不能把真正的尺寸覆盖掉
        let n = nextValue()
        if n != .zero { value = n }
    }
}

// MARK: - 一侧的组件排布
/// 横向 Dock：左组在 Dock 左边、右组在右边；竖向 Dock：左组在上方、右组在下方（紧凑版）。
/// 「融进 Dock」样式：紧贴 Dock、补上 Dock 端头的圆角缺口，接缝处一条竖杠，看起来像 Dock 变长了。
/// 字号按 Dock 粗细自动计算，放不下就整体等比缩小，再不行就隐藏排在后面的组件。
struct SideView: View {
    @ObservedObject var store: WidgetStore
    let side: Side
    @ObservedObject private var dock = DockState.shared
    @AppStorage(Pref.style) private var style = "merged"
    @AppStorage(Pref.fontScale) private var fontScale = 1.0
    @State private var contentSize: CGSize = .zero
    @State private var available: CGFloat = 0
    /// 实在放不下时只显示前几个（缩放低于 minScale 就去掉最后一个）
    @State private var limit = Int.max
    private let minScale: CGFloat = 0.7

    var body: some View {
        GeometryReader { geo in
            let vertical = dock.vertical
            let merged = style == "merged"
            let cross = vertical ? geo.size.width : geo.size.height
            let r = merged ? dock.radius : 0
            let mainAvail = (vertical ? geo.size.height : geo.size.width) - (merged ? r + cross * 0.45 : 0)
            let fontSize = max(9, cross * (vertical ? 0.2 : 0.24) * fontScale)
            let all = (store.selected[side] ?? []).filter { widgetDef($0) != nil }
            let ids = Array(all.prefix(limit))
            let need = vertical ? contentSize.height : contentSize.width
            let scale: CGFloat = need > 0 ? min(1, mainAvail / need) : 1
            let nearDock: Alignment = vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)
            let anchor: UnitPoint = vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)

            Group {
                if ids.isEmpty {
                    Color.clear
                } else if merged {
                    mergedBar(ids: ids, vertical: vertical, size: fontSize, cross: cross, r: r, scale: scale)
                } else {
                    measured(row(ids: ids, vertical: vertical, size: fontSize, cross: cross), size: fontSize, vertical: vertical)
                        .scaleEffect(scale, anchor: anchor)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: nearDock)
            .onAppear { available = mainAvail }
            .onChange(of: geo.size) { _ in available = mainAvail; limit = Int.max }
            .onChange(of: all) { _ in limit = Int.max }
            .onChange(of: style) { _ in limit = Int.max }
            .onChange(of: dock.vertical) { _ in limit = Int.max }
        }
        .onPreferenceChange(ContentSizeKey.self) { size in
            contentSize = size
            let need = dock.vertical ? size.height : size.width
            let shown = min(limit, (store.selected[side] ?? []).count)
            if need > 0, available > 0, available / need < minScale, shown > 1 { limit = shown - 1 }
        }
    }

    /// 测量内容原始尺寸
    private func measured<V: View>(_ v: V, size: CGFloat, vertical: Bool) -> some View {
        v.environment(\.widgetFontSize, size)
            .environment(\.compact, vertical)
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentSizeKey.self, value: g.size)
            })
    }

    /// Dock 朝向本面板的哪条边
    private func dockEdge(_ vertical: Bool) -> Edge {
        vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)
    }

    private func spacer(_ len: CGFloat, _ vertical: Bool) -> some View {
        Color.clear.frame(width: vertical ? nil : len, height: vertical ? len : nil)
    }

    @ViewBuilder
    private func mergedBar(ids: [String], vertical: Bool, size: CGFloat, cross: CGFloat, r: CGFloat, scale: CGFloat) -> some View {
        let edge = dockEdge(vertical)
        let dockFirst = edge == .leading || edge == .top
        let content = measured(row(ids: ids, vertical: vertical, size: size, cross: cross, merged: true), size: size, vertical: vertical)
            .environment(\.widgetInk, Color.primary)
            .scaleEffect(scale)
            .frame(width: vertical ? nil : contentSize.width * scale,
                   height: vertical ? contentSize.height * scale : nil)
        let sep = Rectangle()
            .fill(Color.primary.opacity(0.28))
            .frame(width: vertical ? cross * 0.6 : 1, height: vertical ? 1 : cross * 0.6)
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        stack {
            if dockFirst {
                spacer(r, vertical)               // 盖在 Dock 端头上的那一段（透明，只补圆角缺口）
                spacer(cross * 0.1, vertical)
                sep
                spacer(cross * 0.15, vertical)
                content
                spacer(cross * 0.2, vertical)
            } else {
                spacer(cross * 0.2, vertical)
                content
                spacer(cross * 0.15, vertical)
                sep
                spacer(cross * 0.1, vertical)
                spacer(r, vertical)
            }
        }
        .frame(width: vertical ? cross : nil, height: vertical ? nil : cross)
        .background(
            VisualEffect(material: .popover)
                .clipShape(MergedShape(dockEdge: edge, radius: r), style: FillStyle(eoFill: true))
        )
    }

    @ViewBuilder
    private func row(ids: [String], vertical: Bool, size: CGFloat, cross: CGFloat, merged: Bool = false) -> some View {
        if merged || style == "unified" {
            // 一个底，组件之间细线分隔
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            let ink = merged ? Color.primary : Color.white
            let body = layout {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    widgetDef(id)!.make()
                        .padding(vertical ? .vertical : .horizontal, size * 0.55)
                    if i < ids.count - 1 {
                        Rectangle()
                            .fill(ink.opacity(0.22))
                            .frame(width: vertical ? size * 1.6 : 1, height: vertical ? 1 : size * 1.2)
                    }
                }
            }
            if merged {
                body
            } else {
                body
                    .padding(vertical ? .vertical : .horizontal, size * 0.4)
                    .frame(width: vertical ? cross : nil, height: vertical ? nil : cross)
                    .glass(RoundedRectangle(cornerRadius: cross * 0.36, style: .continuous))
            }
        } else {
            // 分开的胶囊
            let layout = vertical ? AnyLayout(VStackLayout(spacing: size * 0.4)) : AnyLayout(HStackLayout(spacing: size * 0.5))
            layout {
                ForEach(ids, id: \.self) { id in
                    widgetDef(id)!.make()
                        .padding(.horizontal, size * (vertical ? 0.45 : 0.8))
                        .padding(.vertical, size * 0.45)
                        .frame(width: vertical ? cross : nil, height: vertical ? nil : cross)
                        .glass(RoundedRectangle(cornerRadius: cross * 0.36, style: .continuous))
                }
            }
        }
    }
}

/// 融进 Dock 的外形：外侧圆角，靠 Dock 一侧方角；再扣掉 Dock 自己的圆角矩形（偶奇填充），
/// 这样 Dock 端头圆角外面的缺口会被补上，Dock 本体不被盖住。
struct MergedShape: Shape {
    let dockEdge: Edge
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = radius
        let tl: CGFloat = (dockEdge == .leading || dockEdge == .top) ? 0 : r
        let tr: CGFloat = (dockEdge == .trailing || dockEdge == .top) ? 0 : r
        let br: CGFloat = (dockEdge == .trailing || dockEdge == .bottom) ? 0 : r
        let bl: CGFloat = (dockEdge == .leading || dockEdge == .bottom) ? 0 : r

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr) }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br) }
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl) }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl) }
        p.closeSubpath()

        // Dock 本体（只有伸进本面板的 r 那一段有意义）
        let big: CGFloat = 4000
        let dockRect: CGRect
        switch dockEdge {
        case .leading:  dockRect = CGRect(x: rect.minX - big, y: rect.minY, width: big + r, height: rect.height)
        case .trailing: dockRect = CGRect(x: rect.maxX - r, y: rect.minY, width: big + r, height: rect.height)
        case .top:      dockRect = CGRect(x: rect.minX, y: rect.minY - big, width: rect.width, height: big + r)
        case .bottom:   dockRect = CGRect(x: rect.minX, y: rect.maxY - r, width: rect.width, height: big + r)
        }
        if r > 0 { p.addRoundedRect(in: dockRect, cornerSize: CGSize(width: r, height: r), style: .continuous) }
        return p
    }
}
