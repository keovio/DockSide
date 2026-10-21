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
