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
        HotkeyManager.shared.start()

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
        menu.addItem(item("复制 Dock 诊断信息", #selector(copyDiag)))
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
    @objc func toggleHidden() { hidden.toggle(); layout() }
    @objc private func checkUpdates() {
        NSWorkspace.shared.open(URL(string: "https://github.com/keovio/DockSide/releases/latest")!)
    }
    @objc private func copyDiag() { DockDiagnostics.copyToClipboard() }
    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/keovio/DockSide#readme")!)
    }

    // MARK: - 布局：跟随 Dock 位置和方向
    func layout() {
        guard !hidden,
              let bg = DockLocator.backgroundFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(bg) }) else {
            panels.values.forEach { $0.orderOut(nil) }
            TodoPopover.shared.hide()
            return
        }
        let d = UserDefaults.standard
        let s = screen.frame, vf = screen.visibleFrame
        let merged = d.string(forKey: Pref.style) == "merged"
        let gap = merged ? 0 : CGFloat(d.double(forKey: Pref.dockGap))
        let vertical = bg.height > bg.width
        let thickness = vertical ? bg.width : bg.height
        let r = (thickness * 0.206).rounded()   // 实测：64pt 厚的 Dock 圆角半径约 13.2pt
        let overlap = merged ? r : 0          // 融进 Dock 时盖住 Dock 端头的圆角那一段

        let state = DockState.shared
        if state.vertical != vertical { state.vertical = vertical }
        let onLeft = bg.midX < s.midX
        if state.dockOnLeft != onLeft { state.dockOnLeft = onLeft }
        if state.radius != r { state.radius = r }

        if vertical {
            let x = bg.minX + CGFloat(d.double(forKey: Pref.alignBottom))
            let w = bg.width + CGFloat(d.double(forKey: Pref.alignTop) - d.double(forKey: Pref.alignBottom))
            // Dock 在左右两侧：左组放上方，右组放下方
            let aboveY = bg.maxY + gap - overlap
            place(panels[.left]!,  CGRect(x: x, y: aboveY, width: w, height: vf.maxY - 8 - aboveY))
            let belowTop = bg.minY - gap + overlap
            place(panels[.right]!, CGRect(x: x, y: s.minY + 8, width: w, height: belowTop - s.minY - 8))
        } else {
            let y = bg.minY + CGFloat(d.double(forKey: Pref.alignBottom))
            let h = bg.height + CGFloat(d.double(forKey: Pref.alignTop) - d.double(forKey: Pref.alignBottom))
            let leftEnd = bg.minX - gap + overlap
            place(panels[.left]!,  CGRect(x: s.minX + 8, y: y, width: leftEnd - s.minX - 8, height: h))
            let rightStart = bg.maxX + gap - overlap
            place(panels[.right]!, CGRect(x: rightStart, y: y, width: s.maxX - 8 - rightStart, height: h))
        }
    }

    private func place(_ p: NSPanel, _ r: CGRect) {
        guard min(r.width, r.height) > 30, max(r.width, r.height) > 80 else { p.orderOut(nil); return }
        if p.frame != r { p.setFrame(r, display: true) }
        p.orderFrontRegardless()
    }
}
