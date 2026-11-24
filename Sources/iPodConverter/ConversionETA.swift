import Foundation

/// Примерное время конвертации. Скорость — сколько секунд материала пачка обрабатывает за секунду
/// (с учётом того, что файлы идут параллельно) — запоминается по прошлым пачкам на этом компьютере.
/// Во время пачки прогноз поправляется по её фактическому ходу.
enum ConversionETA {
    enum Kind: String { case video, videoMax, music }

    /// Стартовые значения (Mac на Apple Silicon); после первых пачек заменяются своими.
    private static let initial: [Kind: Double] = [.video: 55, .videoMax: 25, .music: 400]
    /// Трек, который подходит iPod как есть, только копируется.
    static let copySeconds = 0.3

    static func speed(_ k: Kind) -> Double {
        let v = UserDefaults.standard.double(forKey: "etaSpeed." + k.rawValue)
        return v > 0 ? v : initial[k]!
    }

    /// Пачка шла в `factor` раз дольше прогноза — поправляем скорость (плавно, чтобы один странный раз не сбил).
    static func adjust(_ kinds: Set<Kind>, factor: Double) {
        let f = min(max(factor, 0.1), 10)
        for k in kinds {
            let old = speed(k)
            UserDefaults.standard.set(old * 0.4 + old / f * 0.6, forKey: "etaSpeed." + k.rawValue)
        }
    }

    static func expected(media seconds: Double, kind: Kind) -> Double { max(0, seconds) / speed(kind) }
}

/// Ход одной пачки: сколько работы ожидали (в секундах по запомненной скорости) и сколько уже сделано.
struct ETATracker {
    private(set) var start: Date?
    private(set) var total: Double = 0
    private(set) var finished: Double = 0
    private(set) var kinds: Set<ConversionETA.Kind> = []
    private var perItem: [UUID: Double] = [:]

    mutating func add(_ id: UUID, expected: Double, kind: ConversionETA.Kind) {
        if start == nil { start = Date() }
        total += expected
        perItem[id] = expected
        kinds.insert(kind)
    }

    func expected(_ id: UUID) -> Double { perItem[id] ?? 0 }

    /// Файл закончился (или с ошибкой) — его работа сделана.
    mutating func finish(_ id: UUID) { finished += perItem.removeValue(forKey: id) ?? 0 }

    /// Файл убрали из пачки — его работы больше нет.
    mutating func drop(_ id: UUID) { total -= perItem.removeValue(forKey: id) ?? 0 }

    /// Сколько ещё ждать. `running` — сделанная доля идущих файлов в тех же единицах.
    func remaining(running: Double) -> Double? {
        guard let start else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let done = finished + running
        let left = max(0, total - done)
        guard elapsed > 5, done > 0.5 else { return left }
        // Чем дольше идёт пачка, тем больше верим её фактическому темпу.
        let w = min(1, elapsed / 30)
        return left * (w * elapsed / done + (1 - w))
    }

    /// Пачка закончилась без ошибок — запоминаем, насколько прогноз разошёлся с фактом.
    func learn() {
        guard let start, finished > 1 else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 3 else { return }
        ConversionETA.adjust(kinds, factor: elapsed / finished)
    }
}
