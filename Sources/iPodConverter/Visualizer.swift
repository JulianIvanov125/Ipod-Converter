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
    private var prevRaw = [Float](repeating: 0, count: n)
    private var cooldown = [Double](repeating: 0, count: n)
    private var prevBass: Float = 0
    private var bassCooldown: Double = 0
    /// Толчок на удар баса, 0…1, гаснет за ~0.4 с.
    private(set) var pulse: Float = 0
    /// Цвета обложки: части спектра, медленная громкость каждой и накопленная «фаза течения».
    static let flowGroups: [Range<Int>] = [0..<6, 6..<14, 14..<24, 24..<36, 36..<n]
    private(set) var flowLevel = [Float](repeating: 0, count: 5)
    private(set) var flowPhase = [Double](repeating: 0, count: 5)
    private var lastTime: Double = 0
    /// Удар баса для цвета: быстро нарастает и гаснет ~0.5 с — толчок без вспышки.
    private(set) var kick: Float = 0
    /// Подписи частот на скачках (эквалайзер): полоса → (время, уровень).
    private(set) var labels: [Int: (t: Double, v: Float)] = [:]

    /// Скачки этого кадра: полоса и сила (0…1); band == -1 — удар баса.
    func update(time: Double) -> [(band: Int, strength: Float)] {
        let raw = AudioAnalyzer.shared.snapshot()
        var onsets: [(Int, Float)] = []
        for i in 0..<Self.n {
            let v = raw[i]
            // Быстрая атака, спад средний — живо, но без дрожи на месте.
            levels[i] = v > levels[i] ? levels[i] + (v - levels[i]) * 0.75 : levels[i] * 0.8 + v * 0.2
            peaks[i] = max(levels[i], peaks[i] - 0.012)
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
        let bass = raw[0..<8].reduce(0, +) / 8
        var bassHit = false
        if bass - prevBass > 0.06, bass > 0.33, time > bassCooldown {
            bassHit = true
            bassCooldown = time + 0.18
            pulse = min(1, pulse + 0.9)
        }
        pulse *= 0.9
        prevBass = bass

        // Резкий звук «размазывается» по соседним полосам — склеиваем соседние скачки
        // в одну каплю на самой громкой частоте. При ударе баса низ отдельно не считаем.
        var merged: [(Int, Float)] = []
        for o in onsets.sorted(by: { $0.0 < $1.0 }) {
            if bassHit && o.0 < 12 { continue }
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
            let v = levels[i]
            guard v > 0.45, v >= levels[i - 1], v >= levels[i + 1] else { continue }
            let around = (levels[max(0, i - 3)] + levels[min(Self.n - 1, i + 3)]) / 2
            guard v - around > 0.08, !labels.keys.contains(where: { abs($0 - i) < 4 && $0 != i }) else { continue }
            labels[i] = (time, v)
        }
        labels = labels.filter { time - $0.value.t < 0.6 }

        // Течение цвета: громкость сглажена на ~1 с (без мерцания), а в ритм ускоряется движение.
        let dt = lastTime == 0 ? 0 : min(0.1, max(0, time - lastTime))
        lastTime = time
        for k in 0..<Self.flowGroups.count {
            let e = energy(Self.flowGroups[k])
            // Низы реагируют быстрее и сильнее, верх — спокойнее.
            let attack: Float = k == 0 ? 0.35 : k == 1 ? 0.22 : 0.12
            let release: Float = k == 0 ? 0.12 : 0.05
            flowLevel[k] += (e - flowLevel[k]) * (e > flowLevel[k] ? attack : release)
            flowPhase[k] += dt * (0.18 + Double(flowLevel[k]) * 1.6 + Double(kick) * (k == 0 ? 3.5 : k == 1 ? 1.8 : 0.8))
        }
        kick += (pulse - kick) * (pulse > kick ? 0.7 : 0.14)
        return onsets
    }

    func energy(_ range: Range<Int>) -> Float {
        let slice = levels[range]
        return slice.reduce(0, +) / Float(max(slice.count, 1))
    }

    /// Центральная частота полосы, Гц.
    static func hz(_ band: Int) -> Double {
        40 * pow(16000.0 / 40, (Double(band) + 0.5) / Double(n))
    }

    static func label(_ hz: Double) -> String {
        if hz >= 10000 { return String(format: "%.0f kHz", hz / 1000) }
        if hz >= 1000 { return String(format: "%.1f kHz", hz / 1000) }
        return "\(Int(hz.rounded())) Hz"
    }

    /// Дробный номер полосы для частоты (для шкалы).
    static func band(for hz: Double) -> Double {
        log(hz / 40) / log(16000.0 / 40) * Double(n) - 0.5
    }
}

// MARK: - Капли на воде

/// Капля: место (доли экрана), время, сила, частота (для подписи).
private struct Drop {
    let x: CGFloat
    let y: CGFloat
    let born: Double
    let strength: CGFloat
    let hz: Double?
    let colorIndex: Int
}

final class DropField {
    fileprivate private(set) var drops: [Drop] = []
    static let life = 4.5
    private var next: Double = 0
    /// Сколько капель появилось всего (для самотеста).
    private(set) var spawned = 0

    func spawn(_ onsets: [(band: Int, strength: Float)], time: Double) {
        drops.removeAll { time - $0.born > Self.life }
        // Вид сверху: капля падает в случайное место всей площади. Не чаще ~3 в секунду —
        // берём только самый сильный скачок кадра, удар баса даёт каплю крупнее.
        guard time >= next, let o = onsets.max(by: { $0.strength < $1.strength }) else { return }
        let bass = o.band < 0
        let strength = CGFloat(o.strength) * (bass ? 1.3 : 0.85)
        guard strength > 0.2 else { return }
        drops.append(Drop(x: .random(in: 0.05...0.95), y: .random(in: 0.08...0.92), born: time,
                          strength: min(1.25, strength), hz: bass ? nil : LevelSmoother.hz(o.band),
                          colorIndex: bass ? 0 : o.band < 12 ? 0 : o.band < 30 ? 1 : 2))
        next = time + (bass ? 0.15 : 0.25)
        spawned += 1
        if drops.count > 20 { drops.removeFirst(drops.count - 20) }
    }
}

// MARK: - Вид

struct AudioVisualizer: View {
    let style: VisualizerStyle
    let colors: CoverColors
    private var accents: [Color] { colors.accents }
    @State private var smoother = LevelSmoother()
    @State private var field = DropField()

    var body: some View {
        TimelineView(.animation) { (timeline: TimelineViewDefaultContext) in
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
            field.spawn(onsets, time: t)
            drawDrops(ctx, size, t: t, colors: [.white, Color(red: 0.45, green: 0.75, blue: 1), Color(red: 0.7, green: 0.55, blue: 1)])
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
        let gradient = Gradient(colors: [accents[0], accents[1], accents[2]])
        for i in 0..<LevelSmoother.n {
            let x = CGFloat(i) * (g.w + g.gap)
            // Контраст: тихое ниже, громкое выше; низы подпрыгивают на ударе баса.
            let boost = i < 12 ? CGFloat(smoother.kick) * 0.4 * (1 - CGFloat(i) / 12) : 0
            let h = max(3, min(1, pow(CGFloat(smoother.levels[i]), 1.5) * 1.4 + boost) * g.maxH)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: g.baseY - h, width: g.w, height: h), cornerRadius: min(g.w / 2, 4)),
                     with: .linearGradient(gradient, startPoint: CGPoint(x: x, y: g.baseY), endPoint: CGPoint(x: x, y: g.baseY - g.maxH)))
            let py = g.baseY - min(1, pow(CGFloat(smoother.peaks[i]), 1.5) * 1.4) * g.maxH - 5
            ctx.fill(Path(roundedRect: CGRect(x: x, y: py, width: g.w, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.85)))
        }
    }

    /// Шкала внизу: 50 Гц … 10 кГц.
    private func drawAxis(_ ctx: GraphicsContext, _ size: CGSize) {
        let y = size.height - 12
        for hz in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            let px = barCenterX(LevelSmoother.band(for: hz), size)
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
            let y = g.baseY - min(1, pow(CGFloat(smoother.peaks[band]), 1.5) * 1.4) * g.maxH - 24
            pill(ctx, LevelSmoother.label(LevelSmoother.hz(band)), at: CGPoint(x: barCenterX(Double(band), size), y: max(14, y)),
                 size: size, alpha: alpha)
        }
    }

    // MARK: Капли на воде

    private func drawDrops(_ ctx: GraphicsContext, _ size: CGSize, t: Double, colors: [Color]) {
        // Вид на воду сверху: круги расходятся широко, почти через весь экран, и медленно тают.
        let reach = hypot(size.width, size.height) * 0.45
        // Удар баса подсвечивает все круги разом — пульс в ритм, гаснет плавно.
        let kick = Double(smoother.kick)
        var glow = ctx
        glow.addFilter(.blur(radius: 6))
        for d in field.drops {
            let age = t - d.born
            let life = age / DropField.life
            guard life < 1 else { continue }
            let c = colors[d.colorIndex % colors.count]
            let center = CGPoint(x: d.x * size.width, y: d.y * size.height)
            // Плавное проявление за 0.25 с и мягкое затухание — без вспышек и мерцания.
            let appear = min(1, age / 0.25)
            let fade = pow(1 - life, 2)
            let bass = d.hz == nil
            for ring in 0..<(bass ? 4 : 3) {
                let ra = age - Double(ring) * (bass ? 0.22 : 0.35)
                guard ra > 0 else { continue }
                // Замедление, как у настоящей волны: быстро вначале, потом еле ползёт.
                let r = CGFloat(1 - exp(-ra * (bass ? 1.1 : 0.75))) * reach * (0.45 + d.strength * 0.55) + 2
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                let alpha = min(0.85, 0.38 * Double(d.strength) * appear * fade * (1 - Double(ring) * 0.22) * (1 + kick * 1.5))
                let width = (bass ? 2.4 : 1.5) - CGFloat(ring) * 0.3
                glow.stroke(Circle().path(in: rect), with: .color(c.opacity(alpha * 0.6)), lineWidth: width + 4)
                ctx.stroke(Circle().path(in: rect), with: .color(c.opacity(alpha)), lineWidth: width)
            }
        }
    }

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
