import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据
struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var created = Date()
    var doneAt: Date?
}

/// 待办清单，保存在 ~/Library/Application Support/DockSide/todos.json
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem] = [] {
        didSet { save() }
    }

    let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockSide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("todos.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([TodoItem].self, from: data) {
            items = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    var pending: [TodoItem] { items.filter { !$0.done } }
    /// 未完成在前，已完成在后
    var sortedForDisplay: [TodoItem] { pending + items.filter { $0.done } }

    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(TodoItem(title: t))
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        items[i].doneAt = items[i].done ? Date() : nil
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func move(from: IndexSet, to: Int) { items.move(fromOffsets: from, toOffset: to) }
    func clearDone() { items.removeAll { $0.done } }

    /// 已完成超过 7 天的自动清除
    func autoClear() {
        guard UserDefaults.standard.bool(forKey: Pref.todoAutoClear) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let kept = items.filter { !($0.done && ($0.doneAt ?? $0.created) < cutoff) }
        if kept.count != items.count { items = kept }
    }

    /// 导入文本：每行一条，支持 Markdown 勾选框「- [ ] / - [x]」、列表符号「- * • 1.」，跳过已存在的未完成项
    @discardableResult
    func importText(_ text: String) -> Int {
        let pattern = #"^\s*(?:[-*•+]\s+)?(?:\d+[.)、]\s*)?(?:\[([ xX✓])\]\s*)?(.+?)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var existing = Set(pending.map(\.title))
        var added: [TodoItem] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let title = ns.substring(with: m.range(at: 2))
            if title.hasPrefix("#") || existing.contains(title) { continue }
            var done = false
            if m.range(at: 1).location != NSNotFound {
                done = ns.substring(with: m.range(at: 1)) != " "
            }
            existing.insert(title)
            added.append(TodoItem(title: title, done: done, doneAt: done ? Date() : nil))
        }
        items.append(contentsOf: added)
        return added.count
    }

    /// 导出为 Markdown 勾选清单（可再导入）
    func exportMarkdown() -> String {
        items.map { "- [\($0.done ? "x" : " ")] \($0.title)" }.joined(separator: "\n") + "\n"
    }
}

enum TodoSound {
    static func play() {
        if UserDefaults.standard.bool(forKey: Pref.todoSound) { NSSound(named: "Tink")?.play() }
    }
}

// MARK: - 导入 / 导出 / 新建
enum TodoIO {
    static let types: [UTType] = [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText,
                                  UTType(filenameExtension: "csv") ?? .commaSeparatedText]

    static func importFromFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "导入待办（txt / md / csv，每行一条）"
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var count = 0
        for url in panel.urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let body = url.pathExtension.lowercased() == "csv"
                    ? text.components(separatedBy: .newlines).map { $0.components(separatedBy: ",").first ?? "" }.joined(separator: "\n")
                    : text
                count += TodoStore.shared.importText(body)
            }
        }
        notify("已导入 \(count) 条待办")
    }

    static func importFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let count = TodoStore.shared.importText(text)
        notify("已从剪贴板导入 \(count) 条待办")
    }

    static func exportToFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "待办.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? TodoStore.shared.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
    }

    static func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([TodoStore.shared.fileURL])
    }

    static func askNew() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "新建待办"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "要做什么？"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { TodoStore.shared.add(field.stringValue) }
    }

    private static func notify(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

// MARK: - 超长标题滚动显示
private struct MarqueeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct Marquee: View {
    let text: String
    let maxChars: Int
    @State private var fullWidth: CGFloat = 0

    var body: some View {
        if text.count <= maxChars {
            Text(text)
        } else {
            Text(String(text.prefix(maxChars)))
                .hidden()
                .overlay(alignment: .leading) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let gap: CGFloat = 40
                        let cycle = Double(fullWidth + gap)
                        let offset = cycle > gap ? (ctx.date.timeIntervalSinceReferenceDate * 30).truncatingRemainder(dividingBy: cycle) : 0
                        HStack(spacing: gap) {
                            Text(text).fixedSize()
                            Text(text).fixedSize()
                        }
                        .offset(x: -CGFloat(offset))
                    }
                }
                .background(
                    Text(text).fixedSize().hidden()
                        .background(GeometryReader { g in
                            Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
                        })
                )
                .clipped()
                .onPreferenceChange(MarqueeWidthKey.self) { fullWidth = $0 }
        }
    }
}

// MARK: - Dock 旁的待办卡片
/// 横排：进度环 + 当前标题 + 下一条 + 完成按钮；竖排：进度环 + 剩余数量。
/// 鼠标悬停（或点击）展开清单。
struct TodoWidget: View {
    @ObservedObject private var store = TodoStore.shared
    @Environment(\.widgetFontSize) private var size
    @Environment(\.compact) private var compact
    @AppStorage(Pref.todoMaxChars) private var maxChars = 20
    @AppStorage(Pref.todoHover) private var hoverExpand = true

    var body: some View {
        let pending = store.pending
        let total = store.items.count
        let done = total - pending.count
        let progress = total == 0 ? 0 : Double(done) / Double(total)

        Group {
            if compact {
                ProgressRing(progress: progress, size: size * 1.9, lineWidth: size * 0.16) {
                    Text("\(pending.count)").font(.system(size: size * 0.75, weight: .bold, design: .rounded))
                }
            } else {
                HStack(spacing: size * 0.55) {
                    ProgressRing(progress: progress, size: size * 1.95, lineWidth: size * 0.14) {
                        Text("\(done)/\(total)").font(.system(size: size * 0.52, weight: .bold, design: .rounded)).minimumScaleFactor(0.7)
                    }
                    VStack(alignment: .leading, spacing: size * 0.08) {
                        if let first = pending.first {
                            Marquee(text: first.title, maxChars: maxChars)
                                .font(.system(size: size * 0.95, weight: .semibold, design: .rounded))
                            Text(pending.count > 1 ? "下一条 · \(short(pending[1].title, maxChars))" : "最后一条了")
                                .font(.system(size: size * 0.74))
                                .opacity(0.7)
                        } else {
                            Text("全部完成").font(.system(size: size * 0.95, weight: .semibold, design: .rounded))
                            Text(total == 0 ? "点这里添加待办" : "辛苦了")
                                .font(.system(size: size * 0.74))
                                .opacity(0.7)
                        }
                    }
                    if let first = pending.first {
                        Image(systemName: "circle")
                            .font(.system(size: size * 1.1, weight: .light))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation { store.toggle(first.id) }
                                TodoSound.play()
                            }
                            .help("完成这一条")
                    }
                }
            }
        }
        .modifier(WidgetText())
        .contentShape(Rectangle())
        .onTapGesture { TodoPopover.shared.toggle() }
        .onHover { inside in
            guard hoverExpand else { return }
            if inside { TodoPopover.shared.show() } else { TodoPopover.shared.scheduleHide() }
        }
    }

    private func short(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(max(1, n - 1))) + "…" : s
    }
}

// MARK: - 悬停展开的清单
final class TodoPopover: NSObject, NSWindowDelegate {
    static let shared = TodoPopover()
    private var panel: KeyPanel?
    private var hideWork: DispatchWorkItem?

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? hide() : show() }

    func show() {
        cancelHide()
        guard !isShown else { return }
        let p = panel ?? makePanel()
        panel = p
        position(p)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
    }

    func cancelHide() { hideWork?.cancel() }

    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            if p.isKeyWindow { return }   // 正在输入时不自动收起，点别处才收起
            if p.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: dockSideLevel.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.delegate = self
        p.contentView = NSHostingView(rootView: TodoPopoverView())
        return p
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let w: CGFloat = 340
        let rows = CGFloat(min(TodoStore.shared.items.count, 9))
        let h: CGFloat = min(max(120 + rows * 34, 170), 460)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let host = NSApp.windows.first { $0 !== p && $0.isVisible && $0.level == dockSideLevel && $0.frame.contains(mouse) }
        var origin: NSPoint
        if DockState.shared.vertical {
            let ref = host?.frame ?? NSRect(origin: mouse, size: .zero)
            let x = DockState.shared.dockOnLeft ? ref.maxX + 8 : ref.minX - w - 8
            origin = NSPoint(x: x, y: mouse.y - h / 2)
        } else {
            let top = host?.frame.maxY ?? (mouse.y + 20)
            origin = NSPoint(x: mouse.x - w / 2, y: top + 8)
        }
        let sf = screen.frame, vf = screen.visibleFrame
        origin.x = min(max(origin.x, sf.minX + 8), sf.maxX - w - 8)
        origin.y = min(max(origin.y, sf.minY + 8), vf.maxY - h - 8)
        p.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
    }
}

struct TodoPopoverView: View {
    @ObservedObject private var store = TodoStore.shared
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("待办").font(.system(size: 16, weight: .bold))
                Text("\(store.pending.count) 项未完成").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    TodoPopover.shared.hide()
                    TodoWindow.show()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help("打开完整清单")
            }
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                TextField("添加待办，回车确认", text: $newTitle)
                    .textFieldStyle(.plain)
                    .onSubmit { store.add(newTitle); newTitle = "" }
            }
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if store.items.isEmpty {
                Text("还没有待办，在上面输入一条吧").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.sortedForDisplay) { item in TodoRow(item: item) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffect(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            if inside { TodoPopover.shared.cancelHide() } else { TodoPopover.shared.scheduleHide() }
        }
    }
}

struct TodoRow: View {
    let item: TodoItem
    @ObservedObject private var store = TodoStore.shared
    @State private var hovering = false

    init(item: TodoItem) { self.item = item }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                let wasDone = item.done
                withAnimation { store.toggle(item.id) }
                if !wasDone { TodoSound.play() }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            Text(item.title)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? Color.secondary : Color.primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            if hovering {
                Button { store.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("删除")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(hovering ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}

// MARK: - 完整清单窗口（可编辑、拖动排序）
struct TodoListView: View {
    @ObservedObject private var store = TodoStore.shared
    @State private var newTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("添加待办，回车确认", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.add(newTitle); newTitle = "" }
                .padding(12)

            List {
                ForEach(store.items) { item in
                    HStack(spacing: 8) {
                        Button { store.toggle(item.id) } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        TextField("", text: Binding(get: { item.title },
                                                    set: { store.rename(item.id, to: $0) }))
                            .textFieldStyle(.plain)
                            .strikethrough(item.done)
                            .foregroundStyle(item.done ? Color.secondary : Color.primary)
                        Button { store.remove(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }

            HStack {
                Menu("导入") {
                    Button("从文件导入…") { TodoIO.importFromFile() }
                    Button("从剪贴板导入") { TodoIO.importFromClipboard() }
                }
                .fixedSize()
                Button("导出…") { TodoIO.exportToFile() }
                Spacer()
                Text("\(store.pending.count) 项未完成").foregroundStyle(.secondary)
                Button("清除已完成") { store.clearDone() }
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 440)
    }
}

enum TodoWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "DockSide 待办"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TodoListView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
