import AppKit
import Observation
import SwiftUI

// MARK: - Стиль визуализации

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case bars, waves, coverWaves
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: L.t("Equalizer", "Эквалайзер", "Еквалайзер", "Эквалайзер")
        case .waves: L.t("Water drops", "Капли на воде", "Краплі на воді", "Кроплі на вадзе")
        case .coverWaves: L.t("Cover colors", "Цвета обложки", "Кольори обкладинки", "Колеры вокладкі")
        }
    }

    var icon: String {
        switch self {
        case .bars: "chart.bar.fill"
        case .waves: "drop.fill"
        case .coverWaves: "paintpalette.fill"
        }
    }
}

@MainActor
@Observable
final class VisualizerSettings {
    static let shared = VisualizerSettings()
    var style: VisualizerStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "visualizer") }
    }
    private init() {
        style = VisualizerStyle(rawValue: UserDefaults.standard.string(forKey: "visualizer") ?? "") ?? .coverWaves
    }
}

// MARK: - Цвета обложки

struct CoverColors {
    /// 3 ярких цвета (эквалайзер, капли).
    var accents: [Color]
    /// Тёмный фон под визуализацию.
    var background: Color
    /// До 5 основных цветов обложки «как есть» (по площади) — для заливки фона.
    var blend: [Color]
}

enum CoverPalette {
    static func colors(from image: NSImage?) -> CoverColors {
        let fallback: [Color] = [Color(red: 0.98, green: 0.24, blue: 0.40), Color(red: 0.55, green: 0.32, blue: 0.98), Color(red: 0.20, green: 0.70, blue: 1.0)]
        let fallbackBlend = fallback + [Color(red: 0.95, green: 0.55, blue: 0.2), Color(red: 0.1, green: 0.8, blue: 0.6)]
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return CoverColors(accents: fallback, background: Color(red: 0.08, green: 0.06, blue: 0.12), blend: fallbackBlend)
        }
        let side = 40
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CoverColors(accents: fallback, background: .black, blend: fallbackBlend) }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        // 18 корзин по оттенку + 3 для серых (тёмный/средний/светлый).
        let hueBins = 18, bins = hueBins + 3
        var vivid = [Double](repeating: 0, count: bins)      // вес = насыщенность × яркость
        var area = [Double](repeating: 0, count: bins)       // вес = площадь
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var avg = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            avg.0 += r; avg.1 += g; avg.2 += b
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            let bin = s < 0.15 ? hueBins + min(2, Int(v * 3)) : min(hueBins - 1, Int(h * CGFloat(hueBins)))
            area[bin] += 1
            if s >= 0.18 && v >= 0.18 { vivid[bin] += Double(s * v) }
            sum[bin].0 += r; sum[bin].1 += g; sum[bin].2 += b
        }
        let n = Double(side * side)
        let background = Color(red: avg.0 / n * 0.35, green: avg.1 / n * 0.35, blue: avg.2 / n * 0.35)
        func mean(_ bin: Int) -> NSColor {
            let c = max(area[bin], 1)
            return NSColor(srgbRed: sum[bin].0 / c, green: sum[bin].1 / c, blue: sum[bin].2 / c, alpha: 1)
        }
        func hsv(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            return (h, s, v)
        }

        // Яркие акценты
        var accents: [Color] = []
        for bin in (0..<hueBins).sorted(by: { vivid[$0] > vivid[$1] }) where vivid[bin] > 0.5 {
            let (h, s, v) = hsv(mean(bin))
            accents.append(Color(hue: h, saturation: max(s, 0.55), brightness: max(v, 0.85)))
            if accents.count == 3 { break }
        }
        while accents.count < 3 { accents.append(fallback[accents.count]) }

        // Основные цвета по площади — чуть осветлённые, чтобы фон не превращался в грязь
        var blend: [Color] = []
        for bin in (0..<bins).sorted(by: { area[$0] > area[$1] }) where area[bin] > n * 0.02 {
            let (h, s, v) = hsv(mean(bin))
            blend.append(Color(hue: h, saturation: min(1, s * 1.15), brightness: min(1, max(v, 0.32) * 1.1)))
            if blend.count == 5 { break }
        }
        // Мало цветов (однотонная обложка) — добавляем акценты.
        for a in accents where blend.count < 5 { blend.append(a) }
        return CoverColors(accents: accents, background: background, blend: blend)
    }
}

// MARK: - Анализ уровней между кадрами

final class LevelSmoother {
    static let n = AudioAnalyzer.bandCount
    /// Эквалайзер: быстрая атака, медленный спад.
    private(set) var levels = [Float](repeating: 0, count: n)
    private(set) var peaks = [Float](repeating: 0, count: n)
    /// Эквалайзер: громкость полос относительно самой громкой в моменте (0…1) и их пики.
    private(set) var eq = [Float](repeating: 0, count: n)
    private(set) var eqPeaks = [Float](repeating: 0, count: n)
    private var eqTop: Float = -120
    private var prevRaw = [Float](repeating: 0, count: n)
    private var cooldown = [Double](repeating: 0, count: n)
    private var prevBass: Float = 0
    private var bassCooldown: Double = 0
    /// Толчок на удар баса, 0…1, гаснет за ~0.4 с.
    private(set) var pulse: Float = 0
    /// Цвета обложки: части спектра, медленная громкость каждой и накопленная «фаза течения».
    static let flowGroups: [Range<Int>] = [0..<edge(85), edge(85)..<edge(230), edge(230)..<edge(800),
                                           edge(800)..<edge(3600), edge(3600)..<n]
    private(set) var flowLevel = [Float](repeating: 0, count: 5)
    private(set) var flowPhase = [Double](repeating: 0, count: 5)
    private var lastTime: Double = 0
    /// Удар баса для цвета: быстро нарастает и гаснет ~0.5 с — толчок без вспышки.
    private(set) var kick: Float = 0
    /// Динамика песни 0…1: насколько сейчас громко относительно последних ~20 с этого трека.
    /// Тихий куплет — около 0, громкий припев — около 1; меняется плавно (~1 с).
    private(set) var intensity: Float = 0.5
    private(set) var loudNow: Float = -120
    private var loudPeak: Float = -120
    /// Сколько секунд трек уже звучит (первые 1.5 с — «прислушиваемся», динамика посередине).
    private var heard: Double = 0
    private var silentFor: Double = 0
    /// Подписи частот на скачках (эквалайзер): полоса → (время, уровень).
    private(set) var labels: [Int: (t: Double, v: Float)] = [:]

    /// Скачки этого кадра: полоса и сила (0…1); band == -1 — удар баса.
    func update(time: Double) -> [(band: Int, strength: Float)] {
        let raw = AudioAnalyzer.shared.snapshot()
        // Сглаживание настроено под 60 кадров/с; при другой частоте кадров пересчитываем
        // коэффициенты по реальному времени — скорость реакции одинаковая на любом экране и на паузе.
        let dt = lastTime == 0 ? 1.0 / 60 : min(0.1, max(0.001, time - lastTime))
        lastTime = time
        let f = Float(dt * 60)
        func k(_ perFrame: Float) -> Float { 1 - pow(1 - perFrame, f) }
        let (atk, rel, top, flowA0, flowA1, flowA2, flowR0, flowR1, kickUp, kickDown) =
            (k(0.75), k(0.2), k(0.6), k(0.35), k(0.22), k(0.12), k(0.12), k(0.05), k(0.7), k(0.14))
        var onsets: [(Int, Float)] = []
        for i in 0..<Self.n {
            let v = raw[i]
            // Быстрая атака, спад средний — живо, но без дрожи на месте.
            levels[i] += (v - levels[i]) * (v > levels[i] ? atk : rel)
            peaks[i] = max(levels[i], peaks[i] - 0.012 * f)
            // Скачок: резкий рост в полосе, громче порога, не чаще раза в 0.3 с на полосу.
            let rise = v - prevRaw[i]
            if rise > 0.1, v > 0.35, time > cooldown[i] {
                onsets.append((i, min(1, v)))
                cooldown[i] = time + 0.3
                // Соседние полосы тоже «гасим», чтобы одна нота не давала пачку капель.
                for k in max(0, i - 2)...min(Self.n - 1, i + 2) { cooldown[k] = max(cooldown[k], time + 0.2) }
            }
            prevRaw[i] = v
        }
        // Относительная шкала: самая громкая полоса — у потолка, остальные ниже на свою разницу в дБ
        // (окно 24 дБ). Потолок быстро поднимается и медленно опускается — без «качания» всей картинки.
        let db = AudioAnalyzer.shared.snapshotDB()
        let frameTop = db.max() ?? -120
        eqTop = frameTop > eqTop ? eqTop + (frameTop - eqTop) * top : max(frameTop, eqTop - 0.25 * f)
        let window: Float = 24
        for i in 0..<Self.n {
            let quiet = max(0, min(1, (eqTop + 70) / 20))   // совсем тихо — столбики опускаются
            let v = max(0, min(1, (db[i] - (eqTop - window)) / window)) * quiet
            eq[i] += (v - eq[i]) * (v > eq[i] ? atk : rel)
            eqPeaks[i] = max(eq[i], eqPeaks[i] - 0.012 * f)
        }

        let bass = raw[Self.bassBands].reduce(0, +) / Float(Self.bassBands.count)
        var bassHit = false
        if bass - prevBass > 0.06, bass > 0.33, time > bassCooldown {
            bassHit = true
            bassCooldown = time + 0.18
            pulse = min(1, pulse + 0.9)
        }
        pulse *= pow(0.9, f)
        prevBass = bass

        // Резкий звук «размазывается» по соседним полосам — склеиваем соседние скачки
        // в одну каплю на самой громкой частоте. При ударе баса низ отдельно не считаем.
        var merged: [(Int, Float)] = []
        for o in onsets.sorted(by: { $0.0 < $1.0 }) {
            if bassHit && o.0 < Self.lowEnd { continue }
            if let last = merged.last, o.0 - last.0 <= 4 || (o.0 - (merged.last?.0 ?? 0)) <= 4 {
                if o.1 > last.1 { merged[merged.count - 1] = o }
            } else {
                merged.append(o)
            }
        }
        onsets = Array(merged.sorted { $0.1 > $1.1 }.prefix(3))
        if bassHit { onsets.append((-1, min(1, bass + 0.2))) }

        // Подписи для эквалайзера: заметные локальные максимумы.
        for i in 1..<(Self.n - 1) {
            let v = eq[i]
            guard v > 0.6, v >= eq[i - 1], v >= eq[i + 1] else { continue }
            let around = (eq[max(0, i - 3)] + eq[min(Self.n - 1, i + 3)]) / 2
            guard v - around > 0.1, !labels.keys.contains(where: { abs($0 - i) < 4 && $0 != i }) else { continue }
            labels[i] = (time, v)
        }
        labels = labels.filter { time - $0.value.t < 0.6 }

        // Течение цвета: громкость сглажена на ~1 с (без мерцания), а в ритм ускоряется движение.
        for k in 0..<Self.flowGroups.count {
            let e = energy(Self.flowGroups[k])
            // Низы реагируют быстрее и сильнее, верх — спокойнее.
            let attack = k == 0 ? flowA0 : k == 1 ? flowA1 : flowA2
            let release = k == 0 ? flowR0 : flowR1
            flowLevel[k] += (e - flowLevel[k]) * (e > flowLevel[k] ? attack : release)
            flowPhase[k] += dt * (0.27 + Double(flowLevel[k]) * 2.25 + Double(kick) * (k == 0 ? 3.5 : k == 1 ? 1.8 : 0.8))
        }
        kick += (pulse - kick) * (pulse > kick ? kickUp : kickDown)

        // Динамика: громкость в дБ (без обрезки, по энергии всех полос), сглаженная ~1 с — биты не раскачивают.
        // Сравниваем с громким пиком последних секунд: на пике — 1, на 12 дБ тише — 0.
        // Пик медленно опускается (0.5 дБ/с), поэтому «громко» — это громко для этой песни, а не вообще.
        func tau(_ sec: Double) -> Float { Float(1 - exp(-dt / sec)) }
        let energy = db.reduce(Float(0)) { $0 + pow(10, $1 / 10) } / Float(max(db.count, 1))
        let loud = 10 * log10(max(energy, 1e-12))
        // Тишина дольше секунды (пауза, новый трек) — начинаем заново.
        silentFor = loud < -75 ? silentFor + dt : 0
        if silentFor > 1 { loudNow = -120; heard = 0 }
        if loudNow < -100 { loudNow = loud }
        loudNow += (loud - loudNow) * tau(loud > loudNow ? 0.5 : 1.2)
        if loud > -75 { heard += dt }
        let target: Float
        if heard < 1.5 {
            loudPeak = loudNow + 4                       // ещё слушаем трек — середина шкалы
            target = loud < -75 ? 0 : 0.5
        } else {
            loudPeak = max(loudNow, loudPeak - Float(dt) * 0.35)
            target = loudNow < -75 ? 0 : max(0, min(1, 1 - (loudPeak - loudNow) / 12))
        }
        intensity += (target - intensity) * tau(target > intensity ? 0.4 : 1.2)
        return onsets
    }

    func energy(_ range: Range<Int>) -> Float {
        let slice = levels[range]
        return slice.reduce(0, +) / Float(max(slice.count, 1))
    }

    /// Центральная частота полосы, Гц.
    /// Диапазон эквалайзера — весь слышимый: 20 Гц … 20 кГц.
    static let lo = 20.0, hi = 20000.0

    static func hz(_ band: Int) -> Double {
        lo * pow(hi / lo, (Double(band) + 0.5) / Double(n))
    }

    /// Номер полосы, с которой начинается эта частота (для групп «бас / середина / верх»).
    static func edge(_ hz: Double) -> Int {
        max(0, min(n, Int((log(hz / lo) / log(hi / lo) * Double(n)).rounded())))
    }
    /// Удары баса: 35–110 Гц (бочка и бас-гитара).
    static let bassBands = edge(35)..<edge(110)
    /// До этой полосы — «низы» (подпрыгивание столбиков, цвет капель).
    static let lowEnd = edge(180)
    static let midEnd = edge(1700)

    static func label(_ hz: Double) -> String {
        if hz >= 10000 { return String(format: "%.0f kHz", hz / 1000) }
        if hz >= 1000 { return String(format: "%.1f kHz", hz / 1000) }
        return "\(Int(hz.rounded())) Hz"
    }

    /// Дробный номер полосы для частоты (для шкалы).
    static func band(for hz: Double) -> Double {
        log(hz / lo) / log(hi / lo) * Double(n) - 0.5
    }
}

// MARK: - Капли на воде

/// Капля: место (доли экрана), время, сила, частота (для подписи).
struct Drop {
    let x: CGFloat
    let y: CGFloat
    let born: Double
    let strength: CGFloat
    let hz: Double?
    let colorIndex: Int
}

final class DropField {
    private(set) var drops: [Drop] = []
    static let life = 4.5
    private var next: Double = 0
    /// Сколько капель появилось всего (для самотеста).
    private(set) var spawned = 0

    /// Возвращает капли, появившиеся в этом кадре.
    @discardableResult
    func spawn(_ onsets: [(band: Int, strength: Float)], time: Double, intensity: Float = 0.5) -> [Drop] {
        let i = CGFloat(intensity)
        drops.removeAll { time - $0.born > Self.life }
        // Вид сверху: капля падает в случайное место всей площади. Не чаще ~3 в секунду —
        // берём только самый сильный скачок кадра, удар баса даёт каплю крупнее.
        guard time >= next else { return [] }
        let before = drops.count
        // До двух капель за раз (бас и самый сильный звук сверху) — в разных местах экрана.
        // Громкая часть песни — до двух капель за раз и крупнее; тихая — по одной, мелкие.
        for o in onsets.sorted(by: { $0.strength > $1.strength }).prefix(intensity > 0.45 ? 2 : 1) {
            let bass = o.band < 0
            let strength = CGFloat(o.strength) * (bass ? 1.3 : 0.85) * (0.55 + 0.75 * i)
            guard strength > 0.2 + (1 - i) * 0.12 else { continue }
            drops.append(Drop(x: .random(in: 0.05...0.95), y: .random(in: 0.08...0.92), born: time,
                              strength: min(1.25, strength), hz: bass ? nil : LevelSmoother.hz(o.band),
                              colorIndex: bass ? 0 : o.band < LevelSmoother.lowEnd ? 0 : o.band < LevelSmoother.midEnd ? 1 : 2))
            // Пауза между каплями: в припеве короче, в куплете длиннее.
            next = time + (bass ? 0.15 : 0.2) * Double(1.8 - 1.0 * i)
            spawned += 1
        }
        let fresh = Array(drops[before...])
        if drops.count > 26 { drops.removeFirst(drops.count - 26) }
        return fresh
    }
}

// MARK: - Вид

/// Внешние часы для съёмки кадров (ImageRenderer не продвигает TimelineView). nil — обычный режим.
@MainActor
@Observable
final class PromoClock {
    static let shared = PromoClock()
    var t: Double?
}

struct AudioVisualizer: View {
    let style: VisualizerStyle
    let colors: CoverColors
    private var accents: [Color] { colors.accents }
    @State private var smoother = LevelSmoother()
    @State private var field = DropField()
    @State private var water = WaterSurface()

    var body: some View {
        if let t = PromoClock.shared.t {
            Canvas { (ctx: inout GraphicsContext, size: CGSize) in render(&ctx, size: size, t: t) }
        } else {
            live
        }
    }

    private var live: some View {
        // Во время игры — с частотой экрана (60 Гц, 120 Гц на ProMotion); сглаживание считается по времени,
        // поэтому реакция одинаковая. На паузе — 20 кадров/с: всё плавно гаснет и почти не нагружает Mac.
        TimelineView(.animation(minimumInterval: PlayerController.shared.isPlaying ? nil : 1.0 / 20)) { (timeline: TimelineViewDefaultContext) in
            Canvas { (ctx: inout GraphicsContext, size: CGSize) in
                render(&ctx, size: size, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func render(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let onsets = smoother.update(time: t)
        switch style {
        case .bars:
            drawBars(ctx, size)
            drawAxis(ctx, size)
            drawBarLabels(ctx, size, t: t)
        case .waves:
            drawWater(ctx, size, t: t, onsets: onsets)
        case .coverWaves:
            drawColorFlow(&ctx, size, t: t)
        }
    }

    // MARK: Эквалайзер

    private func barGeometry(_ size: CGSize) -> (w: CGFloat, gap: CGFloat, baseY: CGFloat, maxH: CGFloat) {
        let gap: CGFloat = 4
        let w = (size.width - gap * CGFloat(LevelSmoother.n - 1)) / CGFloat(LevelSmoother.n)
        // Шкала частот внизу, над столбиками — запас под подписи; кадр сам занимает только низ экрана.
        let baseY = size.height - 30
        return (w, gap, baseY, max(20, baseY - 30))
    }

    private func barCenterX(_ band: Double, _ size: CGSize) -> CGFloat {
        let g = barGeometry(size)
        return CGFloat(band) * (g.w + g.gap) + g.w / 2
    }

    private func drawBars(_ ctx: GraphicsContext, _ size: CGSize) {
        let g = barGeometry(size)
        let n = LevelSmoother.n
        // Столбик уже шага, со скруглением-капсулой; цвет идёт снизу вверх по цветам обложки.
        let bw = max(2, g.w * 0.62)
        let inset = (g.w - bw) / 2
        let gradient = Gradient(stops: [.init(color: accents[0].opacity(0.85), location: 0),
                                        .init(color: accents[1], location: 0.55),
                                        .init(color: accents[2], location: 1)])
        var heights = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            let low = LevelSmoother.lowEnd
            let boost = i < low ? CGFloat(smoother.kick) * 0.4 * (1 - CGFloat(i) / CGFloat(low)) : 0
            heights[i] = max(bw, min(1, pow(CGFloat(smoother.eq[i]), 2.0) + boost) * g.maxH)
        }
        func rect(_ i: Int) -> CGRect {
            CGRect(x: CGFloat(i) * (g.w + g.gap) + inset, y: g.baseY - heights[i], width: bw, height: heights[i])
        }
        let fill = GraphicsContext.Shading.linearGradient(gradient, startPoint: CGPoint(x: 0, y: g.baseY),
                                                          endPoint: CGPoint(x: 0, y: g.baseY - g.maxH))
        // Мягкое свечение под столбиками.
        var glow = ctx
        glow.addFilter(.blur(radius: 14))
        glow.opacity = 0.55
        for i in 0..<n { glow.fill(Path(roundedRect: rect(i), cornerRadius: bw / 2), with: fill) }
        // Сами столбики и блик по левому краю — «стекло».
        for i in 0..<n {
            let r = rect(i)
            ctx.fill(Path(roundedRect: r, cornerRadius: bw / 2), with: fill)
            ctx.fill(Path(roundedRect: CGRect(x: r.minX + bw * 0.18, y: r.minY + bw * 0.4, width: bw * 0.22,
                                              height: max(0, r.height - bw * 0.8)), cornerRadius: bw * 0.11),
                     with: .color(.white.opacity(0.18)))
        }
        // Огибающая по верхушкам — плавная линия.
        var curve = Path()
        for i in 0..<n {
            let p = CGPoint(x: CGFloat(i) * (g.w + g.gap) + g.w / 2, y: g.baseY - heights[i] - 4)
            if i == 0 { curve.move(to: p) } else {
                let prev = CGPoint(x: CGFloat(i - 1) * (g.w + g.gap) + g.w / 2, y: g.baseY - heights[i - 1] - 4)
                let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
                curve.addQuadCurve(to: mid, control: prev)
                if i == n - 1 { curve.addLine(to: p) }
            }
        }
        glow.stroke(curve, with: .color(.white.opacity(0.5)), lineWidth: 4)
        ctx.stroke(curve, with: .color(.white.opacity(0.35)), lineWidth: 1)
        // Пики — светящиеся точки, медленно опускаются.
        for i in 0..<n {
            let py = g.baseY - pow(CGFloat(smoother.eqPeaks[i]), 2.0) * g.maxH - 9
            let c = CGPoint(x: CGFloat(i) * (g.w + g.gap) + g.w / 2, y: py)
            let d = min(bw, 6)
            glow.fill(Circle().path(in: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)), with: .color(accents[2]))
            ctx.fill(Circle().path(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(.white.opacity(0.9)))
        }
    }

    /// Шкала внизу: 20 Гц … 20 кГц.
    private func drawAxis(_ ctx: GraphicsContext, _ size: CGSize) {
        let y = size.height - 12
        for hz in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
            // Крайние подписи (20 Гц, 20 кГц) сдвигаем внутрь, чтобы не обрезались краем экрана.
            let px = min(max(barCenterX(LevelSmoother.band(for: hz), size), 24), size.width - 28)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: y - 13)); p.addLine(to: CGPoint(x: px, y: y - 8)) },
                       with: .color(.white.opacity(0.35)), lineWidth: 1)
            ctx.draw(Text(hz >= 1000 ? "\(Int(hz / 1000)) kHz" : "\(Int(hz)) Hz")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45)),
                     at: CGPoint(x: px, y: y))
        }
    }

    private func drawBarLabels(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let g = barGeometry(size)
        for (band, entry) in smoother.labels {
            let alpha = max(0, 1 - (t - entry.t) / 0.6)
            let y = g.baseY - pow(CGFloat(smoother.eqPeaks[band]), 2.0) * g.maxH - 24
            pill(ctx, LevelSmoother.label(LevelSmoother.hz(band)), at: CGPoint(x: barCenterX(Double(band), size), y: max(14, y)),
                 size: size, alpha: alpha)
        }
    }


    // MARK: Вода

    private func drawWater(_ ctx: GraphicsContext, _ size: CGSize, t: Double, onsets: [(band: Int, strength: Float)]) {
        water.resize(to: size)
        let tones = accents.map { c -> SIMD3<Float> in
            let v = c.rgb
            return v * (0.95 / max(0.2, max(v.x, max(v.y, v.z))))     // яркий тон того же цвета
        }
        let i = smoother.intensity
        water.damping = 0.978 + 0.011 * i
        for d in field.spawn(onsets, time: t, intensity: i) {
            // Тон капли — по высоте звука: низы, середина (голос), верха — разные цвета обложки.
            let color: SIMD3<Float>
            let radius: Float
            if let hz = d.hz {
                let u = Float(log(hz / LevelSmoother.lo) / log(LevelSmoother.hi / LevelSmoother.lo))
                color = u < 0.5 ? mix(tones[0], tones[1], u * 2) : mix(tones[1], tones[2], (u - 0.5) * 2)
                radius = 4.0 - u * 1.4
            } else {
                color = tones[0]
                radius = 6.5
            }
            water.drop(x: d.x, y: d.y, strength: Float(d.strength), radius: radius * (0.8 + 0.5 * i), color: color)
        }
        water.advance(to: t)
        let deep = colors.background.rgb * 0.8 + SIMD3<Float>(repeating: 0.03)
        if let img = water.image(deep: deep, glow: smoother.kick + i * 0.35) {
            ctx.draw(Image(decorative: img, scale: 1).resizable().interpolation(.high), in: CGRect(origin: .zero, size: size))
        }
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ k: Float) -> SIMD3<Float> { a + (b - a) * min(1, max(0, k)) }

    // MARK: Цвета обложки — весь фон заливается и переливается цветами альбома в ритм

    private func drawColorFlow(_ ctx: inout GraphicsContext, _ size: CGSize, t: Double) {
        let full = CGRect(origin: .zero, size: size)
        let blend = colors.blend
        // Основа — самый большой по площади цвет обложки, приглушённый.
        ctx.fill(Path(full), with: .color(blend[0].opacity(0.55)))
        ctx.fill(Path(full), with: .color(.black.opacity(0.35)))

        // Пятна цветов: у каждого своя неровная форма, своя траектория и вращение.
        // Громкость своей части спектра (сглаженная) плавно раздувает пятно, ритм ускоряет течение.
        let minSide = min(size.width, size.height)
        var layer = ctx
        layer.addFilter(.blur(radius: minSide * 0.09))
        for k in 0..<min(blend.count, 5) {
            let kk = Double(k)
            let ph = smoother.flowPhase[k]
            let e = CGFloat(smoother.flowLevel[k])
            // Разные траектории: петли Лиссажу с разными частотами по осям.
            let fx = [1.0, 0.7, 1.3, 0.55, 0.9][k], fy = [0.8, 1.2, 0.6, 1.05, 1.4][k]
            let cx = size.width * (0.5 + 0.36 * CGFloat(sin(ph * fx * 0.35 + kk * 1.7)))
            let cy = size.height * (0.5 + 0.32 * CGFloat(cos(ph * fy * 0.3 + kk * 2.3)))
            let kick = CGFloat(smoother.kick)
            // Бас раздувает своё пятно и чуть толкает соседнее.
            let r = minSide * (0.26 + e * (k == 0 ? 0.62 : 0.45) + (k == 0 ? kick * 0.4 : k == 1 ? kick * 0.18 : kick * 0.06))
            let stretch = 1.15 + 0.35 * CGFloat(sin(ph * 0.21 + kk))
            let angle = ph * (k.isMultiple(of: 2) ? 0.12 : -0.09) + kk
            var blob = Path()
            let steps = 56
            for i in 0...steps {
                let a = Double(i) / Double(steps) * 2 * .pi
                // Края «текут»: несколько медленных гармоник с разными фазами.
                let wobble = 1 + (0.16 + (k == 0 ? Double(kick) * 0.12 : 0)) * sin(3 * a + ph * 0.8 + kk) + 0.09 * sin(5 * a - ph * 0.6 + kk * 2)
                    + 0.05 * sin(2 * a + ph * 1.1)
                let lx = CGFloat(cos(a) * wobble) * r * stretch, ly = CGFloat(sin(a) * wobble) * r
                let p = CGPoint(x: cx + lx * CGFloat(cos(angle)) - ly * CGFloat(sin(angle)),
                                y: cy + lx * CGFloat(sin(angle)) + ly * CGFloat(cos(angle)))
                if i == 0 { blob.move(to: p) } else { blob.addLine(to: p) }
            }
            blob.closeSubpath()
            layer.fill(blob, with: .radialGradient(Gradient(colors: [blend[k].opacity(0.9), blend[k].opacity(0.35), blend[k].opacity(0)]),
                                                   center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r * stretch * 1.15))
        }
        // На удар баса фон мягко наливается основным цветом (вместо белой вспышки).
        let kick = Double(smoother.kick)
        if kick > 0.02 {
            ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [blend[0].opacity(kick * 0.5), .clear]),
                                                       center: CGPoint(x: size.width / 2, y: size.height * 0.55),
                                                       startRadius: 0, endRadius: max(size.width, size.height) * 0.7))
        }
        // Затемнение к краям — обложка и кнопки читаются на любом фоне.
        ctx.fill(Path(full), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.55)]),
                                                   center: CGPoint(x: size.width / 2, y: size.height / 2),
                                                   startRadius: minSide * 0.35, endRadius: max(size.width, size.height) * 0.75))
    }

    // MARK: Подпись частоты

    private func pill(_ ctx: GraphicsContext, _ string: String, at p: CGPoint, size: CGSize, alpha: Double) {
        let text = ctx.resolve(Text(string)
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(.white.opacity(alpha)))
        let ts = text.measure(in: CGSize(width: 200, height: 40))
        let x = min(max(p.x, ts.width / 2 + 8), size.width - ts.width / 2 - 8)
        let bg = CGRect(x: x - ts.width / 2 - 6, y: p.y - ts.height / 2 - 3, width: ts.width + 12, height: ts.height + 6)
        ctx.fill(Path(roundedRect: bg, cornerRadius: bg.height / 2), with: .color(.black.opacity(0.45 * alpha)))
        ctx.draw(text, at: CGPoint(x: x, y: p.y))
    }
}

// MARK: - Выбор стиля

struct VisualizerStylePicker: View {
    @Bindable private var settings = VisualizerSettings.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(VisualizerStyle.allCases) { s in
                Button {
                    settings.style = s
                } label: {
                    Image(systemName: s.icon)
                        .font(.system(size: 12))
                        .frame(width: 30, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(settings.style == s ? 0.25 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.title)
            }
        }
        .foregroundStyle(.white)
    }
}
