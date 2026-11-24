using Microsoft.UI.Xaml;

namespace IPodConverter;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
        // Падение окна — в журнал рядом с журналом движка (%LOCALAPPDATA%\iPod Converter\Logs).
        UnhandledException += (_, e) =>
        {
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iPod Converter", "Logs");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "window.log"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [ERROR] {e.Message}\n{e.Exception}\n");
            }
            catch { }
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Файлы, переданные при запуске («Открыть с помощью» или перетаскивание на ярлык).
        var files = Environment.GetCommandLineArgs().Skip(1).Where(a => File.Exists(a) || Directory.Exists(a)).ToArray();
        _window = new MainWindow(files);
        _window.Activate();
    }
}
