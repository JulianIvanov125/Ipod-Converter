using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace IPodConverter;

public sealed partial class MainWindow : Window
{
    public sealed record ModelItem(string Id, string Title, bool SupportsMax, string Standard, string? Max);

    private readonly EngineClient _engine = new();
    private readonly Dictionary<string, ItemViewModel> _byId = new();
    private readonly List<ItemViewModel> _order = new();
    private readonly ObservableCollection<ItemViewModel> _visible = new();
    private readonly List<ModelItem> _models = new();
    private bool _applying;          // обновление из движка — не отправлять обратно
    private bool _running;
    private string _ipod = "";
    private bool _max;
    private string _out = "";
    private int _dupExtras;

    public MainWindow(string[] startupFiles)
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 760));
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);

        AddFilesText.Text = Strings.AddFiles;
        // Кнопки с иконкой и текстом — имена для экранного диктора (и автотестов).
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(AddFilesButton, Strings.AddFiles);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(AddFolderButton, Strings.AddFolder);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(OutputButton, Strings.Output);
        AddFolderText.Text = Strings.AddFolder;
        StandardButton.Content = Strings.Standard;
        MaxButton.Content = Strings.Maximum;
        ChooseOutputItem.Text = Strings.ChangeOutput;
        OpenOutputItem.Text = Strings.OpenOutput;
        ClearItem.Text = Strings.Clear;
        CheckUpdatesItem.Text = Strings.CheckUpdates;
        VersionItem.Text = Strings.AboutVersion(Updater.CurrentText);
        WhatsNewLink.Content = Strings.WhatsNew;
        SkipLink.Content = Strings.SkipVersion;
        TabAll.Text = Strings.All;
        TabMusic.Text = Strings.Music;
        TabVideos.Text = Strings.Videos;
        TabDups.Text = Strings.Duplicates;
        EmptyTitle.Text = Strings.DropHere;
        EmptyHint.Text = Strings.DropHint;
        List.ItemsSource = _visible;
        UpdateConvertButton();

        _engine.Received += o => DispatcherQueue.TryEnqueue(() => Apply(o));
        _engine.Exited += err => DispatcherQueue.TryEnqueue(() =>
        {
            ShowInfo(Strings.EngineStopped, err, InfoBarSeverity.Error);
            ConvertButton.IsEnabled = false;
        });
        Closed += (_, _) => { StopPlayer(); _engine.Dispose(); };
        ToolTipService.SetToolTip(PlayerSystemButton, Strings.OpenInSystemPlayer);
        ToolTipService.SetToolTip(PlayerFullButton, Strings.FullScreen);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PlayerFullButton, Strings.FullScreen);
        ToolTipService.SetToolTip(PlayerCloseButton, Strings.ClosePlayer);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PlayerSystemButton, Strings.OpenInSystemPlayer);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PlayerCloseButton, Strings.ClosePlayer);

        if (!_engine.Start())
        {
            ShowInfo(Strings.EngineMissing, "", InfoBarSeverity.Error);
            ConvertButton.IsEnabled = AddFilesButton.IsEnabled = AddFolderButton.IsEnabled = false;
            return;
        }
        if (startupFiles.Length > 0) _engine.Add(startupFiles);
        // Как на Mac: сама проверяет обновления не чаще раза в 20 часов.
        if (Updater.AutoCheckDue) _ = CheckForUpdates(manual: false);
    }

    // MARK: обновления

    private Updater.Release? _release;
    private CancellationTokenSource? _download;

    private async Task CheckForUpdates(bool manual)
    {
        try
        {
            var r = await Updater.FetchLatestAsync();
            Updater.SaveState();
            if (r.Version <= Updater.Current)
            {
                if (manual) ShowInfo(Strings.UpToDate(Updater.CurrentText), "", InfoBarSeverity.Success);
                return;
            }
            if (!manual && Updater.SkippedVersion == Updater.Format(r.Version)) return;
            _release = r;
            var oneClick = Updater.CanInstall(r);
            UpdateBar.Title = Strings.UpdateAvailable(Updater.Format(r.Version));
            UpdateBar.Message = Strings.YouHave(Updater.CurrentText) + (oneClick ? "" : " " + Strings.ZipUpdateHint);
            UpdateButton.Content = oneClick ? Strings.UpdateRestart : Strings.Download;
            UpdateButton.IsEnabled = true;
            UpdateProgress.Visibility = Visibility.Collapsed;
            UpdateBar.Severity = InfoBarSeverity.Informational;
            UpdateBar.IsOpen = true;
        }
        catch (Exception ex)
        {
            if (manual) ShowInfo(Strings.UpdateCheckFailed, ex.Message, InfoBarSeverity.Error);
        }
    }

    private void CheckUpdates_Click(object sender, RoutedEventArgs e) => _ = CheckForUpdates(manual: true);

    private void WhatsNew_Click(object sender, RoutedEventArgs e)
    {
        if (_release != null) Updater.OpenPage(_release.Page);
    }

    private void Skip_Click(object sender, RoutedEventArgs e)
    {
        if (_release != null) Updater.SaveState(skip: Updater.Format(_release.Version));
        UpdateBar.IsOpen = false;
    }

    private async void Update_Click(object sender, RoutedEventArgs e)
    {
        var r = _release;
        if (r == null) return;
        if (!Updater.CanInstall(r)) { Updater.OpenPage(r.Page); return; }
        if (_running) { ShowInfo(Strings.StopFirst, "", InfoBarSeverity.Warning); return; }
        UpdateButton.IsEnabled = false;
        UpdateBar.Message = Strings.Downloading;
        UpdateProgress.Value = 0;
        UpdateProgress.Visibility = Visibility.Visible;
        _download = new CancellationTokenSource();
        try
        {
            var progress = new Progress<double>(p => UpdateProgress.Value = p);
            var setup = await Updater.DownloadAsync(r, progress, _download.Token);
            if (!Updater.StartInstaller(setup))
            {
                UpdateBar.Message = Strings.UacDeclined;
                UpdateButton.IsEnabled = true;
                UpdateProgress.Visibility = Visibility.Collapsed;
                return;
            }
            // Установщик ждёт, пока окно закроется, ставит новую версию и открывает её сам.
            Close();
            Application.Current.Exit();
        }
        catch (Exception ex)
        {
            UpdateBar.Severity = InfoBarSeverity.Error;
            UpdateBar.Title = Strings.UpdateFailed;
            UpdateBar.Message = ex.Message;
            UpdateButton.IsEnabled = true;
            UpdateProgress.Visibility = Visibility.Collapsed;
        }
    }

    // MARK: состояние от движка

    private void Apply(JsonObject o)
    {
        var type = o["type"]?.GetValue<string>();
        if (type == "message")
        {
            var text = o["text"]?.GetValue<string>() ?? "";
            var error = o["error"]?.GetValue<bool>() ?? false;
            if (text.StartsWith("done:") && !error)
                ShowInfo(text.Replace("done:", Strings.Done + ":"), Strings.ITunesHint, InfoBarSeverity.Success);
            else
                ShowInfo(text, "", error ? InfoBarSeverity.Error : InfoBarSeverity.Informational);
            return;
        }
        if (type != "state") return;

        _applying = true;
        try
        {
            if (o["models"] is JsonArray models && _models.Count == 0)
            {
                foreach (var m in models.OfType<JsonObject>())
                    _models.Add(new ModelItem(m["id"]!.GetValue<string>(), m["title"]!.GetValue<string>(),
                        m["supportsMax"]?.GetValue<bool>() ?? false, m["standard"]?.GetValue<string>() ?? "",
                        m["max"]?.GetValue<string>()));
                ModelBox.ItemsSource = _models;
            }
            _ipod = o["ipod"]?.GetValue<string>() ?? _ipod;
            _max = o["max"]?.GetValue<bool>() ?? _max;
            _out = o["out"]?.GetValue<string>() ?? _out;
            _running = o["running"]?.GetValue<bool>() ?? false;
            var model = _models.FirstOrDefault(m => m.Id == _ipod);
            if (model != null && !ReferenceEquals(ModelBox.SelectedItem, model)) ModelBox.SelectedItem = model;
            var supportsMax = model?.SupportsMax ?? false;
            StandardButton.IsChecked = !_max || !supportsMax;
            MaxButton.IsChecked = _max && supportsMax;
            MaxButton.IsEnabled = supportsMax && !_running;
            StandardButton.IsEnabled = !_running;
            ModelBox.IsEnabled = !_running;
            StandardButton.Content = model != null ? $"{Strings.Standard} · {model.Standard}" : Strings.Standard;
            MaxButton.Content = model?.Max != null ? $"{Strings.Maximum} · {model.Max}" : Strings.Maximum;
            PresetText.Text = o["preset"]?.GetValue<string>() ?? "";
            OutputText.Text = _out.Length > 0 ? Path.GetFileName(_out.TrimEnd('/', '\\')) : Strings.Output;
            OutputPathItem.Text = _out.Replace('/', '\\');
            if (o["ffmpeg"]?.GetValue<bool>() == false) ShowInfo(Strings.FfmpegMissing, "", InfoBarSeverity.Error);

            // Файлы: обновляем существующие строки, новые добавляем, исчезнувшие убираем.
            var seen = new HashSet<string>();
            var order = new List<ItemViewModel>();
            foreach (var it in (o["items"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
            {
                var id = it["id"]!.GetValue<string>();
                seen.Add(id);
                if (!_byId.TryGetValue(id, out var vm)) { vm = new ItemViewModel(id); _byId[id] = vm; }
                if (vm.Update(it)) vm.Notify(null);
                order.Add(vm);
            }
            foreach (var gone in _byId.Keys.Where(k => !seen.Contains(k)).ToList()) _byId.Remove(gone);

            // Дубли видео
            var roles = new Dictionary<string, (string role, string group)>();
            _dupExtras = 0;
            foreach (var g in (o["dups"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
            {
                var key = g["key"]!.GetValue<string>();
                roles[g["keeper"]!.GetValue<string>()] = ("keep", key);
                foreach (var e in (g["extras"] as JsonArray ?? new JsonArray()))
                {
                    roles[e!.GetValue<string>()] = ("extra", key);
                    _dupExtras++;
                }
            }
            foreach (var vm in order)
            {
                var r = roles.TryGetValue(vm.Id, out var x) ? x : ("", "");
                vm.SetDup(r.Item1, r.Item2);
            }

            _order.Clear();
            _order.AddRange(order);
            RefreshVisible();
            UpdateConvertButton();
            var music = _order.Count(i => !i.IsVideo);
            SummaryText.Text = _order.Count > 0 ? Strings.Summary(music, _order.Count - music) : "";
        }
        finally { _applying = false; }
    }

    private string CurrentTab =>
        Tabs.SelectedItem == TabMusic ? "music" : Tabs.SelectedItem == TabVideos ? "videos" : Tabs.SelectedItem == TabDups ? "dups" : "all";

    private void RefreshVisible()
    {
        IEnumerable<ItemViewModel> list = CurrentTab switch
        {
            "music" => _order.Where(i => !i.IsVideo),
            "videos" => _order.Where(i => i.IsVideo),
            "dups" => _order.Where(i => i.DupRole.Length > 0).OrderBy(i => i.DupGroup).ThenBy(i => i.DupRole == "keep" ? 0 : 1),
            _ => _order,
        };
        var target = list.ToList();
        // Меняем коллекцию только при другом составе/порядке — иначе список мигает при каждом проценте.
        if (!target.SequenceEqual(_visible))
        {
            for (int i = _visible.Count - 1; i >= 0; i--)
                if (!target.Contains(_visible[i])) _visible.RemoveAt(i);
            for (int i = 0; i < target.Count; i++)
            {
                if (i < _visible.Count && ReferenceEquals(_visible[i], target[i])) continue;
                var at = _visible.IndexOf(target[i]);
                if (at >= 0) _visible.Move(at, i); else _visible.Insert(i, target[i]);
            }
        }
        var dups = CurrentTab == "dups";
        EmptyState.Visibility = _visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyTitle.Text = dups ? Strings.NoDuplicates : Strings.DropHere;
        EmptyHint.Visibility = dups ? Visibility.Collapsed : Visibility.Visible;
        TrashDupsButton.Visibility = dups && _dupExtras > 0 ? Visibility.Visible : Visibility.Collapsed;
        TrashDupsButton.Content = Strings.TrashExtras(_dupExtras);
        TrashDupsButton.IsEnabled = !_running;
    }

    private void UpdateConvertButton()
    {
        ConvertText.Text = _running ? Strings.Cancel : Strings.Convert;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(ConvertButton, ConvertText.Text);
        ConvertIcon.Glyph = _running ? "" : "";
        ConvertButton.IsEnabled = _running || _order.Any(i => i.IsChecked && i.State is "ready" or "failed" or "done" or "kept");
    }

    private void ShowInfo(string title, string message, InfoBarSeverity severity)
    {
        Info.ActionButton = null;
        Info.Title = title;
        Info.Message = message;
        Info.Severity = severity;
        Info.IsOpen = true;
    }

    // MARK: действия

    private async void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, CommitButtonText = Strings.AddFiles };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is { Count: > 0 }) _engine.Add(files.Select(f => f.Path));
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var folder = await PickFolder(PickerLocationId.VideosLibrary);
        if (folder != null) _engine.Add(new[] { folder });
    }

    private async Task<string?> PickFolder(PickerLocationId start)
    {
        var picker = new FolderPicker { SuggestedStartLocation = start };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    private void ModelBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_applying || ModelBox.SelectedItem is not ModelItem m || m.Id == _ipod) return;
        _engine.Set(ipod: m.Id);
    }

    private void Standard_Click(object sender, RoutedEventArgs e) { _engine.Set(max: false); StandardButton.IsChecked = true; }
    private void Max_Click(object sender, RoutedEventArgs e) { _engine.Set(max: true); MaxButton.IsChecked = true; }

    private async void ChooseOutput_Click(object sender, RoutedEventArgs e)
    {
        var folder = await PickFolder(PickerLocationId.VideosLibrary);
        if (folder != null) _engine.Set(output: folder);
    }

    private void OpenOutput_Click(object sender, RoutedEventArgs e)
    {
        if (_out.Length == 0) return;
        var path = _out.Replace('/', '\\');
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    private void Clear_Click(object sender, RoutedEventArgs e) => _engine.Clear();

    private void Convert_Click(object sender, RoutedEventArgs e)
    {
        if (_running) _engine.Cancel();
        else { Info.IsOpen = false; _engine.Convert(); }
    }

    private void Tabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => RefreshVisible();

    private static string IdOf(object sender) => (sender as FrameworkElement)?.Tag as string ?? "";

    private void Check_Click(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox cb) _engine.Check(IdOf(sender), cb.IsChecked == true);
    }

    private void Remove_Click(object sender, RoutedEventArgs e) => _engine.Remove(IdOf(sender));
    private void Keep_Click(object sender, RoutedEventArgs e) => _engine.Keep(IdOf(sender));

    private void ShowInFolder_Click(object sender, RoutedEventArgs e)
    {
        if (!_byId.TryGetValue(IdOf(sender), out var vm) || vm.Output.Length == 0) return;
        var path = vm.Output.Replace('/', '\\');
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }

    private async void TrashDups_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = Strings.TrashConfirmTitle,
            Content = Strings.TrashConfirmText,
            PrimaryButtonText = Strings.Ok,
            CloseButtonText = Strings.CancelButton,
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) _engine.TrashDuplicates();
    }

    // MARK: плеер

    private string? _playingPath;

    private void PlayOriginal_Click(object sender, RoutedEventArgs e)
    {
        if (_byId.TryGetValue(IdOf(sender), out var vm)) Play(vm, vm.Path, converted: false);
    }

    private void PlayConverted_Click(object sender, RoutedEventArgs e)
    {
        if (_byId.TryGetValue(IdOf(sender), out var vm) && vm.Output.Length > 0) Play(vm, vm.Output, converted: true);
    }

    private void Play(ItemViewModel vm, string path, bool converted)
    {
        try { PlayCore(vm, path, converted); }
        catch (Exception ex) { Log($"play setup error: {path}: {ex}"); }
    }

    private void PlayCore(ItemViewModel vm, string path, bool converted)
    {
        path = path.Replace('/', '\\');
        StopPlayer();
        if (Info.ActionButton != null) Info.IsOpen = false;   // старая ошибка «не могу воспроизвести» к новому файлу не относится
        _playingPath = path;
        PlayerTitle.Text = vm.ToString();
        PlayerWhich.Text = "· " + (converted ? Strings.ConvertedLower : Strings.Original);
        PlayerKindIcon.Glyph = vm.IsVideo ? "\uE714" : "\uE8D6";
        PlayerFullButton.Visibility = vm.IsVideo ? Visibility.Visible : Visibility.Collapsed;
        // Звук — компактно (только панель управления и обложка), видео — с картинкой.
        Player.Height = vm.IsVideo ? 340 : 150;
        Player.PosterSource = vm.IsVideo ? null : vm.Cover;
        // Сначала показать панель: в свёрнутой панели у MediaPlayerElement ещё нет шаблона, и первый запуск терялся.
        PlayerPanel.Visibility = Visibility.Visible;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (_playingPath != path) return;
            try
            {
                var player = new MediaPlayer { AutoPlay = true };
                player.MediaFailed += (_, args) => DispatcherQueue.TryEnqueue(() =>
                {
                    Log($"play failed: {path}: {args.Error} {args.ErrorMessage}");
                    if (_playingPath != path) return;
                    StopPlayer();
                    ShowInfo(Strings.CantPlay(Path.GetFileName(path)), Strings.CantPlayHint + (args.ErrorMessage is { Length: > 0 } m ? $" ({m})" : ""),
                        InfoBarSeverity.Warning);
                    Info.ActionButton = SystemPlayerButton(path);
                });
                player.Source = MediaSource.CreateFromUri(new Uri(path));
                Player.SetMediaPlayer(player);
                player.Play();
            }
            catch (Exception ex)
            {
                Log($"play error: {path}: {ex}");
                StopPlayer();
                ShowInfo(Strings.CantPlay(Path.GetFileName(path)), ex.Message, InfoBarSeverity.Warning);
                Info.ActionButton = SystemPlayerButton(path);
            }
        });
    }

    private static void Log(string text)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iPod Converter", "Logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "window.log"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [INFO] {text}\n");
        }
        catch { }
    }

    private Button SystemPlayerButton(string path)
    {
        var b = new Button { Content = Strings.OpenInSystemPlayer };
        b.Click += (_, _) => OpenInSystemPlayer(path);
        return b;
    }

    private static void OpenInSystemPlayer(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { }
    }

    private void StopPlayer()
    {
        var old = Player.MediaPlayer;
        if (old != null)
        {
            Player.SetMediaPlayer(null);
            // У MediaPlayerElement с самого начала есть свой пустой MediaPlayer — его Pause() бросает E_ABORT,
            // из-за этого первый запуск после открытия окна молча не срабатывал.
            try { old.Pause(); } catch (System.Runtime.InteropServices.COMException) { }
            try { old.Dispose(); } catch (System.Runtime.InteropServices.COMException) { }
        }
        PlayerPanel.Visibility = Visibility.Collapsed;
    }

    /// <summary>Во весь экран (Esc или двойной щелчок — обратно, это делает сам MediaPlayerElement).</summary>
    private void PlayerFull_Click(object sender, RoutedEventArgs e) => Player.IsFullWindow = true;

    private void PlayerClose_Click(object sender, RoutedEventArgs e) { StopPlayer(); _playingPath = null; }

    private void PlayerSystem_Click(object sender, RoutedEventArgs e)
    {
        if (_playingPath == null) return;
        var path = _playingPath;
        StopPlayer();
        OpenInSystemPlayer(path);
    }

    // MARK: перетаскивание

    private void Root_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = Strings.AddFiles;
        }
    }

    private async void Root_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var paths = items.Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
        if (paths.Count > 0) _engine.Add(paths);
    }
}
