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
    WidgetDef(id: "music",    name: "正在播放", symbol: "music.note") { AnyView(NowPlayingWidget()) },
    WidgetDef(id: "countdown", name: "倒数日", symbol: "calendar.badge.clock") { AnyView(CountdownWidget()) },
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

/// 每个组件单独测出来的尺寸（id → size）
private struct ItemSizesKey: PreferenceKey {
    static let defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - 一侧的组件排布
/// 横向 Dock：左组在 Dock 左边、右组在右边；竖向 Dock：左组在上方、右组在下方（紧凑版）。
/// 「融进 Dock」样式：紧贴 Dock、补上 Dock 端头的圆角缺口，接缝处一条竖杠，看起来像 Dock 变长了。
/// 每个组件先在看不见的地方单独量好尺寸，再直接算出放得下几个、缩放多少：
/// 字最多缩到 minScale，再放不下就少放末尾的组件。不靠"先显示再缩"的反馈，所以不会闪。
struct SideView: View {
    @ObservedObject var store: WidgetStore
    let side: Side
    @ObservedObject private var dock = DockState.shared
    @AppStorage(Pref.style) private var style = "merged"
    @AppStorage(Pref.fontScale) private var fontScale = 1.0
    @AppStorage(Pref.glassTint) private var glassTint = 0.38
    @Environment(\.colorScheme) private var scheme
    @State private var itemSizes: [String: CGSize] = [:]
    private let minScale: CGFloat = 0.85   // 字不能缩得太小，低于这个比例就少放一个组件

    private struct Plan { var ids: [String]; var scale: CGFloat; var contentLen: CGFloat }

    /// 算出显示哪几个、缩放多少
    private func plan(all: [String], vertical: Bool, size: CGFloat, avail: CGFloat) -> Plan? {
        let lens = all.map { id -> CGFloat? in
            guard let s = itemSizes[id] else { return nil }
            return vertical ? s.height : s.width
        }
        guard !all.isEmpty, lens.allSatisfy({ $0 != nil }), avail > 0 else { return nil }
        let gapLen: CGFloat = style == "separate" ? size * (vertical ? 0.4 : 0.5) : 1
        let extra: CGFloat = style == "unified" ? size * 0.8 : 0
        func content(_ n: Int) -> CGFloat {
            lens.prefix(n).reduce(0) { $0 + ($1 ?? 0) } + CGFloat(max(0, n - 1)) * gapLen
        }
        var n = all.count
        while n > 1, (content(n) + extra) * minScale > avail { n -= 1 }
        let len = content(n)
        return Plan(ids: Array(all.prefix(n)), scale: min(1, avail / (len + extra)), contentLen: len)
    }

    var body: some View {
        GeometryReader { geo in
            let vertical = dock.vertical
            let merged = style == "merged"
            let cross = vertical ? geo.size.width : geo.size.height
            let r = merged ? dock.radius : 0
            let avail = (vertical ? geo.size.height : geo.size.width) - (merged ? r + cross * 0.45 : 0)
            let fontSize = max(9, cross * (vertical ? 0.21 : 0.27) * fontScale)
            let all = (store.selected[side] ?? []).filter { widgetDef($0) != nil }
            let p = plan(all: all, vertical: vertical, size: fontSize, avail: avail)
            let nearDock: Alignment = vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)
            let anchor: UnitPoint = vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)

            ZStack(alignment: nearDock) {
                // 看不见的测量层：每个组件单独量尺寸
                measureLayer(all: all, vertical: vertical, size: fontSize, cross: cross, merged: merged)
                    .fixedSize()
                    .hidden()
                    .frame(width: 0, height: 0)

                if let p {
                    if merged {
                        mergedBar(plan: p, vertical: vertical, size: fontSize, cross: cross, r: r)
                    } else {
                        env(row(ids: p.ids, vertical: vertical, size: fontSize, cross: cross), size: fontSize, vertical: vertical)
                            .fixedSize()
                            .scaleEffect(p.scale, anchor: anchor)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: nearDock)
        }
        .onPreferenceChange(ItemSizesKey.self) { sizes in
            // 只在有明显变化时更新，避免秒数跳动引起来回重算
            let changed = sizes.contains { id, s in
                guard let old = itemSizes[id] else { return true }
                return abs(old.width - s.width) > 0.5 || abs(old.height - s.height) > 0.5
            }
            if changed || sizes.count != itemSizes.count { itemSizes = sizes }
        }
    }

    private func env<V: View>(_ v: V, size: CGFloat, vertical: Bool) -> some View {
        v.environment(\.widgetFontSize, size)
            .environment(\.compact, vertical)
    }

    /// 单个组件在当前样式下占的样子（和真正排布时一样的留白）
    @ViewBuilder
    private func item(_ id: String, vertical: Bool, size: CGFloat, cross: CGFloat) -> some View {
        if style == "separate" {
            widgetDef(id)!.make()
                .padding(.horizontal, size * (vertical ? 0.45 : 0.8))
                .padding(.vertical, size * 0.45)
                .frame(width: vertical ? cross : nil, height: vertical ? nil : cross)
        } else {
            widgetDef(id)!.make()
                .padding(vertical ? .vertical : .horizontal, size * 0.55)
        }
    }

    private func measureLayer(all: [String], vertical: Bool, size: CGFloat, cross: CGFloat, merged: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(all, id: \.self) { id in
                item(id, vertical: vertical, size: size, cross: cross)
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ItemSizesKey.self, value: [id: g.size])
                    })
            }
        }
        .environment(\.widgetFontSize, size)
        .environment(\.compact, vertical)
        .environment(\.widgetInk, merged ? Color.primary : Color.white)
    }

    /// Dock 朝向本面板的哪条边
    private func dockEdge(_ vertical: Bool) -> Edge {
        vertical ? (side == .left ? .bottom : .top) : (side == .left ? .trailing : .leading)
    }

    private func spacer(_ len: CGFloat, _ vertical: Bool) -> some View {
        Color.clear.frame(width: vertical ? nil : len, height: vertical ? len : nil)
    }

    @ViewBuilder
    private func mergedBar(plan p: Plan, vertical: Bool, size: CGFloat, cross: CGFloat, r: CGFloat) -> some View {
        let edge = dockEdge(vertical)
        let dockFirst = edge == .leading || edge == .top
        let content = env(row(ids: p.ids, vertical: vertical, size: size, cross: cross, merged: true), size: size, vertical: vertical)
            .environment(\.widgetInk, Color.primary)
            .fixedSize()
            .scaleEffect(p.scale)
            .frame(width: vertical ? nil : p.contentLen * p.scale,
                   height: vertical ? p.contentLen * p.scale : nil)
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
            ZStack {
                VisualEffect(material: .popover)
                // 系统材质比 Dock 浅，压暗一点对上 Dock 的颜色（深色模式少压一些）
                Color.black.opacity(glassTint * (scheme == .dark ? 0.4 : 1))
            }
            .clipShape(MergedShape(dockEdge: edge, radius: r, cover: 3), style: FillStyle(eoFill: true))
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
    /// 往 Dock 里多盖几点，把 Dock 端头自己的边线和圆角盖掉（图标离边缘约 4.6pt，不会被盖到）
    var cover: CGFloat = 0

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
        let c = cover
        switch dockEdge {
        // 洞四周都往里缩 c：顶/底/端头都盖住 Dock 边缘 c 点，就算位置差一两点也不会露缝
        case .leading:  dockRect = CGRect(x: rect.minX - big, y: rect.minY + c, width: big + r - c, height: rect.height - 2 * c)
        case .trailing: dockRect = CGRect(x: rect.maxX - r + c, y: rect.minY + c, width: big + r, height: rect.height - 2 * c)
        case .top:      dockRect = CGRect(x: rect.minX + c, y: rect.minY - big, width: rect.width - 2 * c, height: big + r - c)
        case .bottom:   dockRect = CGRect(x: rect.minX + c, y: rect.maxY - r + c, width: rect.width - 2 * c, height: big + r)
        }
        // 实测 Dock 的圆角是正圆弧（半径约 13pt），不是"连续曲率"圆角；用 .continuous 会在角上露出缝
        if r > 0 { p.addRoundedRect(in: dockRect, cornerSize: CGSize(width: r, height: r), style: .circular) }
        return p
    }
}
