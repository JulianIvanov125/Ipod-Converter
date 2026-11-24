#if os(macOS)
import SwiftUI

// MARK: - Настройки выхода для одного видео (⚙︎ в карточке «После»)

struct ItemOutputView: View {
    @Bindable var item: VideoItem
    @Bindable var store: Store

    private func bind<T>(_ kp: WritableKeyPath<VideoOverride, T>) -> Binding<T> {
        Binding(get: { (item.outputOverride ?? VideoOverride())[keyPath: kp] },
                set: { var o = item.outputOverride ?? VideoOverride(); o[keyPath: kp] = $0; item.outputOverride = o })
    }

    var body: some View {
        let s = store.settings(for: item)
        let issues = VideoOutputSettings.shared.iPodIssues(for: store.model, s)
        let checked = store.checkedVideos.filter { $0.id != item.id }.count
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { item.outputOverride != nil },
                set: { on in
                    let global = VideoOutputSettings.shared
                    item.outputOverride = on ? (global.enabled ? global.asOverride : VideoOverride()) : nil
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.itemOutToggle).font(.system(size: 13, weight: .semibold))
                    Text(L.itemOutHint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L.outContainer).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: bind(\.container)) {
                        ForEach(VideoContainer.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                    }.pickerStyle(.segmented)
                }
                GridRow {
                    Text(L.outCodec).foregroundStyle(.secondary)
                    Picker("", selection: bind(\.codec)) {
                        ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                GridRow {
                    Text(L.resolution).foregroundStyle(.secondary)
                    Picker("", selection: bind(\.resolution)) {
                        ForEach(OutResolution.allCases) { Text($0.title).tag($0) }
                    }
                }
                GridRow {
                    Text(L.outVideoBitrate).foregroundStyle(.secondary)
                    Picker("", selection: bind(\.videoKbps)) {
                        ForEach(VideoOutputSettings.videoRates, id: \.self) { k in Text(k == 0 ? L.outAsPreset : Fmt.kbps(k)).tag(k) }
                    }
                }
                GridRow {
                    Text(L.outAudio).foregroundStyle(.secondary)
                    HStack {
                        Picker("", selection: bind(\.audioKbps)) {
                            ForEach(VideoOutputSettings.audioRates, id: \.self) { k in Text(k == 0 ? L.outAsPreset : "AAC \(k) \(L.kbps)").tag(k) }
                        }
                        Picker("", selection: bind(\.sampleRate)) {
                            ForEach(VideoOutputSettings.sampleRates, id: \.self) { r in
                                Text(r == 0 ? L.outAsPreset : (r == 44100 ? "44.1 \(L.kHz)" : "48 \(L.kHz)")).tag(r)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .labelsHidden()
            .disabled(item.outputOverride == nil)
            .opacity(item.outputOverride == nil ? 0.5 : 1)

            Divider()
            Text("\(s.container.rawValue.uppercased()) · \(s.codecLabel) · \(s.w >= 100_000 ? L.outOriginalSize : "\(s.w)×\(s.h)") · \(Fmt.kbps(s.videoKbps)) · AAC \(s.audioKbps) \(L.kbps)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L.outWarning(store.model.title), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    ForEach(issues, id: \.self) { Text("• " + $0).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button(L.applyToChecked(checked)) {
                    for v in store.checkedVideos where !v.isConverting { v.outputOverride = item.outputOverride }
                }
                .disabled(checked == 0)
                Spacer()
                Button(L.sameAsAll) { item.outputOverride = nil }.disabled(item.outputOverride == nil)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

// MARK: - Формат для одного трека (колонка «Для iPod»)

struct TrackFormatView: View {
    @Bindable var track: TrackItem
    @Bindable var store: Store

    private func bind<T>(_ kp: WritableKeyPath<TrackFormatOverride, T>) -> Binding<T> {
        Binding(get: { (track.formatOverride ?? TrackFormatOverride.fromGlobal())[keyPath: kp] },
                set: { var o = track.formatOverride ?? TrackFormatOverride.fromGlobal(); o[keyPath: kp] = $0; track.formatOverride = o })
    }

    var body: some View {
        let checked = store.tracks.filter { $0.isChecked && $0.id != track.id }.count
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { track.formatOverride != nil },
                set: { track.formatOverride = $0 ? TrackFormatOverride.fromGlobal() : nil })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.trackOutToggle).font(.system(size: 13, weight: .semibold))
                    Text(L.itemOutHint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L.formatLabel).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: bind(\.choice)) {
                        ForEach(AudioFormatChoice.allCases) { c in Text(c == .auto ? L.outAutoPreset(store.model.title) : c.title).tag(c) }
                    }
                }
                GridRow {
                    Text(L.colBitrate).foregroundStyle(.secondary)
                    Picker("", selection: bind(\.kbps)) {
                        ForEach(AudioOutputSettings.bitrates, id: \.self) { k in Text("\(k) \(L.kbps)").tag(k) }
                    }
                    .disabled(!(track.formatOverride?.choice.usesBitrate ?? false))
                }
                GridRow {
                    Text(L.outSampleRate).foregroundStyle(.secondary)
                    Picker("", selection: bind(\.sampleRate)) {
                        ForEach(AudioOutputSettings.sampleRates, id: \.self) { r in
                            Text(r == 0 ? L.outAsPreset : (r == 44100 ? "44.1 \(L.kHz)" : "48 \(L.kHz)")).tag(r)
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .labelsHidden()
            .disabled(track.formatOverride == nil)
            .opacity(track.formatOverride == nil ? 0.5 : 1)
            HStack {
                Button(L.applyToChecked(checked)) {
                    for t in store.tracks where t.isChecked && !t.isActive { t.formatOverride = track.formatOverride }
                }
                .disabled(checked == 0)
                Spacer()
                Button(L.sameAsAll) { track.formatOverride = nil }.disabled(track.formatOverride == nil)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
#endif
