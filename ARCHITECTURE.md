# Cortexa — Architecture

A bird's-eye view of how the pieces fit together. For *how to extend* a piece (gotchas, the step-by-step pattern for adding a feature), see `DEVELOPMENT.md`. For the AI agents specifically, see `AGENTS.md`. For the catalog of actions the app (and its AI) can take, see `SKILLS.md`.

## Components

```
┌─────────────────────┐     imports      ┌──────────────────────┐
│  PCGuard-GUI.ps1     │ ───────────────▶ │  PCGuardCore.psm1     │
│  (foreground app)    │                  │  (shared logic -      │
│  - XAML UI           │                  │   the only place      │
│  - code-behind       │                  │   that touches the    │
│  - background jobs    │                 │   OS / network / AI   │
└─────────┬────────────┘                  │   providers)          │
          │                               └───────────▲───────────┘
          │ reads/writes                              │ imports
          ▼                                            │
┌─────────────────────┐                     ┌──────────┴───────────┐
│  config.json          │ ◀── read by ────  │  PCGuard.ps1          │
│  logs/*.log, *.json   │                   │  (background          │
│  logs/backups/*.zip   │ ──── written by ─▶│   watchdog, runs       │
│  Reports/*.html        │                  │   every 15 min via a   │
│  DisabledStartupItems/ │                  │   Scheduled Task)      │
└─────────────────────┘                     └───────────────────────┘
```

Three PowerShell processes can be running at once, none of which duplicate logic — they all import the same module:

- **`PCGuard-GUI.ps1`** — the app you interact with. A single script: one big `[xml]$xaml` here-string (loose XAML, no compile step) loaded via `[Windows.Markup.XamlReader]::Load`, followed by code-behind that wires named controls to handlers.
- **`PCGuard.ps1`** (the watchdog) — a standalone script invoked every 15 minutes by the `PCGuard-Watchdog` Scheduled Task, independent of whether the GUI is open. It samples health/network/app-usage/security state, writes alerts, and is the only writer of the monthly `logs/pcguard_YYYY-MM.log` file.
- **`PCGuardCore.psm1`** — ~90 exported functions, grouped by domain (system health, process/task/startup management, network, security, app usage, AI/Ollama, AI/Claude, config, history/backup). Every function that touches the OS, registry, network, or an AI provider lives here. Neither the GUI nor the watchdog duplicates this logic; they call it.

External, optional dependencies the module talks to: **Ollama** (`http://localhost:11434`, local, no network egress) and **Anthropic's Claude API** (`https://api.anthropic.com`, cloud, opt-in per click).

## Data flow for a typical feature

Take the Security tab's realtime monitoring as a concrete example — the same shape repeats for Network and App Usage:

1. **GUI refresh** (`Refresh-SecurityTab`, on a button click, a `DispatcherTimer` tick, or app startup) calls core functions (`Get-SecurityStatsSnapshot`, `Get-SecurityEventLog`) to get live data.
2. The snapshot is **persisted** via `Add-JsonHistorySample` (or the security-specific `Add-SecurityHistorySample`) — one JSON object appended as a line to a file under `logs/`. This is a deliberately simple, dependency-free persistence format: no database, just append-only JSON Lines, read back with `Get-JsonHistory`/`Get-SecurityHistory`.
3. The GUI redraws a chart (`Draw-Sparkline`, a generic WPF `Polyline`-based helper) from the last N persisted points, so the trend survives app restarts instead of living only in memory.
4. The **watchdog** calls the same snapshot + persist functions on its own 15-minute cycle, so history keeps accumulating even when the GUI is closed.
5. If you click "Analyze (Claude)", the GUI runs the Claude agent function (`Invoke-ClaudeSecurityAnalysis`) in a **background job** (never on the UI thread), which gathers the same live data *plus* the persisted trend and recent events, builds a prompt, and calls `Invoke-ClaudeGenerate`.

This pattern — live snapshot → persist as JSON Lines → render from persisted history → feed richer context to the matching AI agent → watchdog keeps it going when the GUI is closed — is shared by Security, Network, and App Usage. Prefer it over inventing a new storage format if you add a fourth.

## Persistence layer

All of it lives under the app folder, all of it gitignored (`logs/`, `Reports/`, `config.json`):

| Path | Written by | Format | Purpose |
|---|---|---|---|
| `config.json` | GUI (Settings tab) | single JSON object | all user settings — the one config store, read by both GUI and watchdog via `Get-PCGuardConfig` |
| `logs/pcguard_YYYY-MM.log` | watchdog only | plain text, timestamped lines | RAM/CPU/disk/network samples and alerts; parsed back by regex for the History tab's chart (`Get-HealthHistory`) |
| `logs/security_history.log` | GUI + watchdog | JSON Lines | Security tab's persisted stats trend |
| `logs/network_monitor_history.log` | GUI + watchdog | JSON Lines | Network tab's persisted stats trend |
| `logs/app_usage_history.log` | GUI + watchdog | JSON Lines | App Usage tab's persisted stats trend |
| `logs/app_usage_events.log` | GUI + watchdog | JSON Lines | install/uninstall activity, diffed against `logs/.installed_apps_baseline.json` |
| `logs/claude_token_usage.log` | any Claude call that supplies `-RootDir` | JSON Lines | per-call token cost, rolled up for the Settings tab and the monthly limit check |
| `logs/ai_actions.log` | GUI (any AI-suggested action) | JSON Lines | audit trail: what the AI suggested, what the user decided |
| `logs/app_usage.json` | GUI (15s sampler) + watchdog (15-min sampler) | single JSON object (dictionary) | per-app tracked running time |
| `logs/backups/logs_backup_*.zip` | `Invoke-LogBackup` (GUI launch + watchdog, gated to once per 2 days) | zip | whole `logs/` folder, retained 20 most recent |
| `Reports/*.html` | watchdog (once per day) | HTML | human-readable daily health report, 30-day retention |
| `DisabledStartupItems/` | GUI (Startup tab) | backup files | disabled startup items, so they can be re-enabled |

Why JSON Lines (one JSON object per line, appended) rather than a single JSON array or a real database: appending is O(1) (`Add-Content`, no read-modify-write of the whole file), a half-written line from a crash only breaks that one line (tolerated — `Get-JsonHistory`/`Get-SecurityHistory` skip lines that fail to parse), and no extra dependency is needed beyond what PowerShell already ships with.

## The two AI backends

Covered in full in `AGENTS.md`; architecturally, the distinction that matters:

- **Ollama** (local): the only backend for the main AI Agent tab (chat, system analysis, action chips, command bar, startup review, app decisions, monitoring rules). Zero network egress. No usage limit, because there's no usage cost.
- **Claude** (cloud, opt-in): powers three specialized agents (Network Monitor, Storage Manager, Security Monitor). Each has an `-Provider` parameter (`'Claude'` or `'Ollama'`) so the *same* prompt-building logic can target either backend — switching the Settings-tab "AI Provider" dropdown changes which one the one-shot "Analyze" button uses. Multi-turn "Continue Conversation" is Claude-only (it uses the Anthropic Messages API's `messages` array for real conversational memory; there's no equivalent wired up for Ollama).

## Background jobs (keeping the UI responsive)

Anything that might take more than ~100ms (an AI call, a recursive folder scan, model pull/delete) runs via `Start-Job`, polled by a `DispatcherTimer`, through the reusable `Start-AiJob` helper — never synchronously on the UI thread. Jobs run in a separate process and don't inherit the already-imported module or any GUI-script closures, so every job scriptblock re-imports the module explicitly and receives everything it needs via `-ArgumentList` rather than capturing `$RootDir` etc. from the enclosing scope. See `DEVELOPMENT.md` for the exact pattern and the closure gotcha that motivated it.

## Elevation model

The GUI requests UAC elevation on launch (needed for ending protected processes, scheduled tasks, startup items, Docker/WSL cleanup, System Restore points) and shows which mode it's running in via a title-bar badge. Declining the prompt keeps the app running at standard privileges with reduced functionality rather than failing outright. Path resolution and the elevation relaunch itself both have separate code paths for running as a `.ps1` versus a `ps2exe`-compiled `.exe`, since `$MyInvocation`/`$PSCommandPath` break under compilation.

## Safety boundary: AI suggests, buttons execute

The one architectural invariant that should never be relaxed without deliberate thought: **no AI output is ever executed directly.** Every path from "the AI said X" to "X happened" is re-validated against a hard-coded whitelist in the module and then routed through the *same* button and confirmation dialog a manual click would use. Full detail (and the exact whitelist) is in `AGENTS.md` and `SKILLS.md`; the enforcement pattern itself is in `DEVELOPMENT.md`.
