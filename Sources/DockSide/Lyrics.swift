import AppKit
import SwiftUI
import CryptoKit

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double     // 秒；纯文本歌词为 -1
    let text: String
}

/// 歌词：从 LRCLIB（lrclib.net，免费、无需账号）下载带时间轴的歌词，缓存在本地
final class Lyrics: ObservableObject {
    static let shared = Lyrics()

    enum Status { case idle, loading, synced, plain, none }
    @Published var lines: [LyricLine] = []
    @Published var status: Status = .idle
    private var currentKey = ""

    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DockSide/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var synced: Bool { status == .synced }

    /// 当前播放位置对应第几行
    func index(at position: Double) -> Int? {
        guard synced, !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position + 0.25 { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? ans : nil
    }

    func load(title: String, artist: String, duration: Double) {
        let key = title + "|" + artist
        currentKey = key
        lines = []
        guard !title.isEmpty else { status = .idle; return }
        status = .loading

        let file = cacheDir.appendingPathComponent(Self.hash(key) + ".txt")
        if let cached = try? String(contentsOf: file, encoding: .utf8) {
            apply(cached, key: key)
            return
        }
        Task {
            let text = await Self.fetch(title: title, artist: artist, duration: duration) ?? ""
            try? text.write(to: file, atomically: true, encoding: .utf8)   // 没找到也缓存空结果，避免反复请求
            await MainActor.run { self.apply(text, key: key) }
        }
    }

    private func apply(_ raw: String, key: String) {
        guard key == currentKey else { return }
        let parsed = Self.parseLRC(raw)
        if !parsed.isEmpty {
            lines = parsed; status = .synced
        } else {
            let plain = raw.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
            let nonEmpty = plain.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            lines = nonEmpty ? plain.enumerated().map { LyricLine(id: $0.offset, time: -1, text: $0.element) } : []
            status = nonEmpty ? .plain : .none
        }
    }

    // MARK: 网络
    private static func fetch(title: String, artist: String, duration: Double) async -> String? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 { c.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        if let obj = await json(c.url!) as? [String: Any], let text = best(obj) { return text }

        // 精确匹配不到就搜索，取时长最接近的一条
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { s.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard let list = await json(s.url!) as? [[String: Any]] else { return nil }
        let sorted = list.sorted {
            let a = abs(($0["duration"] as? Double ?? 0) - duration), b = abs(($1["duration"] as? Double ?? 0) - duration)
            let sa = ($0["syncedLyrics"] as? String) != nil, sb = ($1["syncedLyrics"] as? String) != nil
            return sa != sb ? sa : a < b
        }
        for item in sorted { if let t = best(item) { return t } }
        return nil
    }

    private static func best(_ o: [String: Any]) -> String? {
        if let s = o["syncedLyrics"] as? String, !s.isEmpty { return s }
        if let p = o["plainLyrics"] as? String, !p.isEmpty { return p }
        return nil
    }

    private static func json(_ url: URL) async -> Any? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("DockSide (https://github.com/keovio/DockSide)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let data = result.0
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: 解析 [mm:ss.xx]歌词
    static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [(Double, String)] = []
        let regex = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]")
        for line in raw.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append((min * 60 + sec, text))
            }
        }
        return out.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 悬停弹出的歌词面板
final class LyricsPopover {
    static let shared = LyricsPopover()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    var isShown: Bool { panel?.isVisible == true }

    func show() {
        hideWork?.cancel()
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
            if p.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { return }
            p.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: dockSideLevel.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: LyricsView())
        return p
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let w: CGFloat = 340, h: CGFloat = 400
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let host = NSApp.windows.first { $0 !== p && $0.isVisible && $0.level == dockSideLevel && $0.frame.contains(mouse) }
        var origin: NSPoint
        if DockState.shared.vertical {
            let ref = host?.frame ?? NSRect(origin: mouse, size: .zero)
            origin = NSPoint(x: DockState.shared.dockOnLeft ? ref.maxX + 8 : ref.minX - w - 8, y: mouse.y - h / 2)
        } else {
            origin = NSPoint(x: mouse.x - w / 2, y: (host?.frame.maxY ?? mouse.y + 20) + 8)
        }
        let sf = screen.frame, vf = screen.visibleFrame
        origin.x = min(max(origin.x, sf.minX + 8), sf.maxX - w - 8)
        origin.y = min(max(origin.y, sf.minY + 8), vf.maxY - h - 8)
        p.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
    }
}

struct LyricsView: View {
    @ObservedObject private var np = NowPlaying.shared
    @ObservedObject private var lyrics = Lyrics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().opacity(0.4)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffect(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            if inside { LyricsPopover.shared.cancelHide() } else { LyricsPopover.shared.scheduleHide() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let img = np.artwork {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack { Color.white.opacity(0.1); Image(systemName: "music.note") }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Marquee(text: np.hasTrack ? np.title : "未在播放", width: 170, fontSize: 14)
                Marquee(text: np.artist, width: 170, fontSize: 12, semibold: false).opacity(0.65)
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                ctl("backward.fill") { np.previous() }
                ctl(np.playing ? "pause.fill" : "play.fill") { np.toggle() }
                ctl("forward.fill") { np.next() }
            }
        }
    }

    private func ctl(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15)) }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics.status {
        case .loading:
            centered("正在找歌词…")
        case .none, .idle:
            centered(np.hasTrack ? "没有找到这首歌的歌词" : "播放音乐后这里会显示歌词")
        case .plain:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这首只有纯文本歌词，不会跟随滚动").font(.caption).foregroundStyle(.secondary)
                    ForEach(lyrics.lines) { l in Text(l.text.isEmpty ? " " : l.text).font(.system(size: 14)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .synced:
            SyncedLyrics()
        }
    }

    private func centered(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 跟随播放滚动的歌词：当前句居中高亮；手动滚动后 3 秒内不抢；点某一句跳过去
struct SyncedLyrics: View {
    @ObservedObject private var np = NowPlaying.shared
    @ObservedObject private var lyrics = Lyrics.shared
    @State private var current: Int?
    @State private var userScrolledAt = Date.distantPast
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 120)
                    ForEach(lyrics.lines) { l in
                        let on = l.id == current
                        Text(l.text.isEmpty ? "♪" : l.text)
                            .font(.system(size: on ? 17 : 14, weight: on ? .bold : .regular))
                            .foregroundStyle(on ? Color.white : Color.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                            .onTapGesture { np.seek(to: l.time); current = l.id }
                            .id(l.id)
                            .animation(.easeOut(duration: 0.2), value: on)
                    }
                    Color.clear.frame(height: 120)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { _ in userScrolledAt = Date() })
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in
                userScrolledAt = Date()
            }
            .onReceive(tick) { _ in
                let i = lyrics.index(at: np.position())
                guard i != current else { return }
                current = i
                if let i, Date().timeIntervalSince(userScrolledAt) > 3 {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
            .onAppear {
                current = lyrics.index(at: np.position())
                if let c = current { proxy.scrollTo(c, anchor: .center) }
            }
        }
    }
}
