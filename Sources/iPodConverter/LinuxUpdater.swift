#if os(Linux)
import Foundation

/// Обновление Linux-версии. Как ставить новую — зависит от того, как установлена текущая:
/// - из .tar.gz в ~/.local (папка наша) — скачиваем архив, сверяем SHA-256 с digest из GitHub,
///   подменяем свой файл и перезапускаемся (как на Mac);
/// - из .deb в /usr/bin (нужен root) — скачиваем .deb, сверяем и открываем системным установщиком;
/// - иначе (собрано вручную и т. п.) — открываем страницу релиза.
@MainActor
final class LinuxUpdater {
    static let shared = LinuxUpdater()

    enum Kind { case userLocal, deb, other }
    enum Outcome {
        case restarted                 // новая версия уже запущена
        case openedInstaller(URL)      // .deb открыт в системном установщике
        case openedPage(URL)
    }

    private(set) var available: ReleaseInfo?
    var onChange: (() -> Void)?

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateAutoCheck"); LinuxEngine.save() }
    }

    /// Настоящий путь к программе (через /proc/self/exe — без символических ссылок).
    nonisolated static var executable: URL {
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    nonisolated static var kind: Kind {
        let exe = executable
        let dir = exe.deletingLastPathComponent()
        if exe.path == "/usr/bin/ipod-converter" { return .deb }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if exe.path.hasPrefix(home + "/"), FileManager.default.isWritableFile(atPath: dir.path) { return .userLocal }
        return .other
    }

    nonisolated static var arch: (deb: String, tar: String)? {
        var u = utsname()
        uname(&u)
        let m = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        switch m {
        case "x86_64": return ("amd64", "x86_64")
        case "aarch64", "arm64": return ("arm64", "aarch64")
        default: return nil
        }
    }

    /// При запуске — не чаще раза в 20 часов (и только если не выключено).
    func checkOnLaunch() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "updateLastCheck")
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        Task { _ = await check() }
    }

    /// Есть ли версия новее. Ошибку сети не показываем — просто nil.
    @discardableResult
    func check() async -> ReleaseInfo? {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLastCheck")
        LinuxEngine.save()
        guard let r = try? await ReleaseCheck.fetchLatest() else { return nil }
        available = AppVersion.isNewer(r.version, than: AppVersion.current) ? r : nil
        if let a = available { AppLog.info("Update available: \(a.version) (current \(AppVersion.current))") }
        onChange?()
        return available
    }

    /// Поставить найденную версию.
    func install(_ r: ReleaseInfo) async throws -> Outcome {
        guard let arch = Self.arch else { return .openedPage(r.page) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipod-converter-update-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        switch Self.kind {
        case .userLocal:
            guard let a = r.asset(where: { $0 == "ipod-converter-\(r.version)-\(arch.tar).tar.gz" }) else { return .openedPage(r.page) }
            let file = work.appendingPathComponent(a.name)
            try await fetchVerified(a, to: file)
            try await replaceSelf(fromTarball: file, version: r.version, work: work)
            AppLog.info("Updated to \(r.version) (~/.local)")
            relaunch()
            return .restarted
        case .deb:
            guard let a = r.asset(where: { $0 == "ipod-converter_\(r.version)_\(arch.deb).deb" }) else { return .openedPage(r.page) }
            // В «Загрузки»: системный установщик открывает .deb оттуда, и файл не пропадёт до установки.
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let file = downloads.appendingPathComponent(a.name)
            try await fetchVerified(a, to: file)
            AppLog.info("Update \(r.version): .deb downloaded, opening the system installer")
            Self.open(file)
            return .openedInstaller(file)
        case .other:
            Self.open(r.page)
            return .openedPage(r.page)
        }
    }

    /// Скачать и сверить SHA-256 с digest из API GitHub. Без digest не ставим.
    private func fetchVerified(_ a: ReleaseInfo.Asset, to file: URL) async throws {
        guard let expected = a.sha256, expected.count == 64 else { throw Self.fail("No checksum for \(a.name) on GitHub") }
        try await ReleaseCheck.download(a.url, to: file)
        let r = try await ProcessRunner.run("/usr/bin/sha256sum", [file.path], timeout: 120)
        let got = String(decoding: r.out, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        guard got.lowercased() == expected else {
            try? FileManager.default.removeItem(at: file)
            throw Self.fail("The download is damaged (checksum mismatch) — nothing was installed")
        }
    }

    /// Распаковать архив и заменить свой файл (и значки/ярлык) в ~/.local. Запущенная программа
    /// переживает замену: файл подменяется переименованием, старый код остаётся в памяти до перезапуска.
    private func replaceSelf(fromTarball file: URL, version: String, work: URL) async throws {
        let t = try await ProcessRunner.run("/usr/bin/tar", ["-xzf", file.path, "-C", work.path], timeout: 300)
        guard t.status == 0 else { throw Self.fail("Could not unpack the update") }
        let root = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("ipod-converter-") && $0.hasDirectoryPath }
        guard let root else { throw Self.fail("Unexpected update package") }
        let newExe = root.appendingPathComponent("usr/bin/ipod-converter")
        guard FileManager.default.isExecutableFile(atPath: newExe.path) else { throw Self.fail("Unexpected update package") }
        let exe = Self.executable
        let staged = exe.deletingLastPathComponent().appendingPathComponent(".ipod-converter.new")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: newExe, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard rename(staged.path, exe.path) == 0 else { throw Self.fail("Could not replace the program file") }
        // Значки и описание — тоже свежие; ярлык (.desktop) не трогаем: в нём уже правильный путь.
        let prefix = exe.deletingLastPathComponent().deletingLastPathComponent()
        let share = root.appendingPathComponent("usr/share")
        for sub in ["icons", "metainfo", "doc"] {
            let src = share.appendingPathComponent(sub)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            _ = try? await ProcessRunner.run("/bin/cp", ["-r", src.path, prefix.appendingPathComponent("share").path + "/"], timeout: 60)
        }
        try? FileManager.default.removeItem(at: work)
    }

    /// Запустить новую версию и выйти. Новую стартуем через секунду, когда эта уже закрылась:
    /// иначе GTK видит работающую копию (тот же id приложения), передаёт ей управление и закрывается.
    private func relaunch() {
        LinuxEngine.save()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; exec \"$0\"", Self.executable.path]
        try? p.run()
        exit(0)
    }

    /// Открыть файл или страницу программой по умолчанию.
    nonisolated static func open(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        p.arguments = [url.isFileURL ? url.path : url.absoluteString]
        try? p.run()
    }

    nonisolated static func fail(_ text: String) -> NSError {
        NSError(domain: "iPodConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
#endif
