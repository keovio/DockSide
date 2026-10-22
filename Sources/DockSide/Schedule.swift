import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

// MARK: - 数据
struct CalendarEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var calendarName = ""
    var calendarColor = ""      // hex，如 "#4A99E9"
    /// EventKit 事件的标识；nil 表示这是本地 JSON 里的事件
    var ekEventID: String?
    /// 导入的 ICS 里的 UID，用于重复导入时去重
    var uid: String?
    /// 系统日历里这一次发生的原始开始时间（重复日程每次发生共用同一个 ekEventID，靠它定位是哪一次）
    var occurrenceStart: Date?

    // MARK: 解码（v1.4：日期容错，见规格 §5.4）

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, isAllDay, calendarName, calendarColor
        case ekEventID, uid, occurrenceStart
    }

    init(id: UUID = UUID(), title: String, start: Date, end: Date,
         isAllDay: Bool = false, calendarName: String = "", calendarColor: String = "",
         ekEventID: String? = nil, uid: String? = nil, occurrenceStart: Date? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.calendarColor = calendarColor
        self.ekEventID = ekEventID
        self.uid = uid
        self.occurrenceStart = occurrenceStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        // 日期必须能解析，否则这条算失败（交给上层统计，不再静默吞掉）
        start = try Self.decodeDate(c, .start)
        end = try Self.decodeDate(c, .end)
        isAllDay = (try? c.decode(Bool.self, forKey: .isAllDay)) ?? false
        calendarName = (try? c.decode(String.self, forKey: .calendarName)) ?? ""
        calendarColor = (try? c.decode(String.self, forKey: .calendarColor)) ?? ""
        ekEventID = try? c.decodeIfPresent(String.self, forKey: .ekEventID)
        uid = try? c.decodeIfPresent(String.self, forKey: .uid)
        occurrenceStart = try? c.decodeIfPresent(Date.self, forKey: .occurrenceStart)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        // 写出去的永远是数字时间戳（旧版本读得回来）
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(isAllDay, forKey: .isAllDay)
        try c.encode(calendarName, forKey: .calendarName)
        try c.encode(calendarColor, forKey: .calendarColor)
        try c.encodeIfPresent(ekEventID, forKey: .ekEventID)
        try c.encodeIfPresent(uid, forKey: .uid)
        try c.encodeIfPresent(occurrenceStart, forKey: .occurrenceStart)
    }

    /// 日期容错解码：数字时间戳 → ISO8601 字符串 → 常见本地格式
    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>,
                                   _ key: CodingKeys) throws -> Date {
        let sub = try c.superDecoder(forKey: key)
        let single = try sub.singleValueContainer()
        // 数字分支必须与系统默认 Codable 一致：Date 的默认编码基准是 2001-01-01
        if let t = try? single.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: t) }
        guard let s = try? single.decode(String.self) else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "日期既不是数字也不是字符串")
        }
        if let d = ScheduleDateParse.parse(s) { return d }
        throw DecodingError.dataCorruptedError(in: single, debugDescription: "无法解析的日期：\(s)")
    }

    /// 由「系统日历 ID + 这次的开始时间」算出固定的 id，每分钟刷新时列表行不会被重建
    static func stableID(_ ekID: String, _ start: Date) -> UUID {
        let d = Array(SHA256.hash(data: Data("\(ekID)|\(start.timeIntervalSince1970)".utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    var isLocal: Bool { ekEventID == nil }
    var duration: TimeInterval { max(60, end.timeIntervalSince(start)) }

    func isOngoing(_ now: Date) -> Bool { !isAllDay && start <= now && now < end }
    func isPast(_ now: Date) -> Bool { end <= now }
    func minutesUntilStart(_ now: Date) -> Int { Int(start.timeIntervalSince(now) / 60) }
    func minutesUntilEnd(_ now: Date) -> Int { Int(end.timeIntervalSince(now) / 60) }
}

/// 日期字符串解析（规格 v1.4 §5.4 容错口径）
enum ScheduleDateParse {
    /// 依次尝试：ISO8601（带/不带小数秒）→ 常见本地格式
    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // 纯数字串：按 1970 时间戳理解（十几亿量级），否则按 2001 参考时间
        if let n = Double(t) {
            if n > 946_684_800, n < 4_102_444_800 { return Date(timeIntervalSince1970: n) }
            if n > 0, n < 3_155_760_000 { return Date(timeIntervalSinceReferenceDate: n) }
        }

        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: t) { return d }

        // 无时区信息的本地时间
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
        ]
        for pat in patterns {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = pat
            if let d = df.date(from: t) { return d }
        }
        return nil
    }
}

// MARK: - 导入统计与字段校验（规格 v1.4 §5.4）

struct ImportFailure {
    let title: String
    let reason: String
}

struct ImportSummary {
    var imported = 0
    var updated = 0
    var duplicate = 0
    var failed = 0
    var fixed = 0
    var failures: [ImportFailure] = []
    var fixNotes: [String] = []
    static let detailLimit = 10

    static func += (a: inout ImportSummary, b: ImportSummary) {
        a.imported += b.imported
        a.updated += b.updated
        a.duplicate += b.duplicate
        a.failed += b.failed
        a.fixed += b.fixed
        a.failures += b.failures.prefix(max(0, detailLimit - a.failures.count))
        a.fixNotes += b.fixNotes
    }

    var isEmpty: Bool { imported == 0 && updated == 0 && duplicate == 0 && failed == 0 }
}

enum ValidateResult {
    case ok
    case rejected(String)
    case fixed(String)
}

/// 逐条字段校验（规格 v1.4 五条）
enum ScheduleValidate {
    static let earliest = DateComponents(calendar: .current, year: 2000, month: 1, day: 1).date ?? .distantPast
    static let latest   = DateComponents(calendar: .current, year: 2100, month: 1, day: 1).date ?? .distantFuture

    static func check(_ e: inout CalendarEvent) -> ValidateResult {
        // ① 标题去空格后不能为空
        let t = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .rejected("标题是空的") }
        e.title = t

        // ④ 年份范围
        guard e.start >= earliest, e.start <= latest else {
            return .rejected("开始时间不在 2000–2100 年之间（\(formatDate("yyyy-MM-dd", e.start))）")
        }
        guard e.end >= earliest, e.end <= latest else {
            return .rejected("结束时间不在 2000–2100 年之间（\(formatDate("yyyy-MM-dd", e.end))）")
        }

        // ⑤ 全天事件允许 start == end；其余事件必须 end > start
        if e.end < e.start {
            let oldEnd = formatDate("MM-dd HH:mm", e.end)
            e.end = e.start.addingTimeInterval(3600)
            return .fixed("\(e.title)：结束 \(oldEnd) 早于开始，已改为开始后 1 小时")
        }
        if !e.isAllDay && e.end == e.start {
            e.end = e.start.addingTimeInterval(3600)
            return .fixed("\(e.title)：起止时间相同，已改为 1 小时")
        }
        return .ok
    }
}

enum ScheduleAuth { case unknown, granted, denied }

/// 日程数据：EventKit 为主，本地 JSON 兜底（未授权 / 被拒时无缝降级）
final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()

    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var auth: ScheduleAuth = .unknown
    /// 可见日历（已授权时才有内容）
    @Published private(set) var calendars: [EKCalendar] = []

    private let ek = EKEventStore()
    private var refreshTimer: Timer?
    /// 当前已加载的时间窗口
    // 注意：EventKit 的查询跨度最多 4 年，不能用 distantPast/distantFuture，否则什么都查不到
    private var loadedFrom: Date = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
    private var loadedTo: Date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(22 * 86400)
    /// 一次只拉这么多天，翻周视图时按需重拉
    private let chunkDays: Double = 21

    let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockSide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedule.json")
    }()

    private init() {
        refreshAuth()
        // 推迟到下一轮：避免在 SwiftUI 渲染中途修改 @Published
        DispatchQueue.main.async { [weak self] in self?.reload() }
        startTimer()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: ek, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    // MARK: 授权

    func refreshAuth() {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            auth = s == .fullAccess ? .granted : (s == .denied || s == .restricted ? .denied : .unknown)
        } else {
            auth = s == .authorized ? .granted : (s == .denied || s == .restricted ? .denied : .unknown)
        }
    }

    func requestAccess(_ done: ((Bool) -> Void)? = nil) {
        let finish: (Bool) -> Void = { [weak self] ok in
            DispatchQueue.main.async {
                self?.refreshAuth()
                self?.reload()
                done?(ok)
            }
        }
        if #available(macOS 14.0, *) {
            ek.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            ek.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    // MARK: 读取

    /// 重载当前时间窗口的事件
    ///
    /// 【双源合并】EventKit 与本地 JSON 是「双源」，不是「二选一」：
    /// 授权后本地导入的日程必须同样可见，否则导入功能等于失效——
    /// 2026-10-22 线上事故就是这么来的：授权状态下 reload 只读 EventKit，
    /// 用户导入的 312 条永远不显示，点「清空本地数据」也看不出任何变化（看起来像没反应）。
    func reload() {
        guard auth == .granted else {
            events = loadLocal()
            return
        }
        // 订阅日历（节假日、生日）的事件也会显示，所以 chips 里也要列出来才能筛掉
        calendars = ek.calendars(for: .event).sorted { $0.title < $1.title }
        coverToday()
        loadEvents(from: loadedFrom, to: loadedTo)
    }

    /// 合并显示用：当前时间窗口内的本地 JSON 事件
    private func localEventsInWindow() -> [CalendarEvent] {
        let from = loadedFrom == .distantPast ? Date.distantPast : loadedFrom
        let to = loadedTo == .distantFuture ? Date.distantFuture : loadedTo
        return loadLocal().filter { $0.start < to && $0.end > from }
    }

    /// 确保 [from, to] 在已加载范围内，不够就重拉
    func ensureLoaded(from: Date = Date(), days: Double? = nil) {
        let d = days ?? chunkDays
        let from = Calendar.current.startOfDay(for: from)
        let to = from.addingTimeInterval(d * 86400)
        if from >= loadedFrom, to <= loadedTo { return }
        // 和已加载范围合并（Dock 旁的组件永远要有今天的数据），跨度不超过 EventKit 的 4 年上限
        loadedFrom = min(from, loadedFrom)
        loadedTo = max(to, loadedTo)
        if loadedTo.timeIntervalSince(loadedFrom) > 1400 * 86400 { loadedFrom = from; loadedTo = to }
        reload()
    }

    /// 已加载范围必须包含「昨天 ~ 3 天后」（过了午夜或周视图翻到别处时也一样）
    private func coverToday() {
        let today = Calendar.current.startOfDay(for: Date())
        let needFrom = today.addingTimeInterval(-86400), needTo = today.addingTimeInterval(4 * 86400)
        if loadedFrom > needFrom || loadedTo < needTo || loadedTo.timeIntervalSince(loadedFrom) > 1400 * 86400 {
            loadedFrom = min(loadedFrom, needFrom)
            loadedTo = max(loadedTo, today.addingTimeInterval(22 * 86400))
            if loadedTo.timeIntervalSince(loadedFrom) > 1400 * 86400 {
                loadedFrom = needFrom; loadedTo = today.addingTimeInterval(22 * 86400)
            }
        }
    }

    private func loadEvents(from: Date, to: Date) {
        guard auth == .granted, from < to else { events = []; return }
        let localOnly = localEventsInWindow()
        let pred = ek.predicateForEvents(withStart: from, end: to, calendars: nil)
        let found = ek.events(matching: pred)
        events = found.map { ev in
            let ekID = ev.eventIdentifier ?? ev.calendarItemIdentifier
            return CalendarEvent(
                id: CalendarEvent.stableID(ekID, ev.startDate),
                title: ev.title ?? "（无标题）",
                start: ev.startDate,
                end: ev.endDate,
                isAllDay: ev.isAllDay,
                calendarName: ev.calendar?.title ?? "",
                calendarColor: hexString(from: ev.calendar?.cgColor),
                ekEventID: ekID,
                occurrenceStart: ev.startDate
            )
        }
        // 双源合并：系统日历 + 本地导入的一起显示（本地事件用 ekEventID == nil 区分）
        // 去重：同一个事件如果用户既导进本地又存在系统日历里，只显示系统日历那条，
        // 避免列表里出现两条一模一样的（标题 + 开始时间相同即视为同一条）
        let ekKeys = Set(events.map { "\($0.title)|\(Int($0.start.timeIntervalSince1970))" })
        let dedupLocal = localOnly.filter {
            !ekKeys.contains("\($0.title)|\(Int($0.start.timeIntervalSince1970))")
        }
        events = (events + dedupLocal).sorted(by: eventSort)
    }

    /// 本地 JSON 源
    private func loadLocal() -> [CalendarEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let saved = try? JSONDecoder().decode([CalendarEvent].self, from: data) else {
            // 解码失败：先备份原文件，再按空数据处理。
            // 【重要】绝不能直接覆盖——曾经因为解码器读不懂 ISO8601 就写空文件，
            // 把用户导进去的数据连锅端了（2026-10-22 线上事故）。
            let stamp = formatDate("yyyyMMdd-HHmmss", Date())
            let bak = fileURL.deletingLastPathComponent()
                .appendingPathComponent("schedule.损坏备份-\(stamp).json")
            try? data.write(to: bak, options: .atomic)
            NSLog("[DockSide] schedule.json 解码失败，已备份到 %@", bak.path)
            return []
        }
        return saved.map { e in
            var v = e
            v.ekEventID = nil
            return v
        }
        .sorted(by: eventSort)
    }

    private func saveLocal(_ list: [CalendarEvent]) {
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: 写入

    /// 找到列表里这一条对应的系统日历事件；重复日程要按开始时间找到具体那一次，否则会改/删到第一次
    private func ekEvent(for e: CalendarEvent) -> EKEvent? {
        guard let id = e.ekEventID else { return nil }
        if let occ = e.occurrenceStart {
            let pred = ek.predicateForEvents(withStart: occ.addingTimeInterval(-1), end: occ.addingTimeInterval(86400), calendars: nil)
            if let hit = ek.events(matching: pred).first(where: {
                ($0.eventIdentifier ?? $0.calendarItemIdentifier) == id && abs($0.startDate.timeIntervalSince(occ)) < 1
            }) { return hit }
        }
        return ek.event(withIdentifier: id)
    }

    private func save(_ ev: EKEvent) {
        do { try ek.save(ev, span: .thisEvent, commit: true) }
        catch { ScheduleIO.notify("保存到系统日历失败：\(error.localizedDescription)") }
    }

    func add(_ event: CalendarEvent) {
        if auth == .granted {
            let ev = EKEvent(eventStore: ek)
            ev.title = event.title
            ev.startDate = event.start
            ev.endDate = event.end
            ev.isAllDay = event.isAllDay
            guard let cal = ek.defaultCalendarForNewEvents else {
                ScheduleIO.notify("系统日历里没有可写入的默认日历，请先在「日历」App 里设置")
                return
            }
            ev.calendar = cal
            save(ev)
            reload()
        } else {
            var list = loadLocal()
            list.append(event)
            saveLocal(list)
            events = list.sorted(by: eventSort)
        }
    }

    func update(_ event: CalendarEvent) {
        if let ekID = event.ekEventID, auth == .granted {
            guard ekID.isEmpty == false, let ev = ekEvent(for: event) else { return }
            ev.title = event.title
            ev.startDate = event.start
            ev.endDate = event.end
            save(ev)
            reload()
        } else {
            var list = loadLocal()
            guard let i = list.firstIndex(where: { $0.id == event.id }) else { return }
            list[i].title = event.title
            list[i].start = event.start
            list[i].end = event.end
            saveLocal(list)
            events = list.sorted(by: eventSort)
        }
    }

    func remove(_ event: CalendarEvent) {
        if let ekID = event.ekEventID, auth == .granted {
            guard ekID.isEmpty == false, let ev = ekEvent(for: event) else { return }
            do { try ek.remove(ev, span: .thisEvent, commit: true) }
            catch { ScheduleIO.notify("从系统日历删除失败：\(error.localizedDescription)") }
            reload()
        } else {
            var list = loadLocal()
            list.removeAll { $0.id == event.id }
            saveLocal(list)
            events = list.sorted(by: eventSort)
        }
    }

    // MARK: 周期刷新（每 60s，与规格 §0 一致）

    private func startTimer() {
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshAuth()
            if self.auth == .granted { self.coverToday(); self.loadEvents(from: self.loadedFrom, to: self.loadedTo) }
            else { self.events = self.loadLocal() }
            ScheduleSound.check(self.events)
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }
}

let eventSort: (CalendarEvent, CalendarEvent) -> Bool = { a, b in
    if a.isAllDay != b.isAllDay { return a.isAllDay }
    if a.start != b.start { return a.start < b.start }
    return a.calendarName < b.calendarName
}

func hexString(from cg: CGColor?) -> String {
    guard let cg, let comps = cg.components, comps.count >= 3 else { return "#8E8E93" }
    let r = Int((comps[0] * 255).rounded()), g = Int((comps[1] * 255).rounded()), b = Int((comps[2] * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .gray; return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - 筛选（日历 chips / 全天开关）

enum ScheduleFilter {
    static func selectedCalendars() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: Pref.scheduleCalendars) ?? ""
        let names = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Set(names)
    }

    static func setSelected(_ set: Set<String>) {
        UserDefaults.standard.set(set.sorted().joined(separator: ","), forKey: Pref.scheduleCalendars)
    }

    /// 应用日历筛选 + 全天开关
    static func apply(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let picked = selectedCalendars()
        let showAllDay = UserDefaults.standard.object(forKey: Pref.scheduleShowAllDay) as? Bool ?? true
        return events.filter { e in
            if !showAllDay, e.isAllDay { return false }
            if !picked.isEmpty, !e.calendarName.isEmpty, !picked.contains(e.calendarName) { return false }
            return true
        }
        .sorted(by: eventSort)
    }

    static func today(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        let from = cal.startOfDay(for: now)
        guard let to = cal.date(byAdding: .day, value: 1, to: from) else { return [] }
        return apply(events).filter { e in
            if e.isAllDay { return cal.isDate(e.start, inSameDayAs: now) || (e.start < to && e.end > from) }
            return e.start < to && e.end > from
        }
    }

    /// 周视图单列的拆分：某天要画的事件，分成「定时」和「全天」两组。
    /// 抽取出来是为了让「计数与渲染口径一致」可被测试守住（v1.4 验收 19）。
    static func splitForDay(_ events: [CalendarEvent], day: Date)
        -> (timed: [CalendarEvent], allDay: [CalendarEvent]) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let inDay = apply(events).filter { e in
            if e.isAllDay { return e.start < dayEnd && e.end > dayStart }
            return e.start < dayEnd && e.end > dayStart
        }
        return (inDay.filter { !$0.isAllDay }.sorted(by: eventSort),
                inDay.filter { $0.isAllDay }.sorted(by: eventSort))
    }

    /// 胶囊态：按设置里的预读窗口，取「正在进行的」或「最近要开始的」
    static func next(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let win = UserDefaults.standard.string(forKey: Pref.scheduleWindow) ?? "today"
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let horizon: Date
        switch win {
        case "24h": horizon = now.addingTimeInterval(86400)
        case "3d":  horizon = todayStart.addingTimeInterval(3 * 86400)
        default:    horizon = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now.addingTimeInterval(86400)
        }
        let pool = apply(events).filter { $0.end > now }
        if let ongoing = pool.first(where: { $0.isOngoing(now) }) { return ongoing }
        let timed = pool.filter { !$0.isAllDay && $0.start <= horizon }
        if let upcoming = timed.first { return upcoming }
        // 只有全天事件时，返回今日的全天事件
        return pool.first { $0.isAllDay }
    }
}

// MARK: - 提示音

enum ScheduleSound {
    static func check(_ events: [CalendarEvent]) {
        guard UserDefaults.standard.bool(forKey: Pref.scheduleSound) else { return }
        let now = Date()
        let last = UserDefaults.standard.string(forKey: Pref.scheduleLastRung) ?? ""
        for e in events where !e.isAllDay {
            let delta = e.start.timeIntervalSince(now)
            guard delta > 270, delta <= 330 else { continue }   // (4.5min, 5.5min]
            let key = e.ekEventID ?? "\(e.id)"
            if key == last { continue }
            UserDefaults.standard.set(key, forKey: Pref.scheduleLastRung)
            NSSound(named: "Tink")?.play()
            break
        }
    }
}

// MARK: - 导入 / 导出 / 表单

enum ScheduleIO {
    /// 新建（本地 JSON 直接写；已授权时写回系统日历）
    static func askNew(initialStart: Date? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let cal = Calendar.current
        var start = initialStart ?? Date()
        if initialStart == nil {
            // 默认下一个整点
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
            start = cal.date(from: comps)?.addingTimeInterval(3600) ?? Date()
        }
        askForm(title: "新建日程", event: CalendarEvent(title: "", start: start, end: start.addingTimeInterval(3600)),
                button: "添加") { ev in
            ScheduleStore.shared.add(ev)
        }
    }

    static func askEdit(_ event: CalendarEvent) {
        NSApp.activate(ignoringOtherApps: true)
        askForm(title: "编辑日程", event: event, button: "保存") { ev in
            ScheduleStore.shared.update(ev)
        }
    }

    static func askDelete(_ event: CalendarEvent) {
        if event.isLocal {
            ScheduleStore.shared.remove(event)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "从系统日历删除「\(event.title)」？"
        alert.informativeText = "这条日程来自系统日历，删除后会同步到「日历」App，且不能撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { ScheduleStore.shared.remove(event) }
    }

    /// 标题 + 开始 + 结束 的简易表单（NSAlert + accessoryView）
    private static func askForm(title: String, event: CalendarEvent, button: String,
                                commit: @escaping (CalendarEvent) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 84))
        let field = NSTextField(frame: NSRect(x: 0, y: 56, width: 300, height: 24))
        field.placeholderString = "日程标题"
        field.stringValue = event.title
        let startPicker = NSDatePicker(frame: NSRect(x: 0, y: 26, width: 146, height: 24))
        startPicker.datePickerStyle = .textFieldAndStepper
        startPicker.datePickerElements = [.yearMonthDay, .hourMinute]
        startPicker.dateValue = event.start
        let endPicker = NSDatePicker(frame: NSRect(x: 154, y: 26, width: 146, height: 24))
        endPicker.datePickerStyle = .textFieldAndStepper
        endPicker.datePickerElements = [.yearMonthDay, .hourMinute]
        endPicker.dateValue = event.end
        let hint = NSTextField(labelWithString: "开始 / 结束")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 4, width: 200, height: 16)

        box.addSubview(field); box.addSubview(startPicker); box.addSubview(endPicker); box.addSubview(hint)
        alert.accessoryView = box
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var ev = event
        ev.title = t
        ev.start = startPicker.dateValue
        ev.end = max(endPicker.dateValue, startPicker.dateValue.addingTimeInterval(60))
        commit(ev)
    }

    // MARK: 导入（ICS / JSON / 简易文本，自动识别格式）

    static func importFromFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "导入日程（.ics / .json / .txt）"
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "ics") ?? .data,
                                     .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        // 合并策略（远端 merge 语义）+ 校验与明细反馈（本地 v1.4 语义）：
        // 解析 → 字段校验 → 覆盖式合并（已有的覆盖、没有的新增）→ 明细弹窗
        var sum = ImportSummary()
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                sum.failures.append(ImportFailure(title: url.lastPathComponent, reason: "文件读不出来（编码不是 UTF-8？）"))
                sum.failed += 1
                continue
            }
            sum += ingest(text, format: ScheduleImport.format(for: url))
        }
        report(sum, prefix: "")
    }

    static func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            notify("剪贴板是空的")
            return
        }
        report(ingest(text, format: ScheduleImport.sniffText(text)), prefix: "从剪贴板")
    }

    /// 解析 → 字段校验 → 覆盖式合并（已有的覆盖、没有的新增）→ 写入。
    /// 返回可统计的结果（规格 v1.4 §5.4：失败不许静默；导入反馈含新增/覆盖条数）
    @discardableResult
    static func ingest(_ text: String, format: ScheduleImport.Format) -> ImportSummary {
        var sum = ImportSummary()
        let parsed = ScheduleImport.parse(text, format: format)

        if parsed.isEmpty {
            sum.failed = 1
            sum.failures.append(ImportFailure(
                title: "（整个文件）",
                reason: "没有解析出任何日程。json 请确认是数组格式、日期是 ISO8601 或时间戳；ics 请确认含 BEGIN:VEVENT"))
            return sum
        }

        // 字段校验（规格 v1.4 五条口径）
        var valid: [CalendarEvent] = []
        for var e in parsed {
            switch ScheduleValidate.check(&e) {
            case .ok:
                valid.append(e)
            case .rejected(let why):
                sum.failed += 1
                if sum.failures.count < ImportSummary.detailLimit {
                    sum.failures.append(ImportFailure(title: e.title, reason: why))
                }
            case .fixed(let why):
                sum.fixed += 1
                sum.fixNotes.append(why)
                valid.append(e)
            }
        }

        // 覆盖式合并：已有的覆盖、没有的新增（远端 merge 语义）
        let current = localEvents()
        let merged = ScheduleImport.merge(valid, into: current)
        sum.imported = merged.added
        sum.updated = merged.updated
        sum.duplicate = 0

        if merged.added + merged.updated > 0 {
            writeLocal(merged.list)
            UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()),
                                      forKey: Pref.scheduleLastImport)
            ScheduleStore.shared.reload()
        }
        return sum
    }

    /// 统一反馈文案 + 失败明细（规格 v1.4：0 条或失败必须弹窗）
    private static func report(_ sum: ImportSummary, prefix: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()

        let head = prefix.isEmpty ? "" : "\(prefix)导入"
        if sum.imported == 0 && sum.updated == 0 && sum.failed == 0 {
            alert.messageText = "\(head)完成：没有变化（内容和已有的完全一样）"
            alert.informativeText = "0 条新增，0 条覆盖。"
        } else {
            alert.messageText = sum.imported == 0 && sum.updated == 0 && sum.failed > 0
                ? "\(head)失败" : "\(head)完成"
            var parts: [String] = []
            if sum.imported > 0 { parts.append("新增 \(sum.imported) 条") }
            if sum.updated > 0 { parts.append("覆盖更新 \(sum.updated) 条") }
            if sum.duplicate > 0 { parts.append("跳过 \(sum.duplicate) 条重复") }
            parts.append("失败 \(sum.failed) 条")
            alert.informativeText = parts.joined(separator: "，")
            if sum.imported == 0 && sum.updated == 0 && sum.failed > 0 { alert.alertStyle = .warning }
        }

        // 明细：修正说明 + 前 10 条失败原因
        var details: [String] = []
        if sum.fixed > 0 {
            details.append("已修正 \(sum.fixed) 条结束时间早于开始时间：")
            details.append(contentsOf: sum.fixNotes.prefix(5).map { "  · \($0)" })
        }
        if !sum.failures.isEmpty {
            if !details.isEmpty { details.append("") }
            details.append("失败明细" + (sum.failed > sum.failures.count ? "（前 \(sum.failures.count) 条）" : "") + "：")
            details.append(contentsOf: sum.failures.map { "  · \($0.title.isEmpty ? "（无标题）" : $0.title)：\($0.reason)" })
        }
        if !details.isEmpty {
            let box = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 130))
            box.hasVerticalScroller = true
            box.borderType = .bezelBorder
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 130))
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 11)
            tv.string = details.joined(separator: "\n")
            box.documentView = tv
            alert.accessoryView = box
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 只读本地 JSON 文件（不经过 store，避免受授权状态影响）
    static func localEvents() -> [CalendarEvent] {
        guard let data = try? Data(contentsOf: ScheduleStore.shared.fileURL),
              let list = try? JSONDecoder().decode([CalendarEvent].self, from: data) else { return [] }
        return list
    }

    static func writeLocal(_ list: [CalendarEvent]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: ScheduleStore.shared.fileURL, options: .atomic)
        }
    }

    // MARK: 导出（JSON / ICS / Markdown）

    /// 菜单栏「导出日程…」用：先选格式，再选保存位置
    static func exportPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "导出日程"
        alert.informativeText = "JSON 用于备份还原，ICS 可以导入系统「日历」或其他日历应用，Markdown 方便直接看。"
        alert.addButton(withTitle: "ICS")
        alert.addButton(withTitle: "JSON")
        alert.addButton(withTitle: "Markdown")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  exportICS()
        case .alertSecondButtonReturn: exportJSON()
        case .alertThirdButtonReturn:  exportMarkdown()
        default: return
        }
    }

    static func exportJSON() {
        export(kind: .json)
    }

    static func exportICS() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "日程-\(formatDate("yyyy-MM-dd", Date())).ics"
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ScheduleExport.ics(mergedForExport()).write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "日程-\(formatDate("yyyy-MM-dd", Date())).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ScheduleExport.markdown(mergedForExport()).write(to: url, atomically: true, encoding: .utf8)
    }

    /// 导出用：本地 JSON + EventKit（已授权时）合并，按 start 排序
    private static func mergedForExport() -> [CalendarEvent] {
        var all = localEvents()
        if ScheduleStore.shared.auth == .granted {
            let keys = Set(all.map { ScheduleImport.dedupeKey($0) })
            all += ScheduleStore.shared.events.filter { !keys.contains(ScheduleImport.dedupeKey($0)) }
        }
        return all.sorted(by: eventSort)
    }

    private enum ExportKind { case json }

    private static func export(kind: ExportKind) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "日程-\(formatDate("yyyy-MM-dd", Date())).json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = ScheduleExport.json(mergedForExport()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 清空本地数据（EventKit 事件不受影响）
    static func clearLocal() {
        NSApp.activate(ignoringOtherApps: true)
        // 悬浮窗应用（LSUIElement / nonactivating panel）点按钮时 App 往往不在前台，
        // 只靠 activate 有时仍会弹在别的窗口后面，用户看起来就是「按了没反应」。
        // 这里强制置前再弹，并在弹之前把数量告诉用户，避免「已经是空的还弹一次」的困惑。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(.accessory) }

        let existing = localEvents()
        let alert = NSAlert()
        if existing.isEmpty {
            alert.messageText = "本地日程已经是空的"
            alert.informativeText = "DockSide 自己保存的日程文件里没有内容，不需要清空。\n系统「日历」里的日程不受影响。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        alert.messageText = "清空 \(existing.count) 条本地日程？"
        alert.informativeText = "只清空 DockSide 自己保存的本地日程，系统「日历」里的日程不受影响。\n清空前会自动备份一份，出问题能找回。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 先备份再清空（清空是不可逆操作）
        if let data = try? Data(contentsOf: ScheduleStore.shared.fileURL) {
            let stamp = formatDate("yyyyMMdd-HHmmss", Date())
            let bak = ScheduleStore.shared.fileURL.deletingLastPathComponent()
                .appendingPathComponent("schedule.清空前备份-\(stamp).json")
            try? data.write(to: bak, options: .atomic)
        }
        writeLocal([])
        ScheduleStore.shared.reload()

        let done = NSAlert()
        done.messageText = "已清空"
        done.informativeText = "本地日程已清空。原数据备份在同一个文件夹里（文件名以「schedule.清空前备份-」开头）。"
        done.addButton(withTitle: "好")
        done.runModal()
    }

    static func revealData() {
        let url = ScheduleStore.shared.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    static func notify(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    static func openCalendarSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }
}

// MARK: - Dock 旁组件（胶囊态）
struct ScheduleWidget: View {
    @ObservedObject private var store = ScheduleStore.shared
    @Environment(\.widgetFontSize) private var size
    @Environment(\.compact) private var compact
    @AppStorage(Pref.scheduleTitleChars) private var titleChars = 6
    @AppStorage(Pref.scheduleHover) private var hoverExpand = true
    @AppStorage(Pref.schedule24h) private var h24 = true
    @Environment(\.measuring) private var measuring

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
        .modifier(WidgetText())
        .contentShape(Rectangle())
        .onTapGesture { SchedulePopover.shared.toggle() }
        .onHover { inside in
            guard hoverExpand, !measuring else { return }
            if inside { SchedulePopover.shared.show() } else { SchedulePopover.shared.scheduleHide() }
        }
    }

    private func clock(_ d: Date) -> String { formatDate(h24 ? "HH:mm" : "h:mm", d) }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let today = ScheduleFilter.today(store.events, now: now)
        let upcoming = today.filter { $0.end > now }
        let ringProgress = max(0, min(1, now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 86400))
        let showAllDay = UserDefaults.standard.object(forKey: Pref.scheduleShowAllDay) as? Bool ?? true
        let pendingCount = showAllDay ? upcoming.count : upcoming.filter { !$0.isAllDay }.count
        let nextEvent = ScheduleFilter.next(store.events, now: now)

        if compact {
            VStack(spacing: size * 0.15) {
                ProgressRing(progress: ringProgress, size: size * 1.9, lineWidth: size * 0.16) {
                    Text(store.auth == .unknown ? "?" : "\(pendingCount)")
                        .font(.system(size: size * 0.75, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                }
                Text(compactLine(now: now, event: nextEvent))
                    .font(.system(size: size * 0.72, weight: .semibold, design: .rounded))
                    .opacity(0.85)
                    .minimumScaleFactor(0.7)
            }
        } else {
            HStack(spacing: size * 0.5) {
                if store.auth == .unknown {
                    // 未授权：只放文案，单击去授权
                    Text("授权日历")
                        .font(.system(size: size * 0.95, weight: .semibold, design: .rounded))
                } else if let e = nextEvent {
                    if e.isOngoing(now) {
                        Circle()
                            .fill(Color(red: 0.36, green: 0.82, blue: 0.55))
                            .frame(width: max(5, size * 0.38), height: max(5, size * 0.38))
                        Text("进行中")
                            .font(.system(size: size * 0.8, weight: .semibold, design: .rounded))
                            .opacity(0.9)
                    } else {
                        Text(leadingLabel(e, now: now))
                            .font(.system(size: size * 0.9, weight: .medium, design: .rounded))
                            .opacity(0.9)
                    }
                    Marquee(text: e.title, width: size * 0.95 * CGFloat(titleChars), fontSize: size * 0.95)
                    if let tail = trailingLabel(e, now: now) {
                        Text(tail)
                            .font(.system(size: size * 0.74))
                            .opacity(0.7)
                    }
                } else {
                    Text("暂无日程")
                        .font(.system(size: size * 0.95, weight: .semibold, design: .rounded))
                        .opacity(0.7)
                }
            }
        }
    }

    /// 时间位文案：进行中由调用方渲染，这里只处理其余情形
    private func leadingLabel(_ e: CalendarEvent, now: Date) -> String {
        if e.isAllDay { return "全天" }
        let cal = Calendar.current
        if cal.isDateInToday(e.start) { return clock(e.start) }
        if cal.isDateInTomorrow(e.start) { return "明天 " + clock(e.start) }
        return formatDate("EEE ", e.start) + clock(e.start)
    }

    /// 竖排下方那行（宽度只有 Dock 粗细，尽量短）
    private func compactLine(now: Date, event: CalendarEvent?) -> String {
        guard store.auth != .unknown else { return "—" }
        guard let e = event else { return "—" }
        if e.isAllDay { return "全天" }
        if e.isOngoing(now) { return "进行中" }
        let cal = Calendar.current
        if cal.isDateInToday(e.start) { return clock(e.start) }
        if cal.isDateInTomorrow(e.start) { return "明天" }
        return formatDate("EEE", e.start)
    }

    private func trailingLabel(_ e: CalendarEvent, now: Date) -> String? {
        if e.isOngoing(now) {
            let m = e.minutesUntilEnd(now)
            return m >= 60 ? "\(m / 60)h" : "\(max(1, m))m"
        }
        let until = e.minutesUntilStart(now)
        if until > 0, until <= 15 { return "\(until)m" }
        return nil
    }
}

// MARK: - 悬停展开（今日时间轴）
final class SchedulePopover: NSObject, NSWindowDelegate {
    static let shared = SchedulePopover()
    private var panel: KeyPanel?
    private var hideWork: DispatchWorkItem?

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? hide() : show() }

    func show() {
        cancelHide()
        guard !isShown else { return }
        let p = panel ?? makePanel()
        panel = p
        position(p)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
    }

    func cancelHide() { hideWork?.cancel() }

    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            if p.isKeyWindow { return }
            if p.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: dockSideLevel.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.delegate = self
        p.contentView = NSHostingView(rootView: SchedulePopoverView())
        return p
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let w: CGFloat = 340
        let now = Date()
        let today = ScheduleFilter.today(ScheduleStore.shared.events, now: now)
        let rows = CGFloat(min(today.count, 10))
        let h: CGFloat = min(max(120 + rows * 34, 220), 560)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let host = NSApp.windows.first { $0 !== p && $0.isVisible && $0.level == dockSideLevel && $0.frame.contains(mouse) }
        var origin: NSPoint
        if DockState.shared.vertical {
            let ref = host?.frame ?? NSRect(origin: mouse, size: .zero)
            let x = DockState.shared.dockOnLeft ? ref.maxX + 8 : ref.minX - w - 8
            origin = NSPoint(x: x, y: mouse.y - h / 2)
        } else {
            let top = host?.frame.maxY ?? (mouse.y + 20)
            origin = NSPoint(x: mouse.x - w / 2, y: top + 8)
        }
        let sf = screen.frame, vf = screen.visibleFrame
        origin.x = min(max(origin.x, sf.minX + 8), sf.maxX - w - 8)
        origin.y = min(max(origin.y, sf.minY + 8), vf.maxY - h - 8)
        p.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
    }
}

struct SchedulePopoverView: View {
    @ObservedObject private var store = ScheduleStore.shared
    @AppStorage(Pref.schedule24h) private var h24 = true
    @AppStorage(Pref.scheduleShowCalendarColor) private var showColor = true
    @AppStorage(Pref.scheduleDismissDeniedTip) private var noDeniedTip = false

    private var clockPattern: String { h24 ? "HH:mm" : "h:mm" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            body(now: ctx.date)
        }
    }

    @ViewBuilder
    private func body(now: Date) -> some View {
        let today = ScheduleFilter.today(store.events, now: now)
        let allDay = today.filter { $0.isAllDay }
        let timed = today.filter { !$0.isAllDay }
        let ongoing = today.filter { $0.isOngoing(now) }.count

        VStack(alignment: .leading, spacing: 10) {
            header(now: now, count: today.count, ongoing: ongoing)

            if store.auth == .denied, !noDeniedTip {
                deniedTip()
            }

            if !store.calendars.isEmpty, store.auth == .granted {
                chipRow()
            }

            if allDay.isEmpty && timed.isEmpty {
                emptyState(now: now)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !allDay.isEmpty {
                            Text("全天")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 4)
                            ForEach(allDay) { e in
                                ScheduleRow(event: e, now: now, showColor: showColor)
                            }
                        }
                        ForEach(timelineRows(timed, now: now), id: \.self) { row in
                            switch row {
                            case .divider:
                                nowDivider()
                            case .event(let e):
                                ScheduleRow(event: e, now: now, showColor: showColor)
                            }
                        }
                    }
                }
            }

            addBar()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffect(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            if inside { SchedulePopover.shared.cancelHide() } else { SchedulePopover.shared.scheduleHide() }
        }
    }

    // MARK: 区块

    private func header(now: Date, count: Int, ongoing: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(formatDate("M月d日 EEE", now)).font(.system(size: 16, weight: .bold))
            Text("· \(count) 项").font(.system(size: 12)).foregroundStyle(.secondary)
            if ongoing > 0 {
                Text("\(ongoing) 进行中")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.36, green: 0.82, blue: 0.55))
            }
            Spacer()
            Button {
                SchedulePopover.shared.hide()
                ScheduleWindow.show()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("打开完整日历")
        }
    }

    private func deniedTip() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("日历权限被拒，正在使用本地日程").font(.system(size: 11))
            Button("查看本地数据") { ScheduleIO.revealData() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Spacer()
            Button { noDeniedTip = true } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 日历多了会自动换行（规格 §3.2 chips 行）
    private func chipRow() -> some View {
        FlowLayout(spacing: 6) {
            chip(title: "全部", color: nil, all: true)
            ForEach(store.calendars, id: \.calendarIdentifier) { cal in
                chip(title: cal.title, color: hexString(from: cal.cgColor), all: false)
            }
        }
    }

    private func chip(title: String, color: String?, all: Bool) -> some View {
        let picked = ScheduleFilter.selectedCalendars()
        let on = all ? picked.isEmpty : picked.contains(title)
        return Button {
            var set = picked
            if all { set.removeAll() }
            else if set.contains(title) { set.remove(title) } else { set.insert(title) }
            ScheduleFilter.setSelected(set)
        } label: {
            HStack(spacing: 4) {
                if showColor, let c = color {
                    Circle().fill(Color(hex: c)).frame(width: 6, height: 6)
                }
                Text(title).font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .background(Color.white.opacity(on ? 0.16 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func emptyState(now: Date) -> some View {
        if store.auth == .unknown {
            Button("点击授权日历") {
                store.requestAccess { _ in SchedulePopover.shared.show() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)
        } else {
            Text(hasAllDayOnly(now: now) ? "今天只有全天日程" : "今天没有日程，享受空白吧")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        }
    }

    private func hasAllDayOnly(now: Date) -> Bool {
        let today = ScheduleFilter.today(store.events, now: now)
        return !today.isEmpty && today.allSatisfy { $0.isAllDay }
    }

    private func nowDivider() -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(red: 0.36, green: 0.82, blue: 0.55))
                .frame(width: 4, height: 4)
            Rectangle()
                .fill(Color(red: 0.36, green: 0.82, blue: 0.55).opacity(0.6))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
    }

    private func addBar() -> some View {
        Button {
            ScheduleIO.askNew()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                Text("添加日程…").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: 时间轴行（含「现在」分隔线）

    private enum TimelineRow: Hashable {
        case event(CalendarEvent)
        case divider
    }

    private func timelineRows(_ timed: [CalendarEvent], now: Date) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        var inserted = false
        for e in timed {
            // 「现在」线插在第一条尚未结束的事件之前（即已过事件之后）
            if !inserted, e.end > now {
                if timed.contains(where: { $0.isPast(now) }) {
                    rows.append(.divider)
                    inserted = true
                } else {
                    inserted = true
                }
            }
            rows.append(.event(e))
        }
        return rows
    }
}

struct ScheduleRow: View {
    let event: CalendarEvent
    let now: Date
    var showColor = true
    @State private var hovering = false

    var body: some View {
        let ongoing = event.isOngoing(now)
        let past = event.isPast(now)
        HStack(spacing: 8) {
            if ongoing {
                Circle()
                    .fill(Color(red: 0.36, green: 0.82, blue: 0.55))
                    .frame(width: 6, height: 6)
            }
            Text(timeText())
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)
            Text(event.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(event.title)
            Spacer(minLength: 4)
            if hovering {
                Button { ScheduleIO.askDelete(event) } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("删除")
            }
            if showColor, !event.calendarColor.isEmpty {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: event.calendarColor))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background((hovering || ongoing) ? Color.white.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .opacity(past ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { ScheduleIO.askEdit(event) }
    }

    private func timeText() -> String {
        if event.isAllDay { return "全天" }
        let cal = Calendar.current
        let h24 = UserDefaults.standard.object(forKey: Pref.schedule24h) as? Bool ?? true
        let pattern = h24 ? "HH:mm" : "h:mm"
        let s = formatDate(pattern, event.start)
        if !cal.isDate(event.start, inSameDayAs: event.end) {
            return "\(s) …"
        }
        return "\(s) – \(formatDate(pattern, event.end))"
    }
}

// MARK: - 完整窗口（周 / 日视图）
struct ScheduleWindowView: View {
    @ObservedObject private var store = ScheduleStore.shared
    @State private var anchor = Date()
    @State private var mode = 1          // 0 = 日，1 = 周
    @AppStorage(Pref.schedule24h) private var h24 = true
    @AppStorage(Pref.scheduleShowCalendarColor) private var showColor = true

    private let hourHeight: CGFloat = 34
    private let cal = Calendar.current

    private var weekStart: Date {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
        return cal.date(from: comps) ?? cal.startOfDay(for: anchor)
    }

    private var days: [Date] {
        if mode == 1 { return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) } }
        return [cal.startOfDay(for: anchor)]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    hourColumn
                    ForEach(days, id: \.self) { day in
                        dayColumn(day)
                        if day != days.last { Divider() }
                    }
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 380, minHeight: 440)
        .onAppear { store.ensureLoaded(from: weekStart, days: 21) }
        .onChange(of: anchor) { _ in store.ensureLoaded(from: weekStart, days: 21) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .help("上一\(mode == 1 ? "周" : "天")")
            Text(rangeTitle)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .help("下一\(mode == 1 ? "周" : "天")")
            Spacer()
            Picker("", selection: $mode) {
                Text("日").tag(0)
                Text("周").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { ScheduleIO.askNew(initialStart: nextWholeHour()) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("新建日程")
        }
        .padding(12)
    }

    private var rangeTitle: String {
        if mode == 1 {
            let end = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            return "\(formatDate("M月d日", weekStart)) – \(formatDate("M月d日", end))"
        }
        return formatDate("M月d日 EEEE", anchor)
    }

    private func shift(_ dir: Int) {
        let unit: Calendar.Component = mode == 1 ? .weekOfYear : .day
        if let d = cal.date(byAdding: unit, value: dir, to: anchor) { anchor = d }
    }

    private func nextWholeHour() -> Date {
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        return cal.date(from: comps)?.addingTimeInterval(3600) ?? Date()
    }

    private var hourColumn: some View {
        VStack(spacing: 0) {
            // 与列头对齐的空白
            Color.clear.frame(width: 34, height: headerHeight)
            ForEach(0..<24, id: \.self) { h in
                Text(String(format: "%02d", h))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: hourHeight, alignment: .top)
            }
        }
    }

    private let headerHeight: CGFloat = 30

    private func dayColumn(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let split = ScheduleFilter.splitForDay(store.events, day: day)
        let timed = split.timed
        let allDay = split.allDay

        return VStack(spacing: 0) {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    if isToday {
                        Circle().fill(Color(red: 0.36, green: 0.82, blue: 0.55)).frame(width: 4, height: 4)
                    }
                    Text(formatDate("EEE", day) + " " + formatDate("M/d", day))
                        .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.primary : Color.secondary)
                }
            }
            .frame(height: headerHeight, alignment: .top)

            // 全天条（规格 v1.4）：18pt 高、日历色 25%、圆角 3、11pt 单行；
            // 多条时首条整行 + 「+N」徽标；无全天事件的列不占位
            if !allDay.isEmpty {
                allDayBar(allDay, day: day)
            }

            ZStack(alignment: .topLeading) {
                // 网格
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { h in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) {
                                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
                            }
                            .id("\(day.timeIntervalSince1970)-\(h)")
                    }
                }
                // 事件块
                ForEach(timed) { e in
                    eventBlock(e, day: day)
                }
                // 空白处双击新建：按点击的纵向位置换算成对应整点
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { location in
                        let hour = max(0, min(23, Int(location.y / hourHeight)))
                        let start = cal.date(byAdding: .hour, value: hour, to: cal.startOfDay(for: day))
                            ?? cal.startOfDay(for: day)
                        ScheduleIO.askNew(initialStart: start)
                    }
                    .simultaneousGesture(TapGesture(count: 1).onEnded { })
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 周视图每列顶部的全天事件条（规格 v1.4 §4.2）
    @ViewBuilder
    private func allDayBar(_ allDay: [CalendarEvent], day: Date) -> some View {
        let first = allDay[0]
        let more = allDay.count - 1
        HStack(spacing: 2) {
            Text(first.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 18, alignment: .center)
        .background(Color(hex: first.calendarColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
        .padding(.horizontal, 1)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .help(allDay.map(\.title).joined(separator: "、"))
        .onTapGesture {
            // 点全天条进日视图（规格 v1.4）
            anchor = day
            mode = 0
        }
    }

    @ViewBuilder
    private func eventBlock(_ e: CalendarEvent, day: Date) -> some View {
        let dayStart = cal.startOfDay(for: day)
        let startInDay = max(e.start, dayStart)
        let endInDay = min(e.end, dayStart.addingTimeInterval(86400))
        let startMin = startInDay.timeIntervalSince(dayStart) / 60
        let dur = max(15, endInDay.timeIntervalSince(startInDay) / 60)
        let crossesMidnight = e.end > dayStart.addingTimeInterval(86400)

        HStack(spacing: 0) {
            if showColor {
                Rectangle()
                    .fill(Color(hex: e.calendarColor))
                    .frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(e.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                if crossesMidnight {
                    Text("≫")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(14, CGFloat(dur) / 60 * hourHeight - 1), alignment: .top)
        .background(Color(hex: e.calendarColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .offset(y: CGFloat(startMin) / 60 * hourHeight)
        .padding(.horizontal, 1)
        .help("\(e.title)  \(formatDate("HH:mm", e.start))-\(formatDate("HH:mm", e.end))")
        .onTapGesture { ScheduleIO.askEdit(e) }
        .contextMenu {
            Button("编辑…") { ScheduleIO.askEdit(e) }
            Button("删除", role: .destructive) { ScheduleIO.askDelete(e) }
        }
    }

    private var statusBar: some View {
        let inRange = store.events.filter { e in
            guard let end = cal.date(byAdding: .day, value: mode == 1 ? 7 : 1, to: days.first ?? anchor) else { return false }
            return e.start < end && e.end > (days.first ?? anchor)
        }
        let localCount = inRange.filter { $0.isLocal }.count
        return HStack(spacing: 8) {
            Text("\(inRange.count) 条\(mode == 1 ? "本周" : "今日")日程" + (localCount > 0 ? " · \(localCount) 条本地" : ""))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Menu("导出") {
                Button("JSON…") { ScheduleIO.exportJSON() }
                Button("ICS…") { ScheduleIO.exportICS() }
                Button("Markdown…") { ScheduleIO.exportMarkdown() }
            }
            .fixedSize()
            Button("导入…") { ScheduleIO.importFromFile() }.buttonStyle(.borderless)
            Button("在访达中显示数据") { ScheduleIO.revealData() }.buttonStyle(.borderless)
            Button("清空本地数据") { ScheduleIO.clearLocal() }.buttonStyle(.borderless)
        }
        .padding(12)
    }
}

enum ScheduleWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "DockSide 日程"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ScheduleWindowView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
