import Foundation
import Observation

// MARK: - Что нашли

/// Теги, которых не было в файле и которые нашлись в интернете (ключи — как у ffmpeg).
struct FetchedMeta: Equatable {
    /// title, artist, album, album_artist, track («8/13»), disc («1/1»), date (год), genre
    var fields: [String: String] = [:]
    /// Обложка 1200×1200 во временной папке.
    var coverFile: URL?
    var source = "Apple Music"
    /// Обложка уже записана в файл (пометка восстановлена после перезапуска).
    var coverAdded = false

    var isEmpty: Bool { fields.isEmpty && coverFile == nil && !coverAdded }
}

enum MetaStatus: Equatable { case idle, searching, found, notFound }

// MARK: - Догадка по тегам, имени файла и папкам

struct TagGuess: Equatable {
    var artist: String?
    var album: String?
    var title: String
    var trackNo: Int?
    var duration: Double
    /// Альбом взят из тегов (надёжно), а не угадан по имени папки.
    var albumFromTags = false

    /// «Artist/Album (2013)/08 - Title.flac», «08. Artist - Title.mp3», «Artist - Album/Title.m4a»…
    static func from(url: URL, info: AudioInfo) -> TagGuess {
        var base = SeriesParser.normalize(url.deletingPathExtension().lastPathComponent)
        var trackNo = Int((info.tags["track"] ?? "").split(separator: "/").first.map(String.init) ?? "")
        // Номер трека в начале имени: «08 - », «08. », «8) », «A1 »
        if let m = base.range(of: #"^\s*[A-Da-d]?(\d{1,3})(?=[\s.\-_)])[\s.\-_)]+"#, options: .regularExpression) {
            let num = base[m].filter(\.isNumber)
            if trackNo == nil { trackNo = Int(num) }
            base = String(base[m.upperBound...])
        }
        var fileArtist: String?
        var title = base
        let parts = base.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            fileArtist = parts.first
            title = parts.last!
        }

        // Папки: «Artist/Album», «Artist - Album (2013)», «2013 - Album»
        let parent = url.deletingLastPathComponent().lastPathComponent
        let grand = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        var folderAlbum: String? = cleanFolder(parent)
        var folderArtist: String? = cleanFolder(grand)
        if let p = folderAlbum, p.contains(" - ") {
            let pp = p.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
            if pp.count == 2 {
                if Int(pp[0]) != nil { folderAlbum = pp[1] }                       // «2013 - Album»
                else { folderArtist = pp[0]; folderAlbum = pp[1] }                // «Artist - Album»
            }
        }
        // Служебные папки — не альбом и не артист.
        let junk: Set<String> = ["music", "музыка", "downloads", "загрузки", "desktop", "users", "volumes", "flac", "mp3", "cd1", "cd2", "disc 1", "disc 2"]
        if let a = folderAlbum, junk.contains(a.lowercased()) || a.count < 2 { folderAlbum = nil }
        if let a = folderArtist, junk.contains(a.lowercased()) || a.count < 2 || a.hasPrefix("iPod Converter") { folderArtist = nil }

        return TagGuess(
            artist: info.artist ?? fileArtist ?? folderArtist,
            album: info.album ?? folderAlbum,
            title: info.title ?? title,
            trackNo: trackNo,
            duration: info.duration,
            albumFromTags: info.album != nil
        )
    }

    private static func cleanFolder(_ s: String) -> String? {
        var t = SeriesParser.normalize(s)
        // «(2013)», «[FLAC 24-96]», «{WEB}» и прочие пометки релиза
        t = t.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression)
        t = SeriesParser.clean(t)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Поиск в iTunes Search API

// MARK: - Подписи

extension FetchedMeta {
    /// «альбом, год, жанр, обложка» — что именно дополнено.
    var summary: String {
        let order = ["title", "artist", "album", "album_artist", "track", "disc", "date", "genre"]
        var names = order.filter { fields[$0] != nil }.map(L.metaField)
        if coverFile != nil || coverAdded { names.append(L.metaField("cover")) }
        return names.joined(separator: ", ")
    }
}
