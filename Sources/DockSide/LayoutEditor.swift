import SwiftUI

/// 自动换行排布
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            widest = max(widest, x)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// 可拖动的组件标签
struct WidgetChip: View {
    let id: String

    var body: some View {
        let def = widgetDef(id)
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
            Image(systemName: def?.symbol ?? "questionmark")
            Text(def?.name ?? id)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
        .contentShape(Capsule())
        .draggable(id) {
            Text(def?.name ?? id)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.25), in: Capsule())
        }
    }
}

/// 编辑布局：拖动排序、跨侧移动、从组件库添加 / 拖回移除
struct LayoutEditorView: View {
    @ObservedObject private var store = WidgetStore.shared
    @ObservedObject private var dock = DockState.shared
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("拖动标签调整顺序，可以拖到另一侧；从组件库拖进来添加，拖回组件库移除。也可以右键操作。某一侧放不下时拖不进去。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            HStack(alignment: .top, spacing: 14) {
                zone(.left)
                Text("Dock")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 52)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 34)
                zone(.right)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("组件库").font(.headline)
                let unused = allWidgets.filter { !store.active.contains($0.id) }
                FlowLayout {
                    ForEach(unused, id: \.id) { def in
                        WidgetChip(id: def.id)
                            .contextMenu {
                                Button(title(.left).components(separatedBy: "（").first.map { "添加到\($0)" } ?? "添加到左侧") {
                                    tryInsert(def.id, into: .left, before: nil)
                                }
                                Button(title(.right).components(separatedBy: "（").first.map { "添加到\($0)" } ?? "添加到右侧") {
                                    tryInsert(def.id, into: .right, before: nil)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .overlay(alignment: .leading) {
                    if unused.isEmpty {
                        Text("全部组件都已经放上去了").foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first else { return false }
                    store.remove(id)
                    return true
                }
            }
        }
    }

    /// 放得下才放；同一侧里调整顺序不受影响
    @discardableResult
    private func tryInsert(_ id: String, into side: Side, before target: String?) -> Bool {
        let current = store.selected[side] ?? []
        if !current.contains(id) && !LayoutCapacity.shared.fits(current + [id], side: side) {
            let name = widgetDef(id)?.name ?? id
            let where_ = title(side).components(separatedBy: "（").first ?? ""
            withAnimation { warning = "\(where_)放不下「\(name)」了，先移走一个再加" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { warning = nil } }
            return false
        }
        store.insert(id, into: side, before: target)
        return true
    }

    private func title(_ side: Side) -> String {
        if dock.vertical { return side == .left ? "上方（Dock 上面）" : "下方（Dock 下面）" }
        return side == .left ? "左侧（Dock 左边）" : "右侧（Dock 右边）"
    }

    private func zone(_ side: Side) -> some View {
        let ids = store.selected[side] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text(title(side)).font(.headline)
            FlowLayout {
                ForEach(ids, id: \.self) { id in
                    WidgetChip(id: id)
                        .dropDestination(for: String.self) { items, _ in
                            guard let moving = items.first else { return false }
                            return tryInsert(moving, into: side, before: id)
                        }
                        .contextMenu {
                            Button("移到另一侧") { tryInsert(id, into: side.other, before: nil) }
                            Button("移除") { store.remove(id) }
                        }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            .overlay(alignment: .leading) {
                if ids.isEmpty { Text("拖组件到这里").foregroundStyle(.secondary).padding(.leading, 4) }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .dropDestination(for: String.self) { items, _ in
                guard let moving = items.first else { return false }
                return tryInsert(moving, into: side, before: nil)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
