// Рисует иконку 1024×1024: белая плашка, надпись «iPod / VIDEO CONVERTER», колесо из wheel-source.jpg.
// Запуск: swift Icon/make_icon.swift Icon/wheel-source.jpg Icon/AppIcon-1024.png
import AppKit

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!
let outPath = args[2]

// Колесо на исходнике 736×736 (координаты от левого верхнего угла).
let srcSize: CGFloat = 736
let srcCenter = CGPoint(x: 367, y: 368)
let srcRadius: CGFloat = 203

let S: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// Плашка по сетке иконок macOS: 824×824 с отступом 100.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
platePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [
    NSColor(white: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.92, alpha: 1),
])!.draw(in: platePath, angle: -90)
NSColor.black.withAlphaComponent(0.08).setStroke()
platePath.lineWidth = 2
platePath.stroke()

// Колесо: вырезаем круг из исходника.
let wheelRadius: CGFloat = 262
let wheelCenter = CGPoint(x: 512, y: 100 + 70 + wheelRadius) // снизу плашки
let k = wheelRadius / srcRadius
// Переводим центр исходника в координаты с началом снизу.
let srcCenterBL = CGPoint(x: srcCenter.x, y: srcSize - srcCenter.y)
let drawRect = NSRect(
    x: wheelCenter.x - srcCenterBL.x * k, y: wheelCenter.y - srcCenterBL.y * k,
    width: srcSize * k, height: srcSize * k)

let circle = NSBezierPath(ovalIn: NSRect(
    x: wheelCenter.x - wheelRadius, y: wheelCenter.y - wheelRadius,
    width: wheelRadius * 2, height: wheelRadius * 2))

NSGraphicsContext.saveGraphicsState()
let wheelShadow = NSShadow()
wheelShadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
wheelShadow.shadowBlurRadius = 10
wheelShadow.shadowOffset = NSSize(width: 0, height: -3)
wheelShadow.set()
NSColor.white.setFill()
circle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
circle.addClip()
src.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

NSColor.black.withAlphaComponent(0.07).setStroke()
circle.lineWidth = 2
circle.stroke()

// Текст сверху.
func drawCentered(_ text: String, font: NSFont, color: NSColor, kern: CGFloat, baselineY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
    let str = NSAttributedString(string: text, attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: (S - size.width + kern) / 2, y: baselineY))
}

let titleColor = NSColor(calibratedWhite: 0.17, alpha: 1)
let subColor = NSColor(calibratedWhite: 0.50, alpha: 1)
let wheelTop = wheelCenter.y + wheelRadius
drawCentered("iPod", font: .systemFont(ofSize: 118, weight: .bold), color: titleColor, kern: -2,
             baselineY: wheelTop + 80)
drawCentered("VIDEO CONVERTER", font: .systemFont(ofSize: 44, weight: .semibold), color: subColor, kern: 7,
             baselineY: wheelTop + 26)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("ok")
