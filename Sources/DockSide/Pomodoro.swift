import AppKit
import SwiftUI
import UserNotifications

/// 番茄钟 / 倒计时
final class Pomodoro: ObservableObject {
    static let shared = Pomodoro()

    enum Phase { case idle, focus, rest, countdown }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var running = false
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 1
    @Published private(set) var completedToday = 0
    @Published private(set) var flashUntil: Date?

    private var endDate: Date?
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
        }
    }

    var color: Color {
        switch phase {
        case .idle: return Color.white.opacity(0.85)
        case .focus: return Color(red: 1.0, green: 0.42, blue: 0.36)
        case .rest: return Color(red: 0.36, green: 0.82, blue: 0.55)
        case .countdown: return Color(red: 0.47, green: 0.67, blue: 1.0)
        }
    }

    var timeText: String {
        let secs = phase == .idle ? focusMinutes * 60 : Int(remaining.rounded(.up))
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    var progress: Double { phase == .idle ? 0 : 1 - remaining / max(total, 1) }

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

    func setPreset(focus: Int, rest: Int) {
        UserDefaults.standard.set(focus, forKey: Pref.pomoFocus)
        UserDefaults.standard.set(rest, forKey: Pref.pomoBreak)
        startFocus()
    }

    func pause() {
        guard running else { return }
        running = false
        timer?.invalidate()
        if let e = endDate { remaining = max(0, e.timeIntervalSinceNow) }
    }

    func resume() {
        guard phase != .idle else { return }
        running = true
        endDate = Date().addingTimeInterval(remaining)
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
        case .countdown, .idle: reset()
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
        .onTapGesture { pomo.toggle() }
        .contextMenu {
            Button(pomo.primaryActionTitle) { pomo.toggle() }
            if pomo.phase != .idle {
                Button("跳过") { pomo.skip() }
                Button("重置") { pomo.reset() }
            }
            Divider()
            Button("25 / 5 分钟") { pomo.setPreset(focus: 25, rest: 5) }
            Button("50 / 10 分钟") { pomo.setPreset(focus: 50, rest: 10) }
            Button("自定义倒计时…") { pomo.askCustomMinutes() }
            Divider()
            Text("今日已完成 \(pomo.completedToday) 个番茄")
        }
        .help("点击开始 / 暂停，右键更多")
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
