import AppKit
import Foundation

struct MediaInfo {
    var duration: Double
    var width: Int
    var height: Int
    var displayWidth: Int
    var displayHeight: Int
    var videoCodec: String
    var fps: Double
    var videoBitrate: Int?   // бит/с
    var hasAudio: Bool
    var audioCodec: String?
    var fileSize: Int64
    var title: String?
    var artist: String?
    /// Индекс потока со встроенной обложкой (attached_pic), если она есть.
    var coverStreamIndex: Int?
    /// Все теги контейнера (ключи в нижнем регистре).
    var tags: [String: String] = [:]
    /// Звуковая дорожка: та, что помечена «по умолчанию», иначе первая.
    var audioStreamIndex: Int?
    /// Чересстрочное видео (DVD, ТВ-записи) — нужен деинтерлейс.
    var interlaced = false
}

enum FFmpegError: LocalizedError {
    case notFound(String)
    case noVideo
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let tool): L.toolNotFound(tool)
        case .noVideo: L.noVideoTrack
        case .failed(let msg): msg
        }
    }
}

enum FFmpeg {
    static func tool(_ name: String) -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name).path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Запускает процесс и возвращает stdout.
    static func capture(_ path: String, _ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: data)
            }
        }
    }

    // MARK: - ffprobe

    struct Probe: Decodable {
        struct Stream: Decodable {
            let index: Int?
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let avg_frame_rate: String?
            let profile: String?
            let sample_rate: String?
            let channels: Int?
            let bits_per_raw_sample: String?
            let bits_per_sample: Int?
            let sample_fmt: String?
            let field_order: String?
            let r_frame_rate: String?
            let bit_rate: String?
            let sample_aspect_ratio: String?
            let disposition: [String: Int]?
            let side_data_list: [SideData]?
            let tags: [String: String]?
        }
        struct SideData: Decodable { let rotation: Double? }
        struct Format: Decodable {
            let duration: String?
            let size: String?
            let bit_rate: String?
            let tags: [String: String]?
        }
        let streams: [Stream]
        let format: Format
    }

    static func probe(_ url: URL) async throws -> MediaInfo {
        guard let ffprobe = tool("ffprobe") else { throw FFmpegError.notFound("ffprobe") }
        let data = try await capture(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            throw FFmpegError.failed(L.unreadable)
        }
        guard let v = probe.streams.first(where: {
            $0.codec_type == "video" && ($0.disposition?["attached_pic"] ?? 0) == 0
        }), let w = v.width, let h = v.height else { throw FFmpegError.noVideo }

        let a = probe.streams.first { $0.codec_type == "audio" }
        let cover = probe.streams.first {
            $0.codec_type == "video" && ($0.disposition?["attached_pic"] ?? 0) == 1
        }

        // Учитываем неквадратные пиксели и поворот (видео с телефона).
        var dw = w, dh = h
        if let sar = v.sample_aspect_ratio, let r = ratio(sar), r > 0, r != 1 {
            dw = Int(Double(w) * r)
        }
        let rotation = Int(v.side_data_list?.compactMap(\.rotation).first ?? Double(v.tags?["rotate"] ?? "0") ?? 0)
        if abs(rotation) % 180 == 90 { swap(&dw, &dh) }

        let fmtTags = lowercased(probe.format.tags)
        let size = Int64(probe.format.size ?? "") ??
            ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0)

        return MediaInfo(
            duration: Double(probe.format.duration ?? "") ?? 0,
            width: w, height: h,
            displayWidth: dw, displayHeight: dh,
            videoCodec: prettyCodec(v.codec_name),
            fps: ratio(v.avg_frame_rate ?? "") ?? ratio(v.r_frame_rate ?? "") ?? 0,
            videoBitrate: Int(v.bit_rate ?? "") ?? Int(probe.format.bit_rate ?? ""),
            hasAudio: a != nil,
            audioCodec: a.map { prettyCodec($0.codec_name) },
            fileSize: size,
            title: nonEmpty(fmtTags["title"]),
            artist: nonEmpty(fmtTags["artist"] ?? fmtTags["album_artist"] ?? fmtTags["author"]),
            coverStreamIndex: cover?.index,
            tags: fmtTags,
            audioStreamIndex: (probe.streams.first { $0.codec_type == "audio" && ($0.disposition?["default"] ?? 0) == 1 } ?? a)?.index,
            interlaced: ["tt", "bb", "tb", "bt"].contains(v.field_order ?? "")
        )
    }

    /// Превью: встроенная обложка исходника, а если её нет — кадр из видео.
    /// Возвращает JPEG (до 640 px по ширине): он же показывается в карточке и вшивается в готовый файл.
    static func preview(_ url: URL, info: MediaInfo) async -> Data? {
        guard let ffmpeg = tool("ffmpeg") else { return nil }
        let out = ["-frames:v", "1", "-vf", "scale='min(640,iw)':-2", "-q:v", "3",
                   "-f", "image2pipe", "-c:v", "mjpeg", "-"]
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin"]
        if let idx = info.coverStreamIndex {
            args += ["-i", url.path, "-map", "0:\(idx)"]
        } else {
            let t = min(info.duration * 0.15, 30)
            args += ["-ss", String(format: "%.2f", t), "-i", url.path, "-map", "0:V:0"]
        }
        let data = try? await capture(ffmpeg, args + out)
        return (data?.isEmpty ?? true) ? nil : data
    }

    // MARK: - Конвертация

    static func arguments(input: URL, output: URL, info: MediaInfo, settings model: EncodeSettings,
                          cover: URL?, meta: VideoMeta? = nil) -> [String] {
        let size = model.outputSize(for: info)
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path]
        if let cover { args += ["-i", cover.path] }
        let audioMap = info.audioStreamIndex.map { "0:\($0)" } ?? "0:a:0?"
        let deinterlace = info.interlaced ? "yadif," : ""
        args += [
            "-map", "0:V:0", "-map", audioMap,
            "-map_metadata", "0", "-map_chapters", "-1", "-sn", "-dn",
            // Все параметры видео — только для потока v:0, чтобы не задеть обложку.
            "-filter:v:0", "\(deinterlace)scale=\(size.w):\(size.h):flags=lanczos,setsar=1,format=yuv420p",
            "-fpsmax:v:0", "\(model.fpsMax)",
        ]
        switch model.codec {
        case .h264:
            args += ["-c:v:0", "libx264", "-profile:v:0", model.profile]
            if !model.level.isEmpty { args += ["-level:v:0", model.level] }
            args += ["-preset:v:0", model.profile == "baseline" ? "veryslow" : "slow",
                     "-b:v:0", "\(model.videoKbps)k",
                     "-maxrate:v:0", "\(model.maxrateKbps)k",
                     "-bufsize:v:0", "\(model.bufsizeKbps)k"]
            // Старые iPod: одна опорная рамка — самый совместимый вариант.
            if model.profile == "baseline" { args += ["-refs:v:0", "1"] }
        case .hevc:
            // HEVC — аппаратный кодер Mac; метка hvc1 нужна, чтобы файл открывали QuickTime и «Музыка».
            args += ["-c:v:0", "hevc_videotoolbox", "-tag:v:0", "hvc1", "-b:v:0", "\(model.videoKbps)k"]
        }
        // Превью как обложка (covr): её показывают Finder, «Музыка» и iPod.
        if cover != nil {
            args += ["-map", "1:0", "-c:v:1", "copy", "-disposition:v:1", "attached_pic"]
        }
        if info.hasAudio {
            args += ["-c:a", "aac", "-b:a", "\(model.audioKbps)k", "-ar", "\(model.audioRate)", "-ac", "2"]
        }
        if let meta { args += metadataArguments(meta) }
        args += ["-movflags", "+faststart", "-f", model.container.muxer, "-progress", "pipe:1", "-nostats", output.path]
        return args
    }

    /// Теги iTunes: тип (stik), шоу/сезон/серия для сериалов, артист для клипов, год для фильмов.
    static func metadataArguments(_ m: VideoMeta) -> [String] {
        func md(_ k: String, _ v: String) -> [String] { ["-metadata", "\(k)=\(v)"] }
        switch m.category {
        case .musicVideo:
            return md("media_type", "6") + md("title", m.title) + md("artist", m.artist)
        case .film:
            var a = md("media_type", "9") + md("title", m.title)
            if !m.year.isEmpty { a += md("date", m.year) }
            return a
        case .serial:
            let id = String(format: "S%02dE%02d", m.season, m.episode)
            let title = m.title.isEmpty ? "\(m.show) \(id)" : m.title
            return md("media_type", "10") + md("show", m.show) + md("season_number", "\(m.season)")
                + md("episode_sort", "\(m.episode)") + md("episode_id", id) + md("title", title)
                + md("album", "\(m.show), Season \(m.season)") + md("track", "\(m.episode)")
                + md("artist", m.show) + md("album_artist", m.show)
        }
    }

    static func ffmpegOutputLine(_ s: String) -> String {
        let lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last ?? L.ffmpegFailed
    }

    // MARK: - Helpers

    static func ratio(_ s: String) -> Double? {
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 else {
            return Double(s)
        }
        return a / b
    }

    static func lowercased(_ tags: [String: String]?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in tags ?? [:] { out[k.lowercased()] = v }
        return out
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func prettyCodec(_ name: String?) -> String {
        switch name ?? "" {
        case "h264": "H.264"
        case "hevc": "HEVC"
        case "mpeg4": "MPEG-4"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "av1": "AV1"
        case "prores": "ProRes"
        case "aac": "AAC"
        case "mp3": "MP3"
        case "opus": "Opus"
        case "ac3": "AC-3"
        case "eac3": "E-AC-3"
        case "": "?"
        case let other: other.uppercased()
        }
    }
}

/// Запущенный процесс ffmpeg с разбором прогресса из `-progress pipe:1`.
final class ConversionJob: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = ""
    private var errTail = Data()
    private(set) var cancelled = false

    func start(
        ffmpeg: String, args: [String], duration: Double,
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Int32, String) -> Void
    ) throws {
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock()
            buffer += String(decoding: d, as: UTF8.self)
            var lines = buffer.components(separatedBy: "\n")
            buffer = lines.removeLast()
            lock.unlock()
            for line in lines where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)), duration > 0 {
                    progress(min(max(us / 1_000_000 / duration, 0), 1))
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock()
            errTail.append(d)
            if errTail.count > 8000 { errTail = Data(errTail.suffix(8000)) }
            lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            lock.lock()
            let tail = String(decoding: errTail, as: UTF8.self)
            lock.unlock()
            completion(p.terminationStatus, tail)
        }
        try process.run()
    }

    func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}
