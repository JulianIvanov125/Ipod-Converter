#if os(macOS)
import Observation
import SwiftUI

// MARK: - Свои настройки выхода для видео (поверх пресета iPod)

enum OutResolution: String, CaseIterable, Identifiable {
    case preset, r320, r480, r640, hd720, hd1080, original
    var id: String { rawValue }

    var title: String {
        switch self {
        case .preset: L.t("As in preset", "Как в пресете", "Як у пресеті", "Як у прэсэце")
        case .r320: "320×240"
        case .r480: "480×320"
        case .r640: "640×480"
        case .hd720: "1280×720 (720p)"
        case .hd1080: "1920×1080 (1080p)"
        case .original: L.t("Original", "Как в оригинале", "Як в оригіналі", "Як у арыгінале")
        }
    }

    var box: (w: Int, h: Int)? {
        switch self {
        case .preset: nil
        case .r320: (320, 240)
        case .r480: (480, 320)
        case .r640: (640, 480)
        case .hd720: (1280, 720)
        case .hd1080: (1920, 1080)
        case .original: (100_000, 100_000)   // без уменьшения
        }
    }
}

/// Поправки к пресету iPod: общие (кнопка «Выход») или для одного видео (⚙︎ в карточке).
struct VideoOverride: Equatable {
    var container: VideoContainer = .m4v
    var codec: VideoCodec = .h264
    var resolution: OutResolution = .preset
    var videoKbps = 0       // 0 — как в пресете
    var audioKbps = 0
    var sampleRate = 0

    func apply(to base: EncodeSettings) -> EncodeSettings {
        var s = base
        s.isCustom = true
        s.container = container
        s.codec = codec
        if let box = resolution.box {
            s.w = box.w; s.h = box.h
            // Профиль H.264 — по размеру кадра: старые iPod — Baseline, HD — Main/High.
            if box.w * box.h <= 640 * 480 { s.profile = "baseline"; s.level = "3.0" }
            else if box.w * box.h <= 1280 * 720 { s.profile = "main"; s.level = "3.1" }
            else { s.profile = "high"; s.level = "4.1" }
            if resolution == .original { s.profile = "high"; s.level = "" }
            s.fpsMax = box.w * box.h > 640 * 480 ? 60 : 30
        }
        if videoKbps > 0 {
            s.videoKbps = videoKbps
            s.maxrateKbps = videoKbps * 5 / 4
            s.bufsizeKbps = s.maxrateKbps * 2
        }
        if audioKbps > 0 { s.audioKbps = audioKbps }
        if sampleRate > 0 { s.audioRate = sampleRate }
        return s
    }
}

@MainActor
@Observable
final class VideoOutputSettings {
    static let shared = VideoOutputSettings()
    static let videoRates = [0, 500, 768, 1000, 1500, 2500, 4000, 8000]   // 0 — как в пресете
    static let audioRates = [0, 96, 128, 160, 192, 256, 320]
    static let sampleRates = [0, 44100, 48000]

    var enabled: Bool { didSet { save() } }
    var container: VideoContainer { didSet { save() } }
    var codec: VideoCodec { didSet { save() } }
    var resolution: OutResolution { didSet { save() } }
    var videoKbps: Int { didSet { save() } }
    var audioKbps: Int { didSet { save() } }
    var sampleRate: Int { didSet { save() } }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "out.enabled")
        container = VideoContainer(rawValue: d.string(forKey: "out.container") ?? "") ?? .m4v
        codec = VideoCodec(rawValue: d.string(forKey: "out.codec") ?? "") ?? .h264
        resolution = OutResolution(rawValue: d.string(forKey: "out.resolution") ?? "") ?? .preset
        videoKbps = d.integer(forKey: "out.vkbps")
        audioKbps = d.integer(forKey: "out.akbps")
        sampleRate = d.integer(forKey: "out.rate")
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "out.enabled")
        d.set(container.rawValue, forKey: "out.container")
        d.set(codec.rawValue, forKey: "out.codec")
        d.set(resolution.rawValue, forKey: "out.resolution")
        d.set(videoKbps, forKey: "out.vkbps")
        d.set(audioKbps, forKey: "out.akbps")
        d.set(sampleRate, forKey: "out.rate")
    }

    func reset() {
        container = .m4v; codec = .h264; resolution = .preset
        videoKbps = 0; audioKbps = 0; sampleRate = 0
    }

    /// Общие поправки как структура (для «Применить к одному видео»).
    var asOverride: VideoOverride {
        VideoOverride(container: container, codec: codec, resolution: resolution,
                      videoKbps: videoKbps, audioKbps: audioKbps, sampleRate: sampleRate)
    }

    /// Пресет iPod с поправками пользователя.
    func apply(to base: EncodeSettings) -> EncodeSettings {
        enabled ? asOverride.apply(to: base) : base
    }

    /// Чем настройки выходят за пределы того, что играет iPod (пусто — всё в пределах).
    func iPodIssues(for model: IPodModel, _ s: EncodeSettings) -> [String] {
        guard s.isCustom else { return [] }
        let limit = model.settings(max: true)
        var issues: [String] = []
        if s.codec != .h264 { issues.append(L.issueCodec) }
        if s.w > limit.w || s.h > limit.h { issues.append(L.issueResolution(limit.w, limit.h)) }
        if s.maxrateKbps > limit.maxrateKbps { issues.append(L.issueBitrate(limit.maxrateKbps)) }
        if s.audioKbps > 160 { issues.append(L.issueAudio) }
        return issues
    }
}

// MARK: - Кнопка и окно настроек

struct OutputSettingsButton: View {
    @Bindable var store: Store
    @Bindable private var out = VideoOutputSettings.shared
    @State private var open = false

    var body: some View {
        let issues = out.iPodIssues(for: store.model, store.currentSettings)
        Button {
            open.toggle()
        } label: {
            Label(out.enabled ? L.outCustom
                  : L.outPreset(store.model.title) + (store.model.supportsMax && store.maxQuality ? " · \(L.maximum)" : ""),
                  systemImage: issues.isEmpty ? "gearshape" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(issues.isEmpty ? Color.secondary : Color.orange)
        }
        .buttonStyle(.plain)
        .help(L.outHelp)
        .popover(isPresented: $open, arrowEdge: .top) {
            OutputSettingsView(store: store)
        }
    }
}

struct OutputSettingsView: View {
    @Bindable var store: Store
    @Bindable private var out = VideoOutputSettings.shared

    var body: some View {
        let s = store.currentSettings
        let issues = out.iPodIssues(for: store.model, s)
        VStack(alignment: .leading, spacing: 12) {
            if store.model.supportsMax {
                // Пресет iPod: «Стандарт» или «Максимум» — без своих настроек (тот же выбор, что под вкладками iPod).
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.outPresetQuality(store.model.title)).font(.system(size: 13, weight: .semibold))
                    Picker("", selection: $store.maxQuality) {
                        let st = store.model.settings(max: false), mx = store.model.settings(max: true)
                        Text("\(L.standard) · \(st.w)×\(st.h)").tag(false)
                        Text("\(L.maximum) · \(mx.w)×\(mx.h)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(store.isBusy)
                    Text(L.maxHelp("\(store.model.settings(max: true).w)×\(store.model.settings(max: true).h)",
                                     String(format: "%.1f", Double(store.model.settings(max: true).maxrateKbps) / 1000)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }
            Toggle(isOn: $out.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.outToggle).font(.system(size: 13, weight: .semibold))
                    Text(L.outToggleHint(store.model.title)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row(L.outContainer) {
                    Picker("", selection: $out.container) {
                        ForEach(VideoContainer.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                    }.pickerStyle(.segmented)
                }
                row(L.outCodec) {
                    Picker("", selection: $out.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                row(L.resolution) {
                    Picker("", selection: $out.resolution) {
                        ForEach(OutResolution.allCases) { Text($0.title).tag($0) }
                    }
                }
                row(L.outVideoBitrate) {
                    Picker("", selection: $out.videoKbps) {
                        ForEach(VideoOutputSettings.videoRates, id: \.self) { k in
                            Text(k == 0 ? L.outAsPreset : Fmt.kbps(k)).tag(k)
                        }
                    }
                }
                row(L.outAudio) {
                    HStack {
                        Picker("", selection: $out.audioKbps) {
                            ForEach(VideoOutputSettings.audioRates, id: \.self) { k in
                                Text(k == 0 ? L.outAsPreset : "AAC \(k) \(L.kbps)").tag(k)
                            }
                        }
                        Picker("", selection: $out.sampleRate) {
                            ForEach(VideoOutputSettings.sampleRates, id: \.self) { r in
                                Text(r == 0 ? L.outAsPreset : (r == 44100 ? "44.1 \(L.kHz)" : "48 \(L.kHz)")).tag(r)
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .disabled(!out.enabled)
            .opacity(out.enabled ? 1 : 0.5)

            Divider()
            // Итог: что получится
            Text("\(s.container.rawValue.uppercased()) · \(s.codecLabel) · \(s.w >= 100_000 ? L.outOriginalSize : "\(s.w)×\(s.h)") · \(Fmt.kbps(s.videoKbps)) · AAC \(s.audioKbps) \(L.kbps) · \(s.audioRate == 44100 ? "44.1" : "48") \(L.kHz)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L.outWarning(store.model.title), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    ForEach(issues, id: \.self) { Text("• " + $0).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Spacer()
                Button(L.outReset) { out.reset() }.disabled(!out.enabled)
            }
        }
        .padding(16)
        .frame(width: 430)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }
}
#endif
