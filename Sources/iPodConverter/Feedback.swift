import AppKit
import Observation
import SwiftUI

/// «Сообщить о проблеме»: пользователь описывает, что случилось, видит сведения для диагностики
/// и отправляет на GitHub (issue) или письмом разработчику (с файлом журнала во вложении).
@MainActor
@Observable
final class FeedbackCenter {
    static let shared = FeedbackCenter()
    static let windowID = "feedback"
    static let repo = "JulianIvanov125/Ipod-Converter"
    static let email = "ivanovulian@gmail.com"

    enum Kind: String, CaseIterable, Identifiable {
        case bug, idea, question
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bug: L.fbBug
            case .idea: L.fbIdea
            case .question: L.fbQuestion
            }
        }
        var tag: String {
            switch self {
            case .bug: "Bug"
            case .idea: "Idea"
            case .question: "Question"
            }
        }
    }

    var kind: Kind = .bug
    var text = ""
    var attachDiagnostics = true
    /// Отчёт об ошибке, с которой открыли окно (кнопка рядом с ошибкой).
    var report: String?

    private init() {}

    /// Открыть окно с отчётом об ошибке.
    func prepare(report: String?) {
        self.report = report
        if report != nil { kind = .bug; attachDiagnostics = true }
    }

    /// Сведения для диагностики: версия, macOS, Mac, модели iPod (без имён), отчёт, конец журнала.
    func diagnostics(logLines: Int = 60) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var parts = ["iPod Converter \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(SupportReport.machine())"]
        let ipods = IPodDetector.shared.devices.map { d in
            d.model.title + (d.freeBytes.map { ", free \(Fmt.bytes($0))" } ?? "")
        }
        parts.append("iPods: " + (ipods.isEmpty ? "none connected" : ipods.joined(separator: "; ")))
        if let report { parts.append(""); parts.append(AppLog.sanitize(report)) }
        let log = AppLog.tail(logLines)
        if !log.isEmpty { parts.append(""); parts.append("Log (last \(logLines) lines):"); parts.append(log) }
        return parts.joined(separator: "\n")
    }

    private var title: String {
        let first = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return "[\(kind.tag)] " + (first.isEmpty ? (report == nil ? "Feedback" : "Conversion error") : String(first.prefix(80)))
    }

    /// Новый issue на GitHub с заполненным текстом. Ссылка не может быть бесконечной —
    /// журнал урезается, пока всё не поместится (~7500 символов).
    func openGitHub() {
        NSWorkspace.shared.open(githubURL())
        AppLog.info("Feedback: opened GitHub issue form (\(kind.tag))")
    }

    func githubURL() -> URL {
        var lines = 60
        while true {
            var body = text.isEmpty ? "_Describe what happened_" : text
            if attachDiagnostics {
                body += "\n\n<details><summary>Diagnostics</summary>\n\n```\n\(diagnostics(logLines: lines))\n```\n</details>"
            }
            var c = URLComponents(string: "https://github.com/\(Self.repo)/issues/new")!
            c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            if let url = c.url, url.absoluteString.count <= 7500 || lines == 0 { return url }
            lines = lines > 10 ? lines - 10 : 0
        }
    }

    /// Письмо через «Почту» (журнал во вложении); если почтовая программа не настроена — mailto.
    func openEmail() {
        var body = text
        if attachDiagnostics { body += "\n\n---\n" + diagnostics(logLines: 30) }
        let subject = "iPod Converter: " + title
        var items: [Any] = [body]
        if attachDiagnostics, FileManager.default.fileExists(atPath: AppLog.file.path) { items.append(AppLog.file) }
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: items) {
            mail.recipients = [Self.email]
            mail.subject = subject
            mail.perform(withItems: items)
        } else {
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = Self.email
            c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: String(body.prefix(6000)))]
            if let url = c.url { NSWorkspace.shared.open(url) }
        }
        AppLog.info("Feedback: opened email (\(kind.tag))")
    }

    static func revealLog() {
        if FileManager.default.fileExists(atPath: AppLog.file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
        } else {
            try? FileManager.default.createDirectory(at: AppLog.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(AppLog.folder)
        }
    }
}

struct FeedbackView: View {
    @Bindable private var fb = FeedbackCenter.shared
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.fbTitle).font(.system(size: 17, weight: .semibold))
            Picker("", selection: $fb.kind) {
                ForEach(FeedbackCenter.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $fb.text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if fb.text.isEmpty {
                    Text(fb.kind == .bug ? L.fbPlaceholderBug : L.fbPlaceholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tint(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.tint(0.12)))

            Toggle(L.fbAttach, isOn: $fb.attachDiagnostics)
                .font(.system(size: 12))
            if fb.attachDiagnostics {
                DisclosureGroup(L.fbWhatIsSent, isExpanded: $showDetails) {
                    ScrollView {
                        Text(fb.diagnostics())
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                }
                .font(.system(size: 12))
            }

            Text(L.fbPrivacy)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button { FeedbackCenter.revealLog() } label: { Label(L.fbShowLog, systemImage: "doc.text.magnifyingglass") }
                Spacer()
                Button { fb.openEmail() } label: { Label(L.fbEmail, systemImage: "envelope") }
                Button { fb.openGitHub() } label: { Label(L.fbGitHub, systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 520)
        .frame(minHeight: 420)
    }
}

/// Кнопка «Сообщить» рядом с ошибкой: окно отзыва с уже приложенным отчётом.
struct ReportProblemButton: View {
    let report: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            FeedbackCenter.shared.prepare(report: report)
            openWindow(id: FeedbackCenter.windowID)
        } label: {
            Label(L.fbReportShort, systemImage: "exclamationmark.bubble").font(.system(size: 11))
        }
        .buttonStyle(.link)
        .help(L.fbReportHelp)
    }
}

/// Меню «Помощь»: сообщить о проблеме, показать журнал.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L.fbMenu) {
                FeedbackCenter.shared.prepare(report: nil)
                openWindow(id: FeedbackCenter.windowID)
            }
            Button(L.fbShowLog) { FeedbackCenter.revealLog() }
            Divider()
            Button("GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(FeedbackCenter.repo)")!)
            }
        }
    }
}
