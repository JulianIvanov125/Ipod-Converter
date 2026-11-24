using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace IPodConverter;

/// <summary>
/// Связь с движком iPodConverter.exe (Swift): запускает его с командой serve, пишет команды в stdin
/// и получает снимки состояния из stdout — по одной JSON-строке.
/// </summary>
public sealed class EngineClient : IDisposable
{
    private Process? _proc;
    private StreamWriter? _stdin;

    /// <summary>Снимок состояния или сообщение; вызывается не на UI-потоке.</summary>
    public event Action<JsonObject>? Received;
    /// <summary>Движок завершился сам (упал или не нашёлся).</summary>
    public event Action<string>? Exited;

    public static string? FindEngine()
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new List<string>
        {
            Path.Combine(baseDir, "engine", "iPodConverter.exe"),
            Path.Combine(baseDir, "iPodConverter.exe"),
        };
        var env = Environment.GetEnvironmentVariable("IPODCONVERTER_ENGINE");
        if (!string.IsNullOrEmpty(env)) candidates.Insert(0, env);
        return candidates.FirstOrDefault(File.Exists);
    }

    public bool Start()
    {
        var exe = FindEngine();
        if (exe == null) return false;
        var psi = new ProcessStartInfo(exe, "serve")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardInputEncoding = new UTF8Encoding(false),
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        };
        // ffmpeg ищется рядом с движком и в PATH; папка ffmpeg рядом с окном — тоже подходит.
        var extra = new[] { Path.GetDirectoryName(exe)!, Path.Combine(AppContext.BaseDirectory, "ffmpeg") }
            .Where(Directory.Exists);
        psi.Environment["PATH"] = string.Join(";", extra) + ";" + Environment.GetEnvironmentVariable("PATH");

        _proc = Process.Start(psi);
        if (_proc == null) return false;
        _stdin = _proc.StandardInput;
        _stdin.AutoFlush = true;
        _proc.EnableRaisingEvents = true;
        var stderr = new StringBuilder();
        _proc.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (stderr) stderr.AppendLine(e.Data); };
        _proc.BeginErrorReadLine();
        var proc = _proc;
        Task.Run(async () =>
        {
            string? line;
            while ((line = await proc.StandardOutput.ReadLineAsync()) != null)
            {
                if (line.Length == 0 || line[0] != '{') continue;
                try
                {
                    if (JsonNode.Parse(line) is JsonObject o) Received?.Invoke(o);
                }
                catch (JsonException) { /* не JSON — служебный вывод */ }
            }
            await proc.WaitForExitAsync();
            string err; lock (stderr) err = stderr.ToString().Trim();
            Exited?.Invoke(err.Length > 0 ? err : $"exit code {proc.ExitCode}");
        });
        return true;
    }

    public void Send(object command)
    {
        try { _stdin?.WriteLine(JsonSerializer.Serialize(command)); }
        catch (IOException) { /* движок уже закрылся — Exited скажет почему */ }
    }

    public void Add(IEnumerable<string> paths) => Send(new { cmd = "add", paths = paths.ToArray() });
    public void Set(string? ipod = null, bool? max = null, string? output = null)
    {
        var o = new JsonObject { ["cmd"] = "set" };
        if (ipod != null) o["ipod"] = ipod;
        if (max != null) o["max"] = max;
        if (output != null) o["out"] = output;
        try { _stdin?.WriteLine(o.ToJsonString()); } catch (IOException) { }
    }
    public void Convert() => Send(new { cmd = "convert" });
    public void Cancel() => Send(new { cmd = "cancel" });
    public void Clear() => Send(new { cmd = "clear" });
    public void Remove(string id) => Send(new { cmd = "remove", id });
    public void Check(string id, bool on) => Send(new { cmd = "check", id, on });
    public void Keep(string id) => Send(new { cmd = "keep", id });
    public void TrashDuplicates() => Send(new { cmd = "trashDups" });

    public void Dispose()
    {
        // Закрытый stdin — сигнал движку остановить конвертацию и выйти.
        try { _stdin?.Close(); } catch { }
        try { if (_proc is { HasExited: false } p && !p.WaitForExit(3000)) p.Kill(true); } catch { }
        _proc?.Dispose();
    }
}
