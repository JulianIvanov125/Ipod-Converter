import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Поля, которые можно править (ключи — как у ffmpeg).
enum TagField: String, CaseIterable, Identifiable {
    case title, artist, album, album_artist, date, genre, track, disc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: L.tagTitle
        case .artist: L.tagArtist
        case .album: L.tagAlbum
        case .album_artist: L.tagAlbumArtist
        case .date: L.tagYear
        case .genre: L.tagGenre
        case .track: L.tagTrack
        case .disc: L.tagDisc
        }
    }
    /// Поля, которые у каждого трека свои: при правке нескольких треков сразу не показываем.
    var perTrack: Bool { self == .title || self == .track }

    @MainActor func value(_ t: TrackItem) -> String {
        guard let info = t.info else { return "" }
        switch self {
        case .title: return info.title ?? ""
        case .artist: return info.artist ?? ""
        case .album: return info.album ?? ""
        default: return info.tags[rawValue] ?? (self == .date ? info.tags["year"] ?? "" : "")
        }
    }
}

extension TrackItem {
    /// Записать правку тегов в файл. nil — успех, иначе текст ошибки.
    func saveTags(set: [String: String], clear: Set<String>, cover: URL?) async -> String? {
        guard !isActive else { return L.tagBusy }
        guard let original = try? await FFmpeg.probeAudio(url) else { return L.metaWriteCheckFailed }
        switch await TagWriter.edit(url: url, info: original, set: set, clear: clear, cover: cover) {
        case .success:
            AppLog.info("Tags edited: \(url.path) — " + (set.keys.sorted() + clear.sorted().map { "-\($0)" } + (cover != nil ? ["cover"] : [])).joined(separator: ","))
            let keepRating = rating
            if let fresh = try? await FFmpeg.probeAudio(url) {
                info = fresh
                if let idx = fresh.coverStreamIndex, cover != nil { artwork = await FFmpeg.coverThumbnail(url, index: idx) }
            }
            rating = keepRating
            tagsWritten = fetched != nil
            MusicRefresher.shared.add(url, cover: cover)
            return nil
        case .failure(let e):
            AppLog.error("Tags not edited: \(url.path) — \(e.message)")
            return e.message
        }
    }
}

enum CoverImage {
    /// Картинка → JPEG до 1400 px во временной папке (iPod и «Музыке» больше не нужно).
    static func jpegFile(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, 1400 / Double(max(w, h)))
        let nw = Int(Double(w) * scale), nh = Int(Double(h) * scale)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: nw, pixelsHigh: nh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: nw, height: nh).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: nw, height: nh))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iPodConverter/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("edit-\(UUID().uuidString.prefix(8)).jpg")
        return (try? data.write(to: file)) != nil ? file : nil
    }
}

/// Окно правки тегов: один трек или сразу несколько отмеченных (например, весь альбом).
struct TagEditorView: View {
    let tracks: [TrackItem]
    @Environment(\.dismiss) private var dismiss
    @State private var values: [TagField: String] = [:]
    @State private var original: [TagField: String?] = [:]   // nil — у треков разные значения
    @State private var cover: NSImage?
    @State private var coverChanged = false
    @State private var saving = false
    @State private var errors: [String] = []
    @State private var dropTarget = false

    private var multi: Bool { tracks.count > 1 }
    private var fields: [TagField] { TagField.allCases.filter { !multi || !$0.perTrack } }
    private var coverSupported: Bool { tracks.allSatisfy { TagWriter.canWriteCover($0.url.pathExtension.lowercased()) } }
    private var writable: Bool { tracks.allSatisfy { TagWriter.canWrite($0.url.pathExtension.lowercased()) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(multi ? L.tagEditTitleN(tracks.count) : L.tagEditTitle)
                .font(.system(size: 15, weight: .semibold))
            if !multi, let t = tracks.first {
                Text(t.url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: 16) {
                coverBox
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                    ForEach(fields) { f in
                        GridRow {
                            Text(f.label).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            TextField(placeholder(f), text: Binding(get: { values[f] ?? "" }, set: { values[f] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: f == .date || f == .track || f == .disc ? 90 : 260)
                        }
                    }
                }
                .font(.system(size: 12))
            }
            if !writable {
                Label(L.metaWriteUnsupported, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if !errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(errors, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled) }
                    }
                }
                .frame(maxHeight: 80)
            }
            Text(L.tagEditNote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(L.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.tagSave) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !writable || !hasChanges)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private var coverBox: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.tint(0.06))
                if let cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo").font(.system(size: 22))
                        Text(L.tagDropCover).font(.system(size: 10)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(8)
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTarget ? Color.accentColor : Theme.tint(0.12), lineWidth: dropTarget ? 2 : 1))
            .onDrop(of: [.image, .fileURL], isTargeted: $dropTarget) { providers in
                takeImage(from: providers)
            }
            HStack(spacing: 6) {
                Button(L.tagChooseCover) { chooseCover() }
                Button(L.tagPasteCover) {
                    if let img = NSImage(pasteboard: .general) { cover = img; coverChanged = true }
                }
            }
            .controlSize(.small)
            .disabled(!coverSupported)
            if !coverSupported {
                Text(L.tagCoverUnsupported).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 140)
            }
        }
        .disabled(!coverSupported)
    }

    private func placeholder(_ f: TagField) -> String {
        if case .some(nil) = original[f] { return L.tagMixed }
        return ""
    }

    private var hasChanges: Bool {
        coverChanged || fields.contains { f in (values[f] ?? "") != ((original[f] ?? nil) ?? "") }
    }

    private func load() {
        for f in TagField.allCases {
            let vals = Set(tracks.map { f.value($0) })
            let common: String? = vals.count == 1 ? vals.first! : nil
            original[f] = .some(common)
            values[f] = common ?? ""
        }
        let arts = tracks.compactMap(\.artwork)
        if !multi || arts.count == tracks.count { cover = tracks.first?.artwork }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            cover = img; coverChanged = true
        }
    }

    private func takeImage(from providers: [NSItemProvider]) -> Bool {
        guard coverSupported, let p = providers.first else { return false }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                if let img = obj as? NSImage { DispatchQueue.main.async { cover = img; coverChanged = true } }
            }
            return true
        }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url, let img = NSImage(contentsOf: url) { DispatchQueue.main.async { cover = img; coverChanged = true } }
        }
        return true
    }

    private func save() async {
        saving = true
        errors = []
        var set: [String: String] = [:], clear: Set<String> = []
        for f in fields {
            let new = (values[f] ?? "").trimmingCharacters(in: .whitespaces)
            let old = (original[f] ?? nil) ?? ""
            // У нескольких треков пустое поле с «Разные» — не трогаем.
            if multi, original[f] == .some(nil), new.isEmpty { continue }
            guard new != old else { continue }
            if new.isEmpty { clear.insert(f.rawValue) } else { set[f.rawValue] = new }
        }
        let coverFile = coverChanged ? cover.flatMap(CoverImage.jpegFile) : nil
        for t in tracks {
            if let e = await t.saveTags(set: set, clear: clear, cover: coverFile) {
                errors.append("\(t.url.lastPathComponent): \(e)")
            }
        }
        saving = false
        if errors.isEmpty { dismiss() }
    }
}
