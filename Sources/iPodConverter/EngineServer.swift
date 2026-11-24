#if !os(macOS)
import Foundation

/// Движок для окна на другом языке (WinUI на Windows): `iPodConverter serve`.
/// Окно пишет в stdin команды — по одной JSON-строке, движок отвечает в stdout снимками состояния (тоже JSON-строки).
///   → {"cmd":"add","paths":[…]}            → {"cmd":"set","ipod":"nano7","max":true,"out":"C:\\…"}
///   → {"cmd":"convert"}  {"cmd":"cancel"}  {"cmd":"clear"}  {"cmd":"remove","id":"…"}  {"cmd":"check","id":"…","on":false}
///   → {"cmd":"keep","id":"…"} (оставить эту копию)  {"cmd":"trashDups"} (лишние копии — в Корзину)
///   ← {"type":"state", …}  ← {"type":"message","text":"…","error":true}
@MainActor
final class EngineServer {
    private let engine = LinuxEngine()
    private var scheduled = false
    private var sentModels = false

    static func run() -> Never {
        let server = EngineServer()
        server.engine.onChange = { [weak server] in server?.scheduleState() }
        server.sendState()
        // stdin читаем в отдельном потоке: readLine блокирует.
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let box = UncheckedBox(obj)
                Task { @MainActor in server.handle(box.value) }
            }
            // Окно закрылось — stdin кончился: останавливаем конвертацию и выходим.
            Task { @MainActor in
                server.engine.cancel()
                LinuxEngine.save()
                exit(0)
            }
        }
        dispatchMain()
    }

    private func handle(_ c: [String: Any]) {
        switch c["cmd"] as? String ?? "" {
        case "add":
            let paths = (c["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0.path) }
            for m in missing { message("Not found: \(m.path)", error: true) }
            engine.add(paths)
        case "set":
            if let m = (c["ipod"] as? String).flatMap(IPodModel.init(rawValue:)) { engine.model = m }
            if let mx = c["max"] as? Bool { engine.maxQuality = mx }
            if let o = c["out"] as? String, !o.isEmpty { engine.outputRoot = URL(fileURLWithPath: o) }
            scheduleState()
        case "convert":
            guard !engine.running else { return }
            guard FFmpeg.tool("ffmpeg") != nil, FFmpeg.tool("ffprobe") != nil else {
                message(L.toolNotFound("ffmpeg"), error: true); return
            }
            Task {
                let r = await engine.convertAll()
                // Не открывшиеся файлы до конвертации не доходят — считаем и их (как в консольной версии).
                let broken = (engine.tracks.map(\.state) + engine.videos.map(\.state)).filter {
                    if case .failed = $0 { return true } else { return false }
                }.count
                let failed = max(r.failed, broken)
                message("done: \(r.done), failed: \(failed)", error: failed > 0)
                scheduleState()
            }
        case "cancel": engine.cancel()
        case "clear": engine.clear()
        case "remove":
            guard let id = c["id"] as? String else { return }
            if let v = engine.videos.first(where: { $0.id.uuidString == id }), !v.state.isBusy { engine.remove(video: v) }
            if let t = engine.tracks.first(where: { $0.id.uuidString == id }), !t.state.isBusy { engine.remove(track: t) }
        case "check":
            guard let id = c["id"] as? String, let on = c["on"] as? Bool else { return }
            engine.videos.first { $0.id.uuidString == id }?.checked = on
            engine.tracks.first { $0.id.uuidString == id }?.checked = on
            scheduleState()
        case "keep":
            guard let id = c["id"] as? String, let v = engine.videos.first(where: { $0.id.uuidString == id }) else { return }
            engine.keepDuplicate(v)
        case "trashDups":
            let r = engine.trashDuplicates(engine.videoDuplicateGroups.flatMap(\.extras))
            message("moved to Recycle Bin: \(r.moved)" + (r.failed.isEmpty ? "" : "; failed: " + r.failed.joined(separator: "; ")),
                    error: !r.failed.isEmpty)
        default:
            message("unknown command", error: true)
        }
    }

    // MARK: Вывод

    /// Снимок не чаще 10 раз в секунду: прогресс ffmpeg приходит часто.
    private func scheduleState() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            scheduled = false
            sendState()
        }
    }

    private func message(_ text: String, error: Bool) {
        emit(["type": "message", "text": text, "error": error])
    }

    private func sendState() {
        var s: [String: Any] = [
            "type": "state",
            "ipod": engine.model.rawValue,
            "max": engine.maxQuality,
            "supportsMax": engine.model.supportsMax,
            "out": engine.outputRoot.path,
            "running": engine.running,
            "preset": presetLabel(engine.settings),
            "ffmpeg": FFmpeg.tool("ffmpeg") != nil,
        ]
        if !sentModels {
            sentModels = true
            s["models"] = IPodModel.allCases.map { m -> [String: Any] in
                let st = m.settings(max: false)
                var d: [String: Any] = ["id": m.rawValue, "title": m.title, "standard": "\(st.w)×\(st.h)", "supportsMax": m.supportsMax]
                if m.supportsMax { let x = m.settings(max: true); d["max"] = "\(x.w)×\(x.h)" }
                return d
            }
        }
        s["items"] = engine.tracks.map(trackJSON) + engine.videos.map(videoJSON)
        let groups = engine.videoDuplicateGroups
        s["dups"] = groups.map { g in
            ["key": g.key, "keeper": g.keeper.id.uuidString, "extras": g.extras.map(\.id.uuidString)] as [String: Any]
        }
        emit(s)
    }

    private func presetLabel(_ s: EncodeSettings) -> String { "\(s.w)×\(s.h) \(s.codecLabel)" }

    private func stateJSON(_ st: LinuxItemState, into d: inout [String: Any]) {
        switch st {
        case .loading: d["state"] = "loading"
        case .ready: d["state"] = "ready"
        case .queued: d["state"] = "queued"
        case .converting(let p): d["state"] = "converting"; d["progress"] = p
        case .done(let u): d["state"] = "done"; d["output"] = u.path
        case .kept(let u): d["state"] = "kept"; d["output"] = u.path
        case .failed(let e): d["state"] = "failed"; d["error"] = e
        }
    }

    private func trackJSON(_ t: LinuxTrack) -> [String: Any] {
        var d: [String: Any] = ["id": t.id.uuidString, "kind": "audio", "name": t.url.lastPathComponent,
                                "path": t.url.path, "checked": t.checked]
        stateJSON(t.state, into: &d)
        if let i = t.info {
            d["title"] = i.title ?? t.url.deletingPathExtension().lastPathComponent
            d["artist"] = i.artist ?? ""
            d["detail"] = audioDetail(i)
        }
        if let o = t.outInfo { d["after"] = audioDetail(o) }
        return d
    }

    private func videoJSON(_ v: LinuxVideo) -> [String: Any] {
        var d: [String: Any] = ["id": v.id.uuidString, "kind": "video", "name": v.url.lastPathComponent,
                                "path": v.url.path, "checked": v.checked]
        stateJSON(v.state, into: &d)
        if let m = v.meta {
            d["title"] = m.title
            d["artist"] = m.category == .musicVideo ? m.artist : (m.category == .serial ? m.show : "")
            d["category"] = m.category == .musicVideo ? "musicVideo" : (m.category == .serial ? "serial" : "film")
        }
        if let i = v.info { d["detail"] = videoDetail(i) }
        if let o = v.outInfo { d["after"] = videoDetail(o) }
        if let c = v.cover { d["cover"] = c.path }
        return d
    }

    private func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func size(_ b: Int64) -> String {
        b >= 1 << 30 ? String(format: "%.1f GB", Double(b) / Double(1 << 30)) : String(format: "%.1f MB", Double(b) / Double(1 << 20))
    }

    private func videoDetail(_ i: MediaInfo) -> String {
        var p = ["\(i.displayWidth)×\(i.displayHeight)", i.videoCodec.uppercased()]
        if let b = i.videoBitrate { p.append("\(b / 1000) kbps") }
        p.append(i.hasAudio ? (i.audioCodec ?? "audio").uppercased() : "no audio")
        p += [time(i.duration), size(i.fileSize)]
        return p.joined(separator: " · ")
    }

    private func audioDetail(_ i: AudioInfo) -> String {
        var p = [i.codec.uppercased(), String(format: "%.1f kHz", Double(i.sampleRate) / 1000)]
        if let b = i.bits { p.append("\(b)-bit") }
        if let b = i.bitrate { p.append("\(b / 1000) kbps") }
        p += [time(i.duration), size(i.fileSize)]
        return p.joined(separator: " · ")
    }

    private func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
}

/// Переносит словарь из потока чтения stdin в главный актор (JSON-объект там не меняется).
private struct UncheckedBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}
#endif
