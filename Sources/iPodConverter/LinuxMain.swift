#if os(Linux)
import Foundation

/// Точка входа Linux-версии. Без аргументов — окно (GTK); с командой — консольный режим:
///   iPodConverter convert --ipod nano7 [--max] [--out ПАПКА] файлы-или-папки…
///   iPodConverter dups файлы-или-папки…
///   iPodConverter models
@main
enum LinuxMain {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            LinuxApp.run()
            return
        }
        Task { @MainActor in
            let code = await runCommand(cmd, Array(args.dropFirst()))
            _ = AppLog.tail(0)   // дождаться записи журнала
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    static func runCommand(_ cmd: String, _ rest: [String]) async -> Int32 {
        switch cmd {
        case "models":
            for m in IPodModel.allCases {
                let s = m.settings(max: false)
                print("\(m.rawValue)\t\(m.title)\t\(s.w)×\(s.h)" + (m.supportsMax ? "\tmax \(m.settings(max: true).w)×\(m.settings(max: true).h)" : ""))
            }
            return 0
        case "convert", "dups":
            let engine = LinuxEngine()
            var paths: [URL] = []
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
                case "--out":
                    i += 1
                    guard i < rest.count else { return 2 }
                    engine.outputRoot = URL(fileURLWithPath: rest[i])
                default: paths.append(URL(fileURLWithPath: rest[i]))
                }
                i += 1
            }
            guard !paths.isEmpty else { print("No files given"); return 2 }
            engine.add(paths)
            while engine.videos.contains(where: { $0.state == .loading }) || engine.tracks.contains(where: { $0.state == .loading }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
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
                return 0
            }
            let s = engine.settings
            print("iPod: \(engine.model.title), video: \(s.w)×\(s.h) \(s.codecLabel), output: \(engine.outputRoot.path)")
            print("tracks: \(engine.tracks.count), videos: \(engine.videos.count)")
            let r = await engine.convertAll()
            for t in engine.tracks { print(line(t.url, t.state)) }
            for v in engine.videos { print(line(v.url, v.state)) }
            print("done: \(r.done), failed: \(r.failed)")
            return r.failed == 0 ? 0 : 1
        default:
            print("Commands: convert, dups, models")
            return 2
        }
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

/// Окно GTK — следующий шаг; пока подсказка.
enum LinuxApp {
    static func run() {
        print("iPod Converter for Linux. Window coming soon. Commands: convert, dups, models")
    }
}
#endif
