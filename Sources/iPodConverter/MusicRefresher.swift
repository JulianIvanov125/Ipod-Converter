import AppKit
import Foundation

/// Собирает файлы, в которые только что записали теги, и раз в несколько секунд пачкой просит
/// «Музыку» перечитать их (иначе она показывает старые теги и без обложки).
/// Только если «Музыка» запущена: открывать её ради этого не будем.
@MainActor
final class MusicRefresher {
    static let shared = MusicRefresher()
    private var pending: [(file: URL, cover: URL?)] = []
    /// «Музыка» переименовала файл после обновления (старый путь → новый).
    var onMoved: ((URL, URL) -> Void)?
    private var scheduled = false

    func add(_ file: URL, cover: URL?) {
        pending.append((file, cover))
        guard !scheduled else { return }
        scheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await flush()
        }
    }

    static var musicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private func flush() async {
        while !pending.isEmpty {
            let part = Array(pending.prefix(50))
            pending.removeFirst(part.count)
            guard Self.musicRunning else { continue }
            do {
                let answers = try await MusicLibrary.refresh(part)
                for (k, item) in part.enumerated() {
                    let a = k < answers.count ? answers[k] : ""
                    if a.hasPrefix("ERR:") { AppLog.error("Music refresh failed: \(item.file.path) — \(a.dropFirst(4))"); continue }
                    let parts = a.split(separator: "|", maxSplits: 1).map(String.init)
                    let count = Int(parts.first ?? "") ?? 0
                    guard count > 0 else { AppLog.info("Not in Music library: \(item.file.path)"); continue }
                    AppLog.info("Music updated from file: \(item.file.path)")
                    if parts.count > 1, !parts[1].isEmpty {
                        let moved = URL(fileURLWithPath: parts[1])
                        if moved.standardizedFileURL.path != item.file.standardizedFileURL.path {
                            AppLog.info("Music renamed the file: \(item.file.path) → \(moved.path)")
                            onMoved?(item.file, moved)
                        }
                    }
                }
            } catch {
                AppLog.error("Music refresh failed: \(error)")
            }
        }
        scheduled = false
    }
}
