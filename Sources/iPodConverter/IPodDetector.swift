import Foundation
import IOKit
import IOKit.usb
import Observation

/// Находит подключённые iPod: по USB (видно всегда, даже без «режима диска»)
/// и уточняет модель по SysInfo, если iPod смонтирован как диск.
/// USB-идентификаторы Apple (idVendor 0x05AC) — по открытым спискам (libgpod, usb.ids);
/// на реальных устройствах проверены не все.
@MainActor
@Observable
final class IPodDetector {
    static let shared = IPodDetector()

    /// Подключённые сейчас модели (без повторов, в порядке каталога).
    private(set) var connected: [IPodModel] = []
    /// Модель, которую пользователь держит во вкладках: подсказка, когда 5G и 5.5G неотличимы.
    @ObservationIgnored var preferEnhanced5G: () -> Bool = { false }
    /// Вызывается для каждой модели, которая только что появилась.
    @ObservationIgnored var onConnect: ((IPodModel) -> Void)?
    @ObservationIgnored var onDisconnect: ((IPodModel) -> Void)?
    @ObservationIgnored private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        // Опрос раз в 2 с — дёшево и надёжнее, чем подписка на события IOKit из SwiftUI-приложения.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { IPodDetector.shared.refresh() }
        }
    }

    func isConnected(_ m: IPodModel) -> Bool { connected.contains(m) }

    func refresh() {
        let found = Self.detect(preferEnhanced5G: preferEnhanced5G())
        guard found != connected else { return }
        let old = Set(connected)
        connected = found
        for m in found where !old.contains(m) { onConnect?(m) }
        for m in old where !found.contains(m) { onDisconnect?(m) }
    }

    // MARK: Определение

    nonisolated static func detect(preferEnhanced5G: Bool = false) -> [IPodModel] {
        let models = mountedModelNumbers()
        var found = usbProductIDs().compactMap { model(forUSB: $0, modelNumbers: models) }
        // 5G и 5.5G по USB одинаковы; без SysInfo с номером модели берём ту, что у пользователя во вкладках.
        if preferEnhanced5G, models.isEmpty, let i = found.firstIndex(of: .classic5G) { found[i] = .classic55G }
        return IPodModel.allCases.filter { found.contains($0) }
    }

    /// idProduct всех USB-устройств Apple.
    nonisolated static func usbProductIDs() -> [Int] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return [] }
        matching["idVendor"] = 0x05AC
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids: [Int] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if let pid = IORegistryEntryCreateCFProperty(service, "idProduct" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                ids.append(pid)
            }
            IOObjectRelease(service)
        }
        return ids
    }

    /// Номера моделей («MA446») из SysInfo смонтированных iPod.
    nonisolated static func mountedModelNumbers() -> [String] {
        let vols = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return vols.compactMap { v in
            let path = "/Volumes/\(v)/iPod_Control/Device/SysInfo"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") where line.hasPrefix("ModelNumStr:") {
                // «ModelNumStr: xA446» → «A446»
                let raw = line.dropFirst("ModelNumStr:".count).trimmingCharacters(in: .whitespaces)
                return String(raw.drop { !$0.isLetter || $0 == "x" || $0 == "M" }.prefix(4)).uppercased()
            }
            return nil
        }
    }

    /// USB idProduct (+ номер модели, если известен) → модель в приложении.
    nonisolated static func model(forUSB pid: Int, modelNumbers: [String]) -> IPodModel? {
        switch pid {
        case 0x1209:   // iPod with video: 5G и 5.5G — различаем по номеру модели
            let enhanced: Set<String> = ["A444", "A446", "A448", "A450", "A664"]
            return modelNumbers.contains(where: enhanced.contains) ? .classic55G : .classic5G
        case 0x1261:   // iPod classic: 6G / 6.5G / 7G
            if modelNumbers.contains(where: { ["B562", "B565"].contains($0) }) { return .classic65G }
            if modelNumbers.contains(where: { ["C293", "C297"].contains($0) }) { return .classic7G }
            return .classic6G
        case 0x1262: return .nano3
        case 0x1263: return .nano4
        case 0x1265: return .nano5
        case 0x1267: return .nano7
        case 0x1291, 0x1293, 0x1299: return .touch1     // touch 1G–3G
        case 0x129E: return .touch4
        case 0x12AA, 0x12AB: return .touch5             // touch 5G и новее
        default: return nil                              // nano 6 (без видео) и прочие устройства Apple
        }
    }
}
