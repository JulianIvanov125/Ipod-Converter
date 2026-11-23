import Foundation

/// Запись тегов в M4A/M4B без ffmpeg: добавляем записи в moov/udta/meta/ilst и сдвигаем ссылки
/// на аудиоданные (stco/co64). Звук и все прежние поля (в том числе iTunSMPB — данные для
/// воспроизведения без пауз, iTunNORM, Encoding Params) остаются байт в байт —
/// ffmpeg при перепаковке их теряет.
enum MP4Tagger {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Атом: заголовок + либо дочерние атомы (контейнер), либо данные как есть.
    final class Atom {
        var type: String
        var prefix = Data()          // у meta (full box) — 4 байта версии/флагов перед детьми
        var children: [Atom]?
        var payload: Data
        init(type: String, payload: Data = Data(), children: [Atom]? = nil, prefix: Data = Data()) {
            self.type = type; self.payload = payload; self.children = children; self.prefix = prefix
        }

        func child(_ t: String) -> Atom? { children?.first { $0.type == t } }

        var data: Data {
            var body = prefix
            if let children { for c in children { body.append(c.data) } } else { body.append(payload) }
            let total = body.count + 8
            var out = Data()
            if total > Int(UInt32.max) {
                out.append(be32(1)); out.append(type.isoLatin1.prefix(4)); out.append(be64(UInt64(total + 8)))
            } else {
                out.append(be32(UInt32(total))); out.append(type.isoLatin1.prefix(4))
            }
            out.append(body)
            return out
        }
    }

    /// Контейнеры, внутрь которых нужно заглянуть: путь к ilst и к таблицам смещений.
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "meta", "ilst"]

    private static func parse(_ d: Data, _ range: Range<Int>) throws -> [Atom] {
        var atoms: [Atom] = []
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            var size = Int(rd32(d, i))
            let type = String(data: d[(i + 4)..<(i + 8)], encoding: .isoLatin1) ?? "????"
            var header = 8
            if size == 1 {
                guard i + 16 <= range.upperBound else { throw Failure("bad atom") }
                size = Int(rd64(d, i + 8)); header = 16
            } else if size == 0 {
                size = range.upperBound - i
            }
            guard size >= header, i + size <= range.upperBound else { throw Failure("bad atom size in \(type)") }
            let body = (i + header)..<(i + size)
            if containers.contains(type) {
                var start = body.lowerBound
                var prefix = Data()
                // meta в M4A — full box (4 байта версии/флагов); в QuickTime-варианте — нет.
                if type == "meta", body.count >= 12, String(data: d[(start + 4)..<(start + 8)], encoding: .isoLatin1) != "hdlr" {
                    prefix = Data(d[start..<(start + 4)]); start += 4
                }
                atoms.append(Atom(type: type, children: try parse(d, start..<body.upperBound), prefix: prefix))
            } else {
                atoms.append(Atom(type: type, payload: Data(d[body])))
            }
            i += size
        }
        return atoms
    }

    // MARK: - Записи ilst

    private static func dataAtom(_ type: UInt32, _ value: Data) -> Atom {
        var p = be32(type)          // версия 0 + тип
        p.append(be32(0))           // locale
        p.append(value)
        return Atom(type: "data", payload: p)
    }

    private static func textItem(_ name: String, _ s: String) -> Atom {
        Atom(type: name, children: [dataAtom(1, Data(s.utf8))])
    }

    /// «8/13» → номер и всего.
    private static func pair(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard let n = parts.first, n > 0 else { return nil }
        return (n, parts.count > 1 ? parts[1] : 0)
    }

    private static func numberItem(_ name: String, _ s: String, trailing: Bool) -> Atom? {
        guard let (n, total) = pair(s) else { return nil }
        var p = Data([0, 0])
        p.append(be16(UInt16(clamping: n))); p.append(be16(UInt16(clamping: total)))
        if trailing { p.append(contentsOf: [0, 0]) }
        return Atom(type: name, children: [dataAtom(0, p)])
    }

    /// Своё поле iTunes («----»): так же хранятся iTunSMPB и iTunNORM; ffprobe показывает его как тег name.
    private static func freeformItem(_ name: String, _ value: String) -> Atom {
        var mean = Data(count: 4); mean.append(Data("com.apple.iTunes".utf8))
        var nm = Data(count: 4); nm.append(Data(name.utf8))
        return Atom(type: "----", children: [Atom(type: "mean", payload: mean), Atom(type: "name", payload: nm), dataAtom(1, Data(value.utf8))])
    }

    private static let itemNames: [String: String] = [
        "title": "\u{A9}nam", "artist": "\u{A9}ART", "album": "\u{A9}alb", "album_artist": "aART",
        "date": "\u{A9}day", "genre": "\u{A9}gen", "composer": "\u{A9}wrt",
    ]

    // MARK: - Запись

    /// Пишет теги в копию файла dst. Уже существующие записи ilst не трогает.
    static func write(src: URL, dst: URL, fields: [String: String], cover: Data?, mark: String?,
                      replace: Bool = false, clear: Set<String> = []) throws {
        let d = try Data(contentsOf: src, options: .alwaysMapped)
        let top = try parse(d, 0..<d.count)
        guard let moovIndex = top.firstIndex(where: { $0.type == "moov" }) else { throw Failure("no moov atom") }
        let moov = top[moovIndex]
        let oldMoovSize = moov.data.count

        // moov/udta/meta(hdlr mdir)/ilst — создаём, чего нет.
        var udta = moov.child("udta")
        if udta == nil { udta = Atom(type: "udta", children: []); moov.children?.append(udta!) }
        var meta = udta!.child("meta")
        if meta == nil {
            var hdlr = Data(count: 8); hdlr.append(Data("mdirappl".utf8)); hdlr.append(Data(count: 9))
            meta = Atom(type: "meta", children: [Atom(type: "hdlr", payload: hdlr)], prefix: Data(count: 4))
            udta!.children?.append(meta!)
        }
        var ilst = meta!.child("ilst")
        if ilst == nil { ilst = Atom(type: "ilst", children: []); meta!.children?.append(ilst!) }

        // Правка пользователем: старые записи этих полей убираем, новые добавятся ниже.
        if replace {
            var drop = Set((Array(fields.keys) + Array(clear)).compactMap { k -> String? in
                switch k { case "track": "trkn"; case "disc": "disk"; default: itemNames[k] }
            })
            if cover != nil { drop.insert("covr") }
            if drop.contains("\u{A9}gen") { drop.insert("gnre") }   // жанр номером из старых файлов
            ilst!.children?.removeAll { drop.contains($0.type) }
        }
        let have = Set((ilst!.children ?? []).map(\.type))
        var added: [Atom] = []
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            switch k {
            case "track": if !have.contains("trkn"), let a = numberItem("trkn", v, trailing: true) { added.append(a) }
            case "disc": if !have.contains("disk"), let a = numberItem("disk", v, trailing: false) { added.append(a) }
            default:
                if let name = itemNames[k], !have.contains(name) { added.append(textItem(name, v)) }
            }
        }
        if let cover, !have.contains("covr") {
            let png = cover.starts(with: [0x89, 0x50, 0x4E, 0x47])
            added.append(Atom(type: "covr", children: [dataAtom(png ? 14 : 13, cover)]))
        }
        if let mark {
            // Прежнюю пометку заменяем.
            ilst!.children?.removeAll { a in
                a.type == "----" && a.child("name").map { String(decoding: $0.payload.dropFirst(4), as: UTF8.self) == TagWriter.markKey } ?? false
            }
            added.append(freeformItem(TagWriter.markKey, mark))
        }
        ilst!.children?.append(contentsOf: added)

        // Если moov стоит перед аудиоданными, они сдвинутся на разницу размеров — правим смещения.
        let delta = moov.data.count - oldMoovSize
        let moovOffset = top[..<moovIndex].reduce(0) { $0 + $1.data.count }
        let dataAfterMoov = top[(moovIndex + 1)...].contains { $0.type == "mdat" }
        if delta != 0 && dataAfterMoov {
            for trak in moov.children ?? [] where trak.type == "trak" {
                guard let stbl = trak.child("mdia")?.child("minf")?.child("stbl") else { continue }
                if let stco = stbl.child("stco") { try shift(stco, by: delta, wide: false, after: moovOffset) }
                if let co64 = stbl.child("co64") { try shift(co64, by: delta, wide: true, after: moovOffset) }
            }
        }

        // Файл: всё до moov как было, новый moov, всё после — байт в байт.
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let h = try FileHandle(forWritingTo: dst)
        defer { try? h.close() }
        var pos = 0
        for (i, a) in top.enumerated() {
            let size = a === moov ? oldMoovSize : a.data.count
            if i == moovIndex { try h.write(contentsOf: moov.data) }
            else { try h.write(contentsOf: d[pos..<(pos + size)]) }
            pos += size
        }
        guard pos == d.count else { throw Failure("file layout mismatch") }
    }

    private static func shift(_ atom: Atom, by delta: Int, wide: Bool, after: Int) throws {
        var p = atom.payload
        guard p.count >= 8 else { throw Failure("bad chunk table") }
        let n = Int(rd32(p, 4))
        let step = wide ? 8 : 4
        guard p.count >= 8 + n * step else { throw Failure("bad chunk table") }
        for k in 0..<n {
            let at = 8 + k * step
            let old = wide ? Int(rd64(p, at)) : Int(rd32(p, at))
            guard old > after else { continue }
            let new = old + delta
            if wide { p.replaceSubrange(at..<(at + 8), with: be64(UInt64(new))) }
            else {
                guard new >= 0, new <= Int(UInt32.max) else { throw Failure("offset overflow") }
                p.replaceSubrange(at..<(at + 4), with: be32(UInt32(new)))
            }
        }
        atom.payload = p
    }
}

// MARK: - Байты

private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
private func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
private func be64(_ v: UInt64) -> Data { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }
private func rd32(_ d: Data, _ i: Int) -> UInt32 {
    let s = d.startIndex + i
    return UInt32(d[s]) << 24 | UInt32(d[s + 1]) << 16 | UInt32(d[s + 2]) << 8 | UInt32(d[s + 3])
}
private func rd64(_ d: Data, _ i: Int) -> UInt64 { UInt64(rd32(d, i)) << 32 | UInt64(rd32(d, i + 4)) }

private extension String {
    /// Имена атомов вроде «©nam» — по байту на символ (© = 0xA9), не UTF-8.
    var isoLatin1: Data { data(using: .isoLatin1) ?? Data(utf8) }
}
