import AVFoundation
import AppKit
import SwiftUI

/// Скрытый режим для рекламных материалов: `iPodConverter --promo <папка-вывода> <музыка> <видео>`.
/// Открывает своё окно с примерами и снимает его само (разрешение на запись экрана не нужно):
/// вкладки «Музыка» и «Видео», редактор тегов, полоса плеера и кадры полноэкранного плеера для GIF.
/// Настройки пользователя не меняет: всё, что трогает, возвращает как было.
@MainActor
enum Promo {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--promo"), args.count > i + 3 else { return false }
        let out = URL(fileURLWithPath: args[i + 1])
        let music = URL(fileURLWithPath: args[i + 2])
        let videos = URL(fileURLWithPath: args[i + 3])
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { await run(out: out, music: music, videos: videos) }
        return true
    }

    private static func snap(_ view: NSView, _ url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("снимок: \(url.lastPathComponent) \(rep.pixelsWide)×\(rep.pixelsHigh)")
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static func run(out: URL, music: URL, videos: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Не дописывать теги в примеры и не трогать настройки пользователя.
        let fetcher = MetadataFetcher.shared
        let savedFetch = fetcher.enabled, savedStyle = VisualizerSettings.shared.style
        let savedVolume = PlayerController.shared.volume
        fetcher.enabled = false
        let savedLyrics = LyricsStore.shared.visible
        LyricsStore.shared.visible = true
        LyricsView.staticRender = true   // ImageRenderer не рисует прокрутку — строки без неё
        // Не defer: run заканчивается exit(0), а defer при exit не срабатывает — настройки оставались изменёнными
        // (так у пользователя выключилось «Дополнять теги»).
        let restore = {
            LyricsStore.shared.visible = savedLyrics
            fetcher.enabled = savedFetch
            VisualizerSettings.shared.style = savedStyle
            PlayerController.shared.volume = savedVolume
        }

        let store = Store()
        let size = NSSize(width: 1280, height: 800)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: ContentView(store: store).frame(width: size.width, height: size.height))
        win.contentView = host
        win.center()
        win.orderFront(nil)

        // Вкладки подключённых iPod появляются после опроса USB — без них файлы не добавляются.
        IPodDetector.shared.refreshNow()
        var waited = 0.0
        while !store.hasIPod && waited < 6 { await sleep(0.3); waited += 0.3 }
        // Вкладки всех подключённых iPod; добавленные на время съёмки убираем в конце (не defer — run кончается exit).
        var addedTabs: [IPodModel] = []
        for m in IPodDetector.shared.connected where !store.isFavorite(m) { store.toggleFavorite(m); addedTabs.append(m) }
        if !store.hasIPod { store.toggleFavorite(.nano7); addedTabs.append(.nano7) }
        print("вкладки iPod: \(store.favoriteModels.map(\.rawValue)), подключены: \(IPodDetector.shared.devices.map { "\($0.model.rawValue)\($0.ambiguous ? "?" : "")" })")

        // Музыка
        store.add([music])
        let deadline = Date().addingTimeInterval(60)
        while store.tracks.contains(where: { $0.state == .loading }) && Date() < deadline { await sleep(0.3) }
        await sleep(1.5)
        store.section = .music
        await sleep(0.8)
        snap(host, out.appendingPathComponent("1-music.png"))

        // Видео
        store.add([videos])
        store.section = .videos
        while store.items.contains(where: { $0.info == nil }) { await sleep(0.3) }
        await sleep(2.5)
        snap(host, out.appendingPathComponent("2-videos.png"))

        // Редактор тегов (окно-лист)
        store.section = .music
        await sleep(0.5)
        if let t = store.tracks.first(where: { $0.artwork != nil }) ?? store.tracks.first {
            store.editTags(t)
            await sleep(1.2)
            if let sheet = win.attachedSheet, let v = sheet.contentView { snap(v, out.appendingPathComponent("3-tag-editor.png")) }
            store.tagEditTracks = []
            await sleep(0.6)
        }

        // Плеер: тихо, чтобы анализатор получал звук (mute отключает его)
        let pc = PlayerController.shared
        pc.volume = 0.001
        pc.player.volume = 0.001
        // Трек, у которого нашёлся текст в такт (иначе — первый с обложкой).
        for t in store.tracks where t.artwork != nil {
            store.playTrack(t, converted: false)
            await pc.player.seek(to: CMTime(seconds: 50, preferredTimescale: 600))
            var w = 0.0
            while LyricsStore.shared.status == .loading || w < 1 { await sleep(0.5); w += 0.5; if w > 12 { break } }
            if LyricsStore.shared.status == .found, LyricsStore.shared.lyrics?.isSynced == true {
                print("текст песни: \(t.displayTitle)")
                break
            }
        }
        await sleep(1.5)
        snap(host, out.appendingPathComponent("4-player-bar.png"))

        // Полноэкранный плеер: рисуем через ImageRenderer (снимок окна не видит Canvas/TimelineView).
        // Один рендерер на весь ролик — состояние визуализатора (сглаживание, вода) живёт между кадрами.
        let fsSize = CGSize(width: 1280, height: 720)
        for (n, style) in [VisualizerStyle.coverWaves, .waves, .bars].enumerated() {
            VisualizerSettings.shared.style = style
            let r = ImageRenderer(content: FullPlayerView(controller: pc).frame(width: fsSize.width, height: fsSize.height))
            r.scale = 1.5
            let dir = out.appendingPathComponent("frames-\(style.rawValue)", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fps = 20.0
            for f in 0..<Int(fps * 8) {
                let t0 = Date()
                PromoClock.shared.t = Date().timeIntervalSinceReferenceDate
                await sleep(0.012)   // дать рендереру заметить новое время
                if let cg = r.cgImage, f >= Int(fps * 2) {   // первые 2 с — разгон визуализатора
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "%04d.png", f - Int(fps * 2))))
                    if f == Int(fps * 5) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(5 + n)-fullscreen-\(style.rawValue).png"))
                    }
                }
                let left = 1 / fps - Date().timeIntervalSince(t0)
                if left > 0 { await sleep(left) }
            }
            print("кадры: \(style.rawValue)")
            PromoClock.shared.t = nil
        }
        pc.togglePlay()
        restore()
        for m in addedTabs { store.toggleFavorite(m) }
        UserDefaults.standard.synchronize()
        exit(0)
    }
}
