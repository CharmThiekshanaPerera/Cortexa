# Changelog

All notable changes to Cortexa, in the order they were built.

## v1.5.2 — 2026-11-14

### Added
- Real multi-turn chat under both Claude agents (Network Monitor, Storage Manager) - "Continue Conversation" lets you keep asking follow-ups until you reach a decision, with Claude actually remembering the whole conversation (full message history sent each turn via the Anthropic Messages API), not just independent one-shot calls like before. Verified with a real 2-turn test that Claude correctly recalled information from turn 1 in turn 2.

### Fixed
- Caught and fixed a real PowerShell closure bug while building this: a background-job completion callback referencing a local variable from its defining scope would have silently seen it as empty once that scope returned (confirmed via an isolated test before and after the fix). Resolved with `.GetNewClosure()`.
- Replaced an unsafe `-replace` call that would have corrupted the display if Claude's response ever contained a literal `$` followed by digits (PowerShell would interpret it as a regex backreference) with plain string concatenation.

## v1.5.1 — 2026-11-14

### Fixed
- Moved the Claude Storage Manager Agent card from Disk Analysis to the **App Usage** tab, per feedback — its actual data (biggest installed apps + disk space) is the App Usage tab's content, not Disk Analysis's (folders/files/WSL/Docker). No backend change, just corrected placement.

## v1.5 — 2026-11-14

### Added — Claude (Anthropic API), optional
- Two specialized agents now run on Claude instead of the local Ollama model, when an API key is configured in Settings: a **Network Monitor Agent** (Network tab) and a **Storage Manager Agent** (Disk Analysis tab). Everything else in Cortexa, including the main AI Agent tab, is unaffected and stays on Ollama.
- This is the one place in Cortexa where data leaves the machine for AI purposes - both agents' UI text says so explicitly, and nothing is sent unless the corresponding button is clicked.
- API key is entered via a masked PasswordBox and stored only in the local `config.json` (already gitignored; `config.example.json` has empty placeholders for the new fields).
- Verified against real data before shipping: the Network Monitor correctly flagged a database service listening on all interfaces and a background service with known security issues; the Storage Manager produced a prioritized ~19GB cleanup plan and correctly noted that one app's actual data (model files) lives outside its install folder.

## v1.4.3 — 2026-11-14

### Added
- AI decision help on the App Usage tab: select any app, click "Ask AI: Keep or Delete?" for a short Keep / Consider Uninstalling recommendation based on size, publisher, and last-used date (advisory only - still never uninstalls anything itself, "Open Apps & Features" remains the only action path).
- "Ask a Follow-up Question" button pre-fills the AI Agent tab's chat with the selected app's context and switches you there, so you can keep asking anything about it using the existing chat rather than a separate new input.

## v1.4.2 — 2026-11-14

### Added
- **Last Seen for every app, including ones Cortexa never tracked running.** Falls back to Windows' own UserAssist registry record (a real last-run timestamp Windows keeps for GUI-launched apps, independent of Cortexa) when Cortexa has no tracking data of its own. Verified against real data: went from 1/51 apps having a known last-used date to 31/51. The remaining ones are apps with no GUI-launch record at all (e.g. background services like a MySQL server, which are never launched via Explorer/shortcut, so Windows genuinely has nothing to show for them).
- Fixed a `Get-ChildItem -File` parameter-binding error that occurred for a few installed programs with malformed `InstallLocation` registry values - now checks the path exists and is a real folder first.

## v1.4.1 — 2026-11-14

### Changed
- App Usage tab merged into a single unified list, per feedback — one table showing every app (installed + tracked-running) together, each with a Status column ("Used - Xm total" or "Not used (installed)") and a Size column, sortable by Size / Today / Total. Previously this was two separate scrollable cards.

## v1.4 — 2026-11-14

### App Usage tab — Unused Apps section
- Complements the existing "most used" view: every installed program (read from Windows' own Add/Remove Programs registry entries), cross-referenced against what Cortexa has actually tracked running — matched by **install folder path**, not fuzzy name matching (process name "chrome" vs. display name "Google Chrome" can't be reliably string-matched; comparing folders is).
- Sorted with the biggest, never-seen-running apps first — good uninstall candidates.
- Registry's own size estimate shown by default; "Calculate Real Sizes" recomputes the true folder size on demand (verified against real data: registry estimates are often noticeably stale — Microsoft Edge showed 2846 MB estimated vs. 1792 MB real, PowerToys 1725 MB vs. 973 MB real).
- "Open Apps & Features" button for one-click access to Windows' own uninstaller — Cortexa doesn't attempt to drive uninstalls itself, since installer behavior varies too much per app to do safely.

## v1.3 — 2026-11-14

### New: App Usage tab
- Tracks the most-used apps by time: a 15-second sampler while Cortexa's GUI is open, plus a 15-minute sample from the background watchdog so tracking continues when the window is closed. Only counts processes with an actual visible window (filters out background services/drivers).
- Shows Today and All-Time totals, sortable.
- **Dynamic app size**: disk size per app is computed on demand (via a background job, same non-blocking pattern as the folder/file scanners) from the app's install folder — not cached or static, recalculated fresh each time you click Calculate Sizes.
- Reset Usage Data button to clear tracked history.
- Usage data stored in `logs/app_usage.json`, separate from the main watchdog log.

## v1.2 — 2026-11-08

### AI Agent — final batch
- **Comparative analysis**: every analysis and chat response now includes a historical baseline (averages from the watchdog's own logged scans) when enough history exists, so the AI can say whether today's numbers are actually unusual for *this* PC rather than judging them against generic thresholds.
- **Explain This Alert**: select any entry in Recent Alerts and ask the AI why it likely happened and what to do, with the alert text and live system context.
- **Plain-language monitoring rules**: describe a threshold in Settings (e.g. "tell me if chrome uses more than 2GB") and the AI turns it into a structured rule the watchdog checks every 15 minutes. Rules are listed and deletable in Settings.
- **Per-action auto-approve**: optionally skip the confirmation dialog for the command bar's two lowest-risk actions (Free Up RAM, Clean Temp Junk) only — hard-coded eligibility list enforced in the core module, not just a UI toggle; ending a process, stopping software, Speed Boost, and Restore Points always confirm regardless of settings.

### Fixed
- Command bar parser: the local model drops the required `ACTION:` prefix in a majority of runs (measured ~60% in testing) and just emits the bare token - the parser now falls back to finding a known token anywhere in the response instead of silently failing to "None".
- `.exe` compatibility: path resolution and UAC self-elevation both assumed running as a `.ps1`, which broke once compiled via ps2exe.

### Release
- `Cortexa.exe` built and published as a [GitHub Release](https://github.com/CharmThiekshanaPerera/cortexa/releases) (v1.1.0), repo made public, MIT licensed.

## v1.1 — 2026-11-08

### AI Agent — agentic features
- Natural-language command bar (persistent, visible on every tab): type a request like "free up my ram" or "close spotify", the AI maps it to one action from a fixed whitelist, you confirm before anything runs
- Model Manager: pull/delete Ollama models from inside the app
- Multi-step plans: "Run All Suggested Steps" executes an AI-ordered sequence of whitelisted actions with one upfront confirmation
- Action audit log: every AI-suggested action and whether it was accepted or declined, viewable on the AI Agent tab

### Polish
- First-run welcome overlay (shown once, explains all tabs)
- `CHANGELOG.md`

## v1.0 — 2026-11-08

### Monitoring
- System health snapshot: RAM, CPU, disk free space (C:/D:), with live sparkline trend charts
- Network monitoring: live download/upload throughput, per-adapter totals, active connections (netstat-style), traffic history
- Disk I/O live throughput (read/write MB/s)
- System info: uptime, battery status + health report (wear %), GPU utilization
- Security status: Windows Defender, Firewall, BitLocker, disk health/SMART, devices with driver errors
- Recent Windows system/application errors (last 24h)
- WSL/Docker disk and memory footprint

### Task & process management
- Advanced task manager: multi-select, End Task, End Task Tree (kills child processes too), Open File Location, Set Priority, auto-refresh
- Windows Scheduled Tasks browser with Enable/Disable
- Startup items (registry Run keys + Startup folder) with reversible Enable/Disable (backs up before disabling)

### Cleanup & optimization
- Safe Temp/npm-cache cleanup
- Free Up RAM (working-set trimming via `EmptyWorkingSet`)
- Speed Boost (chains cleanup + WSL shutdown + RAM trim + unwanted-software stop, with before/after comparison)
- Stop Unwanted Software (user-defined list, confirm-gated)
- Docker prune, WSL shutdown
- Largest folders / largest individual files scanner
- System Restore point creation

### Background watchdog
- Scheduled task running every 15 minutes, independent of the GUI
- Configurable alert thresholds, Windows toast notifications
- Optional Slack/Discord webhook alerts
- Focus Mode (suppresses notifications without disabling monitoring)
- Auto-generated daily HTML health report (30-day retention)
- Auto-cleanup when disk space gets critical

### AI Agent (Ollama integration)
- Local LLM connection (auto-detects installed models, can start the Ollama server from the app)
- System analysis: diagnosis + prioritized recommendations from live system data
- Chat: ask questions about your system in plain language
- Clickable action chips: AI suggestions from a fixed, code-enforced whitelist, routed through the same buttons/confirmations a manual click would use — the AI never executes anything directly
- "Ask AI About Selected" — explains what a selected process is and whether it's safe to end
- "AI Review Startup Items" — flags startup programs as safe-to-disable / keep / unsure

### Branding & polish
- Renamed from PCGuard to Cortexa, custom-generated icon (hexagonal chip/node design)
- Modern dark UI: card-based layout, live sparklines, pill-style tabs
- Admin self-elevation via UAC with status badge
- Fixed: tab content clipping (added scroll containers), tab-strip overflow risk (widened window, added horizontal scroll fallback), array-unwrap bug affecting single-item list results (fixed in ~10 locations)

### Documentation
- `README.md`, `DEVELOPMENT.md`, `TESTING.md`
