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

    /// M4A/M4B пишем своим кодом (MP4Tagger): ffmpeg теряет поля iTunes (iTunSMPB и др.).
    static func isMP4(_ ext: String) -> Bool { ["m4a", "m4b"].contains(ext) }

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

    /// Пишет найденные теги/обложку (только то, чего в файле не было). Возвращает, что записано, или ошибку.
    static func write(url: URL, info: AudioInfo, meta: FetchedMeta) async -> Result<Written, TagWriteError> {
        let ext = url.pathExtension.lowercased()
        let fields = meta.fields.filter { !$0.value.isEmpty }
        let cover = info.coverStreamIndex == nil && canWriteCover(ext) ? meta.coverFile : nil
        guard !fields.isEmpty || cover != nil else { return .failure(.init(L.metaWriteNothing)) }
        let written = Written(fields: fields.keys.sorted(), cover: cover != nil)
        let r = await apply(url: url, info: info, set: fields, clear: [], cover: cover, replace: false, mark: written.markValue)
        if case .failure(let e) = r { return .failure(e) }
        MetaMarks.set(url, written.markValue)
        return .success(written)
    }

    /// Правка тегов пользователем: set — новые значения (заменяют прежние), clear — удалить поля,
    /// cover — новая обложка (заменяет прежнюю).
    static func edit(url: URL, info: AudioInfo, set: [String: String], clear: Set<String>, cover: URL?) async -> Result<Void, TagWriteError> {
        let ext = url.pathExtension.lowercased()
        if cover != nil, !canWriteCover(ext) { return .failure(.init(L.tagCoverUnsupported)) }
        guard !set.isEmpty || !clear.isEmpty || cover != nil else { return .success(()) }
        return await apply(url: url, info: info, set: set, clear: clear, cover: cover, replace: true, mark: nil)
    }

    private static func apply(url: URL, info: AudioInfo, set fields: [String: String], clear: Set<String>,
                              cover: URL?, replace: Bool, mark: String?) async -> Result<Void, TagWriteError> {
        let ext = url.pathExtension.lowercased()
        guard canWrite(ext) else { return .failure(.init(L.metaWriteUnsupported)) }
        guard let ffmpeg = FFmpeg.tool("ffmpeg") else { return .failure(.init(L.toolNotFound("ffmpeg"))) }

        // Временный файл рядом с оригиналом (тот же диск — подмена мгновенная).
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).ipc-\(UUID().uuidString.prefix(6)).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        if isMP4(ext) {
            do {
                try MP4Tagger.write(src: url, dst: tmp, fields: fields, cover: cover.flatMap { try? Data(contentsOf: $0) },
                                    mark: mark, replace: replace, clear: clear)
            } catch {
                return .failure(.init("\(error)"))
            }
        } else {
            // Новая обложка вместо старой — старую не берём.
            let keepOldCover = info.coverStreamIndex != nil && (cover == nil || !replace)
            let addCover = cover != nil && (replace || info.coverStreamIndex == nil)
            var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", url.path]
            if addCover, let cover { args += ["-i", cover.path] }
            args += ["-map", "0:a"]
            if keepOldCover, let idx = info.coverStreamIndex { args += ["-map", "0:\(idx)"] }
            if addCover { args += ["-map", "1:0"] }
            args += ["-c", "copy", "-map_metadata", "0"]
            // OGG/Opus: теги живут в аудиопотоке.
            let scope = info.tagsInStream ? "-metadata:s:a:0" : "-metadata"
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) { args += [scope, "\(k)=\(v)"] }
            for k in clear.sorted() { args += [scope, "\(k)="] }
            if let mark { args += [scope, "\(markKey)=\(mark)"] }
            if keepOldCover || addCover { args += ["-disposition:v:0", "attached_pic"] }
            if ext == "mp3" { args += ["-id3v2_version", "3"] }
            args += ["-f", muxer(ext), tmp.path]
            do {
                let r = try await ProcessRunner.run(ffmpeg, args, timeout: 120)
                if r.timedOut { return .failure(.init(L.processTimedOut)) }
                if r.status != 0 { return .failure(.init(FFmpeg.ffmpegOutputLine(String(decoding: r.err, as: UTF8.self)))) }
            } catch {
                return .failure(.init(error.localizedDescription))
            }
        }

        // Аудиоданные должны совпасть байт в байт (контрольная сумма пакетов звука до и после).
        if let a = await audioMD5(ffmpeg, url), let b = await audioMD5(ffmpeg, tmp), a != b {
            return .failure(.init(L.metaWriteCheckFailed))
        }

        // Проверка: тот же звук, прежние теги на месте (кроме изменённых), новые записались, оценка не потерялась.
        guard let after = try? await FFmpeg.probeAudio(tmp) else { return .failure(.init(L.metaWriteCheckFailed)) }
        guard after.codec == info.codec, after.sampleRate == info.sampleRate, after.channels == info.channels,
              abs(after.duration - info.duration) < 0.5 else {
            return .failure(.init(L.metaWriteCheckFailed))
        }
        var ignored: Set<String> = ["encoder", "major_brand", "minor_version", "compatible_brands", "creation_time",
                                    "tsse", "encoded_by", "id3v2_priv.xmp", markKey.lowercased()]
        ignored.formUnion(clear)
        let lost = info.tags.keys.filter { !ignored.contains($0) && !$0.hasPrefix("id3v2_priv") && after.tags[$0] == nil }
        guard lost.isEmpty else { return .failure(.init(L.metaWriteWouldLose(lost.sorted().joined(separator: ", ")))) }
        guard fields.keys.allSatisfy({ after.tags[$0] != nil }) else { return .failure(.init(L.metaWriteCheckFailed)) }
        if replace {
            // Значения действительно стали новыми (номер трека «8» и «8/13» считаем одинаковыми).
            for (k, v) in fields {
                let got = after.tags[k] ?? ""
                let same = ["track", "disc"].contains(k) ? got.split(separator: "/").first == v.split(separator: "/").first : got == v
                if !same { return .failure(.init(L.metaWriteCheckFailed)) }
            }
            if clear.contains(where: { after.tags[$0] != nil }) { return .failure(.init(L.metaWriteCheckFailed)) }
        }
        if cover != nil, after.coverStreamIndex == nil { return .failure(.init(L.metaWriteCheckFailed)) }
        if info.coverStreamIndex != nil, after.coverStreamIndex == nil { return .failure(.init(L.metaWriteWouldLose(L.metaField("cover")))) }
        if info.rating != nil, after.rating == nil { return .failure(.init(L.metaWriteWouldLose(L.colRating))) }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
        } catch {
            return .failure(.init(error.localizedDescription))
        }
        return .success(())
    }
}

extension TagWriter {
    /// MD5 пакетов звука без перекодирования (ffmpeg -c copy -f md5).
    static func audioMD5(_ ffmpeg: String, _ url: URL) async -> String? {
        guard let r = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", url.path,
                                                             "-map", "0:a:0", "-c", "copy", "-f", "md5", "-"], timeout: 120),
              r.status == 0 else { return nil }
        return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
