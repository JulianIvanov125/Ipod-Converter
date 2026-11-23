import SwiftUI

private let ink = Theme.ink
private let rowFill = Theme.card
private let hairline = Theme.hairline

/// Ширины колонок списка треков.
private enum Col {
    static let type: CGFloat = 250
    static let bitrate: CGFloat = 78
    static let size: CGFloat = 70
    static let rating: CGFloat = 74
    static let status: CGFloat = 112
}

struct MusicSection: View {
    @Bindable var store: Store
    let isTargeted: Bool
    @State private var confirmTrash = false

    private var emptyText: String {
        switch store.musicScope {
        case .duplicates: store.trackSearch.isEmpty ? L.dupNone : L.searchNothing
        case .selected where !store.tracks.contains(where: \.isChecked): L.nothingChecked
        default: L.searchNothing
        }
    }

    /// Группы дублей: сверху файл, который останется, под ним лишние копии.
    @ViewBuilder
    private var duplicateList: some View {
        let q = store.trackSearch.trimmingCharacters(in: .whitespaces)
        let groups = q.isEmpty ? store.duplicateGroups : store.duplicateGroups.filter { $0.all.contains { $0.matches(q) } }
        ForEach(groups) { g in
            VStack(spacing: 4) {
                ForEach(g.all) { t in
                    let keeper = t.id == g.keeper.id
                    TrackRow(
                        track: t,
                        store: store,
                        model: store.model,
                        showCheckbox: true,
                        onRemove: { store.trashDuplicates([t]) },
                        onCheck: { store.setDuplicateSelected(t, $0) },
                        onPreview: { store.playTrack(t, converted: $0) },
                        onRate: { store.setRating(t, stars: $0) },
                        duplicate: DuplicateRole(isKeeper: keeper, isSelected: store.dupSelection.contains(t.id),
                                                 onKeep: { store.keepDuplicate(t) })
                    )
                }
            }
            .padding(.bottom, 8)
        }
    }

    var body: some View {
        if store.tracks.isEmpty {
            DropPlaceholder(isTargeted: isTargeted, title: L.dropTracks, subtitle: L.orClickTracks) {
                store.openPanel()
            }
        } else {
            // Список считаем один раз за отрисовку: на тысячах треков каждый пересчёт заметен.
            let visible = store.visibleTracks
            VStack(spacing: 0) {
                toolbar(visible)
                columnHeader
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if visible.isEmpty {
                            Text(emptyText)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.top, 30)
                        }
                        if store.musicScope == .duplicates {
                            duplicateList
                        } else {
                        ForEach(visible) { t in
                            TrackRow(
                                track: t,
                                store: store,
                                model: store.model,
                                showCheckbox: true,
                                onRemove: { store.removeTrack(t) },
                                onCheck: { store.setChecked(t, $0) },
                                onPreview: { store.playTrack(t, converted: $0) },
                                onRate: { store.setRating(t, stars: $0) }
                            )
                        }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
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
            .sheet(isPresented: Binding(get: { !store.tagEditTracks.isEmpty }, set: { if !$0 { store.tagEditTracks = [] } })) {
                TagEditorView(tracks: store.tagEditTracks)
            }
        }
    }

    private func toolbar(_ visible: [TrackItem]) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: $store.musicScope) {
                Text(L.scopeAll(store.tracks.count)).tag(Store.MusicScope.all)
                Text(L.scopeSelected(store.tracks.reduce(0) { $0 + ($1.isChecked ? 1 : 0) })).tag(Store.MusicScope.selected)
                Text(L.scopeDuplicates(store.duplicateExtras.count)).tag(Store.MusicScope.duplicates)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(store.isMusicBusy)

            if store.musicScope == .duplicates {
                let extraIDs = Set(store.duplicateExtras.map(\.id))
                let extras = visible.filter { extraIDs.contains($0.id) }
                let allOn = !extras.isEmpty && extras.allSatisfy { store.dupSelection.contains($0.id) }
                Button(allOn ? L.uncheckAll : L.checkAll) { store.setAllDuplicatesSelected(!allOn) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .disabled(extras.isEmpty)
                    .help(L.dupSelectAllHelp)
            } else {
                let allChecked = !visible.isEmpty && visible.allSatisfy(\.isChecked)
                Button(allChecked ? L.uncheckAll : L.checkAll) { store.setAllChecked(!allChecked) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .disabled(store.isMusicBusy)
            }

            Spacer()
            if let p = store.coverRepairProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 80)
                Text(L.coverRepairRunning(p.done, p.total)).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Button {
                    store.repairCovers()
                } label: {
                    Label(L.coverRepairButton, systemImage: "photo.on.rectangle.angled").font(.system(size: 12))
                }
                .buttonStyle(.link)
                .disabled(store.isMusicBusy || store.tracks.isEmpty)
                .help(L.coverRepairHelp)
            }
            MetaToggle()
            Button(L.clearList) { store.clearTracks() }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .disabled(store.isMusicBusy)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 1)
            HStack(spacing: 10) {
                sortHeader(L.colTrack, .title)
                SearchBox(text: $store.trackSearch)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 50)
            // «Тип → для iPod»: что сейчас и что получится после конвертации.
            HStack(spacing: 4) {
                sortHeader(L.colType, .type)
                Text("→").foregroundStyle(.tertiary)
                sortHeader(L.colFor(store.model.title), .target)
            }
            .frame(width: Col.type, alignment: .leading)
            sortHeader(L.colBitrate, .bitrate).frame(width: Col.bitrate, alignment: .trailing)
            sortHeader(L.size, .size).frame(width: Col.size, alignment: .trailing)
            sortHeader(L.colRating, .rating).frame(width: Col.rating, alignment: .leading)
            Color.clear.frame(width: Col.status, height: 1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 24 + 12)
        .padding(.bottom, 4)
    }

    /// Заголовок колонки: клик — по возрастанию, ещё клик — по убыванию, третий — как было.
    private func sortHeader(_ title: String, _ key: TrackSortKey) -> some View {
        let active = store.trackSort == key
        return Button {
            store.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                if active {
                    Image(systemName: store.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? (store.sortAscending ? L.sortDescHelp : L.sortResetHelp) : L.sortAscHelp)
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

            MusicOutputButton(store: store)

            if let status = store.musicStatusForTab {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(status.ok ? Color.green : Color.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let report = store.musicReportForTab {
                CopyReportButton(text: report)
                ReportProblemButton(report: report)
            }

            Spacer()

            IPodStorageBadge(store: store)
            SyncGuideButton(store: store)
            Toggle(isOn: $store.addToMusic) {
                Text(L.toMusicLibrary)
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L.toMusicLibraryHelp)
            if store.addToMusic {
                // Режим плейлиста: треки сразу собираются в плейлист — на iPod он придёт готовым.
                Toggle(isOn: $store.musicToPlaylist) {
                    Text(L.intoPlaylist).font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help(L.intoPlaylistHelp)
                if store.musicToPlaylist {
                    TextField(L.playlistNamePlaceholder, text: $store.musicPlaylist)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 160)
                        .disabled(store.isMusicBusy)
                    PlaylistCoverButton(store: store)
                }
            }

            if let p = store.musicBatchProgress {
                BatchProgress(done: p.done, total: p.total, fraction: p.fraction)
            }
            if store.musicScope == .duplicates {
                let sel = store.selectedDuplicates
                Button(role: .destructive) {
                    confirmTrash = true
                } label: {
                    Label(L.dupTrashN(sel.count), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(sel.isEmpty)
                .alert(L.dupTrashConfirmTitle(sel.count), isPresented: $confirmTrash) {
                    Button(L.dupTrashN(sel.count), role: .destructive) { store.trashDuplicates(sel) }
                    Button(L.cancel, role: .cancel) {}
                } message: {
                    Text(L.dupTrashConfirmText)
                }
            } else if store.isMusicBusy {
                Button(role: .destructive) {
                    store.cancelMusic()
                } label: {
                    Label(L.stop, systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                let convertible = store.convertibleTracks
                Button {
                    store.convertTracks()
                } label: {
                    Label(store.hasCheckedTracks ? L.convertSelectedN(convertible.count) : L.convertN(convertible.count),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(convertible.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .clearGlass(in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

/// Поле поиска рядом с колонкой «Трек».
struct SearchBox: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10))
            TextField(L.searchPlaceholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .textCase(nil)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 190, height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.tint(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.tint(text.isEmpty ? 0.08 : 0.25)))
        .foregroundStyle(.secondary)
        .help(L.searchHelp)
    }
}

/// Дополнять пустые теги и обложки из Apple Music.
struct MetaToggle: View {
    @Bindable private var fetcher = MetadataFetcher.shared

    var body: some View {
        Toggle(isOn: $fetcher.enabled) {
            Label(L.metaToggle, systemImage: "sparkles").font(.system(size: 12))
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .help(L.metaHelp)
    }
}

/// «⚙︎ Выход» для музыки — как у видео: формат, битрейт, частота.
struct MusicOutputButton: View {
    @Bindable var store: Store
    @Bindable private var out = AudioOutputSettings.shared
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(out.isCustom ? L.outMusicSummary(out) : L.outPreset(store.model.title), systemImage: "gearshape")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(out.isCustom ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(store.isMusicBusy)
        .help(L.formatHelp)
        .popover(isPresented: $open, arrowEdge: .top) {
            MusicOutputView(store: store)
        }
    }
}

struct MusicOutputView: View {
    @Bindable var store: Store
    @Bindable private var out = AudioOutputSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.outMusicTitle).font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L.formatLabel).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $out.choice) {
                        ForEach(AudioFormatChoice.allCases) { c in
                            Text(c == .auto ? L.outAutoPreset(store.model.title) : c.title).tag(c)
                        }
                    }
                }
                GridRow {
                    Text(L.colBitrate).font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: $out.kbps) {
                        ForEach(AudioOutputSettings.bitrates, id: \.self) { k in Text("\(k) \(L.kbps)").tag(k) }
                    }
                    .disabled(!out.choice.usesBitrate)
                }
                GridRow {
                    Text(L.outSampleRate).font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: $out.sampleRate) {
                        ForEach(AudioOutputSettings.sampleRates, id: \.self) { r in
                            Text(r == 0 ? L.outAsPreset : (r == 44100 ? "44.1 \(L.kHz)" : "48 \(L.kHz)")).tag(r)
                        }
                    }
                }
            }
            .labelsHidden()
            Divider()
            Text(L.formatHelp).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L.outMusicKeepsCompatible).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L.outReset) { out.reset() }.disabled(!out.isCustom)
            }
        }
        .padding(16)
        .frame(width: 430)
    }
}

/// «Формат: [Авто ▾] [256 ▾]» — что получится на выходе.
struct FormatPicker: View {
    @Bindable private var out = AudioOutputSettings.shared

    var body: some View {
        HStack(spacing: 6) {
            Text(L.formatLabel).font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: $out.choice) {
                ForEach(AudioFormatChoice.allCases) { c in Text(c.title).tag(c) }
            }
            .labelsHidden()
            .fixedSize()
            if out.choice.usesBitrate {
                Picker("", selection: $out.kbps) {
                    ForEach(AudioOutputSettings.bitrates, id: \.self) { k in Text("\(k) \(L.kbps)").tag(k) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .controlSize(.small)
        .help(L.formatHelp)
    }
}

/// Колонка «Для iPod»: клик — свой формат для этого трека.
struct TrackTargetButton<Label: View>: View {
    @Bindable var track: TrackItem
    let store: Store
    @Binding var open: Bool
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                label()
                Spacer(minLength: 0)
                // Шестерёнка видна всегда — как у видео: здесь меняется формат именно этого трека.
                Image(systemName: track.formatOverride != nil ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(track.formatOverride != nil || hover ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.tint(0.06) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(track.isActive)
        .help(L.trackOutToggle)
        .popover(isPresented: $open, arrowEdge: .bottom) { TrackFormatView(track: track, store: store) }
    }
}

struct TrackRow: View {
    @Bindable var track: TrackItem
    var store: Store
    let model: IPodModel
    let showCheckbox: Bool
    let onRemove: () -> Void
    let onCheck: (Bool) -> Void
    let onPreview: (Bool) -> Void
    let onRate: (Int) -> Void
    /// В режиме «Дубликаты»: этот файл остаётся или это лишняя копия.
    var duplicate: DuplicateRole? = nil
    @State private var confirmRemove = false
    @State private var showFormat = false
    @State private var hoverArt = false
    @State private var hoverStar = 0
    @State private var hoverPencil = false

    private var isPlayingHere: Bool {
        PlayerController.shared.current.map { $0.id.hasSuffix(track.id.uuidString) } ?? false
    }

    var body: some View {
        HStack(spacing: 10) {
            if let d = duplicate {
                if d.isKeeper {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .frame(width: 18)
                        .help(L.dupKeeperHelp)
                } else {
                    Toggle("", isOn: Binding(get: { d.isSelected }, set: { onCheck($0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .frame(width: 18)
                }
            } else if showCheckbox {
                Toggle("", isOn: Binding(get: { track.isChecked }, set: { onCheck($0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.tint(0.06))
                if let art = track.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .overlay {
                if track.info != nil && (hoverArt || isPlayingHere) {
                    ZStack {
                        Color.black.opacity(0.45)
                        Image(systemName: isPlayingHere ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hoverArt = $0 }
            .onTapGesture { if track.info != nil { onPreview(false) } }
            .help(L.previewOriginal)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    metaBadge
                    // Карандаш — правка тегов и обложки (то же, что двойной клик и пункт меню).
                    if track.info != nil {
                        Button { store.editTags(track) } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(hoverPencil ? Color.accentColor : Color.secondary)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Theme.tint(hoverPencil ? 0.08 : 0)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hoverPencil = $0 }
                        .disabled(track.isActive)
                        .help(L.tagEditMenu)
                    }
                    if let d = duplicate {
                        Text(d.isKeeper ? L.dupKeeper : L.dupCopy)
                            .font(.system(size: 9, weight: .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(d.isKeeper ? Color.green : Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill((d.isKeeper ? Color.green : Color.orange).opacity(0.12)))
                    }
                }
                if duplicate != nil {
                    // У копий одинаковые артист и название — различаются местом на диске.
                    Text((track.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath + "/" + track.url.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                Text(track.info?.artist ?? L.unknownArtist)
                    .font(.system(size: 12))
                    .foregroundStyle(track.info?.artist == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if track.info != nil && !track.isActive { store.editTags(track) } }
            .help(track.url.path + "\n" + L.tagEditHint)

            if let info = track.info {
                // Тип файла сейчас → формат после конвертации, ⚙︎ — формат именно этого трека.
                TrackTargetButton(track: track, store: store, open: $showFormat) {
                    typeTransition(track.plan(for: model) ?? .compatible, info: info)
                }
                .frame(width: Col.type, alignment: .leading)

                Text(info.bitrate.map { "\($0 / 1000) \(L.kbps)" } ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: Col.bitrate, alignment: .trailing)

                Text(Fmt.bytes(info.fileSize))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: Col.size, alignment: .trailing)

                stars.frame(width: Col.rating, alignment: .leading)

            } else {
                Spacer().frame(width: Col.type + Col.bitrate + Col.size + Col.rating + 30)
            }

            status.frame(width: Col.status, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassCard(RoundedRectangle(cornerRadius: 10), solid: rowFill)
        .foregroundStyle(ink)
        .contextMenu {
            Button { store.editTags(track) } label: {
                Label(track.isChecked && store.tracks.filter(\.isChecked).count > 1 ? L.tagEditMenuN(store.tracks.filter(\.isChecked).count) : L.tagEditMenu,
                      systemImage: "pencil")
            }
            .disabled(track.info == nil || track.isActive)
            Button { showFormat = true } label: { Label(L.trackFormatMenu, systemImage: "gearshape") }
                .disabled(track.info == nil || track.isActive)
            if track.formatOverride != nil {
                Button { track.formatOverride = nil } label: { Label(L.sameAsAll, systemImage: "arrow.uturn.backward") }
            }
            Divider()
            Button(action: track.revealInFinder) { Label(track.isDone ? L.showResultInFinder : L.showOriginalInFinder, systemImage: "folder") }
            if let d = duplicate, !d.isKeeper {
                Divider()
                Button(action: d.onKeep) { Label(L.dupKeepThis, systemImage: "checkmark.seal") }
                Button(role: .destructive, action: onRemove) { Label(L.dupTrashOne, systemImage: "trash") }
            }
        }
        .alert(L.areYouSure, isPresented: $confirmRemove) {
            Button(L.stopAndRemove, role: .destructive, action: onRemove)
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.trackRemoveWhileConverting)
        }
    }

    /// «MP3 → AAC 256» и ниже «44.1 кГц → ≈ 8 МБ»; если файл и так подходит — «MP3 ✓ как есть».
    @ViewBuilder
    private func typeTransition(_ plan: AudioPlan, info: AudioInfo) -> some View {
        let est = Fmt.bytes(AudioRules.estimatedBytes(plan, info: info))
        let target: (name: String, detail: String, help: String)? = {
            switch plan {
            case .compatible: return nil
            case .alac(let rate): return ("ALAC", "16/\(Self.khz(rate))", L.alacHelp)
            case .mp3(let rate, let kbps): return ("MP3 \(kbps)", Self.khz(rate), L.trackOutToggle)
            case .aac(let rate, let kbps): return ("AAC \(kbps)", Self.khz(rate), L.aacHelp)
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(info.typeLabel)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.tint(0.07)))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                if let target {
                    Text(target.name)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.12)))
                } else {
                    Label(L.compatibleBadge, systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            HStack(spacing: 4) {
                Text(info.detailLabel)
                if let target {
                    Text("→").foregroundStyle(.tertiary)
                    Text("\(target.detail) · ≈ \(est)")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .help(target?.help ?? L.compatibleHelp)
    }

    /// Статус поиска тегов: идёт поиск / дополнено из Apple Music / не нашлось.
    @ViewBuilder
    private var metaBadge: some View {
        switch track.metaStatus {
        case .searching:
            ProgressView().controlSize(.mini).help(L.metaSearching)
        case .found:
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .help(L.metaFound(track.fetched?.summary ?? "") + "\n"
                      + (track.tagsWritten ? L.metaWrittenToFile : track.tagWriteError.map(L.metaNotWritten) ?? ""))
        case .notFound:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(L.metaNotFound)
        case .idle:
            EmptyView()
        }
    }

    /// Пять звёзд: клик ставит оценку, повторный клик по той же звезде снимает.
    private var stars: some View {
        let current = track.rating / 20
        return HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                let lit = hoverStar > 0 ? i <= hoverStar : i <= current
                Image(systemName: lit ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(lit ? Color.orange : Theme.tint(0.22))
                    .frame(width: 13, height: 16)
                    .contentShape(Rectangle())
                    .onHover { inside in hoverStar = inside ? i : (hoverStar == i ? 0 : hoverStar) }
                    .onTapGesture { onRate(i) }
            }
        }
        .help(track.musicPersistentID == nil ? L.ratingHelp : L.ratingSyncedHelp)
    }

    private static func khz(_ rate: Int) -> String {
        rate == 44100 ? "44.1" : "\(rate / 1000)"
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            switch track.state {
            case .loading:
                ProgressView().controlSize(.small)
            case .ready:
                EmptyView()
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary).help(L.queued)
            case .converting(let p):
                ProgressView(value: p)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("\(Int(p * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            case .done, .kept:
                if let e = track.musicError {
                    // Сконвертирован, но в «Музыку» не попал.
                    Image(systemName: "music.note")
                        .foregroundStyle(.orange)
                        .help(L.notInMusic(e))
                    CopyReportButton(text: SupportReport.single(model: model, kind: "music", file: track.url, stage: "add to Music", error: e), compact: true)
                }
                Button { onPreview(true) } label: {
                    Image(systemName: "play.circle.fill").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(L.listenResult)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(msg)
                CopyReportButton(text: SupportReport.single(model: model, kind: "music", file: track.url, stage: "convert", error: msg), compact: true)
            }
            // Папка: до конвертации — оригинал, после — готовый файл.
            Button(action: track.revealInFinder) {
                Image(systemName: track.isDone ? "folder.fill" : "folder")
                    .foregroundStyle(track.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(track.isDone ? L.showResultInFinder : L.showOriginalInFinder)
            if let d = duplicate {
                if d.isKeeper {
                    Color.clear.frame(width: 20, height: 20)
                } else {
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.red.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(track.isActive)
                    .help(L.dupTrashOne)
                }
            } else {
            Button {
                if track.isConverting { confirmRemove = true } else { onRemove() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.tint(0.05)))
            }
            .buttonStyle(.plain)
            .help(L.removeFromList)
            }
        }
        .font(.system(size: 13))
    }
}

/// Роль строки в режиме «Дубликаты».
struct DuplicateRole {
    let isKeeper: Bool
    let isSelected: Bool
    let onKeep: () -> Void
}
