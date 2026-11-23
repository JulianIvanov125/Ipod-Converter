import Foundation

/// MCP-сервер (Model Context Protocol): `iPodConverter --mcp`.
/// Запускается без окна; Claude (или другой MCP-клиент) общается с ним через stdin/stdout:
/// JSON-RPC 2.0, по одному сообщению на строку. Инструменты используют тот же код, что и окно приложения.
@MainActor
enum MCPServer {
    nonisolated(unsafe) private static var out: FileHandle!
    private static let store = Store()

    /// Не возвращается: обслуживает главную очередь, пока клиент не закроет stdin.
    nonisolated static func runForever() -> Never {
        // Всё, что приложение могло бы напечатать, — в stderr: stdout занят протоколом.
        let protocolFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        out = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: false)
        Task { @MainActor in IPodDetector.shared.refreshNow() }
        let reader = Thread { readLoop() }
        reader.start()
        dispatchMain()
    }

    /// Читает stdin построчно на своём потоке и передаёт сообщения на главный актор.
    nonisolated private static func readLoop() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let data = Data(line.utf8)
            Task { @MainActor in handle(data) }
        }
        // Клиент закрыл соединение: даём доделать ответы и выходим.
        Task { @MainActor in
            while busyCalls > 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            exit(0)
        }
    }

    private static var busyCalls = 0

    // MARK: - JSON-RPC

    private static func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        out.write(data)
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func replyError(_ id: Any, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func handle(_ data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        let method = msg["method"] as? String ?? ""
        // Уведомления (без id) ответа не ждут.
        guard let id = msg["id"] else { return }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            reply(id, [
                "protocolVersion": supported.contains(asked) ? asked : supported[0],
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "ipod-converter", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"],
                "instructions": """
                    Converts music and videos for classic iPods (5G/5.5G, nano, classic) on this Mac and adds them to Music/TV \
                    for syncing via Finder. Start with list_ipods, then inspect_files before convert. \
                    Paths may be files or folders. Tools that change files ask for confirmation.
                    """,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            busyCalls += 1
            Task { @MainActor in
                defer { busyCalls -= 1 }
                do {
                    let text = try await call(name, args)
                    reply(id, ["content": [["type": "text", "text": text]], "isError": false])
                } catch {
                    reply(id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
                }
            }
        default:
            replyError(id, -32601, "Method not found: \(method)")
        }
    }

    // MARK: - Описание инструментов

    private static let modelIDs = IPodModel.allCases.map(\.rawValue)

    private static var tools: [[String: Any]] {
        let paths: [String: Any] = ["type": "array", "items": ["type": "string"],
                                    "description": "Absolute paths to audio/video files or folders (folders are scanned recursively)."]
        let model: [String: Any] = ["type": "string", "enum": modelIDs,
                                    "description": "Target iPod model id (see list_ipods). Defaults to the first connected iPod, else the model selected in the app."]
        func tool(_ name: String, _ title: String, _ desc: String, _ props: [String: Any], _ required: [String],
                  readOnly: Bool, destructive: Bool = false) -> [String: Any] {
            ["name": name, "title": title, "description": desc,
             "inputSchema": ["type": "object", "properties": props, "required": required],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": readOnly, "openWorldHint": false]]
        }
        return [
            tool("list_ipods", "List iPods",
                 "Connected iPods (model id, name, capacity, free space) and all supported model ids.",
                 [:], [], readOnly: true),
            tool("inspect_files", "Inspect files",
                 "What each file is now, what it becomes for the given iPod (or 'as is'), the estimated size, and whether everything fits on the connected iPod. Changes nothing.",
                 ["paths": paths, "model": model], ["paths"], readOnly: true),
            tool("find_duplicates", "Find duplicate tracks",
                 "Groups tracks with the same artist and title (duration within 2 s). For each group: the file to keep (best quality) and the extra copies. Changes nothing.",
                 ["paths": paths], ["paths"], readOnly: true),
            tool("convert", "Convert for iPod",
                 "Converts the files for the iPod into the app's output folder (music: copied as is when already compatible) and, by default, adds them to Music (tracks) / TV (videos) for syncing. Can take minutes for videos.",
                 ["paths": paths, "model": model,
                  "add_to_library": ["type": "boolean", "description": "Add results to Music/TV. Default: the app's setting."],
                  "playlist": ["type": "string", "description": "Also put tracks into this Music playlist (created if missing)."],
                  "max_quality": ["type": "boolean", "description": "Videos: use the iPod's Maximum preset (e.g. 640×480 on iPod 5.5G, 720×480 on nano 7) instead of Standard. Default: the app's setting."]],
                 ["paths"], readOnly: false),
            tool("fill_tags", "Fill missing tags",
                 "Looks up missing tags (album, year, genre, track number, cover) in the Apple Music catalog and writes them into the original files without re-encoding. Existing tags are never overwritten; a file is replaced only after a check.",
                 ["paths": paths], ["paths"], readOnly: false, destructive: true),
            tool("repair_music_covers", "Re-apply covers in Music",
                 "For tracks that are in the Music library: sets each track's artwork in Music again from the cover embedded in its file. Fixes albums that Music shows grey although the tracks have artwork. Music rewrites the files' artwork (same picture, audio unchanged).",
                 ["paths": paths], ["paths"], readOnly: false),
            tool("trash_duplicates", "Move duplicate copies to Trash",
                 "Moves the extra copies found by find_duplicates to the Trash. The file kept in each group is never touched. Pass 'only' to trash just some of the extra copies.",
                 ["paths": paths,
                  "only": ["type": "array", "items": ["type": "string"], "description": "Subset of extra-copy paths to trash. Default: all extra copies."]],
                 ["paths"], readOnly: false, destructive: true),
        ]
    }

    // MARK: - Инструменты

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func call(_ name: String, _ args: [String: Any]) async throws -> String {
        AppLog.info("MCP: \(name)")
        switch name {
        case "list_ipods": return listIPods()
        case "inspect_files": return try await inspect(args)
        case "find_duplicates": return try await findDuplicates(args)
        case "convert": return try await convert(args)
        case "fill_tags": return try await fillTags(args)
        case "trash_duplicates": return try await trashDuplicates(args)
        case "repair_music_covers": return try await repairCovers(args)
        default: throw ToolError("Unknown tool: \(name)")
        }
    }

    private static func gb(_ b: Int64?) -> String {
        b.map { String(format: "%.1f GB", Double($0) / 1_000_000_000) } ?? "?"
    }

    private static func listIPods() -> String {
        let d = IPodDetector.shared
        d.refreshNow()
        var lines: [String] = []
        if d.devices.isEmpty {
            lines.append("No iPod connected." + (d.accessDenied ? " (An iPod is plugged in, but access to its disk is denied in macOS settings.)" : ""))
        } else {
            lines.append("Connected:")
            for dev in d.devices {
                lines.append("• \(dev.name ?? dev.model.title) — model \(dev.model.rawValue) (\(dev.model.title))"
                             + ", free \(gb(dev.freeBytes)) of \(gb(dev.totalBytes))"
                             + (dev.ambiguous ? " (5G vs 5.5G guessed)" : ""))
            }
        }
        lines.append("")
        lines.append("Supported model ids: " + IPodModel.allCases.map { "\($0.rawValue) (\($0.title))" }.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    private static func targetModel(_ args: [String: Any]) throws -> IPodModel {
        if let raw = args["model"] as? String {
            guard let m = IPodModel(rawValue: raw) else { throw ToolError("Unknown model '\(raw)'. Use one of: \(modelIDs.joined(separator: ", "))") }
            return m
        }
        IPodDetector.shared.refreshNow()
        return IPodDetector.shared.connected.first ?? store.model
    }

    /// Файлы из путей (папки раскрываются), разобранные: треки и видео.
    private static func load(_ args: [String: Any]) async throws -> (tracks: [TrackItem], videos: [VideoItem], missing: [String]) {
        guard let raw = args["paths"] as? [String], !raw.isEmpty else { throw ToolError("'paths' is required") }
        var missing: [String] = []
        var urls: [URL] = []
        for p in raw {
            let path = (p as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { urls.append(URL(fileURLWithPath: path)) } else { missing.append(p) }
        }
        var tracks: [TrackItem] = [], videos: [VideoItem] = []
        for f in Store.expand(urls) {
            if AudioRules.audioExtensions.contains(f.pathExtension.lowercased()) { tracks.append(TrackItem(url: f)) }
            else { videos.append(VideoItem(url: f)) }
        }
        await withTaskGroup(of: Void.self) { g in
            for t in tracks { g.addTask { @MainActor in await TaskLimiter.probes.acquire(); await t.load(); await TaskLimiter.probes.release() } }
            for v in videos { g.addTask { @MainActor in await TaskLimiter.probes.acquire(); await v.load(); await TaskLimiter.probes.release() } }
        }
        return (tracks, videos, missing)
    }

    private static func inspect(_ args: [String: Any]) async throws -> String {
        let m = try targetModel(args)
        let (tracks, videos, missing) = try await load(args)
        store.model = m
        var lines = ["Target: \(m.title) (\(m.rawValue))", ""]
        var total: Int64 = 0
        for t in tracks {
            guard let info = t.info, let plan = t.plan(for: m) else {
                lines.append("✗ \(t.url.path) — not readable: \(t.state)"); continue
            }
            let est = AudioRules.estimatedBytes(plan, info: info)
            total += est
            let target: String = switch plan {
            case .compatible: "as is"
            case .alac(let r): "Apple Lossless \(r) Hz"
            case .aac(let r, let k): "AAC \(k) kbps \(r) Hz"
            case .mp3(let r, let k): "MP3 \(k) kbps \(r) Hz"
            }
            lines.append("♪ \(t.url.path) — \(info.typeLabel) \(info.detailLabel) → \(target), ~\(Fmt.bytes(est))"
                         + " | \(info.artist ?? "?") — \(t.displayTitle)")
        }
        for v in videos {
            guard let info = v.info else { lines.append("✗ \(v.url.path) — not readable"); continue }
            let est = store.settings(for: v).estimatedBytes(for: info)
            total += est
            lines.append("▶ \(v.url.path) — \(v.displayTitle) → ~\(Fmt.bytes(est))")
        }
        for p in missing { lines.append("✗ \(p) — not found") }
        lines.append("")
        lines.append("Tracks: \(tracks.count), videos: \(videos.count), estimated total: \(Fmt.bytes(total))")
        if let dev = IPodDetector.shared.device(for: m), let free = dev.freeBytes {
            lines.append(total <= free ? "Fits: \(gb(free)) free on \(dev.name ?? m.title)."
                                       : "Does NOT fit: needs \(Fmt.bytes(total)), \(gb(free)) free on \(dev.name ?? m.title).")
        }
        return lines.joined(separator: "\n")
    }

    private static func findDuplicates(_ args: [String: Any]) async throws -> String {
        let (tracks, _, missing) = try await load(args)
        let groups = DuplicateFinder.groups(tracks, keep: [:])
        guard !groups.isEmpty else { return "No duplicates among \(tracks.count) tracks." + (missing.isEmpty ? "" : " Not found: \(missing.joined(separator: ", "))") }
        var lines = ["\(groups.count) groups, \(groups.reduce(0) { $0 + $1.extras.count }) extra copies (of \(tracks.count) tracks):"]
        for g in groups {
            lines.append("")
            lines.append("\(g.keeper.info?.artist ?? "?") — \(g.keeper.displayTitle)")
            lines.append("  keep: \(g.keeper.url.path) (\(g.keeper.info.map { "\($0.typeLabel), \(($0.bitrate ?? 0) / 1000) kbps" } ?? ""))")
            for e in g.extras {
                lines.append("  extra: \(e.url.path) (\(e.info.map { "\($0.typeLabel), \(($0.bitrate ?? 0) / 1000) kbps" } ?? ""))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func trashDuplicates(_ args: [String: Any]) async throws -> String {
        let (tracks, _, _) = try await load(args)
        let groups = DuplicateFinder.groups(tracks, keep: [:])
        let only = (args["only"] as? [String]).map { Set($0.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }) }
        let keepers = Set(groups.map { $0.keeper.url.standardizedFileURL.path })
        var moved: [String] = [], failed: [String] = []
        for e in groups.flatMap(\.extras) {
            let p = e.url.standardizedFileURL.path
            guard !keepers.contains(p), only?.contains(p) ?? true else { continue }
            do { try FileManager.default.trashItem(at: e.url, resultingItemURL: nil); moved.append(p) }
            catch { failed.append("\(p): \(error.localizedDescription)") }
        }
        var lines = ["Moved to Trash: \(moved.count)"] + moved.map { "  \($0)" }
        if let only, let skipped = Optional(only.subtracting(moved)), !skipped.isEmpty {
            lines.append("Not an extra copy (left alone): " + skipped.sorted().joined(separator: ", "))
        }
        if !failed.isEmpty { lines.append("Failed: \(failed.count)"); lines += failed.map { "  \($0)" } }
        return lines.joined(separator: "\n")
    }

    private static func repairCovers(_ args: [String: Any]) async throws -> String {
        let (tracks, _, _) = try await load(args)
        let r = await CoverRepair.run(tracks) { _, _ in }
        var lines = ["Covers re-applied in Music: \(r.done), not in the Music library: \(r.notInLibrary), no cover in the file: \(r.noCover), failed: \(r.failed.count)"]
        lines += r.failed.prefix(30).map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    private static func fillTags(_ args: [String: Any]) async throws -> String {
        let (tracks, _, _) = try await load(args)
        let fetcher = MetadataFetcher.shared
        let wasEnabled = fetcher.enabled
        fetcher.enabled = true
        defer { fetcher.enabled = wasEnabled }
        let todo = tracks.filter { $0.info != nil && $0.metaStatus == .idle }
        for t in todo { fetcher.enqueue(t) }
        await fetcher.waitUntilIdle()
        // Найденное пишется в файлы в фоне — ждём, пока каждый закончит.
        for t in todo where t.metaStatus == .found {
            while !t.tagsWritten && t.tagWriteError == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        var lines: [String] = []
        var written = 0, notFound = 0, complete = 0
        for t in tracks {
            switch t.metaStatus {
            case .found where t.tagsWritten:
                written += 1
                lines.append("✓ \(t.url.path) — added: \(t.fetched?.summary ?? "")")
            case .found:
                lines.append("! \(t.url.path) — found (\(t.fetched?.summary ?? "")) but not written: \(t.tagWriteError ?? "?")")
            case .notFound:
                notFound += 1
            default:
                complete += 1
            }
        }
        return (["Written: \(written), no match in Apple Music: \(notFound), already complete or unreadable: \(complete)"] + lines)
            .joined(separator: "\n")
    }

    private static func convert(_ args: [String: Any]) async throws -> String {
        guard !store.isBusy else { throw ToolError("A conversion is already running.") }
        let m = try targetModel(args)
        guard store.hasChosenRoot else {
            throw ToolError("Output folder is not set yet. Open iPod Converter once and choose where to save converted files.")
        }
        let (tracks, videos, missing) = try await load(args)
        guard !tracks.isEmpty || !videos.isEmpty else { throw ToolError("No audio or video files found.") }

        // Настройки окна приложения не меняем: на время вызова, потом возвращаем как было.
        let saved = (store.model, store.addToMusic, store.musicToPlaylist, store.musicPlaylist, store.maxQuality)
        defer {
            store.model = saved.0; store.addToMusic = saved.1
            store.musicToPlaylist = saved.2; store.musicPlaylist = saved.3; store.maxQuality = saved.4
        }
        store.model = m
        if let mq = args["max_quality"] as? Bool { store.maxQuality = mq }
        if let add = args["add_to_library"] as? Bool { store.addToMusic = add }
        if let pl = (args["playlist"] as? String)?.trimmingCharacters(in: .whitespaces), !pl.isEmpty {
            store.musicToPlaylist = true; store.musicPlaylist = pl
        } else {
            store.musicToPlaylist = false
        }
        for t in tracks { t.viewModel = m }
        for v in videos { v.viewModel = m }
        store.tracks = tracks
        store.items = videos
        store.musicScope = .all
        store.trackSearch = ""
        if !tracks.isEmpty { store.convertTracks() }
        if !videos.isEmpty { store.convertAll() }
        while store.isBusy { try? await Task.sleep(nanoseconds: 300_000_000) }

        let es = store.currentSettings
        var lines = ["Target: \(m.title) (\(m.rawValue)), output: \(store.rootFolder.path)"
                     + (videos.isEmpty ? "" : ", video: \(es.w)×\(es.h) \(es.codecLabel) \(Fmt.kbps(es.videoKbps))")]
        if let s = store.musicBatchStatus { lines.append("Music: \(s.text)") }
        if let s = store.videoBatchStatus { lines.append("Videos: \(s.text)") }
        for t in tracks {
            switch t.state(for: m) {
            case .done(let out)?: lines.append("✓ \(t.url.lastPathComponent) → \(out.path)" + (t.musicError.map { " (not added to Music: \($0))" } ?? ""))
            case .kept?: lines.append("✓ \(t.url.lastPathComponent) (as is)")
            case .failed(let e)?: lines.append("✗ \(t.url.lastPathComponent): \(e)")
            default: lines.append("✗ \(t.url.lastPathComponent): \(t.state)")
            }
        }
        for v in videos {
            switch v.state(for: m) {
            case .done(let out)?: lines.append("✓ \(v.url.lastPathComponent) → \(out.path)")
            case .failed(let e)?: lines.append("✗ \(v.url.lastPathComponent): \(e)")
            default: lines.append("✗ \(v.url.lastPathComponent): \(v.state)")
            }
        }
        for p in missing { lines.append("✗ \(p): not found") }
        if let r = store.musicReport ?? store.videoReport { lines.append(""); lines.append("Support report:"); lines.append(r) }
        store.tracks = []; store.items = []
        return lines.joined(separator: "\n")
    }
}
