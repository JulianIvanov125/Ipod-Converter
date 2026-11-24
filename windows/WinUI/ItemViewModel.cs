using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;

namespace IPodConverter;

/// <summary>Строка списка: один файл (трек или видео) и его состояние в движке.</summary>
public sealed class ItemViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public string Id { get; }
    public string Kind { get; private set; } = "";
    public string Path { get; private set; } = "";
    public string Name { get; private set; } = "";
    public string Title { get; private set; } = "";
    public string Subtitle { get; private set; } = "";
    public string Detail { get; private set; } = "";
    public string After { get; private set; } = "";
    public string State { get; private set; } = "";
    public string Status { get; private set; } = "";
    public string Output { get; private set; } = "";
    public string Category { get; private set; } = "";
    public double Progress { get; private set; }
    public bool IsChecked { get; private set; } = true;
    public string? CoverPath { get; private set; }
    public BitmapImage? Cover { get; private set; }
    /// <summary>Роль в группе дублей: "keep", "extra" или пусто.</summary>
    public string DupRole { get; set; } = "";
    public string DupGroup { get; set; } = "";

    public bool IsVideo => Kind == "video";
    public string Glyph => IsVideo ? "" : "";   // Video / Audio (Segoe Fluent Icons)
    public Visibility CoverVisibility => Cover != null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility GlyphVisibility => Cover == null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ProgressVisibility => State is "converting" or "queued" ? Visibility.Visible : Visibility.Collapsed;
    public bool ProgressIndeterminate => State == "queued";
    public double ProgressPercent => Progress * 100;
    public Visibility AfterVisibility => After.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SubtitleVisibility => Subtitle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility OpenVisibility => Output.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public bool IsFailed => State == "failed";
    public bool IsBusy => State is "converting" or "queued";
    public bool CanRemove => !IsBusy;
    /// <summary>Оригинал можно слушать/смотреть, когда файл прочитан (у битого файла — тоже: вдруг Windows его откроет).</summary>
    public bool CanPlayOriginal => State != "loading";
    public Visibility KeepVisibility => DupRole == "extra" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility KeeperBadgeVisibility => DupRole == "keep" ? Visibility.Visible : Visibility.Collapsed;

    public ItemViewModel(string id) => Id = id;

    /// <summary>Имя строки для экранного диктора и UI Automation.</summary>
    public override string ToString() => Subtitle.Length > 0 ? $"{Subtitle} — {Title}" : Title;

    /// <summary>Обновить из снимка движка; true — что-то поменялось.</summary>
    public bool Update(JsonObject o)
    {
        bool changed = false;
        void Set<T>(ref T field, T value, [CallerMemberName] string? _ = null)
        {
            if (!EqualityComparer<T>.Default.Equals(field, value)) { field = value; changed = true; }
        }
        string S(string k) => o[k]?.GetValue<string>() ?? "";

        var kind = S("kind"); Set(ref _kind, kind); Kind = _kind;
        var path = S("path"); Set(ref _path, path); Path = _path;
        var name = S("name"); Set(ref _name, name); Name = _name;
        var title = S("title"); if (title.Length == 0) title = System.IO.Path.GetFileNameWithoutExtension(name);
        Set(ref _title, title); Title = _title;
        Set(ref _subtitle, S("artist")); Subtitle = _subtitle;
        Set(ref _detail, S("detail")); Detail = _detail;
        Set(ref _after, S("after")); After = _after;
        Set(ref _state, S("state")); State = _state;
        Set(ref _output, S("output")); Output = _output;
        Set(ref _category, S("category")); Category = _category;
        Set(ref _progress, o["progress"]?.GetValue<double>() ?? 0); Progress = _progress;
        Set(ref _checked, o["checked"]?.GetValue<bool>() ?? true); IsChecked = _checked;
        var error = S("error");
        var status = State switch
        {
            "loading" => Strings.Reading,
            "ready" => "",
            "queued" => Strings.Queued,
            "converting" => $"{Progress * 100:0}%",
            "done" => Strings.Done,
            "kept" => Strings.KeptAsIs,
            "failed" => error,
            _ => State,
        };
        Set(ref _status, status); Status = _status;

        var cover = o["cover"]?.GetValue<string>();
        if (cover != CoverPath)
        {
            CoverPath = cover;
            changed = true;
            Cover = null;
            if (cover != null && File.Exists(cover))
            {
                try { Cover = new BitmapImage(new Uri(cover)) { DecodePixelWidth = 96 }; } catch { Cover = null; }
            }
        }
        return changed;
    }

    public void SetDup(string role, string group)
    {
        if (DupRole == role && DupGroup == group) return;
        DupRole = role; DupGroup = group;
        Notify(null);
    }

    public void Notify(string? property) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));

    private string _kind = "", _path = "", _name = "", _title = "", _subtitle = "", _detail = "", _after = "",
        _state = "", _output = "", _category = "", _status = "";
    private double _progress;
    private bool _checked = true;
}
