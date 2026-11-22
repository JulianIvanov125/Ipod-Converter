import Foundation

/// Все iPod, которые умеют показывать видео (shuffle, mini, nano 1–2 и nano 6 видео не играют).
/// Параметры кодирования — по техспецификациям Apple (по памяти, не сверены с первоисточником):
/// разрешение = экран устройства, профиль/уровень H.264 — максимум, который заявлен для модели.
enum IPodModel: String, CaseIterable, Identifiable {
    // rawValue используются в настройках — не переименовывать.
    case classic5G
    case classic55G
    case classic6G
    case classic65G
    case classic7G
    case nano3
    case nano4
    case nano5
    case nano7
    case touch1
    case touch4
    case touch5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic5G: "iPod 5G"
        case .classic55G: "iPod 5.5G"
        case .classic6G: "iPod classic 6G"
        case .classic65G: "iPod classic 6.5G"
        case .classic7G: "iPod classic 7G"
        case .nano3: "iPod nano 3"
        case .nano4: "iPod nano 4"
        case .nano5: "iPod nano 5"
        case .nano7: "iPod nano 7"
        case .touch1: "iPod touch 1–3"
        case .touch4: "iPod touch 4"
        case .touch5: "iPod touch 5–7"
        }
    }

    /// Пояснение для списка всех моделей.
    var details: String {
        switch self {
        case .classic5G: "Video · 2005"
        case .classic55G: "Enhanced · 2006"
        case .classic6G: "80/160 \(L.gb) · 2007"
        case .classic65G: "120 \(L.gb) · 2008"
        case .classic7G: "160 \(L.gb) · 2009"
        case .nano3: "\(L.chubby) · 2007"
        case .nano4: "2008"
        case .nano5: "\(L.withCamera) · 2009"
        case .nano7: "2012–2015"
        case .touch1: "2007–2009"
        case .touch4: "Retina · 2010"
        case .touch5: "2012–2019"
        }
    }

    /// Есть ли режим «Максимум» 640×480. Экран всё равно 320×240, но картинка резче
    /// (iPod сам уменьшает кадр) и годится для TV-выхода.
    /// У iPod 5G (2005) 640×480 в спецификации нет — только 320×240, Level 1.3.
    var supportsMax: Bool {
        switch self {
        case .classic55G, .classic6G, .classic65G, .classic7G, .nano3, .nano4, .nano5: true
        default: false
        }
    }

    /// Плейлист в Music.app, который синхронизируется только с этим iPod.
    var playlistName: String { title }

    var fileSuffix: String { title }

    /// Модели в избранном по умолчанию.
    static let defaultFavorites: [IPodModel] = [.classic5G, .nano7]

    func settings(max: Bool) -> EncodeSettings {
        if max && supportsMax {
            switch self {
            case .classic6G, .classic65G, .classic7G:
                // iPod classic: H.264 до 2.5 Мбит/с, 640×480, Baseline до Level 3.0 (спецификация Apple).
                return EncodeSettings(w: 640, h: 480, profile: "baseline", level: "3.0",
                                      videoKbps: 2300, maxrateKbps: 2500, bufsizeKbps: 3000, isMax: true)
            default:
                // 5.5G и nano 3–5: до 1.5 Мбит/с, 640×480, Low-Complexity Baseline
                // (как пресет HandBrake «iPod Legacy»: VBV 1500/2000).
                return EncodeSettings(w: 640, h: 480, profile: "baseline", level: "3.0",
                                      videoKbps: 1400, maxrateKbps: 1500, bufsizeKbps: 2000, isMax: true)
            }
        }
        switch self {
        case .classic5G, .classic55G:
            // 5G и 5.5G: H.264 до 768 кбит/с, 320×240, Baseline до Level 1.3.
            return .init(w: 320, h: 240, profile: "baseline", level: "1.3",
                         videoKbps: 740, maxrateKbps: 768, bufsizeKbps: 1536, isMax: false)
        case .classic6G, .classic65G, .classic7G, .nano3, .nano4:
            return .init(w: 320, h: 240, profile: "baseline", level: "3.0",
                         videoKbps: 740, maxrateKbps: 768, bufsizeKbps: 1536, isMax: false)
        case .nano5:
            return .init(w: 376, h: 240, profile: "baseline", level: "3.0",
                         videoKbps: 800, maxrateKbps: 1000, bufsizeKbps: 2000, isMax: false)
        case .nano7:
            return .init(w: 432, h: 240, profile: "baseline", level: "3.0",
                         videoKbps: 900, maxrateKbps: 1200, bufsizeKbps: 2400, isMax: false)
        case .touch1:
            return .init(w: 480, h: 320, profile: "baseline", level: "3.0",
                         videoKbps: 1200, maxrateKbps: 1500, bufsizeKbps: 3000, isMax: false)
        case .touch4:
            return .init(w: 960, h: 640, profile: "main", level: "3.1",
                         videoKbps: 2000, maxrateKbps: 2500, bufsizeKbps: 5000, isMax: false)
        case .touch5:
            return .init(w: 1136, h: 640, profile: "high", level: "4.1",
                         videoKbps: 2500, maxrateKbps: 3500, bufsizeKbps: 7000, isMax: false)
        }
    }
}

/// Конкретные параметры кодирования.
struct EncodeSettings: Equatable {
    let w: Int
    let h: Int
    let profile: String
    let level: String
    let videoKbps: Int
    let maxrateKbps: Int
    let bufsizeKbps: Int
    let isMax: Bool
    /// AAC-LC: максимум, заявленный для iPod, — 160 кбит/с, 48 кГц.
    var audioKbps: Int { 160 }
    var audioRate: Int { 48000 }

    var profileName: String {
        switch profile {
        case "main": "Main"
        case "high": "High"
        default: "Baseline"
        }
    }

    /// Итоговое разрешение: вписываем в w×h, не увеличиваем, чётные стороны.
    func outputSize(for info: MediaInfo) -> (w: Int, h: Int) {
        let sw = max(info.displayWidth, 2), sh = max(info.displayHeight, 2)
        let scale = min(Double(w) / Double(sw), Double(h) / Double(sh), 1.0)
        let ow = Int((Double(sw) * scale) / 2) * 2
        let oh = Int((Double(sh) * scale) / 2) * 2
        return (max(ow, 2), max(oh, 2))
    }

    /// Оценка размера: (видео + аудио битрейт) × длительность + ~2% на контейнер.
    func estimatedBytes(for info: MediaInfo) -> Int64 {
        let kbps = Double(videoKbps + (info.hasAudio ? audioKbps : 0))
        return Int64(kbps * 1000 / 8 * info.duration * 1.02)
    }
}
