import AppKit
import SwiftUI

// MARK: - Стекло (Liquid Glass на macOS 26+, материалы — на старых системах)

/// Включено ли стекло: настройка пользователя и системное «Уменьшить прозрачность».
@MainActor
enum GlassMode {
    static var isOn: Bool {
        AppearanceSettings.shared.glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

extension View {
    /// Прозрачное стекло (Clear Glass) в форме shape; без стекла — обычная плашка `solid`.
    @ViewBuilder
    func clearGlass<S: Shape>(in shape: S, solid: Color = Theme.raised, tint: Color? = nil) -> some View {
        if GlassMode.isOn {
            if #available(macOS 26.0, *) {
                self.glassEffect(Glass.clear.tint(tint), in: shape)
            } else {
                self.background(.ultraThinMaterial, in: shape)
            }
        } else {
            self.background(shape.fill(solid))
        }
    }

    /// Плавающие панели (плееры) поверх списка: матовое стекло с подложкой — кнопки под ним не просвечивают.
    @ViewBuilder
    func frostedGlass<S: Shape>(in shape: S, solid: Color = Theme.raised) -> some View {
        if GlassMode.isOn {
            if #available(macOS 26.0, *) {
                self.background(shape.fill(solid.opacity(0.55)))
                    .glassEffect(Glass.regular, in: shape)
            } else {
                self.background(shape.fill(solid.opacity(0.55)))
                    .background(.regularMaterial, in: shape)
            }
        } else {
            self.background(shape.fill(solid))
        }
    }

    /// Полупрозрачная заливка карточек: при стекле сквозь неё видно размытый фон окна.
    func glassCard<S: InsettableShape>(_ shape: S, solid: Color) -> some View {
        background(shape.fill(GlassMode.isOn ? Theme.glassCard : solid))
            .overlay(shape.strokeBorder(GlassMode.isOn ? Theme.glassEdge : Theme.hairline))
    }
}

/// Фон окна: размытый рабочий стол позади окна + лёгкая подложка для читаемости.
struct WindowBackground: View {
    @Bindable private var settings = AppearanceSettings.shared

    var body: some View {
        Group {
            if GlassMode.isOn {
                ZStack {
                    BehindWindowBlur()
                    Theme.glassTint
                }
            } else {
                Theme.bg
            }
        }
        .ignoresSafeArea()
        .background(WindowTransparency(transparent: GlassMode.isOn))
    }
}

/// NSVisualEffectView, размывающий то, что позади окна.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Делает само окно непрозрачным/прозрачным (иначе позади SwiftUI-фона рисуется сплошной цвет окна).
private struct WindowTransparency: NSViewRepresentable {
    let transparent: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isOpaque = !transparent
            w.backgroundColor = transparent ? .clear : .windowBackgroundColor
        }
    }
}
