import Foundation

/// 解析导入的日程文本：ICS / JSON / 简易文本。
/// 做成纯函数，方便单测（不碰界面、不碰磁盘）。
enum ScheduleImport {

    enum Format { case ics, json, text }

    /// 按扩展名判断格式；扩展名不认识时嗅探内容
    static func format(for url: URL) -> Format {
        switch url.pathExtension.lowercased() {
        case "ics", "ical", "ifb": return .ics
        case "json": return .json
        case "txt", "md", "csv": return .text
        default: return sniff(url)
        }
    }

    static func sniffText(_ text: String) -> Format {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("BEGIN:VCALENDAR") || t.contains("BEGIN:VEVENT") { return .ics }
        if t.hasPrefix("[") || t.hasPrefix("{") { return .json }
        return .text
    }

    private static func sniff(_ url: URL) -> Format {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return .text }
        return sniffText(t)
    }

    /// 统一入口：解析文本为事件数组
    static func parse(_ text: String, format: Format) -> [CalendarEvent] {
        switch format {
        case .ics:  return parseICS(text)
        case .json: return parseJSON(text)
        case .text: return parseText(text)
        }
    }

    // MARK: - JSON

    static func parseJSON(_ text: String) -> [CalendarEvent] {
        guard let data = text.data(using: .utf8) else { return [] }
        if let list = try? JSONDecoder().decode([CalendarEvent].self, from: data) { return list }
        // 也接受外面包一层 {"events": [...]}
        if let wrapper = try? JSONDecoder().decode(JSONWrapper.self, from: data) { return wrapper.events }
        return []
    }

    private struct JSONWrapper: Decodable { let events: [CalendarEvent] }

    // MARK: - ICS

    /// 极简 ICS 解析：只取 VEVENT 的 SUMMARY / DTSTART / DTEND / UID，够导入用
    static func parseICS(_ text: String) -> [CalendarEvent] {
        let unfolded = unfold(text)
        var result: [CalendarEvent] = []
        var cur: [String: String]?
        var inEvent = false

        for rawLine in unfolded.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "BEGIN:VEVENT" { inEvent = true; cur = [:]; continue }
            if line == "END:VEVENT" {
                if let c = cur, let ev = makeEvent(c) { result.append(ev) }
                inEvent = false; cur = nil; continue
            }
            guard inEvent, let idx = line.firstIndex(of: ":") else { continue }
            let keyPart = String(line[line.startIndex..<idx])
            let value = String(line[line.index(after: idx)...])
            // 去掉参数，如 DTSTART;TZID=Asia/Shanghai
            let key = keyPart.components(separatedBy: ";").first?.uppercased() ?? keyPart.uppercased()
            cur?[key] = value
            if key == "DTSTART" { cur?["DTSTART;RAW"] = keyPart }
        }
        return result
    }

    /// ICS 的折行规则：以空格或制表符开头的续行接到上一行
    static func unfold(_ text: String) -> String {
        var out: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !out.isEmpty { out[out.count - 1] += String(line.dropFirst()) }
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    private static func makeEvent(_ f: [String: String]) -> CalendarEvent? {
        guard let title = f["SUMMARY"], !title.isEmpty else { return nil }
        let isAllDay = f["DTSTART"]?.contains("T") == false && f["DTSTART"]?.count == 8
        guard let start = parseICSDate(f["DTSTART"], raw: f["DTSTART;RAW"], allDay: isAllDay) else { return nil }
        let end = parseICSDate(f["DTEND"], raw: nil, allDay: isAllDay) ?? start.addingTimeInterval(isAllDay ? 86400 : 3600)
        return CalendarEvent(
            title: unescapeICS(title),
            start: start,
            end: max(end, start.addingTimeInterval(60)),
            isAllDay: isAllDay,
            calendarName: unescapeICS(f["CATEGORIES"] ?? ""),
            calendarColor: "#8E8E93",
            ekEventID: nil,
            uid: f["UID"]
        )
    }

    /// 解 ICS 日期。支持 20261022T143000Z / 20261022T143000（带 TZID）/ 20261022
    static func parseICSDate(_ value: String?, raw: String?, allDay: Bool) -> Date? {
        guard var v = value, !v.isEmpty else { return nil }
        var tz = TimeZone.current
        if let raw, let r = raw.range(of: "TZID=") {
            let id = raw[r.upperBound...].components(separatedBy: ";").first ?? ""
            if let z = TimeZone(identifier: String(id)) { tz = z }
        }
        var isUTC = false
        if v.hasSuffix("Z") { v.removeLast(); isUTC = true; tz = TimeZone(identifier: "UTC")! }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = v.contains("T") ? "yyyyMMdd'T'HHmmss" : "yyyyMMdd"
        guard let d = df.date(from: v) else { return nil }
        return isUTC ? d : d   // DateFormatter 已按 tz 解析，返回绝对时间
    }

    static func unescapeICS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - 简易文本

    /// 每行一条：`时间 标题`、`开始时间-结束时间 标题`、或纯标题（归到今天的下一个整点）
    static func parseText(_ text: String, now: Date = Date()) -> [CalendarEvent] {
        let cal = Calendar.current
        var result: [CalendarEvent] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // 去掉列表符号
            for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let ev = parseTextLine(line, now: now) { result.append(ev) }
        }
        _ = cal
        return result
    }

    /// 解析单行。支持的写法：
    ///   09:00-10:00 晨会
    ///   9:00 晨会
    ///   14:30 产品评审会 15:30
    ///   晨会（无时间 → 下一个整点，1 小时）
    static func parseTextLine(_ line: String, now: Date = Date()) -> CalendarEvent? {
        let cal = Calendar.current
        let timeRe = try! NSRegularExpression(pattern: #"(\d{1,2})[:：](\d{2})"#)

        func matches(_ s: String) -> [(Range<String.Index>, Int, Int)] {
            let ns = s as NSString
            return timeRe.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
                guard let r = Range(m.range, in: s) else { return nil }
                let h = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let mi = Int(ns.substring(with: m.range(at: 2))) ?? 0
                return (r, h, mi)
            }
        }

        let found = matches(line)
        let titlePart: String
        var start: Date
        var end: Date

        if found.isEmpty {
            // 无时间：放到今天的下一个整点
            titlePart = line
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
            start = cal.date(from: comps)?.addingTimeInterval(3600) ?? now
            end = start.addingTimeInterval(3600)
        } else {
            let base = cal.startOfDay(for: now)
            func at(_ h: Int, _ mi: Int) -> Date {
                cal.date(byAdding: .minute, value: h * 60 + mi, to: base) ?? now
            }
            start = at(found[0].1, found[0].2)
            if found.count >= 2 {
                end = at(found[1].1, found[1].2)
                if end <= start { end = start.addingTimeInterval(3600) }
            } else {
                end = start.addingTimeInterval(3600)
            }
            // 标题 = 去掉时间片段后的剩余
            var t = line
            for f in found.reversed() { t.removeSubrange(f.0) }
            titlePart = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—~/|:：,，"))
        }

        guard !titlePart.isEmpty else { return nil }
        return CalendarEvent(title: titlePart, start: start, end: end,
                             isAllDay: false, calendarName: "导入", calendarColor: "#8E8E93")
    }

    // MARK: - 去重合并

    /// 按 uid → (标题+开始时间) 的优先级去重，只返回真正新增的事件
    static func dedupe(_ incoming: [CalendarEvent], existing: [CalendarEvent]) -> [CalendarEvent] {
        var uids = Set(existing.compactMap(\.uid).filter { !$0.isEmpty })
        var keys = Set(existing.map { dedupeKey($0) })
        var fresh: [CalendarEvent] = []
        for e in incoming {
            if let uid = e.uid, !uid.isEmpty {
                if uids.contains(uid) { continue }
                uids.insert(uid)
            }
            let k = dedupeKey(e)
            if keys.contains(k) { continue }
            keys.insert(k)
            fresh.append(e)
        }
        return fresh
    }

    /// 导入合并：已有的覆盖，没有的新增。
    /// 「已有」= UID 相同；没有 UID 时 = 标题相同且开始时间相同（结束时间、全天、日历等以导入的为准）
    static func merge(_ incoming: [CalendarEvent], into existing: [CalendarEvent])
        -> (list: [CalendarEvent], added: Int, updated: Int) {
        var list = existing
        var added = 0, updated = 0
        var touched = Set<Int>()   // 同一批里重复出现的，以最后一条为准，但只算一次
        for e in incoming {
            let idx = list.firstIndex { old in
                if let u = e.uid, !u.isEmpty, let ou = old.uid, !ou.isEmpty { return u == ou }
                return old.title == e.title && Int(old.start.timeIntervalSince1970) == Int(e.start.timeIntervalSince1970)
            }
            if let i = idx {
                var v = e
                v.id = list[i].id            // 保留原来的 id，界面上不会当成新事件
                if v.uid == nil { v.uid = list[i].uid }
                if list[i] != v, !touched.contains(i) { updated += 1 }
                touched.insert(i)
                list[i] = v
            } else {
                list.append(e)
                touched.insert(list.count - 1)
                added += 1
            }
        }
        return (list, added, updated)
    }

    static func dedupeKey(_ e: CalendarEvent) -> String {
        "\(e.title)|\(Int(e.start.timeIntervalSince1970))|\(Int(e.end.timeIntervalSince1970))"
    }
}

// MARK: - ICS 导出

enum ScheduleExport {
    /// 转 ICS。colour 用 CATEGORIES 承载日历名（规格 §5.4 要求带上日历信息）
    static func ics(_ events: [CalendarEvent]) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        // 全天事件是「日历上的某一天」，必须按本地时区格式化；
        // 用 UTC 会把本地 11-03 00:00 写成 11-02（东八区偏移一天）
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = TimeZone.current
        dayFmt.dateFormat = "yyyyMMdd"

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//DockSide//Schedule//ZH",
            "CALSCALE:GREGORIAN",
        ]
        for e in events.sorted(by: eventSort) {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(e.uid ?? e.id.uuidString)")
            lines.append("DTSTAMP:\(df.string(from: Date()))")
            if e.isAllDay {
                lines.append("DTSTART;VALUE=DATE:\(dayFmt.string(from: e.start))")
                lines.append("DTEND;VALUE=DATE:\(dayFmt.string(from: e.end))")
            } else {
                lines.append("DTSTART:\(df.string(from: e.start))")
                lines.append("DTEND:\(df.string(from: e.end))")
            }
            lines.append("SUMMARY:\(escapeICS(e.title))")
            if !e.calendarName.isEmpty {
                lines.append("CATEGORIES:\(escapeICS(e.calendarName))")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func escapeICS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    /// 人类可读的 Markdown
    static func markdown(_ events: [CalendarEvent]) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 EEE HH:mm"
        var out = "# 日程导出\n\n"
        var lastDay = ""
        for e in events.sorted(by: eventSort) {
            let day = formatDate("M月d日 EEE", e.start)
            if day != lastDay {
                out += "\n## \(day)\n"
                lastDay = day
            }
            let time: String
            if e.isAllDay {
                time = "全天"
            } else {
                let hm = DateFormatter()
                hm.locale = Locale(identifier: "zh_CN")
                hm.dateFormat = "HH:mm"
                time = "\(hm.string(from: e.start))-\(hm.string(from: e.end))"
            }
            out += "- \(time) \(e.title)"
            if !e.calendarName.isEmpty { out += "（\(e.calendarName)）" }
            out += "\n"
        }
        return out
    }

    static func json(_ events: [CalendarEvent]) -> Data? {
        try? JSONEncoder().encode(events.sorted(by: eventSort))
    }
}
