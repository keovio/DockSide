import SwiftUI

struct CountdownItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var date: Date
    var yearly: Bool

    /// 下一次的日子（每年重复的已过就算明年）
    func target(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var d = cal.startOfDay(for: date)
        guard yearly else { return d }
        while d < today { d = cal.date(byAdding: .year, value: 1, to: d) ?? today }
        return d
    }

    /// 正数 = 还有几天，0 = 今天，负数 = 已过几天
    func days(from now: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: target(from: now)).day ?? 0
    }
}

final class CountdownStore: ObservableObject {
    static let shared = CountdownStore()
    private let key = "countdowns"

    @Published var items: [CountdownItem] = [] { didSet { save() } }
    @Published var current = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([CountdownItem].self, from: data) {
            items = list
        }
    }

    /// 排序：还没到的按近到远，已过的放后面
    var sorted: [CountdownItem] {
        items.sorted {
            let a = $0.days(), b = $1.days()
            if (a >= 0) != (b >= 0) { return a >= 0 }
            return abs(a) < abs(b)
        }
    }

    func next() { current += 1 }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct CountdownWidget: View {
    @ObservedObject private var store = CountdownStore.shared
    @Environment(\.widgetFontSize) private var size
    @Environment(\.compact) private var compact
    @AppStorage(Pref.countdownChars) private var nameChars = 5
    @AppStorage(Pref.countdownShowName) private var showName = true
    @AppStorage(Pref.countdownShowLabel) private var showLabel = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let list = store.sorted
            Group {
                if list.isEmpty {
                    empty
                } else {
                    let item = list[store.current % list.count]
                    let d = item.days(from: ctx.date)
                    if compact {
                        VStack(spacing: 0) {
                            Text(d == 0 ? "今天" : "\(abs(d))")
                                .font(.system(size: size * 1.1, weight: .bold, design: .rounded))
                            Text(d == 0 ? "" : (d > 0 ? "天后" : "天前")).font(.system(size: size * 0.6)).opacity(0.7)
                        }
                    } else {
                        HStack(alignment: .center, spacing: size * 0.45) {
                            if showName || showLabel {
                                VStack(alignment: .leading, spacing: size * 0.05) {
                                    if showName {
                                        Marquee(text: item.name, width: size * 0.8 * CGFloat(nameChars), fontSize: size * 0.8, semibold: false)
                                            .opacity(0.8)
                                    }
                                    if showLabel {
                                        Text(d == 0 ? "就是今天" : (d > 0 ? "还有" : "已经"))
                                            .font(.system(size: size * 0.66)).opacity(0.6)
                                    }
                                }
                            }
                            if d != 0 {
                                HStack(alignment: .firstTextBaseline, spacing: size * 0.1) {
                                    Text("\(abs(d))").font(.system(size: size * 1.45, weight: .bold, design: .rounded))
                                    Text("天").font(.system(size: size * 0.75)).opacity(0.8)
                                }
                            } else {
                                Image(systemName: "party.popper.fill").font(.system(size: size * 1.2))
                            }
                        }
                    }
                }
            }
            .modifier(WidgetText())
            .contentShape(Rectangle())
            .onTapGesture {
                if list.count > 1 { withAnimation { store.next() } } else { SettingsWindow.show(SettingsPage(rawValue: "countdown") ?? .general) }
            }
            .help(list.count > 1 ? "点击切换下一个倒数日" : "打开倒数日设置")
            .contextMenu {
                Button("倒数日设置…") { SettingsWindow.show(SettingsPage(rawValue: "countdown") ?? .general) }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if compact {
            Image(systemName: "calendar.badge.plus")
        } else {
            HStack(spacing: size * 0.35) {
                Image(systemName: "calendar.badge.plus")
                Text("添加倒数日").opacity(0.7)
            }
        }
    }
}

struct CountdownPane: View {
    @ObservedObject private var store = CountdownStore.shared
    @AppStorage(Pref.countdownChars) private var nameChars = 5
    @AppStorage(Pref.countdownShowName) private var showName = true
    @AppStorage(Pref.countdownShowLabel) private var showLabel = true
    @State private var name = ""
    @State private var date = Date()
    @State private var yearly = false

    var body: some View {
        Form {
            Section("显示内容") {
                Toggle("名字", isOn: $showName)
                Toggle("「还有 / 已经」", isOn: $showLabel)
            }
            Section("添加") {
                TextField("名字（比如：生日、放假、考试）", text: $name)
                DatePicker("日期", selection: $date, displayedComponents: .date)
                Toggle("每年重复（生日、纪念日）", isOn: $yearly)
                Button("添加") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    store.items.append(CountdownItem(name: n, date: date, yearly: yearly))
                    name = ""; yearly = false
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("我的倒数日") {
                if store.items.isEmpty {
                    Text("还没有。添加后会在 Dock 旁显示最近的一个，点一下切换下一个。").foregroundStyle(.secondary)
                }
                ForEach(store.sorted) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(formatDate("yyyy年M月d日", item.target()) + (item.yearly ? " · 每年" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let d = item.days()
                        Text(d == 0 ? "今天" : (d > 0 ? "还有 \(d) 天" : "已过 \(-d) 天")).monospacedDigit()
                        Button(role: .destructive) {
                            store.items.removeAll { $0.id == item.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("显示") {
                Picker("名字宽度", selection: $nameChars) {
                    ForEach([3, 4, 5, 6, 8], id: \.self) { Text("\($0) 个字").tag($0) }
                }
                Text("名字超出宽度时会在里面滚动。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
