import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices

enum SettingsPage: String, Hashable, CaseIterable {
    case general, layout, appearance, shortcuts, clock, system, todo, pomodoro, about

    var title: String {
        switch self {
        case .general: return "通用"
        case .layout: return "布局"
        case .appearance: return "外观"
        case .shortcuts: return "快捷键"
        case .clock: return "时钟与日期"
        case .system: return "系统监控"
        case .todo: return "待办"
        case .pomodoro: return "番茄钟"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "square.grid.3x1.below.line.grid.1x2"
        case .appearance: return "paintbrush"
        case .shortcuts: return "command"
        case .clock: return "clock"
        case .system: return "cpu"
        case .todo: return "checklist"
        case .pomodoro: return "timer"
        case .about: return "info.circle"
        }
    }
}

final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage? = .general
}

/// 设置窗口：左侧边栏分区。以后加组件 = 在「组件」分区加一页
struct SettingsView: View {
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.page) {
                Section {
                    ForEach([SettingsPage.general, .layout, .appearance, .shortcuts], id: \.self) { item($0) }
                }
                Section("组件") {
                    ForEach([SettingsPage.clock, .system, .todo, .pomodoro], id: \.self) { item($0) }
                }
                Section {
                    item(.about)
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            detail
                .navigationTitle((nav.page ?? .general).title)
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    private func item(_ p: SettingsPage) -> some View {
        Label(p.title, systemImage: p.symbol).tag(p)
    }

    @ViewBuilder
    private var detail: some View {
        switch nav.page ?? .general {
        case .general: GeneralPane()
        case .layout: ScrollView { LayoutEditorView().padding(24) }
        case .appearance: AppearancePane()
        case .shortcuts: ShortcutsPane()
        case .clock: ClockPane()
        case .system: SystemPane()
        case .todo: TodoPane()
        case .pomodoro: PomodoroPane()
        case .about: AboutPane()
        }
    }
}

struct GeneralPane: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("权限") {
                HStack {
                    Label(trusted ? "辅助功能：已授权" : "辅助功能：未授权",
                          systemImage: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? Color.green : Color.orange)
                    Spacer()
                    Button("打开系统设置") { openAccessibilitySettings() }
                }
                Text("用于读取 Dock 的位置和大小。授权后无需重启。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}

struct AppearancePane: View {
    @AppStorage(Pref.style) private var style = "merged"
    @AppStorage(Pref.fontScale) private var fontScale = 1.0
    @AppStorage(Pref.alignTop) private var alignTop = 0.0
    @AppStorage(Pref.alignBottom) private var alignBottom = 0.0
    @AppStorage(Pref.dockGap) private var dockGap = 4.0
    @AppStorage(Pref.glassTint) private var glassTint = 0.38

    var body: some View {
        Form {
            Section {
                Picker("组件样式", selection: $style) {
                    Text("融进 Dock（推荐）").tag("merged")
                    Text("独立玻璃条").tag("unified")
                    Text("分开的胶囊").tag("separate")
                }
                .pickerStyle(.radioGroup)
            }
            Section("贴合 Dock") {
                HStack {
                    Text("顶边")
                    Slider(value: $alignTop, in: -15...15, step: 0.5)
                    Text(String(format: "%+.1f", alignTop)).monospacedDigit().frame(width: 44)
                }
                HStack {
                    Text("底边")
                    Slider(value: $alignBottom, in: -15...15, step: 0.5)
                    Text(String(format: "%+.1f", alignBottom)).monospacedDigit().frame(width: 44)
                }
                HStack {
                    Text("和 Dock 的间距")
                    Slider(value: $dockGap, in: 0...20, step: 1)
                    Text("\(Int(dockGap))").monospacedDigit().frame(width: 44)
                }
                HStack {
                    Text("玻璃深浅")
                    Slider(value: $glassTint, in: 0...0.6, step: 0.02)
                    Text(String(format: "%.0f%%", glassTint * 100)).monospacedDigit().frame(width: 44)
                }
                Text("位置按 Dock 图标的实际范围自动对齐；如果差一点，拖动这里微调，正数往上。间距只对独立样式有效；玻璃深浅用来对上 Dock 的颜色（融进 Dock 样式）。").font(.caption).foregroundStyle(.secondary)
                Button("恢复默认") { alignTop = 0; alignBottom = 0; dockGap = 4; glassTint = 0.38 }
            }
            Section("字号") {
                HStack {
                    Slider(value: $fontScale, in: 0.7...1.4, step: 0.05)
                    Text(abs(fontScale - 1) < 0.01 ? "自动" : String(format: "%.0f%%", fontScale * 100))
                        .monospacedDigit()
                        .frame(width: 50)
                }
                Text("默认按 Dock 粗细自动计算，这里可以整体放大或缩小。").font(.caption).foregroundStyle(.secondary)
                Button("恢复自动") { fontScale = 1 }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClockPane: View {
    @AppStorage(Pref.clockSeconds) private var seconds = true
    @AppStorage(Pref.clock24h) private var h24 = true

    var body: some View {
        Form {
            Section("时钟") {
                Toggle("显示秒", isOn: $seconds)
                Toggle("24 小时制", isOn: $h24)
            }
            Section("日期") {
                Text("横排显示「月日 星期」，竖排显示「月/日」和星期。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SystemPane: View {
    var body: some View {
        Form {
            Section("刷新频率") {
                LabeledContent("CPU", value: "每 2 秒")
                LabeledContent("内存", value: "每 5 秒")
                LabeledContent("电量", value: "每 30 秒")
            }
        }
        .formStyle(.grouped)
    }
}

struct TodoPane: View {
    @AppStorage(Pref.todoTitleChars) private var titleChars = 6
    @AppStorage(Pref.todoHover) private var hover = true
    @AppStorage(Pref.todoSound) private var sound = true
    @AppStorage(Pref.todoAutoClear) private var autoClear = true

    var body: some View {
        Form {
            Section("Dock 旁显示") {
                Picker("标题宽度", selection: $titleChars) {
                    ForEach([4, 6, 8, 10, 12], id: \.self) { Text("\($0) 个字").tag($0) }
                }
                Text("卡片宽度固定，标题更长会在里面滚动显示。").font(.caption).foregroundStyle(.secondary)
                Toggle("鼠标悬停展开清单", isOn: $hover)
            }
            Section {
                Toggle("完成时音效", isOn: $sound)
                Toggle("已完成项保留 7 天后自动清除", isOn: $autoClear)
            }
            Section("数据") {
                HStack {
                    Button("从文件导入…") { TodoIO.importFromFile() }
                    Button("从剪贴板导入") { TodoIO.importFromClipboard() }
                    Button("导出 Markdown…") { TodoIO.exportToFile() }
                }
                HStack {
                    Button("打开完整清单") { TodoWindow.show() }
                    Button("在访达中显示数据") { TodoIO.revealData() }
                    Button("清除已完成") { TodoStore.shared.clearDone() }
                }
                Text("导入支持 txt / md / csv，每行一条，认得 - [ ] 和 - [x]。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PomodoroPane: View {
    @AppStorage(Pref.pomoFocus) private var focus = 25
    @AppStorage(Pref.pomoBreak) private var rest = 5
    @AppStorage(Pref.pomoSound) private var sound = true
    @AppStorage(Pref.pomoAutoNext) private var autoNext = true
    @ObservedObject private var pomo = Pomodoro.shared

    var body: some View {
        Form {
            Section("开始") {
                HStack {
                    Button("番茄钟") { pomo.startFocus() }
                    Button("正计时") { pomo.startStopwatch() }
                    Button("自定义倒计时…") { pomo.askCustomMinutes() }
                    if pomo.phase != .idle { Button("停止") { pomo.reset() } }
                }
                Text("也可以直接点 Dock 旁的组件选择模式；运行中点一下暂停 / 继续。").font(.caption).foregroundStyle(.secondary)
            }
            Section("番茄钟时长") {
                Stepper("专注 \(focus) 分钟", value: $focus, in: 5...120, step: 5)
                Stepper("休息 \(rest) 分钟", value: $rest, in: 1...60)
            }
            Section {
                Toggle("结束时提示音", isOn: $sound)
                Toggle("自动开始下一轮", isOn: $autoNext)
            }
            Section {
                LabeledContent("今日已完成", value: "\(pomo.completedToday) 个番茄")
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("DockSide").font(.title.bold())
            Text("版本 \(version)").foregroundStyle(.secondary)
            Text("把 Dock 栏两侧的空白变成小组件").foregroundStyle(.secondary)
            Link("GitHub 项目主页", destination: URL(string: "https://github.com/keovio/DockSide")!)
            Button("复制 Dock 诊断信息") { DockDiagnostics.copyToClipboard() }
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ page: SettingsPage = .general) {
        SettingsNav.shared.page = page
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "DockSide 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
