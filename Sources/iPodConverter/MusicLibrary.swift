import Foundation

/// Добавляет готовый файл в Music.app в плейлист конкретного iPod.
/// В Finder для каждого iPod выбирается синхронизация только «своего» плейлиста,
/// поэтому ролик для 5G не попадёт на nano 7 и наоборот.
enum MusicLibrary {
    // argv: имя плейлиста, "video"|"song", затем пары «файл, оценка 0–100 или -1».
    // Возвращает persistent ID добавленных треков (по строке на трек).
    private static let script = """
    on run argv
        set pName to item 1 of argv
        set asVideo to (item 2 of argv) is "video"
        tell application "Music"
            if not (exists user playlist pName) then
                make new user playlist with properties {name:pName}
            end if
        end tell
        set pids to {}
        set i to 3
        repeat while i < (count of argv)
            set f to POSIX file (item i of argv)
            set r to (item (i + 1) of argv) as integer
            tell application "Music"
                set t to add f to user playlist pName
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
                set end of pids to (persistent ID of t)
            end tell
            set i to i + 2
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

    static func add(_ file: URL, playlist: String) async throws {
        _ = try await add([(file, nil)], playlist: playlist, asMusicVideo: true)
    }

    /// Добавить пачку файлов одним запуском AppleScript; возвращает persistent ID в том же порядке.
    static func add(_ files: [(URL, Int?)], playlist: String, asMusicVideo: Bool) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let pairs = files.flatMap { [$0.0.path, "\($0.1 ?? -1)"] }
        let out = try await run(script, [playlist, asMusicVideo ? "video" : "song"] + pairs, app: L.musicApp)
        return out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @discardableResult
    private static func run(_ source: String, _ argv: [String], app: String) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source] + argv
        let err = Pipe(), out = Pipe()
        p.standardError = err
        p.standardOutput = out
        try p.run()
        let (status, stdout): (Int32, String) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
        guard status == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if msg.contains("-1743") { throw FFmpegError.failed(L.noAppAccess(app)) }
            throw FFmpegError.failed(L.cantAddTo(app) + FFmpeg.ffmpegOutputLine(msg))
        }
        return stdout
    }
}
