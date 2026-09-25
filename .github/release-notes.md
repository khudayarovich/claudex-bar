Live status and usage limits for **Claude Code** and **OpenAI Codex**: a traffic light for each agent, right at the top of your screen.

- 🟢 working · 🟡 finished, waiting for your next prompt · 🔴 needs approval or an answer, or blocked
- Hover to expand: usage bars (5-hour and weekly windows with reset countdowns) and every session with what it's doing
- Pops out briefly when a session needs you, a long turn finishes, or usage crosses 80 % / 100 %
- Read-only: installs no hooks, changes no Claude/Codex settings, never refreshes your logins

### Download

| System | File |
|---|---|
| macOS 14+ (Apple Silicon and Intel) | `ClaudexBar-<version>-macOS-universal.zip` |
| Windows 10/11, x64 | `ClaudexBar-<version>-windows-x64.zip` |
| Windows 11 on ARM | `ClaudexBar-<version>-windows-arm64.zip` |

**macOS:**
1. Unzip and move **ClaudexBar.app** to Applications.
2. The app is not notarized, so on first launch right-click it → **Open** → **Open**. Alternatively, run `xattr -dr com.apple.quarantine /Applications/ClaudexBar.app`.
3. The island appears around the notch (on Macs without one, at the top center).

**Windows:**
1. Unzip and run **ClaudexBar.exe**. It is self-contained, so no .NET install is needed.
2. The exe is not code-signed, so SmartScreen may warn: click **More info** → **Run anyway**.
3. The island appears at the top center of your main screen, and there's a tray icon near the clock.

Made by **Farrukh Yuldashev** · MIT license · Not affiliated with Anthropic or OpenAI.
