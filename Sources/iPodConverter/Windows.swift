#if os(Windows)
import Foundation
import WinSDK

/// Windows: Корзина и связка с iTunes (аналог AppleScript-связки с «Музыкой» на Mac).
enum WindowsShell {
    /// В Корзину (можно вернуть), без окон подтверждения.
    static func recycle(_ url: URL) throws {
        // SHFileOperation ждёт список путей, каждый с \0 на конце и ещё один \0 в конце списка.
        var from = Array(url.path.replacingOccurrences(of: "/", with: "\\").utf16) + [0, 0]
        let code: Int32 = from.withUnsafeMutableBufferPointer { buf in
            var op = SHFILEOPSTRUCTW()
            op.wFunc = UINT(FO_DELETE)
            op.pFrom = UnsafePointer(buf.baseAddress)
            op.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI)
            return SHFileOperationW(&op)
        }
        if code != 0 {
            throw NSError(domain: "iPodConverter", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "Could not move to the Recycle Bin (code \(code))"])
        }
    }
}

/// iTunes для Windows через COM (iTunes.Application). Запускаем JScript через cscript — так не нужна
/// COM-обвязка в Swift, а логика та же, что у AppleScript на Mac: добавить файл, положить в плейлист iPod,
/// клипы — тип «Музыкальное видео» и не в перемешивание.
enum ITunesBridge {
    static var isInstalled: Bool {
        // iTunes регистрирует ProgID iTunes.Application в HKEY_CLASSES_ROOT.
        var key: HKEY?
        let ok = RegOpenKeyExW(HKEY_CLASSES_ROOT, Array("iTunes.Application".utf16) + [0], 0, KEY_READ, &key) == ERROR_SUCCESS
        if let key { RegCloseKey(key) }
        return ok
    }

    /// Добавить файлы в медиатеку iTunes и в плейлист. Возвращает строку на файл: «ok», «ERR:…».
    static func add(_ files: [URL], playlist: String, musicVideo: Bool) async -> [String] {
        guard !files.isEmpty else { return [] }
        let script = """
        var args = WScript.Arguments;
        var app = new ActiveXObject("iTunes.Application");
        var name = args(0), isVideo = args(1) == "video";
        var pl = null;
        if (name != "") {
            var src = app.LibrarySource.Playlists;
            for (var i = 1; i <= src.Count; i++) { if (src.Item(i).Name == name) { pl = src.Item(i); break; } }
            if (pl == null) pl = app.CreatePlaylist(name);
        }
        for (var k = 2; k < args.length; k++) {
            try {
                var op = app.LibraryPlaylist.AddFile(args(k));
                while (op != null && op.InProgress) WScript.Sleep(100);
                var tracks = op != null ? op.Tracks : null;
                if (tracks == null || tracks.Count == 0) { WScript.Echo("ERR:not added"); continue; }
                var t = tracks.Item(1);
                if (isVideo) { try { t.VideoKind = 2; } catch (e) {} try { t.ExcludeFromShuffle = true; } catch (e) {} }
                if (pl != null) pl.AddTrack(t);
                WScript.Echo("ok");
            } catch (e) { WScript.Echo("ERR:" + e.message); }
        }
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iPodConverter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let js = dir.appendingPathComponent("itunes-add-\(UUID().uuidString).js")
        guard (try? script.write(to: js, atomically: true, encoding: .utf8)) != nil else { return files.map { _ in "ERR:script" } }
        defer { try? FileManager.default.removeItem(at: js) }
        let cscript = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\cscript.exe"
        let args = ["//nologo", "//E:jscript", js.path, playlist, musicVideo ? "video" : "song"]
            + files.map { $0.path.replacingOccurrences(of: "/", with: "\\") }
        guard let r = try? await ProcessRunner.run(cscript, args, timeout: 600) else { return files.map { _ in "ERR:cscript" } }
        let lines = String(decoding: r.out, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.isEmpty ? files.map { _ in "ERR:" + String(decoding: r.err, as: UTF8.self) } : lines
    }
}

/// Окно WinUI — следующий шаг; пока консольный режим.
enum WindowsApp {
    static func run(files: [URL]) {
        print("iPod Converter for Windows. Window coming soon. Commands: convert, dups, models")
    }
}
#endif
