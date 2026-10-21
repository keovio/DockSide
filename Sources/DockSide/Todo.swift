import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据
struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var created = Date()
}

/// 待办清单，保存在 ~/Library/Application Support/DockSide/todos.json
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem] = [] {
        didSet { save() }
    }

    private let fileURL: URL = {
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

    func add(_ title: String, done: Bool = false) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(TodoItem(title: t, done: done))
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func move(from: IndexSet, to: Int) { items.move(fromOffsets: from, toOffset: to) }
    func clearDone() { items.removeAll { $0.done } }

    /// 导入文本：每行一条，支持 Markdown 勾选框「- [ ] / - [x]」、列表符号「- * • 1.」，跳过已存在的未完成项
    @discardableResult
    func importText(_ text: String) -> Int {
        let pattern = #"^\s*(?:[-*•+]\s+)?(?:\d+[.)、]\s*)?(?:\[([ xX✓])\]\s*)?(.+?)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let existing = Set(pending.map(\.title))
        var added: [TodoItem] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let title = ns.substring(with: m.range(at: 2))
            if title.hasPrefix("#") || existing.contains(title) { continue }   // 跳过 Markdown 标题和重复项
            var done = false
            if m.range(at: 1).location != NSNotFound {
                done = ns.substring(with: m.range(at: 1)) != " "
            }
            added.append(TodoItem(title: title, done: done))
        }
        items.append(contentsOf: added)
        return added.count
    }

    /// 导出为 Markdown 勾选清单（可再导入）
    func exportMarkdown() -> String {
        items.map { "- [\($0.done ? "x" : " ")] \($0.title)" }.joined(separator: "\n") + "\n"
    }
}

// MARK: - 导入 / 导出
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
                // CSV 只取每行第一列
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

    private static func notify(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

// MARK: - Dock 旁的待办胶囊：点圆圈完成当前项，点文字打开清单
struct TodoWidget: View {
    @ObservedObject private var store = TodoStore.shared
    @Environment(\.widgetFontSize) private var size

    var body: some View {
        let pending = store.pending
        let next = pending.first
        HStack(spacing: size * 0.4) {
            Image(systemName: next == nil ? "checkmark.circle.fill" : "circle")
                .onTapGesture { if let n = next { withAnimation { store.toggle(n.id) } } }
            Text(short(next?.title ?? "全部完成"))
            if pending.count > 1 {
                Text("+\(pending.count - 1)").opacity(0.6)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { TodoWindow.show() }
        .modifier(PillStyle())
        .help(next?.title ?? "")
    }

    private func short(_ s: String) -> String {
        s.count > 14 ? String(s.prefix(13)) + "…" : s
    }
}

// MARK: - 待办清单窗口
struct TodoListView: View {
    @ObservedObject var store = TodoStore.shared
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
                                .foregroundStyle(item.done ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        TextField("", text: Binding(get: { item.title },
                                                    set: { store.rename(item.id, to: $0) }))
                            .textFieldStyle(.plain)
                            .strikethrough(item.done)
                            .foregroundStyle(item.done ? .secondary : .primary)
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
