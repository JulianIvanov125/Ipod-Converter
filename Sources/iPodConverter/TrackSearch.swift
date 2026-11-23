import Foundation

// MARK: - Поиск: латиница = кириллица, неверная раскладка

/// «kino» находит «Кино», «Tsoy» — «Цой», «rbyj» (набрано в английской раскладке) — тоже «Кино».
enum TrackSearch {
    /// Приводит строку к упрощённой латинице: транслитерация, без диакритики и регистра,
    /// схлопнуты разные способы записи одних и тех же звуков (ts/c, sh/š, ya/ja/a…).
    static func fold(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping.lowercased()
        t = t.applyingTransform(.toLatin, reverse: false) ?? t
        t = t.applyingTransform(.stripDiacritics, reverse: false) ?? t
        t = t.lowercased()
        // Оставляем только буквы и цифры
        t = String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        // Разные транслитерации одного звука → одно написание (применяется к обеим сторонам)
        let rules: [(String, String)] = [
            ("shch", "s"), ("sch", "s"), ("sh", "s"), ("ch", "c"), ("ts", "c"), ("tz", "c"), ("zh", "z"),
            ("kh", "h"), ("yo", "o"), ("jo", "o"), ("yu", "u"), ("ju", "u"), ("ya", "a"), ("ja", "a"),
            ("ye", "e"), ("je", "e"), ("ii", "i"), ("iy", "i"), ("yi", "i"), ("j", "i"), ("y", "i"),
            ("w", "v"), ("x", "ks"), ("q", "k"), ("ph", "f"), ("ʹ", ""), ("ʺ", ""), ("'", ""),
            ("ei", "i"),   // Mötley → motli = «мотли»
        ]
        for (a, b) in rules { t = t.replacingOccurrences(of: a, with: b) }
        // «й/j/y/и» после правил дают «ii» — схлопываем только их (Обійми = obiimy = obimi).
        while t.contains("ii") { t = t.replacingOccurrences(of: "ii", with: "i") }
        return t
    }

    private static let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    private static let ru = Array("йцукенгшщзхъфывапролджэячсмитьбюё")

    /// Текст, набранный не в той раскладке: «rbyj» ⇄ «кино».
    static func swapLayout(_ s: String) -> String {
        String(s.lowercased().map { c -> Character in
            if let i = en.firstIndex(of: c) { return ru[i] }
            if let i = ru.firstIndex(of: c) { return en[i] }
            return c
        })
    }

    /// Запрос, разобранный один раз на всё поиск по списку (а не на каждый трек).
    struct Query {
        let words: [(direct: String, swapped: String?)]
        init(_ query: String) {
            words = query.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init).map { w in
                let b = w.count >= 3 ? TrackSearch.fold(TrackSearch.swapLayout(w)) : ""
                return (TrackSearch.fold(w), b.count >= 3 && b.count >= w.count - 1 ? b : nil)
            }
        }
        var isEmpty: Bool { words.isEmpty }
        /// hay — уже приведённый fold() текст полей трека.
        func matches(_ hay: String) -> Bool {
            words.allSatisfy { w in
                (!w.direct.isEmpty && hay.contains(w.direct)) || (w.swapped.map { hay.contains($0) } ?? false)
            }
        }
    }

    static func hay(_ fields: [String?]) -> String { fields.compactMap { $0 }.map(fold).joined(separator: " ") }

    static func matches(_ query: String, in fields: [String?]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let hay = fields.compactMap { $0 }.map(fold).joined(separator: " ")
        // Каждое слово запроса должно найтись (порядок не важен)
        let words = q.split(separator: " ").map(String.init)
        return words.allSatisfy { w in
            let a = fold(w)
            if !a.isEmpty && hay.contains(a) { return true }
            // Не та раскладка — только для «нормальных» слов: целиком из букв одной раскладки, от 3 символов,
            // и после перевода не схлопнулось в пару букв (иначе «zzz» → «яяя» → «a» находит всё).
            guard w.count >= 3 else { return false }
            let b = fold(swapLayout(w))
            return b.count >= 3 && b.count >= w.count - 1 && hay.contains(b)
        }
    }
}

// MARK: - Сортировка

enum TrackSortKey: String {
    case title, type, bitrate, size, rating, target
}
