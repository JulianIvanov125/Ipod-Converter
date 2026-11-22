import AppKit
import SwiftUI

/// Обложка-заглушка для плейлиста, как в Apple Music: цветной фон и крупный текст.
/// «Музыка» не даёт поставить обложку плейлиста скриптом — сохраняем картинку,
/// пользователь перетаскивает её на обложку плейлиста сам.
struct CoverDesign: Equatable {
    enum Background: String, CaseIterable, Identifiable {
        case solid, gradient, glow
        var id: String { rawValue }
        var title: String {
            switch self {
            case .solid: L.t("Solid", "Сплошной", "Суцільний", "Суцэльны")
            case .gradient: L.t("Gradient", "Градиент", "Градієнт", "Градыент")
            case .glow: L.t("Glow", "Свечение", "Сяйво", "Ззянне")
            }
        }
    }
    var title: String
    var subtitle: String = ""
    var top: Color
    var bottom: Color
    var background: Background = .gradient
}

/// Готовые сочетания (в духе стандартных обложек Apple Music).
enum CoverPresets {
    static let all: [(Color, Color)] = [
        (Color(red: 0.98, green: 0.36, blue: 0.47), Color(red: 0.74, green: 0.13, blue: 0.40)),   // малиновый
        (Color(red: 1.00, green: 0.62, blue: 0.27), Color(red: 0.93, green: 0.30, blue: 0.22)),   // закат
        (Color(red: 0.99, green: 0.83, blue: 0.30), Color(red: 0.98, green: 0.55, blue: 0.18)),   // солнце
        (Color(red: 0.36, green: 0.85, blue: 0.62), Color(red: 0.08, green: 0.55, blue: 0.48)),   // мята
        (Color(red: 0.35, green: 0.78, blue: 0.98), Color(red: 0.16, green: 0.40, blue: 0.90)),   // небо
        (Color(red: 0.62, green: 0.47, blue: 0.98), Color(red: 0.32, green: 0.20, blue: 0.75)),   // фиалка
        (Color(red: 0.95, green: 0.50, blue: 0.85), Color(red: 0.48, green: 0.24, blue: 0.86)),   // неон
        (Color(red: 0.32, green: 0.33, blue: 0.38), Color(red: 0.08, green: 0.08, blue: 0.10)),   // графит
    ]
}

/// Сама картинка: используется и в превью, и для сохранения в 1200×1200.
struct CoverArtView: View {
    let design: CoverDesign

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack(alignment: .bottomLeading) {
                background(side)
                // Лёгкий блик сверху — как у обложек Apple Music.
                LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
                VStack(alignment: .leading, spacing: side * 0.02) {
                    Text(design.title.isEmpty ? " " : design.title)
                        .font(.system(size: side * 0.12, weight: .heavy))
                        .lineLimit(3)
                        .minimumScaleFactor(0.4)
                    if !design.subtitle.isEmpty {
                        Text(design.subtitle)
                            .font(.system(size: side * 0.05, weight: .semibold))
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(textColor)
                .shadow(color: .black.opacity(0.18), radius: side * 0.01, y: side * 0.004)
                .padding(side * 0.08)
            }
            .frame(width: side, height: side)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func background(_ side: CGFloat) -> some View {
        switch design.background {
        case .solid:
            design.top
        case .gradient:
            LinearGradient(colors: [design.top, design.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .glow:
            ZStack {
                design.bottom
                RadialGradient(colors: [design.top, design.top.opacity(0)], center: .topTrailing, startRadius: 0, endRadius: side * 0.75)
                    .scaleEffect(1.2)
            }
        }
    }

    /// Белый текст на тёмном фоне, тёмный — на очень светлом.
    private var textColor: Color {
        let c = NSColor(design.top).usingColorSpace(.deviceRGB) ?? .white
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma > 0.82 && design.background == .solid ? Color.black.opacity(0.85) : .white
    }
}

enum CoverRenderer {
    /// PNG 1200×1200.
    @MainActor
    static func png(_ design: CoverDesign) -> Data? {
        let r = ImageRenderer(content: CoverArtView(design: design).frame(width: 1200, height: 1200))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Окно генератора: превью, готовые цвета, цвета из обложек треков, свои цвета, текст.
struct PlaylistCoverMaker: View {
    @Bindable var store: Store
    @State private var design: CoverDesign
    @State private var savedTo: URL?
    @State private var copied = false

    init(store: Store) {
        self.store = store
        let name = store.musicPlaylist.trimmingCharacters(in: .whitespaces)
        let p = CoverPresets.all[0]
        _design = State(initialValue: CoverDesign(title: name.isEmpty ? L.playlistNamePlaceholder : name, top: p.0, bottom: p.1))
    }

    /// Пары цветов из обложек добавленных треков (до 4 разных альбомов).
    private var coverPairs: [(Color, Color)] {
        var seen = Set<String>()
        var out: [(Color, Color)] = []
        for t in store.tracks {
            guard let art = t.artwork else { continue }
            let album = t.info?.album ?? t.url.deletingLastPathComponent().path
            guard seen.insert(album).inserted else { continue }
            let c = CoverPalette.colors(from: art)
            out.append((c.accents[0], c.accents.count > 1 ? c.accents[1] : c.background))
            if out.count == 4 { break }
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            CoverArtView(design: design)
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 10) {
                Text(L.coverMakerTitle).font(.system(size: 14, weight: .semibold))
                TextField(L.coverText, text: $design.title)
                    .textFieldStyle(.roundedBorder)
                TextField(L.coverSubtitle, text: $design.subtitle)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $design.background) {
                    ForEach(CoverDesign.Background.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                swatches(CoverPresets.all)
                let fromCovers = coverPairs
                if !fromCovers.isEmpty {
                    Text(L.coverFromArtwork).font(.system(size: 11)).foregroundStyle(.secondary)
                    swatches(fromCovers)
                }
                HStack(spacing: 12) {
                    ColorPicker(L.coverColor1, selection: $design.top, supportsOpacity: false)
                    ColorPicker(L.coverColor2, selection: $design.bottom, supportsOpacity: false)
                        .disabled(design.background == .solid)
                }
                .font(.system(size: 12))

                Spacer(minLength: 4)
                HStack {
                    Button {
                        if let data = CoverRenderer.png(design) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setData(data, forType: .png)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }
                    } label: { Label(copied ? L.copied : L.copyImage, systemImage: copied ? "checkmark" : "doc.on.doc") }
                    Button { save() } label: { Label(L.saveCover, systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent)
                }
                Text(L.coverHowTo).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 300)
        }
        .padding(18)
    }

    private func swatches(_ pairs: [(Color, Color)]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, p in
                Button {
                    design.top = p.0
                    design.bottom = p.1
                } label: {
                    LinearGradient(colors: [p.0, p.1], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// В «iPod Converter Music/Playlist covers/<название>.png» и показать в Finder.
    private func save() {
        guard let data = CoverRenderer.png(design) else { return }
        let dir = store.musicFolder.appendingPathComponent("Playlist covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let base = design.title.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        var url = dir.appendingPathComponent((base.isEmpty ? "Playlist" : base) + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base.isEmpty ? "Playlist" : base) \(n).png"); n += 1
        }
        guard (try? data.write(to: url)) != nil else { return }
        savedTo = url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Кнопка рядом с названием плейлиста.
struct PlaylistCoverButton: View {
    @Bindable var store: Store
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(open ? Color.accentColor : Color.secondary)
        .help(L.coverMakerHelp)
        .popover(isPresented: $open, arrowEdge: .top) { PlaylistCoverMaker(store: store) }
    }
}
