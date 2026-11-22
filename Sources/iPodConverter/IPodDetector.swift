import Foundation
import IOKit
import IOKit.usb
import Observation
import SQLite3

/// Подключённый iPod: модель для конвертации, имя (как в Finder) и серийный номер USB (FireWire GUID).
struct ConnectedIPod: Equatable, Identifiable {
    var id: String { serial.isEmpty ? model.rawValue : serial }
    var model: IPodModel
    /// «Julian’s iPod» — из главного плейлиста iTunesDB; nil, если iPod не смонтирован как диск.
    var name: String?
    var serial: String
    /// 5G и 5.5G неотличимы автоматически — модель можно уточнить вручную.
    var ambiguous: Bool
}

/// Находит подключённые iPod: по USB (видно всегда, даже без «режима диска»), а с диска iPod
/// берёт номер модели (SysInfo) и имя устройства (iTunesDB).
/// USB-идентификаторы Apple (idVendor 0x05AC) — по открытым спискам (libgpod, usb.ids);
/// 0x1209 (5G/5.5G) и 0x1267 (nano 7) проверены на реальных устройствах.
@MainActor
@Observable
final class IPodDetector {
    static let shared = IPodDetector()

    private(set) var devices: [ConnectedIPod] = []
    /// iPod подключён, но доступ к его диску запрещён (запрос macOS про съёмные носители).
    /// Тогда данные iPod не используем: вкладки сами не добавляются — пользователь выбирает iPod вручную.
    private(set) var accessDenied = false
    /// По USB подключено устройство «iPod», но модель не распознана (nano 6 без видео, неизвестная модель).
    private(set) var unknownIPod = false
    /// Подключили iPod (новый или переподключили), а доступа нет — спросить ещё раз своим окном.
    var askPermission = false
    /// Серийные номера iPod, которые были подключены при прошлом опросе.
    @ObservationIgnored private var lastSerials: Set<String> = []
    @ObservationIgnored private var didFirstScan = false
    /// Подключённые модели (без повторов, в порядке каталога).
    var connected: [IPodModel] { IPodModel.allCases.filter { m in devices.contains { $0.model == m } } }

    @ObservationIgnored var onConnect: ((IPodModel) -> Void)?
    @ObservationIgnored var onDisconnect: ((IPodModel) -> Void)?
    /// Без ручного уточнения неоднозначный 5G/5.5G берём по вкладкам пользователя.
    @ObservationIgnored var preferEnhanced5G: () -> Bool = { false }
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

    func isConnected(_ m: IPodModel) -> Bool { devices.contains { $0.model == m } }
    func device(for m: IPodModel) -> ConnectedIPod? { devices.first { $0.model == m } }

    func refresh() {
        let denied = Self.volumeAccessDenied()
        if denied != accessDenied { accessDenied = denied }
        // Новое подключение iPod при запрете доступа — предложить разрешить заново.
        let serials = Set(Self.usbDevices().filter { Self.model(forUSB: $0.pid, modelNumbers: []) != nil }.map(\.serial))
        // При запуске не спрашиваем (пользователь уже ответил) — только при подключении/смене iPod.
        if denied && didFirstScan && !serials.subtracting(lastSerials).isEmpty { askPermission = true }
        if serials.isEmpty { askPermission = false }
        lastSerials = serials
        didFirstScan = true
        let unknown = Self.hasUnrecognizedIPod()
        if unknown != unknownIPod { unknownIPod = unknown }
        let found = denied ? [] : Self.detect(preferEnhanced5G: preferEnhanced5G(), overrides: Self.savedOverrides())
        guard found != devices else { return }
        let old = Set(connected)
        devices = found
        let now = Set(connected)
        for m in connected where !old.contains(m) { onConnect?(m) }
        for m in old where !now.contains(m) { onDisconnect?(m) }
    }

    // MARK: Повторный запрос доступа

    /// macOS спрашивает о съёмных носителях только один раз. Сбрасываем прошлый отказ
    /// только для этого приложения (tccutil reset SystemPolicyRemovableVolumes <bundle id>),
    /// затем обращаемся к диску iPod — система показывает запрос снова.
    func requestAccessAgain() {
        askPermission = false
        let bundleID = Bundle.main.bundleIdentifier ?? "local.ipodconverter"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "SystemPolicyRemovableVolumes", bundleID]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            // Обращение к съёмным дискам вызывает системный запрос; ответ подхватит следующий опрос.
            let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
            for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
                guard let r = try? v.resourceValues(forKeys: Set(keys)), r.volumeIsInternal != true,
                      r.volumeIsRemovable == true || r.volumeIsEjectable == true else { continue }
                _ = try? FileManager.default.contentsOfDirectory(atPath: v.path)
            }
            DispatchQueue.main.async { IPodDetector.shared.refresh() }
        }
    }

    // MARK: Ручное уточнение модели (по серийному номеру устройства)

    nonisolated static func savedOverrides() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "deviceModels") as? [String: String] ?? [:]
    }

    /// «Это iPod 5.5G» — запоминаем для этого устройства.
    func setModel(_ m: IPodModel, for device: ConnectedIPod) {
        guard !device.serial.isEmpty else { return }
        var o = Self.savedOverrides()
        o[device.serial] = m.rawValue
        UserDefaults.standard.set(o, forKey: "deviceModels")
        refresh()
    }

    // MARK: Определение

    nonisolated static func detect(preferEnhanced5G: Bool = false, overrides: [String: String] = [:]) -> [ConnectedIPod] {
        let volumes = mountedIPods()
        var usedVolumes = Set<String>()
        var result: [ConnectedIPod] = []
        // Только iPod (хабы, мониторы и прочие устройства Apple не мешают сопоставлению с дисками).
        let usb = usbDevices().filter { model(forUSB: $0.pid, modelNumbers: []) != nil }
        for dev in usb {
            // Диск этого iPod: по GUID из SysInfo; иначе — единственный «незанятый» iPod-диск.
            var vol = volumes.first { !$0.guid.isEmpty && $0.guid == dev.serial }
            if vol == nil {
                let free = volumes.filter { $0.guid.isEmpty && !usedVolumes.contains($0.path) }
                if free.count == 1 && usb.filter({ u in !volumes.contains { $0.guid == u.serial } }).count == 1 { vol = free.first }
            }
            if let v = vol { usedVolumes.insert(v.path) }
            guard var model = model(forUSB: dev.pid, modelNumbers: vol.map { [$0.modelNumber] } ?? []) else { continue }
            let ambiguous = dev.pid == 0x1209 && (vol?.modelNumber ?? "").isEmpty
            if let o = overrides[dev.serial], let m = IPodModel(rawValue: o) {
                model = m
            } else if ambiguous && preferEnhanced5G {
                model = .classic55G
            }
            result.append(ConnectedIPod(model: model, name: vol?.name, serial: dev.serial, ambiguous: ambiguous))
        }
        return result.sorted { (IPodModel.allCases.firstIndex(of: $0.model) ?? 0) < (IPodModel.allCases.firstIndex(of: $1.model) ?? 0) }
    }

    /// USB-устройства Apple: idProduct и серийный номер (у iPod это FireWire GUID).
    /// Фильтр по idVendor в самом запросе IOKit не срабатывает — проверяем производителя здесь.
    nonisolated static func usbDevices() -> [(pid: Int, serial: String, name: String)] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [(Int, String, String)] = []
        while true {
            let s = IOIteratorNext(iterator)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard (prop("idVendor") as? Int) == 0x05AC, let pid = prop("idProduct") as? Int else { continue }
            let serial = (prop("USB Serial Number") as? String) ?? (prop("kUSBSerialNumberString") as? String) ?? ""
            out.append((pid, serial.uppercased(), (prop("USB Product Name") as? String) ?? ""))
        }
        return out
    }

    struct MountedIPod {
        var path: String
        var guid: String         // «000A270022FC25B9» или пусто
        var modelNumber: String  // «A446» или пусто
        var name: String?
    }

    /// iPod, смонтированные как диски: GUID и номер модели из SysInfo / SysInfoExtended, имя из iTunesDB.
    /// Устройство с USB-именем «iPod», которое не сопоставилось ни с одной моделью с видео.
    nonisolated static func hasUnrecognizedIPod() -> Bool {
        usbDevices().contains { $0.name.localizedCaseInsensitiveContains("iPod") && model(forUSB: $0.pid, modelNumbers: []) == nil }
    }

    /// Подключён iPod (по USB), а прочитать съёмный диск не дают — значит, пользователь запретил доступ.
    nonisolated static func volumeAccessDenied() -> Bool {
        guard usbDevices().contains(where: { model(forUSB: $0.pid, modelNumbers: []) != nil }) else { return false }
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for v in vols {
            guard let r = try? v.resourceValues(forKeys: Set(keys)),
                  r.volumeIsInternal != true, (r.volumeIsRemovable == true || r.volumeIsEjectable == true) else { continue }
            do { _ = try FileManager.default.contentsOfDirectory(atPath: v.path) }
            catch let e as NSError {
                let posix = (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                if e.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) { return true }
            }
        }
        return false
    }

    nonisolated static func mountedIPods() -> [MountedIPod] {
        let vols = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return vols.compactMap { v in
            let root = "/Volumes/\(v)"
            guard FileManager.default.fileExists(atPath: root + "/iPod_Control") else { return nil }
            var guid = "", number = ""
            if let text = try? String(contentsOfFile: root + "/iPod_Control/Device/SysInfo", encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("ModelNumStr:") {
                        let raw = line.dropFirst("ModelNumStr:".count).trimmingCharacters(in: .whitespaces)
                        number = String(raw.drop { !$0.isLetter || $0 == "x" || $0 == "M" }.prefix(4)).uppercased()
                    }
                    if line.hasPrefix("FirewireGuid:") {
                        guid = line.dropFirst("FirewireGuid:".count).trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "0x", with: "").uppercased()
                    }
                }
            }
            if guid.isEmpty,
               let d = FileManager.default.contents(atPath: root + "/iPod_Control/Device/SysInfoExtended"),
               let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
               let g = plist["FireWireGUID"] as? String {
                guid = g.replacingOccurrences(of: "0x", with: "").uppercased()
            }
            return MountedIPod(path: root, guid: guid, modelNumber: number, name: deviceName(root))
        }
    }

    /// Имя iPod, как в Finder. nano 6/7: скрытый главный контейнер в SQLite-базе (Library.itdb);
    /// остальные: главный плейлист (mhyp с флагом master) в iTunesDB.
    nonisolated static func deviceName(_ root: String) -> String? {
        if let n = sqliteName(root + "/iPod_Control/iTunes/iTunes Library.itlp/Library.itdb") { return n }
        guard let h = FileHandle(forReadingAtPath: root + "/iPod_Control/iTunes/iTunesDB") else { return nil }
        defer { try? h.close() }
        // Главный плейлист идёт после списка треков — читаем частями, пока не найдём (до 64 МБ).
        var data = Data()
        while data.count < 64 << 20, let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
            data.append(chunk)
            if let name = masterPlaylistName(data) { return name }
        }
        return nil
    }

    /// Только чтение (immutable): базу iPod не трогаем.
    nonisolated static func sqliteName(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        let sql = "SELECT name FROM container WHERE distinguished_kind = 0 AND is_hidden = 1 AND parent_pid = 0 LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        let name = String(cString: c)
        return name.isEmpty ? nil : name
    }

    nonisolated static func masterPlaylistName(_ d: Data) -> String? {
        let b = [UInt8](d)
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : 0 }
        let tag = Array("mhyp".utf8), mhod = Array("mhod".utf8)
        var i = 0
        while i + 24 < b.count {
            if b[i] == tag[0], Array(b[i..<i + 4]) == tag {
                let hl = u32(i + 4), tl = u32(i + 8)
                if b[i + 20] == 1 && i + tl <= b.count {       // главный плейлист
                    var j = i + hl
                    while j + 40 < i + tl, Array(b[j..<j + 4]) == mhod {
                        let total = u32(j + 8), type = u32(j + 12)
                        if type == 1 {                         // заголовок
                            let len = u32(j + 28)
                            guard j + 40 + len <= b.count else { return nil }
                            return String(bytes: b[(j + 40)..<(j + 40 + len)], encoding: .utf16LittleEndian)
                        }
                        guard total > 0 else { break }
                        j += total
                    }
                    return nil
                }
                i += max(hl, 4)
                continue
            }
            i += 1
        }
        return nil
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
