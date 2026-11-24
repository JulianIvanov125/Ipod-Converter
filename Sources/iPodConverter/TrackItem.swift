#if os(macOS)
import AppKit
import Foundation
import Observation

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
    var info: AudioInfo? {
        didSet { dupKeyCache = nil; hayCache = nil; TrackItem.infoVersion &+= 1 }
    }
    /// Растёт при любом изменении тегов любого трека — для кэшей, зависящих от тегов (дубликаты).
    @ObservationIgnored nonisolated(unsafe) static var infoVersion = 0
    /// Ключ «артист|название» для поиска дублей — считается один раз (разбор имени файла и папок дорогой).
    @ObservationIgnored private var dupKeyCache: String??
    var dupKey: String? {
        if let c = dupKeyCache { return c }
        var k: String?
        if let info {
            let g = TagGuess.from(url: url, info: info)
            let title = DuplicateFinder.norm(g.title)
            k = title.isEmpty ? nil : "\(DuplicateFinder.norm(g.artist))|\(title)"
        }
        dupKeyCache = .some(k)
        return k
    }
    var artwork: NSImage?
    /// iPod открытой вкладки — для него показываем состояние строки.
    var viewModel: IPodModel?
    /// Анализ файла — общий для всех iPod.
    private var base: State = .loading
    /// Своё состояние для каждого iPod: в очереди / идёт / готово / ошибка.
    private var perModel: [IPodModel: State] = [:]
    private var musicErrorBy: [IPodModel: String] = [:]
    /// Параметры готового файла (битрейт, размер) — перечитываются после конвертации, для «было → стало».
    private var outputInfoBy: [IPodModel: AudioInfo] = [:]
    /// Готовый файл для iPod открытой вкладки (если он уже есть и прочитан).
    var outputInfo: AudioInfo? {
        guard let m = viewModel, case .done? = perModel[m] else { return nil }
        return outputInfoBy[m]
    }
    /// Перечитать готовый файл, чтобы показать его настоящий битрейт и размер.
    func loadOutputInfo(_ file: URL, for model: IPodModel) {
        Task {
            if let i = try? await FFmpeg.probeAudio(file) { outputInfoBy[model] = i }
        }
    }
    var state: State { viewModel.flatMap { perModel[$0] } ?? base }
    func state(for m: IPodModel) -> State? { perModel[m] }
    func setState(_ s: State?, for m: IPodModel) { perModel[m] = s }
    var isChecked = false
    /// Оценка 0–100 (20 = ★). Берётся из файла, меняется в списке.
    var rating = 0
    /// Трек в «Музыке» после добавления — чтобы менять там оценку.
    var musicPersistentID: String?
    /// Не удалось добавить в «Музыку» (текст ошибки) — у трека на вкладке этого iPod и в отчёте.
    var musicError: String? { viewModel.flatMap { musicErrorBy[$0] } }
    func setMusicError(_ e: String?, for m: IPodModel) { musicErrorBy[m] = e }
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
        Task { await writeTagsToFile() }
    }

    /// Найденное записано в сам файл (без перекодирования).
    var tagsWritten = false
    /// Не удалось записать в файл — найденное попадёт только в готовый файл при конвертации.
    var tagWriteError: String?

    /// Пишем найденные теги и обложку прямо в исходный файл: звук не трогаем, пометка остаётся в файле.
    func writeTagsToFile() async {
        guard let meta = fetched, !meta.isEmpty, !tagsWritten, !isActive, let before = info else { return }
        // В списке info уже дополнено найденным — для проверки нужен файл как есть.
        guard let original = try? await FFmpeg.probeAudio(url) else { return }
        switch await TagWriter.write(url: url, info: original, meta: meta) {
        case .success(let w):
            AppLog.info("Tags written: \(url.path) — \(w.markValue)")
            tagsWritten = true
            // Файл может быть в медиатеке «Музыки» — пусть она перечитает теги и обложку.
            MusicRefresher.shared.add(url, cover: w.cover ? meta.coverFile : nil)
            tagWriteError = nil
            if var fresh = try? await FFmpeg.probeAudio(url) {
                fresh.rating = before.rating
                info = fresh
            }
        case .failure(let e):
            tagWriteError = e.message
            AppLog.error("Tags not written: \(url.path) — \(e.message)")
        }
    }

    /// Подходящий по формату файл, но с найденными тегами/обложкой: переупаковка без перекодирования.
    /// Если теги уже записаны в оригинал, переупаковывать нечего — файл просто копируется.
    var needsRetag: Bool {
        guard let f = fetched, !f.isEmpty, !tagsWritten || (f.coverFile != nil && info?.coverStreamIndex == nil) else { return false }
        return ["mp3", "m4a", "m4b", "mp4"].contains(url.pathExtension.lowercased())
    }

    /// Имя файла без расширения и с ним — считаются один раз (разбор URL дорогой на тысячах треков).
    let fileBaseName: String
    let fileName: String

    init(url: URL) {
        self.url = url
        fileBaseName = url.deletingPathExtension().lastPathComponent
        fileName = url.lastPathComponent
    }

    var displayTitle: String { info?.title ?? fileBaseName }

    /// Текст для поиска (транслитерация дорогая — считаем один раз, пока не поменялись теги).
    @ObservationIgnored private var hayCache: String?
    var searchHay: String {
        if let h = hayCache { return h }
        let h = TrackSearch.hay([displayTitle, info?.artist, info?.album, fileName])
        hayCache = h
        return h
    }

    /// Подходит ли трек под строку поиска.
    func matches(_ query: String) -> Bool { TrackSearch.Query(query).matches(searchHay) }
    func matches(_ query: TrackSearch.Query) -> Bool { query.matches(searchHay) }

    /// Идёт конвертация (для любого iPod).
    var isConverting: Bool {
        perModel.values.contains { if case .converting = $0 { return true } else { return false } }
    }

    var isActive: Bool { isConverting || perModel.values.contains(.queued) }

    func load() async {
        do {
            let info = try await FFmpeg.probeAudio(url)
            self.info = info
            rating = info.rating ?? 0
            // Теги уже дописывались раньше — возвращаем пометку «Дополнено из Apple Music».
            if let restored = MetaMarks.restore(url: url, info: info) {
                fetched = restored
                metaStatus = .found
                tagsWritten = true
            }
            base = .ready
            if let idx = info.coverStreamIndex {
                artwork = await FFmpeg.coverThumbnail(url, index: idx)
            }
        } catch {
            base = .failed(error.localizedDescription)
            AppLog.error("Track not readable: \(url.path) — \(error.localizedDescription)")
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
    func convert(plan: AudioPlan, model: IPodModel, into folder: URL, completion: @escaping @MainActor (URL?) -> Void) {
        if viewModel == nil { viewModel = model }
        guard let info, let ffmpeg = FFmpeg.tool("ffmpeg") else {
            perModel[model] = .failed(L.toolNotFound("ffmpeg"))
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
        perModel[model] = .converting(0)
        do {
            try job.start(
                ffmpeg: ffmpeg, args: args, duration: info.duration,
                progress: { [weak self] p in
                    Task { @MainActor in
                        guard let self, case .converting? = self.perModel[model] else { return }
                        self.perModel[model] = .converting(p)
                    }
                },
                completion: { [weak self] status, stderr in
                    Task { @MainActor in
                        guard let self else { return }
                        self.job = nil
                        if job.cancelled {
                            try? FileManager.default.removeItem(at: output)
                            self.perModel[model] = nil
                            completion(nil)
                        } else if status == 0 {
                            self.perModel[model] = .done(output)
                            self.loadOutputInfo(output, for: model)
                            completion(output)
                        } else {
                            try? FileManager.default.removeItem(at: output)
                            self.perModel[model] = .failed(FFmpeg.ffmpegOutputLine(stderr))
                            AppLog.error("Track convert failed: \(self.url.path) [\(model.rawValue)] — \(AppLog.ffmpegTail(stderr))")
                            completion(nil)
                        }
                    }
                }
            )
        } catch {
            perModel[model] = .failed(error.localizedDescription)
            completion(nil)
        }
    }

    func cancel() {
        for (m, st) in perModel where st == .queued { perModel[m] = nil }
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
    func copyAsIs(model: IPodModel, into folder: URL, completion: @escaping @MainActor (URL?) -> Void) {
        if viewModel == nil { viewModel = model }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let src = url
        let dest = Self.uniqueURL(in: folder, base: src.deletingPathExtension().lastPathComponent,
                                  ext: src.pathExtension.isEmpty ? "m4a" : src.pathExtension)
        perModel[model] = .converting(0)
        Task.detached(priority: .userInitiated) {
            let error: String? = {
                do { try FileManager.default.copyItem(at: src, to: dest); return nil }
                catch { return error.localizedDescription }
            }()
            await MainActor.run {
                if let error {
                    self.perModel[model] = .failed(error)
                    completion(nil)
                } else {
                    self.perModel[model] = .done(dest)
                    self.loadOutputInfo(dest, for: model)
                    completion(dest)
                }
            }
        }
    }
}

#endif
