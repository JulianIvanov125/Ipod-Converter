import Foundation

/// Журнал приложения: ~/Library/Logs/iPod Converter/iPodConverter.log.
/// Что конвертировалось, ошибки ffmpeg и «Музыки», подключения iPod. Домашняя папка заменяется на «~»,
/// чтобы в отчёт не попадало имя пользователя. Больше 2 МБ — старый журнал уходит в .1 (хранится один).
enum AppLog {
    static let folder: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/iPod Converter", isDirectory: true)
    static let file = folder.appendingPathComponent("iPodConverter.log")
    private static let old = folder.appendingPathComponent("iPodConverter.1.log")
    private static let queue = DispatchQueue(label: "local.ipodconverter.log", qos: .utility)
    private static let maxSize = 2_000_000

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    /// Убирает из текста домашнюю папку (имя пользователя).
    static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        t = t.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "/Users/…", options: .regularExpression)
        return t
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(level)] \(sanitize(message))\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxSize {
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    /// Последние строки журнала (для отчёта).
    static func tail(_ lines: Int) -> String {
        queue.sync {}   // дождаться записи того, что уже в очереди
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    /// Хвост ошибки ffmpeg: последние строки stderr (без прогресса).
    static func ffmpegTail(_ stderr: String, lines: Int = 8) -> String {
        stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("frame=") && !$0.hasPrefix("size=") }
            .suffix(lines).joined(separator: " | ")
    }
}
