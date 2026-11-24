#if !os(macOS)
import Foundation

/// Точка входа Linux-версии. Без аргументов — окно (GTK); с командой — консольный режим:
///   iPodConverter convert --ipod nano7 [--max] [--out ПАПКА] файлы-или-папки…
///   iPodConverter dups [--trash] файлы-или-папки…   (--trash — лишние копии в Корзину)
///   convert … --itunes — на Windows добавить готовые файлы в iTunes и в плейлист iPod
///   iPodConverter models
@main
enum LinuxMain {
    static func main() {
        #if os(Windows)
        // MSVC CRT: _IOLBF с размером 0 — недопустимый параметр, процесс падает (0xC0000409). Без буфера.
        setvbuf(stdout, nil, _IONBF, 0)
        #else
        setvbuf(stdout, nil, _IOLBF, 0)
        #endif
        let args = Array(CommandLine.arguments.dropFirst())
        // Движок для окна WinUI: команды в stdin, состояние в stdout (JSON-строки).
        if args.first == "serve" { EngineServer.run() }
        // Без команды или с путями к файлам («Открыть с помощью») — окно.
        guard let cmd = args.first, ["convert", "dups", "models", "update", "version"].contains(cmd) else {
            #if os(Windows)
            WindowsApp.run(files: args.map { URL(fileURLWithPath: $0) })
            #else
            LinuxApp.run(files: args.map { URL(fileURLWithPath: $0) })
            #endif
            return
        }
        Task { @MainActor in
            let code = await runCommand(cmd, Array(args.dropFirst()))
            _ = AppLog.tail(0)   // дождаться записи журнала
            LinuxEngine.save()
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    static func runCommand(_ cmd: String, _ rest: [String]) async -> Int32 {
        switch cmd {
        case "version":
            print(AppVersion.current)
            return 0
        #if os(Linux)
        case "update":
            // ipod-converter update [--install]: проверить новую версию и, с --install, поставить её.
            guard let r = await LinuxUpdater.shared.check() else {
                print("Up to date (\(AppVersion.current))"); return 0
            }
            print("Available: \(r.version) (current \(AppVersion.current)), install kind: \(LinuxUpdater.kind)")
            guard rest.contains("--install") else { print("Run with --install to update."); return 0 }
            do {
                switch try await LinuxUpdater.shared.install(r) {
                case .restarted: return 0
                case .openedInstaller(let f): print("Opened the installer for \(f.path)")
                case .openedPage(let u): print("Opened \(u.absoluteString)")
                }
                return 0
            } catch {
                print("Update failed: \(error.localizedDescription)"); return 1
            }
        #endif
        case "models":
            for m in IPodModel.allCases {
                let s = m.settings(max: false)
                print("\(m.rawValue)\t\(m.title)\t\(s.w)×\(s.h)" + (m.supportsMax ? "\tmax \(m.settings(max: true).w)×\(m.settings(max: true).h)" : ""))
            }
            return 0
        case "convert", "dups":
            let engine = LinuxEngine(persist: false)   // флаги консоли не меняют настройки окна
            var paths: [URL] = []
            var toITunes = false, trash = false
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--ipod":
                    i += 1
                    guard i < rest.count, let m = IPodModel(rawValue: rest[i]) else {
                        print("Unknown iPod. Run: iPodConverter models"); return 2
                    }
                    engine.model = m
                case "--max": engine.maxQuality = true
                case "--standard": engine.maxQuality = false
                case "--itunes": toITunes = true
                case "--trash": trash = true
                case "--out":
                    i += 1
                    guard i < rest.count else { return 2 }
                    engine.outputRoot = URL(fileURLWithPath: rest[i])
                default: paths.append(URL(fileURLWithPath: rest[i]))
                }
                i += 1
            }
            guard !paths.isEmpty else { print("No files given"); return 2 }
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0.path) }
            for m in missing { print("✗ Not found: \(m.path)") }
            engine.add(paths)
            while engine.videos.contains(where: { $0.state == .loading }) || engine.tracks.contains(where: { $0.state == .loading }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Ничего не нашлось (неверный путь, пустая папка) — это ошибка, а не «всё готово».
            guard !engine.videos.isEmpty || !engine.tracks.isEmpty else { print("No audio or video files found"); return 2 }
            if cmd == "dups" {
                let groups = engine.videoDuplicateGroups
                print("videos: \(engine.videos.count), duplicate groups: \(groups.count)")
                for g in groups {
                    print("• \(g.key)")
                    for v in g.all {
                        let i = v.info!
                        print("   \(v.id == g.keeper.id ? "KEEP" : "copy") \(i.displayWidth)×\(i.displayHeight) \(i.videoCodec) — \(v.url.lastPathComponent)")
                    }
                }
                if trash {
                    let r = engine.trashDuplicates(groups.flatMap(\.extras))
                    print("moved to Trash: \(r.moved)")
                    for f in r.failed { print("✗ \(f)") }
                    return r.failed.isEmpty ? 0 : 1
                }
                return 0
            }
            let s = engine.settings
            print("iPod: \(engine.model.title), video: \(s.w)×\(s.h) \(s.codecLabel), output: \(engine.outputRoot.path)")
            print("tracks: \(engine.tracks.count), videos: \(engine.videos.count)")
            let r = await engine.convertAll()
            for t in engine.tracks { print(line(t.url, t.state)) }
            for v in engine.videos { print(line(v.url, v.state)) }
            // Файлы, которые не открылись (нет ffprobe, битый файл), до конвертации не доходят — считаем и их.
            let failed = (engine.tracks.map(\.state) + engine.videos.map(\.state)).filter {
                if case .failed = $0 { return true } else { return false }
            }.count
            print("done: \(r.done), failed: \(max(r.failed, failed))")
            var syncFailed = 0
            if toITunes { syncFailed = await addToITunes(engine) }
            return max(r.failed, failed) + syncFailed == 0 ? 0 : 1
        default:
            print("Commands: convert, dups, models, update, version")
            return 2
        }
    }

    /// Готовые файлы — в медиатеку iTunes и в плейлист iPod (как «Музыка» на Mac). Возвращает число ошибок.
    @MainActor
    static func addToITunes(_ engine: LinuxEngine) async -> Int {
        #if os(Windows)
        guard ITunesBridge.isInstalled else { print("iTunes is not installed"); return 1 }
        func out(_ s: LinuxItemState) -> URL? {
            switch s { case .done(let u), .kept(let u): u; default: nil }
        }
        let songs = engine.tracks.compactMap { out($0.state) }
        let clips = engine.videos.filter { $0.meta?.category == .musicVideo }.compactMap { out($0.state) }
        let other = engine.videos.filter { $0.meta?.category != .musicVideo }.compactMap { out($0.state) }
        let playlist = engine.model.playlistName
        var bad = 0
        for (files, video) in [(songs, false), (clips, true), (other, false)] where !files.isEmpty {
            let res = await ITunesBridge.add(files, playlist: playlist, musicVideo: video)
            for (f, r) in zip(files, res + Array(repeating: "ERR:no answer", count: max(0, files.count - res.count))) {
                if r == "ok" { print("♫ iTunes: \(f.lastPathComponent) → \(playlist)") } else { print("✗ iTunes: \(f.lastPathComponent): \(r)"); bad += 1 }
            }
        }
        return bad
        #else
        print("--itunes works only on Windows")
        return 1
        #endif
    }

    static func line(_ url: URL, _ s: LinuxItemState) -> String {
        switch s {
        case .done(let o): "✓ \(url.lastPathComponent) → \(o.path)"
        case .kept(let o): "✓ \(url.lastPathComponent) (as is) → \(o.path)"
        case .failed(let e): "✗ \(url.lastPathComponent): \(e)"
        default: "· \(url.lastPathComponent): \(s)"
        }
    }
}

#endif
