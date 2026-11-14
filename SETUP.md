# Running Cortexa in a New Environment

Everything you need to get Cortexa running from scratch on a Windows machine that has never seen it before — whether that's a clean PC, a VM, or just a folder you copied over. Pick one of the two paths below; you don't need both.

## Path A: Just run the `.exe` (no PowerShell knowledge needed)

1. Download the latest release from [github.com/CharmThiekshanaPerera/cortexa/releases](https://github.com/CharmThiekshanaPerera/cortexa/releases) and extract the zip anywhere you like (e.g. `C:\Cortexa`).
2. Double-click `Cortexa.exe`.
3. **Windows SmartScreen will likely say "Windows protected your PC."** This is expected — the `.exe` isn't code-signed (that needs a paid certificate), so any new, unsigned executable triggers this once per machine. Click **More info → Run anyway**.
4. A UAC prompt follows — click **Yes**. Cortexa requests admin rights for ending protected processes, managing scheduled tasks/startup items, Docker/WSL cleanup, and System Restore points. Declining still runs it, just with reduced functionality (a badge in the title bar shows which mode you're in).
5. That's it — the window opens. Skip to **First run** below.

## Path B: Run from source

1. Make sure you have **Windows 10/11** and **PowerShell 5.1+** (built into Windows already — nothing to install) or PowerShell 7+.
2. Get the source onto the machine, either:
   ```powershell
   git clone https://github.com/CharmThiekshanaPerera/cortexa.git
   ```
   or download the repo as a zip from GitHub and extract it.
3. From inside that folder, run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File PCGuard-GUI.ps1
   ```
   The `-ExecutionPolicy Bypass` flag is needed because Windows blocks unsigned scripts by default on most machines — this bypasses that for just this one invocation, it doesn't change your system-wide execution policy.
4. A UAC prompt appears (same as Path A, step 4) — click **Yes**.

Everything below applies to either path.

## First run

- No `config.json` exists yet — Cortexa runs on built-in defaults until you visit **Settings** and click **Save**, which creates it. (`config.example.json` in the repo shows the full default schema if you want to hand-craft one instead — copy it to `config.json` and edit before first launch.)
- A one-time welcome overlay explains each tab; dismiss it with "Got it - let's go."
- Everything core (monitoring, cleanup, process/task/startup management) works immediately with **zero setup** — no accounts, no API keys, no internet connection required.

## Optional: local AI (Ollama)

Powers the **AI Agent** tab (chat, system analysis, suggested actions, command bar) — fully local, no data leaves the machine.

1. Install [Ollama](https://ollama.com) for Windows.
2. Pull at least one model, e.g.:
   ```powershell
   ollama pull qwen2.5:3b
   ```
3. Open Cortexa's **AI Agent** tab — it auto-detects installed models and shows connection status. If Ollama isn't running, click **Start Ollama** to launch it from inside the app.

## Optional: Claude (Anthropic API)

Powers three specialized agents (Network Monitor, Storage Manager, Security Monitor) with more capable cloud models. **Skip this if you don't want any data leaving the machine** — everything else in Cortexa works fully offline without it.

1. Get an API key from [console.anthropic.com](https://console.anthropic.com).
2. In Cortexa, go to **Settings → Claude (Anthropic API)**, paste the key into the masked field, pick a model from the dropdown (or leave the default), and click **Save**.
3. Optionally set a monthly token limit (0 = unlimited) so usage can't run away unnoticed.
4. If you'd rather not use Claude at all but still want these three agents, switch **AI Provider** to "Ollama (local)" instead — same agents, routed to your local model, no key needed.

The key is written only to your local `config.json`, which is gitignored — it's never part of the repo and never leaves the machine except in the literal API calls you trigger by clicking an "Analyze" button.

## Optional: background watchdog (monitoring when the app is closed)

Click **Install Watchdog** on the Dashboard, or run manually from the project folder:
```powershell
. .\PCGuardCore.psm1
Install-Watchdog -ScriptDir "<path to this folder>"
```
This registers a per-user Scheduled Task (`PCGuard-Watchdog`) that runs `PCGuard.ps1` every 15 minutes independently of the GUI — logging health/network/app-usage/security history, raising alerts, and (optionally) running an AI analysis. Uninstall it the same way, from the Dashboard button or `Uninstall-Watchdog`.

## Moving to yet another machine later

Nothing is hardcoded to a specific path or user — `Install-Watchdog`/`Install-PCGuard.ps1` resolve the script folder at install time (`$PSScriptRoot`/`-ScriptDir`), and the compiled `.exe` resolves its own folder at runtime rather than assuming a build-time path. Copying the whole project folder to a new location and re-running Path A or B above is enough; just reinstall the watchdog if you had one, since a Scheduled Task registered against the old path won't follow the move automatically.

## If something doesn't work

- **"cannot be loaded because running scripts is disabled"** — you ran `PCGuard-GUI.ps1`/`PCGuard.ps1` directly instead of through `powershell -ExecutionPolicy Bypass -File ...`. Use the command from Path B, step 3.
- **UAC prompt never appears / app runs without admin badge** — you may have declined it; just relaunch and accept this time, or keep using the standard-privilege mode if that's intentional.
- **AI Agent tab shows Ollama as unavailable** — Ollama isn't installed or isn't running; see the Ollama section above.
- **Claude agent buttons show a key/configuration error** — no key saved yet, or the AI Provider is still set to Claude with an empty key; see the Claude section above.
- For anything else, see `TESTING.md` for how to validate your own setup, and `DEVELOPMENT.md`/`ARCHITECTURE.md` if you're trying to understand *why* something behaves the way it does.
