#if os(macOS)
import Foundation

/// iPodConverter --selftest-series: прогон разборщика по набору имён.
enum SeriesSelfTest {
    static let cases: [(String, String?, String?)] = [
        ("Breaking.Bad.S01E02.720p.WEB-DL.x264-GROUP", nil, nil),
        ("breaking bad s1e2", nil, nil),
        ("The Office S02.E05 - Halloween", nil, nil),
        ("Friends - 1x05 - The One with the East German Laundry Detergent", nil, nil),
        ("Sherlock Season 2 Episode 3 The Reichenbach Fall", nil, nil),
        ("Doctor Who Series 4 Episode 8", nil, nil),
        ("Чорнобиль Сезон 1 Серія 3", nil, nil),
        ("Чорнобиль - сезон один, серія три", nil, nil),
        ("Слуга народу 2 сезон 5 серія", nil, nil),
        ("Сваты - серия 1 - 1 сезон", nil, nil),
        ("Сваты 3-й сезон 7-я серия", nil, nil),
        ("Кухня. Сезон 2. Серия 10", nil, nil),
        ("Перший сезон, друга серія", "Шоу", nil),
        ("Гульня ў кальмара Сезон 1 Серыя 4", nil, nil),
        ("S1 - 0aeae first seria", "Моє шоу", nil),
        ("S1 - 05 - Пілот", "Моє шоу", nil),
        ("[SubsPlease] Frieren - 05 (1080p) [ABCD1234]", nil, nil),
        ("Episode 07", "Season 2", "Lost"),
        ("05 - Название серии", "Сезон 3", "Кухня"),
        ("Серия 12", "Интерны", nil),
        ("E03 The Pilot", "S01", "Mr Robot"),
        ("Mr.Robot.S03E10.1080p", nil, nil),
        // не сериалы
        ("Inception (2010) 1080p BluRay", nil, nil),
        ("Daft Punk - Get Lucky", nil, nil),
        ("Jay-Z - 99 Problems", nil, nil),
        ("1917.2019.1080p.mkv", nil, nil),
        ("Movie 1920x1080", nil, nil),
    ]

    static func run() {
        for (name, parent, grand) in cases {
            if let g = SeriesParser.parse(fileName: name, parentFolder: parent, grandparentFolder: grand) {
                print("✔ \(name)\n     → «\(g.show)» S\(g.season) E\(g.episode)" + (g.title.map { " «\($0)»" } ?? ""))
            } else {
                print("— \(name)\n     → не сериал")
            }
        }
    }
}
#endif
