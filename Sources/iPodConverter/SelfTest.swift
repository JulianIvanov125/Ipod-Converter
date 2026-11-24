#if os(macOS)
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
        if args.contains("--selftest-feedback") {
            Task { @MainActor in
                AppLog.info("Selftest line with home \(NSHomeDirectory())/Music/song.mp3")
                for i in 0..<200 { AppLog.error("Filler error \(i) " + String(repeating: "x", count: 80)) }
                IPodDetector.shared.refreshNow()
                let fb = FeedbackCenter.shared
                fb.prepare(report: "iPod: nano 7 · music\nFailed:\n• \(NSHomeDirectory())/Music/a.flac — convert: boom")
                fb.text = "Конвертация упала\nподробности"
                let d = fb.diagnostics()
                print("home in diagnostics: \(d.contains(NSHomeDirectory()))")
                print(d.split(separator: "\n").prefix(8).joined(separator: "\n"))
                let u = fb.githubURL()
                print("github url length: \(u.absoluteString.count), prefix: \(u.absoluteString.prefix(120))")
                print("log file: \(AppLog.file.path), exists: \(FileManager.default.fileExists(atPath: AppLog.file.path))")
                exit(0)
            }
            return true
        }
        // --selftest-edit <папка> <обложка>: правка тегов пользователем (замена, удаление, новая обложка).
        if let i = args.firstIndex(of: "--selftest-edit"), args.count > i + 2 {
            let dir = URL(fileURLWithPath: args[i + 1])
            let cover = URL(fileURLWithPath: args[i + 2])
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("e-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for f in files {
                    let t = TrackItem(url: f)
                    await t.load()
                    let e = await t.saveTags(set: ["title": "Edited Title", "album": "Edited Album", "genre": "Jazz", "track": "7/12"],
                                             clear: ["date"], cover: cover)
                    let a = try? await FFmpeg.probeAudio(f)
                    print("\(f.lastPathComponent): ошибка=\(e ?? "-") title=\(a?.title ?? "-") album=\(a?.album ?? "-") genre=\(a?.tags["genre"] ?? "-") track=\(a?.tags["track"] ?? "-") date=\(a?.tags["date"] ?? "нет") обложка=\(a?.coverStreamIndex != nil) smpb=\(a?.tags["itunsmpb"] != nil)")
                }
                exit(0)
            }
            return true
        }
        // --selftest-refresh [файл]: отложенное обновление «Музыки» (файл — добавить; без файла — только дождаться).
        if let i = args.firstIndex(of: "--selftest-refresh") {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                let r = MusicRefresher.shared
                r.start()
                print("ждут с прошлого раза: \(r.waiting), «Музыка» открыта: \(MusicRefresher.musicRunning)")
                if args.count > i + 1 { r.add(URL(fileURLWithPath: args[i + 1]), cover: nil) }
                let started = Date()
                while r.waiting > 0 && Date().timeIntervalSince(started) < 45 { try? await Task.sleep(nanoseconds: 500_000_000) }
                print("через \(Int(Date().timeIntervalSince(started))) с ждут: \(r.waiting)")
                exit(0)
            }
            return true
        }
        // --selftest-videodups <папка>: какие видео приложение считает дублями и какое оставит.
        if let i = args.firstIndex(of: "--selftest-videodups"), args.count > i + 1 {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                let dir = URL(fileURLWithPath: args[i + 1])
                let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { ["mp4", "m4v", "mov", "mkv", "webm", "avi"].contains($0.pathExtension.lowercased()) }
                var items: [VideoItem] = []
                for f in files { let v = VideoItem(url: f); await v.load(); items.append(v) }
                let groups = DuplicateFinder.videoGroups(items, keep: [:])
                print("видео: \(items.count), групп дублей: \(groups.count)")
                for g in groups {
                    print("• \(g.key)")
                    for v in g.all {
                        let i = v.info!
                        print("   \(v.id == g.keeper.id ? "ОСТАВИМ" : "копия  ") \(i.displayWidth)×\(i.displayHeight) \(i.videoCodec) — \(v.url.lastPathComponent)")
                    }
                }
                exit(0)
            }
            return true
        }
        // --selftest-update <dmg> <sha256> <версия>: обновление этой копии приложения из локального DMG.
        if let i = args.firstIndex(of: "--selftest-update"), args.count > i + 3 {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                print("сравнение версий: 1.3.10>1.3.9 \(Updater.isNewer("1.3.10", than: "1.3.9")), 1.4>1.3.1 \(Updater.isNewer("1.4", than: "1.3.1")), 1.3.1>1.3.1 \(Updater.isNewer("1.3.1", than: "1.3.1"))")
                if let r = try? await Updater.fetchLatest() {
                    print("GitHub: последний \(r.version), dmg \(r.dmg != nil), digest \(r.dmgSHA256 ?? "нет"), sha256 \(r.sha256 != nil), новее текущей \(Updater.isNewer(r.version, than: Updater.currentVersion))")
                }
                print("можно заменить на месте: \(Updater.canReplaceInPlace) (\(Bundle.main.bundleURL.path))")
                do {
                    // Третий аргумент — файл .sha256 или «sha256:<hex>», как поле digest в API GitHub.
                    let shaArg = args[i + 2]
                    let app = try await Updater.prepare(dmg: URL(fileURLWithPath: args[i + 1]),
                                                        expectedSHA256: shaArg.hasPrefix("sha256:") ? String(shaArg.dropFirst(7)) : nil,
                                                        sha: shaArg.hasPrefix("sha256:") ? nil : URL(fileURLWithPath: shaArg),
                                                        version: args[i + 3]) { _ in }
                    print("подготовлено: \(app.lastPathComponent) — перезапуск")
                    // Как у пользователя: окно обновления открыто листом — раньше из-за него выход отменялся.
                    Updater.shared.phase = .installing
                    Updater.shared.showWindow = true
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    try Updater.relaunch(replacingWith: app)
                } catch {
                    print("ОШИБКА: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return true
        }
        // --selftest-tags <папка с копиями файлов> <обложка.jpg>: пишет теги в файлы, проверяет пометку и дубли.
        if let i = args.firstIndex(of: "--selftest-tags"), args.count > i + 2 {
            let dir = URL(fileURLWithPath: args[i + 1])
            let cover = URL(fileURLWithPath: args[i + 2])
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { AudioRules.audioExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for f in files where f.lastPathComponent.hasPrefix("w-") {
                    let t = TrackItem(url: f)
                    await t.load()
                    let before = t.info!
                    var meta = FetchedMeta()
                    meta.fields = ["album": "Selftest Album", "date": "1999", "genre": "Rock"].filter { before.tags[$0.key] == nil }
                    if before.coverStreamIndex == nil { meta.coverFile = cover }
                    if meta.isEmpty { print("\(f.lastPathComponent): все теги уже есть — пропуск"); continue }
                    t.apply(meta)
                    while t.tagsWritten == false && t.tagWriteError == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                    let again = TrackItem(url: f)
                    await again.load()
                    let a = again.info!
                    print("\(f.lastPathComponent): записано=\(t.tagsWritten) ошибка=\(t.tagWriteError ?? "-") | после перезапуска: пометка=\(again.metaStatus) [\(again.fetched?.summary ?? "")] album=\(a.album ?? "-") date=\(a.tags["date"] ?? "-") обложка=\(a.coverStreamIndex != nil) оценка=\(a.rating.map(String.init) ?? "-") кодек=\(before.codec)→\(a.codec) длит=\(String(format: "%.2f→%.2f", before.duration, a.duration)) needsRetag=\(again.needsRetag)")
                }
                let st = Store()
                for f in files where f.lastPathComponent.hasPrefix("d-") { let t = TrackItem(url: f); await t.load(); st.tracks.append(t) }
                for g in st.duplicateGroups {
                    print("группа \(g.key): оставим \(g.keeper.url.lastPathComponent), копии: \(g.extras.map(\.url.lastPathComponent))")
                }
                st.musicScope = .duplicates
                print("в списке «Дубликаты»: \(st.visibleTracks.count), лишних \(st.duplicateExtras.count)")
                st.setAllDuplicatesSelected(true)
                print("выбрано всё: \(st.selectedDuplicates.count), среди них оставляемые: \(st.selectedDuplicates.filter { s in st.duplicateGroups.contains { $0.keeper.id == s.id } }.count)")
                // Попытка удалить и оставляемый файл — должен остаться.
                let keepers = st.duplicateGroups.map(\.keeper)
                st.trashDuplicates(st.selectedDuplicates + keepers)
                print("после удаления: \(st.musicBatchStatus?.text ?? "-"), в списке \(st.tracks.count), оставляемые на месте: \(keepers.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })")
                exit(0)
            }
            return true
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
                let query = TrackSearch.Query(q)
                let hits = library.filter { query.matches(TrackSearch.hay([$0.0, $0.1])) }.map { "\($0.0) — \($0.1)" }
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
                    let r: URL? = await withCheckedContinuation { cont in t.convert(plan: p, model: .classic55G, into: out) { cont.resume(returning: $0) } }
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
        if let i = args.firstIndex(of: "--selftest-batch"), args.count > i + 2 {
            // Пачка видео через очередь: сколько идёт одновременно, как растёт общий прогресс.
            // Пишет только во временную папку, в «Музыку» не добавляет; настройки возвращаются как были.
            let root = URL(fileURLWithPath: args[i + 1])
            let files = args[(i + 2)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            let domain = Bundle.main.bundleIdentifier ?? "local.ipodconverter"
            let saved = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            Task { @MainActor in
                let st = Store()
                st.addToMusic = false
                st.rootFolder = root
                st.createFolderStructure()
                for f in files { let v = VideoItem(url: f); v.viewModel = st.model; st.items.append(v); await v.load() }
                // «--break»: исходник третьего файла пропадает после анализа — проверяем, как видна ошибка.
                if args.contains("--break"), files.count > 2 { try? FileManager.default.removeItem(at: files[2]) }
                st.enqueueVideos(st.items)
                var maxRunning = 0, log: [String] = []
                let t0 = Date()
                while st.isVideoBusy {
                    let running = st.items.filter { if case .converting = $0.state { return true } else { return false } }.count
                    maxRunning = max(maxRunning, running)
                    if let p = st.videoBatchProgress, log.last != "\(p.done)/\(p.total)" { log.append("\(p.done)/\(p.total)") }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let done = st.items.filter { if case .done = $0.state { return true } else { return false } }.count
                print("пачка: \(files.count) видео, одновременно максимум \(maxRunning), готово \(done), за \(String(format: "%.1f", Date().timeIntervalSince(t0))) с")
                print("прогресс: " + log.joined(separator: " → "))
                print("статус: \(st.videoBatchStatus.map { $0.text } ?? "-")")
                // Вкладки: у другого iPod своё состояние — ни «готово», ни ошибок от этой пачки.
                @MainActor func isDone(_ v: VideoItem) -> Bool { if case .done = v.state { return true } else { return false } }
                @MainActor func isFailed(_ v: VideoItem) -> Bool { if case .failed = v.state { return true } else { return false } }
                let first = st.model
                let other: IPodModel = first == .nano7 ? .classic5G : .nano7
                let a = (st.items.filter(isDone).count, st.items.filter(isFailed).count)
                st.model = other
                let b = (st.items.filter(isDone).count, st.items.filter(isFailed).count, st.videosToConvert.count)
                st.model = first
                let c = st.items.filter(isDone).count
                print("вкладка \(first.title): готово \(a.0), ошибок \(a.1) · вкладка \(other.title): готово \(b.0), ошибок \(b.1), к конвертации \(b.2) · обратно: готово \(c)")
                if let r = st.videoReport { print("--- отчёт ---\n" + r) }
                UserDefaults.standard.setPersistentDomain(saved, forName: domain)
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-dynamics"), args.count > i + 1 {
            // По секундам: динамика песни и сколько капель упало (тихая часть → громкая).
            let f = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                let pc = PlayerController.shared
                // Не mute: при выключенном звуке macOS через несколько секунд перестаёт прогонять звук через анализатор.
                pc.player.volume = 0.001
                pc.play([PlayEntry(id: "dyn", url: f, title: "Test", subtitle: "", artwork: nil, isVideo: false)], startAt: 0)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let sm = LevelSmoother(), field = DropField()
                let t0 = Date().timeIntervalSinceReferenceDate
                var sec = 0, lastSpawned = 0, line: [String] = []
                while Date().timeIntervalSinceReferenceDate - t0 < 12 {
                    let t = Date().timeIntervalSinceReferenceDate
                    field.spawn(sm.update(time: t), time: t, intensity: sm.intensity)
                    if Int(t - t0) > sec {
                        let raw = AudioAnalyzer.shared.snapshot(); line.append(String(format: "%d с: динамика %.2f, капель %d, дБ %.1f, макс. полоса %.2f, играет %d, позиция %.1f, ошибка %@", sec + 1, sm.intensity, field.spawned - lastSpawned, sm.loudNow, raw.max() ?? 0, pc.isPlaying ? 1 : 0, pc.currentTime, pc.error ?? "-"))
                        lastSpawned = field.spawned; sec = Int(t - t0)
                    }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                print(line.joined(separator: "\n"))
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-load"), args.count > i + 2, let n = Int(args[i + 1]) {
            // Нагрузка: n анализов файлов через ту же очередь, что и при добавлении папки; ни один не должен зависнуть.
            let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                let items = (0..<n).map { TrackItem(url: files[$0 % files.count]) }
                let t0 = Date()
                for t in items {
                    Task {
                        await TaskLimiter.probes.acquire()
                        await t.load()
                        await TaskLimiter.probes.release()
                    }
                }
                while items.contains(where: { $0.state == .loading }) && Date().timeIntervalSince(t0) < 90 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let stuck = items.filter { $0.state == .loading }.count
                let failed = items.filter { if case .failed = $0.state { return true } else { return false } }.count
                print(String(format: "анализ %d файлов: %.1f с, зависло %d, с ошибкой %d", n, Date().timeIntervalSince(t0), stuck, failed))
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-cover"), args.count > i + 1 {
            // Примеры обложек плейлиста в PNG.
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                let p = CoverPresets.all
                let designs: [(String, CoverDesign)] = [
                    ("gradient", CoverDesign(title: "Lana Del Rey Mood", subtitle: "Ultraviolence", top: p[0].0, bottom: p[0].1, background: .gradient)),
                    ("glow", CoverDesign(title: "Для бега", top: p[4].0, bottom: p[5].1, background: .glow)),
                    ("solid", CoverDesign(title: "Chill", subtitle: "iPod nano 7", top: p[2].0, bottom: p[2].1, background: .solid)),
                ]
                for (name, d) in designs {
                    if let data = CoverRenderer.png(d) { try? data.write(to: dir.appendingPathComponent("cover-\(name).png")) }
                }
                print("обложки сохранены")
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--selftest-classify"), args.count > i + 1 {
            // Как приложение поймёт видео: тип, исполнитель, название.
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                for f in files {
                    guard let info = try? await FFmpeg.probe(f) else { print("\(f.lastPathComponent): не читается"); continue }
                    let m = VideoClassifier.guess(url: f, info: info)
                    print("\(f.lastPathComponent)\n   → \(m.category.rawValue): «\(m.artist)» — «\(m.title)»")
                }
                exit(0)
            }
            return true
        }
        if args.contains("--selftest-detect") {
            // Сколько стоит один опрос iPod (то, что таймер делает каждые 2 с).
            Task { @MainActor in
                let d = IPodDetector.shared
                d.refreshNow()
                let t0 = Date()
                for _ in 0..<10 { d.refreshNow() }
                func ms(_ f: () -> Void) -> Double { let t = Date(); for _ in 0..<10 { f() }; return Date().timeIntervalSince(t) * 100 }
                let usb = IPodDetector.usbDevices()
                print(String(format: "usb %.2f, доступ %.2f, диски %.2f, detect %.2f мс",
                             ms { _ = IPodDetector.usbDevices() }, ms { _ = IPodDetector.volumeAccessDenied(usb: usb) },
                             ms { _ = IPodDetector.mountedIPods() }, ms { _ = IPodDetector.detect(usb: usb) }))
                print(String(format: "опрос iPod: %.1f мс за раз; найдено: %@", Date().timeIntervalSince(t0) * 100,
                             d.devices.map { "\($0.model.rawValue) «\($0.name ?? "-")» свободно \(Fmt.bytes($0.freeBytes ?? 0)) из \(Fmt.bytes($0.totalBytes ?? 0))" }.joined(separator: ", ")))
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--selftest-water"), args.count > i + 1 {
            // Модель воды без звука: капли по расписанию, кадры в PNG 1600×900, время кадра.
            let dir = URL(fileURLWithPath: args[i + 1])
            let water = WaterSurface()
            water.resize(to: CGSize(width: 1600, height: 900))
            let tones: [SIMD3<Float>] = [SIMD3(0.95, 0.25, 0.2), SIMD3(0.95, 0.6, 0.3), SIMD3(0.4, 0.6, 0.95)]
            var t = 1000.0
            var shots = [0.4, 1.2, 2.5]
            var cost = 0.0, frames = 0
            for f in 0..<180 {
                if f % 15 == 0 { water.drop(x: .random(in: 0.1...0.9), y: .random(in: 0.1...0.9), strength: 1.2, radius: 6.5, color: tones[0]) }
                if f % 15 == 7 { water.drop(x: .random(in: 0.1...0.9), y: .random(in: 0.1...0.9), strength: 0.7, radius: 3.4, color: tones[(f / 15) % 2 + 1]) }
                t += 1.0 / 60
                let c0 = Date()
                water.advance(to: t)
                let img = water.image(deep: SIMD3(0.07, 0.05, 0.07), glow: 0.2)
                cost += Date().timeIntervalSince(c0); frames += 1
                if let s0 = shots.first, Double(f) / 60 >= s0, let img {
                    shots.removeFirst()
                    let ctx = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.interpolationQuality = .high
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1600, height: 900))
                    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "water-%.1f.png", s0)))
                }
            }
            print(String(format: "вода: %.2f мс на кадр (сетка %d×%d)", cost / Double(frames) * 1000, water.w, water.h))
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest-viz"), args.count > i + 1 {
            let f = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                let pc = PlayerController.shared
                pc.player.volume = 0.001   // не mute: при mute macOS перестаёт отдавать звук анализатору
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
                let field = DropField()
                var flowMin: Float = 1, flowMax: Float = 0, kickMax: Float = 0, eqBass: Float = 0, eq2k: Float = 0, eqTop: Float = 0
                for _ in 0..<240 {
                    let t = Date().timeIntervalSinceReferenceDate
                    let os = sm.update(time: t)
                    field.spawn(os, time: t)
                    flowMin = min(flowMin, sm.flowLevel[0]); flowMax = max(flowMax, sm.flowLevel[0]); kickMax = max(kickMax, sm.kick)
                    let b60 = Int(LevelSmoother.band(for: 60)), b2k = Int(LevelSmoother.band(for: 2000))
                    eqBass = max(eqBass, sm.eq[b60]); eq2k = max(eq2k, sm.eq[b2k]); eqTop = max(eqTop, sm.eq[LevelSmoother.n - 3])
                    for o in os {
                        log.append(String(format: "%.2fс ", t - t0) + (o.band < 0 ? "БАС" : LevelSmoother.label(LevelSmoother.hz(o.band))))
                    }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                print("капли (\(log.count)): " + log.joined(separator: " | "))
                print("видимых капель за 4 с: \(field.spawned); бас-пятно цвета: \(String(format: "%.2f…%.2f", flowMin, flowMax)), фаза \(String(format: "%.2f", sm.flowPhase[0])), удар до \(String(format: "%.2f", kickMax))")
                print(String(format: "эквалайзер (макс.): 60 Гц %.2f, 2 кГц %.2f, верх %.2f", eqBass, eq2k, eqTop))
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
                    t.convert(plan: plan, model: model, into: out) { cont.resume(returning: $0) }
                }
                print("   ⇒ \(result?.lastPathComponent ?? "FAILED: \(t.state)")")
            }
            restoreSettings()
            exit(0)
        }
        return true
    }
}
#endif
