import Foundation
import Observation

/// Язык интерфейса. «Как в системе»: ru/uk/be берём из системы, любой другой язык → английский.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru, uk, be

    var id: String { rawValue }

    /// Название языка на нём самом.
    var nativeName: String {
        switch self {
        case .system: L.t("System", "Как в системе", "Як у системі", "Як у сістэме")
        case .en: "English"
        case .ru: "Русский"
        case .uk: "Українська"
        case .be: "Беларуская"
        }
    }

    static func fromSystem() -> AppLanguage {
        for id in Locale.preferredLanguages {
            switch String(id.prefix(2)) {
            case "ru": return .ru
            case "uk": return .uk
            case "be": return .be
            case "en": return .en
            default: continue
            }
        }
        return .en
    }
}

@Observable
final class LanguageSettings {
    static let shared = LanguageSettings()

    var choice: AppLanguage {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "language") }
    }

    /// Фактический язык (без «system»). Язык системы запоминаем: его спрашивает каждая строка интерфейса,
    /// а Locale.preferredLanguages на тысячах строк заметно тормозит. Обновляется при смене языка в системе.
    var current: AppLanguage { choice == .system ? systemLanguage : choice }
    private var systemLanguage = AppLanguage.fromSystem()
    @ObservationIgnored private var localeObserver: NSObjectProtocol?

    private init() {
        choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                                object: nil, queue: .main) { _ in
            let lang = AppLanguage.fromSystem()
            MainActor.assumeIsolated { LanguageSettings.shared.systemLanguage = lang }
        }
    }
}

/// Все строки интерфейса: английский, русский, украинский, белорусский.
enum L {
    static func t(_ en: String, _ ru: String, _ uk: String, _ be: String) -> String {
        switch LanguageSettings.shared.current {
        case .ru: ru
        case .uk: uk
        case .be: be
        default: en
        }
    }

    // Шапка
    static var whichIPod: String { t("Convert for which iPod", "Под какой iPod конвертируем", "Під який iPod конвертуємо", "Пад які iPod канвертуем") }
    static var waitForConversion: String { t("Wait until the conversion finishes", "Дождитесь окончания конвертации", "Дочекайтеся завершення конвертації", "Дачакайцеся заканчэння канвертацыі") }
    static var catalogHelp: String { t("All iPods — star the ones you own", "Все iPod — отметьте свои звёздочкой", "Усі iPod — позначте свої зірочкою", "Усе iPod — адзначце свае зорачкай") }
    static var standard: String { t("Standard", "Стандарт", "Стандарт", "Стандарт") }
    static var maximum: String { t("Maximum", "Максимум", "Максимум", "Максімум") }
    static func maxHelp(_ size: String, _ mbps: String) -> String {
        t("Maximum: H.264 up to \(size), up to \(mbps) Mbps — a sharper picture, but a bigger file. If the iPod rejects the file, update its firmware or switch back to Standard.",
          "Максимум: H.264 до \(size), до \(mbps) Мбит/с — картинка резче, но файл больше. Если iPod не примет файл — обновите прошивку или верните «Стандарт».",
          "Максимум: H.264 до \(size), до \(mbps) Мбіт/с — картинка чіткіша, але файл більший. Якщо iPod не прийме файл — оновіть прошивку або поверніть «Стандарт».",
          "Максімум: H.264 да \(size), да \(mbps) Мбіт/с — карцінка больш выразная, але файл большы. Калі iPod не прыме файл — абнавіце прашыўку або вярніце «Стандарт».")
    }
    static var appearance: String { t("Appearance", "Оформление", "Вигляд", "Выгляд") }
    static var glassMode: String { t("Glass (translucency)", "Стекло (полупрозрачность)", "Скло (напівпрозорість)", "Шкло (паўпразрыстасць)") }
    static var language: String { t("Language", "Язык", "Мова", "Мова") }

    // Низ окна
    static var add: String { t("Add", "Добавить", "Додати", "Дадаць") }
    static var openOutputFolder: String { t("Open the folder with converted files", "Открыть папку с готовыми файлами", "Відкрити теку з готовими файлами", "Адкрыць папку з гатовымі файламі") }
    static func toMusic(_ playlist: String) -> String {
        t("Add to Music → playlist “\(playlist)”", "В «Музыку» → плейлист «\(playlist)»", "У «Музику» → плейлист «\(playlist)»", "У «Музыку» → плэйліст «\(playlist)»")
    }
    static var toMusicHelp: String {
        t("After conversion the file goes into the Music app, into the selected iPod's playlist. In Finder, set each iPod to sync only its own playlist.",
          "После конвертации файл попадёт в Music.app в плейлист выбранного iPod. В Finder для каждого iPod включите синхронизацию только его плейлиста.",
          "Після конвертації файл потрапить у Music.app у плейлист вибраного iPod. У Finder для кожного iPod увімкніть синхронізацію лише його плейлиста.",
          "Пасля канвертацыі файл трапіць у Music.app у плэйліст выбранага iPod. У Finder для кожнага iPod уключыце сінхранізацыю толькі яго плэйліста.")
    }
    static var convertAll: String { t("Convert all", "Конвертировать все", "Конвертувати все", "Канвертаваць усё") }

    // Список моделей
    static var allIPods: String { t("All iPods with video", "Все iPod с видео", "Усі iPod з відео", "Усе iPod з відэа") }
    static var starredAppear: String { t("Starred models appear as tabs", "Отмеченные звёздочкой появятся во вкладках", "Позначені зірочкою з'являться у вкладках", "Адзначаныя зорачкай з'явяцца ва ўкладках") }
    static func upTo(_ size: String) -> String { t("(up to \(size))", "(до \(size))", "(до \(size))", "(да \(size))") }
    static var keepOne: String { t("At least one iPod must stay in the tabs", "Хотя бы один iPod должен остаться во вкладках", "Хоча б один iPod має залишитися у вкладках", "Хаця б адзін iPod павінен застацца ва ўкладках") }

    // Пустой экран
    static var dropHere: String { t("Drop a video here", "Перетащите видео сюда", "Перетягніть відео сюди", "Перацягніце відэа сюды") }
    static var orClick: String {
        t("or click to choose a file · MP4, MOV, MKV, AVI…", "или нажмите, чтобы выбрать файл · MP4, MOV, MKV, AVI…",
          "або натисніть, щоб вибрати файл · MP4, MOV, MKV, AVI…", "або націсніце, каб выбраць файл · MP4, MOV, MKV, AVI…")
    }

    // Карточка
    static var readingInfo: String { t("Reading file info…", "Читаю информацию о файле…", "Читаю інформацію про файл…", "Чытаю інфармацыю пра файл…") }
    static var unknownArtist: String { t("Unknown artist", "Артист не указан", "Виконавця не вказано", "Выканаўца не пазначаны") }
    static var removeFromList: String { t("Remove from list", "Убрать из списка", "Прибрати зі списку", "Прыбраць са спісу") }
    static var now: String { t("Now", "Сейчас", "Зараз", "Цяпер") }
    static var after: String { t("After", "После", "Після", "Пасля") }
    static var resolution: String { t("Resolution", "Разрешение", "Роздільність", "Раздзяляльнасць") }
    static var quality: String { t("Quality", "Качество", "Якість", "Якасць") }
    static var size: String { t("Size", "Размер", "Розмір", "Памер") }
    static var duration: String { t("Duration", "Длительность", "Тривалість", "Працягласць") }
    static var format: String { t("Format", "Формат", "Формат", "Фармат") }
    static var noAudio: String { t("no audio", "без звука", "без звуку", "без гуку") }
    static var kbps: String { t("kbps", "кбит/с", "кбіт/с", "кбіт/с") }
    static var mbps: String { t("Mbps", "Мбит/с", "Мбіт/с", "Мбіт/с") }
    static var kHz: String { t("kHz", "кГц", "кГц", "кГц") }
    static var readyToConvert: String { t("Ready to convert", "Готово к конвертации", "Готово до конвертації", "Гатова да канвертацыі") }
    static var stop: String { t("Stop", "Остановить", "Зупинити", "Спыніць") }
    static func convertedFor(_ m: String) -> String { t("Converted for \(m)", "Отконвертировано для \(m)", "Сконвертовано для \(m)", "Канвертавана для \(m)") }
    static var convertAgain: String { t("Convert again (for the selected iPod)", "Конвертировать ещё раз (под выбранный iPod)", "Конвертувати ще раз (під вибраний iPod)", "Канвертаваць яшчэ раз (пад выбраны iPod)") }
    static var convert: String { t("Convert", "Конвертировать", "Конвертувати", "Канвертаваць") }
    static var showOriginalInFinder: String { t("Show original in Finder", "Показать оригинал в Finder", "Показати оригінал у Finder", "Паказаць арыгінал у Finder") }
    static var showResultInFinder: String { t("Show converted file in Finder", "Показать готовый файл в Finder", "Показати готовий файл у Finder", "Паказаць гатовы файл у Finder") }
    static var showInFinder: String { t("Show in Finder", "Показать в Finder", "Показати у Finder", "Паказаць у Finder") }
    static var fileAppearsLater: String { t("The file will appear after conversion", "Файл появится после конвертации", "Файл з'явиться після конвертації", "Файл з'явіцца пасля канвертацыі") }

    // Подтверждение удаления во время конвертации
    static var areYouSure: String { t("Are you sure?", "Вы точно уверены?", "Ви точно впевнені?", "Вы сапраўды ўпэўненыя?") }
    static var removeWhileConverting: String {
        t("This video is converting right now. The conversion will stop and the unfinished file will be deleted.",
          "Это видео сейчас конвертируется. Конвертация остановится, а недоделанный файл удалится.",
          "Це відео зараз конвертується. Конвертацію буде зупинено, а незавершений файл видалено.",
          "Гэта відэа зараз канвертуецца. Канвертацыя спыніцца, а незавершаны файл будзе выдалены.")
    }
    static var stopAndRemove: String { t("Stop and remove", "Остановить и удалить", "Зупинити й видалити", "Спыніць і выдаліць") }
    static var removeTab: String { t("Remove tab", "Убрать вкладку", "Прибрати вкладку", "Прыбраць укладку") }
    static var stopAndRemoveTab: String { t("Stop and remove tab", "Остановить и убрать", "Зупинити й прибрати", "Спыніць і прыбраць") }
    static func removeTabWhileConverting(_ m: String) -> String {
        t("Converting for \(m) right now. The conversion will stop and unfinished files will be deleted.",
          "Сейчас идёт конвертация под \(m). Она остановится, а недоделанные файлы удалятся.",
          "Зараз триває конвертація під \(m). Її буде зупинено, а незавершені файли видалено.",
          "Зараз ідзе канвертацыя пад \(m). Яна спыніцца, а незавершаныя файлы будуць выдалены.")
    }
    // Разделы и музыка
    static var sectionMusic: String { t("Music", "Музыка", "Музика", "Музыка") }
    static var sectionVideos: String { t("Videos", "Видео", "Відео", "Відэа") }
    static func scopeAll(_ n: Int) -> String { t("All tracks (\(n))", "Все треки (\(n))", "Усі треки (\(n))", "Усе трэкі (\(n))") }
    static func scopeSelected(_ n: Int) -> String { t("Selected (\(n))", "Выбранные (\(n))", "Вибрані (\(n))", "Выбраныя (\(n))") }
    static var checkAll: String { t("Select all", "Выбрать все", "Вибрати всі", "Выбраць усе") }
    static var uncheckAll: String { t("Deselect all", "Снять все", "Зняти всі", "Зняць усе") }
    static var checkedIgnored: String {
        t("“All tracks” is on — checkmarks are ignored", "Включено «Все треки» — отметки не учитываются",
          "Увімкнено «Усі треки» — позначки не враховуються", "Уключана «Усе трэкі» — адзнакі не ўлічваюцца")
    }
    static var formatLabel: String { t("Format:", "Формат:", "Формат:", "Фармат:") }
    static var formatHelp: String {
        t("""
          What you get for the iPod.
          Auto — files that already play are copied as is; lossless → Apple Lossless; the rest → AAC 256.
          AAC / MP3 — everything at the chosen bitrate (saves space). Files already in that format at the same or lower bitrate are copied without re-encoding.
          Apple Lossless — lossless sources → ALAC 16-bit. Lossy files (MP3, AAC…) can't become lossless, so they stay as they are.
          """,
          """
          Что получится для iPod.
          Авто — то, что уже играет, копируется как есть; lossless → Apple Lossless; остальное → AAC 256.
          AAC / MP3 — всё в выбранном битрейте (экономит место). Файлы, уже в этом формате с таким же или меньшим битрейтом, копируются без пережатия.
          Apple Lossless — lossless-исходники → ALAC 16 бит. Из lossy (MP3, AAC…) lossless не сделать, они остаются как есть.
          """,
          """
          Що вийде для iPod.
          Авто — те, що вже грає, копіюється як є; lossless → Apple Lossless; решта → AAC 256.
          AAC / MP3 — усе у вибраному бітрейті (економить місце). Файли, що вже в цьому форматі з таким самим або меншим бітрейтом, копіюються без перетискання.
          Apple Lossless — lossless-джерела → ALAC 16 біт. З lossy (MP3, AAC…) lossless не зробити, вони лишаються як є.
          """,
          """
          Што атрымаецца для iPod.
          Аўта — тое, што ўжо грае, капіюецца як ёсць; lossless → Apple Lossless; астатняе → AAC 256.
          AAC / MP3 — усё ў выбраным бітрэйце (эканоміць месца). Файлы, што ўжо ў гэтым фармаце з такім жа ці меншым бітрэйтам, капіююцца без перацісквання.
          Apple Lossless — lossless-крыніцы → ALAC 16 біт. З lossy (MP3, AAC…) lossless не зрабіць, яны застаюцца як ёсць.
          """)
    }
    static func videosCount(_ n: Int) -> String { t("Videos: \(n)", "Видео: \(n)", "Відео: \(n)", "Відэа: \(n)") }
    // Поиск и сортировка
    static var searchPlaceholder: String { t("Search", "Поиск", "Пошук", "Пошук") }
    static var searchHelp: String {
        t("Title, artist, album or file name. Latin and Cyrillic are the same (kino = Кино), the wrong keyboard layout works too (rbyj = кино).",
          "Название, артист, альбом или имя файла. Латиница и кириллица равны (kino = Кино), можно набирать и не в той раскладке (rbyj = кино).",
          "Назва, виконавець, альбом або ім'я файлу. Латиниця й кирилиця рівні (kino = Кіно), можна набирати й не в тій розкладці (rbyj = кино).",
          "Назва, выканаўца, альбом або імя файла. Лацінка і кірыліца роўныя (kino = Кіно), можна набіраць і не ў той раскладцы (rbyj = кино).")
    }
    static var searchNothing: String { t("Nothing found", "Ничего не найдено", "Нічого не знайдено", "Нічога не знойдзена") }
    static var sortAscHelp: String { t("Sort ascending", "Сортировать по возрастанию", "Сортувати за зростанням", "Сартаваць па ўзрастанні") }
    static var sortDescHelp: String { t("Sort descending", "Сортировать по убыванию", "Сортувати за спаданням", "Сартаваць па змяншэнні") }
    static var sortResetHelp: String { t("Back to the original order", "Вернуть исходный порядок", "Повернути початковий порядок", "Вярнуць першапачатковы парадак") }
    static func scopeAllVideos(_ n: Int) -> String { t("All (\(n))", "Все (\(n))", "Усі (\(n))", "Усе (\(n))") }
    static func filterAll(_ n: Int) -> String { t("All \(n)", "Все \(n)", "Усі \(n)", "Усе \(n)") }
    static var filterHelp: String {
        t("Show only music videos, films or series", "Показывать только клипы, фильмы или сериалы",
          "Показувати лише кліпи, фільми або серіали", "Паказваць толькі кліпы, фільмы або серыялы")
    }
    static func forSelected(_ n: Int) -> String {
        t("Type for selected (\(n)):", "Тип для выбранных (\(n)):", "Тип для вибраних (\(n)):", "Тып для выбраных (\(n)):")
    }
    // Свои настройки выхода
    static func outPresetQuality(_ m: String) -> String { t("\(m) preset", "Пресет \(m)", "Пресет \(m)", "Прэсэт \(m)") }
    static func outPreset(_ m: String) -> String { t("Output: \(m) preset", "Выход: пресет \(m)", "Вихід: пресет \(m)", "Выхад: прэсэт \(m)") }
    static var outCustom: String { t("Output: custom", "Выход: свои настройки", "Вихід: свої налаштування", "Выхад: свае налады") }
    static var outHelp: String { t("Container, codec, resolution, bitrate and audio of converted videos", "Контейнер, кодек, разрешение, битрейт и звук готовых видео", "Контейнер, кодек, роздільність, бітрейт і звук готових відео", "Кантэйнер, кодэк, раздзяляльнасць, бітрэйт і гук гатовых відэа") }
    static var outToggle: String { t("Custom output settings", "Свои настройки выхода", "Свої налаштування виходу", "Свае налады выхаду") }
    static func outToggleHint(_ m: String) -> String { t("Off — the automatic \(m) preset is used", "Выключено — используется автоматический пресет \(m)", "Вимкнено — використовується автоматичний пресет \(m)", "Выключана — выкарыстоўваецца аўтаматычны прэсэт \(m)") }
    static var outContainer: String { t("Container", "Контейнер", "Контейнер", "Кантэйнер") }
    static var outCodec: String { t("Codec", "Кодек", "Кодек", "Кодэк") }
    static var outVideoBitrate: String { t("Video bitrate", "Битрейт видео", "Бітрейт відео", "Бітрэйт відэа") }
    static var outAudio: String { t("Audio", "Звук", "Звук", "Гук") }
    static var outAsPreset: String { t("As in preset", "Как в пресете", "Як у пресеті", "Як у прэсэце") }
    static var outOriginalSize: String { t("original size", "размер оригинала", "розмір оригіналу", "памер арыгінала") }
    static var outReset: String { t("Reset to preset", "Сбросить к пресету", "Скинути до пресету", "Скінуць да прэсэта") }
    static func outWarning(_ m: String) -> String { t("\(m) may not play these files:", "\(m) может не воспроизвести такие файлы:", "\(m) може не відтворити такі файли:", "\(m) можа не прайграць такія файлы:") }
    static var issueCodec: String { t("iPods play only H.264", "iPod играет только H.264", "iPod грає лише H.264", "iPod грае толькі H.264") }
    static func issueResolution(_ w: Int, _ h: Int) -> String { t("resolution above \(w)×\(h)", "разрешение больше \(w)×\(h)", "роздільність більша за \(w)×\(h)", "раздзяляльнасць большая за \(w)×\(h)") }
    static func issueBitrate(_ k: Int) -> String { t("video bitrate above \(k) kbps", "битрейт видео выше \(k) кбит/с", "бітрейт відео вищий за \(k) кбіт/с", "бітрэйт відэа вышэй за \(k) кбіт/с") }
    static var issueAudio: String { t("audio above 160 kbps", "звук выше 160 кбит/с", "звук вищий за 160 кбіт/с", "гук вышэй за 160 кбіт/с") }
    static func convertSelectedN(_ n: Int) -> String {
        t("Convert selected (\(n))", "Конвертировать выбранные (\(n))", "Конвертувати вибрані (\(n))", "Канвертаваць выбраныя (\(n))")
    }
    static var nothingChecked: String {
        t("Nothing is checked — tick files in “All”", "Ничего не отмечено — отметьте файлы во «Все»",
          "Нічого не позначено — позначте файли в «Усі»", "Нічога не адзначана — адзначце файлы ва «Усе»")
    }
    static var outMusicTitle: String { t("Music output", "Выход для музыки", "Вихід для музики", "Выхад для музыкі") }
    static var outSampleRate: String { t("Sample rate", "Частота", "Частота", "Частата") }
    static func outAutoPreset(_ m: String) -> String { t("Auto (\(m) preset)", "Авто (пресет \(m))", "Авто (пресет \(m))", "Аўта (прэсэт \(m))") }
    static var outMusicKeepsCompatible: String {
        t("Files copied as is keep their own sample rate.", "Файлы, которые копируются как есть, сохраняют свою частоту.",
          "Файли, що копіюються як є, зберігають свою частоту.", "Файлы, якія капіююцца як ёсць, захоўваюць сваю частату.")
    }
    @MainActor static func outMusicSummary(_ o: AudioOutputSettings) -> String {
        var parts = [o.choice == .auto ? "Auto" : o.choice.title]
        if o.choice.usesBitrate { parts.append("\(o.kbps) \(kbps)") }
        if o.sampleRate > 0 { parts.append(o.sampleRate == 44100 ? "44.1 \(kHz)" : "48 \(kHz)") }
        return t("Output: ", "Выход: ", "Вихід: ", "Выхад: ") + parts.joined(separator: " · ")
    }
    static func yourIPod(_ m: String) -> String { t("Your \(m)", "Ваш \(m)", "Ваш \(m)", "Ваш \(m)") }
    static var connectedBadge: String { t("connected", "подключён", "підключений", "падключаны") }
    static var connectedHelp: String {
        t("This iPod is connected now", "Этот iPod сейчас подключён", "Цей iPod зараз підключений", "Гэты iPod зараз падключаны")
    }
    static var itemOutToggle: String { t("Custom settings for this video", "Свои настройки для этого видео", "Свої налаштування для цього відео", "Свае налады для гэтага відэа") }
    static var trackOutToggle: String { t("Custom format for this track", "Свой формат для этого трека", "Свій формат для цього треку", "Свой фармат для гэтага трэка") }
    static var itemOutHint: String { t("Off — the general Output settings are used", "Выключено — используются общие настройки «Выход»", "Вимкнено — використовуються загальні налаштування «Вихід»", "Выключана — выкарыстоўваюцца агульныя налады «Выхад»") }
    static func applyToChecked(_ n: Int) -> String { t("Apply to checked (\(n))", "Применить к выбранным (\(n))", "Застосувати до вибраних (\(n))", "Прымяніць да выбраных (\(n))") }
    static var sameAsAll: String { t("Same as all", "Как у всех", "Як у всіх", "Як ва ўсіх") }
    static var customMark: String { t("custom", "свои", "свої", "свае") }
    // Подсказка по синхронизации
    static var syncGuideTitle: String { t("How to sync with your iPod", "Как синхронизировать с iPod", "Як синхронізувати з iPod", "Як сінхранізаваць з iPod") }
    static func syncConnected(_ m: String) -> String { t("Connected: \(m)", "Подключён: \(m)", "Підключено: \(m)", "Падключаны: \(m)") }
    static var syncStep1: String {
        t("Connect the iPod and select it in the Finder sidebar (Locations).",
          "Подключите iPod и выберите его в боковой панели Finder (раздел «Места»).",
          "Підключіть iPod і виберіть його в бічній панелі Finder (розділ «Місця»).",
          "Падключыце iPod і выберыце яго ў бакавой панэлі Finder (раздзел «Месцы»).")
    }
    static func syncStep2(_ p: String) -> String {
        t("Music tab: turn on “Sync music”, choose “Selected playlists…” and tick “\(p)”.",
          "Вкладка «Музыка»: включите синхронизацию, выберите «Выбранные плейлисты…» и отметьте «\(p)».",
          "Вкладка «Музика»: увімкніть синхронізацію, виберіть «Вибрані плейлисти…» і позначте «\(p)».",
          "Укладка «Музыка»: уключыце сінхранізацыю, выберыце «Выбраныя плэйлісты…» і адзначце «\(p)».")
    }
    static func syncStep3(_ p: String) -> String {
        t("Movies and TV Shows tabs: turn on sync and tick the films and series you converted (or the “\(p)” playlist, if Finder offers it).",
          "Вкладки «Фильмы» и «Телешоу»: включите синхронизацию и отметьте сконвертированные фильмы и сериалы (или плейлист «\(p)», если Finder его предлагает).",
          "Вкладки «Фільми» та «Телешоу»: увімкніть синхронізацію й позначте сконвертовані фільми та серіали (або плейлист «\(p)», якщо Finder його пропонує).",
          "Укладкі «Фільмы» і «Тэлешоу»: уключыце сінхранізацыю і адзначце канвертаваныя фільмы і серыялы (або плэйліст «\(p)», калі Finder яго прапануе).")
    }
    static var syncStep4: String { t("Click “Sync” (or “Apply”).", "Нажмите «Синхронизировать» (или «Применить»).", "Натисніть «Синхронізувати» (або «Застосувати»).", "Націсніце «Сінхранізаваць» (або «Ужыць»).") }
    static var syncNote: String {
        t("Each iPod gets its own playlist, so music for one iPod doesn't end up on another. Covers and ratings come from the Music app.",
          "У каждого iPod свой плейлист, поэтому музыка для одного iPod не попадёт на другой. Обложки и оценки iPod берёт из «Музыки».",
          "У кожного iPod свій плейлист, тож музика для одного iPod не потрапить на інший. Обкладинки й оцінки iPod бере з «Музики».",
          "У кожнага iPod свой плэйліст, таму музыка для аднаго iPod не трапіць на іншы. Вокладкі і ацэнкі iPod бярэ з «Музыкі».")
    }
    static var syncOpenFinder: String { t("Open Finder", "Открыть Finder", "Відкрити Finder", "Адкрыць Finder") }
    static func convertsFor(_ m: String) -> String { t("Converting for \(m)", "Конвертация под \(m)", "Конвертація під \(m)", "Канвертацыя пад \(m)") }
    static var ambiguousHint: String {
        t("5G and 5.5G can't be told apart automatically — click ⌄ next to the name to choose.",
          "5G и 5.5G не различить автоматически — выберите модель кнопкой ⌄ рядом с названием.",
          "5G і 5.5G не розрізнити автоматично — оберіть модель кнопкою ⌄ поруч із назвою.",
          "5G і 5.5G не адрозніць аўтаматычна — выберыце мадэль кнопкай ⌄ побач з назвай.")
    }
    static var chooseModelHelp: String {
        t("Which iPod is it: 5G or 5.5G? 5.5G can play video up to 640×480 (Maximum quality).",
          "Какой это iPod: 5G или 5.5G? 5.5G показывает видео до 640×480 (качество «Максимум»).",
          "Який це iPod: 5G чи 5.5G? 5.5G показує відео до 640×480 (якість «Максимум»).",
          "Які гэта iPod: 5G ці 5.5G? 5.5G паказвае відэа да 640×480 (якасць «Максімум»).")
    }
    static func thisIs(_ m: String) -> String { t("This is \(m)", "Это \(m)", "Це \(m)", "Гэта \(m)") }
    static var noIPodTitle: String { t("Choose your iPod", "Выберите iPod", "Виберіть iPod", "Выберыце iPod") }
    static var noIPodSubtitle: String {
        t("Star your iPod in “List iPods picks” — then you can add files. A connected iPod is added automatically.",
          "Отметьте свой iPod звёздочкой в «List iPods picks» — после этого можно добавлять файлы. Подключённый iPod добавляется сам.",
          "Позначте свій iPod зірочкою в «List iPods picks» — після цього можна додавати файли. Підключений iPod додається сам.",
          "Адзначце свой iPod зорачкай у «List iPods picks» — пасля гэтага можна дадаваць файлы. Падключаны iPod дадаецца сам.")
    }
    static var noIPodButton: String { t("Choose iPod", "Выбрать iPod", "Вибрати iPod", "Выбраць iPod") }
    static var trackFormatMenu: String { t("Format for this track…", "Формат для этого трека…", "Формат для цього треку…", "Фармат для гэтага трэка…") }
    static var accessDeniedTitle: String { t("No access to the iPod", "Нет доступа к iPod", "Немає доступу до iPod", "Няма доступу да iPod") }
    static var accessDeniedText: String {
        t("You didn't allow access to removable volumes, so the app can't tell which iPod is connected. Choose it here manually — or allow access in System Settings → Privacy & Security → Files & Folders.",
          "Доступ к съёмным носителям не разрешён, поэтому приложение не знает, какой iPod подключён. Выберите его здесь вручную — или разрешите доступ: Системные настройки → Конфиденциальность и безопасность → Файлы и папки.",
          "Доступ до знімних носіїв не дозволено, тому застосунок не знає, який iPod підключено. Виберіть його тут вручну — або дозвольте доступ: Системні параметри → Приватність і безпека → Файли й папки.",
          "Доступ да здымных носьбітаў не дазволены, таму праграма не ведае, які iPod падключаны. Выберыце яго тут уручную — або дазвольце доступ: Сістэмныя налады → Прыватнасць і бяспека → Файлы і папкі.")
    }
    static var openPrivacySettings: String { t("Open settings", "Открыть настройки", "Відкрити налаштування", "Адкрыць налады") }
    static var unknownIPodHint: String {
        t("An iPod is connected, but its model wasn't recognized — choose it manually.",
          "iPod подключён, но модель не определена — выберите её вручную.",
          "iPod підключено, але модель не визначено — виберіть її вручну.",
          "iPod падключаны, але мадэль не вызначана — выберыце яе ўручную.")
    }
    static var permTitle: String { t("An iPod is connected", "Подключён iPod", "Підключено iPod", "Падключаны iPod") }
    static var permMessage: String {
        t("Allow access to the iPod so the app can recognize its model and name and add its tab? macOS will ask for permission.",
          "Разрешить доступ к iPod, чтобы приложение определило его модель и имя и добавило вкладку? macOS попросит подтвердить.",
          "Дозволити доступ до iPod, щоб застосунок визначив його модель та ім'я й додав вкладку? macOS попросить підтвердити.",
          "Дазволіць доступ да iPod, каб праграма вызначыла яго мадэль і імя і дадала ўкладку? macOS папросіць пацвердзіць.")
    }
    static var permAllow: String { t("Allow", "Разрешить", "Дозволити", "Дазволіць") }
    static var permNotNow: String { t("Not now", "Не сейчас", "Не зараз", "Не цяпер") }
    static var clearList: String { t("Clear list", "Очистить список", "Очистити список", "Ачысціць спіс") }
    static var colTrack: String { t("Track", "Трек", "Трек", "Трэк") }
    static var colType: String { t("Type", "Тип", "Тип", "Тып") }
    static var colBitrate: String { t("Bitrate", "Битрейт", "Бітрейт", "Бітрэйт") }
    static func colFor(_ m: String) -> String { t("For \(m)", "Для \(m)", "Для \(m)", "Для \(m)") }
    static var compatibleBadge: String { t("Fits as is", "Подходит", "Підходить", "Падыходзіць") }
    static var compatibleHelp: String {
        t("This format already plays on the selected iPod — the file is copied to the folder as is, without re-encoding (no quality loss).",
          "Этот формат уже играет на выбранном iPod — файл копируется в папку как есть, без перекодирования (качество не теряется).",
          "Цей формат уже грає на вибраному iPod — файл копіюється в теку як є, без перекодування (якість не втрачається).",
          "Гэты фармат ужо грае на выбраным iPod — файл капіюецца ў папку як ёсць, без перакадавання (якасць не губляецца).")
    }
    static var alacHelp: String {
        t("Lossless source → Apple Lossless, 16-bit, up to 48 kHz: no quality loss within what the iPod can play.",
          "Lossless-исходник → Apple Lossless, 16 бит, до 48 кГц: без потерь в пределах того, что играет iPod.",
          "Lossless-джерело → Apple Lossless, 16 біт, до 48 кГц: без втрат у межах того, що грає iPod.",
          "Lossless-крыніца → Apple Lossless, 16 біт, да 48 кГц: без страт у межах таго, што грае iPod.")
    }
    static var aacHelp: String {
        t("Format the iPod can't play → AAC 256 kbps (Apple encoder).",
          "Формат, который iPod не играет → AAC 256 кбит/с (кодер Apple).",
          "Формат, який iPod не грає → AAC 256 кбіт/с (кодер Apple).",
          "Фармат, які iPod не грае → AAC 256 кбіт/с (кодэр Apple).")
    }
    static var queued: String { t("Queued", "В очереди", "У черзі", "У чарзе") }
    static var coverMakerTitle: String { t("Playlist cover", "Обложка плейлиста", "Обкладинка плейлиста", "Вокладка плэйліста") }
    static var coverMakerHelp: String { t("Make a cover for this playlist", "Сделать обложку для плейлиста", "Зробити обкладинку для плейлиста", "Зрабіць вокладку для плэйліста") }
    static var coverText: String { t("Text", "Текст", "Текст", "Тэкст") }
    static var coverSubtitle: String { t("Caption (optional)", "Подпись (необязательно)", "Підпис (необов’язково)", "Подпіс (неабавязкова)") }
    static var coverFromArtwork: String { t("From your track covers", "Из обложек ваших треков", "З обкладинок ваших треків", "З вокладак вашых трэкаў") }
    static var coverColor1: String { t("Color 1", "Цвет 1", "Колір 1", "Колер 1") }
    static var coverColor2: String { t("Color 2", "Цвет 2", "Колір 2", "Колер 2") }
    static var copyImage: String { t("Copy", "Скопировать", "Скопіювати", "Скапіяваць") }
    static var saveCover: String { t("Save", "Сохранить", "Зберегти", "Захаваць") }
    static var coverHowTo: String {
        t("Music doesn't let apps set playlist covers. Open the playlist in Music, click its cover and drop this picture there.",
          "«Музыка» не даёт программам ставить обложку плейлиста. Откройте плейлист в «Музыке», нажмите на его обложку и перетащите туда эту картинку.",
          "«Музика» не дозволяє програмам ставити обкладинку плейлиста. Відкрийте плейлист у «Музиці», натисніть на його обкладинку й перетягніть туди цю картинку.",
          "«Музыка» не дае праграмам ставіць вокладку плэйліста. Адкрыйце плэйліст у «Музыцы», націсніце на яго вокладку і перацягніце туды гэтую карцінку.")
    }
    static var processTimedOut: String {
        t("the file took too long to read — it may be damaged or the disk is too slow",
          "файл читается слишком долго — возможно, он повреждён или диск слишком медленный",
          "файл читається занадто довго — можливо, він пошкоджений або диск занадто повільний",
          "файл чытаецца занадта доўга — магчыма, ён пашкоджаны або дыск занадта павольны")
    }
    static func storageLine(free: String, total: String) -> String {
        t("iPod: \(free) free of \(total)", "iPod: свободно \(free) из \(total)", "iPod: вільно \(free) з \(total)", "iPod: вольна \(free) з \(total)")
    }
    static func storageNeed(_ n: String) -> String { t("needs ≈ \(n)", "нужно ≈ \(n)", "потрібно ≈ \(n)", "трэба ≈ \(n)") }
    static func storageNotEnough(_ n: String) -> String {
        t("Not enough space: about \(n) more is needed — remove something from the iPod or convert fewer files.",
          "Места не хватит: нужно ещё около \(n) — удалите что-то с iPod или выберите меньше файлов.",
          "Місця не вистачить: потрібно ще близько \(n) — видаліть щось з iPod або виберіть менше файлів.",
          "Месца не хопіць: трэба яшчэ каля \(n) — выдаліце нешта з iPod або выберыце менш файлаў.")
    }
    static func storageHelp(_ name: String) -> String {
        t("Free space on “\(name)” right now and the approximate size of the files after conversion. Syncing copies them to the iPod.",
          "Свободное место на «\(name)» сейчас и примерный размер файлов после конвертации. При синхронизации они копируются на iPod.",
          "Вільне місце на «\(name)» зараз і приблизний розмір файлів після конвертації. Під час синхронізації вони копіюються на iPod.",
          "Вольнае месца на «\(name)» зараз і прыкладны памер файлаў пасля канвертацыі. Пры сінхранізацыі яны капіююцца на iPod.")
    }
    static var toMusicLibrary: String { t("Add to Music", "В «Музыку»", "У «Музику»", "У «Музыку»") }
    static var toMusicLibraryHelp: String {
        t("After conversion tracks go into your Music library — with covers and tags, ready to sync to the iPod.",
          "После конвертации треки попадут в медиатеку «Музыки» — с обложками и тегами, готовые к синхронизации с iPod.",
          "Після конвертації треки потраплять у медіатеку «Музики» — з обкладинками й тегами, готові до синхронізації з iPod.",
          "Пасля канвертацыі трэкі трапяць у медыятэку «Музыкі» — з вокладкамі і тэгамі, гатовыя да сінхранізацыі з iPod.")
    }
    static var intoPlaylist: String { t("Into playlist", "В плейлист", "У плейлист", "У плэйліст") }
    static var intoPlaylistHelp: String {
        t("Also collect these tracks into a playlist — after syncing it is ready on the iPod.",
          "Ещё и собрать эти треки в плейлист — после синхронизации он будет готов на iPod.",
          "Ще й зібрати ці треки в плейлист — після синхронізації він буде готовий на iPod.",
          "Яшчэ і сабраць гэтыя трэкі ў плэйліст — пасля сінхранізацыі ён будзе гатовы на iPod.")
    }
    static var playlistNamePlaceholder: String { t("Playlist name", "Название плейлиста", "Назва плейлиста", "Назва плэйліста") }
    static var inLibrary: String { t("In the Music library", "В медиатеке «Музыки»", "У медіатеці «Музики»", "У медыятэцы «Музыкі»") }
    static var copyForSupport: String { t("Copy for support", "Скопировать для поддержки", "Скопіювати для підтримки", "Скапіяваць для падтрымкі") }
    static var copyForSupportHelp: String {
        t("Copies what succeeded, where it failed and the error text — send it to the developer.",
          "Копирует, что прошло, где упало и текст ошибки — отправьте разработчику.",
          "Копіює, що пройшло, де впало і текст помилки — надішліть розробнику.",
          "Капіюе, што прайшло, дзе ўпала і тэкст памылкі — дашліце распрацоўшчыку.")
    }
    static var copied: String { t("Copied", "Скопировано", "Скопійовано", "Скапіявана") }
    static func addingToMusicN(_ done: Int, _ total: Int) -> String {
        t("Adding to Music… \(done) of \(total)", "Добавляю в «Музыку»… \(done) из \(total)",
          "Додаю в «Музику»… \(done) з \(total)", "Дадаю ў «Музыку»… \(done) з \(total)")
    }
    static func addedToMusicPartial(_ done: Int, _ total: Int) -> String {
        t("added to Music: \(done) of \(total)", "в «Музыку» добавлено \(done) из \(total)",
          "до «Музики» додано \(done) з \(total)", "у «Музыку» дададзена \(done) з \(total)")
    }
    static func notInMusic(_ e: String) -> String {
        t("Not added to Music: \(e)", "Не добавлен в «Музыку»: \(e)", "Не додано до «Музики»: \(e)", "Не дададзена ў «Музыку»: \(e)")
    }
    static var videosReadyTitle: String { t("Videos ready", "Видео готовы", "Відео готові", "Відэа гатовыя") }
    static func videosSummary(done: Int, failed: Int) -> String {
        failed == 0 ? t("Converted: \(done).", "Сконвертировано: \(done).", "Сконвертовано: \(done).", "Сканвертавана: \(done).")
            : t("Converted: \(done), errors: \(failed).", "Сконвертировано: \(done), с ошибкой: \(failed).",
                "Сконвертовано: \(done), з помилкою: \(failed).", "Сканвертавана: \(done), з памылкай: \(failed).")
    }
    static func batchProgress(_ done: Int, _ total: Int) -> String {
        t("\(done) of \(total)", "\(done) из \(total)", "\(done) з \(total)", "\(done) з \(total)")
    }
    static var dropTracks: String { t("Drop tracks or a folder here", "Перетащите треки или папку сюда", "Перетягніть треки або теку сюди", "Перацягніце трэкі або папку сюды") }
    static var orClickTracks: String {
        t("or click to choose · FLAC, OGG, Opus, WMA, APE, MP3…", "или нажмите, чтобы выбрать · FLAC, OGG, Opus, WMA, APE, MP3…",
          "або натисніть, щоб вибрати · FLAC, OGG, Opus, WMA, APE, MP3…", "або націсніце, каб выбраць · FLAC, OGG, Opus, WMA, APE, MP3…")
    }
    static var convertedHeader: String { t("Converted", "Готово", "Готово", "Гатова") }
    static var beforeAfterHelp: String {
        t("Before conversion → in the converted file", "Было до конвертации → в готовом файле",
          "Було до конвертації → у готовому файлі", "Было да канвертацыі → у гатовым файле")
    }
    static func convertN(_ n: Int) -> String { t("Convert (\(n))", "Конвертировать (\(n))", "Конвертувати (\(n))", "Канвертаваць (\(n))") }
    static var notAudio: String { t("No audio track in the file", "В файле нет звуковой дорожки", "У файлі немає звукової доріжки", "У файле няма гукавой дарожкі") }
    static var chooseTracks: String { t("Choose tracks or folders to convert", "Выберите треки или папки для конвертации", "Виберіть треки або теки для конвертації", "Выберыце трэкі або папкі для канвертацыі") }
    static func musicReady(_ m: String) -> String { t("Music ready for \(m)", "Музыка готова для \(m)", "Музика готова для \(m)", "Музыка гатова для \(m)") }
    static func musicSummary(converted: Int, kept: Int, failed: Int) -> String {
        var s = t("Converted: \(converted) · copied as is: \(kept)", "Сконвертировано: \(converted) · скопировано как есть: \(kept)",
                  "Сконвертовано: \(converted) · скопійовано як є: \(kept)", "Канвертавана: \(converted) · скапіявана як ёсць: \(kept)")
        if failed > 0 { s += t(" · errors: \(failed)", " · ошибок: \(failed)", " · помилок: \(failed)", " · памылак: \(failed)") }
        return s
    }
    static var trackRemoveWhileConverting: String {
        t("This track is converting right now. The conversion will stop and the unfinished file will be deleted.",
          "Этот трек сейчас конвертируется. Конвертация остановится, а недоделанный файл удалится.",
          "Цей трек зараз конвертується. Конвертацію буде зупинено, а незавершений файл видалено.",
          "Гэты трэк зараз канвертуецца. Канвертацыя спыніцца, а незавершаны файл будзе выдалены.")
    }

    // Папки, категории, TV
    static var chooseRootMessage: String {
        t("Where to save? “iPod Converter Music” and “iPod Converter Video” (with Music Videos, Films, Serials) will be created here.",
          "Куда сохранить? Здесь будут созданы «iPod Converter Music» и «iPod Converter Video» (в ней Music Videos, Films, Serials).",
          "Куди зберегти? Тут буде створено «iPod Converter Music» та «iPod Converter Video» (у ній Music Videos, Films, Serials).",
          "Куды захаваць? Тут будуць створаны «iPod Converter Music» і «iPod Converter Video» (у ёй Music Videos, Films, Serials).")
    }
    static var categoryHelp: String {
        t("Category decides the folder and how the iPod lists the video. Detected automatically — fix it if it's wrong.",
          "Категория определяет папку и раздел на iPod. Определяется автоматически — поправьте, если ошиблась.",
          "Категорія визначає теку й розділ на iPod. Визначається автоматично — виправте, якщо помилилась.",
          "Катэгорыя вызначае папку і раздзел на iPod. Вызначаецца аўтаматычна — выпраўце, калі памылілася.")
    }
    static var showField: String { t("Show", "Сериал", "Серіал", "Серыял") }
    static var seasonField: String { t("Season", "Сезон", "Сезон", "Сезон") }
    static var episodeField: String { t("Episode", "Серия", "Серія", "Серыя") }
    static var episodeTitleField: String { t("Episode title", "Название серии", "Назва серії", "Назва серыі") }
    static var titleField: String { t("Title", "Название", "Назва", "Назва") }
    static var yearField: String { t("Year", "Год", "Рік", "Год") }
    static var artistField: String { t("Artist", "Артист", "Виконавець", "Выканаўца") }
    static func toLibrary(_ playlist: String) -> String {
        t("Add to Music/TV → playlist “\(playlist)”", "В «Музыку»/TV → плейлист «\(playlist)»",
          "У «Музику»/TV → плейлист «\(playlist)»", "У «Музыку»/TV → плэйліст «\(playlist)»")
    }
    static var toLibraryHelp: String {
        t("Music videos go to Music, films and series go to the TV app — into the selected iPod's playlist. In Finder, sync each iPod with its own playlist (Movies and TV Shows tabs).",
          "Клипы попадут в «Музыку», фильмы и сериалы — в приложение TV, в плейлист выбранного iPod. В Finder синхронизируйте каждый iPod с его плейлистом (вкладки «Фильмы» и «Телешоу»).",
          "Кліпи потраплять у «Музику», фільми й серіали — у застосунок TV, у плейлист вибраного iPod. У Finder синхронізуйте кожен iPod з його плейлистом (вкладки «Фільми» та «Телешоу»).",
          "Кліпы трапяць у «Музыку», фільмы і серыялы — у праграму TV, у плэйліст выбранага iPod. У Finder сінхранізуйце кожны iPod з яго плэйлістам (укладкі «Фільмы» і «Тэлешоу»).")
    }
    static var musicApp: String { t("Music", "Музыка", "Музика", "Музыка") }
    static var tvApp: String { "TV" }
    static var addingToTV: String { t("Adding to TV…", "Добавляю в TV…", "Додаю в TV…", "Дадаю ў TV…") }
    static func inTV(_ p: String) -> String { t("In TV, playlist “\(p)”", "В TV, плейлист «\(p)»", "У TV, плейлист «\(p)»", "У TV, плэйліст «\(p)»") }
    static func noAppAccess(_ app: String) -> String {
        t("No access to \(app): System Settings → Privacy & Security → Automation",
          "Нет доступа к «\(app)»: Системные настройки → Конфиденциальность → Автоматизация",
          "Немає доступу до «\(app)»: Системні параметри → Приватність і безпека → Автоматизація",
          "Няма доступу да «\(app)»: Сістэмныя налады → Прыватнасць і бяспека → Аўтаматызацыя")
    }
    static func cantAddTo(_ app: String) -> String { t("Couldn't add to \(app): ", "Не удалось добавить в «\(app)»: ", "Не вдалося додати в «\(app)»: ", "Не ўдалося дадаць у «\(app)»: ") }

    // Плеер
    static var original: String { t("Original", "Оригинал", "Оригінал", "Арыгінал") }
    static var convertedShort: String { t("Converted", "После конвертации", "Після конвертації", "Пасля канвертацыі") }
    static var previewOriginal: String { t("Play original", "Просмотреть оригинал", "Переглянути оригінал", "Праглядзець арыгінал") }
    static var watchResult: String { t("Watch result", "Смотреть результат", "Дивитися результат", "Глядзець вынік") }
    static var listenResult: String { t("Listen to result", "Слушать результат", "Слухати результат", "Слухаць вынік") }
    static var preparingPreview: String { t("Preparing preview…", "Готовлю превью…", "Готую прев'ю…", "Рыхтую прэв'ю…") }
    static var previewFailed: String { t("Can't play this file", "Не получается воспроизвести файл", "Не вдається відтворити файл", "Не атрымліваецца прайграць файл") }
    static var previousItem: String { t("Previous", "Предыдущее", "Попереднє", "Папярэдняе") }
    static var nextItem: String { t("Next", "Следующее", "Наступне", "Наступнае") }
    static var pause: String { t("Pause", "Пауза", "Пауза", "Паўза") }
    static var playWord: String { t("Play", "Воспроизвести", "Відтворити", "Прайграць") }
    static var fullscreen: String { t("Full screen", "На весь экран", "На весь екран", "На ўвесь экран") }
    static var exitFullscreen: String { t("Exit full screen", "Выйти из полноэкранного режима", "Вийти з повноекранного режиму", "Выйсці з поўнаэкраннага рэжыму") }
    static var closePlayer: String { t("Close player", "Закрыть плеер", "Закрити плеєр", "Закрыць плэер") }
    static var volume: String { t("Volume", "Громкость", "Гучність", "Гучнасць") }
    static var mute: String { t("Mute", "Выключить звук", "Вимкнути звук", "Выключыць гук") }
    static var unmute: String { t("Unmute", "Включить звук", "Увімкнути звук", "Уключыць гук") }

    // Оценки
    static var colRating: String { t("Rating", "Оценка", "Оцінка", "Ацэнка") }
    static var ratingHelp: String {
        t("Rating from the file. It goes to Music together with the track and syncs to the iPod. Click the same star again to clear it.",
          "Оценка из файла. Уйдёт в «Музыку» вместе с треком и синхронизируется на iPod. Повторный клик по той же звезде снимает оценку.",
          "Оцінка з файлу. Піде в «Музику» разом із треком і синхронізується на iPod. Повторний клік по тій самій зірці знімає оцінку.",
          "Ацэнка з файла. Пойдзе ў «Музыку» разам з трэкам і сінхранізуецца на iPod. Паўторны клік па той жа зорцы здымае ацэнку.")
    }
    static var ratingSyncedHelp: String {
        t("The track is already in Music — changing the rating here changes it there too.",
          "Трек уже в «Музыке» — оценка меняется и там.",
          "Трек уже в «Музиці» — оцінка змінюється і там.",
          "Трэк ужо ў «Музыцы» — ацэнка змяняецца і там.")
    }

    // Режимы плеера
    static var shuffleOff: String { t("Shuffle: off", "Случайный порядок: выключен", "Випадковий порядок: вимкнено", "Выпадковы парадак: выключаны") }
    static var shuffleOn: String { t("Shuffle: on", "Случайный порядок: включён", "Випадковий порядок: увімкнено", "Выпадковы парадак: уключаны") }
#if os(macOS)
    static func repeatHelp(_ m: RepeatMode) -> String {
        switch m {
        case .off: t("Repeat: off — stops at the end of the list", "Повтор: выключен — в конце списка остановится", "Повтор: вимкнено — у кінці списку зупиниться", "Паўтор: выключаны — у канцы спіса спыніцца")
        case .all: t("Repeat: whole list", "Повтор: весь список по кругу", "Повтор: увесь список по колу", "Паўтор: увесь спіс па крузе")
        case .one: t("Repeat: this track", "Повтор: один трек", "Повтор: один трек", "Паўтор: адзін трэк")
        }
    }
#endif
    static var showLyricsNow: String { t("Show lyrics", "Показать текст песни", "Показати текст пісні", "Паказаць тэкст песні") }

    // Текст песни
    static var showLyrics: String { t("Show lyrics", "Показывать текст песни", "Показувати текст пісні", "Паказваць тэкст песні") }
    static var lyricsOnline: String { t("Search online (lrclib.net)", "Искать в интернете (lrclib.net)", "Шукати в інтернеті (lrclib.net)", "Шукаць у інтэрнэце (lrclib.net)") }
    static var lyricsOnlineHelp: String {
        t("Lyrics are taken from a .lrc file next to the track, then from the file's tags, then from lrclib.net — only artist, title, album and duration are sent there.",
          "Текст берётся из файла .lrc рядом с треком, затем из тегов файла, затем с lrclib.net — туда уходят только артист, название, альбом и длительность.",
          "Текст береться з файлу .lrc поруч із треком, потім із тегів файлу, потім з lrclib.net — туди йдуть лише виконавець, назва, альбом і тривалість.",
          "Тэкст бярэцца з файла .lrc побач з трэкам, потым з тэгаў файла, потым з lrclib.net — туды ідуць толькі выканаўца, назва, альбом і працягласць.")
    }
    static var lyricsSource: String { t("Source", "Источник", "Джерело", "Крыніца") }
    static var lyricsFromFile: String { t("file tags", "теги файла", "теги файлу", "тэгі файла") }
    static var lyricsSearching: String { t("Looking for lyrics…", "Ищу текст песни…", "Шукаю текст пісні…", "Шукаю тэкст песні…") }
    static var lyricsNotFound: String { t("Lyrics not found", "Текст не найден", "Текст не знайдено", "Тэкст не знойдзены") }
    static var lyricsNotFoundOffline: String {
        t("No lyrics in the file. Online search is off.", "В файле текста нет. Поиск в интернете выключен.",
          "У файлі тексту немає. Пошук в інтернеті вимкнено.", "У файле тэксту няма. Пошук у інтэрнэце выключаны.")
    }
    static var lyricsNotSynced: String { t("Lyrics without timing", "Текст без синхронизации", "Текст без синхронізації", "Тэкст без сінхранізацыі") }

    // Теги из интернета
    static var metaToggle: String { t("Fill tags", "Дополнять теги", "Доповнювати теги", "Дапаўняць тэгі") }
    static var metaHelp: String {
        t("Missing tags (title, artist, album, track number, year, genre) and covers are filled from the Apple Music catalog (iTunes Search). Existing tags are never overwritten. Found tags and covers are written into the file itself without re-encoding (the audio is untouched; the original is replaced only after a check). Only artist, album and title are sent — from tags or, if there are none, from file and folder names.",
          "Пустые теги (название, артист, альбом, номер трека, год, жанр) и обложки дополняются из каталога Apple Music (iTunes Search). То, что уже есть в файле, не перезаписывается. Найденные теги и обложка записываются прямо в файл без перекодирования (звук не меняется, оригинал заменяется только после проверки). Отправляются только артист, альбом и название — из тегов, а если их нет, из имени файла и папок.",
          "Порожні теги (назва, виконавець, альбом, номер треку, рік, жанр) і обкладинки доповнюються з каталогу Apple Music (iTunes Search). Те, що вже є у файлі, не перезаписується. Знайдені теги й обкладинка записуються просто у файл без перекодування (звук не змінюється, оригінал замінюється лише після перевірки). Надсилаються лише виконавець, альбом і назва — з тегів, а якщо їх немає, з назви файлу й тек.",
          "Пустыя тэгі (назва, выканаўца, альбом, нумар трэка, год, жанр) і вокладкі дапаўняюцца з каталога Apple Music (iTunes Search). Тое, што ўжо ёсць у файле, не перазапісваецца. Знойдзеныя тэгі і вокладка запісваюцца проста ў файл без перакадавання (гук не мяняецца, арыгінал замяняецца толькі пасля праверкі). Адпраўляюцца толькі выканаўца, альбом і назва — з тэгаў, а калі іх няма, з назвы файла і папак.")
    }
    static var metaSearching: String { t("Looking for missing tags…", "Ищу недостающие теги…", "Шукаю відсутні теги…", "Шукаю адсутныя тэгі…") }
    static func metaFound(_ what: String) -> String {
        t("Filled from Apple Music: \(what)", "Дополнено из Apple Music: \(what)", "Доповнено з Apple Music: \(what)", "Дапоўнена з Apple Music: \(what)")
    }
    static var metaNotFound: String {
        t("No confident match in Apple Music — tags left as they are", "В Apple Music не нашлось уверенного совпадения — теги оставлены как есть",
          "В Apple Music не знайшлося впевненого збігу — теги залишено як є", "У Apple Music не знайшлося ўпэўненага супадзення — тэгі пакінуты як ёсць")
    }
    static func metaField(_ key: String) -> String {
        switch key {
        case "title": t("title", "название", "назва", "назва")
        case "artist": t("artist", "артист", "виконавець", "выканаўца")
        case "album": t("album", "альбом", "альбом", "альбом")
        case "album_artist": t("album artist", "артист альбома", "виконавець альбому", "выканаўца альбома")
        case "track": t("track number", "номер трека", "номер треку", "нумар трэка")
        case "disc": t("disc", "диск", "диск", "дыск")
        case "date": t("year", "год", "рік", "год")
        case "genre": t("genre", "жанр", "жанр", "жанр")
        case "cover": t("cover", "обложка", "обкладинка", "вокладка")
        default: key
        }
    }

    static var cancel: String { t("Cancel", "Отмена", "Скасувати", "Скасаваць") }

    // Уведомления и «Музыка»
    static func videoReady(_ m: String) -> String { t("Video ready for \(m)", "Видео готово для \(m)", "Відео готове для \(m)", "Відэа гатова для \(m)") }
    static func convertedBody(_ title: String, folder: String) -> String {
        t("“\(title)” has been converted and is in the “\(folder)” folder.",
          "«\(title)» отконвертировано и лежит в папке «\(folder)».",
          "«\(title)» сконвертовано, файл лежить у теці «\(folder)».",
          "«\(title)» канвертавана, файл ляжыць у папцы «\(folder)».")
    }
    static var changeFolder: String { t("Change…", "Изменить…", "Змінити…", "Змяніць…") }
    static var resetFolder: String { t("Back to the default folder", "Вернуть папку по умолчанию", "Повернути типову теку", "Вярнуць папку па змаўчанні") }
    static var chooseFolderMessage: String { t("Choose where to save converted files", "Выберите, куда сохранять готовые файлы", "Виберіть, куди зберігати готові файли", "Выберыце, куды захоўваць гатовыя файлы") }
    static var chooseButton: String { t("Choose", "Выбрать", "Вибрати", "Выбраць") }
    static var saveTo: String { t("Save to", "Сохранять в", "Зберігати в", "Захоўваць у") }
    static var folderMissing: String { t("Folder not found — it will be created, or choose another one", "Папки нет — она будет создана, или выберите другую", "Теки немає — її буде створено, або виберіть іншу", "Папкі няма — яна будзе створана, або выберыце іншую") }
    static var addingToMusic: String { t("Adding to Music…", "Добавляю в «Музыку»…", "Додаю в «Музику»…", "Дадаю ў «Музыку»…") }
    static func inMusic(_ p: String) -> String { t("In Music, playlist “\(p)”", "В «Музыке», плейлист «\(p)»", "У «Музиці», плейлист «\(p)»", "У «Музыцы», плэйліст «\(p)»") }
    static func addedBody(_ title: String, _ p: String) -> String {
        t("“\(title)” was added to the “\(p)” playlist — connect your iPod to sync.",
          "«\(title)» добавлено в плейлист «\(p)» — подключите iPod для синхронизации.",
          "«\(title)» додано в плейлист «\(p)» — підключіть iPod для синхронізації.",
          "«\(title)» дададзена ў плэйліст «\(p)» — падключыце iPod для сінхранізацыі.")
    }
    static func notAddedBody(_ e: String) -> String {
        t("The file is ready but wasn't added to Music: \(e)", "Файл готов, но в «Музыку» не добавлен: \(e)",
          "Файл готовий, але в «Музику» не доданий: \(e)", "Файл гатовы, але ў «Музыку» не дададзены: \(e)")
    }
    static var noMusicAccess: String {
        t("No access to Music: System Settings → Privacy & Security → Automation",
          "Нет доступа к «Музыке»: Системные настройки → Конфиденциальность → Автоматизация",
          "Немає доступу до «Музики»: Системні параметри → Приватність і безпека → Автоматизація",
          "Няма доступу да «Музыкі»: Сістэмныя налады → Прыватнасць і бяспека → Аўтаматызацыя")
    }
    static var cantAddToMusic: String { t("Couldn't add to Music: ", "Не удалось добавить в «Музыку»: ", "Не вдалося додати в «Музику»: ", "Не ўдалося дадаць у «Музыку»: ") }
    static var chooseVideos: String { t("Choose videos to convert", "Выберите видео для конвертации", "Виберіть відео для конвертації", "Выберыце відэа для канвертацыі") }
    static var openVideo: String { t("Open Video…", "Открыть видео…", "Відкрити відео…", "Адкрыць відэа…") }

    // Ошибки
    static func toolNotFound(_ tool: String) -> String {
        t("\(tool) not found. Install it: brew install ffmpeg", "Не найден \(tool). Установите: brew install ffmpeg",
          "Не знайдено \(tool). Встановіть: brew install ffmpeg", "Не знойдзены \(tool). Усталюйце: brew install ffmpeg")
    }
    static var noVideoTrack: String { t("The file has no video track", "В файле нет видеодорожки", "У файлі немає відеодоріжки", "У файле няма відэадарожкі") }
    static var unreadable: String { t("Couldn't read the file — is it really a video?", "Не удалось прочитать файл — это точно видео?", "Не вдалося прочитати файл — це точно відео?", "Не ўдалося прачытаць файл — гэта сапраўды відэа?") }
    static var ffmpegFailed: String { t("ffmpeg exited with an error", "ffmpeg завершился с ошибкой", "ffmpeg завершився з помилкою", "ffmpeg завяршыўся з памылкай") }

    // Подписи моделей
    static var chubby: String { t("“fatty”", "«толстенький»", "«товстунчик»", "«тоўсценькі»") }
    static var withCamera: String { t("with camera", "с камерой", "з камерою", "з камерай") }
    static var gb: String { t("GB", "ГБ", "ГБ", "ГБ") }

    // Запись тегов в файл
    static var metaWrittenToFile: String {
        t("Written into the file itself (audio untouched).", "Записано в сам файл (звук не тронут).",
          "Записано в сам файл (звук не змінено).", "Запісана ў сам файл (гук не крануты).")
    }
    static func metaNotWritten(_ why: String) -> String {
        t("Not written into the file: \(why). Will be added to the converted copy.",
          "В файл не записано: \(why). Будет добавлено в готовую копию.",
          "У файл не записано: \(why). Буде додано в готову копію.",
          "У файл не запісана: \(why). Будзе дададзена ў гатовую копію.")
    }
    static var metaWriteUnsupported: String { t("this format is not supported", "этот формат не поддерживается", "цей формат не підтримується", "гэты фармат не падтрымліваецца") }
    static var metaWriteNothing: String { t("nothing to write", "нечего записывать", "нічого записувати", "няма чаго запісваць") }
    static var metaWriteCheckFailed: String {
        t("check after writing failed, the original is kept", "проверка после записи не прошла, оригинал оставлен",
          "перевірка після запису не пройшла, оригінал залишено", "праверка пасля запісу не прайшла, арыгінал пакінуты")
    }
    static func metaWriteWouldLose(_ what: String) -> String {
        t("would lose \(what), the original is kept", "потерялось бы: \(what), оригинал оставлен",
          "загубилося б: \(what), оригінал залишено", "згубілася б: \(what), арыгінал пакінуты")
    }

    // Дубликаты
    static func scopeDuplicates(_ n: Int) -> String { t("Duplicates (\(n))", "Дубликаты (\(n))", "Дублікати (\(n))", "Дублікаты (\(n))") }
    static var dupNone: String { t("No duplicates in the list", "Дубликатов в списке нет", "Дублікатів у списку немає", "Дублікатаў у спісе няма") }
    static var dupKeeper: String { t("Keep", "Оставим", "Залишимо", "Пакінем") }
    static var dupCopy: String { t("Copy", "Копия", "Копія", "Копія") }
    static var dupKeeperHelp: String {
        t("This file stays: the best quality in the group. Right-click another copy to keep it instead.",
          "Этот файл остаётся: лучшее качество в группе. Чтобы оставить другую копию, нажмите на неё правой кнопкой.",
          "Цей файл залишається: найкраща якість у групі. Щоб залишити іншу копію, натисніть на неї правою кнопкою.",
          "Гэты файл застаецца: лепшая якасць у групе. Каб пакінуць іншую копію, націсніце на яе правай кнопкай.")
    }
    static var dupKeeperHelpVideo: String {
        t("This file stays: the best quality in the group (bigger picture, newer codec, higher bitrate). Click “Keep this one instead” on another copy to keep it.",
          "Этот файл остаётся: лучшее качество в группе (больше картинка, новее кодек, выше битрейт). Чтобы оставить другую копию, нажмите у неё «Оставить этот вместо».",
          "Цей файл залишається: найкраща якість у групі (більша картинка, новіший кодек, вищий бітрейт). Щоб залишити іншу копію, натисніть у неї «Залишити цей замість».",
          "Гэты файл застаецца: лепшая якасць у групе (большая карцінка, навейшы кодэк, вышэйшы бітрэйт). Каб пакінуць іншую копію, націсніце ў яе «Пакінуць гэты замест».")
    }
    static var dupKeepThis: String { t("Keep this one instead", "Оставить этот вместо", "Залишити цей замість", "Пакінуць гэты замест") }
    static var dupTrashOne: String { t("Move to Trash", "В Корзину", "У Кошик", "У Сметніцу") }
    static func dupTrashN(_ n: Int) -> String { t("Move to Trash (\(n))", "В Корзину (\(n))", "У Кошик (\(n))", "У Сметніцу (\(n))") }
    static var dupSelectAllHelp: String {
        t("Selects only the extra copies — the file that stays in each group is never selected.",
          "Выбираются только лишние копии — файл, который остаётся в группе, не выбирается никогда.",
          "Вибираються лише зайві копії — файл, що залишається в групі, не вибирається ніколи.",
          "Выбіраюцца толькі лішнія копіі — файл, які застаецца ў групе, не выбіраецца ніколі.")
    }
    static func dupTrashConfirmTitle(_ n: Int) -> String {
        t("Move \(n) copies to Trash?", "Переместить копии в Корзину: \(n)?", "Перемістити копії в Кошик: \(n)?", "Перамясціць копіі ў Сметніцу: \(n)?")
    }
    static var dupTrashConfirmText: String {
        t("One file of each group stays. Files can be restored from the Trash.",
          "В каждой группе остаётся один файл. Файлы можно вернуть из Корзины.",
          "У кожній групі залишається один файл. Файли можна повернути з Кошика.",
          "У кожнай групе застаецца адзін файл. Файлы можна вярнуць са Сметніцы.")
    }
    static func dupTrashed(_ n: Int) -> String {
        t("Moved to Trash: \(n)", "Перемещено в Корзину: \(n)", "Переміщено в Кошик: \(n)", "Перамешчана ў Сметніцу: \(n)")
    }
    static func dupTrashFailed(_ ok: Int, _ bad: Int) -> String {
        t("Moved to Trash: \(ok), failed: \(bad).", "Перемещено в Корзину: \(ok), не удалось: \(bad).",
          "Переміщено в Кошик: \(ok), не вдалося: \(bad).", "Перамешчана ў Сметніцу: \(ok), не ўдалося: \(bad).")
    }

    // Сообщить о проблеме
    static var fbTitle: String { t("Report a Problem", "Сообщить о проблеме", "Повідомити про проблему", "Паведаміць пра праблему") }
    static var fbMenu: String { t("Report a Problem…", "Сообщить о проблеме…", "Повідомити про проблему…", "Паведаміць пра праблему…") }
    static var fbBug: String { t("Bug", "Ошибка", "Помилка", "Памылка") }
    static var fbIdea: String { t("Idea", "Идея", "Ідея", "Ідэя") }
    static var fbQuestion: String { t("Question", "Вопрос", "Питання", "Пытанне") }
    static var fbPlaceholderBug: String {
        t("What happened? What did you do before it?", "Что случилось? Что вы делали перед этим?",
          "Що сталося? Що ви робили перед цим?", "Што здарылася? Што вы рабілі перад гэтым?")
    }
    static var fbPlaceholder: String { t("Your message", "Ваше сообщение", "Ваше повідомлення", "Ваша паведамленне") }
    static var fbAttach: String {
        t("Attach diagnostics (app version, macOS, iPod models, recent log)", "Приложить сведения (версия, macOS, модели iPod, последние записи журнала)",
          "Додати відомості (версія, macOS, моделі iPod, останні записи журналу)", "Дадаць звесткі (версія, macOS, мадэлі iPod, апошнія запісы журнала)")
    }
    static var fbWhatIsSent: String { t("What will be sent", "Что будет отправлено", "Що буде надіслано", "Што будзе адпраўлена") }
    static var fbPrivacy: String {
        t("Your home folder is replaced with “~”. Nothing is sent automatically: GitHub opens a public issue form in the browser; email opens your mail app with the log attached — you review and send it yourself.",
          "Домашняя папка заменяется на «~». Ничего не отправляется само: GitHub открывает в браузере форму публичного issue, письмо — почтовую программу с журналом во вложении. Вы проверяете и отправляете сами.",
          "Домашня тека замінюється на «~». Нічого не надсилається саме: GitHub відкриває в браузері форму публічного issue, лист — поштову програму з журналом у вкладенні. Ви перевіряєте й надсилаєте самі.",
          "Хатняя папка замяняецца на «~». Нічога не адпраўляецца само: GitHub адкрывае ў браўзеры форму публічнага issue, ліст — паштовую праграму з журналам ва ўкладанні. Вы правяраеце і адпраўляеце самі.")
    }
    static var fbShowLog: String { t("Show Log in Finder", "Показать журнал в Finder", "Показати журнал у Finder", "Паказаць журнал у Finder") }
    static var fbEmail: String { t("Email", "Письмо", "Лист", "Ліст") }
    static var fbGitHub: String { t("Open on GitHub", "Открыть на GitHub", "Відкрити на GitHub", "Адкрыць на GitHub") }
    static var fbReportShort: String { t("Report", "Сообщить", "Повідомити", "Паведаміць") }
    static var fbReportHelp: String {
        t("Send this error to the developer (GitHub or email)", "Отправить эту ошибку разработчику (GitHub или письмо)",
          "Надіслати цю помилку розробнику (GitHub або лист)", "Адправіць гэтую памылку распрацоўшчыку (GitHub або ліст)")
    }

    // Правка тегов
    static var tagEditMenu: String { t("Edit Tags…", "Изменить теги…", "Змінити теги…", "Змяніць тэгі…") }
    static func tagEditMenuN(_ n: Int) -> String { t("Edit Tags of \(n) Tracks…", "Изменить теги \(n) треков…", "Змінити теги \(n) треків…", "Змяніць тэгі \(n) трэкаў…") }
    static var tagEditHint: String { t("Double-click to edit tags", "Двойной клик — изменить теги", "Подвійний клік — змінити теги", "Двайны клік — змяніць тэгі") }
    static var tagEditTitle: String { t("Edit Tags", "Теги трека", "Теги треку", "Тэгі трэка") }
    static func tagEditTitleN(_ n: Int) -> String { t("Tags of \(n) tracks", "Теги \(n) треков", "Теги \(n) треків", "Тэгі \(n) трэкаў") }
    static var tagTitle: String { t("Title", "Название", "Назва", "Назва") }
    static var tagArtist: String { t("Artist", "Артист", "Виконавець", "Выканаўца") }
    static var tagAlbum: String { t("Album", "Альбом", "Альбом", "Альбом") }
    static var tagAlbumArtist: String { t("Album artist", "Артист альбома", "Виконавець альбому", "Выканаўца альбома") }
    static var tagYear: String { t("Year", "Год", "Рік", "Год") }
    static var tagGenre: String { t("Genre", "Жанр", "Жанр", "Жанр") }
    static var tagTrack: String { t("Track #", "№ трека", "№ треку", "№ трэка") }
    static var tagDisc: String { t("Disc #", "№ диска", "№ диска", "№ дыска") }
    static var tagMixed: String { t("Mixed", "Разные", "Різні", "Розныя") }
    static var tagDropCover: String { t("Drop a picture here", "Перетащите картинку сюда", "Перетягніть зображення сюди", "Перацягніце малюнак сюды") }
    static var tagChooseCover: String { t("Choose…", "Выбрать…", "Вибрати…", "Выбраць…") }
    static var tagPasteCover: String { t("Paste", "Вставить", "Вставити", "Уставіць") }
    static var tagSave: String { t("Save to File", "Сохранить в файл", "Зберегти у файл", "Захаваць у файл") }
    static var tagBusy: String { t("the track is being converted", "трек сейчас конвертируется", "трек зараз конвертується", "трэк зараз канвертуецца") }
    static var tagCoverUnsupported: String {
        t("Covers can't be written into OGG/Opus files", "В OGG/Opus обложку записать нельзя", "В OGG/Opus обкладинку записати не можна", "У OGG/Opus вокладку запісаць нельга")
    }
    static var tagEditNote: String {
        t("Changes are written into the file itself without re-encoding; the original is replaced only after a check. If Music is open, the track there is updated too. Empty field = remove the tag.",
          "Изменения записываются прямо в файл без перекодирования; оригинал заменяется только после проверки. Если открыта «Музыка», трек обновится и там. Пустое поле — удалить тег.",
          "Зміни записуються просто у файл без перекодування; оригінал замінюється лише після перевірки. Якщо відкрита «Музика», трек оновиться і там. Порожнє поле — видалити тег.",
          "Змены запісваюцца проста ў файл без перакадавання; арыгінал замяняецца толькі пасля праверкі. Калі адкрыта «Музыка», трэк абновіцца і там. Пустое поле — выдаліць тэг.")
    }

    static func alreadyInMusic(_ n: Int) -> String {
        t("already in Music: \(n)", "уже в «Музыке»: \(n)", "уже в «Музиці»: \(n)", "ужо ў «Музыцы»: \(n)")
    }

    // Обложки → «Музыка»
    static var coverRepairButton: String { t("Covers → Music", "Обложки → «Музыка»", "Обкладинки → «Музика»", "Вокладкі → «Музыка»") }
    static var coverRepairHelp: String {
        t("Music sometimes shows an album grey although its tracks have covers. This sets each track's cover in Music again from its file (checked tracks, or all in the list). Music rewrites the files' artwork: same picture, audio unchanged.",
          "«Музыка» иногда показывает альбом серым, хотя у треков есть обложки. Эта кнопка заново ставит каждому треку в «Музыке» его обложку из файла (отмеченным или всем в списке). «Музыка» перезапишет обложку в файлах: та же картинка, звук не меняется.",
          "«Музика» іноді показує альбом сірим, хоча в треків є обкладинки. Ця кнопка заново ставить кожному треку в «Музиці» його обкладинку з файлу (позначеним або всім у списку). «Музика» перезапише обкладинку у файлах: те саме зображення, звук не змінюється.",
          "«Музыка» часам паказвае альбом шэрым, хоць у трэкаў ёсць вокладкі. Гэтая кнопка нанова ставіць кожнаму трэку ў «Музыцы» яго вокладку з файла (адзначаным або ўсім у спісе). «Музыка» перазапіша вокладку ў файлах: той самы малюнак, гук не мяняецца.")
    }
    static func coverRepairRunning(_ d: Int, _ n: Int) -> String { t("Covers: \(d) of \(n)", "Обложки: \(d) из \(n)", "Обкладинки: \(d) з \(n)", "Вокладкі: \(d) з \(n)") }
    static func coverRepairDone(_ ok: Int, _ notIn: Int, _ none: Int, _ bad: Int) -> String {
        var s = t("Covers updated in Music: \(ok)", "Обложки обновлены в «Музыке»: \(ok)", "Обкладинки оновлено в «Музиці»: \(ok)", "Вокладкі абноўлены ў «Музыцы»: \(ok)")
        if notIn > 0 { s += t(" · not in Music: \(notIn)", " · нет в «Музыке»: \(notIn)", " · немає в «Музиці»: \(notIn)", " · няма ў «Музыцы»: \(notIn)") }
        if none > 0 { s += t(" · no cover in file: \(none)", " · без обложки в файле: \(none)", " · без обкладинки у файлі: \(none)", " · без вокладкі ў файле: \(none)") }
        if bad > 0 { s += t(" · errors: \(bad)", " · ошибок: \(bad)", " · помилок: \(bad)", " · памылак: \(bad)") }
        return s
    }

    // Обновление
    static var updMenu: String { t("Check for Updates…", "Проверить обновления…", "Перевірити оновлення…", "Праверыць абнаўленні…") }
    static var updChecking: String { t("Checking for updates…", "Проверяю обновления…", "Перевіряю оновлення…", "Правяраю абнаўленні…") }
    static func updUpToDate(_ v: String) -> String { t("You have the latest version (\(v)).", "У вас последняя версия (\(v)).", "У вас остання версія (\(v)).", "У вас апошняя версія (\(v)).") }
    static func updAvailable(_ v: String) -> String { t("iPod Converter \(v) is available", "Доступна новая версия: \(v)", "Доступна нова версія: \(v)", "Даступная новая версія: \(v)") }
    static func updCurrent(_ v: String) -> String { t("You have \(v).", "У вас \(v).", "У вас \(v).", "У вас \(v).") }
    static var updManualHint: String {
        t("This update can't be installed automatically here — the download page will open.",
          "Здесь обновление не поставится само — откроется страница загрузки.",
          "Тут оновлення не встановиться саме — відкриється сторінка завантаження.",
          "Тут абнаўленне не ўсталюецца само — адкрыецца старонка загрузкі.")
    }
    static var updSkip: String { t("Skip This Version", "Пропустить эту версию", "Пропустити цю версію", "Прапусціць гэтую версію") }
    static var updLater: String { t("Later", "Позже", "Пізніше", "Пазней") }
    static var updInstall: String { t("Update and Restart", "Обновить и перезапустить", "Оновити й перезапустити", "Абнавіць і перазапусціць") }
    static var updOpenPage: String { t("Open Download Page", "Открыть страницу загрузки", "Відкрити сторінку завантаження", "Адкрыць старонку загрузкі") }
    static var updDownloading: String { t("Downloading the update…", "Скачиваю обновление…", "Завантажую оновлення…", "Спампоўваю абнаўленне…") }
    static var updInstalling: String { t("Installing — the app will restart…", "Устанавливаю — приложение перезапустится…", "Встановлюю — застосунок перезапуститься…", "Усталёўваю — праграма перазапусціцца…") }
    static var updAuto: String { t("Check automatically", "Проверять автоматически", "Перевіряти автоматично", "Правяраць аўтаматычна") }
    static var updCheckFailed: String { t("Couldn't check for updates", "Не удалось проверить обновления", "Не вдалося перевірити оновлення", "Не ўдалося праверыць абнаўленні") }
    static var updNoChecksum: String { t("The release has no checksum — download it manually", "У релиза нет контрольной суммы — скачайте вручную", "У релізу немає контрольної суми — завантажте вручну", "У рэліза няма кантрольнай сумы — спампуйце ўручную") }
    static var updDownloadFailed: String { t("Download failed", "Не удалось скачать", "Не вдалося завантажити", "Не ўдалося спампаваць") }
    static var updChecksumMismatch: String { t("The download is damaged (checksum mismatch) — nothing was installed", "Файл повреждён (контрольная сумма не совпала) — ничего не установлено", "Файл пошкоджено (контрольна сума не збіглася) — нічого не встановлено", "Файл пашкоджаны (кантрольная сума не супала) — нічога не ўсталявана") }
    static var updMountFailed: String { t("Couldn't open the downloaded DMG", "Не удалось открыть скачанный DMG", "Не вдалося відкрити завантажений DMG", "Не ўдалося адкрыць спампаваны DMG") }
    static var updBadPackage: String { t("The download doesn't contain the expected app", "В скачанном файле не то приложение", "У завантаженому файлі не той застосунок", "У спампаваным файле не тая праграма") }
    static var updCopyFailed: String { t("Couldn't copy the new version", "Не удалось скопировать новую версию", "Не вдалося скопіювати нову версію", "Не ўдалося скапіяваць новую версію") }
    static var close: String { t("Close", "Закрыть", "Закрити", "Закрыць") }
    static var updNotifyBody: String { t("Click to update — no need to download the DMG again.", "Нажмите, чтобы обновить — скачивать DMG заново не нужно.", "Натисніть, щоб оновити — завантажувати DMG знову не потрібно.", "Націсніце, каб абнавіць — спампоўваць DMG нанова не трэба.") }
}
