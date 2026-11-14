# Cortexa — Skills & Capabilities Catalog

Every discrete thing Cortexa can do, in one reference. "Skill" here means a concrete capability — an action the app can perform, or a read-only capability it exposes — not a vague feature description. For which AI agent (if any) can trigger which action, see `AGENTS.md`. For the architecture behind the safety model, see `DEVELOPMENT.md`.

## How to read this

- **Manual path**: the button/control a user clicks themselves. This always exists for every action — there is no AI-only action.
- **AI-triggerable**: whether an AI agent can *suggest* this (chips, command bar, multi-step plan) — suggesting always still routes through the manual path's own button and confirmation, per the safety model in `AGENTS.md`.
- **Confirm?**: whether a confirmation dialog is shown. "Always" means no setting can bypass it.
- **Reversible?**: whether the action can be undone, and how.

## Cleanup & optimization

| Skill | Core function | Manual path | AI-triggerable | Confirm? | Reversible? |
|---|---|---|---|---|---|
| Free Up RAM (working-set trim) | `Invoke-FreeUpRam` | Dashboard button | Yes (chip, command bar, auto-approve eligible) | No if auto-approved, else Yes | Yes — no lasting change, RAM just gets used again |
| Clean Temp / npm-cache junk | `Invoke-SafeCleanup` | Dashboard button | Yes (chip, command bar, auto-approve eligible) | No if auto-approved, else Yes | No — files are deleted (but only from Temp/npm-cache) |
| Speed Boost (chained cleanup + WSL shutdown + RAM trim + stop unwanted) | — (GUI orchestrates the above) | Dashboard button | Yes (chip, command bar) | Always (own dialog) | Partially — see component actions |
| Stop Unwanted Software (user-defined list) | `Invoke-StopUnwantedProcesses` | Dashboard button | Yes (chip, command bar) | Always (own dialog) | Yes — just relaunch the app |
| Shutdown WSL | `Invoke-WslShutdown` | Dashboard / Disk Analysis button | Yes (chip, command bar) | No | Yes — WSL restarts on next use |
| Docker Prune (`docker system prune -a --volumes`) | — (direct `docker` CLI call) | Disk Analysis button | No | Always (own dialog, explains impact) | No — images/volumes are gone, must re-pull/rebuild |
| Auto-cleanup when disk critically low | `Invoke-SafeCleanup` | — (watchdog-only, automatic) | N/A | N/A (no user present) | No |

## Safety / recovery

| Skill | Core function | Manual path | AI-triggerable | Confirm? | Reversible? |
|---|---|---|---|---|---|
| Create System Restore Point | `Invoke-CreateRestorePoint` | Dashboard button | Yes (chip, command bar) | Always (own dialog) | N/A — this action *creates* a rollback point |
| Battery Health Report | `Get-BatteryHealthReport` | Dashboard button | No | No | N/A — read-only |

## Process management

| Skill | Core function | Manual path | AI-triggerable | Confirm? | Reversible? |
|---|---|---|---|---|---|
| End Task | — (`Stop-Process`) | Processes tab button | Yes — command bar `EndProcess:<name>`, re-validated against live `Get-Process` before anything happens | Always | No |
| End Task Tree (kills children too) | `Stop-ProcessTree` | Processes tab button | No | Always | No |
| Set Process Priority | `Set-ProcessPriority` | Processes tab | No | No | Yes — set it back |
| Open File Location | `Get-ProcessFilePath` | Processes tab button | No | No | N/A — read-only |
| Ask AI About Selected (explain + safety verdict) | `Invoke-AiExplainProcess` | Processes tab button | N/A (this *is* the AI feature) | No | N/A — advisory text only |

## Startup & scheduled tasks

| Skill | Core function | Manual path | AI-triggerable | Confirm? | Reversible? |
|---|---|---|---|---|---|
| Disable Startup Item | `Disable-StartupItem` | Startup tab button | No | No | Yes — backed up to `DisabledStartupItems/` before disabling |
| Enable Startup Item | `Enable-StartupItem` | Startup tab button | No | No | N/A — this *is* the undo |
| AI Review Startup Items (safe-to-disable verdicts) | `Invoke-AiReviewStartupItems` | Startup tab button | N/A (this *is* the AI feature) | No | N/A — advisory text only |
| Enable/Disable Scheduled Task | `Set-ScheduledTaskState` | Tasks tab button | No | No | Yes — toggle back |

## Network

| Skill | Core function | Manual path | AI-triggerable | Confirm? | Reversible? |
|---|---|---|---|---|---|
| Live download/upload throughput | `Get-NetworkStats` | Network tab (auto or manual refresh) | No | N/A | N/A — read-only |
| Active connections list (netstat-style) | `Get-ActiveConnections` | Network tab | No | N/A | N/A — read-only |
| Network Activity Log (new-connection diff) | — (GUI-side diff each refresh) | Network tab | No | N/A | N/A — read-only, session-only |
| Realtime network stats + persisted trend | `Get-NetworkMonitorStats` | Network tab | No | N/A | N/A — read-only |
| Analyze Network (Claude or Ollama) | `Invoke-ClaudeNetworkAnalysis` | Network tab button | N/A (this *is* the AI feature) | No | N/A — advisory text only |

## Security

| Skill | Core function | Manual path | AI-triggerable | Confirm? | Reversible? |
|---|---|---|---|---|---|
| Defender / Firewall / BitLocker status | `Get-SecurityStatus` | Security tab | No | N/A | N/A — read-only |
| Disk health (SMART) | `Get-DiskHealth` | Security tab | No | N/A | N/A — read-only |
| Listening Services (attack surface) | `Get-ListeningServices` | Security tab | No | N/A | N/A — read-only |
| Security Event Log (24h) | `Get-SecurityEventLog` | Security tab | No | N/A | N/A — read-only |
| Realtime security stats + persisted trend | `Get-SecurityStatsSnapshot` | Security tab | No | N/A | N/A — read-only |
| Quick Access (open Firewall/BitLocker/Device Manager/Windows Security) | — (`Start-Process` to a native Windows applet) | Security tab buttons | No | No | N/A — opens a native Windows UI, doesn't change anything itself |
| Analyze Security (Claude or Ollama) | `Invoke-ClaudeSecurityAnalysis` | Security tab button | N/A (this *is* the AI feature) | No | N/A — advisory text only |

## App Usage

| Skill | Core function | Manual path | AI-triggerable | Confirm? | Reversible? |
|---|---|---|---|---|---|
| Combined app list (installed + tracked, usage + size) | `Get-CombinedAppsSummary` | App Usage tab | No | N/A | N/A — read-only |
| Calculate Real Sizes (on-demand, true folder size) | `Get-AppSizeOnDisk` | App Usage tab button | No | No | N/A — read-only, just slower/accurate |
| Open Apps & Features (to uninstall) | — (`Start-Process ms-settings:appsfeatures`) | App Usage tab button | No | No | N/A — opens native Windows uninstaller, Cortexa doesn't drive it |
| Reset Usage Data | `Reset-AppUsageStats` | App Usage tab button | No | Always | No — tracked history is cleared |
| Install/Uninstall Activity Log | `Update-AppInstallBaseline` / `Get-AppInstallEventLog` | App Usage tab | No | N/A | N/A — read-only |
| Realtime app stats + persisted trend | `Get-AppUsageStatsSnapshot` | App Usage tab | No | N/A | N/A — read-only |
| Ask AI: Keep or Delete? | `Invoke-AiAppDecision` | App Usage tab button | N/A (this *is* the AI feature) | No | N/A — advisory text only, never uninstalls |
| Analyze Storage (Claude or Ollama) | `Invoke-ClaudeStorageAnalysis` | App Usage tab button | N/A (this *is* the AI feature) | No | N/A — advisory text only |

## AI Agent tab

| Skill | Core function | Manual path | Confirm? |
|---|---|---|---|
| Chat about your system | `Invoke-AiChat` | AI Agent tab | No |
| Full system analysis + suggested-action chips | `Invoke-AiSystemAnalysis` | AI Agent tab button | Per-chip, see Cleanup/Safety tables above |
| Natural-language command bar | `Invoke-AiParseCommand` | persistent bar, every tab | Yes, unless auto-approved or pure navigation |
| Run All Suggested Steps (multi-step plan) | — (GUI orchestrates chips in order) | AI Agent tab button | One upfront + any step's own dialog |
| Plain-language monitoring rule creation | `Invoke-AiParseRule` | Settings tab | No (rule just gets added; watchdog enforces it going forward) |
| Explain This Alert | `Invoke-AiExplainAlert` | AI Agent / History tab | No |
| Model Manager (pull/delete Ollama models) | `Invoke-OllamaPullModel` / `Invoke-OllamaDeleteModel` | AI Agent tab | No |
| Action History (audit log) | `Get-AiActionLog` | AI Agent tab | N/A — read-only |

## Settings

| Skill | Core function | Manual path |
|---|---|---|
| Alert thresholds (RAM/disk warn/critical) | `Save-PCGuardConfig` | Settings tab |
| Webhook alerts (Slack/Discord) | `Send-WebhookAlert` | Settings tab |
| Install/Uninstall background watchdog | `Install-Watchdog` / `Uninstall-Watchdog` | Dashboard button |
| Settings backup/restore | `Export-PCGuardSettings` / `Import-PCGuardSettings` | Settings tab |
| Claude API key (set/clear), model picker | — (`Get-PCGuardConfig`/`Save-PCGuardConfig`) | Settings tab |
| AI Provider switch (Claude ↔ Ollama for the 3 specialist agents) | — (config field, read by the 3 agent functions) | Settings tab |
| Monthly Claude token limit | `Test-ClaudeTokenLimit` | Settings tab |
| Claude token usage display (today/month/all-time) | `Get-ClaudeTokenUsageSummary` | Settings tab |
| Per-action auto-approve (Free Up RAM, Clean Temp only) | `Get-AutoApproveEligibleActions` | Settings tab |

## The whitelisted AI action vocabulary

The exact tokens any AI agent's output is allowed to map to (everything else is silently dropped, never executed): `FreeRam`, `CleanTemp`, `StopUnwanted`, `SpeedBoost`, `ShutdownWsl`, `RestorePoint`, plus the command bar's two parameterized tokens `EndProcess:<name>` and `OpenTab:<name>`. Of these, only `FreeRam` and `CleanTemp` are eligible for auto-approve (skipping the confirmation dialog), and that eligibility list is enforced in `PCGuardCore.psm1`, not just the Settings UI. See `AGENTS.md` for which agents can produce which tokens, and `DEVELOPMENT.md` for how a hallucinated/unknown token is handled (dropped, not executed).
