import AVFoundation
import AppKit
import Foundation

/// Скрытая самопроверка аудио-конвейера без интерфейса:
/// iPodConverter --selftest-audio <модель> <папка-вывода> файлы…
/// Печатает разбор, выбранный план и результат, затем завершает приложение.
@MainActor
enum SelfTest {
    private static var restoreSettings: () -> Void = {}
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--selftest-series") {
            SeriesSelfTest.run()
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest-meta"), args.count > i + 2 {
            let out = URL(fileURLWithPath: args[i + 1])
            let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                MetadataFetcher.shared.enabled = true
                var tracks: [TrackItem] = []
                for f in files {
                    let t = TrackItem(url: f)
                    await t.load()
                    if let info = t.info {
                        let g = TagGuess.from(url: f, info: info)
                        print("\(f.lastPathComponent): догадка «\(g.artist ?? "-")» / «\(g.album ?? "-")» / №\(g.trackNo.map(String.init) ?? "-") «\(g.title)»")
                    }
                    MetadataFetcher.shared.enqueue(t)
                    tracks.append(t)
                }
                await MetadataFetcher.shared.waitUntilIdle()
                for t in tracks {
                    print("\(t.url.lastPathComponent): \(t.metaStatus)")
                    for (k, v) in (t.fetched?.fields ?? [:]).sorted(by: { $0.key < $1.key }) { print("   + \(k) = \(v)") }
                    if let c = t.fetched?.coverFile { print("   + обложка \(c.lastPathComponent)") }
                    guard let plan = t.plan(for: .classic55G) else { continue }
                    let p: AudioPlan = plan == .compatible && !t.needsRetag ? .aac(rate: 44100, kbps: 256) : plan
                    let r: URL? = await withCheckedContinuation { cont in t.convert(plan: p, into: out) { cont.resume(returning: $0) } }
                    print("   ⇒ \(r?.lastPathComponent ?? "FAILED \(t.state)")")
                }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-lyrics"), args.count > i + 1 {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                for f in files {
                    let t = TrackItem(url: f)
                    await t.load()
                    guard let info = t.info else { print("\(f.lastPathComponent): не читается"); continue }
                    let q = LyricsQuery(file: f, title: info.title ?? f.deletingPathExtension().lastPathComponent,
                                        artist: info.artist, album: info.album, duration: info.duration)
                    let started = Date()
                    let l = await LyricsStore.find(q, online: true)
                    let dt = String(format: "%.1f c", Date().timeIntervalSince(started))
                    guard let l else { print("\(f.lastPathComponent): не найден (\(dt))"); continue }
                    print("\(f.lastPathComponent): источник \(l.source), \(l.isSynced ? "в такт, строк \(l.lines.count)" : "без синхронизации") (\(dt))")
                    for line in l.lines.prefix(3) { print(String(format: "   [%05.2f] ", line.time) + line.text) }
                    if l.isSynced, let mid = l.lines.dropFirst(2).first {
                        print("   на \(String(format: "%.2f", mid.time + 0.5)) c звучит строка #\(l.index(at: mid.time + 0.5) ?? -1): \(l.lines[l.index(at: mid.time + 0.5) ?? 0].text)")
                    }
                }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-viz"), args.count > i + 1 {
            let f = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                let pc = PlayerController.shared
                pc.player.isMuted = true
                pc.play([PlayEntry(id: "viz", url: f, title: "", subtitle: "", artwork: nil, isVideo: false)], startAt: 0)
                try? await Task.sleep(nanoseconds: 300_000_000)
                // 4 секунды «кадров» по 60 Гц: какие скачки поймал детектор капель.
                let sm = LevelSmoother()
                let t0 = Date().timeIntervalSinceReferenceDate
                var log: [String] = []
                for _ in 0..<240 {
                    let t = Date().timeIntervalSinceReferenceDate
                    for o in sm.update(time: t) {
                        log.append(String(format: "%.2fс ", t - t0) + (o.band < 0 ? "БАС" : LevelSmoother.label(LevelSmoother.hz(o.band))))
                    }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                print("капли (\(log.count)): " + log.joined(separator: " | "))
                let b = AudioAnalyzer.shared.snapshot()
                let top = b.enumerated().sorted { $0.element > $1.element }.prefix(3)
                func hz(_ i: Int) -> Int { Int(40 * pow(16000.0 / 40, (Double(i) + 0.5) / Double(AudioAnalyzer.bandCount))) }
                print("полос: \(b.count), макс \(String(format: "%.2f", b.max() ?? 0)), среднее \(String(format: "%.2f", b.reduce(0, +) / Float(b.count)))")
                print("самые громкие: " + top.map { "≈\(hz($0.offset)) Гц (\(String(format: "%.2f", $0.element)))" }.joined(separator: ", "))
                let red = NSImage(contentsOfFile: args.count > i + 2 ? args[i + 2] : "") 
                if let red { let p = CoverPalette.colors(from: red); print("акценты: \(p.accents.map { "\($0)" })"); print("заливка: \(p.blend.map { "\($0)" })") }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-preview"), args.count > i + 1 {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                let pc = PlayerController.shared
                for f in files {
                    let isVideo = !AudioRules.audioExtensions.contains(f.pathExtension.lowercased())
                    let e = PlayEntry(id: f.path, url: f, title: "", subtitle: "", artwork: nil, isVideo: isVideo)
                    let started = Date()
                    let url = await pc.playableURL(for: e, token: pc.loadToken)
                    var playable = false
                    if let url { playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false }
                    print("\(f.lastPathComponent): " + (url == nil ? "FAILED" : (url == f ? "напрямую" : "копия .\(url!.pathExtension)"))
                          + String(format: " за %.1f c", Date().timeIntervalSince(started)) + ", AVPlayer: \(playable ? "играет" : "НЕТ")")
                }
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-video"), args.count > i + 2 {
            let root = URL(fileURLWithPath: args[i + 1])
            let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                for f in files {
                    let v = VideoItem(url: f)
                    await v.load()
                    guard let m = v.meta else { print("\(f.lastPathComponent): \(v.state)"); continue }
                    print("\(f.lastPathComponent) → \(m.category.rawValue): \(v.displayTitle)")
                    v.convert(model: .classic55G, maxQuality: false, videoRoot: root, addToMusic: false)
                    while v.isConverting { try? await Task.sleep(nanoseconds: 200_000_000) }
                    if case .done(let out) = v.state {
                        print("   ⇒ " + out.path.replacingOccurrences(of: root.path + "/", with: ""))
                    } else { print("   ⇒ \(v.state)") }
                }
                exit(0)
            }
            return true
        }
        guard let i = args.firstIndex(of: "--selftest-audio"), args.count > i + 3 else { return false }
        let model = IPodModel(rawValue: args[i + 1]) ?? .classic55G
        // необязательно: --format aac:128 / mp3:320 / alac / auto
        let savedFormat = UserDefaults.standard.object(forKey: "audioFormat")
        let savedKbps = UserDefaults.standard.object(forKey: "audioKbps")
        defer {
            // Возвращаем настройки пользователя после изменения ниже (запись — в didSet).
        }
        restoreSettings = {
            for (k, v) in [("audioFormat", savedFormat), ("audioKbps", savedKbps)] {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
        if let f = args.firstIndex(of: "--format"), args.count > f + 1 {
            let parts = args[f + 1].split(separator: ":")
            AudioOutputSettings.shared.choice = AudioFormatChoice(rawValue: String(parts[0])) ?? .auto
            if parts.count > 1, let k = Int(parts[1]) { AudioOutputSettings.shared.kbps = k }
        }
        let out = URL(fileURLWithPath: args[i + 2])
        let files = args[(i + 3)...].filter { !$0.hasPrefix("--") && !$0.contains(":") && !["auto", "alac"].contains($0) }
            .map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            for f in files {
                let t = TrackItem(url: f)
                await t.load()
                guard let info = t.info, let plan = t.plan(for: model) else {
                    print("\(f.lastPathComponent): \(t.state)")
                    continue
                }
                print("\(f.lastPathComponent): \(info.typeLabel) [\(info.detailLabel)] ch=\(info.channels) "
                      + "\(info.bitrate.map { "\($0 / 1000)k" } ?? "-") «\(info.artist ?? "-") — \(info.title ?? "-")» "
                      + "fmt=\(AudioOutputSettings.shared.choice.rawValue)/\(AudioOutputSettings.shared.kbps) cover=\(info.coverStreamIndex.map(String.init) ?? "-") rating=\(info.rating.map { "\($0 / 20)★" } ?? "-") → \(plan)")
                if plan == .compatible { continue }
                let result: URL? = await withCheckedContinuation { cont in
                    t.convert(plan: plan, into: out) { cont.resume(returning: $0) }
                }
                print("   ⇒ \(result?.lastPathComponent ?? "FAILED: \(t.state)")")
            }
            restoreSettings()
            exit(0)
        }
        return true
    }
}
