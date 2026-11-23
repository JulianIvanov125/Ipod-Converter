import Foundation

/// Запись найденных тегов и обложки прямо в исходный файл — без перекодирования (ffmpeg -c copy).
/// Пишем во временный файл рядом, проверяем результат и только потом подменяем оригинал.
/// Если что-то потерялось бы (звук, теги, оценка), оригинал не трогаем.
enum TagWriter {
    /// Пометка «дополнено iPod Converter» в самом файле (mp3, flac, ogg, opus): список дописанных полей.
    static let markKey = "IPODCONVERTER"

    static func canWrite(_ ext: String) -> Bool {
        ["mp3", "m4a", "m4b", "flac", "ogg", "oga", "opus"].contains(ext)
    }

    /// В OGG/Opus ffmpeg обложку не пишет — только теги.
    static func canWriteCover(_ ext: String) -> Bool {
        !["ogg", "oga", "opus"].contains(ext)
    }

    /// В M4A своё поле не пишется (ffmpeg кладёт его в формат, который «Музыка» не читает) —
    /// пометку храним в приложении.
    static func canWriteMark(_ ext: String) -> Bool {
        !["m4a", "m4b"].contains(ext)
    }

    private static func muxer(_ ext: String) -> String {
        switch ext {
        case "mp3": "mp3"
        case "m4a", "m4b": "ipod"
        case "flac": "flac"
        case "opus": "opus"
        default: "ogg"
        }
    }

    /// Что было дописано: поля и обложка.
    struct Written {
        var fields: [String]
        var cover: Bool
        var markValue: String { (fields + (cover ? ["cover"] : [])).joined(separator: ",") }
    }

    /// Пишет теги/обложку. Возвращает, что записано, или текст ошибки.
    static func write(url: URL, info: AudioInfo, meta: FetchedMeta) async -> Result<Written, TagWriteError> {
        let ext = url.pathExtension.lowercased()
        guard canWrite(ext) else { return .failure(.init(L.metaWriteUnsupported)) }
        guard let ffmpeg = FFmpeg.tool("ffmpeg") else { return .failure(.init(L.toolNotFound("ffmpeg"))) }
        let fields = meta.fields.filter { !$0.value.isEmpty }
        let cover = info.coverStreamIndex == nil && canWriteCover(ext) ? meta.coverFile : nil
        guard !fields.isEmpty || cover != nil else { return .failure(.init(L.metaWriteNothing)) }
        let written = Written(fields: fields.keys.sorted(), cover: cover != nil)

        // Временный файл рядом с оригиналом (тот же диск — подмена мгновенная).
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).ipc-\(UUID().uuidString.prefix(6)).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", url.path]
        if let cover { args += ["-i", cover.path] }
        args += ["-map", "0:a"]
        if let idx = info.coverStreamIndex { args += ["-map", "0:\(idx)"] }
        if cover != nil { args += ["-map", "1:0"] }
        args += ["-c", "copy", "-map_metadata", "0"]
        // OGG/Opus: теги живут в аудиопотоке.
        let scope = info.tagsInStream ? "-metadata:s:a:0" : "-metadata"
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { args += [scope, "\(k)=\(v)"] }
        if canWriteMark(ext) { args += [scope, "\(markKey)=\(written.markValue)"] }
        if info.coverStreamIndex != nil || cover != nil { args += ["-disposition:v:0", "attached_pic"] }
        if ext == "mp3" { args += ["-id3v2_version", "3"] }
        args += ["-f", muxer(ext), tmp.path]

        do {
            let r = try await ProcessRunner.run(ffmpeg, args, timeout: 120)
            if r.timedOut { return .failure(.init(L.processTimedOut)) }
            if r.status != 0 { return .failure(.init(FFmpeg.ffmpegOutputLine(String(decoding: r.err, as: UTF8.self)))) }
        } catch {
            return .failure(.init(error.localizedDescription))
        }

        // Проверка: тот же звук, все прежние теги на месте, новые записались, оценка не потерялась.
        guard let after = try? await FFmpeg.probeAudio(tmp) else { return .failure(.init(L.metaWriteCheckFailed)) }
        guard after.codec == info.codec, after.sampleRate == info.sampleRate, after.channels == info.channels,
              abs(after.duration - info.duration) < 0.5 else {
            return .failure(.init(L.metaWriteCheckFailed))
        }
        let ignored: Set<String> = ["encoder", "major_brand", "minor_version", "compatible_brands", "creation_time",
                                    "tsse", "encoded_by", "id3v2_priv.xmp", markKey.lowercased()]
        let lost = info.tags.keys.filter { !ignored.contains($0) && !$0.hasPrefix("id3v2_priv") && after.tags[$0] == nil }
        guard lost.isEmpty else { return .failure(.init(L.metaWriteWouldLose(lost.sorted().joined(separator: ", ")))) }
        guard fields.keys.allSatisfy({ after.tags[$0] != nil }) else { return .failure(.init(L.metaWriteCheckFailed)) }
        if cover != nil, after.coverStreamIndex == nil { return .failure(.init(L.metaWriteCheckFailed)) }
        if info.rating != nil, after.rating == nil { return .failure(.init(L.metaWriteWouldLose(L.colRating))) }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
        } catch {
            return .failure(.init(error.localizedDescription))
        }
        MetaMarks.set(url, written.markValue)
        return .success(written)
    }
}

struct TagWriteError: Error {
    let message: String
    init(_ m: String) { message = m }
}

/// Пометки «дополнено» для файлов, куда своё поле не записать (M4A), и про запас для остальных.
/// Ключ — путь к файлу; пометка действует, только пока у файла тот же размер и дата изменения
/// (если на этом месте окажется другой файл, пометка не подхватится).
enum MetaMarks {
    private static let key = "metaMarks"

    private static func stamp(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return "\(size)|\(Int(date.timeIntervalSince1970))"
    }

    static func get(_ url: URL) -> String? {
        guard let raw = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[url.standardizedFileURL.path],
              let st = stamp(url), raw.hasPrefix(st + "|") else { return nil }
        return String(raw.dropFirst(st.count + 1))
    }

    static func set(_ url: URL, _ value: String) {
        guard let st = stamp(url) else { return }
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[url.standardizedFileURL.path] = st + "|" + value
        UserDefaults.standard.set(d, forKey: key)
    }

    /// Пометка из файла или из приложения → что показывать в подсказке «Дополнено из Apple Music».
    static func restore(url: URL, info: AudioInfo) -> FetchedMeta? {
        guard let raw = info.tags[TagWriter.markKey.lowercased()] ?? get(url), !raw.isEmpty else { return nil }
        var meta = FetchedMeta()
        for name in raw.split(separator: ",").map(String.init) {
            if name == "cover" { meta.coverAdded = true } else { meta.fields[name] = info.tags[name] ?? "" }
        }
        return meta.isEmpty ? nil : meta
    }
}
