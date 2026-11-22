import Foundation

// MARK: - Категория и метаданные видео

enum VideoCategory: String, CaseIterable, Identifiable {
    case musicVideo, film, serial
    var id: String { rawValue }

    /// Имя подпапки внутри «iPod Converter Video».
    var folderName: String {
        switch self {
        case .musicVideo: "Music Videos"
        case .film: "Films"
        case .serial: "Serials"
        }
    }
}

/// То, что уйдёт в теги готового файла и определит папку.
struct VideoMeta: Equatable {
    var category: VideoCategory
    var title: String
    var artist: String = ""
    var year: String = ""
    var show: String = ""
    var season: Int = 1
    var episode: Int = 1
}

/// Результат разбора имени файла серии.
struct EpisodeGuess: Equatable {
    var show: String
    var season: Int
    var episode: Int
    var title: String?
}

// MARK: - Разбор имён серий

/// Понимает имена серий на английском, русском, украинском и белорусском:
/// S01E02, s1e2, S01.E02, 1x02, Season 1 Episode 2, Сезон 1 Серия 2, 1 сезон 2 серия,
/// «серия 2 - 1 сезон», «сезон один», «перший сезон», «S1 - 05», «Show - 05 [1080p]»,
/// а также сезон из имени папки («Season 2», «Сезон 2», «S02») и шоу из папки уровнем выше.
enum SeriesParser {
    static func parse(fileName: String, parentFolder: String?, grandparentFolder: String?) -> EpisodeGuess? {
        let name = normalize(fileName)

        var season: (value: Int, range: NSRange)?
        var episode: (value: Int, range: NSRange)?

        // 1. Склеенные формы: S01E02, S1 E2, S01.E02, S01-E02
        if let m = firstMatch(#"(?<![\p{L}\d])s(\d{1,2})[\s\-]*e(\d{1,3})(?!\d)"#, in: name),
           let s = Int(group(m, 1, name)), let e = Int(group(m, 2, name)) {
            season = (s, m.range); episode = (e, m.range)
        }
        // 2. 1x02
        else if let m = firstMatch(#"(?<![\p{L}\d])(\d{1,2})x(\d{1,3})(?![\p{L}\d])"#, in: name),
                let s = Int(group(m, 1, name)), let e = Int(group(m, 2, name)) {
            season = (s, m.range); episode = (e, m.range)
        } else {
            season = findSeason(in: name)
            episode = findEpisode(in: name, after: season?.range)
        }

        // Сезон из папки, если в имени его нет.
        var folderIsSeason = false
        if let parent = parentFolder.map(normalize), let s = seasonOnly(parent) {
            folderIsSeason = true
            if season == nil { season = (s, NSRange(location: NSNotFound, length: 0)) }
        }

        // Номер в начале имени («05 - Title», «05. Title»), если сезон известен из папки или имени.
        if episode == nil, season != nil || folderIsSeason,
           let m = firstMatch(#"^(\d{1,3})(?=[\s\-\.\)]|$)"#, in: name),
           let e = Int(group(m, 1, name)), e < 1900 {
            episode = (e, m.range)
        }

        guard let ep = episode else { return nil }
        let seasonValue = season?.value ?? 1

        // Название шоу: всё до первого найденного маркера; иначе — папка.
        let starts = [season?.range, ep.range].compactMap { $0 }.filter { $0.location != NSNotFound }
        let firstStart = starts.map(\.location).min() ?? 0
        let lastEnd = starts.map { $0.location + $0.length }.max() ?? 0
        let ns = name as NSString
        var show = clean(ns.substring(to: firstStart))
        if show.isEmpty {
            let folder = folderIsSeason ? grandparentFolder : parentFolder
            show = clean(normalize(folder ?? ""))
        }
        if show.isEmpty { show = "Unknown" }

        var tail = ns.substring(from: min(lastEnd, ns.length))
        if let junkStart = tail.range(of: junk, options: .regularExpression) {
            tail = String(tail[..<junkStart.lowerBound])
        }
        var title: String? = clean(tail)
        if title?.isEmpty == true { title = nil }

        return EpisodeGuess(show: show, season: seasonValue, episode: ep.value, title: title)
    }

    // MARK: Слова

    private static let seasonWord = #"season|seasons|сезон|сезона|сезоне|сезоні|сэзон|sezon"#
    private static let episodeWord = #"episode|episod|ep|серия|серии|серію|серія|серії|серыя|серыі|эпизод|епізод|эпізод|выпуск|випуск|seria|seriya|serija"#
    /// Число цифрами или словом (дальше проверяется в `number(from:)`).
    private static let num = #"(\d{1,3}|[\p{L}'’ʼ]{3,12})"#
    /// Окончания порядковых: 1-й, 2-я, 1st, 2nd…
    private static let ordSuffix = #"(?:-?(?:й|я|ый|ий|ой|ая|ше|th|st|nd|rd))?"#

    private static func findSeason(in s: String) -> (value: Int, range: NSRange)? {
        let patterns = [
            #"(?<![\p{L}])(?:"# + seasonWord + #")[\s:#№\-]*"# + num + #"(?![\p{L}\d])"#
                + #"(?!"# + ordSuffix + #"\s*(?:"# + episodeWord + #")(?![\p{L}])(?![\s:#№\.\-]*\d))"#,       // Season 1, сезон один
            #"(?<![\p{L}\d])"# + num + ordSuffix + #"\s*(?:"# + seasonWord + #")(?![\p{L}])"#,  // 1 сезон, first season
            #"(?<![\p{L}\d])s(\d{1,2})(?![\p{L}\d])"#,                                          // S1
            #"(?<![\p{L}])series\s*(\d{1,2})(?=\s*(?:episode|ep|e\d))"#,                        // Series 2 Episode 3 (UK)
        ]
        for p in patterns {
            for m in matches(p, in: s) {
                if let v = number(from: group(m, 1, s)) { return (v, m.range) }
            }
        }
        return nil
    }

    private static func findEpisode(in s: String, after seasonRange: NSRange?) -> (value: Int, range: NSRange)? {
        let explicit = [
            #"(?<![\p{L}])(?:"# + episodeWord + #")[\s:#№\.\-]*"# + num + #"(?![\p{L}\d])"#,       // Episode 5, серия 5, ep05
            #"(?<![\p{L}\d])"# + num + ordSuffix + #"\s*(?:"# + episodeWord + #")(?![\p{L}])"#,  // 5 серия, first seria
            #"(?<![\p{L}\d])e(\d{1,3})(?![\p{L}\d])"#,                                          // E05
        ]
        for p in explicit {
            for m in matches(p, in: s) {
                if let v = number(from: group(m, 1, s)), v < 1900 { return (v, m.range) }
            }
        }
        // «S1 - 05», «Season 1 - 05»: номер сразу после маркера сезона.
        if let r = seasonRange, let swiftRange = Range(r, in: s) {
            let tail = String(s[swiftRange.upperBound...])
            if let m = firstMatch(#"^\s*[\-–—:]?\s*(\d{1,3})(?![\p{L}\d])"#, in: tail),
               let e = Int(group(m, 1, tail)), e < 1900 {
                let loc = r.location + r.length + m.range.location
                return (e, NSRange(location: loc, length: m.range.length))
            }
        }
        // Аниме-стиль «Show - 05 [1080p]» / «Show - 05 - Title» / «Show - 05v2».
        for m in matches(#"\s[\-–]\s(\d{1,3})(?=\s*(?:\[|\(|$|v\d|[\-–]\s))"#, in: s) {
            if let v = Int(group(m, 1, s)), v < 1900 { return (v, m.range) }
        }
        return nil
    }

    /// Папка «Season 2» / «Сезон 2» / «S02» / «2 сезон» → 2.
    private static func seasonOnly(_ folder: String) -> Int? {
        guard let found = findSeason(in: folder) else { return nil }
        // Папка должна быть «про сезон», а не названием шоу с цифрой.
        let rest = clean((folder as NSString).replacingCharacters(in: found.range, with: " "))
        return rest.count <= 3 ? found.value : nil
    }

    // MARK: Числа словами

    private static let words: [(String, Int)] = [
        // английский
        ("one", 1), ("first", 1), ("two", 2), ("second", 2), ("three", 3), ("third", 3), ("four", 4), ("fourth", 4),
        ("five", 5), ("fifth", 5), ("six", 6), ("sixth", 6), ("seven", 7), ("seventh", 7), ("eight", 8), ("eighth", 8),
        ("nine", 9), ("ninth", 9), ("ten", 10), ("tenth", 10), ("eleven", 11), ("twelve", 12),
    ]
    /// Основы слов RU/UK/BE: «перв-», «перш-», «друг-», «трет-», «трэц-»…
    private static let stems: [(String, Int)] = [
        ("один", 1), ("одна", 1), ("одн", 1), ("перв", 1), ("перш", 1), ("адзін", 1), ("адна", 1),
        ("два", 2), ("две", 2), ("дві", 2), ("дзве", 2), ("втор", 2), ("друг", 2),
        ("три", 3), ("тры", 3), ("трет", 3), ("трэц", 3),
        ("четыр", 4), ("чотир", 4), ("чатыр", 4), ("четв", 4), ("чацв", 4),
        ("пять", 5), ("пят", 5), ("п'ят", 5), ("п’ят", 5), ("пʼят", 5), ("пяц", 5),
        ("шесть", 6), ("шест", 6), ("шість", 6), ("шост", 6), ("шэсц", 6),
        ("семь", 7), ("седьм", 7), ("сім", 7), ("сьом", 7), ("сем", 7), ("сём", 7),
        ("восемь", 8), ("восьм", 8), ("вісім", 8), ("восем", 8),
        ("девять", 9), ("девят", 9), ("дев'ят", 9), ("дев’ят", 9), ("девʼят", 9), ("дзевяц", 9), ("дзявят", 9),
        ("десять", 10), ("десят", 10), ("дзесяц", 10), ("дзясят", 10),
    ]

    static func number(from token: String) -> Int? {
        if let n = Int(token) { return n }
        let w = token.lowercased()
        if let hit = words.first(where: { $0.0 == w }) { return hit.1 }
        // Самая длинная подходящая основа: «седьмой» → «седьм», а не «сем».
        return stems.filter { w.hasPrefix($0.0) }.max { $0.0.count < $1.0.count }?.1
    }

    // MARK: Очистка

    /// Точки и подчёркивания → пробелы, лишние пробелы убираются.
    static func normalize(_ s: String) -> String {
        // Имена файлов в macOS хранятся в NFD («й» = «и» + краткая) — приводим к NFC для регулярок.
        var t = s.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "_", with: " ")
        // Точки между словами (Show.Name.S01E02) → пробел; «Mr. Robot» тоже переживёт.
        t = t.replacingOccurrences(of: #"\.(?=\S)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static let junk = #"(?i)\b(2160p|1080p|1080i|720p|576p|480p|360p|4k|uhd|hdr|web[\s\-]?dl|web[\s\-]?rip|webrip|hdtv|hdrip|bdrip|brrip|dvdrip|bluray|blu[\s\-]?ray|x264|x265|h264|h 264|h265|hevc|avc|xvid|divx|aac|ac3|dts|eac3|ddp?5 1|5 1|2 0|10bit|8bit|proper|repack|rus|ukr|eng|sub|subs|lostfilm|newstudio|novafilm|baibako|kubik|jaskier|amedia|coldfilm)\b"#

    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\{[^}]*\}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\((?!(?:19|20)\d\d\))[^)]*\)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: junk, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.,:;#|()[]{}"))
    }

    // MARK: Регулярки

    private static func matches(_ pattern: String, in s: String) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func firstMatch(_ pattern: String, in s: String) -> NSTextCheckingResult? {
        matches(pattern, in: s).first
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }
}

// MARK: - Автоопределение категории

enum VideoClassifier {
    /// «Unknown Artist» и подобные заглушки других программ — это не исполнитель.
    static func isPlaceholderArtist(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || ["unknown artist", "unknown", "artist", "неизвестный исполнитель", "неизвестный артист",
                             "невідомий виконавець", "невядомы выканаўца", "<unknown>"].contains(t)
    }

    /// Хвосты от прошлых конвертаций: «_ipod5g_480», «_ipod_nano7_ipod_nano7», «[iPod 5.5G]».
    static func stripConverterSuffix(_ s: String) -> String {
        var t = s
        let pattern = #"(\s*\[iPod[^\]]*\]|_ipod[a-z0-9_]*|_\d{3,4}p?)+$"#
        while let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]), !r.isEmpty {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func guess(url: URL, info: MediaInfo) -> VideoMeta {
        let base = stripConverterSuffix(url.deletingPathExtension().lastPathComponent)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let grand = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let tags = info.tags
        let artistTag = info.artist.flatMap { isPlaceholderArtist($0) ? nil : $0 }
        let titleTag = info.title.map(stripConverterSuffix).flatMap { $0.isEmpty ? nil : $0 }

        // 1. Теги сериала в самом файле.
        if let show = tags["show"], let ep = Int(tags["episode_sort"] ?? "") {
            return VideoMeta(category: .serial, title: tags["title"] ?? "", show: show,
                             season: Int(tags["season_number"] ?? "") ?? 1, episode: ep)
        }
        // 2. Имя файла / папки.
        if let g = SeriesParser.parse(fileName: base, parentFolder: parent, grandparentFolder: grand) {
            return VideoMeta(category: .serial, title: g.title ?? "", show: g.show, season: g.season, episode: g.episode)
        }
        // 3. Клип: есть артист в тегах или «Артист - Песня» и короче 15 минут.
        let cleaned = SeriesParser.clean(SeriesParser.normalize(base))
        if let artist = artistTag {
            return VideoMeta(category: .musicVideo, title: titleTag ?? cleaned, artist: artist)
        }
        // «Артист - Песня» — из тега названия (у старых конвертаций он полный), иначе из имени файла.
        let dashSource = titleTag.map { SeriesParser.clean(SeriesParser.normalize($0)) }
            .flatMap { $0.range(of: #"\s[\-–—]\s"#, options: .regularExpression) != nil ? $0 : nil } ?? cleaned
        if info.duration > 0, info.duration < 15 * 60,
           let dash = dashSource.range(of: #"\s[\-–—]\s"#, options: .regularExpression) {
            return VideoMeta(category: .musicVideo,
                             title: String(dashSource[dash.upperBound...]).trimmingCharacters(in: .whitespaces),
                             artist: String(dashSource[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
        // 4. Фильм: название до года, год отдельно.
        var title = titleTag ?? cleaned
        var year = ""
        if let r = base.range(of: #"(?<!\d)(19[3-9]\d|20[0-4]\d)(?!\d)"#, options: .regularExpression) {
            year = String(base[r])
            if titleTag == nil {
                let before = SeriesParser.clean(SeriesParser.normalize(String(base[..<r.lowerBound])))
                if !before.isEmpty { title = before }
            }
        }
        return VideoMeta(category: .film, title: title, year: year)
    }
}
