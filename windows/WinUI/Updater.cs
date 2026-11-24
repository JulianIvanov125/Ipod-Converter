using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace IPodConverter;

/// <summary>
/// Обновление из приложения, как на Mac: GitHub releases/latest → Setup.exe своей архитектуры →
/// сверка SHA-256 с полем digest ассета (отдельный .sha256 не скачиваем) → тихая установка и перезапуск.
/// Версия из zip (без установщика) обновляется только по ссылке на страницу релиза.
/// </summary>
public static class Updater
{
    public const string Repo = "JulianIvanov125/Ipod-Converter";
    private static readonly TimeSpan AutoInterval = TimeSpan.FromHours(20);

    public sealed record Release(Version Version, string Tag, string Page, string Notes, string? SetupName, string? SetupUrl, string? Sha256, long Size);

    public static Version Current
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0";
            return Parse(v.Split('+')[0]) ?? new Version(0, 0);
        }
    }

    public static string CurrentText => Format(Current);

    /// <summary>Поставлено установщиком (рядом лежит деинсталлятор Inno) — можно обновлять само.</summary>
    public static bool IsInstalled => File.Exists(Path.Combine(AppContext.BaseDirectory, "unins000.exe"));

    private static string Arch => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";

    public static Version? Parse(string s)
    {
        s = s.Trim().TrimStart('v', 'V');
        if (!s.Contains('.')) s += ".0";
        return Version.TryParse(s, out var v) ? v : null;
    }

    public static string Format(Version v) => v.Build > 0 ? $"{v.Major}.{v.Minor}.{v.Build}" : $"{v.Major}.{v.Minor}";

    // MARK: когда проверять

    private static string StateFile => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iPod Converter", "update.json");

    public static bool AutoCheckDue
    {
        get
        {
            try
            {
                var o = JsonNode.Parse(File.ReadAllText(StateFile));
                var last = DateTime.Parse(o?["lastCheck"]?.GetValue<string>() ?? "");
                return DateTime.UtcNow - last.ToUniversalTime() > AutoInterval;
            }
            catch { return true; }
        }
    }

    public static string? SkippedVersion
    {
        get { try { return JsonNode.Parse(File.ReadAllText(StateFile))?["skip"]?.GetValue<string>(); } catch { return null; } }
    }

    public static void SaveState(string? skip = null)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StateFile)!);
            var o = new JsonObject { ["lastCheck"] = DateTime.UtcNow.ToString("o") };
            var keep = skip ?? SkippedVersion;
            if (keep != null) o["skip"] = keep;
            File.WriteAllText(StateFile, o.ToJsonString());
        }
        catch { }
    }

    // MARK: проверка

    private static HttpClient NewClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("iPodConverter");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return http;
    }

    /// <summary>Последний релиз. Адрес API можно подменить переменной IPODCONVERTER_RELEASE_URL (для проверки на поддельном релизе).</summary>
    public static async Task<Release> FetchLatestAsync()
    {
        var url = Environment.GetEnvironmentVariable("IPODCONVERTER_RELEASE_URL");
        if (string.IsNullOrEmpty(url)) url = $"https://api.github.com/repos/{Repo}/releases/latest";
        string json;
        if (url.StartsWith("file:", StringComparison.OrdinalIgnoreCase)) json = await File.ReadAllTextAsync(new Uri(url).LocalPath);
        else { using var http = NewClient(); json = await http.GetStringAsync(url); }
        var o = JsonNode.Parse(json) as JsonObject ?? throw new InvalidDataException("bad response");
        var tag = o["tag_name"]?.GetValue<string>() ?? "";
        var version = Parse(tag) ?? throw new InvalidDataException($"bad tag {tag}");
        var setupName = $"iPod-Converter-{Format(version)}-Windows-{Arch}-Setup.exe";
        JsonObject? asset = (o["assets"] as JsonArray)?.OfType<JsonObject>()
            .FirstOrDefault(a => string.Equals(a["name"]?.GetValue<string>(), setupName, StringComparison.OrdinalIgnoreCase));
        string? sha = asset?["digest"]?.GetValue<string>();
        if (sha != null && sha.StartsWith("sha256:")) sha = sha["sha256:".Length..].ToLowerInvariant(); else sha = null;
        return new Release(version, tag, o["html_url"]?.GetValue<string>() ?? $"https://github.com/{Repo}/releases/latest",
            o["body"]?.GetValue<string>() ?? "", asset != null ? setupName : null,
            asset?["browser_download_url"]?.GetValue<string>(), sha, asset?["size"]?.GetValue<long>() ?? 0);
    }

    public static bool CanInstall(Release r) => IsInstalled && r.SetupUrl != null && r.Sha256 != null;

    // MARK: установка

    /// <summary>Скачать Setup.exe и сверить SHA-256 с digest; несовпадение — файл удаляется, ошибка.</summary>
    public static async Task<string> DownloadAsync(Release r, IProgress<double> progress, CancellationToken ct)
    {
        if (r.SetupUrl == null || r.Sha256 == null || r.SetupName == null) throw new InvalidOperationException("no installer in this release");
        var dir = Path.Combine(Path.GetTempPath(), "iPodConverter-update");
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, r.SetupName);
        if (File.Exists(file)) File.Delete(file);

        if (r.SetupUrl.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
        {
            File.Copy(new Uri(r.SetupUrl).LocalPath, file);   // для проверки на поддельном релизе
            progress.Report(1);
        }
        else
        {
            using var http = NewClient();
            using var resp = await http.GetAsync(r.SetupUrl, HttpCompletionOption.ResponseHeadersRead, ct);
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? r.Size;
            await using var src = await resp.Content.ReadAsStreamAsync(ct);
            await using var dst = File.Create(file);
            var buf = new byte[1 << 16];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
                done += n;
                if (total > 0) progress.Report((double)done / total);
            }
        }

        string actual;
        await using (var fs = File.OpenRead(file))
            actual = Convert.ToHexString(await SHA256.HashDataAsync(fs, ct)).ToLowerInvariant();
        if (actual != r.Sha256)
        {
            File.Delete(file);
            throw new InvalidDataException($"SHA-256 mismatch: expected {r.Sha256}, got {actual}");
        }
        return file;
    }

    /// <summary>
    /// Запустить установщик тихо: он ждёт, пока это окно закроется, ставит поверх и открывает новую версию (/RELAUNCH=1).
    /// Установка «для всех» спросит разрешение Windows (UAC). Возвращает false, если пользователь отказал.
    /// </summary>
    public static bool StartInstaller(string setup)
    {
        try
        {
            Process.Start(new ProcessStartInfo(setup, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1")
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(setup)!,
            });
            return true;
        }
        catch (System.ComponentModel.Win32Exception) { return false; }   // отказ в UAC
    }

    public static void OpenPage(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}
