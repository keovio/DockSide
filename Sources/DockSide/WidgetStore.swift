import Foundation

enum Side: String, CaseIterable {
    case left, right
    var other: Side { self == .left ? .right : .left }
}

/// 每一侧放了哪些组件、什么顺序，自动保存到 UserDefaults
final class WidgetStore: ObservableObject {
    static let shared = WidgetStore()

    @Published var selected: [Side: [String]] = [:]

    private init() {
        let d = UserDefaults.standard
        selected[.left]  = d.stringArray(forKey: "left")  ?? ["clock", "cpu", "memory"]
        selected[.right] = d.stringArray(forKey: "right") ?? ["todo"]
    }

    var active: Set<String> { Set(selected.values.flatMap { $0 }) }

    /// 放到某一侧（插到 target 前面，target 为空则放最后）；同一个组件只会出现一次
    func insert(_ id: String, into side: Side, before target: String?) {
        guard id != target else { return }
        var map = selected
        for s in Side.allCases { map[s]?.removeAll { $0 == id } }
        var ids = map[side] ?? []
        if let t = target, let i = ids.firstIndex(of: t) { ids.insert(id, at: i) } else { ids.append(id) }
        map[side] = ids
        selected = map
        save()
    }

    func remove(_ id: String) {
        var map = selected
        for s in Side.allCases { map[s]?.removeAll { $0 == id } }
        selected = map
        save()
    }

    private func save() {
        for s in Side.allCases { UserDefaults.standard.set(selected[s] ?? [], forKey: s.rawValue) }
    }
}
