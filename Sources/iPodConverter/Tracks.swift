import AppKit
import Foundation
import Observation

// MARK: - Информация о треке

struct AudioInfo {
    var codec: String          // имя кодека ffmpeg: flac, mp3, aac, alac, pcm_s16le…
    var profile: String?       // для AAC: LC, HE-AAC…
    var sampleRate: Int
    var channels: Int
    var bits: Int?             // разрядность для lossless/PCM
    var bitrate: Int?          // бит/с
    var duration: Double
    var fileSize: Int64
    var ext: String            // расширение файла в нижнем регистре
    var title: String?
    var artist: String?
    var album: String?
    var coverStreamIndex: Int?
    /// Теги лежат в потоке, а не в контейнере (OGG/Opus).
    var tagsInStream: Bool
    /// Оценка из файла, 0–100 (как в «Музыке»: 20 = ★, 100 = ★★★★★); nil — нет.
    var rating: Int? = nil
    /// Все теги файла (ключи в нижнем регистре): track, date, genre, album_artist…
    var tags: [String: String] = [:]

    var isLossless: Bool {
        ["flac", "alac", "ape", "wavpack", "tta", "mlp", "truehd", "wmalossless"].contains(codec)
            || codec.hasPrefix("pcm_") || codec.hasPrefix("dsd_")
    }

    /// «FLAC», «MP3», «WAV»…
    var typeLabel: String { ext.uppercased() }

    /// «24-bit · 96 kHz», «44.1 kHz», «Opus»…
    var detailLabel: String {
        var parts: [String] = []
        let codecName = codec.hasPrefix("pcm_") ? "PCM" : codec.hasPrefix("dsd_") ? "DSD" : FFmpeg.prettyCodec(codec)
        if codecName.uppercased() != typeLabel { parts.append(codecName) }
        if let bits, isLossless { parts.append("\(bits)-bit") }
        if sampleRate > 0 {
            let k = Double(sampleRate) / 1000
            parts.append(k == k.rounded() ? "\(Int(k)) \(L.kHz)" : String(format: "%.1f ", k) + L.kHz)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Что делать с треком под конкретный iPod

enum AudioPlan: Equatable {
    case compatible
    case alac(rate: Int)
    case aac(rate: Int, kbps: Int)
    case mp3(rate: Int, kbps: Int)

    static let aacKbps = 256

    /// Расширение готового файла.
    var ext: String {
        if case .mp3 = self { return "mp3" }
        return "m4a"
    }
}

/// Свой формат для одного трека (nil у трека — общие настройки).
struct TrackFormatOverride: Equatable {
    var choice: AudioFormatChoice
    var kbps: Int
    var sampleRate: Int

    @MainActor static func fromGlobal() -> TrackFormatOverride {
        let g = AudioOutputSettings.shared
        return TrackFormatOverride(choice: g.choice, kbps: g.kbps, sampleRate: g.sampleRate)
    }
}

/// Какой формат хочет получить пользователь.
enum AudioFormatChoice: String, CaseIterable, Identifiable {
    case auto, aac, mp3, alac
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: L.t("Auto", "Авто", "Авто", "Аўта")
        case .aac: "AAC"
        case .mp3: "MP3"
        case .alac: "Apple Lossless"
        }
    }

    var usesBitrate: Bool { self == .aac || self == .mp3 }
}

@MainActor
@Observable
final class AudioOutputSettings {
    static let shared = AudioOutputSettings()
    static let bitrates = [128, 192, 256, 320]

    var choice: AudioFormatChoice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "audioFormat") }
    }
    var kbps: Int {
        didSet { UserDefaults.standard.set(kbps, forKey: "audioKbps") }
    }
    /// Частота дискретизации на выходе: 0 — как в пресете (44.1 для 44.1-семейства, иначе 48), 44100 или 48000.
    var sampleRate: Int {
        didSet { UserDefaults.standard.set(sampleRate, forKey: "audioRate") }
    }
    static let sampleRates = [0, 44100, 48000]

    /// Пользователь что-то поменял относительно пресета iPod.
    var isCustom: Bool { choice != .auto || sampleRate != 0 }

    func reset() { choice = .auto; kbps = 256; sampleRate = 0 }

    private init() {
        choice = AudioFormatChoice(rawValue: UserDefaults.standard.string(forKey: "audioFormat") ?? "") ?? .auto
        let saved = UserDefaults.standard.integer(forKey: "audioKbps")
        kbps = Self.bitrates.contains(saved) ? saved : 256
        let rate = UserDefaults.standard.integer(forKey: "audioRate")
        sampleRate = Self.sampleRates.contains(rate) ? rate : 0
    }
}

enum AudioRules {
    /// Контейнеры, которые iPod принимает (через «Музыку»).
    static let ipodExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4", "wav", "aif", "aiff", "aifc"]

    /// Все аудиофайлы, которые приложение готово принять.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4a", "aac", "wav", "aif", "aiff", "aifc", "caf",
        "flac", "ogg", "oga", "opus", "wma", "ape", "wv", "tta", "dsf", "dff",
        "mka", "ac3", "eac3", "mp2", "mpc", "amr", "alac", "spx",
    ]

    /// План с учётом выбранного пользователем формата.
    @MainActor
    static func plan(for info: AudioInfo, model: IPodModel) -> AudioPlan {
        let s = AudioOutputSettings.shared
        return plan(for: info, model: model, choice: s.choice, kbps: s.kbps, rateOverride: s.sampleRate)
    }

    static func plan(for info: AudioInfo, model: IPodModel, choice: AudioFormatChoice, kbps: Int, rateOverride: Int = 0) -> AudioPlan {
        let rate = rateOverride > 0 ? rateOverride : targetRate(info.sampleRate)
        let playable = playsAsIs(info, model: model)
        let srcKbps = (info.bitrate ?? Int.max) / 1000
        switch choice {
        case .auto:
            if playable { return .compatible }
            return info.isLossless ? .alac(rate: rate) : .aac(rate: rate, kbps: AudioPlan.aacKbps)
        case .alac:
            // Lossless из lossy не сделать — такие треки оставляем как есть или в AAC 256.
            if info.isLossless { return playable && info.codec == "alac" ? .compatible : .alac(rate: rate) }
            return playable ? .compatible : .aac(rate: rate, kbps: AudioPlan.aacKbps)
        case .aac:
            // Уже AAC не выше выбранного битрейта — не пережимаем (лишняя потеря качества).
            if playable, info.codec == "aac", srcKbps <= kbps + kbps / 10 { return .compatible }
            return .aac(rate: rate, kbps: kbps)
        case .mp3:
            if playable, info.codec == "mp3", srcKbps <= kbps + kbps / 10 { return .compatible }
            return .mp3(rate: rate, kbps: kbps)
        }
    }

    /// Классические iPod и nano: AAC, HE-AAC (кроме 5G/5.5G — не сверено), MP3, Apple Lossless,
    /// WAV/AIFF. Lossless — не выше 16 бит и 48 кГц, максимум стерео.
    static func playsAsIs(_ info: AudioInfo, model: IPodModel) -> Bool {
        guard ipodExtensions.contains(info.ext), info.channels <= 2, info.sampleRate <= 48000 else { return false }
        switch info.codec {
        case "mp3":
            return true
        case "aac":
            let p = (info.profile ?? "LC").uppercased()
            if p == "LC" { return true }
            return p.hasPrefix("HE") && model != .classic5G && model != .classic55G
        case "alac":
            return (info.bits ?? 16) <= 16
        case "pcm_s16le", "pcm_s16be":
            return ["wav", "aif", "aiff", "aifc"].contains(info.ext)
        default:
            return false
        }
    }

    /// 44.1-семейство (22.05, 88.2, 176.4…) → 44.1 кГц, остальное → 48 кГц.
    static func targetRate(_ src: Int) -> Int {
        src > 0 && src % 11025 == 0 ? 44100 : 48000
    }

    /// Грубая оценка размера результата.
    static func estimatedBytes(_ plan: AudioPlan, info: AudioInfo) -> Int64 {
        switch plan {
        case .compatible: return info.fileSize
        case .aac(_, let kbps), .mp3(_, let kbps): return Int64(Double(kbps) * 1000 / 8 * info.duration)
        case .alac(let rate):
            // ALAC обычно сжимает 16-bit PCM примерно до 55–65%.
            return Int64(Double(rate * 16 * 2) / 8 * info.duration * 0.6)
        }
    }
}

// MARK: - ffprobe / ffmpeg для аудио

extension FFmpeg {
    static func probeAudio(_ url: URL) async throws -> AudioInfo {
        guard let ffprobe = tool("ffprobe") else { throw FFmpegError.notFound("ffprobe") }
        let data = try await capture(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              let a = probe.streams.first(where: { $0.codec_type == "audio" })
        else { throw FFmpegError.failed(L.notAudio) }

        let cover = probe.streams.first {
            $0.codec_type == "video" && ($0.disposition?["attached_pic"] ?? 0) == 1
        }
        var bits = Int(a.bits_per_raw_sample ?? "") ?? a.bits_per_sample.flatMap { $0 > 0 ? $0 : nil }
        if bits == nil, let codec = a.codec_name, codec.hasPrefix("pcm_") {
            bits = Int(codec.filter(\.isNumber))
        }

        let fmtTags = lowercased(probe.format.tags)
        let streamTags = lowercased(a.tags)
        let tagsInStream = fmtTags["title"] == nil && fmtTags["artist"] == nil
            && (streamTags["title"] != nil || streamTags["artist"] != nil)
        let tags = tagsInStream ? streamTags : fmtTags
        let size = Int64(probe.format.size ?? "") ??
            ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0)

        return AudioInfo(
            codec: a.codec_name ?? "?",
            profile: a.profile,
            sampleRate: Int(a.sample_rate ?? "") ?? 0,
            channels: a.channels ?? 2,
            bits: bits,
            bitrate: Int(a.bit_rate ?? "") ?? Int(probe.format.bit_rate ?? ""),
            duration: Double(probe.format.duration ?? "") ?? 0,
            fileSize: size,
            ext: url.pathExtension.lowercased(),
            title: nonEmpty(tags["title"]),
            artist: nonEmpty(tags["artist"] ?? tags["album_artist"]),
            album: nonEmpty(tags["album"]),
            coverStreamIndex: cover?.index,
            tagsInStream: tagsInStream,
            rating: RatingReader.fromTags(fmtTags.merging(streamTags) { a, _ in a })
                ?? (url.pathExtension.lowercased() == "mp3" ? RatingReader.popm(url) : nil),
            // Пустые значения не считаем тегами; tracknumber/year из Vorbis приводим к именам ffmpeg.
            tags: fmtTags.merging(streamTags) { a, _ in a }
                .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                .reduce(into: [String: String]()) { d, kv in
                    let k = ["tracknumber": "track", "year": "date", "albumartist": "album_artist", "discnumber": "disc"][kv.key] ?? kv.key
                    if d[k] == nil { d[k] = kv.value }
                }
        )
    }

    /// Обложка из файла: maxSide — для списка (маленькая), для плеера — крупная, без увеличения сверх оригинала.
    static func coverThumbnail(_ url: URL, index: Int, maxSide: Int = 200) async -> NSImage? {
        guard let ffmpeg = tool("ffmpeg") else { return nil }
        let data = try? await capture(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path, "-map", "0:\(index)",
            "-frames:v", "1", "-vf", "scale='min(\(maxSide),iw)':-2:flags=lanczos", "-q:v", "2",
            "-f", "image2pipe", "-c:v", "mjpeg", "-",
        ])
        return data.flatMap { $0.isEmpty ? nil : NSImage(data: $0) }
    }

    /// Есть ли AAC-кодер Apple (AudioToolbox) — он звучит лучше встроенного в ffmpeg.
    static let hasAudioToolboxAAC: Bool = {
        guard let ffmpeg = tool("ffmpeg") else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-encoders"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("aac_at")
    }()

    static func audioArguments(input: URL, output: URL, info: AudioInfo, plan: AudioPlan, fetched: FetchedMeta? = nil) -> [String] {
        // Обложка: своя из файла, иначе — найденная в интернете (вторым входом).
        let fetchedCover = info.coverStreamIndex == nil ? fetched?.coverFile : nil
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path]
        if let fetchedCover { args += ["-i", fetchedCover.path] }
        args += ["-map", "0:a:0"]
        if let idx = info.coverStreamIndex { args += ["-map", "0:\(idx)"] } else if fetchedCover != nil { args += ["-map", "1:0"] }
        args += ["-map_metadata", info.tagsInStream ? "0:s:a:0" : "0", "-map_chapters", "-1"]
        // Дописываем только то, чего в файле не было.
        for (k, v) in (fetched?.fields ?? [:]).sorted(by: { $0.key < $1.key }) { args += ["-metadata", "\(k)=\(v)"] }
        switch plan {
        case .alac(let rate):
            args += ["-c:a", "alac", "-af", "aresample=\(rate):dither_method=triangular", "-sample_fmt", "s16p"]
        case .aac(let rate, let kbps):
            args += ["-c:a", hasAudioToolboxAAC ? "aac_at" : "aac", "-b:a", "\(kbps)k", "-ar", "\(rate)"]
        case .mp3(let rate, let kbps):
            args += ["-c:a", "libmp3lame", "-b:a", "\(kbps)k", "-ar", "\(rate)"]
        case .compatible:
            args += ["-c:a", "copy"]
        }
        if info.channels > 2 { args += ["-ac", "2"] }
        if info.coverStreamIndex != nil || fetchedCover != nil {
            // Обложку уменьшаем до 600 px: старые iPod тормозят на огромных картинках.
            args += ["-c:v", "mjpeg", "-filter:v", "scale='2*trunc(min(600,iw)/2)':-2", "-q:v", "3",
                     "-disposition:v", "attached_pic"]
        }
        if output.pathExtension.lowercased() == "mp3" {
            // ID3v2.3 — его понимают и «Музыка», и старые iPod.
            args += ["-id3v2_version", "3", "-f", "mp3"]
        } else {
            args += ["-f", "ipod"]
        }
        args += ["-progress", "pipe:1", "-nostats", output.path]
        return args
    }
}

// MARK: - Трек в списке

@MainActor
@Observable
final class TrackItem: Identifiable {
    enum State: Equatable {
        case loading
        case ready
        case queued
        case converting(Double)
        case done(URL)
        case kept          // формат уже подходит, конвертация не нужна
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var info: AudioInfo?
    var artwork: NSImage?
    var state: State = .loading
    var isChecked = false
    /// Оценка 0–100 (20 = ★). Берётся из файла, меняется в списке.
    var rating = 0
    /// Трек в «Музыке» после добавления — чтобы менять там оценку.
    var musicPersistentID: String?
    /// Не удалось добавить в «Музыку» (текст ошибки) — показываем у трека и в отчёте.
    var musicError: String?
    /// Что нашлось в интернете для пустых тегов.
    var fetched: FetchedMeta?
    var metaStatus: MetaStatus = .idle
    @ObservationIgnored private var job: ConversionJob?

    /// Применить найденное: показываем в списке и потом пишем в готовый файл.
    func apply(_ meta: FetchedMeta) {
        guard !meta.isEmpty else { metaStatus = .notFound; return }
        fetched = meta
        metaStatus = .found
        if info?.title == nil { info?.title = meta.fields["title"] }
        if info?.artist == nil { info?.artist = meta.fields["artist"] }
        if info?.album == nil { info?.album = meta.fields["album"] }
        for (k, v) in meta.fields where info?.tags[k] == nil { info?.tags[k] = v }
        if artwork == nil, let f = meta.coverFile, let img = NSImage(contentsOf: f) { artwork = img }
    }

    /// Подходящий по формату файл, но с найденными тегами/обложкой: переупаковка без перекодирования.
    var needsRetag: Bool {
        guard let f = fetched, !f.isEmpty else { return false }
        return ["mp3", "m4a", "m4b", "mp4"].contains(url.pathExtension.lowercased())
    }

    init(url: URL) { self.url = url }

    var displayTitle: String { info?.title ?? url.deletingPathExtension().lastPathComponent }

    var isConverting: Bool {
        if case .converting = state { return true }
        return false
    }

    var isActive: Bool { isConverting || state == .queued }

    func load() async {
        do {
            let info = try await FFmpeg.probeAudio(url)
            self.info = info
            rating = info.rating ?? 0
            state = .ready
            if let idx = info.coverStreamIndex {
                artwork = await FFmpeg.coverThumbnail(url, index: idx)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Свой формат для этого трека (nil — общие настройки «Выход»).
    var formatOverride: TrackFormatOverride?

    func plan(for model: IPodModel) -> AudioPlan? {
        guard let info else { return nil }
        if let o = formatOverride {
            return AudioRules.plan(for: info, model: model, choice: o.choice, kbps: o.kbps, rateOverride: o.sampleRate)
        }
        return AudioRules.plan(for: info, model: model)
    }

    /// Запускает ffmpeg; completion получает готовый файл или nil.
    func convert(plan: AudioPlan, into folder: URL, completion: @escaping @MainActor (URL?) -> Void) {
        guard let info, let ffmpeg = FFmpeg.tool("ffmpeg") else {
            state = .failed(L.toolNotFound("ffmpeg"))
            completion(nil)
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // «Как есть» с новыми тегами — расширение оригинала (mp3 остаётся mp3).
        let ext = plan == .compatible ? url.pathExtension.lowercased() : plan.ext
        let output = Self.uniqueURL(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: ext)
        let args = FFmpeg.audioArguments(input: url, output: output, info: info, plan: plan, fetched: fetched)
        let job = ConversionJob()
        self.job = job
        state = .converting(0)
        do {
            try job.start(
                ffmpeg: ffmpeg, args: args, duration: info.duration,
                progress: { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.isConverting else { return }
                        self.state = .converting(p)
                    }
                },
                completion: { [weak self] status, stderr in
                    Task { @MainActor in
                        guard let self else { return }
                        self.job = nil
                        if job.cancelled {
                            try? FileManager.default.removeItem(at: output)
                            self.state = .ready
                            completion(nil)
                        } else if status == 0 {
                            self.state = .done(output)
                            completion(output)
                        } else {
                            try? FileManager.default.removeItem(at: output)
                            self.state = .failed(FFmpeg.ffmpegOutputLine(stderr))
                            completion(nil)
                        }
                    }
                }
            )
        } catch {
            state = .failed(error.localizedDescription)
            completion(nil)
        }
    }

    func cancel() {
        if state == .queued { state = .ready }
        job?.cancel()
    }

    var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    /// До конвертации — где лежит оригинал, после — готовый файл.
    func revealInFinder() {
        if case .done(let out) = state, FileManager.default.fileExists(atPath: out.path) {
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func uniqueURL(in folder: URL, base: String, ext: String = "m4a") -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Формат уже подходит iPod — просто копируем файл в папку (без перекодирования, качество то же).
    func copyAsIs(into folder: URL, completion: @escaping @MainActor (URL?) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let src = url
        let dest = Self.uniqueURL(in: folder, base: src.deletingPathExtension().lastPathComponent,
                                  ext: src.pathExtension.isEmpty ? "m4a" : src.pathExtension)
        state = .converting(0)
        Task.detached(priority: .userInitiated) {
            let error: String? = {
                do { try FileManager.default.copyItem(at: src, to: dest); return nil }
                catch { return error.localizedDescription }
            }()
            await MainActor.run {
                if let error {
                    self.state = .failed(error)
                    completion(nil)
                } else {
                    self.state = .done(dest)
                    completion(dest)
                }
            }
        }
    }
}
