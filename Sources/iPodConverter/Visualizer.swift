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
    /// Подписи частот на скачках (эквалайзер): полоса → (время, уровень).
    private(set) var labels: [Int: (t: Double, v: Float)] = [:]

    /// Скачки этого кадра: полоса и сила (0…1); band == -1 — удар баса.
    func update(time: Double) -> [(band: Int, strength: Float)] {
        let raw = AudioAnalyzer.shared.snapshot()
        var onsets: [(Int, Float)] = []
        for i in 0..<Self.n {
            let v = raw[i]
            levels[i] = v > levels[i] ? levels[i] + (v - levels[i]) * 0.6 : levels[i] * 0.88 + v * 0.12
            peaks[i] = max(levels[i], peaks[i] - 0.012)
            // Скачок: резкий рост в полосе, громче порога, не чаще раза в 0.3 с на полосу.
            let rise = v - prevRaw[i]
            if rise > 0.14, v > 0.42, time > cooldown[i] {
                onsets.append((i, min(1, v)))
                cooldown[i] = time + 0.3
                // Соседние полосы тоже «гасим», чтобы одна нота не давала пачку капель.
                for k in max(0, i - 2)...min(Self.n - 1, i + 2) { cooldown[k] = max(cooldown[k], time + 0.2) }
            }
            prevRaw[i] = v
        }
        let bass = raw[0..<8].reduce(0, +) / 8
        var bassHit = false
        if bass - prevBass > 0.08, bass > 0.4, time > bassCooldown {
            bassHit = true
            bassCooldown = time + 0.25
            pulse = min(1, pulse + 0.7)
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
    static let life = 2.4

    func spawn(_ onsets: [(band: Int, strength: Float)], time: Double) {
        for o in onsets {
            if o.band < 0 {
                // Удар баса — большая капля около центра.
                drops.append(Drop(x: 0.5 + .random(in: -0.08...0.08), y: 0.55 + .random(in: -0.05...0.05), born: time,
                                  strength: CGFloat(o.strength) * 1.4, hz: nil, colorIndex: 0))
            } else {
                // Чем выше частота — тем правее; высота — случайная по «поверхности».
                let u = CGFloat(o.band) / CGFloat(LevelSmoother.n - 1)
                drops.append(Drop(x: 0.08 + u * 0.84, y: .random(in: 0.35...0.8), born: time,
                                  strength: CGFloat(o.strength), hz: LevelSmoother.hz(o.band),
                                  colorIndex: o.band < 12 ? 0 : o.band < 30 ? 1 : 2))
            }
        }
        drops.removeAll { time - $0.born > Self.life }
        if drops.count > 60 { drops.removeFirst(drops.count - 60) }
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
        let baseY = size.height * 0.78
        return (w, gap, baseY, baseY - 8)
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
            let h = max(3, CGFloat(smoother.levels[i]) * g.maxH)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: g.baseY - h, width: g.w, height: h), cornerRadius: min(g.w / 2, 4)),
                     with: .linearGradient(gradient, startPoint: CGPoint(x: x, y: g.baseY), endPoint: CGPoint(x: x, y: g.baseY - g.maxH)))
            let py = g.baseY - CGFloat(smoother.peaks[i]) * g.maxH - 5
            ctx.fill(Path(roundedRect: CGRect(x: x, y: py, width: g.w, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.85)))
            ctx.fill(Path(roundedRect: CGRect(x: x, y: g.baseY + 4, width: g.w, height: h * 0.25), cornerRadius: min(g.w / 2, 4)),
                     with: .linearGradient(Gradient(colors: [accents[0].opacity(0.3), .clear]),
                                           startPoint: CGPoint(x: x, y: g.baseY), endPoint: CGPoint(x: x, y: g.baseY + h * 0.25)))
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
            let y = g.baseY - CGFloat(smoother.peaks[band]) * g.maxH - 24
            pill(ctx, LevelSmoother.label(LevelSmoother.hz(band)), at: CGPoint(x: barCenterX(Double(band), size), y: max(14, y)),
                 size: size, alpha: alpha)
        }
    }

    // MARK: Капли на воде

    private func drawDrops(_ ctx: GraphicsContext, _ size: CGSize, t: Double, colors: [Color]) {
        // Спокойная «поверхность»: едва заметные горизонтальные блики.
        for k in 0..<5 {
            let y = size.height * (0.4 + CGFloat(k) * 0.12)
            let a = 0.05 + 0.03 * sin(t * 0.7 + Double(k))
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                       with: .linearGradient(Gradient(colors: [.clear, .white.opacity(a), .clear]),
                                             startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                       lineWidth: 1)
        }

        let maxR = min(size.width, size.height) * 0.45
        for d in field.drops {
            let age = t - d.born
            let life = age / DropField.life
            guard life < 1 else { continue }
            let c = colors[d.colorIndex % colors.count]
            let center = CGPoint(x: d.x * size.width, y: d.y * size.height)
            let fade = pow(1 - life, 1.6)

            // Три расходящихся кольца с задержкой; эллипс — вид на воду под углом.
            for ring in 0..<3 {
                let ra = age - Double(ring) * 0.16
                guard ra > 0 else { continue }
                let r = CGFloat(1 - exp(-ra * 1.6)) * maxR * (0.45 + d.strength * 0.6)
                let rect = CGRect(x: center.x - r, y: center.y - r * 0.38, width: r * 2, height: r * 0.76)
                let alpha = Double(fade) * Double(d.strength) * (1 - Double(ring) * 0.28)
                let width = max(0.6, (3.2 - CGFloat(ring)) * CGFloat(1 - life))
                var glow = ctx
                glow.addFilter(.blur(radius: 5))
                glow.stroke(Ellipse().path(in: rect), with: .color(c.opacity(alpha * 0.7)), lineWidth: width + 3)
                ctx.stroke(Ellipse().path(in: rect), with: .color(c.opacity(alpha)), lineWidth: width)
            }
            // Сам «всплеск» в первые доли секунды.
            if age < 0.25 {
                let s = CGFloat(1 - age / 0.25)
                let r = 6 + d.strength * 10 * s
                ctx.fill(Ellipse().path(in: CGRect(x: center.x - r, y: center.y - r * 0.5, width: r * 2, height: r)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(Double(s)), c.opacity(0)]),
                                               center: center, startRadius: 0, endRadius: r))
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

        // Пятна цветов: каждое плавает по своей траектории, размер — от громкости своей части спектра.
        let groups: [Range<Int>] = [0..<6, 6..<14, 14..<24, 24..<36, 36..<LevelSmoother.n]
        let minSide = min(size.width, size.height)
        let pulse = CGFloat(smoother.pulse)
        var layer = ctx
        layer.addFilter(.blur(radius: minSide * 0.1))
        for k in 0..<min(blend.count, 5) {
            let kk = Double(k)
            let e = CGFloat(smoother.energy(groups[k]))
            let cx = size.width * (0.5 + 0.38 * CGFloat(sin(t * (0.07 + kk * 0.023) + kk * 1.7)))
            let cy = size.height * (0.5 + 0.34 * CGFloat(cos(t * (0.06 + kk * 0.019) + kk * 2.3)))
            let r = minSide * (0.32 + e * 0.38 + (k == 0 ? pulse * 0.18 : 0))
            let rect = CGRect(x: cx - r * 1.25, y: cy - r, width: r * 2.5, height: r * 2)
            layer.fill(Ellipse().path(in: rect),
                       with: .radialGradient(Gradient(colors: [blend[k].opacity(0.95), blend[k].opacity(0)]),
                                             center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r * 1.25))
        }
        // На удар баса — лёгкая вспышка всего фона.
        if pulse > 0.02 {
            ctx.fill(Path(full), with: .color(.white.opacity(Double(pulse) * 0.08)))
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
