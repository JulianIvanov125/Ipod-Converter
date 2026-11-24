#if os(macOS)
import Foundation

/// «Обложки → «Музыка»»: каждому треку ставим в «Музыке» его же обложку из файла.
/// «Музыка» иногда показывает альбом серым, хотя обложка у трека есть; после повторной установки
/// она перестраивает запись обложки и альбом показывается. Сама «Музыка» при этом перезаписывает файл
/// (та же картинка, звук не меняется).
enum CoverRepair {
    struct Result { var done = 0, notInLibrary = 0, noCover = 0, failed: [String] = [] }

    /// Обложку из файла — во временный файл (без перекодирования).
    static func extractCover(_ url: URL, index: Int) async -> URL? {
        guard let ffmpeg = FFmpeg.tool("ffmpeg") else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iPodConverter/repair", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(UUID().uuidString + ".img")
        guard let r = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", url.path,
                                                             "-map", "0:\(index)", "-c", "copy", "-frames:v", "1", "-f", "image2", out.path], timeout: 60),
              r.status == 0, FileManager.default.fileExists(atPath: out.path) else { return nil }
        return out
    }

    /// progress(готово, всего) — для строки состояния.
    @MainActor
    static func run(_ tracks: [TrackItem], progress: @escaping @MainActor (Int, Int) -> Void) async -> Result {
        var res = Result()
        let list = tracks.filter { $0.info != nil }
        var processed = 0
        for start in stride(from: 0, to: list.count, by: 50) {
            let part = Array(list[start..<min(start + 50, list.count)])
            var items: [(file: URL, cover: URL)] = []
            for t in part {
                guard let idx = t.info?.coverStreamIndex, let c = await extractCover(t.url, index: idx) else { res.noCover += 1; continue }
                items.append((t.url, c))
            }
            do {
                let answers = try await MusicLibrary.reapplyArtwork(items)
                for (k, it) in items.enumerated() {
                    let a = k < answers.count ? answers[k] : ""
                    if a == "1" { res.done += 1 }
                    else if a.hasPrefix("ERR:") { res.failed.append("\(it.file.lastPathComponent): \(a.dropFirst(4))") }
                    else { res.notInLibrary += 1 }
                }
            } catch {
                res.failed.append(error.localizedDescription)
                for it in items { try? FileManager.default.removeItem(at: it.cover) }
                break
            }
            for it in items { try? FileManager.default.removeItem(at: it.cover) }
            processed += part.count
            progress(processed, list.count)
        }
        AppLog.info("Covers re-applied in Music: \(res.done), not in library: \(res.notInLibrary), no cover in file: \(res.noCover), failed: \(res.failed.count)")
        for f in res.failed { AppLog.error("Cover repair failed: \(f)") }
        return res
    }
}
#endif
