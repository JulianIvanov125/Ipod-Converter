import AppKit
import Observation
import SwiftUI

// MARK: - Выбор темы

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L.t("System", "Как в системе", "Як у системі", "Як у сістэме")
        case .light: L.t("Light", "Светлая", "Світла", "Светлая")
        case .dark: L.t("Dark", "Тёмная", "Темна", "Цёмная")
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// Тема запоминается и применяется ко всему приложению через NSApp.appearance —
/// так переключаются и окна, и всплывающие меню, и диалоги.
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    var choice: AppAppearance {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: "appearance")
            apply()
        }
    }

    private init() {
        choice = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    func apply() {
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Палитра

/// Цвета, которые сами подстраиваются под светлую/тёмную тему.
/// В тёмной теме карточки файлов заметно светлее фона (серые), чтобы текст на них легко читался,
/// а то, что в светлой теме «поднято» (белые плашки внутри карточек, выбранная вкладка, мини-плеер), — ещё светлее.
enum Theme {
    /// Фон окна.
    static let bg = dynamic(light: .white, dark: rgb(0x1E1E20))
    /// Карточки и строки файлов.
    static let card = dynamic(light: rgb(0xF6F6F8), dark: rgb(0x3A3A3D))
    /// Поднятые элементы: плашки «Сейчас/После», выбранная вкладка, мини-плеер, всплывающие окна.
    static let raised = dynamic(light: .white, dark: rgb(0x4A4A4F))
    /// Основной текст.
    static let ink = dynamic(light: rgb(0x1C1C1E), dark: rgb(0xF5F5F7))
    /// Тонкие линии и рамки.
    static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.12))

    /// Полупрозрачная подложка (кнопки-кружки, бейджи, рамки): чёрная в светлой теме, белая — в тёмной.
    static func tint(_ opacity: Double) -> Color {
        dynamic(light: NSColor.black.withAlphaComponent(opacity),
                dark: NSColor.white.withAlphaComponent(min(opacity * 1.6, 1)))
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Меню темы

struct AppearanceMenu: View {
    @Bindable private var settings = AppearanceSettings.shared

    var body: some View {
        Menu {
            ForEach(AppAppearance.allCases) { a in
                Button {
                    settings.choice = a
                } label: {
                    // Галочка у текущего выбора; иконку темы показываем у остальных.
                    Label(a.title, systemImage: settings.choice == a ? "checkmark" : a.icon)
                }
            }
        } label: {
            Image(systemName: settings.choice.icon)
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(L.appearance + ": " + settings.choice.title)
    }
}
