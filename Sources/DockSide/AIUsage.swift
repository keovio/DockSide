import AppKit
import SwiftUI

// MARK: - AI 用量：DeepSeek 余额、智谱 GLM Coding Plan 额度
//
// DeepSeek：GET https://api.deepseek.com/user/balance（Bearer key）→ 余额。
//   官方没有查 token 用量的接口，「今日花费」= 今天第一次读到的余额 − 现在的余额（充值后重新起算）。
// GLM：GET {host}/api/monitor/usage/quota/limit（Authorization: 原始 key，不带 Bearer）
//   → TOKENS_LIMIT（unit 3 / number 5 = 5 小时窗口，unit 6 = 每周）百分比和重置时间；
//   GET {host}/api/monitor/usage/model-usage?startTime&endTime → 今日 token 数。
//   只有 Coding Plan 的 key 能查；按量付费账号查不到余额（智谱没有公开接口）。

/// API Key 存在本机 ~/Library/Application Support/DockSide/ai-keys.json（权限 600，只有自己能读）。
/// 不用钥匙串：app 每次更新签名都会变，钥匙串会反复弹窗要密码。
enum AIKeychain {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockSide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-keys.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func get(_ account: String) -> String { load()[account] ?? "" }

    static func set(_ account: String, _ value: String) {
        var dict = load()
        dict[account] = value.isEmpty ? nil : value
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct DeepSeekUsage {
    var balance: Double
    var currency: String
    var spentToday: Double
    var available: Bool
}

struct GLMUsage {
    var level: String
    var fiveHourUsed: Double          // 0~100
    var fiveHourReset: Date?
    var weeklyUsed: Double?
    var weeklyReset: Date?
    var tokensToday: Double?
}

final class AIUsageStore: ObservableObject {
    static let shared = AIUsageStore()

    @Published var deepseek: DeepSeekUsage?
    @Published var glm: GLMUsage?
    @Published var deepseekError: String?
    @Published var glmError: String?
    @Published var updated: Date?
    @Published var loading = false

    private var timer: Timer?
    private var started = false

    @Published private(set) var hasDeepSeekKey = !AIKeychain.get("deepseek").isEmpty
    @Published private(set) var hasGLMKey = !AIKeychain.get("glm").isEmpty

    func setKey(_ account: String, _ value: String) {
        AIKeychain.set(account, value)
        hasDeepSeekKey = !AIKeychain.get("deepseek").isEmpty
        hasGLMKey = !AIKeychain.get("glm").isEmpty
        if started { refresh() } else { start() }
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        reschedule()
    }

    func reschedule() {
        timer?.invalidate()
        let minutes = max(1, UserDefaults.standard.integer(forKey: Pref.aiRefreshMinutes))
        let t = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let d = UserDefaults.standard
        let dsKey = AIKeychain.get("deepseek"), glmKey = AIKeychain.get("glm")
        let wantDS = d.bool(forKey: Pref.aiShowDeepSeek) && !dsKey.isEmpty
        let wantGLM = d.bool(forKey: Pref.aiShowGLM) && !glmKey.isEmpty
        if dsKey.isEmpty { deepseek = nil; deepseekError = nil }
        if glmKey.isEmpty { glm = nil; glmError = nil }
        guard wantDS || wantGLM else { return }
        loading = true
        let region = d.string(forKey: Pref.aiGLMRegion) ?? "cn"
        Task {
            async let ds = AIUsageStore.loadDeepSeek(wantDS ? dsKey : nil)
            async let gl = AIUsageStore.loadGLM(wantGLM ? glmKey : nil, region: region)
            let (r1, r2) = await (ds, gl)
            await MainActor.run {
                switch r1 {
                case .success(let v)?: self.deepseek = v; self.deepseekError = nil
                case .failure(let e)?: self.deepseekError = AIUsageStore.describe(e)
                case nil: break
                }
                switch r2 {
                case .success(let v)?: self.glm = v; self.glmError = nil
                case .failure(let e)?: self.glmError = AIUsageStore.describe(e)
                case nil: break
                }
                self.updated = Date()
                self.loading = false
            }
        }
    }

    private static func loadDeepSeek(_ key: String?) async -> Result<DeepSeekUsage, Error>? {
        guard let key else { return nil }
        return await capture { try await fetchDeepSeek(key) }
    }

    private static func loadGLM(_ key: String?, region: String) async -> Result<GLMUsage, Error>? {
        guard let key else { return nil }
        return await capture { try await fetchGLM(key, region: region) }
    }

    private static func capture<T>(_ f: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func describe(_ e: Error) -> String {
        if let f = e as? Failure { return f.message }
        if (e as NSError).domain == NSURLErrorDomain { return "网络连不上" }
        return e.localizedDescription
    }

    private static func get(_ url: URL, auth: String) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw Failure(message: "API Key 无效") }
        guard (200..<300).contains(code) else { throw Failure(message: "服务返回 \(code)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "返回格式看不懂")
        }
        return obj
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: DeepSeek

    static func fetchDeepSeek(_ key: String) async throws -> DeepSeekUsage {
        let obj = try await get(URL(string: "https://api.deepseek.com/user/balance")!, auth: "Bearer \(key)")
        guard let infos = obj["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            throw Failure(message: "没读到余额")
        }
        let info = infos.first { ($0["currency"] as? String) == "CNY" } ?? infos[0]
        let currency = info["currency"] as? String ?? "CNY"
        let balance = num(info["total_balance"]) ?? 0
        let spent = spentToday(balance: balance, currency: currency)
        return DeepSeekUsage(balance: balance, currency: currency, spentToday: spent,
                             available: obj["is_available"] as? Bool ?? true)
    }

    /// 今天第一次读到的余额作为起点；余额比起点高（充值了）就把起点挪上去
    private static func spentToday(balance: Double, currency: String) -> Double {
        let d = UserDefaults.standard
        let today = formatDate("yyyy-MM-dd", Date()) + currency
        var start = balance
        if d.string(forKey: Pref.aiDSDay) == today {
            start = max(d.double(forKey: Pref.aiDSDayStart), balance)
        }
        d.set(today, forKey: Pref.aiDSDay)
        d.set(start, forKey: Pref.aiDSDayStart)
        return max(0, start - balance)
    }

    // MARK: GLM

    static func fetchGLM(_ key: String, region: String) async throws -> GLMUsage {
        let host = region == "intl" ? "https://api.z.ai" : "https://open.bigmodel.cn"
        let quota = try await get(URL(string: host + "/api/monitor/usage/quota/limit")!, auth: key)
        if let ok = quota["success"] as? Bool, !ok {
            throw Failure(message: (quota["msg"] as? String) ?? "查不到额度（需要 Coding Plan 的 Key）")
        }
        guard let data = quota["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]] else {
            throw Failure(message: "查不到额度（需要 Coding Plan 的 Key）")
        }
        let tokenRows = limits.filter { ($0["type"] as? String) == "TOKENS_LIMIT" }
        func isFiveHour(_ r: [String: Any]) -> Bool { num(r["unit"]) == 3 }
        func isWeekly(_ r: [String: Any]) -> Bool { num(r["unit"]) == 6 }
        guard let five = tokenRows.first(where: isFiveHour) ?? tokenRows.first else {
            throw Failure(message: "没有 token 额度数据")
        }
        let weekly = tokenRows.first(where: isWeekly)
        func date(_ v: Any?) -> Date? { num(v).map { Date(timeIntervalSince1970: $0 / 1000) } }

        var usage = GLMUsage(level: (data["level"] as? String) ?? "",
                             fiveHourUsed: num(five["percentage"]) ?? 0,
                             fiveHourReset: date(five["nextResetTime"]),
                             weeklyUsed: weekly.flatMap { num($0["percentage"]) },
                             weeklyReset: weekly.flatMap { date($0["nextResetTime"]) })

        // 今日 token：今天 00:00:00 ~ 当前小时 59:59（失败不影响额度显示）
        let now = Date()
        let fmt = "yyyy-MM-dd HH:mm:ss"
        let start = formatDate(fmt, Calendar.current.startOfDay(for: now))
        let end = formatDate("yyyy-MM-dd HH", now) + ":59:59"
        var comps = URLComponents(string: host + "/api/monitor/usage/model-usage")!
        comps.queryItems = [URLQueryItem(name: "startTime", value: start), URLQueryItem(name: "endTime", value: end)]
        if let url = comps.url, let m = try? await get(url, auth: key),
           let md = m["data"] as? [String: Any] {
            if let total = md["totalUsage"] as? [String: Any], let t = num(total["totalTokensUsage"]) {
                usage.tokensToday = t
            } else if let hourly = md["tokensUsage"] as? [Any] {
                usage.tokensToday = hourly.compactMap { num($0) }.reduce(0, +)
            }
        }
        return usage
    }
}

/// 1234 → 1.2K，3_400_000 → 3.4M
func shortTokens(_ v: Double) -> String {
    switch v {
    case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
    case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
    case 1_000...: return String(format: "%.1fK", v / 1_000)
    default: return String(Int(v))
    }
}

func money(_ v: Double, _ currency: String) -> String {
    (currency == "USD" ? "$" : "¥") + String(format: "%.2f", v)
}

// MARK: - 组件

struct AIUsageWidget: View {
    @ObservedObject private var store = AIUsageStore.shared
    @Environment(\.widgetFontSize) private var size
    @Environment(\.compact) private var compact
    @Environment(\.measuring) private var measuring
    @AppStorage(Pref.aiShowDeepSeek) private var showDS = true
    @AppStorage(Pref.aiShowGLM) private var showGLM = true
    @AppStorage(Pref.aiShowToday) private var showToday = true
    @Environment(\.widgetInk) private var ink

    private var items: [Item] {
        var list: [Item] = []
        if showDS, store.hasDeepSeekKey { list.append(dsItem) }
        if showGLM, store.hasGLMKey { list.append(glmItem) }
        return list
    }

    private struct Item: Identifiable {
        let id: String
        let name: String
        let main: String
        let sub: String?
        let warn: Bool
        let ring: Double?      // GLM 剩余比例
    }

    private var dsItem: Item {
        if let v = store.deepseek {
            return Item(id: "ds", name: "DeepSeek", main: money(v.balance, v.currency),
                        sub: "今日 " + money(v.spentToday, v.currency),
                        warn: !v.available || v.balance < 5, ring: nil)
        }
        return Item(id: "ds", name: "DeepSeek", main: store.deepseekError == nil ? "…" : "—",
                    sub: store.deepseekError, warn: store.deepseekError != nil, ring: nil)
    }

    private var glmItem: Item {
        if let v = store.glm {
            let left = max(0, 100 - v.fiveHourUsed)
            return Item(id: "glm", name: "GLM", main: "剩 \(Int(left.rounded()))%",
                        sub: v.tokensToday.map { "今日 " + shortTokens($0) },
                        warn: left < 15, ring: left / 100)
        }
        return Item(id: "glm", name: "GLM", main: store.glmError == nil ? "…" : "—",
                    sub: store.glmError, warn: store.glmError != nil, ring: nil)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                HStack(spacing: size * 0.35) {
                    Image(systemName: "gauge")
                    if !compact { Text("设置 AI 用量").opacity(0.7) }
                }
            } else if compact {
                VStack(spacing: size * 0.25) {
                    ForEach(items) { it in
                        VStack(spacing: 0) {
                            Text(it.id == "ds" ? "DS" : "GLM").font(.system(size: size * 0.55)).opacity(0.6)
                            Text(compactValue(it))
                                .font(.system(size: size * 0.72, weight: .semibold, design: .rounded))
                                .foregroundStyle(it.warn ? Color.orange : ink)
                        }
                    }
                }
            } else {
                HStack(spacing: size * 0.8) {
                    ForEach(items) { it in row(it) }
                }
            }
        }
        .modifier(WidgetText())
        .contentShape(Rectangle())
        .onTapGesture {
            if items.isEmpty { SettingsWindow.show(.aiusage) } else { store.refresh() }
        }
        .help(helpText)
        .contextMenu {
            Button("立即刷新") { store.refresh() }
            Button("AI 用量设置…") { SettingsWindow.show(.aiusage) }
        }
        .onAppear { if !measuring { store.start() } }
    }

    private func compactValue(_ it: Item) -> String {
        if it.id == "ds", let v = store.deepseek { return String(format: "%.0f", v.balance) }
        if it.id == "glm", let v = store.glm { return "\(Int(max(0, 100 - v.fiveHourUsed).rounded()))%" }
        return "—"
    }

    @ViewBuilder
    private func row(_ it: Item) -> some View {
        HStack(spacing: size * 0.4) {
            if let r = it.ring {
                ProgressRing(progress: r, size: size * 1.5, lineWidth: size * 0.15,
                             color: it.warn ? .orange : Color(red: 0.36, green: 0.82, blue: 0.55)) {
                    EmptyView()
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(showToday && it.sub != nil ? "\(it.name) · \(it.sub!)" : it.name)
                    .font(.system(size: size * 0.62))
                    .opacity(0.65)
                Text(it.main)
                    .font(.system(size: size * 0.95, weight: .semibold, design: .rounded))
                    .foregroundStyle(it.warn ? Color.orange : ink)
            }
        }
    }

    private var helpText: String {
        var lines: [String] = []
        if let v = store.deepseek {
            lines.append("DeepSeek 余额 \(money(v.balance, v.currency))，今日约花 \(money(v.spentToday, v.currency))")
        } else if let e = store.deepseekError { lines.append("DeepSeek：\(e)") }
        if let v = store.glm {
            var s = "GLM 5 小时额度已用 \(Int(v.fiveHourUsed))%"
            if let r = v.fiveHourReset { s += "，\(formatDate("HH:mm", r)) 重置" }
            if let w = v.weeklyUsed { s += "；本周已用 \(Int(w))%" }
            if let t = v.tokensToday { s += "；今日 \(shortTokens(t)) tokens" }
            lines.append(s)
        } else if let e = store.glmError { lines.append("GLM：\(e)") }
        if let u = store.updated { lines.append("更新于 \(formatDate("HH:mm", u))，点一下刷新") }
        return lines.isEmpty ? "点一下设置 API Key" : lines.joined(separator: "\n")
    }
}

// MARK: - 设置页

struct AIUsagePane: View {
    @ObservedObject private var store = AIUsageStore.shared
    @AppStorage(Pref.aiShowDeepSeek) private var showDS = true
    @AppStorage(Pref.aiShowGLM) private var showGLM = true
    @AppStorage(Pref.aiShowToday) private var showToday = true
    @AppStorage(Pref.aiGLMRegion) private var region = "cn"
    @AppStorage(Pref.aiRefreshMinutes) private var minutes = 5
    @State private var dsKey = ""
    @State private var glmKey = ""

    var body: some View {
        Form {
            Section("DeepSeek") {
                Toggle("在 Dock 旁显示", isOn: $showDS)
                keyRow(saved: store.hasDeepSeekKey, text: $dsKey, account: "deepseek", placeholder: "sk-…")
                status(store.deepseek.map { "余额 \(money($0.balance, $0.currency))，今日约花 \(money($0.spentToday, $0.currency))" },
                       error: store.deepseekError)
                Text("DeepSeek 只提供余额接口，查不到 token 数。「今日花费」按今天余额的减少量估算，充值后重新算。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("智谱 GLM") {
                Toggle("在 Dock 旁显示", isOn: $showGLM)
                Picker("账号所在", selection: $region) {
                    Text("国内（bigmodel.cn）").tag("cn")
                    Text("国际（z.ai）").tag("intl")
                }
                keyRow(saved: store.hasGLMKey, text: $glmKey, account: "glm", placeholder: "API Key")
                status(store.glm.map { v in
                    var s = "5 小时额度剩 \(Int(max(0, 100 - v.fiveHourUsed)))%"
                    if let w = v.weeklyUsed { s += "，本周剩 \(Int(max(0, 100 - w)))%" }
                    if let t = v.tokensToday { s += "，今日 \(shortTokens(t)) tokens" }
                    return s
                }, error: store.glmError)
                Text("需要 GLM Coding Plan 的 Key：显示 5 小时额度剩余和今日 token 数。按量付费账号智谱没有开放余额接口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("显示") {
                Toggle("显示今日用量（今日花费 / 今日 token）", isOn: $showToday)
                Picker("刷新间隔", selection: $minutes) {
                    ForEach([1, 5, 15, 30], id: \.self) { Text("\($0) 分钟").tag($0) }
                }
                .onChange(of: minutes) { _ in store.reschedule() }
                HStack {
                    Button("立即刷新") { store.refresh() }
                    if store.loading { ProgressView().controlSize(.small) }
                    if let u = store.updated {
                        Text("更新于 \(formatDate("HH:mm:ss", u))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("API Key 只保存在这台 Mac 上。点 Dock 旁的组件也会刷新，鼠标停留可看详情。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: region) { _ in store.refresh() }
    }

    @ViewBuilder
    private func keyRow(saved: Bool, text: Binding<String>, account: String, placeholder: String) -> some View {
        if saved {
            HStack {
                Label("API Key 已保存", systemImage: "key.fill").foregroundStyle(.secondary)
                Spacer()
                Button("删除") { store.setKey(account, "") }
            }
        } else {
            HStack {
                SecureField(placeholder, text: text)
                Button("保存") {
                    let v = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    store.setKey(account, v)
                    text.wrappedValue = ""
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func status(_ ok: String?, error: String?) -> some View {
        if let e = error {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if let s = ok {
            Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}
