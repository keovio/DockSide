import AppKit
import Carbon
import SwiftUI

/// 全局快捷键能触发的操作
enum HotkeyAction: String, CaseIterable, Identifiable {
    case toggleWidgets, newTodo, showTodos, togglePomodoro, editLayout, openSettings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleWidgets: return "显示 / 隐藏组件"
        case .newTodo: return "新建待办"
        case .showTodos: return "打开待办清单"
        case .togglePomodoro: return "番茄钟 开始 / 暂停"
        case .editLayout: return "编辑布局"
        case .openSettings: return "打开设置"
        }
    }

    func perform() {
        switch self {
        case .toggleWidgets: (NSApp.delegate as? AppDelegate)?.toggleHidden()
        case .newTodo: TodoIO.askNew()
        case .showTodos: TodoWindow.show()
        case .togglePomodoro: Pomodoro.shared.toggle()
        case .editLayout: SettingsWindow.show(.layout)
        case .openSettings: SettingsWindow.show(.general)
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String
}

/// 用 Carbon RegisterEventHotKey 注册全局快捷键（不需要额外权限）
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    @Published private(set) var combos: [HotkeyAction: KeyCombo] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private let signature: OSType = 0x444B5344   // "DKSD"

    private init() {
        for a in HotkeyAction.allCases {
            if let data = UserDefaults.standard.data(forKey: "hotkey." + a.rawValue),
               let c = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                combos[a] = c
            }
        }
    }

    func start() {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec, nil, nil)
            installed = true
        }
        registerAll()
    }

    func set(_ combo: KeyCombo?, for action: HotkeyAction) {
        // 同一个组合只能给一个操作
        if let combo { for (a, c) in combos where c == combo && a != action { combos[a] = nil; save(a) } }
        combos[action] = combo
        save(action)
        registerAll()
    }

    private func save(_ a: HotkeyAction) {
        if let c = combos[a], let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: "hotkey." + a.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: "hotkey." + a.rawValue)
        }
    }

    private func registerAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        for (i, a) in HotkeyAction.allCases.enumerated() {
            guard let c = combos[a] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(i + 1))
            if RegisterEventHotKey(c.keyCode, c.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    fileprivate func fire(_ id: UInt32) {
        let all = HotkeyAction.allCases
        let i = Int(id) - 1
        guard i >= 0, i < all.count else { return }
        all[i].perform()
    }

    /// 把按键事件转换成组合；必须带 ⌘ / ⌃ / ⌥ 之一
    static func combo(from event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var text = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); text += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); text += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); text += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); text += "⌘" }
        return KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: text + keyName(event))
    }

    private static func keyName(_ e: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "空格", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let s = special[e.keyCode] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

private func hotkeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    if status == noErr {
        let id = hk.id
        DispatchQueue.main.async { HotkeyManager.shared.fire(id) }
    }
    return noErr
}

// MARK: - 设置页
struct ShortcutsPane: View {
    @ObservedObject private var manager = HotkeyManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(action: action)
                    }
                }
            } footer: {
                Text("点右边的框，然后按下想要的组合键（需要包含 ⌘、⌃ 或 ⌥）。按 ⎋ 取消，⌫ 清除。全局有效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject private var manager = HotkeyManager.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "请按下快捷键…" : (manager.combos[action]?.display ?? "点击录制"))
                    .frame(minWidth: 120)
                    .foregroundStyle(recording ? Color.accentColor : (manager.combos[action] == nil ? Color.secondary : Color.primary))
            }
            if manager.combos[action] != nil && !recording {
                Button {
                    manager.set(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: stop()                                       // Esc 取消
            case 51, 117: manager.set(nil, for: action); stop()   // Delete 清除
            default:
                if let c = HotkeyManager.combo(from: event) {
                    manager.set(c, for: action)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
