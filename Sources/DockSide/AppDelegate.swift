import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = WidgetStore()
    lazy var panels: [Side: NSPanel] = [
        .left:  makeSidePanel(SideView(store: store, side: .left)),
        .right: makeSidePanel(SideView(store: store, side: .right)),
    ]
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
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

    // MARK: 菜单栏：每次打开时重建，勾选状态保持最新
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for side in Side.allCases {
            let sub = NSMenu()
            for w in allWidgets {
                let item = NSMenuItem(title: w.name, action: #selector(toggleWidget(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [side.rawValue, w.id]
                item.state = (store.selected[side] ?? []).contains(w.id) ? .on : .off
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: side.title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "⚠️ 需要辅助功能权限…", action: #selector(openAccessibility), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 DockSide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String],
              let side = Side(rawValue: pair[0]) else { return }
        store.toggle(pair[1], on: side)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: 布局：跟随 Dock 位置
    func layout() {
        guard let dock = DockLocator.iconsFrame(), dock.width > dock.height,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(dock) }) else {
            panels.values.forEach { $0.orderOut(nil) }
            return
        }
        let gap: CGFloat = 10, s = screen.frame
        place(panels[.left]!,  CGRect(x: s.minX + gap, y: dock.minY,
                                      width: dock.minX - s.minX - gap * 2, height: dock.height))
        place(panels[.right]!, CGRect(x: dock.maxX + gap, y: dock.minY,
                                      width: s.maxX - dock.maxX - gap * 2, height: dock.height))
    }

    private func place(_ p: NSPanel, _ r: CGRect) {
        guard r.width > 80 else { p.orderOut(nil); return }
        if p.frame != r { p.setFrame(r, display: true) }
        p.orderFrontRegardless()
    }
}
