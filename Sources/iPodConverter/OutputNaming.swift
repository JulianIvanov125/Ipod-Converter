import Foundation

/// Имена и папки готовых файлов — одинаковые в Mac- и Linux-версии.
/// Music Videos/«Артист - Песня», Films/«Название (Год)», Serials/Шоу/Season N/«Шоу S01E03 Название».
enum OutputNaming {
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

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    /// Свободное имя: «Имя.m4v», иначе «Имя 2.m4v», «Имя 3.m4v»…
    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

/// Какие файлы принимаем — общий список для Mac и Linux.
enum MediaKinds {
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "divx", "xvid", "wmv", "asf", "flv", "f4v",
        "mpg", "mpeg", "mpe", "m1v", "m2v", "ts", "mts", "m2ts", "tod", "vob", "3gp", "3g2", "ogv",
        "rm", "rmvb", "dv", "mxf", "y4m", "nut", "amv", "h264", "hevc",
    ]
}
