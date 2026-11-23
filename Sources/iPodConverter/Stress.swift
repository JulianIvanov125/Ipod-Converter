import AppKit
import SwiftUI

/// Нагрузочный тест в настоящем окне: `iPodConverter --stress <папка-треков> <папка-видео>`.
/// Добавляет тысячи файлов, делает типичные действия и печатает по каждому этапу:
/// длительность, подвисания главного потока, память, открытые файлы.
@MainActor
enum Stress {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--stress"), args.count > i + 2 else { return false }
        setvbuf(stdout, nil, _IOLBF, 0)
        let tracks = URL(fileURLWithPath: args[i + 1]), videos = URL(fileURLWithPath: args[i + 2])
        Task { await run(tracks: tracks, videos: videos) }
        return true
    }

    /// Задержка главного потока: раз в 20 мс из фона «стучимся» на главный и меряем, когда ответил.
    final class StallMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var maxGap = 0.0, over100 = 0, over500 = 0
        private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        init() {
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                let t0 = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    let gap = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    guard let self else { return }
                    self.lock.lock()
                    self.maxGap = max(self.maxGap, gap)
                    if gap > 100 { self.over100 += 1 }
                    if gap > 500 { self.over500 += 1 }
                    self.lock.unlock()
                }
            }
            timer.resume()
        }
        func take() -> (max: Double, over100: Int, over500: Int) {
            lock.lock(); defer { lock.unlock() }
            let r = (maxGap, over100, over500)
            maxGap = 0; over100 = 0; over500 = 0
            return r
        }
    }

    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func openFDs() -> Int { (0..<8192).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static func run(tracks: URL, videos: URL) async {
        let monitor = StallMonitor()
        let store = Store()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: ContentView(store: store))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        IPodDetector.shared.refreshNow()
        var w = 0.0
        while !store.hasIPod && w < 6 { await sleep(0.3); w += 0.3 }
        var addedTab: IPodModel?
        if !store.hasIPod { store.toggleFavorite(.classic55G); addedTab = .classic55G }

        var started = Date()
        func phase(_ name: String) {
            let s = monitor.take()
            print(String(format: "%-34@ %7.1f с | подвисание макс %6.0f мс, >100 мс: %4d, >500 мс: %3d | память %6.0f МБ | файлов %4d",
                         name as NSString, Date().timeIntervalSince(started), s.max, s.over100, s.over500, memoryMB(), openFDs()))
            started = Date()
        }
        phase("старт")

        // 1. Треки
        store.section = .music
        store.add([tracks])
        print("  добавлено треков: \(store.tracks.count)")
        while store.tracks.contains(where: { $0.state == .loading }) && Date().timeIntervalSince(started) < 900 { await sleep(0.5) }
        let failedT = store.tracks.filter { if case .failed = $0.state { return true } else { return false } }
        phase("загрузка \(store.tracks.count) треков")
        if !failedT.isEmpty { print("  ОШИБКИ треков: \(failedT.count), пример: \(failedT.first.map { "\($0.state)" } ?? "")") }
        await sleep(2); phase("простой после треков (2 с)")

        // 2. Видео
        store.add([videos])
        store.section = .videos
        print("  добавлено видео: \(store.items.count)")
        while store.items.contains(where: { $0.state == .loading }) && Date().timeIntervalSince(started) < 1800 { await sleep(0.5) }
        let failedV = store.items.filter { if case .failed = $0.state { return true } else { return false } }
        phase("загрузка \(store.items.count) видео")
        if !failedV.isEmpty { print("  ОШИБКИ видео: \(failedV.count), пример: \(failedV.first.map { "\($0.state)" } ?? "")") }
        await sleep(2); phase("простой после видео (2 с)")

        // 3. Действия в интерфейсе
        store.section = .music; await sleep(1.5); phase("вкладка «Музыка»")
        store.musicScope = .duplicates; await sleep(2); phase("«Дубликаты» (\(store.duplicateExtras.count) копий)")
        store.setAllDuplicatesSelected(true); await sleep(1); phase("выбрать все дубликаты")
        store.setAllDuplicatesSelected(false)
        store.musicScope = .all; await sleep(1); phase("назад «Все»")
        for q in ["n", "na", "nad", "nada"] { store.trackSearch = q; await sleep(0.15) }
        await sleep(1); phase("поиск по буквам")
        store.trackSearch = ""; await sleep(1); phase("сброс поиска")
        store.toggleSort(.title); await sleep(1); store.toggleSort(.title); await sleep(1); store.toggleSort(.title); await sleep(1)
        phase("сортировка ↑ ↓ сброс")
        store.setAllChecked(true); await sleep(1); phase("отметить все треки")
        store.setAllChecked(false)
        store.section = .videos; await sleep(1.5); phase("вкладка «Видео»")
        store.setAllVideosChecked(true); await sleep(1); phase("отметить все видео")
        store.setAllVideosChecked(false)
        if let t = store.tracks.first { store.playTrack(t, converted: false); PlayerController.shared.player.volume = 0.001 }
        store.section = .music; await sleep(3); phase("воспроизведение 3 с")
        PlayerController.shared.close()
        store.clearTracks(); store.clearVideos(); await sleep(2); phase("очистить списки")

        if let m = addedTab { store.toggleFavorite(m) }
        exit(0)
    }
}
