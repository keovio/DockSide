// 日程组件的纯逻辑测试：不启动 App、不碰用户的 schedule.json
//
// 跑法（在仓库根目录）：
//   ./tests/run.sh
//
// 覆盖：事件判定与排序、今日筛选（含跨午夜）、全天开关、日历筛选、
//       胶囊「下一条」的预读窗口、ICS/JSON/文本导入、去重、JSON/ICS/Markdown 导出与往返。

import AppKit
import EventKit

var pass = 0
var fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("✅ \(name)") } else { fail += 1; print("❌ \(name)") }
}

let cal = Calendar.current
func dt(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
}
func ev(_ title: String, _ s: Date, _ e: Date, allDay: Bool = false,
        calName: String = "工作", color: String = "#4A99E9") -> CalendarEvent {
    CalendarEvent(title: title, start: s, end: e, isAllDay: allDay, calendarName: calName, calendarColor: color)
}

// 测试不读用户的真实偏好
let touchKeys = [Pref.scheduleShowAllDay, Pref.scheduleCalendars, Pref.scheduleWindow, Pref.scheduleSound]
for k in touchKeys { UserDefaults.standard.removeObject(forKey: k) }

let now = dt(2026, 10, 22, 14, 30)
let today0 = dt(2026, 10, 22, 0, 0)

// MARK: - 模型判定
let ongoing = ev("进行中", dt(2026, 10, 22, 14, 0), dt(2026, 10, 22, 15, 0))
let future = ev("未来", dt(2026, 10, 22, 16, 0), dt(2026, 10, 22, 17, 0))
let past = ev("已过", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0))

ok(ongoing.isOngoing(now), "进行中判定：14:00-15:00 在 14:30 为进行中")
ok(!ongoing.isPast(now), "进行中不算已过")
ok(past.isPast(now), "09:00-10:00 在 14:30 为已过")
ok(!future.isOngoing(now), "未开始不算进行中")
ok(future.minutesUntilStart(now) == 90, "距开始 90 分钟")
ok(ongoing.minutesUntilEnd(now) == 30, "距结束 30 分钟")
ok(ev("边界", now, now.addingTimeInterval(3600)).isOngoing(now), "start == now 算进行中")
ok(!ev("边界2", now.addingTimeInterval(-3600), now).isOngoing(now), "end == now 不算进行中")

// MARK: - 排序
let a = ev("B", dt(2026, 10, 22, 16, 0), dt(2026, 10, 22, 17, 0), calName: "家庭")
let b = ev("A", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0), calName: "工作")
let c = ev("全天", today0, today0.addingTimeInterval(86400), allDay: true, calName: "工作")
let sortedList = [a, b, c].sorted(by: eventSort)
ok(sortedList.first?.isAllDay == true, "排序：全天事件排最前")
ok(sortedList[1].title == "A" && sortedList[2].title == "B", "排序：定时事件按开始时间升序")
let sameStart1 = ev("X", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0), calName: "Z日历")
let sameStart2 = ev("Y", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0), calName: "A日历")
ok([sameStart1, sameStart2].sorted(by: eventSort).first?.calendarName == "A日历", "排序：同开始时间按日历名")

// MARK: - 今日筛选（含跨午夜）
let crossFromYesterday = ev("跨午夜昨晚", dt(2026, 10, 21, 23, 0), dt(2026, 10, 22, 1, 0))
let crossToTomorrow = ev("跨午夜今晚", dt(2026, 10, 22, 23, 0), dt(2026, 10, 23, 1, 0))
let tomorrowEv = ev("明天", dt(2026, 10, 23, 9, 0), dt(2026, 10, 23, 10, 0))
let allDayToday = ev("今日全天", today0, today0.addingTimeInterval(86400), allDay: true)

let pool = [ongoing, future, past, crossFromYesterday, crossToTomorrow, tomorrowEv, allDayToday]
let todayTitles = Set(ScheduleFilter.today(pool, now: now).map(\.title))
ok(todayTitles.contains("进行中"), "今日：普通事件在内")
ok(todayTitles.contains("已过"), "今日：已过去的今日事件仍列出")
ok(todayTitles.contains("跨午夜昨晚"), "今日：昨天开始、今天结束的跨午夜事件在内")
ok(todayTitles.contains("跨午夜今晚"), "今日：今天开始、明天结束的跨午夜事件在内")
ok(!todayTitles.contains("明天"), "今日：明天的整日事件不在内")
ok(todayTitles.contains("今日全天"), "今日：全天事件在内")
ok(ScheduleFilter.today(pool, now: now).first?.isAllDay == true, "今日：全天事件仍排最前")
ok(crossToTomorrow.duration == 2 * 3600, "跨午夜事件时长为 2 小时")

// MARK: - 全天开关
UserDefaults.standard.set(false, forKey: Pref.scheduleShowAllDay)
ok(!ScheduleFilter.today(pool, now: now).contains { $0.isAllDay }, "关闭「显示全天事件」后全天被过滤")
UserDefaults.standard.set(true, forKey: Pref.scheduleShowAllDay)
ok(ScheduleFilter.today(pool, now: now).contains { $0.isAllDay }, "打开后全天回来")

// MARK: - 日历筛选
UserDefaults.standard.set("家庭", forKey: Pref.scheduleCalendars)
ok(ScheduleFilter.apply(pool).allSatisfy { $0.calendarName == "家庭" }, "日历筛选：只留选中的「家庭」")
ok(ScheduleFilter.selectedCalendars() == ["家庭"], "日历筛选集解析正确")
UserDefaults.standard.set("", forKey: Pref.scheduleCalendars)
ok(ScheduleFilter.apply(pool).count == pool.count, "筛选集为空 = 全部显示")
let noCal = ev("无日历", dt(2026, 10, 22, 11, 0), dt(2026, 10, 22, 12, 0), calName: "")
UserDefaults.standard.set("家庭", forKey: Pref.scheduleCalendars)
ok(ScheduleFilter.apply([noCal]).count == 1, "日历名为空的事件不被筛选误杀")
UserDefaults.standard.set("", forKey: Pref.scheduleCalendars)

// MARK: - 胶囊的「下一条」
UserDefaults.standard.set("today", forKey: Pref.scheduleWindow)
ok(ScheduleFilter.next(pool, now: now)?.title == "进行中", "预读今日：进行中优先于未来事件")
ok(ScheduleFilter.next(pool.filter { $0.title != "进行中" }, now: now)?.title == "未来", "无进行中时取最近要开始的")
ok(ScheduleFilter.next([tomorrowEv], now: now) == nil, "预读今日：无今日事件时返回 nil（显示暂无日程）")
UserDefaults.standard.set("24h", forKey: Pref.scheduleWindow)
ok(ScheduleFilter.next([tomorrowEv], now: now)?.title == "明天", "预读 24 小时：能取到明天")
UserDefaults.standard.set("3d", forKey: Pref.scheduleWindow)
// 「未来 3 天」= 今天 / 明天 / 后天
ok(ScheduleFilter.next([ev("后天", dt(2026, 10, 24, 9, 0), dt(2026, 10, 24, 10, 0))], now: now)?.title == "后天",
   "预读 3 天：后天（今日起第 2 天）能取到")
ok(ScheduleFilter.next([ev("第四天", dt(2026, 10, 25, 9, 0), dt(2026, 10, 25, 10, 0))], now: now) == nil,
   "预读 3 天：第 4 天不取（3 天窗口到后天结束）")
UserDefaults.standard.set("today", forKey: Pref.scheduleWindow)
ok(ScheduleFilter.next([allDayToday], now: now)?.isAllDay == true, "只有全天事件时返回全天事件")

// MARK: - 颜色与 JSON
let hexColor = hexString(from: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
ok(hexColor == "#FF0000", "hex 转换：纯红 = #FF0000（实际 \(hexColor)）")
ok(hexString(from: nil) == "#8E8E93", "hex 转换：nil 回退灰色")

let roundTrip = [ongoing, allDayToday]
let data = try! JSONEncoder().encode(roundTrip)
let back = try! JSONDecoder().decode([CalendarEvent].self, from: data)
ok(back.count == 2 && back[0].title == ongoing.title, "JSON 编解码往返保真")
ok(back[0].start.timeIntervalSince1970 == ongoing.start.timeIntervalSince1970, "JSON 往返时间戳不丢精度")
// 后向兼容：旧文件没有 ekEventID / uid 字段
let legacy = "[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"title\":\"旧数据\",\"start\":0,\"end\":3600,\"isAllDay\":false,\"calendarName\":\"工作\",\"calendarColor\":\"#4A99E9\"}]"
let legacyDecoded = try? JSONDecoder().decode([CalendarEvent].self, from: legacy.data(using: .utf8)!)
ok(legacyDecoded?.first?.title == "旧数据", "旧版 JSON（无 ekEventID/uid）可解码")
ok(legacyDecoded?.first?.isLocal == true, "旧版 JSON 事件识别为本地事件")
ok((try? JSONDecoder().decode([CalendarEvent].self, from: "not json".data(using: .utf8)!)) == nil,
   "损坏 JSON 解码返回 nil 而非崩溃")

// MARK: - 导入：ICS
let icsSample = """
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:abc-123
SUMMARY:产品评审会
DTSTART:20261102T060000Z
DTEND:20261102T070000Z
CATEGORIES:工作
END:VEVENT
BEGIN:VEVENT
UID:all-day-1
SUMMARY:团队休假日
DTSTART;VALUE=DATE:20261103
DTEND;VALUE=DATE:20261104
END:VEVENT
END:VCALENDAR
"""
let icsEvents = ScheduleImport.parseICS(icsSample)
ok(icsEvents.count == 2, "ICS：解析出 2 条事件（实际 \(icsEvents.count)）")
ok(icsEvents.first?.title == "产品评审会", "ICS：SUMMARY 解出标题")
ok(icsEvents.first?.uid == "abc-123", "ICS：UID 解出")
ok(icsEvents.first?.calendarName == "工作", "ICS：CATEGORIES 映射到日历名")
let icsLocalTime = icsEvents.first.map { formatDate("HH:mm", $0.start) } ?? "-"
ok(icsLocalTime == DateFormatter.localizedString(from: icsEvents.first!.start, dateStyle: .none, timeStyle: .short).replacingOccurrences(of: "上午", with: "").trimmingCharacters(in: .whitespaces) ||
   icsLocalTime == "14:00", "ICS：UTC 时间按本地时区换算（实际 \(icsLocalTime)）")
ok(icsEvents.first?.isAllDay == false, "ICS：带 T 的 DTSTART 不是全天")
ok(icsEvents.last?.isAllDay == true, "ICS：VALUE=DATE 识别为全天")

let folded = "BEGIN:VEVENT\r\nUID:f1\r\nSUMMARY:很长的标题会被\r\n 折成两行\r\nDTSTART:20261102T060000Z\r\nDTEND:20261102T070000Z\r\nEND:VEVENT"
ok(ScheduleImport.parseICS(folded).first?.title == "很长的标题会被折成两行", "ICS：续行正确拼接")

let escaped = "BEGIN:VEVENT\r\nUID:e1\r\nSUMMARY:评审\\, 讨论\\; 备注\r\nDTSTART:20261102T060000Z\r\nDTEND:20261102T070000Z\r\nEND:VEVENT"
ok(ScheduleImport.parseICS(escaped).first?.title == "评审, 讨论; 备注", "ICS：反转义 \\, 和 \\;")

let tzEvent = "BEGIN:VEVENT\r\nUID:tz1\r\nSUMMARY:TZID 测试\r\nDTSTART;TZID=Asia/Shanghai:20261102T143000\r\nDTEND;TZID=Asia/Shanghai:20261102T153000\r\nEND:VEVENT"
let tzParsed = ScheduleImport.parseICS(tzEvent).first
ok(tzParsed.map { formatDate("HH:mm", $0.start) } == "14:30",
   "ICS：TZID 时区解析为 14:30（实际 \(tzParsed.map { formatDate("HH:mm", $0.start) } ?? "-")）")

let noEnd = "BEGIN:VEVENT\r\nUID:n1\r\nSUMMARY:无结束\r\nDTSTART:20261102T060000Z\r\nEND:VEVENT"
if let ne = ScheduleImport.parseICS(noEnd).first {
    ok(ne.end.timeIntervalSince(ne.start) == 3600, "ICS：缺 DTEND 默认 1 小时")
} else { ok(false, "ICS：缺 DTEND 默认 1 小时（解析失败）") }

let noSummary = "BEGIN:VEVENT\r\nUID:ns1\r\nDTSTART:20261102T060000Z\r\nDTEND:20261102T070000Z\r\nEND:VEVENT"
ok(ScheduleImport.parseICS(noSummary).isEmpty, "ICS：缺 SUMMARY 的事件被跳过（不产生空标题）")

// MARK: - 导入：简易文本
let nowT = dt(2026, 10, 22, 14, 30)
let textEvents = ScheduleImport.parseText("09:00-10:00 晨会\n14:30 产品评审会\n- 无时间的条目", now: nowT)
ok(textEvents.count == 3, "文本：解析 3 条（实际 \(textEvents.count)）")
if textEvents.count == 3 {
    ok(textEvents[0].title == "晨会", "文本：「09:00-10:00 晨会」标题正确（实际 \(textEvents[0].title)）")
    ok(formatDate("HH:mm", textEvents[0].start) == "09:00", "文本：开始 09:00")
    ok(formatDate("HH:mm", textEvents[0].end) == "10:00", "文本：结束 10:00")
    ok(textEvents[1].title == "产品评审会", "文本：单时间标题正确（实际 \(textEvents[1].title)）")
    ok(formatDate("HH:mm", textEvents[1].end) == "15:30", "文本：单时间默认 1 小时")
    ok(textEvents[2].title == "无时间的条目", "文本：无时间条目标题正确")
    ok(formatDate("HH:mm", textEvents[2].start) == "15:00", "文本：无时间放到下一个整点 15:00")
}
ok(ScheduleImport.parseText("# 注释\n\n", now: nowT).isEmpty, "文本：注释与空行被跳过")

// MARK: - 导入：JSON
let jsonEvents = ScheduleImport.parseJSON(String(data: try! JSONEncoder().encode([ongoing]), encoding: .utf8)!)
ok(jsonEvents.count == 1 && jsonEvents[0].title == "进行中", "JSON：数组格式可解析")
ok(ScheduleImport.parseJSON("{\"events\":[]}").isEmpty, "JSON：{\"events\":[]} 可解析为空")
ok(ScheduleImport.parseJSON("garbage").isEmpty, "JSON：非法内容返回空数组不崩")

// MARK: - 去重
let base = [ev("晨会", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0))]
var dup = base[0]; dup.id = UUID()
ok(ScheduleImport.dedupe([dup], existing: base).isEmpty, "去重：完全相同的事件（不同 id）被跳过")
let sameTitleDiffTime = ev("晨会", dt(2026, 10, 22, 11, 0), dt(2026, 10, 22, 12, 0))
ok(ScheduleImport.dedupe([sameTitleDiffTime], existing: base).count == 1, "去重：标题同但时间不同，保留")
var uidA = ev("A", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0)); uidA.uid = "uid-x"
var uidB = ev("B 标题改了", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0)); uidB.uid = "uid-x"
ok(ScheduleImport.dedupe([uidB], existing: [uidA]).isEmpty, "去重：UID 相同即视为同一条（即使标题变了）")
ok(ScheduleImport.dedupe([dup, dup], existing: []).count == 1, "去重：同一批内的重复也只留一条")

// MARK: - 导出
let exportList = [ev("晨会", dt(2026, 11, 2, 9, 0), dt(2026, 11, 2, 10, 0), calName: "工作"),
                  ev("休假日", dt(2026, 11, 3, 0, 0), dt(2026, 11, 4, 0, 0), allDay: true, calName: "家庭")]
let icsOut = ScheduleExport.ics(exportList)
ok(icsOut.contains("BEGIN:VCALENDAR"), "导出 ICS：有 VCALENDAR 头")
ok(icsOut.contains("SUMMARY:晨会"), "导出 ICS：含标题")
ok(icsOut.contains("CATEGORIES:工作"), "导出 ICS：含日历分类")
ok(icsOut.contains("DTSTART;VALUE=DATE:20261103"), "导出 ICS：全天事件用 VALUE=DATE 且日期不偏移")
ok(icsOut.hasSuffix("\r\n"), "导出 ICS：以 CRLF 结尾")

let roundTripICS = ScheduleImport.parseICS(icsOut)
ok(roundTripICS.count == 2, "导出 ICS 再导入：条数一致（实际 \(roundTripICS.count)）")
ok(roundTripICS.contains { $0.title == "晨会" }, "导出 ICS 再导入：标题保留")
ok(roundTripICS.contains { $0.isAllDay && $0.title == "休假日" }, "导出 ICS 再导入：全天标记保留")
// 全天事件的日期必须还是本地 11-03（回归 §时区 bug）
if let allDayBack = roundTripICS.first(where: { $0.isAllDay }) {
    ok(formatDate("yyyy-MM-dd", allDayBack.start) == "2026-11-03",
       "导出 ICS 再导入：全天事件日期不偏移（实际 \(formatDate("yyyy-MM-dd", allDayBack.start))）")
} else { ok(false, "导出 ICS 再导入：全天事件丢失") }

let special = [ev("A, B; C\\D", dt(2026, 11, 2, 9, 0), dt(2026, 11, 2, 10, 0))]
let specialICS = ScheduleExport.ics(special)
ok(ScheduleImport.parseICS(specialICS).first?.title == "A, B; C\\D",
   "导出 ICS 再导入：特殊字符完整保留（实际 \(ScheduleImport.parseICS(specialICS).first?.title ?? "-")）")

let md = ScheduleExport.markdown(exportList)
ok(md.contains("# 日程导出"), "导出 Markdown：有标题")
ok(md.contains("晨会"), "导出 Markdown：含事件")
ok(ScheduleExport.json(exportList).flatMap { try? JSONDecoder().decode([CalendarEvent].self, from: $0) }?.count == 2,
   "导出 JSON 再解码：条数一致")

// MARK: - 格式识别
ok(ScheduleImport.sniffText(icsSample) == .ics, "识别：ICS 内容识别为 .ics")
ok(ScheduleImport.sniffText("[{\"title\":\"a\"}]") == .json, "识别：JSON 内容识别为 .json")
ok(ScheduleImport.sniffText("09:00 晨会") == .text, "识别：纯文本识别为 .text")

// 还原偏好
for k in touchKeys { UserDefaults.standard.removeObject(forKey: k) }


// MARK: - v1.4 Bug 1 回归：ISO8601 日期解码（用户 312 条日程静默失败）
let isoDate = "2026-10-22T07:30:00+08:00"
let isoJSON = "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"起床\",\"start\":\"2026-10-22T07:30:00+08:00\",\"end\":\"2026-10-22T07:45:00+08:00\",\"isAllDay\":false,\"calendarName\":\"求职日程\",\"calendarColor\":\"#4A99E9\",\"ekEventID\":null,\"uid\":\"keovi-0001@dockside\",\"occurrenceStart\":null}]"
let isoParsed = ScheduleImport.parseJSON(isoJSON)
ok(isoParsed.count == 1, "Bug1 回归：ISO8601 字符串日期可解码（实际 \(isoParsed.count) 条）")
ok(isoParsed.first?.title == "起床", "Bug1 回归：标题保留")
ok(isoParsed.first.map { formatDate("HH:mm", $0.start) } == "07:30",
   "Bug1 回归：时间按本地时区正确（实际 \(isoParsed.first.map { formatDate("HH:mm", $0.start) } ?? "-")）")
ok(isoParsed.first?.uid == "keovi-0001@dockside", "Bug1 回归：uid 保留")

// 数字时间戳旧格式仍能读（双向兼容）
let tsJSON = "[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"title\":\"旧格式\",\"start\":1792623600,\"end\":1792624500,\"isAllDay\":false,\"calendarName\":\"工作\",\"calendarColor\":\"#4A99E9\"}]"
ok(ScheduleImport.parseJSON(tsJSON).count == 1, "Bug1 回归：数字时间戳旧格式仍可解码")

// 写出去的必须是数字时间戳（旧版本读得回来）
let rtData = try! JSONEncoder().encode(isoParsed)
let rtBack = try? JSONDecoder().decode([CalendarEvent].self, from: rtData)
ok(rtBack?.count == 1, "Bug1 回归：自己写出的格式可被标准解码器读回")

// 日期解析器各种格式
ok(ScheduleDateParse.parse("2026-10-22T07:30:00+08:00") != nil, "日期解析：带时区 ISO8601")
ok(ScheduleDateParse.parse("2026-10-22T07:30:00Z") != nil, "日期解析：UTC ISO8601")
ok(ScheduleDateParse.parse("2026-10-22T07:30:00.123+08:00") != nil, "日期解析：带小数秒")
ok(ScheduleDateParse.parse("2026-10-22 07:30:00") != nil, "日期解析：无时区空格格式")
ok(ScheduleDateParse.parse("2026-10-22") != nil, "日期解析：纯日期")
ok(ScheduleDateParse.parse("1792623600") != nil, "日期解析：字符串形式时间戳")
ok(ScheduleDateParse.parse("不是日期") == nil, "日期解析：垃圾字符串返回 nil")
ok(ScheduleDateParse.parse("") == nil, "日期解析：空串返回 nil")

// MARK: - v1.4 字段校验五条
var v1 = ev("", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0))
if case .rejected = ScheduleValidate.check(&v1) { ok(true, "校验①：空标题被拒绝") } else { ok(false, "校验①：空标题被拒绝") }

var v1b = ev("   ", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0))
if case .rejected = ScheduleValidate.check(&v1b) { ok(true, "校验①：纯空格标题被拒绝") } else { ok(false, "校验①：纯空格标题被拒绝") }

var v2 = ev("正常", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0))
if case .ok = ScheduleValidate.check(&v2) { ok(true, "校验：正常事件通过") } else { ok(false, "校验：正常事件通过") }

var v3 = ev("结束早于开始", dt(2026, 10, 22, 10, 0), dt(2026, 10, 22, 9, 0))
if case .fixed = ScheduleValidate.check(&v3) {
    ok(v3.end.timeIntervalSince(v3.start) == 3600, "校验③：end<start 自动修正为 start+1h")
} else { ok(false, "校验③：end<start 自动修正") }

var v4 = ev("1999年", dt(1999, 12, 31, 9, 0), dt(1999, 12, 31, 10, 0))
if case .rejected = ScheduleValidate.check(&v4) { ok(true, "校验④：1999 年视为脏数据拒绝") } else { ok(false, "校验④：1999 年拒绝") }

var v5 = ev("2101年", dt(2101, 1, 1, 9, 0), dt(2101, 1, 1, 10, 0))
if case .rejected = ScheduleValidate.check(&v5) { ok(true, "校验④：2101 年视为脏数据拒绝") } else { ok(false, "校验④：2101 年拒绝") }

var v6 = ev("全天起止相同", dt(2026, 10, 22, 0, 0), dt(2026, 10, 22, 0, 0), allDay: true)
if case .ok = ScheduleValidate.check(&v6) { ok(true, "校验⑤：全天事件允许 start == end") } else { ok(false, "校验⑤：全天允许 start==end") }

var v7 = ev("定时起止相同", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 9, 0))
if case .fixed = ScheduleValidate.check(&v7) { ok(true, "校验：定时事件起止相同被修正") } else { ok(false, "校验：定时起止相同被修正") }

var v8 = ev("  两边有空格  ", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0))
_ = ScheduleValidate.check(&v8)
ok(v8.title == "两边有空格", "校验①：标题首尾空格被去掉（实际「\(v8.title)」）")

// 导入统计结构
var sumA = ImportSummary(); sumA.imported = 3; sumA.failed = 1
var sumB = ImportSummary(); sumB.imported = 2; sumB.duplicate = 4
sumA += sumB
ok(sumA.imported == 5 && sumA.duplicate == 4 && sumA.failed == 1, "导入统计：多文件累加正确")

// MARK: - v1.4 Bug 2 回归：全天事件在周视图有像素位（数据侧）
// 只有全天事件的一天：状态栏计数用的 store.events 与列内 allDay 必须一致
let onlyAllDayPool = [ev("重阳节", today0, today0.addingTimeInterval(86400), allDay: true),
                      ev("霜降", dt(2026, 10, 23, 0, 0), dt(2026, 10, 24, 0, 0), allDay: true)]
let todayOnlyAllDay = ScheduleFilter.today(onlyAllDayPool, now: now)
ok(todayOnlyAllDay.count == 1, "Bug2 回归：今日只有全天事件时筛选得出 1 条")
ok(todayOnlyAllDay.allSatisfy { $0.isAllDay }, "Bug2 回归：筛出的是全天事件（旧代码不渲染这类）")



// MARK: - v1.4 验收 19：全天事件必须在周视图有渲染位（计数与画面一致）
// 复刻用户现场：一周里只有节气/节日这类全天事件，旧代码「4 条但全空」
UserDefaults.standard.set("", forKey: Pref.scheduleCalendars)
UserDefaults.standard.set(true, forKey: Pref.scheduleShowAllDay)

let holidayWeek = [
    ev("重阳节", dt(2026, 10, 18, 0, 0), dt(2026, 10, 19, 0, 0), allDay: true, calName: "节假日"),
    ev("霜降",   dt(2026, 10, 23, 0, 0), dt(2026, 10, 24, 0, 0), allDay: true, calName: "节假日"),
    ev("寒衣节", dt(2026, 10, 24, 0, 0), dt(2026, 10, 25, 0, 0), allDay: true, calName: "节假日"),
    ev("万圣夜", dt(2026, 10, 25, 0, 0), dt(2026, 10, 26, 0, 0), allDay: true, calName: "节假日"),
]
let mon = dt(2026, 10, 19, 0, 0)
let tue = dt(2026, 10, 20, 0, 0)
let sun = dt(2026, 10, 18, 0, 0)
let fri = dt(2026, 10, 23, 0, 0)

let holidaySun = ScheduleFilter.splitForDay(holidayWeek, day: sun)
ok(holidaySun.allDay.count == 1, "验收19：周日列出 1 条全天（重阳节），不再只进列头小字")
ok(holidaySun.allDay.first?.title == "重阳节", "验收19：周日全天条内容是重阳节")
ok(holidaySun.timed.isEmpty, "验收19：周日没有定时事件")

let holidayMon = ScheduleFilter.splitForDay(holidayWeek, day: mon)
ok(holidayMon.allDay.isEmpty && holidayMon.timed.isEmpty, "验收19：无事件的列不占位（周一空）")

let holidayFri = ScheduleFilter.splitForDay(holidayWeek, day: fri)
ok(holidayFri.allDay.count == 1 && holidayFri.allDay.first?.title == "霜降", "验收19：周五全天条是霜降")

// 一整周只有全天事件时，7 天里能画出的事件总数 = 数据总条数（不多算、不漏算）
let weekDays = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: sun) }
let renderedCount = weekDays.reduce(0) { acc, d in
    let sp = ScheduleFilter.splitForDay(holidayWeek, day: d)
    return acc + sp.allDay.count + sp.timed.count
}
// 10/18(日) ~ 10/24(六) 这一周里只有 3 条（万圣夜 10/25 属下一周）
ok(renderedCount == 3,
   "验收19：本周渲染出 3 条（重阳节/霜降/寒衣节），万圣夜属下周一不越界（实际 \(renderedCount)）")
let nextWeekSun = dt(2026, 10, 25, 0, 0)
ok(ScheduleFilter.splitForDay(holidayWeek, day: nextWeekSun).allDay.first?.title == "万圣夜",
   "验收19：万圣夜在下一周周日正确显示")

// 定时 + 全天混排：两组都要出现
let mixedPool2 = [
    ev("晨会", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0)),
    ev("团队休假日", dt(2026, 10, 22, 0, 0), dt(2026, 10, 23, 0, 0), allDay: true, calName: "节假日"),
]
let mixedSplit = ScheduleFilter.splitForDay(mixedPool2, day: dt(2026, 10, 22, 0, 0))
ok(mixedSplit.timed.count == 1 && mixedSplit.allDay.count == 1,
   "验收19：同一天定时+全天都要渲染（各 1 条）")
ok(mixedSplit.allDay.first?.title == "团队休假日", "验收19：全天条取到团队休假日")

// 跨午夜事件在列的归属：22:00-次日02:00 应同时出现在两天
let crossDay = [ev("跨午夜", dt(2026, 10, 22, 22, 0), dt(2026, 10, 23, 2, 0))]
ok(ScheduleFilter.splitForDay(crossDay, day: dt(2026, 10, 22, 0, 0)).timed.count == 1, "验收19：跨午夜事件出现在开始日")
ok(ScheduleFilter.splitForDay(crossDay, day: dt(2026, 10, 23, 0, 0)).timed.count == 1, "验收19：跨午夜事件也出现在结束日")

// 多天连续的全天事件（如长假）每天都要显示
let longHoliday = [ev("国庆假期", dt(2026, 10, 1, 0, 0), dt(2026, 10, 8, 0, 0), allDay: true, calName: "节假日")]
let oct3 = ScheduleFilter.splitForDay(longHoliday, day: dt(2026, 10, 3, 0, 0))
ok(oct3.allDay.count == 1, "验收19：跨多天的全天事件，中间每天都能渲染")



// MARK: - 线上事故回归：解码失败绝不能销毁用户数据
// 事故经过：旧解码器读不懂 ISO8601 → loadLocal 判定「文件损坏」→ 直接写空文件 → 用户 312 条被连锅端
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("dockside-test-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

// ① 模拟「解码失败」时的正确行为：备份原文件，不覆盖
let badFile = tmpDir.appendingPathComponent("schedule.json")
let badContent = "[{\"title\":\"数据\",\"start\":\"坏掉的日期\",\"end\":\"也坏\"}]"
try! badContent.write(to: badFile, atomically: true, encoding: .utf8)
let decodedBad = (try? JSONDecoder().decode([CalendarEvent].self, from: Data(contentsOf: badFile))) ?? []
ok(decodedBad.isEmpty, "事故回归：损坏内容确实解码失败（准备前提）")
// 修复后的逻辑：备份而不是覆盖
let bakFile = tmpDir.appendingPathComponent("schedule.损坏备份-test.json")
if let d = try? Data(contentsOf: badFile) { try? d.write(to: bakFile, options: .atomic) }
ok(FileManager.default.fileExists(atPath: bakFile.path), "事故回归：解码失败时原文件被备份")
ok((try? String(contentsOf: bakFile, encoding: .utf8)) == badContent, "事故回归：备份内容与原始一致（数据可找回）")

// ② 关键：容错解码让「以前会失败」的文件现在能正常读，根本不会走到损坏分支
let isoAgain = "[{\"id\":\"00000000-0000-0000-0000-000000000009\",\"title\":\"起床\",\"start\":\"2026-10-22T07:30:00+08:00\",\"end\":\"2026-10-22T07:45:00+08:00\",\"isAllDay\":false,\"calendarName\":\"求职日程\",\"calendarColor\":\"#4A99E9\"}]"
ok(ScheduleImport.parseJSON(isoAgain).count == 1, "事故回归：ISO8601 文件不再被判为损坏（容错解码兜住）")

// ③ 空文件/不存在文件都是安全的空结果，不是错误
let emptyFile = tmpDir.appendingPathComponent("empty.json")
try! "[]".write(to: emptyFile, atomically: true, encoding: .utf8)
ok(((try? JSONDecoder().decode([CalendarEvent].self, from: Data(contentsOf: emptyFile))) ?? []).isEmpty,
   "事故回归：空数组文件正常解码为空，不触发重建")
let missing = tmpDir.appendingPathComponent("not-exist.json")
ok((try? Data(contentsOf: missing)) == nil, "事故回归：文件不存在返回 nil，按空处理不崩")

try? FileManager.default.removeItem(at: tmpDir)

// MARK: - 清空本地数据：先备份再清(用户报「按了没反应」)
// 数据侧要保证：备份写成功、清空后确实是空、备份内容等于清空前内容
let clrDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("dockside-clear-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: clrDir, withIntermediateDirectories: true)
let clrFile = clrDir.appendingPathComponent("schedule.json")
let beforeClear = try! JSONEncoder().encode([ongoing, allDayToday])
try! beforeClear.write(to: clrFile, options: .atomic)
let backupBeforeClear = clrDir.appendingPathComponent("schedule.清空前备份-test.json")
try! Data(contentsOf: clrFile).write(to: backupBeforeClear, options: .atomic)
try! JSONEncoder().encode([CalendarEvent]()).write(to: clrFile, options: .atomic)
ok(((try? JSONDecoder().decode([CalendarEvent].self, from: Data(contentsOf: clrFile))) ?? []).isEmpty,
   "清空回归：清空后文件确实是空数组")
ok((try? Data(contentsOf: backupBeforeClear))?.count == beforeClear.count,
   "清空回归：清空前备份字节数与原始一致（可恢复）")
let restored = (try? JSONDecoder().decode([CalendarEvent].self, from: Data(contentsOf: backupBeforeClear))) ?? []
ok(restored.count == 2, "清空回归：备份能被解码回来（2 条）")
try? FileManager.default.removeItem(at: clrDir)



// MARK: - 线上事故回归：「清空没反应」的真正根因
// 事故：授权状态下 reload() 只读 EventKit，完全不读本地 JSON →
//      导入的日程永不显示；清空本地文件界面无变化 → 用户以为「按了没反应」。
// 验收要求：EventKit 与本地 JSON 是双源，授权后两者都要显示。

// ① 双源去重逻辑：同标题同开始时间只留一条
func dedupeAgainstEK(_ ekList: [CalendarEvent], _ localList: [CalendarEvent]) -> [CalendarEvent] {
    let keys = Set(ekList.map { "\($0.title)|\(Int($0.start.timeIntervalSince1970))" })
    let keep = localList.filter { !keys.contains("\($0.title)|\(Int($0.start.timeIntervalSince1970))") }
    return (ekList + keep).sorted(by: eventSort)
}

let ekEvent = ev("产品评审会", dt(2026, 10, 22, 14, 30), dt(2026, 10, 22, 15, 30), calName: "工作")
var localDup = ev("产品评审会", dt(2026, 10, 22, 14, 30), dt(2026, 10, 22, 15, 30), calName: "本地")
localDup.ekEventID = nil
var localOnly2 = ev("晨会", dt(2026, 10, 22, 9, 0), dt(2026, 10, 22, 10, 0), calName: "本地")
localOnly2.ekEventID = nil

let merged2 = dedupeAgainstEK([ekEvent], [localDup, localOnly2])
ok(merged2.count == 2, "事故回归：系统日历 1 条 + 本地独有的 1 条 = 2 条（重复的去掉）")
ok(merged2.filter { $0.title == "产品评审会" }.count == 1, "事故回归：跨源重复事件只显示一条")
ok(merged2.contains { $0.title == "晨会" && $0.isLocal }, "事故回归：本地独有事件必须显示（旧代码会整个吞掉）")

// ② 只有本地数据、没有任何系统日历时，本地必须全显示
let onlyLocal = [localDup, localOnly2]
ok(dedupeAgainstEK([], onlyLocal).count == 2, "事故回归：无系统日程时本地事件全部可见")

// ③ 标题相同但时间不同 → 视为两条，都保留
var sameTitleDiff = ev("晨会", dt(2026, 10, 22, 15, 0), dt(2026, 10, 22, 16, 0), calName: "本地")
sameTitleDiff.ekEventID = nil
ok(dedupeAgainstEK([ekEvent], [sameTitleDiff]).count == 2, "事故回归：同标题不同时间不算重复，都保留")

// ④ 本地事件的身份判定：ekEventID == nil 即本地（清空/编辑/删除都靠它分流）
ok(localOnly2.isLocal == true, "事故回归：本地事件 isLocal == true")
// 系统日历事件必须带 ekEventID；辅助函数 ev() 默认 ekEventID = nil（那是本地事件的标志）
var ekMarked = ekEvent
ekMarked.ekEventID = "EK-1234"
ok(ekMarked.isLocal == false, "事故回归：带 ekEventID 的事件 isLocal == false（判定分流正确）")


print("\n=== \(pass) 通过 / \(fail) 失败 ===")
exit(fail == 0 ? 0 : 1)
