#if os(macOS)
import AppKit

/// Текст для поддержки: версия приложения и macOS, iPod, что прошло и где упало, с текстом ошибки.
/// Пользователь копирует его одной кнопкой и пересылает разработчику.
enum SupportReport {
    struct Failure {
        let file: String
        let stage: String      // "convert" | "add to Music" | "add to TV"
        let error: String
    }

    static func text(model: IPodModel, kind: String, succeeded: [String], total: Int, failures: [Failure]) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = [
            "iPod Converter \(version) (\(build)) · macOS \(os) · \(machine())",
            "iPod: \(model.title) · \(kind)",
            "OK: \(succeeded.count) of \(total)" + (failures.isEmpty ? "" : " · failed: \(failures.count)"),
        ]
        if !failures.isEmpty {
            lines.append("")
            lines.append("Failed:")
            for f in failures { lines.append("• \(f.file) — \(f.stage): \(f.error)") }
        }
        if !succeeded.isEmpty {
            lines.append("")
            lines.append("Succeeded:")
            for s in succeeded { lines.append("• \(s)") }
        }
        return lines.joined(separator: "\n")
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Модель Mac, например «Mac15,9».
    static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

import SwiftUI

/// Кнопка «Скопировать для поддержки»; после нажатия на пару секунд — «Скопировано».
struct CopyReportButton: View {
    let text: String
    var compact = false
    @State private var copied = false

    var body: some View {
        Button {
            SupportReport.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            if compact {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            } else {
                Label(copied ? L.copied : L.copyForSupport, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
        }
        .buttonStyle(.link)
        .help(L.copyForSupportHelp)
    }
}

extension SupportReport {
    /// Отчёт по одному файлу.
    static func single(model: IPodModel, kind: String, file: URL, stage: String, error: String) -> String {
        text(model: model, kind: kind, succeeded: [], total: 1, failures: [.init(file: file.lastPathComponent, stage: stage, error: error)])
    }
}
#endif
