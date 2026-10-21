import AppKit
import SwiftUI
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = WidgetStore.shared
    lazy var panels: [Side: NSPanel] = [
        .left:  makeSidePanel(SideView(store: store, side: .left)),
        .right: makeSidePanel(SideView(store: store, side: .right)),
    ]
    private var statusItem: NSStatusItem!
    private var hidden = false

    func applicationDidFinishLaunching(_ n: Notification) {
        Pref.register()
        TodoStore.shared.autoClear()

        // 请求辅助功能权限（用于读取 Dock 位置）
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockSide")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.layout() }
        layout()
    }

    // MARK: - 菜单栏菜单：只放常用操作，长度固定；设置都在设置窗口里
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = store.active

        // 组件快捷操作：每个启用的组件最多挂两个动作
        var quick: [NSMenuItem] = []
        if active.contains("todo") {
            quick.append(item("新建待办…", #selector(newTodo), "n"))
            quick.append(item("从剪贴板导入待办", #selector(importClipboard)))
        }
        if active.contains("pomodoro") {
            let p = Pomodoro.shared
            let title = p.running ? "暂停番茄钟" : (p.phase == .idle ? "开始番茄钟" : "继续番茄钟")
            quick.append(item(title, #selector(togglePomodoro), "p"))
        }
        if !quick.isEmpty {
            let header = NSMenuItem(title: "组件快捷操作", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for q in quick { menu.addItem(q) }
            menu.addItem(.separator())
        }

        menu.addItem(item("编辑布局…", #selector(openLayout), "l"))
        menu.addItem(item(hidden ? "显示组件" : "临时隐藏组件", #selector(toggleHidden), "h"))
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠️ 需要辅助功能权限…", #selector(openAX)))
        }
        menu.addItem(item("设置…", #selector(openSettings), ","))
        menu.addItem(item("检查更新…", #selector(checkUpdates)))
        menu.addItem(item("使用帮助", #selector(openHelp)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 DockSide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func newTodo() { TodoIO.askNew() }
    @objc private func importClipboard() { TodoIO.importFromClipboard() }
    @objc private func togglePomodoro() { Pomodoro.shared.toggle() }
    @objc private func openLayout() { SettingsWindow.show(.layout) }
    @objc private func openSettings() { SettingsWindow.show(.general) }
    @objc private func openAX() { openAccessibilitySettings() }
    @objc private func toggleHidden() { hidden.toggle(); layout() }
    @objc private func checkUpdates() {
        NSWorkspace.shared.open(URL(string: "https://github.com/keovio/DockSide/releases/latest")!)
    }
    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/keovio/DockSide#readme")!)
    }

    // MARK: - 布局：跟随 Dock 位置和方向
    func layout() {
        guard !hidden,
              let dock = DockLocator.iconsFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(dock) }) else {
            panels.values.forEach { $0.orderOut(nil) }
            TodoPopover.shared.hide()
            return
        }
        let d = UserDefaults.standard
        let s = screen.frame, vf = screen.visibleFrame
        let gap = CGFloat(d.double(forKey: Pref.dockGap))
        let vertical = dock.height > dock.width
        let state = DockState.shared
        if state.vertical != vertical { state.vertical = vertical }
        let onLeft = dock.midX < s.midX
        if state.dockOnLeft != onLeft { state.dockOnLeft = onLeft }

        if vertical {
            // Dock 在左右两侧：左组放上方，右组放下方
            place(panels[.left]!,  CGRect(x: dock.minX, y: dock.maxY + gap,
                                          width: dock.width, height: vf.maxY - dock.maxY - gap - 8))
            place(panels[.right]!, CGRect(x: dock.minX, y: s.minY + 8,
                                          width: dock.width, height: dock.minY - s.minY - gap - 8))
        } else {
            // 辅助功能给的图标区和 Dock 实际的玻璃底不完全重合：
            // 玻璃底顶部比图标区低约 9%，底部多出约 20%（按 macOS 26 实测估算），再加用户微调
            let h = dock.height
            let top = dock.maxY - h * 0.09 + CGFloat(d.double(forKey: Pref.alignTop))
            let bottom = max(s.minY, dock.minY - h * 0.2 + CGFloat(d.double(forKey: Pref.alignBottom)))
            let barH = max(20, top - bottom)
            place(panels[.left]!,  CGRect(x: s.minX + 8, y: bottom,
                                          width: dock.minX - s.minX - gap - 8, height: barH))
            place(panels[.right]!, CGRect(x: dock.maxX + gap, y: bottom,
                                          width: s.maxX - dock.maxX - gap - 8, height: barH))
        }
    }

    private func place(_ p: NSPanel, _ r: CGRect) {
        guard min(r.width, r.height) > 30, max(r.width, r.height) > 80 else { p.orderOut(nil); return }
        if p.frame != r { p.setFrame(r, display: true) }
        p.orderFrontRegardless()
    }
}
