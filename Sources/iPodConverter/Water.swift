import AppKit
import SwiftUI

/// Поверхность воды для «Капель»: настоящая волновая модель (сетка высот), а не нарисованные круги.
/// Капля продавливает воду, волны расходятся, отражаются от краёв и складываются; свет бликует на гребнях.
/// Каждая капля ещё и «красит» воду своим цветом — цвет растекается и медленно тает.
final class WaterSurface {
    private(set) var w = 0, h = 0
    private var cur: [Float] = [], prev: [Float] = []
    private var inkR: [Float] = [], inkG: [Float] = [], inkB: [Float] = []
    /// Сглаженная «энергия» волн: где вода недавно волновалась — краска виднее (без провалов на узлах волны).
    private var energy: [Float] = []
    private var pixels: [UInt8] = []
    private var lastTime: Double = 0
    private var carry: Double = 0
    /// Шагов модели в секунду — задаёт скорость волн.
    static let stepsPerSecond = 110.0
    /// Затухание за шаг: волна пересекает экран и гаснет за ~3 с.
    static let damping: Float = 0.986

    /// Размер сетки под пропорции экрана (по ширине ~400 ячеек — дальше картинка сглаживается).
    func resize(to size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let nw = 400, nh = max(40, Int((CGFloat(nw) * size.height / size.width).rounded()))
        guard nw != w || nh != h else { return }
        w = nw; h = nh
        cur = .init(repeating: 0, count: w * h); prev = cur
        inkR = cur; inkG = cur; inkB = cur; energy = cur
        pixels = .init(repeating: 255, count: w * h * 4)
    }

    /// Капля в точке (0…1). strength 0…1.3, радиус больше у басов.
    func drop(x: CGFloat, y: CGFloat, strength: Float, radius: Float, color: SIMD3<Float>) {
        guard w > 0 else { return }
        let cx = Float(x) * Float(w - 1), cy = Float(y) * Float(h - 1)
        let reach = Int(radius * 3) + 1
        let ink = Int(radius * 5) + 1
        for yy in max(1, Int(cy) - ink)..<min(h - 1, Int(cy) + ink) {
            for xx in max(1, Int(cx) - ink)..<min(w - 1, Int(cx) + ink) {
                let dx = Float(xx) - cx, dy = Float(yy) - cy
                let d2 = dx * dx + dy * dy
                let i = yy * w + xx
                if abs(xx - Int(cx)) <= reach && abs(yy - Int(cy)) <= reach {
                    // Ямка с мягкими краями — из неё и пойдут кольца.
                    cur[i] -= strength * 10 * exp(-d2 / (radius * radius))
                }
                let k = strength * 0.7 * exp(-d2 / (radius * radius * 8))
                inkR[i] += (color.x - inkR[i]) * min(1, k)
                inkG[i] += (color.y - inkG[i]) * min(1, k)
                inkB[i] += (color.z - inkB[i]) * min(1, k)
            }
        }
    }

    /// Продвинуть модель до момента t (фиксированный шаг — одинаково на любой частоте кадров).
    func advance(to t: Double) {
        guard w > 0 else { return }
        if lastTime == 0 { lastTime = t }
        carry += min(0.1, max(0, t - lastTime)) * Self.stepsPerSecond
        lastTime = t
        var n = Int(carry)
        carry -= Double(n)
        n = min(n, 6)
        for _ in 0..<n { step() }
    }

    private func step() {
        let damp = Self.damping
        cur.withUnsafeBufferPointer { c in
            prev.withUnsafeMutableBufferPointer { p in
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 1..<(w - 1) {
                        let i = row + x
                        let v = (c[i - 1] + c[i + 1] + c[i - w] + c[i + w]) * 0.5 - p[i]
                        p[i] = v * damp
                    }
                }
            }
        }
        swap(&cur, &prev)
        cur.withUnsafeBufferPointer { c in
            energy.withUnsafeMutableBufferPointer { e in
                for i in 0..<e.count { e[i] = e[i] * 0.95 + abs(c[i]) * 0.05 }
            }
        }
        // Краска расплывается, как краситель в воде, и медленно тает.
        stepCount += 1
        if stepCount % 2 == 0 {
            diffuse(&inkR); diffuse(&inkG); diffuse(&inkB)
        }
    }

    private var stepCount = 0
    private var scratch: [Float] = []

    private func diffuse(_ a: inout [Float]) {
        if scratch.count != a.count { scratch = a }
        scratch.withUnsafeMutableBufferPointer { o in
            a.withUnsafeBufferPointer { s in
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 1..<(w - 1) {
                        let i = row + x
                        o[i] = (s[i] * 4 + s[i - 1] + s[i + 1] + s[i - w] + s[i + w]) * 0.125 * 0.996
                    }
                }
            }
        }
        swap(&a, &scratch)
    }

    /// Картинка поверхности: глубина + краска капель + свет на склонах волн + блики.
    func image(deep: SIMD3<Float>, glow: Float) -> CGImage? {
        guard w > 0 else { return nil }
        let lx: Float = -0.55, ly: Float = -0.83          // свет сверху-слева
        pixels.withUnsafeMutableBufferPointer { px in
            cur.withUnsafeBufferPointer { c in
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * w + x
                        // Наклон по соседям через одну ячейку — гасит мелкую «сеточную» рябь.
                        let xl = max(0, x - 2), xr = min(w - 1, x + 2)
                        let yu = max(0, y - 2), yd = min(h - 1, y + 2)
                        let sx = (c[y * w + xr] - c[y * w + xl]) * 0.5
                        let sy = (c[yd * w + x] - c[yu * w + x]) * 0.5
                        // Преломление: дно/небо (вертикальный градиент) видно со сдвигом по наклону волны —
                        // так рябь «играет» светом даже на тёмной воде.
                        let ry = max(0, min(1, (Float(y) + sy * 14) / Float(h)))
                        let env = 1.0 + 0.9 * (1 - ry) * (1 - ry)
                        let slope = (sx * lx + sy * ly) * 0.5
                        let lit = slope > 0 ? slope / (1 + slope) * 0.32 : 0
                        // Тень на склоне — мягким множителем, без чёрных «трещин».
                        let shade = slope < 0 ? max(0.72, 1 + slope / (1 - slope) * 0.5) : 1
                        let hi = max(0, slope - 0.25)
                        let spec = min(0.6, hi * hi * 1.2)
                        // Краска видна на гребнях и в ряби, в спокойной воде — лишь лёгкий оттенок.
                        let wave = min(1, energy[i] * 1.4)
                        let inkA = 0.1 + wave * 0.85 + glow * 0.12
                        var r = deep.x * env + inkR[i] * inkA + lit * (0.55 + inkR[i]) + spec * (0.7 + inkR[i] * 0.3)
                        var g = deep.y * env + inkG[i] * inkA + lit * (0.55 + inkG[i]) + spec * (0.7 + inkG[i] * 0.3)
                        var b = deep.z * env + inkB[i] * inkA + lit * (0.55 + inkB[i]) + spec * (0.7 + inkB[i] * 0.3)
                        r *= shade; g *= shade; b *= shade
                        r = min(1, max(0, r)); g = min(1, max(0, g)); b = min(1, max(0, b))
                        let o = i * 4
                        px[o] = UInt8(r * 255); px[o + 1] = UInt8(g * 255); px[o + 2] = UInt8(b * 255); px[o + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension Color {
    /// Компоненты RGB 0…1 (для смешивания цветов в модели воды).
    var rgb: SIMD3<Float> {
        let c = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        return SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }
}
