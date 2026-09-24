# ClaudexBar

A Dynamic-Island-style widget that hugs the MacBook notch and shows, at a glance, what your
**Claude Code** and **OpenAI Codex** sessions are doing and how much of each plan's usage limit is left.

```
 ╭──────────╮▁▁▁▁ notch ▁▁▁▁╭──────────╮
 │ ✳ ●●●    │               │    ●●● ⌬ │      ← Claude left, Codex right
 ╰──────────╯               ╰──────────╯
```

## Traffic lights

| Lamp | Meaning |
|---|---|
| 🟢 green (breathing) | the agent is working |
| 🟡 yellow (steady) | a turn finished and is waiting for your next prompt; dims after 30 min ("parked") |
| 🔴 red (blinking) | needs approval or an answer, or is blocked (error, usage limit reached) |
| all dim | no session |

With several sessions, every lamp whose state is present lights up. For example, red and green together mean one session needs you while another keeps working.

The thin ring around each logo shows the most constrained usage window (green < 50 % < yellow < 80 % < orange < 100 % = red).

**Interacting:**
- **Hover** the island to expand it. You get usage bars with reset countdowns, and every session with its activity (e.g. `Needs approval · Bash: rm -rf build`, `Running: npm test`).
- **Click** to pin it open. **Click a session** to bring its app or terminal to the front.
- **Right-click** for Settings / Refresh / Quit.
- The island pops out briefly on its own when a session needs you, a long turn finishes, or usage crosses 80 % / 100 %.

## Build, run, install

Requires macOS 14+ and Xcode 26 / Swift 6.2.

```bash
make build        # swift build + ad-hoc signed build/ClaudexBar.app
make run          # launch it
make demo         # scripted demo cycling through every state
make test         # unit + integration tests
make install      # copy to ~/Applications and launch
```

Launch at login is in **Settings → General**. It is available once the app is installed under Applications.

## Where the data comes from (read-only)

ClaudexBar never edits Claude/Codex configuration, installs no hooks, and never writes their
files, databases or Keychain items. It never refreshes OAuth tokens (refresh tokens rotate, so that would sign the CLIs out).

| What | Source |
|---|---|
| Claude session state | `~/.claude/sessions/<pid>.json`: Claude Code's live registry (`busy` / `idle` / `waiting` + `waitingFor`), the backing store of `claude agents --json` |
| Claude activity detail | tail of `~/.claude/projects/*/<session>.jsonl` (current tool, errors) |
| Claude usage | the Claude app's own cache `~/Library/Application Support/Claude/plan-usage-history.json`; plus `api.anthropic.com/api/oauth/usage` when Claude Code's Keychain login holds a valid token |
| Codex session state | rollouts `~/.codex/sessions/**/rollout-*.jsonl` (turn start/end, pending questions), and which threads a running `codex` process has open (libproc) |
| Codex thread names | `~/.codex/state_*.sqlite` (opened `immutable`/read-only) and `session_index.jsonl` |
| Codex usage | `chatgpt.com/backend-api/wham/usage` with `~/.codex/auth.json`, falling back to the rate limits Codex writes to its rollouts; last resort (only when no Codex process runs): `codex app-server` → `account/rateLimits/read` |

Everything above is undocumented and can change between versions. Parsers are lenient, and unknown values degrade to "unknown" rather than breaking.

**Known limits:**
- Codex does not persist approval prompts, so Codex approvals aren't detected. Questions (`request_user_input`) are.
- Claude reset times are only shown when an API reading exists or the Claude app's sampled history pins the window start to within 30 min (marked `≈`).

## Debugging

```bash
build/ClaudexBar.app/Contents/MacOS/ClaudexBar --snapshot /tmp/shots   # render every state to PNG
open -n build/ClaudexBar.app --args --demo --demo-freeze all-lit         # freeze a demo scenario
open -n build/ClaudexBar.app --args --debug-commands                     # accept debug commands:
osascript -l JavaScript -e 'ObjC.import("Foundation");$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("dev.claudexbar.debug","present expanded",$(),true)'
swift run claudex-probe claude-sessions | codex-sessions --all | codex-loaded | usage | engine | windows
```

Other flags: `--simulate-no-notch`, `--force-reduce-motion`, `--present <collapsed|expanded|peek>`, `--replace`.
