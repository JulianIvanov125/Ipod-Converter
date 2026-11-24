using System.Globalization;

namespace IPodConverter;

/// <summary>Строки окна на языке системы: английский, русский, украинский, белорусский (как в Mac-версии).</summary>
public static class Strings
{
    private static readonly int Lang = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName switch
    {
        "ru" => 1, "uk" => 2, "be" => 3, _ => 0,
    };

    private static string T(string en, string ru, string uk, string be) => Lang switch { 1 => ru, 2 => uk, 3 => be, _ => en };

    public static string AddFiles => T("Add Files", "Добавить файлы", "Додати файли", "Дадаць файлы");
    public static string AddFolder => T("Add Folder", "Добавить папку", "Додати теку", "Дадаць тэчку");
    public static string Convert => T("Convert", "Конвертировать", "Конвертувати", "Канвертаваць");
    public static string Cancel => T("Stop", "Остановить", "Зупинити", "Спыніць");
    public static string Clear => T("Clear List", "Очистить список", "Очистити список", "Ачысціць спіс");
    public static string Standard => T("Standard", "Стандарт", "Стандарт", "Стандарт");
    public static string Maximum => T("Maximum", "Максимум", "Максимум", "Максімум");
    public static string Output => T("Output", "Выход", "Вихід", "Выхад");
    public static string ChangeOutput => T("Choose Output Folder…", "Выбрать папку вывода…", "Вибрати теку виводу…", "Выбраць тэчку вываду…");
    public static string OpenOutput => T("Open Output Folder", "Открыть папку вывода", "Відкрити теку виводу", "Адкрыць тэчку вываду");
    public static string All => T("All", "Все", "Усі", "Усе");
    public static string Music => T("Music", "Музыка", "Музика", "Музыка");
    public static string Videos => T("Videos", "Видео", "Відео", "Відэа");
    public static string Duplicates => T("Duplicates", "Дубликаты", "Дублікати", "Дублікаты");
    public static string DropHere => T("Drop music and videos here", "Перетащите сюда музыку и видео", "Перетягніть сюди музику та відео", "Перацягніце сюды музыку і відэа");
    public static string DropHint => T("FLAC, MP3, WAV, Opus, MKV, MP4, AVI, WebM… — or use Add Files", "FLAC, MP3, WAV, Opus, MKV, MP4, AVI, WebM… — или кнопка «Добавить файлы»",
        "FLAC, MP3, WAV, Opus, MKV, MP4, AVI, WebM… — або кнопка «Додати файли»", "FLAC, MP3, WAV, Opus, MKV, MP4, AVI, WebM… — або кнопка «Дадаць файлы»");
    public static string NoDuplicates => T("No duplicate videos", "Дубликатов видео нет", "Дублікатів відео немає", "Дублікатаў відэа няма");
    public static string Reading => T("Reading…", "Читаю…", "Читаю…", "Чытаю…");
    public static string Queued => T("Waiting", "В очереди", "У черзі", "У чарзе");
    public static string Done => T("Done", "Готово", "Готово", "Гатова");
    public static string KeptAsIs => T("Copied as is — iPod plays it", "Скопирован как есть — iPod его играет", "Скопійовано як є — iPod його грає", "Скапіяваны як ёсць — iPod яго грае");
    public static string Remove => T("Remove from List", "Убрать из списка", "Прибрати зі списку", "Прыбраць са спісу");
    public static string ShowInFolder => T("Show in Folder", "Показать в папке", "Показати в теці", "Паказаць у тэчцы");
    public static string KeepThis => T("Keep this one instead", "Оставить эту", "Залишити цю", "Пакінуць гэту");
    public static string Keeper => T("Stays", "Остаётся", "Залишається", "Застаецца");
    public static string TrashExtras(int n) => T($"Move {n} to Recycle Bin", $"В Корзину ({n})", $"У Кошик ({n})", $"У Сметніцу ({n})");
    public static string TrashConfirmTitle => T("Move extra copies to the Recycle Bin?", "Убрать лишние копии в Корзину?", "Прибрати зайві копії в Кошик?", "Прыбраць лішнія копіі ў Сметніцу?");
    public static string TrashConfirmText => T("The copy marked “Stays” is not touched. You can restore files from the Recycle Bin.",
        "Копия с пометкой «Остаётся» не трогается. Файлы можно вернуть из Корзины.",
        "Копія з позначкою «Залишається» не змінюється. Файли можна повернути з Кошика.",
        "Копія з пазнакай «Застаецца» не крануецца. Файлы можна вярнуць са Сметніцы.");
    public static string Ok => T("Move to Recycle Bin", "В Корзину", "У Кошик", "У Сметніцу");
    public static string CancelButton => T("Cancel", "Отмена", "Скасувати", "Скасаваць");
    public static string EngineMissing => T("Conversion engine (iPodConverter.exe) not found next to the app. Reinstall iPod Converter.",
        "Не найден движок конвертации (iPodConverter.exe) рядом с программой. Переустановите iPod Converter.",
        "Не знайдено рушій конвертації (iPodConverter.exe) поруч з програмою. Перевстановіть iPod Converter.",
        "Не знойдзены рухавік канвертацыі (iPodConverter.exe) побач з праграмай. Пераўсталюйце iPod Converter.");
    public static string EngineStopped => T("The conversion engine stopped", "Движок конвертации остановился", "Рушій конвертації зупинився", "Рухавік канвертацыі спыніўся");
    public static string FfmpegMissing => T("ffmpeg.exe not found: put it in the “engine” folder next to the app or add it to PATH",
        "Не найден ffmpeg.exe: положите его в папку «engine» рядом с программой или добавьте в PATH",
        "Не знайдено ffmpeg.exe: покладіть його в теку «engine» поруч з програмою або додайте в PATH",
        "Не знойдзены ffmpeg.exe: пакладзіце яго ў тэчку «engine» побач з праграмай або дадайце ў PATH");
    public static string ITunesHint => T("Ready files are in the output folder — add them to iTunes and sync your iPod.",
        "Готовые файлы — в папке вывода: добавьте их в iTunes и синхронизируйте iPod.",
        "Готові файли — у теці виводу: додайте їх в iTunes і синхронізуйте iPod.",
        "Гатовыя файлы — у тэчцы вываду: дадайце іх у iTunes і сінхранізуйце iPod.");
    public static string Summary(int music, int videos) => T($"{music} tracks · {videos} videos", $"Треков: {music} · видео: {videos}",
        $"Треків: {music} · відео: {videos}", $"Трэкаў: {music} · відэа: {videos}");
    public static string ChooseFiles => T("Choose music and videos", "Выберите музыку и видео", "Виберіть музику та відео", "Выберыце музыку і відэа");
}
