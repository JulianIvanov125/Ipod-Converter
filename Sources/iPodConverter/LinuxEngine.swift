#if !os(macOS)
import Foundation

/// Состояние файла в списке Linux-версии.
enum LinuxItemState: Equatable {
    case loading
    case ready
    case queued
    case converting(Double)
    case done(URL)
    case kept(URL)          // трек уже подходит iPod — скопирован как есть
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .queued, .converting: true
        default: false
        }
    }
}

@MainActor
final class LinuxVideo: VideoDupItem {
    let id = UUID()
    let url: URL
    var info: MediaInfo?
    var meta: VideoMeta?
    var cover: URL?
    /// Готовый файл, перечитанный после конвертации, — для «было → стало».
    var outInfo: MediaInfo?
    var state: LinuxItemState = .loading
    var checked = true
    init(url: URL) { self.url = url }
}

@MainActor
final class LinuxTrack {
    let id = UUID()
    let url: URL
    var info: AudioInfo?
    var outInfo: AudioInfo?
    var state: LinuxItemState = .loading
    var checked = true
    init(url: URL) { self.url = url }
}

/// Модель Linux-версии: списки, разбор файлов, очередь конвертации. Без «Музыки»/iTunes —
/// готовые файлы складываются в папку, на iPod их переносит пользователь (Rhythmbox, gtkpod, Strawberry).
@MainActor
final class LinuxEngine {
    var model: IPodModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "linux.model"); Self.save() }
    }
    var maxQuality: Bool {
        didSet { UserDefaults.standard.set(maxQuality, forKey: "maxQuality"); Self.save() }
    }
    var outputRoot: URL {
        didSet { UserDefaults.standard.set(outputRoot.path, forKey: "rootFolder"); Self.save() }
    }
    private(set) var videos: [LinuxVideo] = []
    private(set) var tracks: [LinuxTrack] = []
    var videoDupKeep: [String: UUID] = [:]
    private(set) var running = false
    private var cancelRequested = false
    private var current: ConversionJob?

    /// На Linux UserDefaults пишутся на диск не сами по себе — сохраняем сразу (иначе выбор iPod терялся).
    nonisolated static func save() { UserDefaults.standard.synchronize() }

    /// Перерисовать интерфейс (вызывается на главном потоке).
    var onChange: (() -> Void)?

    init() {
        let d = UserDefaults.standard
        model = d.string(forKey: "linux.model").flatMap(IPodModel.init(rawValue:)) ?? .classic55G
        maxQuality = d.object(forKey: "maxQuality") as? Bool ?? false
        let home = FileManager.default.homeDirectoryForCurrentUser
        outputRoot = d.string(forKey: "rootFolder").map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Videos", isDirectory: true)
    }

    var videoRoot: URL { outputRoot.appendingPathComponent("iPod Converter Video", isDirectory: true) }
    var musicRoot: URL { outputRoot.appendingPathComponent("iPod Converter Music", isDirectory: true) }
    var settings: EncodeSettings { model.settings(max: maxQuality) }

    // MARK: Добавление

    /// Файлы и папки (папки раскрываются рекурсивно; берём только аудио и видео).
    func add(_ urls: [URL]) {
        var newVideos: [LinuxVideo] = []
        var newTracks: [LinuxTrack] = []
        let known = Set(videos.map(\.url.path) + tracks.map(\.url.path))
        for f in Self.expand(urls) where !known.contains(f.path) {
            let e = f.pathExtension.lowercased()
            if AudioRules.audioExtensions.contains(e) { newTracks.append(LinuxTrack(url: f)) }
            else if MediaKinds.videoExtensions.contains(e) { newVideos.append(LinuxVideo(url: f)) }
        }
        videos += newVideos
        tracks += newTracks
        onChange?()
        Task { await load(newVideos, newTracks) }
    }

    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                    .allObjects as? [URL]) ?? []
                out += items.filter {
                    let e = $0.pathExtension.lowercased()
                    return AudioRules.audioExtensions.contains(e) || MediaKinds.videoExtensions.contains(e)
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else {
                out.append(u)
            }
        }
        return out
    }

    private func load(_ vs: [LinuxVideo], _ ts: [LinuxTrack]) async {
        for v in vs {
            do {
                let info = try await FFmpeg.probe(v.url)
                v.info = info
                v.meta = VideoClassifier.guess(url: v.url, info: info)
                if let jpeg = await FFmpeg.preview(v.url, info: info) {
                    let f = FileManager.default.temporaryDirectory
                        .appendingPathComponent("iPodConverter", isDirectory: true)
                        .appendingPathComponent("\(v.id.uuidString).jpg")
                    try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? jpeg.write(to: f)) != nil { v.cover = f }
                }
                v.state = .ready
            } catch {
                v.state = .failed(error.localizedDescription)
            }
            onChange?()
        }
        for t in ts {
            do {
                t.info = try await FFmpeg.probeAudio(t.url)
                t.state = .ready
            } catch {
                t.state = .failed(error.localizedDescription)
            }
            onChange?()
        }
    }

    // MARK: Удаление и дубликаты

    func remove(video v: LinuxVideo) { videos.removeAll { $0.id == v.id }; onChange?() }
    func remove(track t: LinuxTrack) { tracks.removeAll { $0.id == t.id }; onChange?() }
    func clear() { guard !running else { return }; videos = []; tracks = []; videoDupKeep = [:]; onChange?() }

    var videoDuplicateGroups: [VideoDuplicateGroup<LinuxVideo>] {
        DuplicateFinder.videoGroups(videos, keep: videoDupKeep)
    }

    func keepDuplicate(_ v: LinuxVideo) {
        guard let g = videoDuplicateGroups.first(where: { $0.all.contains { $0.id == v.id } }) else { return }
        videoDupKeep[g.key] = v.id
        onChange?()
    }

    /// Лишние копии — в Корзину (freedesktop). Оставляемый файл группы не трогаем никогда.
    @discardableResult
    func trashDuplicates(_ list: [LinuxVideo]) -> (moved: Int, failed: [String]) {
        let groups = videoDuplicateGroups
        let extras = Set(groups.flatMap(\.extras).map(\.id))
        let keepers = Set(groups.map(\.keeper.id))
        var moved = 0
        var failed: [String] = []
        for v in list where extras.contains(v.id) && !keepers.contains(v.id) && !v.state.isBusy {
            do {
                try Self.trash(v.url)
                videos.removeAll { $0.id == v.id }
                moved += 1
            } catch {
                failed.append("\(v.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        onChange?()
        return (moved, failed)
    }

    /// Корзина по спецификации freedesktop: gio trash (есть в GNOME/KDE), иначе ~/.local/share/Trash вручную.
    nonisolated static func trash(_ url: URL) throws {
        #if os(Windows)
        try WindowsShell.recycle(url)
        return
        #else
        if let gio = ["/usr/bin/gio", "/bin/gio"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gio)
            p.arguments = ["trash", url.path]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
        }
        let fm = FileManager.default
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/Trash", isDirectory: true)
        let files = trash.appendingPathComponent("files", isDirectory: true)
        let infoDir = trash.appendingPathComponent("info", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try fm.createDirectory(at: infoDir, withIntermediateDirectories: true)
        let base = url.lastPathComponent
        var name = base
        var n = 2
        while fm.fileExists(atPath: files.appendingPathComponent(name).path) { name = "\(n) \(base)"; n += 1 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let info = "[Trash Info]\nPath=\(path)\nDeletionDate=\(f.string(from: Date()))\n"
        try info.write(to: infoDir.appendingPathComponent(name + ".trashinfo"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: url, to: files.appendingPathComponent(name))
        #endif
    }

    // MARK: Конвертация

    /// Отмеченные и готовые к конвертации.
    var pending: (videos: [LinuxVideo], tracks: [LinuxTrack]) {
        func ok(_ s: LinuxItemState) -> Bool {
            switch s { case .ready, .failed, .done, .kept: true; default: false }
        }
        return (videos.filter { $0.checked && $0.info != nil && ok($0.state) },
                tracks.filter { $0.checked && $0.info != nil && ok($0.state) })
    }

    func cancel() {
        cancelRequested = true
        current?.cancel()
    }

    /// Конвертирует отмеченное по очереди. Возвращает (готово, ошибок).
    @discardableResult
    func convertAll() async -> (done: Int, failed: Int) {
        guard !running, let ffmpeg = FFmpeg.tool("ffmpeg") else { return (0, 0) }
        let (vs, ts) = pending
        guard !vs.isEmpty || !ts.isEmpty else { return (0, 0) }
        running = true
        cancelRequested = false
        for v in vs { v.state = .queued }
        for t in ts { t.state = .queued }
        onChange?()
        var done = 0, failed = 0
        for t in ts where !cancelRequested {
            if await convert(t, ffmpeg: ffmpeg) { done += 1 } else if case .failed = t.state { failed += 1 }
        }
        for v in vs where !cancelRequested {
            if await convert(v, ffmpeg: ffmpeg) { done += 1 } else if case .failed = v.state { failed += 1 }
        }
        for v in vs where v.state == .queued { v.state = .ready }
        for t in ts where t.state == .queued { t.state = .ready }
        running = false
        current = nil
        onChange?()
        AppLog.info("Linux batch for \(model.rawValue): \(done) done, \(failed) failed")
        return (done, failed)
    }

    private func convert(_ v: LinuxVideo, ffmpeg: String) async -> Bool {
        guard let info = v.info else { return false }
        let meta = v.meta ?? VideoMeta(category: .film, title: v.url.deletingPathExtension().lastPathComponent)
        let s = settings
        let (folder, base) = OutputNaming.destination(for: meta, videoRoot: videoRoot, fallback: v.url)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = OutputNaming.uniqueURL(in: folder, base: "\(base) [\(model.fileSuffix)]", ext: s.container.rawValue)
        v.state = .converting(0)
        onChange?()
        // На Linux нет кодера Apple — звук готовим отдельно, без перегруза (иначе на iPod треск).
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("iPodConverter", isDirectory: true)
        let audio = FFmpeg.hasAudioToolboxAAC ? nil
            : await FFmpeg.preparePeakSafeAudio(input: v.url, info: info, settings: s, workDir: work)
        defer { if let audio { try? FileManager.default.removeItem(at: audio) } }
        let args = FFmpeg.arguments(input: v.url, output: output, info: info, settings: s,
                                    cover: v.cover, meta: meta, ipod: model.playlistName, preparedAudio: audio)
        let (status, err) = await run(ffmpeg, args, duration: info.duration) { p in v.state = .converting(p) }
        if status == 0 && !cancelRequested {
            v.outInfo = try? await FFmpeg.probe(output)
            v.state = .done(output)
            onChange?()
            return true
        }
        try? FileManager.default.removeItem(at: output)
        v.state = cancelRequested ? .ready : .failed(FFmpeg.ffmpegOutputLine(err))
        if !cancelRequested { AppLog.error("Video convert failed: \(v.url.path) — \(AppLog.ffmpegTail(err))") }
        onChange?()
        return false
    }

    private func convert(_ t: LinuxTrack, ffmpeg: String) async -> Bool {
        guard let info = t.info else { return false }
        let plan = AudioRules.plan(for: info, model: model)
        try? FileManager.default.createDirectory(at: musicRoot, withIntermediateDirectories: true)
        let ext = plan == .compatible ? t.url.pathExtension.lowercased() : plan.ext
        let output = OutputNaming.uniqueURL(in: musicRoot, base: t.url.deletingPathExtension().lastPathComponent, ext: ext)
        if plan == .compatible {
            // Уже играет на iPod — просто копия без перекодирования (без потерь).
            do {
                try FileManager.default.copyItem(at: t.url, to: output)
                t.state = .kept(output)
                onChange?()
                return true
            } catch {
                t.state = .failed(error.localizedDescription)
                onChange?()
                return false
            }
        }
        let args = FFmpeg.audioArguments(input: t.url, output: output, info: info, plan: plan)
        t.state = .converting(0)
        onChange?()
        let (status, err) = await run(ffmpeg, args, duration: info.duration) { p in t.state = .converting(p) }
        if status == 0 && !cancelRequested {
            t.outInfo = try? await FFmpeg.probeAudio(output)
            t.state = .done(output)
            onChange?()
            return true
        }
        try? FileManager.default.removeItem(at: output)
        t.state = cancelRequested ? .ready : .failed(FFmpeg.ffmpegOutputLine(err))
        onChange?()
        return false
    }

    /// Запуск ffmpeg с прогрессом; ждём окончания без блокировки главного потока.
    private func run(_ ffmpeg: String, _ args: [String], duration: Double,
                     progress: @escaping @MainActor (Double) -> Void) async -> (Int32, String) {
        let job = ConversionJob()
        current = job
        return await withCheckedContinuation { cont in
            do {
                try job.start(ffmpeg: ffmpeg, args: args, duration: duration,
                              progress: { p in Task { @MainActor in progress(p); self.onChange?() } },
                              completion: { status, err in cont.resume(returning: (status, err)) })
            } catch {
                cont.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
#endif
