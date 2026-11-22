import UniformTypeIdentifiers
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class VideoItem: Identifiable {
    enum State: Equatable {
        case loading
        case ready
        case converting(Double)
        case done(URL)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var info: MediaInfo?
    var thumbnail: NSImage?
    /// Отмечено галочкой (режим «Выбранные»).
    var isChecked = false
    /// Свои настройки выхода для этого видео (nil — общие).
    var outputOverride: VideoOverride?
    /// Категория и теги (определяются автоматически, пользователь может поправить).
    var meta: VideoMeta?
    /// JPEG-превью во временной папке — вшивается в готовый файл как обложка.
    @ObservationIgnored private var coverFile: URL?
    var state: State = .loading
    var usedModel: IPodModel?
    var usedSettings: EncodeSettings?
    var outputBytes: Int64?
    /// Статус добавления в Music.app (nil — не добавляли).
    var musicStatus: (text: String, ok: Bool)?
    @ObservationIgnored private var addToMusic = false
    @ObservationIgnored private var usedMeta: VideoMeta?

    /// Папка и имя файла по категории:
    /// Music Videos/«Артист - Песня», Films/«Название (Год)», Serials/Шоу/Season N/«Шоу S01E03 Название».
    static func destination(for m: VideoMeta, videoRoot: URL, fallback: URL) -> (URL, String) {
        let cat = videoRoot.appendingPathComponent(m.category.folderName, isDirectory: true)
        let fb = fallback.deletingPathExtension().lastPathComponent
        switch m.category {
        case .musicVideo:
            let name = m.artist.isEmpty ? m.title : "\(m.artist) - \(m.title)"
            return (cat, safe(name.isEmpty ? fb : name))
        case .film:
            let name = m.year.isEmpty ? m.title : "\(m.title) (\(m.year))"
            return (cat, safe(name.isEmpty ? fb : name))
        case .serial:
            let show = safe(m.show.isEmpty ? "Unknown" : m.show)
            let folder = cat.appendingPathComponent(show, isDirectory: true)
                .appendingPathComponent("Season \(m.season)", isDirectory: true)
            let id = String(format: "S%02dE%02d", m.season, m.episode)
            return (folder, safe("\(show) \(id)" + (m.title.isEmpty ? "" : " \(m.title)")))
        }
    }

    private static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }
    @ObservationIgnored private var job: ConversionJob?

    init(url: URL) { self.url = url }

    var displayTitle: String {
        if let m = meta {
            switch m.category {
            case .serial: return m.show + String(format: " · S%02dE%02d", m.season, m.episode) + (m.title.isEmpty ? "" : " · \(m.title)")
            case .musicVideo: return m.artist.isEmpty ? m.title : "\(m.artist) — \(m.title)"
            case .film: return m.year.isEmpty ? m.title : "\(m.title) (\(m.year))"
            }
        }
        return info?.title ?? url.deletingPathExtension().lastPathComponent
    }

    var isConverting: Bool {
        if case .converting = state { return true }
        return false
    }

    func load() async {
        do {
            let info = try await FFmpeg.probe(url)
            self.info = info
            meta = VideoClassifier.guess(url: url, info: info)
            state = .ready
            if let jpeg = await FFmpeg.preview(url, info: info) {
                thumbnail = NSImage(data: jpeg)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iPodConverter", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("\(id.uuidString).jpg")
                if (try? jpeg.write(to: file)) != nil { coverFile = file }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// videoRoot — папка «iPod Converter Video».
    func convert(model: IPodModel, settings: EncodeSettings, videoRoot: URL, addToMusic: Bool) {
        guard let info, !isConverting else { return }
        guard let ffmpeg = FFmpeg.tool("ffmpeg") else {
            state = .failed(FFmpegError.notFound("ffmpeg").localizedDescription)
            return
        }
        let meta = self.meta ?? VideoMeta(category: .film, title: url.deletingPathExtension().lastPathComponent)
        let (folder, base) = Self.destination(for: meta, videoRoot: videoRoot, fallback: url)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = Self.uniqueURL(in: folder, base: "\(base) [\(model.fileSuffix)]", ext: settings.container.rawValue)
        let cover = coverFile.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let args = FFmpeg.arguments(input: url, output: output, info: info, settings: settings, cover: cover, meta: meta)
        usedMeta = meta

        let job = ConversionJob()
        self.job = job
        usedModel = model
        usedSettings = settings
        outputBytes = nil
        musicStatus = nil
        self.addToMusic = addToMusic
        state = .converting(0)

        do {
            try job.start(
                ffmpeg: ffmpeg, args: args, duration: info.duration,
                progress: { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self, self.isConverting else { return }
                        self.state = .converting(p)
                    }
                },
                completion: { [weak self] status, stderr in
                    Task { @MainActor [weak self] in
                        self?.finish(status: status, stderr: stderr, output: output, job: job, model: model)
                    }
                }
            )
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func finish(status: Int32, stderr: String, output: URL, job: ConversionJob, model: IPodModel) {
        self.job = nil
        if job.cancelled {
            try? FileManager.default.removeItem(at: output)
            state = .ready
            return
        }
        if status == 0 {
            outputBytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
            state = .done(output)
            guard addToMusic else {
                Notifier.notify(
                    title: L.videoReady(model.title),
                    body: L.convertedBody(displayTitle, folder: output.deletingLastPathComponent().lastPathComponent),
                    fileURL: output
                )
                return
            }
            let meta = usedMeta
            let inTV = meta.map { $0.category != .musicVideo } ?? false
            musicStatus = (inTV ? L.addingToTV : L.addingToMusic, true)
            Task {
                do {
                    if let meta, inTV {
                        try await MusicLibrary.addToTV(output, playlist: model.playlistName, meta: meta)
                    } else {
                        try await MusicLibrary.add(output, playlist: model.playlistName)
                    }
                    musicStatus = (inTV ? L.inTV(model.playlistName) : L.inMusic(model.playlistName), true)
                    Notifier.notify(
                        title: L.videoReady(model.title),
                        body: L.addedBody(displayTitle, model.playlistName),
                        fileURL: output
                    )
                } catch {
                    musicStatus = (error.localizedDescription, false)
                    Notifier.notify(
                        title: L.videoReady(model.title),
                        body: L.notAddedBody(error.localizedDescription),
                        fileURL: output
                    )
                }
            }
        } else {
            try? FileManager.default.removeItem(at: output)
            state = .failed(FFmpeg.ffmpegOutputLine(stderr))
        }
    }

    func cancel() { job?.cancel() }

    /// До конвертации — где лежит оригинал, после — готовый файл.
    func revealInFinder() {
        if case .done(let out) = state, FileManager.default.fileExists(atPath: out.path) {
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func uniqueURL(in folder: URL, base: String, ext: String = "m4v") -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

@MainActor
@Observable
final class Store {
    enum Section: String { case music, videos }
    enum MusicScope: String { case all, selected }

    var items: [VideoItem] = []
    var tracks: [TrackItem] = []
    var section: Section {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "section") }
    }
    var musicScope: MusicScope = .all
    /// Поиск по трекам (латиница = кириллица, неверная раскладка).
    var trackSearch = ""
    /// Сортировка списка треков; nil — в порядке добавления.
    var trackSort: TrackSortKey?
    var sortAscending = true

    /// Клик по заголовку: ↑ → ↓ → исходный порядок.
    func toggleSort(_ key: TrackSortKey) {
        if trackSort != key { trackSort = key; sortAscending = true }
        else if sortAscending { sortAscending = false }
        else { trackSort = nil; sortAscending = true }
    }

    /// То, что видно в списке: после поиска и сортировки. По нему же идут «следующий/предыдущий» в плеере.
    var visibleTracks: [TrackItem] {
        var list = tracks.filter { t in
            // «Выбранные» — показываем только отмеченные; «Все» — весь список (отметки остаются).
            (musicScope == .all || t.isChecked)
                && TrackSearch.matches(trackSearch, in: [t.displayTitle, t.info?.artist, t.info?.album, t.url.lastPathComponent])
        }
        guard let key = trackSort else { return list }
        let m = model
        func planRank(_ t: TrackItem) -> Int {
            switch t.plan(for: m) {
            case .compatible: 0
            case .alac: 1
            case .aac: 2
            case .mp3: 3
            case nil: 4
            }
        }
        list.sort { a, b in
            let less: Bool
            switch key {
            case .title: less = a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
            case .type: less = (a.info?.typeLabel ?? "", a.info?.codec ?? "") < (b.info?.typeLabel ?? "", b.info?.codec ?? "")
            case .bitrate: less = (a.info?.bitrate ?? 0) < (b.info?.bitrate ?? 0)
            case .size: less = (a.info?.fileSize ?? 0) < (b.info?.fileSize ?? 0)
            case .rating: less = a.rating < b.rating
            case .target: less = planRank(a) < planRank(b)
            }
            return sortAscending ? less : !less && !(a === b)
        }
        return list
    }
    /// Итог последней пачки треков (для строки состояния внизу).
    var musicBatchStatus: (text: String, ok: Bool)?

    // Очередь конвертации треков
    @ObservationIgnored private var musicQueue: [TrackItem] = []
    private(set) var musicRunning = 0
    @ObservationIgnored private var batch = (model: IPodModel.classic5G, outputs: [(URL, TrackItem)](), converted: 0, kept: 0, failed: 0)
    private static let maxParallelTracks = 3
    var model: IPodModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "model") }
    }
    var addToMusic: Bool {
        didSet { UserDefaults.standard.set(addToMusic, forKey: "addToMusic") }
    }
    /// Режим «Максимум» (640×480, 1.5 Мбит/с) для моделей, которые его поддерживают.
    var maxQuality: Bool {
        didSet { UserDefaults.standard.set(maxQuality, forKey: "maxQuality") }
    }

    /// Параметры для выбранной вкладки.
    var currentSettings: EncodeSettings { VideoOutputSettings.shared.apply(to: model.settings(max: maxQuality)) }

    /// Настройки для конкретного видео: его собственные или общие.
    func settings(for item: VideoItem) -> EncodeSettings {
        let base = model.settings(max: maxQuality)
        if let o = item.outputOverride { return o.apply(to: base) }
        return VideoOutputSettings.shared.apply(to: base)
    }
    /// Избранные модели — из них строятся вкладки.
    private(set) var favorites: Set<IPodModel> {
        didSet { UserDefaults.standard.set(favorites.map(\.rawValue), forKey: "favorites") }
    }

    /// Вкладки: избранное в порядке каталога (по году выхода).
    var favoriteModels: [IPodModel] { IPodModel.allCases.filter { favorites.contains($0) } }

    func isFavorite(_ m: IPodModel) -> Bool { favorites.contains(m) }

    /// Идёт ли сейчас конвертация под этот iPod.
    func isConverting(for m: IPodModel) -> Bool {
        items.contains { $0.isConverting && $0.usedModel == m } || (isMusicBusy && batch.model == m)
    }

    /// Убрать вкладку (снять звёздочку). Конвертации под этот iPod останавливаются.
    /// Вкладки подключённых iPod, которые пользователь закрыл (до отключения устройства).
    @ObservationIgnored private var dismissedConnected: Set<IPodModel> = []

    /// Подключили iPod: добавляем его вкладку и выбираем (если ничего не конвертируется).
    func iPodConnected(_ m: IPodModel) {
        guard !dismissedConnected.contains(m) else { return }
        if !favorites.contains(m) { favorites.insert(m) }
        if !isBusy { model = m }
    }

    func iPodDisconnected(_ m: IPodModel) {
        dismissedConnected.remove(m)
    }

    func removeTab(_ m: IPodModel) {
        guard favorites.contains(m), favorites.count > 1 else { return }
        // Закрыли вкладку подключённого iPod — не навязываем её снова, пока его не переподключат.
        if IPodDetector.shared.isConnected(m) { dismissedConnected.insert(m) }
        for item in items where item.isConverting && item.usedModel == m { item.cancel() }
        if isMusicBusy && batch.model == m { cancelMusic() }
        toggleFavorite(m)
    }

    func toggleFavorite(_ m: IPodModel) {
        if favorites.contains(m) {
            guard favorites.count > 1 else { return }
            favorites.remove(m)
            if model == m { model = favoriteModels.first ?? .classic5G }
        } else {
            favorites.insert(m)
        }
    }

    // MARK: - Папки для готовых файлов
    //
    // Пользователь выбирает корневую папку (спрашиваем при каждой конвертации),
    // внутри создаются «iPod Converter Music» и «iPod Converter Video»
    // (а в ней — «Music Videos», «Films», «Serials»).

    static let musicFolderName = "iPod Converter Music"
    static let videoFolderName = "iPod Converter Video"
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser

    var rootFolder: URL {
        didSet { UserDefaults.standard.set(rootFolder.path, forKey: "rootFolder") }
    }

    var outputFolder: URL { rootFolder.appendingPathComponent(Self.videoFolderName, isDirectory: true) }
    var musicFolder: URL { rootFolder.appendingPathComponent(Self.musicFolderName, isDirectory: true) }
    var musicDestination: URL { musicFolder }

    /// Папка назначения для текущего раздела.
    var currentDestination: URL { section == .music ? musicFolder : outputFolder }
    var isDefaultFolder: Bool { rootFolder.standardizedFileURL == Self.defaultRoot.standardizedFileURL }

    /// Создаёт всю структуру папок в корне.
    func createFolderStructure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        for c in VideoCategory.allCases {
            try? fm.createDirectory(at: outputFolder.appendingPathComponent(c.folderName, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
    }

    /// Папку уже выбирали — больше не спрашиваем (сменить можно кнопкой «Изменить…» внизу).
    private(set) var hasChosenRoot: Bool {
        didSet { UserDefaults.standard.set(hasChosenRoot, forKey: "rootChosen") }
    }

    /// Перед конвертацией: спрашиваем папку только в первый раз
    /// или если выбранная папка пропала (например, отключён внешний диск).
    func ensureDestination() -> Bool {
        if hasChosenRoot, FileManager.default.fileExists(atPath: rootFolder.path) {
            createFolderStructure()
            return true
        }
        return askDestination()
    }

    /// Спрашивает, куда сохранять. false — пользователь отменил.
    @discardableResult
    func askDestination() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L.chooseButton
        panel.message = L.chooseRootMessage
        panel.directoryURL = rootFolder
        guard panel.runModal() == .OK, var url = panel.url else { return false }
        // Выбрали саму «iPod Converter Music/Video» — корнем считаем папку выше.
        if [Self.musicFolderName, Self.videoFolderName].contains(url.lastPathComponent) {
            url = url.deletingLastPathComponent()
        }
        rootFolder = url
        hasChosenRoot = true
        createFolderStructure()
        return true
    }

    func chooseOutputFolder() { askDestination() }

    func resetOutputFolder() { rootFolder = Self.defaultRoot }

    private static func savedFolder(_ key: String, default def: URL) -> URL {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return def }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    init() {
        section = Section(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .videos
        rootFolder = Self.savedFolder("rootFolder", default: Self.defaultRoot)
        // Папку уже выбирали в прошлых версиях, если она сохранена.
        hasChosenRoot = UserDefaults.standard.bool(forKey: "rootChosen")
            || UserDefaults.standard.string(forKey: "rootFolder") != nil
        model = IPodModel(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .classic5G
        addToMusic = UserDefaults.standard.object(forKey: "addToMusic") as? Bool ?? true
        maxQuality = UserDefaults.standard.bool(forKey: "maxQuality")
        let saved = (UserDefaults.standard.stringArray(forKey: "favorites") ?? []).compactMap(IPodModel.init(rawValue:))
        favorites = Set(saved.isEmpty ? IPodModel.defaultFavorites : saved)
        if !favorites.contains(model) { favorites.insert(model) }
        let detector = IPodDetector.shared
        detector.onConnect = { [weak self] m in self?.iPodConnected(m) }
        detector.preferEnhanced5G = { [weak self] in
            guard let self else { return false }
            return self.favorites.contains(.classic55G) && !self.favorites.contains(.classic5G)
        }
        detector.onDisconnect = { [weak self] m in self?.iPodDisconnected(m) }
        // Не в самотестах — им опрос USB ни к чему.
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") }) {
            DispatchQueue.main.async { detector.start() }
        }
    }

    var isBusy: Bool { items.contains { $0.isConverting } || isMusicBusy }
    var isMusicBusy: Bool { musicRunning > 0 || !musicQueue.isEmpty }

    /// Принимает файлы и папки: аудио уходит в «Музыку», остальное — в «Видео».
    func add(_ urls: [URL]) {
        var addedAudio = 0, addedVideo = 0
        let files = Self.expand(urls)
        for file in files {
            if AudioRules.audioExtensions.contains(file.pathExtension.lowercased()) {
                guard !tracks.contains(where: { $0.url == file }) else { continue }
                let t = TrackItem(url: file)
                tracks.append(t)
                addedAudio += 1
                Task {
                    await t.load()
                    MetadataFetcher.shared.enqueue(t)   // пустые теги/обложку — из интернета
                }
            } else {
                guard !items.contains(where: { $0.url == file }) else { continue }
                let item = VideoItem(url: file)
                items.append(item)
                addedVideo += 1
                Task { await item.load() }
            }
        }
        if addedAudio > 0 && addedVideo == 0 { section = .music }
        if addedVideo > 0 && addedAudio == 0 { section = .videos }
    }

    /// Видео, которые принимаем (ffmpeg читает почти всё; список — для фильтра папок и окна выбора).
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "divx", "xvid", "wmv", "asf", "flv", "f4v",
        "mpg", "mpeg", "mpe", "m1v", "m2v", "ts", "mts", "m2ts", "tod", "vob", "3gp", "3g2", "ogv",
        "rm", "rmvb", "dv", "mxf", "y4m", "nut", "amv", "h264", "hevc",
    ]

    /// Раскрывает папки (рекурсивно) в список файлов; из папок берём только аудио и видео.
    private static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { out.append(url); continue }
            let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                .compactMap { $0 as? URL } ?? []
            out += files
                .filter {
                    let e = $0.pathExtension.lowercased()
                    return AudioRules.audioExtensions.contains(e) || Self.videoExtensions.contains(e)
                }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return out
    }

    // MARK: - Просмотр

    /// Видео: оригиналы или готовые файлы; «следующее/предыдущее» идёт по этому же списку.
    func playVideo(_ item: VideoItem, converted: Bool) {
        let list: [(VideoItem, URL)] = items.compactMap { v in
            if converted { if case .done(let out) = v.state { return (v, out) } else { return nil } }
            return v.info != nil ? (v, v.url) : nil
        }
        let entries = list.map { v, url in
            PlayEntry(id: "\(converted ? "c" : "o")-\(v.id)", url: url, title: v.displayTitle,
                      subtitle: converted ? L.convertedFor(v.usedModel?.title ?? model.title) : L.original,
                      artwork: v.thumbnail, isVideo: true)
        }
        if let i = list.firstIndex(where: { $0.0.id == item.id }) { PlayerController.shared.play(entries, startAt: i) }
    }

    func playTrack(_ track: TrackItem, converted: Bool) {
        let list: [(TrackItem, URL)] = visibleTracks.compactMap { t in
            if converted {
                switch t.state {
                case .done(let out): return (t, out)
                case .kept: return (t, t.url)
                default: return nil
                }
            }
            return t.info != nil ? (t, t.url) : nil
        }
        let entries = list.map { t, url in
            PlayEntry(id: "\(converted ? "c" : "o")-\(t.id)", url: url, title: t.displayTitle,
                      subtitle: (t.info?.artist ?? L.unknownArtist) + " · " + (converted ? L.convertedShort : L.original),
                      artwork: t.artwork, isVideo: false,
                      // Обложку в полном качестве берём из оригинала: в готовом файле она ужата до 600 px.
                      coverSource: t.info?.coverStreamIndex.map { (t.url, $0) },
                      lyrics: t.info.map {
                          LyricsQuery(file: t.url, title: $0.title ?? t.url.deletingPathExtension().lastPathComponent,
                                      artist: $0.artist, album: $0.album, duration: $0.duration)
                      })
        }
        if let i = list.firstIndex(where: { $0.0.id == track.id }) { PlayerController.shared.play(entries, startAt: i) }
    }

    // MARK: - Музыка

    /// Треки, которые пойдут в работу: все или только отмеченные.
    /// Что пойдёт в конвертацию: отмеченные (если есть), иначе всё, что видно в списке.
    var tracksInScope: [TrackItem] {
        let visible = visibleTracks
        let checked = visible.filter(\.isChecked)
        return checked.isEmpty ? visible : checked
    }

    var hasCheckedTracks: Bool { visibleTracks.contains(where: \.isChecked) }

    var convertibleTracks: [TrackItem] {
        tracksInScope.filter { t in
            switch t.state {
            case .ready, .done, .kept, .failed: t.info != nil
            default: false
            }
        }
    }

    func convertTracks() {
        let list = convertibleTracks
        guard !list.isEmpty, !isMusicBusy, ensureDestination() else { return }
        batch = (model, [], 0, 0, 0)
        musicBatchStatus = nil
        let folder = musicDestination
        for t in list where t.plan(for: model) != nil {
            t.state = .queued
            musicQueue.append(t)
        }
        pumpMusic(folder: folder)
    }

    private func pumpMusic(folder: URL) {
        while musicRunning < Self.maxParallelTracks, !musicQueue.isEmpty {
            let t = musicQueue.removeFirst()
            guard t.state == .queued, let plan = t.plan(for: batch.model) else { continue }
            musicRunning += 1
            let done: @MainActor (URL?) -> Void = { [weak self] output in
                guard let self else { return }
                self.musicRunning -= 1
                if let output {
                    self.batch.outputs.append((output, t))
                    if plan == .compatible { self.batch.kept += 1 } else { self.batch.converted += 1 }
                } else if case .failed = t.state {
                    self.batch.failed += 1
                }
                self.pumpMusic(folder: folder)
            }
            if plan == .compatible && !t.needsRetag {
                t.copyAsIs(into: folder, completion: done)
            } else {
                t.convert(plan: plan, into: folder, completion: done)
            }
        }
        if musicRunning == 0 && musicQueue.isEmpty { finishMusicBatch() }
    }

    private func finishMusicBatch() {
        let b = batch
        guard b.converted + b.kept + b.failed > 0 else { return }
        let summary = L.musicSummary(converted: b.converted, kept: b.kept, failed: b.failed)
        let notifyFile = b.outputs.first?.0 ?? musicFolder
        guard addToMusic, !b.outputs.isEmpty else {
            musicBatchStatus = (summary, b.failed == 0)
            Notifier.notify(title: L.musicReady(b.model.title), body: summary, fileURL: notifyFile)
            return
        }
        musicBatchStatus = (L.addingToMusic, true)
        Task {
            do {
                let pids = try await MusicLibrary.add(
                    b.outputs.map { ($0.0, $0.1.rating > 0 ? $0.1.rating : nil) },
                    playlist: b.model.playlistName, asMusicVideo: false)
                for (pid, entry) in zip(pids, b.outputs) where !pid.isEmpty { entry.1.musicPersistentID = pid }
                musicBatchStatus = (summary + " · " + L.inMusic(b.model.playlistName), b.failed == 0)
                Notifier.notify(title: L.musicReady(b.model.title),
                                body: summary + " " + L.inMusic(b.model.playlistName) + ".", fileURL: notifyFile)
            } catch {
                musicBatchStatus = (error.localizedDescription, false)
                Notifier.notify(title: L.musicReady(b.model.title), body: L.notAddedBody(error.localizedDescription), fileURL: notifyFile)
            }
        }
    }

    /// Остановить всю пачку треков.
    func cancelMusic() {
        let queued = musicQueue
        musicQueue.removeAll()
        for t in queued { t.cancel() }
        for t in tracks where t.isConverting { t.cancel() }
    }

    func removeTrack(_ t: TrackItem) {
        musicQueue.removeAll { $0.id == t.id }
        t.cancel()
        tracks.removeAll { $0.id == t.id }
    }

    func clearTracks() {
        cancelMusic()
        if let cur = PlayerController.shared.current, !cur.isVideo { PlayerController.shared.close() }
        tracks.removeAll()
        musicScope = .all
        musicBatchStatus = nil
    }

    /// Звёзды 0–5. Если трек уже в «Музыке» — меняем и там (а оттуда при синхронизации — на iPod).
    func setRating(_ t: TrackItem, stars: Int) {
        let new = t.rating == stars * 20 ? 0 : stars * 20   // повторный клик по той же звезде — снять оценку
        t.rating = new
        guard let pid = t.musicPersistentID else { return }
        Task {
            do { try await MusicLibrary.setRating(persistentID: pid, rating: new) }
            catch { musicBatchStatus = (error.localizedDescription, false) }
        }
    }

    /// Отметка не переключает вид: «Выбранные» — отдельный фильтр списка.
    func setChecked(_ t: TrackItem, _ value: Bool) {
        t.isChecked = value
    }

    /// Отметить/снять видимые треки (с учётом поиска).
    func setAllChecked(_ value: Bool) {
        for t in visibleTracks { t.isChecked = value }
    }

    func openMusicFolder() {
        try? FileManager.default.createDirectory(at: musicDestination, withIntermediateDirectories: true)
        NSWorkspace.shared.open(musicDestination)
    }

    func convert(_ item: VideoItem) {
        guard ensureDestination() else { return }
        start(item)
    }

    private func start(_ item: VideoItem) {
        item.convert(model: model, settings: settings(for: item), videoRoot: outputFolder, addToMusic: addToMusic)
    }

    // MARK: - Выбор и фильтр видео

    /// Все или только отмеченные.
    var videoScope: MusicScope = .all
    /// Фильтр по типу: nil — все, иначе только клипы / фильмы / сериалы.
    var videoFilter: VideoCategory?

    /// Что видно в списке (с учётом фильтра по типу).
    var visibleVideos: [VideoItem] {
        items.filter { v in
            (videoScope == .all || v.isChecked) && (videoFilter == nil || v.meta?.category == videoFilter)
        }
    }

    var hasCheckedVideos: Bool { visibleVideos.contains(where: \.isChecked) }

    func videoCount(_ c: VideoCategory?) -> Int {
        c.map { cat in items.filter { $0.meta?.category == cat }.count } ?? items.count
    }

    var checkedVideos: [VideoItem] { items.filter(\.isChecked) }

    /// Что пойдёт в конвертацию по кнопке внизу: видимые (фильтр) — все или только отмеченные.
    var videosToConvert: [VideoItem] {
        let visible = visibleVideos
        let checked = visible.filter(\.isChecked)
        return (checked.isEmpty ? visible : checked).filter { v in
            switch v.state {
            case .ready, .failed, .done: v.info != nil
            default: false
            }
        }
    }

    func setVideoChecked(_ v: VideoItem, _ value: Bool) {
        v.isChecked = value
    }

    func setAllVideosChecked(_ value: Bool) {
        for v in visibleVideos { v.isChecked = value }
    }

    /// Поменять тип всем отмеченным: Клип / Фильм / Сериал.
    func applyCategory(_ c: VideoCategory) {
        for v in checkedVideos where !v.isConverting {
            guard var m = v.meta else { continue }
            if m.category == c { continue }
            m.category = c
            // Для сериала без названия шоу берём название файла/фильма.
            if c == .serial && m.show.isEmpty { m.show = m.title.isEmpty ? v.url.deletingPathExtension().lastPathComponent : m.title }
            v.meta = m
        }
    }

    func convertAll() {
        let list = videosToConvert
        guard !list.isEmpty, ensureDestination() else { return }
        for item in list { start(item) }
    }

    /// Очистить список видео (идущие конвертации останавливаются).
    func clearVideos() {
        for item in items where item.isConverting { item.cancel() }
        if let cur = PlayerController.shared.current, cur.isVideo { PlayerController.shared.close() }
        items.removeAll()
        videoScope = .all
        videoFilter = nil
    }

    func remove(_ item: VideoItem) {
        item.cancel()
        items.removeAll { $0.id == item.id }
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputFolder)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if section == .music {
            panel.canChooseDirectories = true
            panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder]
                + AudioRules.audioExtensions.compactMap { UTType(filenameExtension: $0) }
            panel.message = L.chooseTracks
        } else {
            panel.canChooseDirectories = false
            panel.canChooseDirectories = true
            panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .folder]
                + Self.videoExtensions.compactMap { UTType(filenameExtension: $0) }
            panel.message = L.chooseVideos
        }
        if panel.runModal() == .OK { add(panel.urls) }
    }
}
