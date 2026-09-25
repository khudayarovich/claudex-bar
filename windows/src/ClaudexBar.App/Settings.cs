using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace ClaudexBar.App;

internal enum IslandPosition { Center, Left, Right }

internal sealed class AppSettings
{
    public IslandPosition Position { get; set; } = IslandPosition.Center;
    public bool HideInFullScreen { get; set; } = true;
    public bool ShowUsageRing { get; set; } = true;
    public bool PeekAttention { get; set; } = true;
    public bool PeekFinished { get; set; } = true;
    public bool PeekUsage { get; set; } = true;
    public bool Sound { get; set; }
    public bool ClaudeUsageApi { get; set; } = true;
    public bool CodexUsageApi { get; set; } = true;
    public int FreshMinutes { get; set; } = 30;

    private static string FilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClaudexBar", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

internal sealed class SettingsWindow : Window
{
    public SettingsWindow(AppSettings settings, Action changed)
    {
        Title = "ClaudexBar Settings";
        Width = 440;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        CheckBox Toggle(string text, bool value, Action<bool> set)
        {
            var cb = new CheckBox { Content = text, IsChecked = value, Margin = new Thickness(0, 2) };
            cb.IsCheckedChanged += (_, _) => { set(cb.IsChecked == true); settings.Save(); changed(); };
            return cb;
        }

        TextBlock Header(string text) => new() { Text = text, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 12, 0, 4) };

        var position = new ComboBox { ItemsSource = new[] { "Top center", "Top left", "Top right" }, SelectedIndex = (int)settings.Position, Width = 160 };
        position.SelectionChanged += (_, _) => { settings.Position = (IslandPosition)Math.Max(0, position.SelectedIndex); settings.Save(); changed(); };

        var fresh = new NumericUpDown { Minimum = 5, Maximum = 240, Increment = 5, Value = settings.FreshMinutes, Width = 130, FormatString = "0" };
        fresh.ValueChanged += (_, _) => { settings.FreshMinutes = (int)(fresh.Value ?? 30); settings.Save(); changed(); };

        var panel = new StackPanel { Margin = new Thickness(20, 8, 20, 20), Spacing = 2 };
        panel.Children.Add(Header("Startup"));
        var login = Toggle("Launch ClaudexBar when I sign in", Win32.GetLaunchAtLogin(), Win32.SetLaunchAtLogin);
        login.IsEnabled = Win32.LaunchAtLoginSupported;
        panel.Children.Add(login);

        panel.Children.Add(Header("Island"));
        panel.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { new TextBlock { Text = "Position", VerticalAlignment = VerticalAlignment.Center, Width = 110 }, position },
        });
        panel.Children.Add(Toggle("Hide while a full-screen app or game is in front", settings.HideInFullScreen, v => settings.HideInFullScreen = v));
        panel.Children.Add(Toggle("Show usage ring around each logo", settings.ShowUsageRing, v => settings.ShowUsageRing = v));
        panel.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 4, 0, 0),
            Children = { new TextBlock { Text = "Yellow stays bright for (min)", VerticalAlignment = VerticalAlignment.Center, Width = 190 }, fresh },
        });

        panel.Children.Add(Header("Pop out the island when"));
        panel.Children.Add(Toggle("A session needs approval or an answer", settings.PeekAttention, v => settings.PeekAttention = v));
        panel.Children.Add(Toggle("A turn longer than 20 s finishes", settings.PeekFinished, v => settings.PeekFinished = v));
        panel.Children.Add(Toggle("Usage crosses 80 % or 100 %", settings.PeekUsage, v => settings.PeekUsage = v));
        panel.Children.Add(Toggle("Play a sound when a session needs you", settings.Sound, v => settings.Sound = v));

        panel.Children.Add(Header("Usage limits"));
        panel.Children.Add(Toggle("Claude: ask Anthropic's usage API with Claude Code's login", settings.ClaudeUsageApi, v => settings.ClaudeUsageApi = v));
        panel.Children.Add(Toggle("Codex: ask ChatGPT's usage API with Codex's login", settings.CodexUsageApi, v => settings.CodexUsageApi = v));
        panel.Children.Add(new TextBlock
        {
            Text = "Logins are only read, never refreshed or stored. Otherwise the numbers the Claude app and Codex already saved are used.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.6, FontSize = 11, Margin = new Thickness(0, 4, 0, 0),
        });
        panel.Children.Add(Header("About"));
        panel.Children.Add(new TextBlock
        {
            Text = $"ClaudexBar {typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3)}", FontSize = 13, FontWeight = FontWeight.SemiBold,
        });
        panel.Children.Add(new TextBlock { Text = "by Farrukh Yuldashev", FontSize = 12, Opacity = 0.8 });
        panel.Children.Add(new TextBlock
        {
            Text = "Live status and usage limits for Claude Code and Codex. Not affiliated with Anthropic or OpenAI.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.55, FontSize = 11, Margin = new Thickness(0, 2, 0, 0),
        });
        Content = new ScrollViewer { Content = panel };
    }
}
