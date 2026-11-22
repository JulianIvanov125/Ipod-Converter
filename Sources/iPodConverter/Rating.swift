import Foundation

/// Чтение оценки трека из файла.
/// MP3 — кадр ID3 POPM (0–255, как пишут Windows Media Player, foobar2000, MusicBee);
/// FLAC/OGG/Opus/APE — тег RATING (1–5, 0–100) или FMPS_RATING (0.0–1.0).
/// Сама «Музыка» хранит оценки в своей медиатеке, а не в файлах.
enum RatingReader {
    static func fromTags(_ tags: [String: String]) -> Int? {
        for key in ["rating", "fmps_rating", "rating wmp", "rate"] {
            guard let raw = tags[key]?.trimmingCharacters(in: .whitespaces),
                  let v = Double(raw.replacingOccurrences(of: ",", with: ".")) else { continue }
            if key == "fmps_rating" || (raw.contains(".") && v <= 1) { return clamp(v * 100) }
            if v <= 5 { return clamp(v * 20) }
            if v <= 100 { return clamp(v) }
            if v <= 255 { return fromPOPM(Int(v)) }
        }
        return nil
    }

    /// 0–255 → 0–100 по общепринятой шкале (1 → ★, 64 → ★★, 128 → ★★★, 196 → ★★★★, 255 → ★★★★★).
    static func fromPOPM(_ b: Int) -> Int? {
        switch b {
        case 0: return nil
        case 1...31: return 20
        case 32...95: return 40
        case 96...159: return 60
        case 160...223: return 80
        default: return 100
        }
    }

    /// Ищет кадр POPM в заголовке ID3v2.3/2.4.
    static func popm(_ url: URL) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 10), head.count == 10,
              head.prefix(3) == Data("ID3".utf8) else { return nil }
        let b = [UInt8](head)
        let major = Int(b[3])
        guard major == 3 || major == 4 else { return nil }
        let tagSize = syncsafe(b[6], b[7], b[8], b[9])
        guard tagSize > 0, tagSize < 50_000_000, let body = try? h.read(upToCount: tagSize) else { return nil }
        let d = [UInt8](body)
        var pos = 0
        if b[5] & 0x40 != 0, d.count >= 4 { // расширенный заголовок
            pos = major == 4 ? syncsafe(d[0], d[1], d[2], d[3]) : (be(d[0], d[1], d[2], d[3]) + 4)
        }
        while pos + 10 <= d.count {
            let id = String(bytes: d[pos..<pos + 4], encoding: .ascii) ?? ""
            if id.first == "\0" || id.isEmpty { break }
            let size = major == 4 ? syncsafe(d[pos + 4], d[pos + 5], d[pos + 6], d[pos + 7])
                                  : be(d[pos + 4], d[pos + 5], d[pos + 6], d[pos + 7])
            let start = pos + 10
            guard size > 0, start + size <= d.count else { break }
            if id == "POPM", let zero = d[start..<start + size].firstIndex(of: 0), zero + 1 < start + size {
                return fromPOPM(Int(d[zero + 1]))
            }
            pos = start + size
        }
        return nil
    }

    private static func syncsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7F) << 21 | Int(b & 0x7F) << 14 | Int(c & 0x7F) << 7 | Int(d & 0x7F)
    }

    private static func be(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a) << 24 | Int(b) << 16 | Int(c) << 8 | Int(d)
    }

    private static func clamp(_ v: Double) -> Int? {
        let r = Int((v / 20).rounded()) * 20
        return r <= 0 ? nil : min(r, 100)
    }
}
