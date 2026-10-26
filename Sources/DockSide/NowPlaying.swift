import AppKit
import SwiftUI

/// 正在播放：通过系统私有框架 MediaRemote 读取（和控制中心一样，Music、Spotify、浏览器视频都能读到）
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published var title = ""
    @Published var artist = ""
    @Published var artwork: NSImage?
    @Published var playing = false
    @Published var duration: Double = 0
    // 播放进度：elapsed 是 elapsedAt 那一刻的位置，之后按 rate 往前推
    private(set) var elapsed: Double = 0
    private(set) var elapsedAt = Date()
    private(set) var rate: Double = 0

    /// 现在播到第几秒
    func position(at now: Date = Date()) -> Double {
        guard playing else { return elapsed }
        return elapsed + now.timeIntervalSince(elapsedAt) * max(rate, 1)
    }

    var hasTrack: Bool { !title.isEmpty }

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias GetPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias SendFn = @convention(c) (UInt32, NSDictionary?) -> Bool

    private var getInfo: GetInfoFn?
    private var getPlaying: GetPlayingFn?
    private var send: SendFn?
    private typealias SeekFn = @convention(c) (Double) -> Void
    private var seekFn: SeekFn?
    private var timer: Timer?
    private var lastArtworkKey = ""
    private var lyricsKey = ""

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let h = dlopen(path, RTLD_NOW) else { return }
        if let p = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") { getInfo = unsafeBitCast(p, to: GetInfoFn.self) }
        if let p = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") { getPlaying = unsafeBitCast(p, to: GetPlayingFn.self) }
        if let p = dlsym(h, "MRMediaRemoteSendCommand") { send = unsafeBitCast(p, to: SendFn.self) }
        if let p = dlsym(h, "MRMediaRemoteSetElapsedTime") { seekFn = unsafeBitCast(p, to: SeekFn.self) }
    }

    /// 有组件显示时才轮询
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        getInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let d = info as? [String: Any] ?? [:]
            let t = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let a = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            if t != self.title { self.title = t }
            if a != self.artist { self.artist = a }
            let key = t + "|" + a
            if key != self.lastArtworkKey {
                if let data = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, let img = NSImage(data: data) {
                    self.artwork = img
                    self.lastArtworkKey = key
                } else if t.isEmpty {
                    self.artwork = nil
                    self.lastArtworkKey = key
                }
            }
            let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            if self.getPlaying == nil { self.playing = rate > 0 }
            self.rate = rate
            if let e = d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double {
                self.elapsed = e
                self.elapsedAt = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
            }
            let dur = d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            if dur != self.duration { self.duration = dur }
            if key != self.lyricsKey {
                self.lyricsKey = key
                Lyrics.shared.load(title: t, artist: a, duration: dur)
            }
        }
        getPlaying?(DispatchQueue.main) { [weak self] p in
            if self?.playing != p { self?.playing = p }
        }
    }

    // MediaRemote 命令：0 播放 1 暂停 2 切换 4 下一首 5 上一首
    func toggle()   { command(2); playing.toggle() }
    func next()     { command(4) }
    func previous() { command(5) }
    func seek(to t: Double) {
        seekFn?(t)
        elapsed = t; elapsedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    private func command(_ c: UInt32) {
        _ = send?(c, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }
}

struct NowPlayingWidget: View {
    @ObservedObject private var np = NowPlaying.shared
    @Environment(\.widgetFontSize) private var size
    @Environment(\.compact) private var compact
    @AppStorage(Pref.musicTitleChars) private var titleChars = 7
    @AppStorage(Pref.musicShowCover) private var showCover = true
    @AppStorage(Pref.musicShowArtist) private var showArtist = true
    @AppStorage(Pref.musicShowButtons) private var showButtons = true
    @Environment(\.measuring) private var measuring

    var body: some View {
        Group {
            if compact {
                VStack(spacing: size * 0.25) {
                    cover(size * 1.6)
                    Image(systemName: np.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.8))
                        .contentShape(Rectangle())
                        .onTapGesture { np.toggle() }
                }
            } else {
                HStack(spacing: size * 0.5) {
                    if showCover { cover(size * 2.2) }
                    VStack(alignment: .leading, spacing: size * 0.05) {
                        let w = size * 0.95 * CGFloat(titleChars)
                        if np.hasTrack {
                            Marquee(text: np.title, width: w, fontSize: size * 0.95)
                            if showArtist, !np.artist.isEmpty {
                                Marquee(text: np.artist, width: w, fontSize: size * 0.72, semibold: false)
                                    .opacity(0.7)
                            }
                        } else {
                            Text("未在播放").font(.system(size: size * 0.95, weight: .semibold, design: .rounded))
                                .opacity(0.6)
                                .frame(width: w, alignment: .leading)
                        }
                    }
                    if showButtons, np.hasTrack {
                        HStack(spacing: size * 0.6) {
                            button(np.playing ? "pause.fill" : "play.fill", help: np.playing ? "暂停" : "播放") { np.toggle() }
                            button("forward.fill", help: "下一首") { np.next() }
                        }
                    }
                }
            }
        }
        .modifier(WidgetText())
        .contextMenu {
            Button("上一首") { np.previous() }
            Button(np.playing ? "暂停" : "播放") { np.toggle() }
            Button("下一首") { np.next() }
        }
        .onAppear { if !measuring { np.start() } }
        .onHover { inside in
            guard !measuring else { return }
            if inside { LyricsPopover.shared.show() } else { LyricsPopover.shared.scheduleHide() }
        }
    }

    @ViewBuilder
    private func cover(_ s: CGFloat) -> some View {
        Group {
            if let img = np.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: s * 0.45, weight: .semibold))
                }
            }
        }
        .frame(width: s, height: s)
        .clipShape(RoundedRectangle(cornerRadius: s * 0.22, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { np.toggle() }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.95))
            .contentShape(Rectangle().inset(by: -4))
            .onTapGesture(perform: action)
            .help(help)
    }
}
