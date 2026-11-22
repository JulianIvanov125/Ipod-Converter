import SwiftUI

private let ink = Theme.ink
private let cardFill = Theme.card
private let hairline = Theme.hairline

struct ContentView: View {
    @Bindable var store: Store
    @State private var isTargeted = false
    @State private var showCatalog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.section == .music {
                MusicSection(store: store, isTargeted: isTargeted)
            } else if store.items.isEmpty {
                DropPlaceholder(isTargeted: isTargeted, title: L.dropHere, subtitle: L.orClick) { store.openPanel() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(store.items) { item in
                            ItemCard(
                                item: item,
                                model: store.model,
                                settings: store.currentSettings,
                                onConvert: { store.convert(item) },
                                onRemove: { store.remove(item) },
                                onPreview: { store.playVideo(item, converted: $0) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .background(Color.accentColor.opacity(0.04))
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                footer
            }
            // Музыка играет — полоса плеера на всю ширину внизу окна (как в Apple Music).
            MusicPlayerBar(controller: PlayerController.shared)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: PlayerController.shared.current?.isVideo)
        .overlay(alignment: .bottomTrailing) {
            MiniPlayer(controller: PlayerController.shared)
                .padding(.trailing, 20)
                .padding(.bottom, 72)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: PlayerController.shared.current?.id)
        }
        .overlay {
            // Полный экран плеера — поверх всего окна.
            if PlayerController.shared.isFullscreen {
                FullPlayerView(controller: PlayerController.shared)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: PlayerController.shared.isFullscreen)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(ink)
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Picker("", selection: $store.section) {
                Label(L.sectionMusic, systemImage: "music.note").tag(Store.Section.music)
                Label(L.sectionVideos, systemImage: "film").tag(Store.Section.videos)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 6)

            Text(L.whichIPod)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                IPodTabs(store: store)

                Button {
                    showCatalog.toggle()
                } label: {
                    Text("List iPods picks")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ink.opacity(showCatalog ? 1 : 0.75))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.tint(showCatalog ? 0.07 : 0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Theme.tint(0.12))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(L.catalogHelp)
                .popover(isPresented: $showCatalog, arrowEdge: .bottom) {
                    CatalogView(store: store)
                }
            }

            if store.section == .videos && store.model.supportsMax {
                Picker("", selection: $store.maxQuality) {
                    Text("\(L.standard) · 320×240").tag(false)
                    Text("\(L.maximum) · 640×480").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(store.isBusy)
                .help(L.maxHelp(String(format: "%.1f", Double(store.model.settings(max: true).maxrateKbps) / 1000)))
            }
        }
        .padding(.top, 34)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 12) {
                AppearanceMenu()
                LanguageMenu()
            }
            .padding(.top, 10)
            .padding(.trailing, 16)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                store.openPanel()
            } label: {
                Label(L.add, systemImage: "plus")
            }
            .buttonStyle(.bordered)

            OutputFolderControl(store: store)

            Spacer()

            Toggle(isOn: $store.addToMusic) {
                Text(L.toLibrary(store.model.playlistName))
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L.toLibraryHelp)

            if store.items.filter({ $0.state == .ready }).count > 1 {
                Button {
                    store.convertAll()
                } label: {
                    Label(L.convertAll, systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
    }
}

// MARK: - Папка для готовых файлов

struct OutputFolderControl: View {
    @Bindable var store: Store

    /// «~/…/Папка» с обрезкой середины, чтобы кнопка «Изменить…» стояла сразу за путём.
    static func shortPath(_ url: URL, max: Int = 48) -> String {
        let p = (url.path as NSString).abbreviatingWithTildeInPath
        guard p.count > max else { return p }
        let keep = max - 1
        return String(p.prefix(keep / 2)) + "…" + String(p.suffix(keep - keep / 2))
    }

    var body: some View {
        let dest = store.currentDestination
        // Для музыки проверяем базовую папку: подпапка iPod создаётся при конвертации.
        // Подпапки создаются при первой конвертации; предупреждаем, только если пропал сам корень (например, отключён диск).
        let missing = !FileManager.default.fileExists(atPath: store.rootFolder.path)
        HStack(spacing: 8) {
            Button {
                if store.section == .music { store.openMusicFolder() } else { store.openOutputFolder() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: missing ? "folder.badge.questionmark" : "folder")
                    Text(Self.shortPath(dest))
                        .lineLimit(1)
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(missing ? Color.orange : Color.secondary)
            .fixedSize()
            .help("\(L.saveTo): \(dest.path)" + (missing ? "\n" + L.folderMissing : "") + "\n" + L.openOutputFolder)

            Button(L.changeFolder) { store.chooseOutputFolder() }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .disabled(store.isBusy)

            if !store.isDefaultFolder {
                Button {
                    store.resetOutputFolder()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.isBusy)
                .help(L.resetFolder)
            }
        }
    }
}

// MARK: - Вкладки iPod с крестиком

struct IPodTabs: View {
    @Bindable var store: Store
    @State private var pendingRemoval: IPodModel?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.favoriteModels) { m in
                IPodTab(
                    title: m.title,
                    selected: store.model == m,
                    canSelect: !store.isBusy,
                    canRemove: store.favoriteModels.count > 1,
                    onSelect: { store.model = m },
                    onRemove: {
                        if store.isConverting(for: m) { pendingRemoval = m } else { store.removeTab(m) }
                    }
                )
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tint(0.055)))
        .alert(
            L.areYouSure,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { m in
            Button(L.stopAndRemoveTab, role: .destructive) { store.removeTab(m) }
            Button(L.cancel, role: .cancel) {}
        } message: { m in
            Text(L.removeTabWhileConverting(m.title))
        }
    }
}

private struct IPodTab: View {
    let title: String
    let selected: Bool
    let canSelect: Bool
    let canRemove: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hover = false
    @State private var hoverX = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Theme.tint(hoverX ? 0.12 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary.opacity(selected || hover ? 1 : 0.55))
                .onHover { hoverX = $0 }
                .help(L.removeTab)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, canRemove ? 6 : 12)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.raised : Theme.tint(hover && canSelect ? 0.04 : 0))
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1.5, y: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { if canSelect { onSelect() } }
        .onHover { hover = $0 }
        .opacity(!canSelect && !selected ? 0.55 : 1)
        .help(!canSelect && !selected ? L.waitForConversion : "")
    }
}

// MARK: - Выбор языка

struct LanguageMenu: View {
    @Bindable private var lang = LanguageSettings.shared

    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { l in
                Button {
                    lang.choice = l
                } label: {
                    let name = l == .system ? "\(l.nativeName) · \(AppLanguage.fromSystem().nativeName)" : l.nativeName
                    if lang.choice == l { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(lang.current.rawValue.uppercased())
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(L.language)
    }
}

// MARK: - Все iPod со звёздочками

struct CatalogView: View {
    @Bindable var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.allIPods)
                    .font(.system(size: 14, weight: .semibold))
                Text(L.starredAppear)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            VStack(spacing: 0) {
                ForEach(IPodModel.allCases) { m in
                    row(m)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 330)
        .background(Theme.raised)
        .foregroundStyle(ink)
    }

    private func row(_ m: IPodModel) -> some View {
        let fav = store.isFavorite(m)
        let isLast = fav && store.favoriteModels.count == 1
        return Button {
            store.toggleFavorite(m)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(fav ? Color.yellow : Theme.tint(0.25))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title)
                        .font(.system(size: 13, weight: fav ? .semibold : .regular))
                    Text("\(m.details) · \(m.settings(max: false).w)×\(m.settings(max: false).h)" + (m.supportsMax ? " \(L.upTo640)" : "") + " · H.264 \(m.settings(max: false).profileName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLast)
        .help(isLast ? L.keepOne : "")
    }
}

// MARK: - Пустой экран с плюсом

struct DropPlaceholder: View {
    let isTargeted: Bool
    let title: String
    let subtitle: String
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(isTargeted ? 0.18 : (hover ? 0.12 : 0.08)))
                    .frame(width: 128, height: 128)
                Image(systemName: "plus")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .scaleEffect(isTargeted ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTargeted)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Theme.tint(0.12),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

// MARK: - Карточка видео

struct ItemCard: View {
    let item: VideoItem
    let model: IPodModel
    let settings: EncodeSettings
    let onConvert: () -> Void
    let onRemove: () -> Void
    let onPreview: (Bool) -> Void
    @State private var confirmRemove = false
    @State private var hoverThumb = false

    private var isPlayingHere: Bool {
        PlayerController.shared.current.map { $0.id.hasSuffix(item.id.uuidString) } ?? false
    }

    private var usesFinished: Bool {
        if case .done = item.state { return true }
        return item.isConverting
    }

    private var target: IPodModel {
        usesFinished ? (item.usedModel ?? model) : model
    }

    private var targetSettings: EncodeSettings {
        usesFinished ? (item.usedSettings ?? settings) : settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleRow
            if item.meta != nil {
                MetaEditor(item: item).disabled(item.isConverting)
            }
            if let info = item.info {
                comparison(info)
            } else if item.state == .loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.readingInfo).foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
            }
            controls
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hairline))
    }

    private var titleRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                if let img = item.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film").foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 112, height: 63)
            .overlay {
                if item.info != nil {
                    Image(systemName: isPlayingHere ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(hoverThumb ? 0.65 : 0.45)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { hoverThumb = $0 }
            .onTapGesture { if item.info != nil { onPreview(false) } }
            .help(L.previewOriginal)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(item.info?.artist ?? L.unknownArtist)
                    .font(.system(size: 13))
                    .foregroundStyle(item.info?.artist == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                Text(item.url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                if item.isConverting { confirmRemove = true } else { onRemove() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.tint(0.05)))
            }
            .buttonStyle(.plain)
            .help(L.removeFromList)
            .alert(L.areYouSure, isPresented: $confirmRemove) {
                Button(L.stopAndRemove, role: .destructive, action: onRemove)
                Button(L.cancel, role: .cancel) {}
            } message: {
                Text(L.removeWhileConverting)
            }
        }
    }

    private func comparison(_ info: MediaInfo) -> some View {
        let ts = targetSettings
        let out = ts.outputSize(for: info)
        let estimate = item.outputBytes ?? ts.estimatedBytes(for: info)
        let sizePrefix = item.outputBytes == nil ? "≈ " : ""
        return HStack(alignment: .center, spacing: 14) {
            SpecColumn(header: L.now, rows: [
                (L.resolution, "\(info.displayWidth)×\(info.displayHeight)"),
                (L.quality, quality(info)),
                (L.size, Fmt.bytes(info.fileSize)),
                (L.duration, Fmt.duration(info.duration)),
            ], highlighted: false)

            Image(systemName: "arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            SpecColumn(header: "\(L.after) · \(target.title)" + (ts.isMax ? " · \(L.maximum)" : ""), rows: [
                (L.resolution, "\(out.w)×\(out.h)"),
                (L.quality, "H.264 \(ts.profileName) · \(Fmt.kbps(ts.videoKbps))"),
                (L.size, sizePrefix + Fmt.bytes(estimate)),
                (L.format, info.hasAudio ? "M4V · AAC \(ts.audioKbps) \(L.kbps) · 48 \(L.kHz)" : "M4V · \(L.noAudio)"),
            ], highlighted: true)
        }
    }

    private func quality(_ info: MediaInfo) -> String {
        var parts = [info.videoCodec]
        if info.fps > 0 { parts.append(Fmt.fps(info.fps)) }
        if let br = info.videoBitrate { parts.append(Fmt.kbps(br / 1000)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            switch item.state {
            case .loading:
                Spacer()
            case .ready:
                Text(L.readyToConvert)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                folderButton(enabled: false)
                playButton
            case .converting(let p):
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                Text("\(Int(p * 100))%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                Button(action: item.cancel) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help(L.stop)
            case .done:
                VStack(alignment: .leading, spacing: 3) {
                    Label(L.convertedFor(target.title), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                    if let music = item.musicStatus {
                        Label(music.text, systemImage: music.ok ? "music.note" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(music.ok ? Color.secondary : Color.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button {
                    onPreview(true)
                } label: {
                    Label(L.watchResult, systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                folderButton(enabled: true)
                playButton
                    .help(L.convertAgain)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                folderButton(enabled: false)
                if item.info != nil { playButton }
            }
        }
    }

    private var playButton: some View {
        Button(action: onConvert) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help(L.convert)
    }

    /// enabled == true — готовый файл, false — оригинал (до конвертации).
    private func folderButton(enabled converted: Bool) -> some View {
        Button(action: item.revealInFinder) {
            Image(systemName: converted ? "folder.fill" : "folder")
                .font(.system(size: 15))
                .foregroundStyle(converted ? Color.accentColor : Color.secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.tint(0.05)))
        }
        .buttonStyle(.plain)
        .help(converted ? L.showResultInFinder : L.showOriginalInFinder)
    }
}

// MARK: - Категория и теги видео

extension VideoCategory {
    var localizedName: String {
        switch self {
        case .musicVideo: L.t("Music video", "Клип", "Кліп", "Кліп")
        case .film: L.t("Film", "Фильм", "Фільм", "Фільм")
        case .serial: L.t("TV series", "Сериал", "Серіал", "Серыял")
        }
    }

    var icon: String {
        switch self {
        case .musicVideo: "music.note.tv"
        case .film: "film"
        case .serial: "tv"
        }
    }
}

struct MetaEditor: View {
    @Bindable var item: VideoItem

    private func bind<T>(_ kp: WritableKeyPath<VideoMeta, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { item.meta?[keyPath: kp] ?? fallback }, set: { item.meta?[keyPath: kp] = $0 })
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: bind(\.category, .film)) {
                ForEach(VideoCategory.allCases) { c in
                    Label(c.localizedName, systemImage: c.icon).tag(c)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(L.categoryHelp)

            switch item.meta?.category ?? .film {
            case .serial:
                text(L.showField, \.show).frame(minWidth: 120)
                number("S", \.season)
                number("E", \.episode)
                text(L.episodeTitleField, \.title)
            case .film:
                text(L.titleField, \.title)
                text(L.yearField, \.year).frame(width: 58)
            case .musicVideo:
                text(L.artistField, \.artist)
                text(L.titleField, \.title)
            }
        }
        .controlSize(.small)
    }

    private func text(_ prompt: String, _ kp: WritableKeyPath<VideoMeta, String>) -> some View {
        TextField(prompt, text: bind(kp, ""), prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .help(prompt)
    }

    private func number(_ label: String, _ kp: WritableKeyPath<VideoMeta, Int>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", value: bind(kp, 1), format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 40)
        }
        .help(label == "S" ? L.seasonField : L.episodeField)
    }
}

struct SpecColumn: View {
    let header: String
    let rows: [(String, String)]
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(row.1)
                        .font(.system(size: 13, weight: i == 0 || i == 2 ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlighted ? Color.accentColor.opacity(0.35) : hairline)
        )
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func kbps(_ k: Int) -> String {
        k >= 1000 ? String(format: "%.1f ", Double(k) / 1000) + L.mbps : "\(k) \(L.kbps)"
    }

    static func fps(_ f: Double) -> String {
        abs(f - f.rounded()) < 0.01 ? "\(Int(f.rounded())) fps" : String(format: "%.2f fps", f)
    }
}
