import AppKit
import SwiftUI
import UserNotifications

/// 番茄钟 / 倒计时
final class Pomodoro: ObservableObject {
    static let shared = Pomodoro()

    enum Phase { case idle, focus, rest, countdown, stopwatch }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var running = false
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 1
    @Published private(set) var completedToday = 0
    @Published private(set) var flashUntil: Date?

    private var endDate: Date?
    private var startDate: Date?   // 正计时用
    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        if d.string(forKey: "pomoDay") == Self.today { completedToday = d.integer(forKey: "pomoCount") }
    }

    private static var today: String { formatDate("yyyy-MM-dd", Date()) }
    var focusMinutes: Int { max(1, UserDefaults.standard.integer(forKey: Pref.pomoFocus)) }
    var breakMinutes: Int { max(1, UserDefaults.standard.integer(forKey: Pref.pomoBreak)) }

    // MARK: 显示
    var label: String {
        switch phase {
        case .idle: return "番茄钟"
        case .focus: return "专注"
        case .rest: return "休息"
        case .countdown: return "倒计时"
        case .stopwatch: return "计时"
        }
    }

    var color: Color {
        switch phase {
        case .idle: return Color.primary.opacity(0.85)
        case .focus: return Color(red: 1.0, green: 0.42, blue: 0.36)
        case .rest: return Color(red: 0.36, green: 0.82, blue: 0.55)
        case .countdown: return Color(red: 0.47, green: 0.67, blue: 1.0)
        case .stopwatch: return Color(red: 0.78, green: 0.58, blue: 1.0)
        }
    }

    var timeText: String {
        let secs = phase == .idle ? focusMinutes * 60 : (phase == .stopwatch ? Int(remaining) : Int(remaining.rounded(.up)))
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    var progress: Double {
        switch phase {
        case .idle: return 0
        case .stopwatch: return remaining.truncatingRemainder(dividingBy: 60) / 60   // 每分钟转一圈
        default: return 1 - remaining / max(total, 1)
        }
    }

    var primaryActionTitle: String {
        running ? "暂停" : (phase == .idle ? "开始专注" : "继续")
    }

    // MARK: 操作
    func toggle() {
        if phase == .idle { startFocus() } else if running { pause() } else { resume() }
    }

    func startFocus() { begin(.focus, minutes: focusMinutes) }
    func startRest() { begin(.rest, minutes: breakMinutes) }
    func startCountdown(minutes: Int) { begin(.countdown, minutes: minutes) }

    /// 正计时（秒表），从 0 往上数
    func startStopwatch() {
        prepare(.stopwatch, minutes: 0)
        remaining = 0
        resume()
    }

    func setPreset(focus: Int, rest: Int) {
        UserDefaults.standard.set(focus, forKey: Pref.pomoFocus)
        UserDefaults.standard.set(rest, forKey: Pref.pomoBreak)
        startFocus()
    }

    func pause() {
        guard running else { return }
        running = false
        timer?.invalidate()
        if phase == .stopwatch, let st = startDate {
            remaining = Date().timeIntervalSince(st)
        } else if let e = endDate {
            remaining = max(0, e.timeIntervalSinceNow)
        }
    }

    func resume() {
        guard phase != .idle else { return }
        running = true
        if phase == .stopwatch {
            startDate = Date().addingTimeInterval(-remaining)
        } else {
            endDate = Date().addingTimeInterval(remaining)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func skip() { finish(notify: false) }

    func reset() {
        timer?.invalidate()
        running = false
        phase = .idle
        remaining = 0
        total = 1
    }

    func askCustomMinutes() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "自定义倒计时"
        alert.informativeText = "输入分钟数"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "10"
        alert.accessoryView = field
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn,
           let m = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), m > 0 {
            startCountdown(minutes: m)
        }
    }

    static let countdownPresets = [5, 10, 15, 25, 30, 45, 60]

    /// 在鼠标位置弹出模式菜单
    func popUpMenu() {
        let menu = NSMenu()
        if phase != .idle {
            menu.addItem(ActionItem(running ? "暂停" : "继续") { [weak self] in self?.toggle() })
            if phase == .focus || phase == .rest { menu.addItem(ActionItem("跳过这一轮") { [weak self] in self?.skip() }) }
            menu.addItem(ActionItem("停止") { [weak self] in self?.reset() })
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("番茄钟（\(focusMinutes) / \(breakMinutes) 分钟）") { [weak self] in self?.startFocus() })
        menu.addItem(ActionItem("正计时") { [weak self] in self?.startStopwatch() })
        let cd = NSMenuItem(title: "倒计时", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in Self.countdownPresets {
            sub.addItem(ActionItem("\(m) 分钟") { [weak self] in self?.startCountdown(minutes: m) })
        }
        sub.addItem(.separator())
        sub.addItem(ActionItem("自定义…") { [weak self] in self?.askCustomMinutes() })
        cd.submenu = sub
        menu.addItem(cd)
        menu.addItem(.separator())
        let count = NSMenuItem(title: "今日已完成 \(completedToday) 个番茄", action: nil, keyEquivalent: "")
        count.isEnabled = false
        menu.addItem(count)
        menu.addItem(ActionItem("番茄钟设置…") { SettingsWindow.show(.pomodoro) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: 内部
    private func begin(_ p: Phase, minutes: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        prepare(p, minutes: minutes)
        resume()
    }

    private func prepare(_ p: Phase, minutes: Int) {
        timer?.invalidate()
        running = false
        phase = p
        total = TimeInterval(minutes * 60)
        remaining = total
    }

    private func tick() {
        if phase == .stopwatch {
            if let st = startDate { remaining = Date().timeIntervalSince(st) }
            return
        }
        guard let e = endDate else { return }
        remaining = max(0, e.timeIntervalSinceNow)
        if remaining <= 0 { finish(notify: true) }
    }

    private func finish(notify: Bool) {
        timer?.invalidate()
        running = false
        let ended = phase
        if notify {
            if ended == .focus {
                completedToday += 1
                UserDefaults.standard.set(Self.today, forKey: "pomoDay")
                UserDefaults.standard.set(completedToday, forKey: "pomoCount")
            }
            alert(for: ended)
        }
        let auto = UserDefaults.standard.bool(forKey: Pref.pomoAutoNext)
        switch ended {
        case .focus: auto ? startRest() : prepare(.rest, minutes: breakMinutes)
        case .rest: auto ? startFocus() : prepare(.focus, minutes: focusMinutes)
        case .countdown, .stopwatch, .idle: reset()
        }
    }

    private func alert(for p: Phase) {
        flashUntil = Date().addingTimeInterval(5)
        if UserDefaults.standard.bool(forKey: Pref.pomoSound) { NSSound(named: "Glass")?.play() }
        let c = UNMutableNotificationContent()
        switch p {
        case .focus: c.title = "专注结束"; c.body = "休息一下吧"
        case .rest: c.title = "休息结束"; c.body = "开始下一个番茄"
        default: c.title = "倒计时结束"; c.body = "时间到了"
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Dock 旁的番茄钟组件：点击开始 / 暂停，右键更多
struct PomodoroWidget: View {
    @ObservedObject private var pomo = Pomodoro.shared
    @Environment(\.widgetFontSize) private var size
    @Environment(\.compact) private var compact

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let flashing = (pomo.flashUntil ?? .distantPast) > ctx.date
            let dim = flashing && Int(ctx.date.timeIntervalSinceReferenceDate * 3) % 2 == 0
            content.opacity(dim ? 0.3 : 1)
        }
        .modifier(WidgetText())
        .contentShape(Rectangle())
        .onTapGesture {
            // 没在跑时点一下弹出模式菜单；在跑时点一下暂停 / 继续
            if pomo.phase == .idle { pomo.popUpMenu() } else { pomo.toggle() }
        }
        .contextMenu {
            if pomo.phase != .idle {
                Button(pomo.running ? "暂停" : "继续") { pomo.toggle() }
                if pomo.phase == .focus || pomo.phase == .rest { Button("跳过这一轮") { pomo.skip() } }
                Button("停止") { pomo.reset() }
                Divider()
            }
            Button("番茄钟（\(pomo.focusMinutes) / \(pomo.breakMinutes) 分钟）") { pomo.startFocus() }
            Button("正计时") { pomo.startStopwatch() }
            Menu("倒计时") {
                ForEach(Pomodoro.countdownPresets, id: \.self) { m in
                    Button("\(m) 分钟") { pomo.startCountdown(minutes: m) }
                }
                Divider()
                Button("自定义…") { pomo.askCustomMinutes() }
            }
            Divider()
            Text("今日已完成 \(pomo.completedToday) 个番茄")
            Button("番茄钟设置…") { SettingsWindow.show(.pomodoro) }
        }
        .help("点击选择模式或暂停 / 继续，右键更多")
    }

    @ViewBuilder
    private var content: some View {
        let icon = Image(systemName: pomo.running ? "pause.fill" : "play.fill")
        if compact {
            VStack(spacing: size * 0.25) {
                ProgressRing(progress: pomo.progress, size: size * 1.7, lineWidth: size * 0.16, color: pomo.color) {
                    icon.font(.system(size: size * 0.55))
                }
                Text(pomo.timeText).font(.system(size: size * 0.72, weight: .semibold, design: .rounded))
            }
        } else {
            HStack(spacing: size * 0.5) {
                ProgressRing(progress: pomo.progress, size: size * 1.5, lineWidth: size * 0.15, color: pomo.color) {
                    icon.font(.system(size: size * 0.5))
                }
                Text(pomo.label)
                    .font(.system(size: size * 0.85, weight: .semibold, design: .rounded))
                    .foregroundStyle(pomo.color)
                Text(pomo.timeText)
                    .font(.system(size: size * 1.15, weight: .bold, design: .rounded))
            }
        }
    }
}

/// 带闭包的菜单项
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}
