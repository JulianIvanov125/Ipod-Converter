import Foundation

enum DuplicateFinder {
    /// Сравниваем без регистра, диакритики и знаков препинания. Скобки не выкидываем:
    /// «Song (Live)» и «Song» — разные записи.
    static func norm(_ s: String?) -> String {
        guard let s else { return "" }
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

}

#if os(macOS)
/// Группа одинаковых треков: один остаётся (лучшее качество или выбранный вручную), остальные — лишние копии.
struct DuplicateGroup: Identifiable {
    let key: String
    let keeper: TrackItem
    let extras: [TrackItem]
    var id: String { key }
    var all: [TrackItem] { [keeper] + extras }
}

extension DuplicateFinder {
    /// Чем лучше копия, тем больше: без потерь, выше битрейт, есть обложка, больше тегов, есть оценка.
    @MainActor static func quality(_ t: TrackItem) -> (Int, Int, Int, Int, Int) {
        let i = t.info
        return (i?.isLossless == true ? 1 : 0, i?.bitrate ?? 0, i?.coverStreamIndex != nil || t.artwork != nil ? 1 : 0,
                i?.tags.count ?? 0, t.rating)
    }

    /// Группы дублей: тот же артист и название, длительность отличается не больше чем на 2 с.
    @MainActor
    static func groups(_ tracks: [TrackItem], keep: [String: UUID]) -> [DuplicateGroup] {
        var byName: [String: [TrackItem]] = [:]
        var order: [String] = []
        for t in tracks {
            guard let key = t.dupKey else { continue }
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(t)
        }
        var out: [DuplicateGroup] = []
        for key in order {
            guard let list = byName[key], list.count > 1 else { continue }
            // Внутри одного названия — разбиваем по длительности (разные версии песни не дубли).
            let sorted = list.sorted { ($0.info?.duration ?? 0) < ($1.info?.duration ?? 0) }
            var clusters: [[TrackItem]] = []
            for t in sorted {
                if let last = clusters.last?.last, abs((last.info?.duration ?? 0) - (t.info?.duration ?? 0)) <= 2 {
                    clusters[clusters.count - 1].append(t)
                } else {
                    clusters.append([t])
                }
            }
            for (n, c) in clusters.enumerated() where c.count > 1 {
                let gkey = "\(key)#\(n)"
                let chosen = keep[gkey].flatMap { id in c.first { $0.id == id } }
                let keeper = chosen ?? c.max { quality($0) < quality($1) }!
                let extras = c.filter { $0.id != keeper.id }
                    .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
                out.append(DuplicateGroup(key: gkey, keeper: keeper, extras: extras))
            }
        }
        return out
    }
}

extension Store {
    /// Группы дублей считаются заново, только когда изменился список, теги или выбор «оставить этот»
    /// (иначе на тысячах треков пересчёт шёл бы на каждую перерисовку окна).
    var duplicateGroups: [DuplicateGroup] {
        var h = Hasher()
        h.combine(tracks.count)
        for t in tracks { h.combine(ObjectIdentifier(t)) }
        h.combine(TrackItem.infoVersion)
        for (k, v) in dupKeep.sorted(by: { $0.key < $1.key }) { h.combine(k); h.combine(v) }
        let sig = h.finalize()
        if let c = dupCache, c.sig == sig { return c.groups }
        let g = DuplicateFinder.groups(tracks, keep: dupKeep)
        dupCache = (sig, g)
        return g
    }

    /// Лишние копии (их можно удалять).
    var duplicateExtras: [TrackItem] { duplicateGroups.flatMap(\.extras) }

    /// Оставить этот файл, а другие копии группы считать лишними.
    func keepDuplicate(_ t: TrackItem) {
        guard let g = duplicateGroups.first(where: { $0.all.contains { $0.id == t.id } }) else { return }
        dupKeep[g.key] = t.id
        dupSelection.remove(t.id)
    }

    func setDuplicateSelected(_ t: TrackItem, _ on: Bool) {
        if on { dupSelection.insert(t.id) } else { dupSelection.remove(t.id) }
    }

    /// Выбрать/снять все лишние копии (с учётом поиска).
    func setAllDuplicatesSelected(_ on: Bool) {
        let ids = Set(visibleTracks.map(\.id)).intersection(duplicateExtras.map(\.id))
        if on { dupSelection.formUnion(ids) } else { dupSelection.subtract(ids) }
    }

    var selectedDuplicates: [TrackItem] {
        duplicateExtras.filter { dupSelection.contains($0.id) }
    }

    /// Убрать лишние копии в Корзину. Оставляемый файл группы не трогаем никогда.
    func trashDuplicates(_ list: [TrackItem]) {
        let groups = duplicateGroups
        let extras = Set(groups.flatMap(\.extras).map(\.id))
        let keepers = Set(groups.map(\.keeper.id))
        var moved = 0
        var failed: [String] = []
        for t in list where extras.contains(t.id) && !keepers.contains(t.id) && !t.isActive {
            if let cur = PlayerController.shared.current, cur.id.hasSuffix(t.id.uuidString) { PlayerController.shared.close() }
            do {
                try FileManager.default.trashItem(at: t.url, resultingItemURL: nil)
                removeTrack(t)
                dupSelection.remove(t.id)
                moved += 1
            } catch {
                failed.append("\(t.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if failed.isEmpty {
            musicBatchStatus = (L.dupTrashed(moved), true)
        } else {
            musicBatchStatus = (L.dupTrashFailed(moved, failed.count) + " " + failed.joined(separator: "; "), false)
        }
        if duplicateGroups.isEmpty && musicScope == .duplicates { musicScope = .all }
    }
}

#endif

// MARK: - Дубли видео

/// Группа одинаковых видео: одно остаётся (лучшее качество или выбранное вручную), остальные — лишние копии.
/// Видео для поиска дублей: и карточка Mac-приложения, и элемент списка в Linux-версии.
@MainActor
protocol VideoDupItem: AnyObject {
    var id: UUID { get }
    var url: URL { get }
    var meta: VideoMeta? { get }
    var info: MediaInfo? { get }
}

struct VideoDuplicateGroup<V: VideoDupItem>: Identifiable {
    let key: String
    let keeper: V
    let extras: [V]
    var id: String { key }
    var all: [V] { [keeper] + extras }
}

extension DuplicateFinder {
    /// Хвосты, которые не делают видео другим: наши пометки «_ipod5g_480», «[iPod nano 7]»
    /// и типичные приписки загрузок «(Official Video)», «(Official Music Video)», «HD».
    static func cleanVideoTitle(_ s: String) -> String {
        var t = s
        for p in [#"(?i)_ipod[a-z0-9_.]*"#,
                  #"(?i)\[\s*ipod[^\]]*\]"#,
                  #"(?i)[\(\[]\s*(official|offical)?\s*(music\s*)?(video|clip|audio|lyric(s)?(\s*video)?)\s*(hd|hq|4k)?\s*[\)\]]"#,
                  #"(?i)[\(\[]\s*(hd|hq|4k|1080p|720p)\s*[\)\]]"#] {
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        return t
    }

    /// Ключ видео: клип — артист и название, фильм — название и год, серия — сериал, сезон и номер.
    /// Для какого iPod сделан файл: «[iPod nano 7]» в имени или альбом «iPod …» (так подписывает приложение).
    /// Версии одного видео для разных iPod нужны обе — это не дубли.
    @MainActor static func videoTarget(_ v: some VideoDupItem) -> String {
        let name = v.url.deletingPathExtension().lastPathComponent
        if let r = name.range(of: #"\[(iPod[^\]]*)\]"#, options: .regularExpression) {
            return norm(String(name[r]))
        }
        let album = v.info?.tags["album"] ?? ""
        return album.lowercased().hasPrefix("ipod ") ? norm(album) : ""
    }

    @MainActor static func videoKey(_ v: some VideoDupItem) -> String? {
        guard let m = v.meta, v.info != nil else { return nil }
        let target = videoTarget(v)
        return baseVideoKey(m).map { target.isEmpty ? $0 : "\($0)|\(target)" }
    }

    static func baseVideoKey(_ m: VideoMeta) -> String? {
        switch m.category {
        case .musicVideo:
            let title = norm(cleanVideoTitle(m.title))
            guard !title.isEmpty else { return nil }
            return "mv|\(norm(m.artist))|\(title)"
        case .film:
            let title = norm(cleanVideoTitle(m.title))
            guard !title.isEmpty else { return nil }
            return "film|\(title)|\(m.year)"
        case .serial:
            guard !m.show.isEmpty else { return nil }
            return "tv|\(norm(m.show))|\(m.season)|\(m.episode)"
        }
    }

    /// Чем лучше копия, тем больше: больше картинка, современнее кодек, выше битрейт, больше файл.
    @MainActor static func videoQuality(_ v: some VideoDupItem) -> (Int, Int, Int, Int64) {
        guard let i = v.info else { return (0, 0, 0, 0) }
        let codec: Int
        switch i.videoCodec.lowercased() {
        case "hevc", "h265", "av1", "vp9": codec = 3
        case "h264": codec = 2
        default: codec = 1
        }
        return (i.displayWidth * i.displayHeight, codec, i.videoBitrate ?? 0, i.fileSize)
    }

    /// Группы дублей видео: тот же ключ и длительность отличается не больше чем на 2 с.
    @MainActor
    static func videoGroups<V: VideoDupItem>(_ items: [V], keep: [String: UUID]) -> [VideoDuplicateGroup<V>] {
        var byKey: [String: [V]] = [:]
        var order: [String] = []
        for v in items {
            guard let key = videoKey(v) else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(v)
        }
        var out: [VideoDuplicateGroup<V>] = []
        for key in order {
            guard let list = byKey[key], list.count > 1 else { continue }
            let sorted = list.sorted { ($0.info?.duration ?? 0) < ($1.info?.duration ?? 0) }
            var clusters: [[V]] = []
            for v in sorted {
                if let last = clusters.last?.last, abs((last.info?.duration ?? 0) - (v.info?.duration ?? 0)) <= 2 {
                    clusters[clusters.count - 1].append(v)
                } else {
                    clusters.append([v])
                }
            }
            for (n, c) in clusters.enumerated() where c.count > 1 {
                let gkey = "\(key)#\(n)"
                let chosen = keep[gkey].flatMap { id in c.first { $0.id == id } }
                let keeper = chosen ?? c.max { videoQuality($0) < videoQuality($1) }!
                let extras = c.filter { $0.id != keeper.id }
                    .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
                out.append(VideoDuplicateGroup<V>(key: gkey, keeper: keeper, extras: extras))
            }
        }
        return out
    }
}

#if os(macOS)
extension VideoItem: VideoDupItem {}

extension Store {
    /// Группы дублей видео (с учётом фильтра по типу).
    var videoDuplicateGroups: [VideoDuplicateGroup<VideoItem>] {
        let list = videoFilter.map { f in items.filter { $0.meta?.category == f } } ?? items
        return DuplicateFinder.videoGroups(list, keep: videoDupKeep)
    }

    var videoDuplicateExtras: [VideoItem] { videoDuplicateGroups.flatMap(\.extras) }

    func keepVideoDuplicate(_ v: VideoItem) {
        guard let g = videoDuplicateGroups.first(where: { $0.all.contains { $0.id == v.id } }) else { return }
        videoDupKeep[g.key] = v.id
        videoDupSelection.remove(v.id)
    }

    func setVideoDuplicateSelected(_ v: VideoItem, _ on: Bool) {
        if on { videoDupSelection.insert(v.id) } else { videoDupSelection.remove(v.id) }
    }

    func setAllVideoDuplicatesSelected(_ on: Bool) {
        let ids = Set(videoDuplicateExtras.map(\.id))
        if on { videoDupSelection.formUnion(ids) } else { videoDupSelection.subtract(ids) }
    }

    var selectedVideoDuplicates: [VideoItem] {
        videoDuplicateExtras.filter { videoDupSelection.contains($0.id) }
    }

    /// Убрать лишние копии видео в Корзину. Оставляемый файл группы не трогаем никогда.
    func trashVideoDuplicates(_ list: [VideoItem]) {
        let groups = DuplicateFinder.videoGroups(items, keep: videoDupKeep)
        let extras = Set(groups.flatMap(\.extras).map(\.id))
        let keepers = Set(groups.map(\.keeper.id))
        var moved = 0
        var failed: [String] = []
        for v in list where extras.contains(v.id) && !keepers.contains(v.id) && !v.isConverting {
            if let cur = PlayerController.shared.current, cur.id.hasSuffix(v.id.uuidString) { PlayerController.shared.close() }
            do {
                try FileManager.default.trashItem(at: v.url, resultingItemURL: nil)
                remove(v)
                videoDupSelection.remove(v.id)
                moved += 1
                AppLog.info("Duplicate video moved to Trash: \(v.url.path)")
            } catch {
                failed.append("\(v.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        videoBatchStatus = failed.isEmpty
            ? (L.dupTrashed(moved), true)
            : (L.dupTrashFailed(moved, failed.count) + " " + failed.joined(separator: "; "), false)
        if videoDuplicateGroups.isEmpty && videoScope == .duplicates { videoScope = .all }
    }
}
#endif
