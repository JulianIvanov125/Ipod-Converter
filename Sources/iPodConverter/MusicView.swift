import SwiftUI

private let ink = Theme.ink
private let rowFill = Theme.card
private let hairline = Theme.hairline

/// Ширины колонок списка треков.
private enum Col {
    static let type: CGFloat = 120
    static let bitrate: CGFloat = 78
    static let size: CGFloat = 70
    static let target: CGFloat = 118
    static let rating: CGFloat = 74
    static let status: CGFloat = 112
}

struct MusicSection: View {
    @Bindable var store: Store
    let isTargeted: Bool

    var body: some View {
        if store.tracks.isEmpty {
            DropPlaceholder(isTargeted: isTargeted, title: L.dropTracks, subtitle: L.orClickTracks) {
                store.openPanel()
            }
        } else {
            VStack(spacing: 0) {
                toolbar
                columnHeader
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.tracks) { t in
                            TrackRow(
                                track: t,
                                model: store.model,
                                showCheckbox: true,
                                onRemove: { store.removeTrack(t) },
                                onCheck: { store.setChecked(t, $0) },
                                onPreview: { store.playTrack(t, converted: $0) },
                                onRate: { store.setRating(t, stars: $0) }
                            )
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
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $store.musicScope) {
                Text(L.scopeAll(store.tracks.count)).tag(Store.MusicScope.all)
                Text(L.scopeSelected(store.tracks.filter(\.isChecked).count)).tag(Store.MusicScope.selected)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(store.isMusicBusy)

            let allChecked = store.tracks.allSatisfy(\.isChecked)
            Button(allChecked ? L.uncheckAll : L.checkAll) { store.setAllChecked(!allChecked) }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .disabled(store.isMusicBusy)

            if store.musicScope == .all && store.tracks.contains(where: \.isChecked) {
                Label(L.checkedIgnored, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
            MetaToggle()
            FormatPicker().disabled(store.isMusicBusy)
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
            Text(L.colTrack).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 50)
            Text(L.colType).frame(width: Col.type, alignment: .leading)
            Text(L.colBitrate).frame(width: Col.bitrate, alignment: .trailing)
            Text(L.size).frame(width: Col.size, alignment: .trailing)
            Text(L.colRating).frame(width: Col.rating, alignment: .leading)
            Text(L.colFor(store.model.title)).frame(width: Col.target, alignment: .leading).lineLimit(1)
            Color.clear.frame(width: Col.status, height: 1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 24 + 12)
        .padding(.bottom, 4)
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

            if let status = store.musicBatchStatus {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(status.ok ? Color.green : Color.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()

            Toggle(isOn: $store.addToMusic) {
                Text(L.toMusic(store.model.playlistName))
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L.toMusicHelp)

            if store.isMusicBusy {
                Button(role: .destructive) {
                    store.cancelMusic()
                } label: {
                    Label(L.stop, systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    store.convertTracks()
                } label: {
                    Label(L.convertN(store.convertibleTracks.count), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.convertibleTracks.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
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

struct TrackRow: View {
    @Bindable var track: TrackItem
    let model: IPodModel
    let showCheckbox: Bool
    let onRemove: () -> Void
    let onCheck: (Bool) -> Void
    let onPreview: (Bool) -> Void
    let onRate: (Int) -> Void
    @State private var confirmRemove = false
    @State private var hoverArt = false
    @State private var hoverStar = 0

    private var isPlayingHere: Bool {
        PlayerController.shared.current.map { $0.id.hasSuffix(track.id.uuidString) } ?? false
    }

    var body: some View {
        HStack(spacing: 10) {
            if showCheckbox {
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
                }
                Text(track.info?.artist ?? L.unknownArtist)
                    .font(.system(size: 12))
                    .foregroundStyle(track.info?.artist == nil ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(track.url.path)

            if let info = track.info {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.typeLabel)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.tint(0.07)))
                    Text(info.detailLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: Col.type, alignment: .leading)

                Text(info.bitrate.map { "\($0 / 1000) \(L.kbps)" } ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: Col.bitrate, alignment: .trailing)

                Text(Fmt.bytes(info.fileSize))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: Col.size, alignment: .trailing)

                stars.frame(width: Col.rating, alignment: .leading)

                targetBadge(AudioRules.plan(for: info, model: model), info: info)
                    .frame(width: Col.target, alignment: .leading)
            } else {
                Spacer().frame(width: Col.type + Col.bitrate + Col.size + Col.rating + Col.target + 40)
            }

            status.frame(width: Col.status, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hairline))
        .foregroundStyle(ink)
        .alert(L.areYouSure, isPresented: $confirmRemove) {
            Button(L.stopAndRemove, role: .destructive, action: onRemove)
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.trackRemoveWhileConverting)
        }
    }

    @ViewBuilder
    private func targetBadge(_ plan: AudioPlan, info: AudioInfo) -> some View {
        let est = Fmt.bytes(AudioRules.estimatedBytes(plan, info: info))
        switch plan {
        case .compatible:
            Label(L.compatibleBadge, systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                .help(L.compatibleHelp)
        case .alac(let rate):
            VStack(alignment: .leading, spacing: 1) {
                Text("→ ALAC 16/\(Self.khz(rate))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("≈ \(est)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .help(L.alacHelp)
        case .mp3(let rate, let kbps):
            VStack(alignment: .leading, spacing: 1) {
                Text("→ MP3 \(kbps) · \(Self.khz(rate))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("≈ \(est)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .aac(let rate, let kbps):
            VStack(alignment: .leading, spacing: 1) {
                Text("→ AAC \(kbps) · \(Self.khz(rate))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("≈ \(est)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .help(L.aacHelp)
        }
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
                .help(L.metaFound(track.fetched?.summary ?? ""))
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
            }
            // Папка: до конвертации — оригинал, после — готовый файл.
            Button(action: track.revealInFinder) {
                Image(systemName: track.isDone ? "folder.fill" : "folder")
                    .foregroundStyle(track.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(track.isDone ? L.showResultInFinder : L.showOriginalInFinder)
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
        .font(.system(size: 13))
    }
}
