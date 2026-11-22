import AppKit
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

    var isEmpty: Bool { fields.isEmpty && coverFile == nil }
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

/// Дополняет пустые теги и обложки треков из каталога Apple Music (iTunes Search API).
/// Треки одной папки/альбома ищутся одним запросом; запросы идут не чаще раза в 3 секунды
/// (лимит Apple — около 20 в минуту). Туда уходят только артист, альбом и название.
@MainActor
@Observable
final class MetadataFetcher {
    static let shared = MetadataFetcher()

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "metaOnline") }
    }

    @ObservationIgnored private var pending: [TrackItem] = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var lastRequest = Date.distantPast
    @ObservationIgnored private var coverCache: [Int: URL] = [:]

    private init() {
        enabled = UserDefaults.standard.object(forKey: "metaOnline") as? Bool ?? true
    }

    /// Нужно ли что-то дополнять у трека.
    static func missing(_ info: AudioInfo) -> [String] {
        var m: [String] = []
        if info.title == nil { m.append("title") }
        if info.artist == nil { m.append("artist") }
        if info.album == nil { m.append("album") }
        if info.tags["album_artist"] == nil { m.append("album_artist") }
        if info.tags["track"] == nil { m.append("track") }
        if info.tags["disc"] == nil { m.append("disc") }
        if info.tags["date"] == nil && info.tags["year"] == nil { m.append("date") }
        if info.tags["genre"] == nil { m.append("genre") }
        if info.coverStreamIndex == nil { m.append("cover") }
        return m
    }

    func enqueue(_ t: TrackItem) {
        guard enabled, let info = t.info else { return }
        // Есть всё главное — не трогаем (номер диска/исполнитель альбома сами по себе не повод лезть в сеть).
        let need = Self.missing(info).filter { !["disc", "album_artist"].contains($0) }
        guard !need.isEmpty else { return }
        t.metaStatus = .searching
        pending.append(t)
        guard !running else { return }
        running = true
        Task { await processLoop() }
    }

    func waitUntilIdle() async {
        while running || !pending.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    private func processLoop() async {
        while true {
            // Небольшая пауза: треки папки догружаются — собираем их в одну группу.
            try? await Task.sleep(nanoseconds: 700_000_000)
            let batch = pending
            pending.removeAll()
            if batch.isEmpty { break }

            // Группы: один альбом (артист+альбом) — один запрос. Без альбома — по одному треку.
            var groups: [String: [(TrackItem, TagGuess)]] = [:]
            var order: [String] = []
            for t in batch {
                guard let info = t.info else { continue }
                let g = TagGuess.from(url: t.url, info: info)
                let key = g.album.map { "\(g.artist?.lowercased() ?? "")|\($0.lowercased())" } ?? "track|\(t.id)"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append((t, g))
            }
            for key in order {
                guard let group = groups[key] else { continue }
                await process(group)
            }
        }
        running = false
    }

    private func process(_ group: [(TrackItem, TagGuess)]) async {
        let first = group[0].1
        let term: String
        if let album = first.album {
            term = [first.artist, album].compactMap { $0 }.joined(separator: " ")
        } else {
            term = [first.artist, first.title].compactMap { $0 }.joined(separator: " ")
        }
        let songs = await search(term: term)
        var picks = Self.match(group.map(\.1), in: songs)

        // Альбом угадан по папке, а нашлось не то (папка оказалась не альбомом: «Загрузки», «meta»…) —
        // ищем каждый трек отдельно по «артист + название».
        if let album = first.album, !first.albumFromTags {
            let albumOK = picks.contains { p in
                p.map { Self.similarity(album, $0["collectionName"] as? String ?? "") > 0.5 } ?? false
            }
            if !albumOK {
                for (i, (_, g)) in group.enumerated() {
                    var single = g
                    single.album = nil
                    let s2 = await search(term: [g.artist, g.title].compactMap { $0 }.joined(separator: " "))
                    picks[i] = Self.match([single], in: s2).first ?? nil
                }
            }
        }
        for ((track, _), pick) in zip(group, picks) {
            guard let song = pick, let info = track.info else {
                track.metaStatus = .notFound
                continue
            }
            var meta = FetchedMeta()
            let missing = Set(Self.missing(info))
            func put(_ key: String, _ value: Any?) {
                guard missing.contains(key), let v = value.map({ "\($0)" }), !v.isEmpty, v != "0" else { return }
                meta.fields[key] = v
            }
            put("title", song["trackName"])
            put("artist", song["artistName"])
            put("album", song["collectionName"])
            put("album_artist", song["collectionArtistName"] ?? song["artistName"])
            if let n = song["trackNumber"] as? Int {
                put("track", (song["trackCount"] as? Int).map { "\(n)/\($0)" } ?? "\(n)")
            }
            if let n = song["discNumber"] as? Int {
                put("disc", (song["discCount"] as? Int).map { "\(n)/\($0)" } ?? "\(n)")
            }
            put("date", (song["releaseDate"] as? String).map { String($0.prefix(4)) })
            put("genre", song["primaryGenreName"])
            if missing.contains("cover"), let id = song["collectionId"] as? Int, let art = song["artworkUrl100"] as? String {
                meta.coverFile = await cover(collectionId: id, art100: art)
            }
            track.apply(meta)
        }
    }

    // MARK: Сеть

    private func search(term: String) async -> [[String: Any]] {
        // Не чаще раза в 3 секунды.
        let wait = 3.1 - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequest = Date()
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue("iPodConverter/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.filter { ($0["wrapperType"] as? String) == "track" }
    }

    private func cover(collectionId: Int, art100: String) async -> URL? {
        if let f = coverCache[collectionId], FileManager.default.fileExists(atPath: f.path) { return f }
        let big = art100.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
        guard let url = URL(string: big),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iPodConverter/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(collectionId).jpg")
        guard (try? data.write(to: file)) != nil else { return nil }
        coverCache[collectionId] = file
        return file
    }

    // MARK: Сопоставление

    /// Для каждого локального трека — лучшая песня из выдачи (или nil, если уверенного совпадения нет).
    /// Сначала выбирается одно издание альбома (то, где совпало больше всего треков), потом треки внутри него.
    nonisolated static func match(_ guesses: [TagGuess], in songs: [[String: Any]]) -> [[String: Any]?] {
        guard !songs.isEmpty else { return guesses.map { _ in nil } }
        let byCollection = Dictionary(grouping: songs) { ($0["collectionId"] as? Int) ?? 0 }
        let isAlbum = guesses.count > 1 || guesses.first?.album != nil

        func bestIn(_ list: [[String: Any]], for g: TagGuess) -> (song: [String: Any], score: Double)? {
            list.map { ($0, score(g, $0)) }
                .max { a, b in
                    if abs(a.1 - b.1) > 0.05 { return a.1 < b.1 }
                    // Почти равны: свой альбом артиста лучше сборника, студийный (меньше треков) лучше
                    // «Best of», и только потом — более ранний релиз.
                    let va = isCompilation(a.0), vb = isCompilation(b.0)
                    if va != vb { return va }
                    let ca = a.0["trackCount"] as? Int ?? 99, cb = b.0["trackCount"] as? Int ?? 99
                    if ca != cb { return ca > cb }
                    return (a.0["releaseDate"] as? String ?? "") > (b.0["releaseDate"] as? String ?? "")
                }
                .flatMap { $0.1 >= 1.0 ? $0 : nil }
        }

        if isAlbum {
            // Издание, где сумма уверенных совпадений больше; при равенстве — где число треков ближе к нашему.
            let ranked = byCollection.values.map { list -> ([[String: Any]], Double) in
                let total = guesses.compactMap { bestIn(list, for: $0)?.score }.reduce(0, +)
                let count = (list.first?["trackCount"] as? Int) ?? list.count
                return (list, total - Double(abs(count - guesses.count)) * 0.05)
            }.sorted { $0.1 > $1.1 }
            if let best = ranked.first, best.1 > 0 {
                return guesses.map { bestIn(best.0, for: $0)?.song }
            }
        }
        return guesses.map { bestIn(songs, for: $0)?.song }
    }

    /// Насколько песня похожа на трек: название (0…2), номер трека (+0.6), длительность (+0.8 / −1), артист/альбом (+0.4).
    nonisolated static func score(_ g: TagGuess, _ s: [String: Any]) -> Double {
        var sc = similarity(g.title, s["trackName"] as? String ?? "") * 2
        if let n = g.trackNo, n == s["trackNumber"] as? Int { sc += 0.6 }
        if let ms = s["trackTimeMillis"] as? Double, g.duration > 0 {
            let d = abs(ms / 1000 - g.duration)
            sc += d <= 3 ? 0.8 : d <= 8 ? 0.2 : -1
        }
        if let a = g.artist {
            let sa = max(similarity(a, s["artistName"] as? String ?? ""), similarity(a, s["collectionArtistName"] as? String ?? ""))
            sc += sa > 0.5 ? 0.2 : -0.3
        }
        let collection = s["collectionName"] as? String ?? ""
        if let al = g.album {
            if similarity(al, collection) > 0.5 { sc += 0.2 }
            // Точное совпадение названия альбома (без пометок в скобках) — сильный плюс.
            if bare(al) == bare(collection) && !collection.contains("(") { sc += 0.3 }
        }
        // Ремиксы, демо, live и прочие версии трека — только если они есть в названии файла.
        let versionWords = #"(?i)\b(remix|mix|demo|live|edit|version|instrumental|acoustic|karaoke|remaster(ed)?)\b"#
        let songTitle = s["trackName"] as? String ?? ""
        if songTitle.range(of: versionWords, options: .regularExpression) != nil,
           g.title.range(of: versionWords, options: .regularExpression) == nil { sc -= 0.4 }
        // Сборник разных исполнителей — только если альбом указан и совпал.
        if isCompilation(s), g.album.map({ similarity($0, collection) <= 0.5 }) ?? true { sc -= 0.3 }
        // Юбилейные/deluxe/live-издания и сборники — только если их явно указали.
        if isSpecialEdition(collection) && !isSpecialEdition(g.album ?? "") { sc -= 0.35 }
        return sc
    }

    nonisolated private static func bare(_ s: String) -> String {
        s.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func isCompilation(_ song: [String: Any]) -> Bool {
        let ca = (song["collectionArtistName"] as? String ?? "").lowercased()
        return ca.contains("various") || ca.contains("сборник") || ca.contains("verschiedene")
    }

    nonisolated static func isSpecialEdition(_ s: String) -> Bool {
        s.range(of: #"(?i)anniversary|deluxe|edition|remaster|expanded|\blive\b|karaoke|instrumental|tribute|greatest hits|best of|essential|collection|anthology|hits|version|\b\d{2}\b$"#,
                options: .regularExpression) != nil
    }

    /// Сходство строк 0…1 по словам, без регистра, диакритики, скобок «(feat. …)» и «(Remastered)».
    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            return Set(t.split(separator: " ").map(String.init).filter { !["the", "a", "feat", "ft"].contains($0) })
        }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        let inter = Double(wa.intersection(wb).count)
        return inter / Double(min(wa.count, wb.count)) * 0.7 + inter / Double(wa.union(wb).count) * 0.3
    }
}

// MARK: - Подписи

extension FetchedMeta {
    /// «альбом, год, жанр, обложка» — что именно дополнено.
    var summary: String {
        let order = ["title", "artist", "album", "album_artist", "track", "disc", "date", "genre"]
        var names = order.filter { fields[$0] != nil }.map(L.metaField)
        if coverFile != nil { names.append(L.metaField("cover")) }
        return names.joined(separator: ", ")
    }
}
