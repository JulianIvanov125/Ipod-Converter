import AppKit
import UserNotifications

/// Системные уведомления macOS со звуком. Клик по уведомлению открывает файл в Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, fileURL: URL) {
        shared.post(title: title, body: body, fileURL: fileURL)
    }

    private func post(title: String, body: String, fileURL: URL) {
        guard available else { return fallback(title: title, body: body) }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                self.fallback(title: title, body: body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["path": fileURL.path]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if error != nil { self.fallback(title: title, body: body) }
            }
        }
    }

    /// Запасной вариант, если уведомления не разрешены: AppleScript + системный звук.
    private func fallback(title: String, body: String) {
        DispatchQueue.main.async {
            NSSound(named: "Glass")?.play()
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    // Показывать баннер и звук, даже когда приложение на переднем плане.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}
