import Foundation
import Observation
import SwiftUI

// MARK: - Модель

struct LyricLine: Equatable {
    let time: Double
    let text: String
}

struct Lyrics: Equatable {
    /// Строки с таймингами (в такт). Пусто — есть только обычный текст.
    var lines: [LyricLine]
    var plain: String?
    var source: String
    var isSynced: Bool { !lines.isEmpty }

    /// Номер строки, которая звучит в момент time.
    func index(at time: Double) -> Int? {
        guard isSynced else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

/// Что искать: из тегов трека.
struct LyricsQuery: Equatable {
    var file: URL
    var title: String
    var artist: String?
    var album: String?
    var duration: Double
}

// MARK: - Разбор LRC

enum LRCParser {
    /// «[01:23.45]текст», несколько меток на строку, [offset:±мс], метки слов <01:23.45> убираются.
    static func parse(_ text: String) -> [LyricLine] {
        var offset = 0.0
        if let m = text.range(of: #"\[offset:\s*([+-]?\d+)\]"#, options: [.regularExpression, .caseInsensitive]) {
            let v = text[m].filter { "+-0123456789".contains($0) }
            offset = (Double(v) ?? 0) / 1000
        }
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        var out: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !ms.isEmpty else { continue }
            var body = ns.substring(from: ms.last!.range.location + ms.last!.range.length)
            body = body.replacingOccurrences(of: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for m in ms {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(time: max(0, min * 60 + sec - offset), text: body))
            }
        }
        out.sort { $0.time < $1.time }
        // Пустые строки-паузы в начале не нужны.
        while out.first?.text.isEmpty == true { out.removeFirst() }
        return out
    }

    static func looksSynced(_ text: String) -> Bool {
        text.range(of: #"\[\d{1,3}:\d{1,2}([.:]\d{1,3})?\]"#, options: .regularExpression) != nil
    }
}

// MARK: - Поиск текста

@MainActor
@Observable
final class LyricsStore {
    static let shared = LyricsStore()

    enum Status: Equatable { case idle, loading, found, notFound }

    private(set) var lyrics: Lyrics?
    private(set) var status: Status = .idle
    /// Показывать текст в полноэкранном плеере.
    var visible: Bool {
        didSet { UserDefaults.standard.set(visible, forKey: "lyricsVisible") }
    }
    /// Искать в интернете (lrclib.net): туда уходят только артист, название, альбом и длительность.
    var onlineEnabled: Bool {
        didSet { UserDefaults.standard.set(onlineEnabled, forKey: "lyricsOnline") }
    }

    @ObservationIgnored private var cache: [URL: Lyrics?] = [:]
    @ObservationIgnored private var token = UUID()

    private init() {
        visible = UserDefaults.standard.object(forKey: "lyricsVisible") as? Bool ?? true
        onlineEnabled = UserDefaults.standard.object(forKey: "lyricsOnline") as? Bool ?? true
    }

    func clear() {
        token = UUID()
        lyrics = nil
        status = .idle
    }

    func load(_ q: LyricsQuery) {
        let t = UUID()
        token = t
        if let cached = cache[q.file] {
            lyrics = cached
            status = cached == nil ? .notFound : .found
            return
        }
        lyrics = nil
        status = .loading
        let online = onlineEnabled
        Task {
            let found = await Self.find(q, online: online)
            guard t == token else { return }
            cache[q.file] = found
            lyrics = found
            status = found == nil ? .notFound : .found
        }
    }

    /// Порядок: .lrc рядом с файлом → текст в тегах файла → LRCLIB.
    nonisolated static func find(_ q: LyricsQuery, online: Bool) async -> Lyrics? {
        // 1. Файл .lrc с тем же именем
        let lrc = q.file.deletingPathExtension().appendingPathExtension("lrc")
        if let s = (try? String(contentsOf: lrc, encoding: .utf8)) ?? (try? String(contentsOf: lrc, encoding: .windowsCP1251)) {
            let lines = LRCParser.parse(s)
            if !lines.isEmpty { return Lyrics(lines: lines, plain: nil, source: ".lrc") }
        }
        // 2. Теги файла (ID3 USLT, ©lyr, LYRICS)
        var embeddedPlain: String?
        if let text = await embedded(q.file) {
            if LRCParser.looksSynced(text) {
                let lines = LRCParser.parse(text)
                if !lines.isEmpty { return Lyrics(lines: lines, plain: nil, source: L.lyricsFromFile) }
            }
            embeddedPlain = text
        }
        // 3. LRCLIB
        if online, let remote = await lrclib(q) {
            if remote.isSynced || embeddedPlain == nil { return remote }
        }
        return embeddedPlain.map { Lyrics(lines: [], plain: $0, source: L.lyricsFromFile) }
    }

    nonisolated private static func embedded(_ url: URL) async -> String? {
        guard let ffprobe = FFmpeg.tool("ffprobe"),
              let data = try? await FFmpeg.capture(ffprobe, ["-v", "error", "-print_format", "json",
                                                             "-show_entries", "format_tags:stream_tags", url.path]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var tags: [[String: Any]] = []
        if let f = json["format"] as? [String: Any], let t = f["tags"] as? [String: Any] { tags.append(t) }
        for s in json["streams"] as? [[String: Any]] ?? [] { if let t = s["tags"] as? [String: Any] { tags.append(t) } }
        for t in tags {
            for (k, v) in t {
                let key = k.lowercased()
                if key.hasPrefix("lyrics") || key.hasPrefix("unsyncedlyrics") || key == "©lyr",
                   let s = v as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
                    return s
                }
            }
        }
        return nil
    }

    nonisolated private static func lrclib(_ q: LyricsQuery) async -> Lyrics? {
        guard let artist = q.artist, !artist.isEmpty else { return nil }
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: q.title),
            URLQueryItem(name: "album_name", value: q.album ?? ""),
            URLQueryItem(name: "duration", value: "\(Int(q.duration.rounded()))"),
        ]
        if let r = await fetch(get.url!), let item = r as? [String: Any], let l = lyrics(from: item) { return l }

        // Не нашлось точное совпадение — ищем и берём ближайший по длительности (±5 с), с синхронизацией в приоритете.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: q.title), URLQueryItem(name: "artist_name", value: artist)]
        guard let list = await fetch(search.url!) as? [[String: Any]] else { return nil }
        let candidates = list.filter { abs(($0["duration"] as? Double ?? 0) - q.duration) <= 5 || q.duration <= 0 }
        let best = candidates.first { ($0["syncedLyrics"] as? String)?.isEmpty == false } ?? candidates.first
        return best.flatMap(lyrics(from:))
    }

    nonisolated private static func lyrics(from item: [String: Any]) -> Lyrics? {
        if let s = item["syncedLyrics"] as? String, !s.isEmpty {
            let lines = LRCParser.parse(s)
            if !lines.isEmpty { return Lyrics(lines: lines, plain: item["plainLyrics"] as? String, source: "LRCLIB") }
        }
        if let p = item["plainLyrics"] as? String, !p.isEmpty { return Lyrics(lines: [], plain: p, source: "LRCLIB") }
        return nil
    }

    nonisolated private static func fetch(_ url: URL) async -> Any? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("iPodConverter/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Вид: текст в такт

struct LyricsView: View {
    @Bindable var store = LyricsStore.shared
    @Bindable var controller: PlayerController

    var body: some View {
        Group {
            switch store.status {
            case .loading:
                hint(L.lyricsSearching, icon: "magnifyingglass")
            case .notFound, .idle:
                hint(store.onlineEnabled ? L.lyricsNotFound : L.lyricsNotFoundOffline, icon: "text.badge.xmark")
            case .found:
                if let l = store.lyrics {
                    if l.isSynced { synced(l) } else { plain(l) }
                }
            }
        }
    }

    private func synced(_ l: Lyrics) -> some View {
        let active = l.index(at: controller.currentTime + 0.25)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 160)
                    ForEach(Array(l.lines.enumerated()), id: \.offset) { i, line in
                        LyricLineView(text: line.text, distance: active.map { i - $0 })
                            .onTapGesture { controller.seek(to: line.time) }   // клик по строке — перемотка
                            .id(i)
                    }
                    Color.clear.frame(height: 240)
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: active) { _, new in
                guard let new else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.38)) }
            }
            .onAppear { if let a = active { proxy.scrollTo(a, anchor: UnitPoint(x: 0, y: 0.38)) } }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }

    private func plain(_ l: Lyrics) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L.lyricsNotSynced).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Text(l.plain ?? "").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(8)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 40)
        }
    }

    private func hint(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28))
            Text(text).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Кнопка «Текст» в полноэкранном плеере

struct LyricsMenu: View {
    @Bindable private var store = LyricsStore.shared

    var body: some View {
        HStack(spacing: 2) {
            Button {
                store.visible.toggle()
            } label: {
                Image(systemName: store.visible ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(store.visible ? 0.25 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.showLyrics)
            Menu {
                Toggle(L.showLyrics, isOn: $store.visible)
                Toggle(L.lyricsOnline, isOn: $store.onlineEnabled)
                if let l = store.lyrics { Text("\(L.lyricsSource): \(l.source)") }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L.lyricsOnlineHelp)
        }
        .foregroundStyle(.white)
    }
}

/// Одна строка: текущая — крупная и яркая, соседние тусклее и чуть размыты.
private struct LyricLineView: View {
    let text: String
    /// Насколько строка далеко от текущей (0 — текущая, nil — песня ещё не началась).
    let distance: Int?

    private var isActive: Bool { distance == 0 }
    private var far: Double { Double(abs(distance ?? 3)) }
    private var opacity: Double { isActive ? 1 : max(0.18, 0.5 - far * 0.08) }
    private var blur: Double { isActive ? 0 : min(far * 0.6, 2.5) }

    var body: some View {
        Text(text.isEmpty ? "♪" : text)
            .font(.system(size: isActive ? 34 : 28, weight: .bold))
            .foregroundStyle(Color.white.opacity(opacity))
            .blur(radius: blur)
            .scaleEffect(isActive ? 1 : 0.97, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isActive)
    }
}
