import SwiftUI

func formatDate(_ pattern: String, _ date: Date) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "zh_CN")
    df.dateFormat = pattern
    return df.string(from: date)
}

struct ClockWidget: View {
    @AppStorage(Pref.clockSeconds) private var seconds = true
    @AppStorage(Pref.clock24h) private var h24 = true
    @Environment(\.compact) private var compact
    @Environment(\.widgetFontSize) private var size

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if compact {
                VStack(spacing: 0) {
                    Text(formatDate(h24 ? "HH" : "h", ctx.date))
                    Text(formatDate("mm", ctx.date)).opacity(0.8)
                }
                .font(.system(size: size * 1.1, weight: .semibold, design: .rounded))
            } else {
                Text(formatDate((h24 ? "HH:mm" : "h:mm") + (seconds ? ":ss" : ""), ctx.date))
            }
        }
        .modifier(WidgetText())
    }
}

struct DateWidget: View {
    @Environment(\.compact) private var compact
    @Environment(\.widgetFontSize) private var size

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            if compact {
                VStack(spacing: size * 0.1) {
                    Text(formatDate("M/d", ctx.date)).font(.system(size: size * 0.85, weight: .semibold, design: .rounded))
                    Text(formatDate("EEE", ctx.date)).font(.system(size: size * 0.7)).opacity(0.8)
                }
            } else {
                Text(formatDate("M月d日 EEEE", ctx.date))
            }
        }
        .modifier(WidgetText())
    }
}

/// 图标 + 数值的指标组件
struct MetricWidget: View {
    let every: TimeInterval
    let value: () -> (symbol: String, text: String)
    @Environment(\.compact) private var compact
    @Environment(\.widgetFontSize) private var size

    var body: some View {
        TimelineView(.periodic(from: .now, by: every)) { _ in
            let v = value()
            if compact {
                VStack(spacing: size * 0.2) {
                    Image(systemName: v.symbol)
                    Text(v.text).font(.system(size: size * 0.75, weight: .semibold, design: .rounded))
                }
            } else {
                HStack(spacing: size * 0.35) {
                    Image(systemName: v.symbol).opacity(0.85)
                    Text(v.text)
                }
            }
        }
        .modifier(WidgetText())
    }
}

struct CPUWidget: View {
    var body: some View {
        MetricWidget(every: 2) { ("cpu", "\(Int(Metrics.cpu.usage() * 100))%") }
    }
}

struct MemoryWidget: View {
    var body: some View {
        MetricWidget(every: 5) { ("memorychip", "\(Int(Metrics.memoryUsage() * 100))%") }
    }
}

struct BatteryWidget: View {
    var body: some View {
        MetricWidget(every: 30) {
            guard let level = Metrics.batteryLevel() else { return ("powerplug", "—") }
            let symbol = level >= 88 ? "battery.100" : level >= 63 ? "battery.75" : level >= 38 ? "battery.50" : level >= 13 ? "battery.25" : "battery.0"
            return (symbol, "\(level)%")
        }
    }
}
