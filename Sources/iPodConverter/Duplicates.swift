import AppKit
import Foundation

/// Группа одинаковых треков: один остаётся (лучшее качество или выбранный вручную), остальные — лишние копии.
struct DuplicateGroup: Identifiable {
    let key: String
    let keeper: TrackItem
    let extras: [TrackItem]
    var id: String { key }
    var all: [TrackItem] { [keeper] + extras }
}

enum DuplicateFinder {
    /// Сравниваем без регистра, диакритики и знаков препинания. Скобки не выкидываем:
    /// «Song (Live)» и «Song» — разные записи.
    static func norm(_ s: String?) -> String {
        guard let s else { return "" }
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

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
    var duplicateGroups: [DuplicateGroup] { DuplicateFinder.groups(tracks, keep: dupKeep) }

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
