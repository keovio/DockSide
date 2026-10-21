import Foundation

enum Side: String, CaseIterable {
    case left, right
    var title: String { self == .left ? "左侧" : "右侧" }
}

/// 用户在每一侧选了哪些组件，自动保存到 UserDefaults
final class WidgetStore: ObservableObject {
    @Published var selected: [Side: [String]] = [:]

    init() {
        let d = UserDefaults.standard
        selected[.left]  = d.stringArray(forKey: "left")  ?? ["clock"]
        selected[.right] = d.stringArray(forKey: "right") ?? ["date"]
    }

    func toggle(_ id: String, on side: Side) {
        var ids = selected[side] ?? []
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        selected[side] = ids
        UserDefaults.standard.set(ids, forKey: side.rawValue)
    }
}
