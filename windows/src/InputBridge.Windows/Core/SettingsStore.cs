using System.Text.Json;

namespace InputBridge.Windows;

public sealed class SettingsStore
{
    private readonly string _path;
    private readonly JsonSerializerOptions _json = new() { WriteIndented = true };

    public SettingsStore()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "InputBridge");
        Directory.CreateDirectory(root);
        _path = Path.Combine(root, "settings.json");
    }

    public AppSettings Load()
    {
        if (!File.Exists(_path)) return new AppSettings();
        var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), _json) ?? new AppSettings();
        if (settings.ControllerId == Guid.Empty) settings.ControllerId = Guid.NewGuid();
        return settings;
    }

    public void Save(AppSettings settings)
    {
        var temp = _path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(settings, _json));
        File.Move(temp, _path, true);
    }
}
