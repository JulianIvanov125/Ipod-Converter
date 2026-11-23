import Foundation

/// Добавляет готовый файл в Music.app в плейлист конкретного iPod.
/// В Finder для каждого iPod выбирается синхронизация только «своего» плейлиста,
/// поэтому ролик для 5G не попадёт на nano 7 и наоборот.
enum MusicLibrary {
    /// Что добавить в «Музыку». name/artist/album — для поиска уже существующего трека (без дубликатов).
    struct Item {
        var file: URL
        var rating: Int?
        var name = ""
        var artist = ""
        var album = ""
        /// Обложка для форматов, которые не хранят её внутри (WAV/AIFF).
        var cover: URL?
    }

    // argv: плейлист, "video"|"song", затем по 6 значений на трек: файл, оценка (-1 нет), название, артист, альбом, обложка ("" нет).
    // Уже есть в медиатеке (то же название + артист + альбом) — не дублируем: перепривязываем к новому файлу
    // и кладём в плейлист, если его там нет. Возвращает persistent ID (по строке на трек).
    private static let script = """
    on run argv
        set pName to item 1 of argv
        set asVideo to (item 2 of argv) is "video"
        -- Пустое имя плейлиста — только в медиатеку (треки: пользователь сам собирает плейлисты).
        set pl to missing value
        if pName is not "" then
            tell application "Music"
                if not (exists user playlist pName) then
                    make new user playlist with properties {name:pName}
                end if
                set pl to user playlist pName
            end tell
        end if
        set pids to {}
        set i to 3
        repeat while i + 5 ≤ (count of argv)
            set f to POSIX file (item i of argv)
            set r to (item (i + 1) of argv) as integer
            set tName to item (i + 2) of argv
            set tArtist to item (i + 3) of argv
            set tAlbum to item (i + 4) of argv
            set coverPath to item (i + 5) of argv
            -- Каждый трек отдельно: ошибка одного не останавливает остальные, а в ответе видно, какой упал.
            try
                tell application "Music"
                    set found to {}
                    if tName is not "" then
                        try
                            set found to (every file track of library playlist 1 whose name is tName and artist is tArtist and album is tAlbum)
                        end try
                    end if
                    if (count of found) > 0 then
                        set t to item 1 of found
                        try
                            set location of t to f
                        end try
                        set pid to persistent ID of t
                        if pl is not missing value and not (exists (some track of pl whose persistent ID is pid)) then
                            duplicate t to pl
                        end if
                    else
                        -- «add» иногда ничего не возвращает (файл уже в медиатеке и т. п.) — тогда ищем трек сами.
                        set t to missing value
                        try
                            if pl is missing value then
                            set t to add f
                        else
                            set t to add f to pl
                        end if
                        end try
                        if t is missing value and tName is not "" then
                            delay 0.5
                            try
                                set t to item 1 of (every file track of library playlist 1 whose name is tName and artist is tArtist and album is tAlbum)
                                set pid to persistent ID of t
                                if pl is not missing value and not (exists (some track of pl whose persistent ID is pid)) then
                                    duplicate t to pl
                                end if
                            end try
                        end if
                    end if
                    if t is missing value then
                        -- Не нашли — пропускаем только этот трек, остальные добавляются.
                        set end of pids to ""
                    else
                    if asVideo then
                        try
                            set media kind of t to music video
                        end try
                    end if
                    if r > -1 then
                        try
                            set rating of t to r
                        end try
                    end if
                    if coverPath is not "" then
                        try
                            set data of artwork 1 of t to (read (POSIX file coverPath) as picture)
                        end try
                    end if
                    set end of pids to (persistent ID of t)
                    end if
                end tell
            on error errMsg
                set end of pids to ("ERR:" & errMsg)
            end try
            set i to i + 6
        end repeat
        set AppleScript's text item delimiters to linefeed
        return pids as text
    end run
    """

    private static let ratingScript = """
    on run argv
        tell application "Music"
            set rating of (first track whose persistent ID is (item 1 of argv)) to ((item 2 of argv) as integer)
        end tell
    end run
    """

    /// Поменять оценку трека в «Музыке» (0–100, 20 = одна звезда). Оттуда она уйдёт и на iPod.
    static func setRating(persistentID: String, rating: Int) async throws {
        _ = try await run(ratingScript, [persistentID, "\(rating)"], app: L.musicApp)
    }

    // TV.app: фильмы и сериалы. argv: плейлист, "movie"|"tv", шоу, сезон, серия, файл
    private static let tvScript = """
    on run argv
        set pName to item 1 of argv
        set kind to item 2 of argv
        set f to POSIX file (item 6 of argv)
        tell application "TV"
            if not (exists user playlist pName) then
                make new user playlist with properties {name:pName}
            end if
            set t to add f to user playlist pName
            try
                if kind is "tv" then
                    set media kind of t to TV show
                    set show of t to (item 3 of argv)
                    set season number of t to ((item 4 of argv) as integer)
                    set episode number of t to ((item 5 of argv) as integer)
                else
                    set media kind of t to movie
                end if
            end try
        end tell
    end run
    """

    /// Фильм или серия → TV.app, в плейлист iPod. Теги сериала дублируются и в самом файле.
    static func addToTV(_ file: URL, playlist: String, meta: VideoMeta) async throws {
        let kind = meta.category == .serial ? "tv" : "movie"
        _ = try await run(tvScript, [playlist, kind, meta.show, "\(meta.season)", "\(meta.episode)", file.path], app: L.tvApp)
    }

    static func add(_ file: URL, playlist: String, name: String = "", artist: String = "") async throws {
        _ = try await add([Item(file: file, rating: nil, name: name, artist: artist)], playlist: playlist, asMusicVideo: true)
    }

    /// Добавить пачку файлов одним запуском AppleScript; возвращает persistent ID в том же порядке.
    /// Ответ на каждый трек по порядку: persistent ID, пусто (не нашли) или «ERR:текст ошибки».
    static func add(_ items: [Item], playlist: String, asMusicVideo: Bool) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        let args = items.flatMap { [$0.file.path, "\($0.rating ?? -1)", $0.name, $0.artist, $0.album, $0.cover?.path ?? ""] }
        let out = try await run(script, [playlist, asMusicVideo ? "video" : "song"] + args, app: L.musicApp)
        return out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Файлы медиатеки «Музыки»: путь (NFC) → persistent ID. Одним запросом, ~1 с на 1500 треков.
    static func libraryIndex() async throws -> [String: String] {
        let out = try await run(indexScript, [], app: L.musicApp)
        var d: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            d[normPath(parts[1])] = parts[0]
        }
        return d
    }

    static func normPath(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    private static let indexScript = """
    on run argv
        tell application "Music"
            set locs to location of every file track of library playlist 1
            set ids to persistent ID of every file track of library playlist 1
        end tell
        set out to ""
        repeat with k from 1 to count locs
            set p to ""
            try
                set p to POSIX path of (item k of locs)
            end try
            set out to out & (item k of ids) & tab & p & linefeed
        end repeat
        return out
    end run
    """

    /// Положить треки, которые уже есть в медиатеке, в плейлист (создать, если нет). Повторно не добавляет.
    static func addToPlaylist(_ persistentIDs: [String], playlist: String) async throws {
        guard !persistentIDs.isEmpty, !playlist.isEmpty else { return }
        _ = try await run(playlistScript, [playlist] + persistentIDs, app: L.musicApp)
    }

    private static let playlistScript = """
    on run argv
        set pName to item 1 of argv
        tell application "Music"
            if not (exists user playlist pName) then make new user playlist with properties {name:pName}
            set pl to user playlist pName
            repeat with i from 2 to count argv
                set pid to item i of argv
                try
                    if not (exists (some track of pl whose persistent ID is pid)) then
                        duplicate (some track of library playlist 1 whose persistent ID is pid) to pl
                    end if
                end try
            end repeat
        end tell
        return ""
    end run
    """

    /// Поставить треку в «Музыке» обложку заново (та же картинка из файла). Чинит серые альбомы:
    /// «Музыка» перестраивает запись обложки. Ответ по файлу: «1» — поставлено, «0» — нет в медиатеке, «ERR:…».
    static func reapplyArtwork(_ items: [(file: URL, cover: URL)]) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        let out = try await run(artworkScript, items.flatMap { [$0.file.path, $0.cover.path] }, app: L.musicApp)
        return out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static let artworkScript = """
    on run argv
        tell application "Music"
            set allTracks to file tracks of library playlist 1
            set locs to location of every file track of library playlist 1
        end tell
        set paths to {}
        repeat with l in locs
            try
                set end of paths to POSIX path of l
            on error
                set end of paths to ""
            end try
        end repeat
        set out to ""
        repeat with i from 1 to (count argv) by 2
            set p to item i of argv
            set c to item (i + 1) of argv
            set n to 0
            try
                repeat with k from 1 to (count paths)
                    if item k of paths is p then
                        tell application "Music" to set data of artwork 1 of (item k of allTracks) to (read (POSIX file c) as picture)
                        set n to 1
                    end if
                end repeat
                set out to out & n & linefeed
            on error e
                set out to out & "ERR:" & e & linefeed
            end try
        end repeat
        return out
    end run
    """

    /// «Музыка» хранит теги и обложку у себя и сама файл не перечитывает. После записи тегов в файл
    /// просим её обновить трек (refresh), а обложку, если её не было, ставим явно.
    /// Ответ по каждому файлу: «сколько треков обновлено|новый путь» или «ERR:…».
    /// Новый путь — если «Музыка» сама переименовала файл («Упорядочивать папку медиатеки»).
    static func refresh(_ items: [(file: URL, cover: URL?)]) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        let args = items.flatMap { [$0.file.path, $0.cover?.path ?? ""] }
        let out = try await run(refreshScript, args, app: L.musicApp)
        return out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static let refreshScript = """
    on run argv
        set out to ""
        tell application "Music"
            -- Расположения всех файловых треков один раз: поиск «whose location is» не находит.
            set allTracks to file tracks of library playlist 1
            set locs to location of every file track of library playlist 1
        end tell
        set paths to {}
        repeat with l in locs
            try
                set end of paths to POSIX path of l
            on error
                set end of paths to ""
            end try
        end repeat
        tell application "Music"
            repeat with i from 1 to (count argv) by 2
                set p to item i of argv
                set c to item (i + 1) of argv
                set n to 0
                set np to ""
                try
                    repeat with k from 1 to (count paths)
                        if item k of paths is p then
                            set t to item k of allTracks
                            refresh t
                            if c is not "" then
                                try
                                    set data of artwork 1 of t to (read (POSIX file c) as picture)
                                end try
                            end if
                            set n to n + 1
                            try
                                set np to POSIX path of ((location of t) as alias)
                            end try
                        end if
                    end repeat
                    set out to out & n & "|" & np & linefeed
                on error e
                    set out to out & "ERR:" & e & linefeed
                end try
            end repeat
        end tell
        return out
    end run
    """

    @discardableResult
    private static func run(_ source: String, _ argv: [String], app: String) async throws -> String {
        // Партия из 50 треков в «Музыку» может идти несколько минут — ждём до 15.
        let r = try await ProcessRunner.run("/usr/bin/osascript", ["-e", source] + argv, timeout: 900)
        if r.timedOut { throw FFmpegError.failed(L.cantAddTo(app) + L.processTimedOut) }
        let status = r.status, stdout = String(decoding: r.out, as: UTF8.self)
        guard status == 0 else {
            let msg = String(decoding: r.err, as: UTF8.self)
            if msg.contains("-1743") { throw FFmpegError.failed(L.noAppAccess(app)) }
            throw FFmpegError.failed(L.cantAddTo(app) + FFmpeg.ffmpegOutputLine(msg))
        }
        return stdout
    }
}
