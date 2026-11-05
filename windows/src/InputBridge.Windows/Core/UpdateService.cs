using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace InputBridge.Windows;

public enum UpdateState { Idle, Checking, UpToDate, Available, Downloading, ReadyToInstall, Installing, Failed }

public sealed record UpdateInfo(SemVer Version, string Tag, string HtmlUrl, string AssetName, Uri DownloadUrl, long Size, string? Sha256);

/// <summary>
/// Polls GitHub Releases for a newer version, downloads the Windows installer, verifies its
/// SHA-256 digest and runs it silently. The stable channel only sees the release GitHub marks
/// as latest; the beta channel also considers pre-releases.
/// </summary>
public sealed class UpdateService : IDisposable
{
    public const string Owner = "ArdanucAKAR";
    public const string Repository = "InputBridge";
    public const string WindowsAssetName = "InputBridge-Windows-Setup.exe";

    private static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(6);

    private readonly AppSettings _settings;
    private readonly HttpClient _http;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly CancellationTokenSource _cts = new();
    private readonly string _downloadDirectory;
    private Task? _loop;

    public static bool IsRunningPrerelease { get; } = ReadCurrentVersion().IsPrerelease;

    public SemVer CurrentVersion { get; }
    public bool IsDevelopmentBuild => CurrentVersion == SemVer.Zero;
    public UpdateState State { get; private set; } = UpdateState.Idle;
    public string StatusText { get; private set; } = "";
    public UpdateInfo? Latest { get; private set; }
    public string? DownloadedInstallerPath { get; private set; }

    public event Action? Changed;
    /// <summary>Raised once per newly found version so the UI can notify the user.</summary>
    public event Action<UpdateInfo>? UpdateReady;
    /// <summary>Raised after the installer has been launched; the app must exit so files can be replaced.</summary>
    public event Action? InstallerLaunched;

    public UpdateService(AppSettings settings)
    {
        _settings = settings;
        CurrentVersion = ReadCurrentVersion();
        _downloadDirectory = Path.Combine(Path.GetTempPath(), "InputBridge", "updates");
        _http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        _http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("InputBridge-Updater", CurrentVersion.ToString()));
        StatusText = IsDevelopmentBuild
            ? "Development build — automatic update checks are off."
            : $"Version {CurrentVersion}.";
    }

    public void Start()
    {
        if (_loop is not null) return;
        CleanupOldDownloads();
        _loop = Task.Run(() => LoopAsync(_cts.Token));
    }

    private async Task LoopAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(StartupDelay, token);
            while (!token.IsCancellationRequested)
            {
                if (_settings.AutoCheckUpdates && !IsDevelopmentBuild)
                {
                    await CheckAsync(userInitiated: false, token);
                }
                await Task.Delay(CheckInterval, token);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Checks GitHub, and downloads the installer when a newer version exists.</summary>
    public async Task CheckAsync(bool userInitiated, CancellationToken token = default)
    {
        if (!await _gate.WaitAsync(0, token)) return;
        try
        {
            if (State is UpdateState.Installing) return;
            if (State is UpdateState.ReadyToInstall && !userInitiated) return;

            SetState(UpdateState.Checking, "Checking GitHub for updates…");
            var latest = await FetchLatestAsync(token);
            if (latest is null)
            {
                SetState(UpdateState.UpToDate, $"No Windows installer found in the latest release. Current version {CurrentVersion}.");
                return;
            }

            Latest = latest;
            if (latest.Version <= CurrentVersion)
            {
                SetState(UpdateState.UpToDate, $"InputBridge {CurrentVersion} is up to date.");
                return;
            }

            var alreadyDownloaded = DownloadedInstallerPath is not null && File.Exists(DownloadedInstallerPath)
                && Path.GetFileName(Path.GetDirectoryName(DownloadedInstallerPath)) == latest.Tag;
            if (!alreadyDownloaded)
            {
                SetState(UpdateState.Downloading, $"Downloading InputBridge {latest.Version}…");
                DownloadedInstallerPath = await DownloadAsync(latest, token);
            }

            SetState(UpdateState.ReadyToInstall, $"InputBridge {latest.Version} is ready to install.");
            if (!alreadyDownloaded) UpdateReady?.Invoke(latest);

            if (_settings.AutoInstallUpdates && !userInitiated)
            {
                TryInstall();
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception ex)
        {
            SetState(UpdateState.Failed, $"Update check failed: {ex.Message}");
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Starts the downloaded installer silently (UAC prompt) and asks the app to exit.</summary>
    public bool TryInstall()
    {
        var path = DownloadedInstallerPath;
        if (State != UpdateState.ReadyToInstall || path is null || !File.Exists(path)) return false;

        try
        {
            var log = Path.Combine(_downloadDirectory, "install.log");
            var info = new ProcessStartInfo(path)
            {
                UseShellExecute = true,
                Verb = "runas",
                Arguments = $"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /LOG=\"{log}\"",
                WorkingDirectory = Path.GetDirectoryName(path)!
            };
            Process.Start(info);
            SetState(UpdateState.Installing, $"Installing InputBridge {Latest?.Version}… The app will restart.");
            InstallerLaunched?.Invoke();
            return true;
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // ERROR_CANCELLED: the user declined the UAC prompt. Keep the download for later.
            SetState(UpdateState.ReadyToInstall, "Update was not installed (administrator approval was declined).");
            return false;
        }
        catch (Exception ex)
        {
            SetState(UpdateState.Failed, $"Could not start the installer: {ex.Message}");
            return false;
        }
    }

    private async Task<UpdateInfo?> FetchLatestAsync(CancellationToken token)
    {
        if (!_settings.ReceiveBetaUpdates)
        {
            var latest = await GetJsonAsync<GitHubRelease>($"https://api.github.com/repos/{Owner}/{Repository}/releases/latest", token);
            return latest is null || latest.Prerelease ? null : ToUpdateInfo(latest);
        }

        // Beta channel: newest version among recent published releases, pre-releases included.
        var releases = await GetJsonAsync<List<GitHubRelease>>($"https://api.github.com/repos/{Owner}/{Repository}/releases?per_page=30", token) ?? [];
        return releases
            .Select(ToUpdateInfo)
            .OfType<UpdateInfo>()
            .OrderByDescending(info => info.Version)
            .FirstOrDefault();
    }

    private async Task<T?> GetJsonAsync<T>(string url, CancellationToken token) where T : class
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        using var response = await _http.SendAsync(request, token);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        if ((int)response.StatusCode == 403 || (int)response.StatusCode == 429)
            throw new InvalidOperationException("GitHub rate limit reached, will retry later.");
        response.EnsureSuccessStatusCode();

        await using var stream = await response.Content.ReadAsStreamAsync(token);
        return await JsonSerializer.DeserializeAsync<T>(stream, cancellationToken: token)
            ?? throw new InvalidOperationException("Empty response from GitHub.");
    }

    private static UpdateInfo? ToUpdateInfo(GitHubRelease release)
    {
        if (release.Draft) return null;
        if (!SemVer.TryParse(release.TagName, out var version)) return null;

        var asset = release.Assets.FirstOrDefault(a => string.Equals(a.Name, WindowsAssetName, StringComparison.OrdinalIgnoreCase));
        if (asset is null) return null;

        var uri = new Uri(asset.BrowserDownloadUrl);
        if (uri.Scheme != Uri.UriSchemeHttps || !uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Unexpected download location for the installer.");

        string? sha256 = null;
        if (asset.Digest is { } digest && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
            sha256 = digest["sha256:".Length..].Trim().ToLowerInvariant();

        return new UpdateInfo(version, release.TagName, release.HtmlUrl, asset.Name, uri, asset.Size, sha256);
    }

    private async Task<string> DownloadAsync(UpdateInfo info, CancellationToken token)
    {
        var directory = Path.Combine(_downloadDirectory, info.Tag);
        Directory.CreateDirectory(directory);
        var target = Path.Combine(directory, info.AssetName);
        var partial = target + ".part";

        using (var request = new HttpRequestMessage(HttpMethod.Get, info.DownloadUrl))
        {
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/octet-stream"));
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            await using var source = await response.Content.ReadAsStreamAsync(token);
            await using var destination = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true);
            await source.CopyToAsync(destination, token);
        }

        var length = new FileInfo(partial).Length;
        if (info.Size > 0 && length != info.Size)
        {
            File.Delete(partial);
            throw new InvalidDataException($"Downloaded installer size mismatch ({length} != {info.Size}).");
        }

        if (info.Sha256 is not null)
        {
            string actual;
            await using (var file = File.OpenRead(partial))
            {
                actual = Convert.ToHexString(await SHA256.HashDataAsync(file, token)).ToLowerInvariant();
            }
            if (actual != info.Sha256)
            {
                File.Delete(partial);
                throw new InvalidDataException("Downloaded installer failed the SHA-256 check.");
            }
        }

        File.Move(partial, target, overwrite: true);
        return target;
    }

    private void CleanupOldDownloads()
    {
        try
        {
            if (!Directory.Exists(_downloadDirectory)) return;
            foreach (var dir in Directory.GetDirectories(_downloadDirectory))
            {
                if (SemVer.TryParse(Path.GetFileName(dir), out var v) && v <= CurrentVersion)
                    Directory.Delete(dir, recursive: true);
            }
        }
        catch
        {
            // Best effort; a locked or missing temp folder must not block startup.
        }
    }

    private void SetState(UpdateState state, string text)
    {
        State = state;
        StatusText = text;
        Changed?.Invoke();
    }

    /// <summary>Reads the full version (including a -beta suffix) stamped by the release build.</summary>
    private static SemVer ReadCurrentVersion()
    {
        var assembly = Assembly.GetEntryAssembly();
        var informational = assembly?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (SemVer.TryParse(informational, out var version)) return version;
        return SemVer.TryParse(assembly?.GetName().Version?.ToString(), out version) ? version : SemVer.Zero;
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
        _http.Dispose();
    }

    private sealed class GitHubRelease
    {
        [JsonPropertyName("tag_name")] public string TagName { get; set; } = "";
        [JsonPropertyName("html_url")] public string HtmlUrl { get; set; } = "";
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<GitHubAsset> Assets { get; set; } = [];
    }

    private sealed class GitHubAsset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("size")] public long Size { get; set; }
        [JsonPropertyName("digest")] public string? Digest { get; set; }
        [JsonPropertyName("browser_download_url")] public string BrowserDownloadUrl { get; set; } = "";
    }
}
