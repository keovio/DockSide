import AppKit
import SwiftUI
import ApplicationServices

/// 用辅助功能 API 读取 Dock 图标区的真实位置（Cocoa 坐标，左下原点）
enum DockLocator {
    static func iconsFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first(where: { role(of: $0) == kAXListRole }) else { return nil }

        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sizeRef)
        guard let p = posRef, let s = sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)

        // AX 坐标原点在主屏左上角，转换为 Cocoa 左下角
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: primaryH - pos.y - size.height, width: size.width, height: size.height)
    }

    private static func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return v as? String
    }
}

let dockSideLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

/// Dock 两侧的透明悬浮窗
func makeSidePanel<V: View>(_ view: V) -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = dockSideLevel
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    p.contentView = NSHostingView(rootView: view)
    return p
}

/// 可以接收键盘输入的无边框面板（待办弹出层用）
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 毛玻璃背景
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

// MARK: - 诊断：把系统能拿到的 Dock 几何信息全部列出来，用来精确对齐
enum DockDiagnostics {
    static func report() -> String {
        var out: [String] = []
        func r(_ v: CGRect) -> String { String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", v.minX, v.minY, v.width, v.height) }

        for (i, s) in NSScreen.screens.enumerated() {
            out.append("screen\(i) frame \(r(s.frame)) visible \(r(s.visibleFrame)) scale \(s.backingScaleFactor)")
        }
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        out.append("dock prefs: orientation=\(dockDefaults?.string(forKey: "orientation") ?? "-") tilesize=\(dockDefaults?.object(forKey: "tilesize") ?? "-") magnification=\(dockDefaults?.object(forKey: "magnification") ?? "-") autohide=\(dockDefaults?.object(forKey: "autohide") ?? "-")")
        out.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // 辅助功能：Dock 的所有顶层元素和图标
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
            for el in (children as? [AXUIElement]) ?? [] {
                out.append("AX \(attr(el, kAXRoleAttribute) ?? "?") \(axFrame(el).map(r) ?? "-")")
                var items: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &items)
                let list = (items as? [AXUIElement]) ?? []
                for (j, it) in list.enumerated() where j < 2 || j >= list.count - 2 {
                    out.append("   item\(j) \(attr(it, kAXSubroleAttribute) ?? "") \(attr(it, kAXTitleAttribute) ?? "") \(axFrame(it).map(r) ?? "-")")
                }
                out.append("   (\(list.count) items)")
            }
        } else {
            out.append("Dock 进程未找到")
        }

        // 窗口服务器：Dock 进程拥有的窗口
        if let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for w in infos where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
                let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                out.append(String(format: "CGWindow layer=%@ name=%@ onscreen=%@ alpha=%@ x=%.1f y=%.1f w=%.1f h=%.1f",
                                  "\(w[kCGWindowLayer as String] ?? "-")", "\(w[kCGWindowName as String] ?? "")",
                                  "\(w[kCGWindowIsOnscreen as String] ?? "-")", "\(w[kCGWindowAlpha as String] ?? "-")",
                                  b["X"] ?? -1, b["Y"] ?? -1, b["Width"] ?? -1, b["Height"] ?? -1))
            }
        }
        if let f = DockLocator.iconsFrame() { out.append("iconsFrame(cocoa) \(r(f))") }
        return out.joined(separator: "\n")
    }

    private static func attr(_ el: AXUIElement, _ key: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, key as CFString, &v)
        return v as? String
    }

    /// AX 原始坐标（左上原点）
    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Dock 诊断信息已复制"
        a.informativeText = "直接粘贴发过来就行。"
        a.runModal()
    }
}
