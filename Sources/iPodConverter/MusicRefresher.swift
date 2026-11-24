#if os(macOS)
import AppKit
import Foundation

/// Собирает файлы, в которые только что записали теги, и пачкой просит «Музыку» перечитать их
/// (сама она файлы не перечитывает и показывает старые теги и без обложки).
/// Если «Музыка» закрыта, список сохраняется и применяется, когда её откроют
/// (или при следующем запуске приложения, если «Музыка» уже открыта). Открывать «Музыку» ради этого не будем.
@MainActor
final class MusicRefresher {
    static let shared = MusicRefresher()

    struct Item: Codable, Equatable {
        var file: String
        var cover: String?
    }

    private var pending: [Item] = []
    private var scheduled = false
    private var observer: NSObjectProtocol?
    private static let key = "musicRefreshPending"
    /// Обложки для отложенных обновлений: временные файлы могут удалиться до запуска «Музыки».
    private static let coverFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iPod Converter/Pending covers", isDirectory: true)
    /// «Музыка» переименовала файл после обновления (старый путь → новый).
    var onMoved: ((URL, URL) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            pending = saved
        }
    }

    /// Запуск приложения: следим за запуском «Музыки»; если она уже открыта — применяем отложенное.
    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.Music" else { return }
            // Дать «Музыке» загрузить медиатеку, прежде чем спрашивать её. (Task — см. IPodDetector.refresh.)
            Task { @MainActor in MusicRefresher.shared.schedule(after: 8) }
        }
        if !pending.isEmpty {
            AppLog.info("Music updates waiting from last time: \(pending.count)")
            schedule(after: 3)
        }
    }

    var waiting: Int { pending.count }

    func add(_ file: URL, cover: URL?) {
        let item = Item(file: file.path, cover: cover?.path)
        pending.removeAll { $0.file == item.file }
        pending.append(item)
        save()
        schedule(after: 3)
    }

    static var musicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private func schedule(after seconds: Double) {
        guard !scheduled else { return }
        scheduled = true
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await flush()
        }
    }

    /// Список в настройки; обложки из временной папки — в свою, чтобы дожили до запуска «Музыки».
    private func save() {
        let fm = FileManager.default
        for i in pending.indices {
            guard let c = pending[i].cover, !c.hasPrefix(Self.coverFolder.path) else { continue }
            try? fm.createDirectory(at: Self.coverFolder, withIntermediateDirectories: true)
            let dst = Self.coverFolder.appendingPathComponent(UUID().uuidString + "." + URL(fileURLWithPath: c).pathExtension)
            pending[i].cover = (try? fm.copyItem(at: URL(fileURLWithPath: c), to: dst)) != nil ? dst.path : nil
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: Self.key)
        // Обложки, которые больше никому не нужны.
        let used = Set(pending.compactMap(\.cover))
        for f in (try? fm.contentsOfDirectory(at: Self.coverFolder, includingPropertiesForKeys: nil)) ?? [] where !used.contains(f.path) {
            try? fm.removeItem(at: f)
        }
    }

    private func flush() async {
        defer { scheduled = false }
        guard Self.musicRunning else {
            if !pending.isEmpty { AppLog.info("Music is closed — \(pending.count) updates will be applied when it opens") }
            return
        }
        while !pending.isEmpty {
            let part = Array(pending.prefix(50))
            // Файл могли удалить, пока ждали.
            let alive = part.filter { FileManager.default.fileExists(atPath: $0.file) }
            do {
                let answers = try await MusicLibrary.refresh(alive.map { (URL(fileURLWithPath: $0.file), $0.cover.map { URL(fileURLWithPath: $0) }) })
                for (k, item) in alive.enumerated() {
                    let a = k < answers.count ? answers[k] : ""
                    if a.hasPrefix("ERR:") { AppLog.error("Music refresh failed: \(item.file) — \(a.dropFirst(4))"); continue }
                    let parts = a.split(separator: "|", maxSplits: 1).map(String.init)
                    let count = Int(parts.first ?? "") ?? 0
                    guard count > 0 else { AppLog.info("Not in Music library: \(item.file)"); continue }
                    AppLog.info("Music updated from file: \(item.file)")
                    if parts.count > 1, !parts[1].isEmpty {
                        let old = URL(fileURLWithPath: item.file), moved = URL(fileURLWithPath: parts[1])
                        if moved.standardizedFileURL.path != old.standardizedFileURL.path {
                            AppLog.info("Music renamed the file: \(item.file) → \(moved.path)")
                            onMoved?(old, moved)
                        }
                    }
                }
            } catch {
                // «Музыка» не ответила (закрыли, нет доступа) — попробуем при следующем запуске.
                AppLog.error("Music refresh failed: \(error)")
                return
            }
            pending.removeAll { p in part.contains(p) }
            save()
        }
    }
}
#endif
