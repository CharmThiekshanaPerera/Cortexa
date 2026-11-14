# Cortexa — AI Agents

Cortexa has four AI agents and one non-AI automated process that's sometimes confused for one. This document covers each: what it sees, what backend runs it, what it can (and can't) do, and how it fits the safety model. For the list of concrete actions any agent can trigger, see `SKILLS.md`. For how the backends are wired up internally, see `ARCHITECTURE.md`.

## The one rule that applies to all of them

**No agent executes anything directly.** Every agent is advisory: it produces text, or at most a token from a fixed whitelist that the GUI re-validates and routes through a real button's existing confirmation dialog. There is no code path anywhere in Cortexa where parsed AI output results in a `Stop-Process`, registry write, firewall change, or similar directly. See `DEVELOPMENT.md`'s "AI agent's safety design" section for the implementation.

## 1. General AI Agent (AI Agent tab)

- **Backend:** Ollama only, always local. Whichever model is selected in the tab's dropdown (auto-detected from what's pulled; `Pull Model`/`Delete Model` manage models from inside the app).
- **Data it sees:** a compact live system snapshot (`Get-AiSystemContext` — RAM/CPU/disk, uptime, battery, top processes, Defender status, driver errors) plus historical baselines from the watchdog's own logs, so it can say whether today's numbers are unusual for *this* machine.
- **What it does:**
  - **Chat** (`Invoke-AiChat`) — free-form questions about your system.
  - **System analysis** (`Invoke-AiSystemAnalysis`) — a full diagnosis + prioritized recommendations, ending with a `SUGGESTED_ACTIONS:` line drawn only from the fixed action vocabulary, rendered as clickable chips.
  - **Natural-language command bar** (`Invoke-AiParseCommand`/`Get-AiParsedCommand`, visible on every tab) — maps a typed request like "free up my ram" to one whitelisted action (or `EndProcess:<name>` / `OpenTab:<name>`), with a confirmation dialog before anything runs (except pure navigation).
  - **"Ask AI About Selected"** (`Invoke-AiExplainProcess`) — explains a selected process and whether it looks safe to end.
  - **"AI Review Startup Items"** (`Invoke-AiReviewStartupItems`) — flags each startup entry safe-to-disable / keep / unsure.
  - **"Ask AI: Keep or Delete?"** (`Invoke-AiAppDecision`, App Usage tab) — a Keep/Consider-uninstalling recommendation per app, based on size/publisher/last-used.
  - **"Explain This Alert"** (`Invoke-AiExplainAlert`) — why a logged alert likely happened and what to do.
  - **Plain-language monitoring rules** (`Invoke-AiParseRule`/`Get-AiParsedRule`) — turns "tell me if chrome uses more than 2GB" into a structured rule the watchdog checks every cycle.
- **Multi-step plans:** "Run All Suggested Steps" shows one upfront confirmation listing the ordered steps, then raises each mapped button's click event in sequence. Buttons with their own internal confirm dialog (Speed Boost, Stop Unwanted, Restore Point) still show that second dialog — a button's own safety gate is never skipped just because a higher-level flow already asked once.
- **Audit trail:** every suggested action and the user's decision (`Accepted`/`Declined`/`AutoApproved`) is logged via `Write-AiActionLog`, visible on the AI Agent tab's "Action History" panel.
- **Auto-approve:** optionally skips the confirmation dialog for exactly two actions — `FreeRam` and `CleanTemp` — the lowest-risk, fully reversible pair. This eligibility list (`Get-AutoApproveEligibleActions`) is enforced in the module itself, not just a UI toggle; it can't be widened from Settings.

## 2–4. The three Claude-powered specialist agents

Each lives on the tab whose data it's built around, each is **optional** (needs an Anthropic API key, or can be switched to run on Ollama instead — see "Provider switch" below), and each is the one place its data leaves the machine when using Claude.

| Agent | Tab | Core function | What it reviews |
|---|---|---|---|
| **Network Monitor** | Network | `Invoke-ClaudeNetworkAnalysis` | adapter totals, active connections, realtime stats (connection count, listening ports, unique remote IPs), and the persisted connection-count trend |
| **Storage Manager** | App Usage | `Invoke-ClaudeStorageAnalysis` | disk free space, realtime app stats (total/unused apps, unused/total size), the persisted unused-size trend, recent install/uninstall activity, and the biggest installed apps with usage status |
| **Security Monitor** | Security | `Invoke-ClaudeSecurityAnalysis` | firewall/Defender/BitLocker status, driver errors, listening services (attack surface), realtime stats, and the last 24h of Windows security events (logons, account/firewall/Defender changes, new services) |

Shared properties of all three:

- **Advisory only.** They report; they never block a connection, delete a file, uninstall an app, or change a setting themselves.
- **No fabricated CVEs.** The Security Monitor is explicitly instructed never to invent a specific CVE number or claim knowledge of a live vulnerability database — it sticks to configuration-level risks and event patterns actually visible in the data it was given.
- **Multi-turn chat.** Each has a "Continue Conversation" box. The first analysis seeds a real message history (`Invoke-ClaudeChat`, full `messages` array sent each turn), so a follow-up like "which one should I fix first?" gets an answer that actually accounts for the earlier analysis — not an independent one-shot call.
- **Provider switch.** Settings → "AI Provider for these three agents" can route the one-shot "Analyze" button to local Ollama instead of Claude (`-Provider 'Ollama' -OllamaModel <model>` on the same core function — identical prompt, different backend, no data leaves the machine, no token cost). "Continue Conversation" still requires Claude; the GUI shows a clear message rather than silently failing if you try it while on Ollama.
- **Token usage & limit.** Every real Claude call (analysis or chat) logs its token cost (`Add-ClaudeTokenUsageSample`). A monthly limit can be set in Settings (0 = unlimited); `Test-ClaudeTokenLimit` is checked *before* the HTTP request inside `Invoke-ClaudeGenerate`/`Invoke-ClaudeChat`, so a reached limit costs nothing rather than being flagged only after the fact.

## Not an AI agent: the background watchdog

`PCGuard.ps1`, run every 15 minutes by the `PCGuard-Watchdog` Scheduled Task, is **automation, not AI** — it's a fixed script that samples health/network/app-usage/security state, checks thresholds and user-defined rules, raises alerts, and (only if `AiEnabled` is set in Settings) optionally runs the General AI Agent's system analysis once per cycle and logs the result (never shown as a popup). It's listed here only to be explicit that it is not itself an agent with judgment — it's the thing that keeps the other agents' persisted history building when the GUI is closed.

## Adding a new agent

1. Decide its data (what does it need to see that no existing agent already surfaces?) and write a `Get-XStatsSnapshot`-style core function if it needs a realtime-stats/trend/event-log setup — reuse `Add-JsonHistorySample`/`Get-JsonHistory` rather than inventing another persistence format.
2. Write `Invoke-ClaudeXAnalysis` (or an Ollama-only equivalent) following the existing three as a template: build the prompt and system prompt as local variables, branch on `-Provider` at the very end, call `Invoke-ClaudeGenerate -RootDir $RootDir -Agent '<name>'` for the Claude path so token tracking picks it up automatically.
3. If it should support multi-turn chat, follow the `$script:ClaudeXMessages`/`$script:ClaudeXSystemPrompt`/`$script:ClaudeXBaseText` pattern already used by the other three, including `.GetNewClosure()` on the `-OnComplete` scriptblock (see `DEVELOPMENT.md`'s closure gotcha).
4. If any action it could prompt is new (not already a button), it must go through the same whitelist-and-real-button pattern as every other action — see `SKILLS.md` and `DEVELOPMENT.md`.
