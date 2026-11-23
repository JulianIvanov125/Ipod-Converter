import AppKit
import CryptoKit
import Observation
import SwiftUI

/// Обновление по клику: последний релиз на GitHub → скачать DMG → сверить SHA-256 (файл .sha256 рядом
/// в релизе) → достать приложение → закрыться, подменить себя и запуститься заново.
/// Если подменить нельзя (нет прав на папку, нет контрольной суммы) — открываем страницу релиза.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()
    static let repo = FeedbackCenter.repo

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL?
        let sha256: URL?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Double), installing, failed(String)
    }

    var phase: Phase = .idle
    var showWindow = false
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck") }
    }

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// «1.3.10» > «1.3.9».
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// При запуске — не чаще раза в сутки и не для пропущенной пользователем версии.
    func checkOnLaunch() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "updateLastCheck")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if userInitiated { showWindow = true }
        phase = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
        do {
            let r = try await Self.fetchLatest()
            if Self.isNewer(r.version, than: Self.currentVersion) {
                let skipped = UserDefaults.standard.string(forKey: "updateSkipped")
                phase = .available(r)
                if userInitiated || skipped != r.version { showWindow = true }
                // Системное уведомление — при автоматической проверке (пропущенную версию не напоминаем).
                if !userInitiated && skipped != r.version {
                    Notifier.notifyUpdate(title: L.updAvailable(r.version), body: L.updNotifyBody)
                }
                AppLog.info("Update available: \(r.version) (current \(Self.currentVersion))")
            } else {
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
            AppLog.error("Update check failed: \(error.localizedDescription)")
        }
    }

    func skip(_ r: Release) {
        UserDefaults.standard.set(r.version, forKey: "updateSkipped")
        showWindow = false
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("iPodConverter", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure(L.updCheckFailed)
        }
        let assets = (j["assets"] as? [[String: Any]]) ?? []
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       notes: j["body"] as? String ?? "", page: page, dmg: asset(".dmg"), sha256: asset(".dmg.sha256"))
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    // MARK: Установка

    /// Можно ли заменить приложение на месте (иначе — только страница релиза).
    static var canReplaceInPlace: Bool {
        let app = Bundle.main.bundleURL
        return app.pathExtension == "app" && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    func install(_ r: Release) {
        guard let dmg = r.dmg, let sha = r.sha256, Self.canReplaceInPlace else {
            NSWorkspace.shared.open(r.page)
            return
        }
        phase = .downloading(0)
        Task {
            do {
                let newApp = try await Self.prepare(dmg: dmg, sha: sha, version: r.version) { p in
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(p) } }
                }
                phase = .installing
                AppLog.info("Installing update \(r.version)")
                try Self.relaunch(replacingWith: newApp)
            } catch {
                phase = .failed(error.localizedDescription)
                AppLog.error("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Скачать, сверить SHA-256, смонтировать DMG и скопировать приложение рядом с текущим (тот же диск).
    nonisolated static func prepare(dmg: URL, sha: URL, version: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("iPodConverter-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let expected = String(decoding: try await URLSession.shared.data(from: sha).0, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map { String($0).lowercased() } ?? ""
        guard expected.count == 64 else { throw Failure(L.updNoChecksum) }

        let file = work.appendingPathComponent("update.dmg")
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tmp, resp) = try await session.download(from: dmg)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw Failure(L.updDownloadFailed) }
        try fm.moveItem(at: tmp, to: file)

        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .alwaysMapped)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw Failure(L.updChecksumMismatch) }

        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let a = try await ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, file.path], timeout: 120)
        guard a.status == 0 else { throw Failure(L.updMountFailed) }
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", "-quiet", "-force", mount.path]) }

        guard let src = (try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)).first(where: { $0.pathExtension == "app" }),
              let b = Bundle(url: src), b.bundleIdentifier == Bundle.main.bundleIdentifier,
              (b.infoDictionary?["CFBundleShortVersionString"] as? String) == version else {
            throw Failure(L.updBadPackage)
        }
        // Копия рядом с текущим приложением: подмена потом — простое переименование на том же диске.
        let dest = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".iPod Converter \(version).app", isDirectory: true)
        try? fm.removeItem(at: dest)
        let c = try await ProcessRunner.run("/usr/bin/ditto", [src.path, dest.path], timeout: 300)
        guard c.status == 0 else { throw Failure(L.updCopyFailed) }
        try? fm.removeItem(at: file)
        return dest
    }

    /// Скрипт ждёт, пока приложение закроется, переносит старую версию в Корзину, ставит новую и запускает её.
    static func relaunch(replacingWith newApp: URL) throws {
        let app = Bundle.main.bundleURL
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        OLD="$1"; NEW="$2"
        BAK="${OLD%.app}.previous.app"
        rm -rf "$BAK"
        mv "$OLD" "$BAK" && mv "$NEW" "$OLD" || { mv "$BAK" "$OLD" 2>/dev/null; open "$OLD"; exit 1; }
        xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
        open "$OLD"
        """
        // Старую копию убирает в Корзину уже новая версия при запуске (cleanupPrevious):
        // через Finder macOS спрашивала разрешение «управлять Finder», и скрипт висел на этом вопросе.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "updater", app.path, newApp.path]
        try p.run()
        // Пока на окне открыт лист (окно обновления), macOS отменяет выход — приложение не закрывалось
        // и обновление «висело». Закрываем листы, потом выходим; если выход всё равно отменят — exit.
        Updater.shared.showWindow = false
        for w in NSApp.windows { if let s = w.attachedSheet { w.endSheet(s) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    /// После обновления рядом остаётся «… .previous.app» — убираем её в Корзину (не удаляем насовсем).
    static func cleanupPrevious() {
        let app = Bundle.main.bundleURL
        let bak = app.deletingPathExtension().appendingPathExtension("previous").appendingPathExtension("app")
        guard FileManager.default.fileExists(atPath: bak.path) else { return }
        do {
            try FileManager.default.trashItem(at: bak, resultingItemURL: nil)
            AppLog.info("Previous version moved to Trash")
        } catch {
            AppLog.error("Could not move previous version to Trash: \(error.localizedDescription)")
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}

/// Окно «Доступно обновление».
struct UpdateView: View {
    @Bindable private var u = Updater.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch u.phase {
            case .idle, .checking:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L.updChecking) }
            case .upToDate:
                Label(L.updUpToDate(Updater.currentVersion), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available(let r):
                Text(L.updAvailable(r.version)).font(.system(size: 16, weight: .semibold))
                Text(L.updCurrent(Updater.currentVersion)).font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    Text(LocalizedStringKey(r.notes.replacingOccurrences(of: "\r\n", with: "\n")))
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tint(0.05)))
                if !Updater.canReplaceInPlace || r.sha256 == nil {
                    Text(L.updManualHint).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L.updSkip) { u.skip(r); dismiss() }
                    Spacer()
                    Button(L.updLater) { u.showWindow = false; dismiss() }.keyboardShortcut(.cancelAction)
                    Button(Updater.canReplaceInPlace && r.sha256 != nil ? L.updInstall : L.updOpenPage) { u.install(r) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .downloading(let p):
                Text(L.updDownloading).font(.system(size: 13, weight: .semibold))
                ProgressView(value: p)
            case .installing:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L.updInstalling) }
            case .failed(let e):
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
            }
            if case .available = u.phase {} else {
                HStack {
                    Toggle(L.updAuto, isOn: $u.autoCheck).font(.system(size: 12))
                    Spacer()
                    Button(L.close) { u.showWindow = false; dismiss() }
                }
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
