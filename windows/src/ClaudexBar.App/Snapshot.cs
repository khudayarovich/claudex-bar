using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using ClaudexBar.Core;

namespace ClaudexBar.App;

/// <summary>Renders island states to PNG offscreen for visual verification (`--snapshot dir`).</summary>
internal static class SnapshotRenderer
{
    public static void Run(string dir)
    {
        Directory.CreateDirectory(dir);
        var now = DateTimeOffset.UtcNow;
        (string Name, string Scenario, IslandMode Mode, PeekEvent? Peek)[] cases =
        [
            ("collapsed-idle", "idle", IslandMode.Collapsed, null),
            ("collapsed-mixed", "mixed", IslandMode.Collapsed, null),
            ("collapsed-all-lit", "all-lit", IslandMode.Collapsed, null),
            ("peek-approval", "attention", IslandMode.Peek,
                new PeekEvent("a", PeekKind.Attention, Provider.Claude, LampColor.Red, "Claude · api-server", "needs approval — Bash", null, now)),
            ("expanded-mixed", "mixed", IslandMode.Expanded, null),
            ("expanded-all-lit", "all-lit", IslandMode.Expanded, null),
            ("expanded-idle", "idle", IslandMode.Expanded, null),
        ];
        foreach (var c in cases)
        {
            var vm = new IslandViewModel();
            vm.Apply(new SessionSnapshot(now, DemoScenarios.Sessions(c.Scenario, now)));
            vm.Apply(DemoScenarios.Usage(now, codexWeek: c.Scenario == "all-lit" ? 44 : 63));
            var window = new IslandWindow(vm, new AppSettings(), new IslandActions(_ => { }, () => { }, () => { }, () => { }),
                reduceMotion: true, snapshot: true);
            if (c.Peek is { } p) window.Enqueue([p]);
            else if (c.Mode == IslandMode.Expanded) window.Present(IslandMode.Expanded, pinned: true);
            var root = (Control)window.Content!;
            window.Content = null;
            var size = new Size(double.IsNaN(window.Width) ? Metrics.CollapsedWidth : window.Width, double.IsNaN(window.Height) ? Metrics.Band : window.Height);
            var frame = new Border
            {
                Width = size.Width + 80, Height = size.Height + 24,
                Background = new LinearGradientBrush
                {
                    StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                    GradientStops = { new GradientStop(Color.FromRgb(0x5C, 0x6B, 0x8F), 0), new GradientStop(Color.FromRgb(0x9E, 0x85, 0x9E), 1) },
                },
                Child = new Panel
                {
                    Children =
                    {
                        new Border { Height = Metrics.Band + 1, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top, Background = new SolidColorBrush(Color.FromArgb(70, 255, 255, 255)) },
                        new Border { Width = size.Width, Height = size.Height, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top, Child = root },
                    },
                },
            };
            // Host offscreen in a real window so control templates (buttons) are applied.
            var host = new Window
            {
                SystemDecorations = SystemDecorations.None, ShowInTaskbar = false, ShowActivated = false,
                Width = frame.Width, Height = frame.Height, Position = new PixelPoint(-30000, -30000), Content = frame,
            };
            host.Show();
            host.UpdateLayout();
            var px = new PixelSize((int)(frame.Width * 2), (int)(frame.Height * 2));
            using var bitmap = new RenderTargetBitmap(px, new Vector(192, 192));
            bitmap.Render(frame);
            bitmap.Save(Path.Combine(dir, c.Name + ".png"));
            host.Close();
            window.Close();
        }
        Console.WriteLine($"SNAPSHOTS {cases.Length} written to {dir}");
    }
}
