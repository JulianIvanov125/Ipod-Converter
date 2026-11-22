import AVFoundation
import AVKit
import AppKit
import SwiftUI

// MARK: - Что играем

struct PlayEntry: Identifiable, Equatable {
    let id: String
    let url: URL
    let title: String
    let subtitle: String
    let artwork: NSImage?
    let isVideo: Bool
    /// Откуда взять обложку в полном качестве (файл и номер потока с картинкой).
    var coverSource: (url: URL, index: Int)? = nil
    /// Для музыки: что искать в текстах песен.
    var lyrics: LyricsQuery? = nil

    static func == (a: PlayEntry, b: PlayEntry) -> Bool { a.id == b.id }
}

// MARK: - Очередь: порядок, перемешивание, повтор

enum RepeatMode: String, CaseIterable {
    case off, all, one
    var next: RepeatMode { self == .off ? .all : self == .all ? .one : .off }
}

/// Порядок проигрывания. При перемешивании текущий трек остаётся первым, остальные — в случайном порядке;
/// при повторе списка после последнего снова идёт первый (а при перемешивании — новый случайный круг).
struct PlayQueue {
    private(set) var order: [Int] = []
    private(set) var current = 0

    var position: Int { order.firstIndex(of: current) ?? 0 }

    mutating func reset(count: Int, start: Int, shuffle: Bool) {
        current = start
        order = Array(0..<count)
        if shuffle { reshuffle() }
    }

    /// Перемешать всё, кроме текущего (он остаётся на своём месте — первым в новом порядке).
    mutating func reshuffle() {
        order = [current] + order.filter { $0 != current }.shuffled()
    }

    mutating func unshuffle() { order = order.sorted() }

    /// Новый круг при перемешивании: полностью новый порядок, первым — не тот, что только что доиграл.
    mutating func newShuffledRound() -> Int {
        var o = order.shuffled()
        if o.count > 1, o.first == current { o.swapAt(0, Int.random(in: 1..<o.count)) }
        order = o
        current = o.first ?? 0
        return current
    }

    func next(repeatAll: Bool) -> Int? {
        let p = position
        if p + 1 < order.count { return order[p + 1] }
        return repeatAll && !order.isEmpty ? order[0] : nil
    }

    func previous(repeatAll: Bool) -> Int? {
        let p = position
        if p > 0 { return order[p - 1] }
        return repeatAll && !order.isEmpty ? order[order.count - 1] : nil
    }

    var isAtEnd: Bool { position == order.count - 1 }

    mutating func move(to i: Int) { current = i }
}

// MARK: - Плеер

/// Один плеер на всё приложение: мини-окно внизу и полноэкранное окно показывают один и тот же AVPlayer.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    let player = AVPlayer()
    private(set) var entries: [PlayEntry] = []
    private(set) var index = 0
    var current: PlayEntry? { entries.indices.contains(index) ? entries[index] : nil }
    @ObservationIgnored private var queue = PlayQueue()
    var hasPrevious: Bool { queue.previous(repeatAll: repeatMode == .all) != nil }
    var hasNext: Bool { queue.next(repeatAll: repeatMode == .all) != nil }

    /// Повтор: выключен (в конце списка остановиться), весь список по кругу, один трек.
    var repeatMode: RepeatMode {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }
    /// Случайный порядок.
    var shuffle: Bool {
        didSet {
            UserDefaults.standard.set(shuffle, forKey: "shuffle")
            if shuffle { queue.reshuffle() } else { queue.unshuffle() }
        }
    }

    func cycleRepeat() { repeatMode = repeatMode.next }

    /// Громкость 0…1 (общая для видео и треков, запоминается).
    var volume: Float {
        didSet { player.volume = volume; UserDefaults.standard.set(volume, forKey: "playerVolume") }
    }
    /// Без звука (громкость при этом сохраняется).
    var muted: Bool {
        didSet { player.isMuted = muted; UserDefaults.standard.set(muted, forKey: "playerMuted") }
    }

    private(set) var isPlaying = false
    var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isScrubbing = false
    /// Прогресс подготовки копии для просмотра (nil — не готовим).
    private(set) var preparing: Double?
    /// Обложка текущего трека в полном качестве (догружается после старта).
    private(set) var hiResArtwork: NSImage?
    var artwork: NSImage? { hiResArtwork ?? current?.artwork }
    @ObservationIgnored private var hiResCache: [String: NSImage] = [:]
    private(set) var error: String?

    @ObservationIgnored var loadToken = UUID()
    @ObservationIgnored private var prepJob: ConversionJob?
    @ObservationIgnored private var proxies: [URL: URL] = [:]
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// Полноэкранный плеер рисуется поверх главного окна (так он работает и когда окно уже
    /// развёрнуто на отдельный рабочий стол).
    private(set) var isFullscreen = false
    @ObservationIgnored private weak var hostWindow: NSWindow?
    @ObservationIgnored private var weEnteredFullscreen = false
    @ObservationIgnored private var fsObserver: NSObjectProtocol?
    /// Цвета обложки текущего трека (для «волн в цвет обложки»).
    private(set) var palette: CoverColors = CoverPalette.colors(from: nil)

    private init() {
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off
        shuffle = UserDefaults.standard.bool(forKey: "shuffle")
        volume = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 1
        muted = UserDefaults.standard.bool(forKey: "playerMuted")
        player.volume = volume
        player.isMuted = muted
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isScrubbing, t.seconds.isFinite { self.currentTime = t.seconds }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, d != self.duration {
                    self.duration = d
                    NowPlaying.update(self)   // длительность стала известна — обновляем полосу в системе
                }
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    // MARK: Управление

    func play(_ entries: [PlayEntry], startAt i: Int) {
        guard entries.indices.contains(i) else { return }
        self.entries = entries
        queue.reset(count: entries.count, start: i, shuffle: shuffle)
        load(i)
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if player.rate > 0 { player.pause() } else {
            if duration > 0, currentTime >= duration - 0.3 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying = player.rate > 0
        NowPlaying.update(self)
    }

    func next() {
        // Новый круг при перемешивании — новый случайный порядок.
        if queue.isAtEnd && repeatMode == .all && shuffle {
            load(queue.newShuffledRound())
            return
        }
        guard let n = queue.next(repeatAll: repeatMode == .all) else { return }
        load(n)
    }

    func previous() {
        // Как в плеерах: если прошло больше 3 секунд — в начало текущего.
        if currentTime > 3 || !hasPrevious { seek(to: 0) } else if let p = queue.previous(repeatAll: repeatMode == .all) { load(p) }
    }

    /// Трек доиграл до конца.
    private func finished() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            isPlaying = true
        } else if hasNext {
            next()
        } else {
            isPlaying = false   // повтор выключен — в конце списка останавливаемся
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        NowPlaying.update(self)
    }

    func skip(_ delta: Double) { seek(to: min(max(currentTime + delta, 0), max(duration, 0))) }

    func close() {
        loadToken = UUID()
        prepJob?.cancel()
        prepJob = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        entries = []
        LyricsStore.shared.clear()
        preparing = nil
        error = nil
        isPlaying = false
        exitFullscreen()
        NowPlaying.update(self)
    }

    // MARK: Загрузка

    private func load(_ i: Int) {
        index = i
        queue.move(to: i)
        error = nil
        currentTime = 0
        duration = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        prepJob?.cancel()
        prepJob = nil
        let token = UUID()
        loadToken = token
        let entry = entries[i]
        hiResArtwork = hiResCache[entry.id]
        if let q = entry.lyrics { LyricsStore.shared.load(q) } else { LyricsStore.shared.clear() }
        palette = CoverPalette.colors(from: hiResArtwork ?? entry.artwork)
        if hiResArtwork == nil, let src = entry.coverSource {
            Task {
                let img = await FFmpeg.coverThumbnail(src.url, index: src.index, maxSide: 1200)
                guard token == loadToken, let img else { return }
                hiResCache[entry.id] = img
                hiResArtwork = img
                NowPlaying.update(self)
                palette = CoverPalette.colors(from: img)
            }
        }
        Task {
            let url = await playableURL(for: entry, token: token)
            guard token == loadToken else { return }
            preparing = nil
            guard let url else {
                error = error ?? L.previewFailed
                return
            }
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            // Для музыки подключаем анализ спектра (визуализация в полном экране).
            if !entry.isVideo, let track = try? await asset.loadTracks(withMediaType: .audio).first {
                item.audioMix = AudioAnalyzer.shared.makeAudioMix(for: track)
            }
            guard token == loadToken else { return }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finished()
                }
            }
            player.replaceCurrentItem(with: item)
            player.play()
            isPlaying = true
            NowPlaying.update(self)
        }
    }

    /// Файл, который умеет AVPlayer: сам оригинал или временная копия, сделанная ffmpeg.
    func playableURL(for e: PlayEntry, token: UUID) async -> URL? {
        if let p = proxies[e.url], FileManager.default.fileExists(atPath: p.path) { return p }
        let asset = AVURLAsset(url: e.url)
        if (try? await asset.load(.isPlayable)) == true {
            let hasVideo = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
            if !e.isVideo || hasVideo { return e.url }
        }
        guard let ffmpeg = FFmpeg.tool("ffmpeg") else { error = L.toolNotFound("ffmpeg"); return nil }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iPodConverter/preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(e.isVideo ? "mp4" : "m4a")
        preparing = 0

        var attempts: [[String]] = []
        if e.isVideo {
            let info = try? await FFmpeg.probe(e.url)
            let audio = info?.audioStreamIndex.map { ["-map", "0:\($0)"] } ?? ["-map", "0:a:0?"]
            let head = ["-hide_banner", "-nostdin", "-y", "-i", e.url.path, "-map", "0:V:0"] + audio + ["-sn", "-dn"]
            let tail = ["-c:a", "aac", "-b:a", "192k", "-ac", "2", "-movflags", "+faststart", "-f", "mp4",
                        "-progress", "pipe:1", "-nostats", out.path]
            // 1) H.264/HEVC — только переупаковка, секунды.
            if let codec = info?.videoCodec, codec == "H.264" || codec == "HEVC" {
                attempts.append(head + ["-c:v", "copy"] + (codec == "HEVC" ? ["-tag:v", "hvc1"] : []) + tail)
            }
            // 2) Остальное — быстрое аппаратное перекодирование до 720p.
            let deint = (info?.interlaced ?? false) ? "yadif," : ""
            attempts.append(head + ["-vf", "\(deint)scale=-2:'min(720,ih)',format=yuv420p",
                                    "-c:v", "h264_videotoolbox", "-b:v", "3000k"] + tail)
            attempts.append(head + ["-vf", "\(deint)scale=-2:'min(720,ih)',format=yuv420p",
                                    "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23"] + tail)
            duration = info?.duration ?? 0
        } else {
            let info = try? await FFmpeg.probeAudio(e.url)
            attempts.append(["-hide_banner", "-nostdin", "-y", "-i", e.url.path, "-map", "0:a:0", "-vn",
                             "-c:a", FFmpeg.hasAudioToolboxAAC ? "aac_at" : "aac", "-b:a", "256k", "-ac", "2",
                             "-f", "ipod", "-progress", "pipe:1", "-nostats", out.path])
            duration = info?.duration ?? 0
        }

        let total = duration
        for args in attempts {
            guard token == loadToken else { return nil }
            let ok: Bool = await withCheckedContinuation { cont in
                let job = ConversionJob()
                prepJob = job
                do {
                    try job.start(
                        ffmpeg: ffmpeg, args: args, duration: total,
                        progress: { p in Task { @MainActor in if token == self.loadToken { self.preparing = p } } },
                        completion: { status, _ in cont.resume(returning: status == 0 && !job.cancelled) }
                    )
                } catch { cont.resume(returning: false) }
            }
            if ok {
                proxies[e.url] = out
                return out
            }
        }
        try? FileManager.default.removeItem(at: out)
        return nil
    }

    // MARK: Полный экран

    func openFullscreen() {
        guard current != nil, !isFullscreen else { return }
        let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        hostWindow = w
        isFullscreen = true
        guard let w else { return }
        if w.styleMask.contains(.fullScreen) {
            weEnteredFullscreen = false   // окно уже на своём рабочем столе — просто показываем плеер поверх
        } else {
            weEnteredFullscreen = true
            w.toggleFullScreen(nil)
        }
        if let fsObserver { NotificationCenter.default.removeObserver(fsObserver) }
        // Вышли из полного экрана зелёной кнопкой/жестом — убираем и плеер.
        fsObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isFullscreen, self.weEnteredFullscreen else { return }
                self.weEnteredFullscreen = false
                self.isFullscreen = false
            }
        }
    }

    func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        // Возвращаем окно как было, только если в полный экран его переводили мы.
        if weEnteredFullscreen, let w = hostWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        weEnteredFullscreen = false
    }

}

// MARK: - Видео-поверхность

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

// MARK: - Общие кнопки и перемотка

struct PlayerControls: View {
    @Bindable var controller: PlayerController
    var dark = false
    var fullscreen = false

    var body: some View {
        VStack(spacing: 6) {
            scrubber
            HStack(spacing: 18) {
                Spacer()
                ModeButton(icon: "shuffle", active: controller.shuffle, size: 12, dark: dark,
                           help: controller.shuffle ? L.shuffleOn : L.shuffleOff) { controller.shuffle.toggle() }
                button("backward.fill", L.previousItem, size: 14) { controller.previous() }
                button(controller.isPlaying ? "pause.fill" : "play.fill",
                       controller.isPlaying ? L.pause : L.playWord, size: 20) { controller.togglePlay() }
                    .disabled(controller.preparing != nil)
                button("forward.fill", L.nextItem, size: 14) { controller.next() }
                    .disabled(!controller.hasNext)
                ModeButton(icon: controller.repeatMode == .one ? "repeat.1" : "repeat",
                           active: controller.repeatMode != .off, size: 12, dark: dark,
                           help: L.repeatHelp(controller.repeatMode)) { controller.cycleRepeat() }
                Spacer()
                VolumeControl(controller: controller, dark: dark)
                if fullscreen {
                    button("arrow.down.right.and.arrow.up.left", L.exitFullscreen, size: 13) { controller.exitFullscreen() }
                } else {
                    button("arrow.up.left.and.arrow.down.right", L.fullscreen, size: 13) { controller.openFullscreen() }
                }
            }
        }
        .foregroundStyle(dark ? Color.white : Color.primary)
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(Fmt.duration(controller.currentTime))
            Slider(
                value: Binding(get: { controller.currentTime }, set: { controller.currentTime = $0 }),
                in: 0...max(controller.duration, 0.1)
            ) { editing in
                controller.isScrubbing = editing
                if !editing { controller.seek(to: controller.currentTime) }
            }
            .controlSize(.mini)
            .disabled(controller.duration <= 0)
            Text(Fmt.duration(controller.duration))
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(dark ? Color.white.opacity(0.8) : Color.secondary)
    }

    private func button(_ icon: String, _ help: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Громкость: значок динамика (клик — без звука) и ползунок.
struct VolumeControl: View {
    @Bindable var controller: PlayerController
    var dark = false

    private var icon: String {
        if controller.muted || controller.volume == 0 { return "speaker.slash.fill" }
        return controller.volume < 0.34 ? "speaker.wave.1.fill" : controller.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if controller.volume == 0 { controller.volume = 0.5; controller.muted = false }
                else { controller.muted.toggle() }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.muted ? L.unmute : L.mute)
            Slider(value: Binding(get: { Double(controller.muted ? 0 : controller.volume) },
                                  set: { controller.volume = Float($0); if $0 > 0 { controller.muted = false } }),
                   in: 0...1)
                .controlSize(.mini)
                .frame(width: 80)
                .help(L.volume)
        }
        .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.secondary)
    }
}

// MARK: - Мини-плеер снизу

struct MiniPlayer: View {
    @Bindable var controller: PlayerController

    var body: some View {
        // Мини-окно — только для видео; музыка играет в полосе внизу (MusicPlayerBar).
        if let e = controller.current, e.isVideo {
            VStack(alignment: .leading, spacing: 8) {
                if e.isVideo {
                    ZStack {
                        Color.black
                        if controller.preparing == nil && controller.error == nil {
                            VideoSurface(player: controller.player)
                        }
                        overlayState
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture(count: 2) { controller.openFullscreen() }
                    .onTapGesture { controller.togglePlay() }
                }
                HStack(spacing: 10) {
                    if !e.isVideo {
                        artwork(e).frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(e.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button(action: controller.close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.tint(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(L.closePlayer)
                }
                if !e.isVideo { overlayState }
                PlayerControls(controller: controller)
            }
            .padding(12)
            .frame(width: 340)
            .clearGlass(in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(GlassMode.isOn ? 0.12 : 0.18), radius: 18, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var overlayState: some View {
        if let p = controller.preparing {
            VStack(spacing: 6) {
                ProgressView(value: p).frame(width: 160)
                Text("\(L.preparingPreview) \(Int(p * 100))%").font(.system(size: 11))
            }
            .foregroundStyle(controller.current?.isVideo == true ? Color.white : Color.secondary)
        } else if let err = controller.error {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    private func artwork(_ e: PlayEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.tint(0.06))
            if let a = controller.artwork {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Кнопки режимов

/// Перемешивание / повтор: подсвечена, когда режим включён.
struct ModeButton: View {
    let icon: String
    let active: Bool
    var size: CGFloat = 12
    var dark = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: active ? .bold : .regular))
                .foregroundStyle(active ? Color.accentColor : (dark ? Color.white.opacity(0.55) : Color.secondary))
                .frame(width: size + 16, height: size + 12)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(active ? 0.15 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// «Текст»: активна, только если текст песни нашёлся; открывает полный экран с текстом.
struct LyricsButton: View {
    @Bindable var controller: PlayerController
    @Bindable private var lyrics = LyricsStore.shared

    var body: some View {
        let has = lyrics.status == .found
        Button {
            lyrics.visible = true
            controller.openFullscreen()
        } label: {
            Image(systemName: has ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 14))
                .foregroundStyle(has ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!has)
        .help(lyrics.status == .loading ? L.lyricsSearching : has ? L.showLyricsNow : L.lyricsNotFound)
    }
}

// MARK: - Полоса плеера для музыки (в духе Apple Music)

struct MusicPlayerBar: View {
    @Bindable var controller: PlayerController
    @State private var hoverArt = false

    var body: some View {
        if let e = controller.current, !e.isVideo {
            HStack(spacing: 20) {
                // Слева: большая обложка, название, артист
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.tint(0.08))
                        if let a = controller.artwork {
                            Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.secondary)
                        }
                        if hoverArt {
                            Color.black.opacity(0.35)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    .onHover { hoverArt = $0 }
                    .onTapGesture { controller.openFullscreen() }
                    .help(L.fullscreen)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(e.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Центр: кнопки и перемотка
                VStack(spacing: 6) {
                    HStack(spacing: 26) {
                        ModeButton(icon: "shuffle", active: controller.shuffle, size: 13,
                                   help: controller.shuffle ? L.shuffleOn : L.shuffleOff) { controller.shuffle.toggle() }
                        barButton("backward.fill", L.previousItem, 17) { controller.previous() }
                        barButton(controller.isPlaying ? "pause.fill" : "play.fill",
                                  controller.isPlaying ? L.pause : L.playWord, 26) { controller.togglePlay() }
                            .disabled(controller.preparing != nil)
                        barButton("forward.fill", L.nextItem, 17) { controller.next() }
                            .disabled(!controller.hasNext)
                        ModeButton(icon: controller.repeatMode == .one ? "repeat.1" : "repeat",
                                   active: controller.repeatMode != .off, size: 13,
                                   help: L.repeatHelp(controller.repeatMode)) { controller.cycleRepeat() }
                    }
                    if let p = controller.preparing {
                        HStack(spacing: 8) {
                            ProgressView(value: p).controlSize(.mini)
                            Text("\(L.preparingPreview) \(Int(p * 100))%").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    } else if let err = controller.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
                    } else {
                        scrubber
                    }
                }
                .frame(width: 460)

                // Справа: полный экран и закрыть
                HStack(spacing: 14) {
                    VolumeControl(controller: controller)
                    LyricsButton(controller: controller)
                    barButton("arrow.up.left.and.arrow.down.right", L.fullscreen, 14) { controller.openFullscreen() }
                    barButton("xmark", L.closePlayer, 13) { controller.close() }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .clearGlass(in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(Fmt.duration(controller.currentTime)).frame(width: 40, alignment: .trailing)
            Slider(
                value: Binding(get: { controller.currentTime }, set: { controller.currentTime = $0 }),
                in: 0...max(controller.duration, 0.1)
            ) { editing in
                controller.isScrubbing = editing
                if !editing { controller.seek(to: controller.currentTime) }
            }
            .controlSize(.small)
            .disabled(controller.duration <= 0)
            Text("-" + Fmt.duration(max(controller.duration - controller.currentTime, 0))).frame(width: 44, alignment: .leading)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func barButton(_ icon: String, _ help: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .frame(width: size + 14, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Полноэкранный плеер

struct FullPlayerView: View {
    @Bindable var controller: PlayerController
    @Bindable private var viz = VisualizerSettings.shared
    @State private var showControls = true
    @State private var hideTask: DispatchWorkItem?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let e = controller.current {
                if e.isVideo {
                    if controller.preparing == nil { VideoSurface(player: controller.player).ignoresSafeArea() }
                } else {
                    musicScene
                }
                if let p = controller.preparing {
                    VStack(spacing: 8) {
                        ProgressView(value: p).frame(width: 260).tint(.white)
                        Text("\(L.preparingPreview) \(Int(p * 100))%").foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if showControls, let e = controller.current {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            Text(e.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        if !e.isVideo {
                            HStack(spacing: 14) {
                                LyricsMenu()
                                VisualizerStylePicker()
                            }
                        }
                    }
                    PlayerControls(controller: controller, dark: true, fullscreen: true)
                }
                .padding(20)
                .frame(maxWidth: 720)
                .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
                .padding(.bottom, 40)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { _ in poke() }
        .onTapGesture { controller.togglePlay(); poke() }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) { controller.exitFullscreen(); return .handled }
        .onKeyPress(.space) { controller.togglePlay(); poke(); return .handled }
        .onKeyPress(.leftArrow) { controller.skip(-10); poke(); return .handled }
        .onKeyPress(.rightArrow) { controller.skip(10); poke(); return .handled }
        .onAppear { poke(); focused = true }
    }

    /// Музыка: фон в цвет обложки, обложка и визуализация под ритм.
    private var musicScene: some View {
        GeometryReader { geo in
            ZStack {
                if viz.style == .bars {
                    // Эквалайзер — только нижняя полоса экрана, ниже обложки и текста
                    VStack {
                        Spacer()
                        AudioVisualizer(style: viz.style, colors: controller.palette)
                            .frame(height: min(geo.size.height * 0.26, 300))
                            .opacity(LyricsStore.shared.visible ? 0.6 : 0.9)
                    }
                } else {
                    // Капли и цвета обложки — на весь экран, за обложкой
                    AudioVisualizer(style: viz.style, colors: controller.palette)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if LyricsStore.shared.visible {
                    HStack(spacing: geo.size.width * 0.05) {
                        Group {
                            if let a = controller.artwork {
                                Image(nsImage: a).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
                            } else {
                                Image(systemName: "music.note").font(.system(size: 120)).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .frame(maxWidth: min(geo.size.width * 0.32, 520), maxHeight: min(geo.size.height * 0.5, 520))
                        LyricsView(controller: controller)
                            .frame(maxWidth: geo.size.width * 0.5, maxHeight: geo.size.height * 0.72)
                    }
                    .padding(.horizontal, geo.size.width * 0.06)
                    // место под кнопки, а при эквалайзере — под его полосу
                    .padding(.bottom, viz.style == .bars ? max(140, min(geo.size.height * 0.26, 300)) : 140)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                // Обложка — сверху по центру
                VStack {
                    Group {
                        if let a = controller.artwork {
                            Image(nsImage: a).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
                        } else {
                            Image(systemName: "music.note").font(.system(size: 120)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: min(geo.size.height * 0.42, 520), maxHeight: min(geo.size.height * 0.42, 520))
                    .padding(.top, geo.size.height * 0.08)
                    Spacer()
                }
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Показать кнопки и спрятать через 3 секунды без движения мыши.
    private func poke() {
        withAnimation(.easeOut(duration: 0.15)) { showControls = true }
        hideTask?.cancel()
        let task = DispatchWorkItem {
            if controller.isPlaying { withAnimation(.easeIn(duration: 0.4)) { showControls = false } }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }
}
