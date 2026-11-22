import MediaPlayer
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
        if let i = args.firstIndex(of: "--selftest-scope"), args.count > i + 1 {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                let st = Store()
                for f in files { let t = TrackItem(url: f); await t.load(); st.tracks.append(t) }
                @MainActor func line(_ title: String) {
                    print("\(title): в списке \(st.visibleTracks.count), к конвертации \(st.convertibleTracks.count)\(st.hasCheckedTracks ? " (выбранные)" : "")")
                }
                st.musicScope = .all; line("Все, ничего не отмечено")
                st.setChecked(st.tracks[0], true); st.setChecked(st.tracks[2], true); line("Все, отмечено 2")
                st.musicScope = .selected; line("Выбранные, отмечено 2")
                st.setChecked(st.tracks[0], false); line("Выбранные, сняли одну")
                st.musicScope = .all; line("Снова Все")
                st.setAllChecked(false); st.musicScope = .selected; line("Выбранные, ничего не отмечено")
                // Свой формат одного трека
                st.tracks[1].formatOverride = TrackFormatOverride(choice: .mp3, kbps: 320, sampleRate: 44100)
                for t in st.tracks.prefix(3) { print("план \(t.url.lastPathComponent): \(t.plan(for: .classic55G).map { "\($0)" } ?? "-")\(t.formatOverride != nil ? " (свой)" : "")") }
                // Свои настройки одного видео
                let v = VideoItem(url: URL(fileURLWithPath: "/x.mkv"))
                v.outputOverride = VideoOverride(container: .mp4, codec: .hevc, resolution: .hd720, videoKbps: 2500)
                let sv = st.settings(for: v), sOther = st.settings(for: VideoItem(url: URL(fileURLWithPath: "/y.mkv")))
                print("видео со своими: \(sv.container.rawValue) \(sv.codecLabel) \(sv.w)×\(sv.h) \(sv.videoKbps)k; остальные: \(sOther.container.rawValue) \(sOther.codecLabel) \(sOther.w)×\(sOther.h)")
                exit(0)
            }
            return true
        }
        if args.contains("--selftest-ipods") {
            print("доступ к дискам iPod запрещён: \(IPodDetector.volumeAccessDenied()), нераспознанный iPod: \(IPodDetector.hasUnrecognizedIPod())")
            for d in IPodDetector.detect(overrides: IPodDetector.savedOverrides()) {
                print("подключён: «\(d.name ?? "-")» → конвертация под \(d.model.title)\(d.ambiguous ? " (5G/5.5G не различить автоматически)" : ""), GUID …\(d.serial.suffix(4))")
            }
            let cases: [(Int, [String], String)] = [
                (0x1209, ["A002"], "iPod 5G 30GB"), (0x1209, ["A446"], "iPod 5.5G 30GB"), (0x1209, [], "5G/5.5G без диска"),
                (0x1261, ["B029"], "classic 80GB"), (0x1261, ["B562"], "classic 120GB"), (0x1261, ["C297"], "classic 160GB 2009"),
                (0x1262, [], "nano 3"), (0x1265, [], "nano 5"), (0x1266, [], "nano 6 (без видео)"), (0x1267, [], "nano 7"),
                (0x129E, [], "touch 4"), (0x8007, [], "хаб Apple"),
            ]
            for (pid, nums, name) in cases {
                print(String(format: "  0x%04X %@ → ", pid, name) + (IPodDetector.model(forUSB: pid, modelNumbers: nums)?.title ?? "не iPod с видео"))
            }
            exit(0)
        }
        if args.contains("--selftest-tools") {
            print("ffmpeg:  \(FFmpeg.tool("ffmpeg") ?? "нет")")
            print("ffprobe: \(FFmpeg.tool("ffprobe") ?? "нет")")
            exit(0)
        }
        // --out mp4:hevc:hd720 — свои настройки выхода для --selftest-video (без сохранения в настройки)
        if let o = args.firstIndex(of: "--out"), args.count > o + 1 {
            let p = args[o + 1].split(separator: ":").map(String.init)
            let out = VideoOutputSettings.shared
            let saved = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("out.") }
            out.enabled = true
            if p.count > 0 { out.container = VideoContainer(rawValue: p[0]) ?? .m4v }
            if p.count > 1 { out.codec = VideoCodec(rawValue: p[1]) ?? .h264 }
            if p.count > 2 { out.resolution = OutResolution(rawValue: p[2]) ?? .preset }
            if p.count > 3 { out.videoKbps = Int(p[3]) ?? 0 }
            restoreSettings = {
                for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("out.") { UserDefaults.standard.removeObject(forKey: k) }
                for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) }
            }
        }
        if args.contains("--selftest-search") {
            let library: [(String, String)] = [("Кино", "Группа крови"), ("Виктор Цой", "Звезда по имени Солнце"),
                ("Океан Ельзи", "Обійми"), ("Daft Punk", "Get Lucky"), ("Чайф", "Аргентина — Ямайка 5:0"),
                ("Ляпис Трубецкой", "Капитал"), ("Mötley Crüe", "Kickstart My Heart"), ("Земфира", "Хочешь?")]
            let queries = ["kino", "Кино", "rbyj", "tsoy", "coj", "okean elzy", "обійми", "obiimy", "chaif", "jamajka",
                           "ляпис капитал", "lyapis", "motley crue", "мотли", "zemfira", "хочешь", "daft lucky", "дафт", "zzz"]
            for q in queries {
                let hits = library.filter { TrackSearch.matches(q, in: [$0.0, $0.1]) }.map { "\($0.0) — \($0.1)" }
                print("«\(q)» → " + (hits.isEmpty ? "—" : hits.joined(separator: "; ")))
            }
            exit(0)
        }
        if args.contains("--selftest-queue") {
            func run(_ title: String, start: Int, shuffle: Bool, repeatAll: Bool, steps: Int) {
                var q = PlayQueue()
                q.reset(count: 5, start: start, shuffle: shuffle)
                var seq = [q.current]
                for _ in 0..<steps {
                    if q.isAtEnd && repeatAll && shuffle { seq.append(q.newShuffledRound()); continue }
                    guard let n = q.next(repeatAll: repeatAll) else { seq.append(-1); break }
                    q.move(to: n)
                    seq.append(n)
                }
                print(title + ": " + seq.map { $0 < 0 ? "стоп" : "\($0 + 1)" }.joined(separator: " → "))
            }
            run("по порядку, повтор выкл, с 2-го", start: 1, shuffle: false, repeatAll: false, steps: 10)
            run("по порядку, повтор списка   ", start: 3, shuffle: false, repeatAll: true, steps: 8)
            run("перемешано, повтор выкл     ", start: 2, shuffle: true, repeatAll: false, steps: 10)
            run("перемешано, повтор списка   ", start: 0, shuffle: true, repeatAll: true, steps: 14)
            var q = PlayQueue(); q.reset(count: 5, start: 0, shuffle: false)
            print("«назад» с первого: повтор выкл → \(q.previous(repeatAll: false).map { "\($0 + 1)" } ?? "нет"), повтор списка → \(q.previous(repeatAll: true).map { "\($0 + 1)" } ?? "нет")")
            // Каждый круг перемешивания содержит все треки ровно по разу
            var ok = true
            for _ in 0..<200 {
                var qq = PlayQueue(); qq.reset(count: 7, start: Int.random(in: 0..<7), shuffle: true)
                if Set(qq.order).count != 7 || qq.order.first != qq.current { ok = false }
            }
            print("200 перемешиваний: все треки по разу и текущий первым — \(ok ? "да" : "НЕТ")")
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
                pc.play([PlayEntry(id: "viz", url: f, title: "Test Song", subtitle: "Test Artist · Original", artwork: nil, isVideo: false)], startAt: 0)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let i = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    print("Now Playing: «\(i[MPMediaItemPropertyTitle] ?? "-")» — \(i[MPMediaItemPropertyArtist] ?? "-"), длительность \(i[MPMediaItemPropertyPlaybackDuration] ?? "-") c, скорость \(i[MPNowPlayingInfoPropertyPlaybackRate] ?? "-"), состояние \(MPNowPlayingInfoCenter.default().playbackState.rawValue)")
                    pc.togglePlay()
                    print("после паузы: скорость \(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] ?? "-"), состояние \(MPNowPlayingInfoCenter.default().playbackState.rawValue)")
                    pc.togglePlay()
                } else { print("Now Playing: пусто") }
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
                    v.convert(model: .classic55G, settings: VideoOutputSettings.shared.apply(to: IPodModel.classic55G.settings(max: false)), videoRoot: root, addToMusic: false)
                    while v.isConverting { try? await Task.sleep(nanoseconds: 200_000_000) }
                    if case .done(let out) = v.state {
                        print("   ⇒ " + out.path.replacingOccurrences(of: root.path + "/", with: ""))
                    } else { print("   ⇒ \(v.state)") }
                }
                restoreSettings()
                exit(0)
            }
            return true
        }
        guard let i = args.firstIndex(of: "--selftest-audio"), args.count > i + 3 else { return false }
        let model = IPodModel(rawValue: args[i + 1]) ?? .classic55G
        // необязательно: --format aac:128 / mp3:320 / alac / auto
        let savedFormat = UserDefaults.standard.object(forKey: "audioFormat")
        let savedKbps = UserDefaults.standard.object(forKey: "audioKbps")
        let savedRate = UserDefaults.standard.object(forKey: "audioRate")
        defer {
            // Возвращаем настройки пользователя после изменения ниже (запись — в didSet).
        }
        restoreSettings = {
            for (k, v) in [("audioFormat", savedFormat), ("audioKbps", savedKbps), ("audioRate", savedRate)] {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
        if let f = args.firstIndex(of: "--format"), args.count > f + 1 {
            let parts = args[f + 1].split(separator: ":")
            AudioOutputSettings.shared.choice = AudioFormatChoice(rawValue: String(parts[0])) ?? .auto
            if parts.count > 1, let k = Int(parts[1]) { AudioOutputSettings.shared.kbps = k }
            if parts.count > 2, let r = Int(parts[2]) { AudioOutputSettings.shared.sampleRate = r }
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
