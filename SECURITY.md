# Security Policy

Cortexa requests administrator rights and touches sensitive areas of Windows (processes, startup items, scheduled tasks, firewall/Defender/BitLocker status, your installed-app list). This document covers how it's designed to limit risk, and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Instead:

- Use GitHub's private vulnerability reporting: open the [Security tab](https://github.com/CharmThiekshanaPerera/cortexa/security) on this repo → "Report a vulnerability", or
- Contact the maintainer directly via the profile on [CharmThiekshanaPerera](https://github.com/CharmThiekshanaPerera).

Include what you found, how to reproduce it, and the potential impact. This is a single-maintainer personal project (no dedicated security team), so response times aren't guaranteed, but reports are taken seriously and credited in the `CHANGELOG.md` fix entry unless you ask not to be.

## Design decisions that exist for security reasons

- **Local-first by default.** The only AI path that sends data off the machine is the optional Claude integration (Network Monitor, Storage Manager, Security Monitor agents) — and only when you click one of those agents' buttons with an API key configured. Everything else, including the main AI Agent tab, runs on a local Ollama model with zero network egress.
- **The AI never executes anything directly.** Every AI-suggested action (Ollama or Claude) is advisory text only. Where Cortexa does map AI output to an action (the command bar, "Run All Suggested Steps"), the mapped token is re-validated against a hard-coded whitelist in `PCGuardCore.psm1` and routed through the *same* button/confirmation dialog a manual click would use — there is no code path where parsed AI output results in a `Stop-Process`, registry write, or similar directly. See `DEVELOPMENT.md`'s "AI agent's safety design" section for the implementation details.
- **API keys are never committed.** The Anthropic API key is entered via a masked `PasswordBox`, stored only in your local `config.json` (gitignored, never part of the repo), and every commit in this project's history is scanned for the key pattern before pushing. If you ever find a real key committed anywhere in this repo's history, report it as a vulnerability immediately — it should not be possible, but treat any instance as urgent.
- **Admin rights are requested, not silently assumed.** Cortexa prompts for UAC elevation on launch (needed for ending protected processes, managing scheduled tasks/startup items, Docker/WSL cleanup, System Restore points) and shows which mode it's running in via the title-bar badge. Declining the prompt still runs the app at standard privileges with reduced functionality, rather than failing outright.
- **Destructive actions are confirm-gated and reversible where possible.** Ending a process, stopping software, Speed Boost, and creating/restoring from a Restore Point always show a confirmation dialog, with no setting to bypass that. Disabling a startup item backs it up first (`DisabledStartupItems/`) so it can be re-enabled. Only two low-risk, fully reversible actions (Free Up RAM, Clean Temp Junk) can be opted into auto-approve, and that eligibility list is enforced in code, not just the UI.
- **No packet capture, no email credential storage.** The Network tab is bandwidth/connection monitoring, not packet-level inspection — that would need a capture driver (Npcap) and broader access than this tool is meant to have. Webhook alerts (Slack/Discord) are supported instead of SMTP specifically to avoid needing to store an email password in `config.json`.

## Supported versions

This is a actively-developed personal tool without formal version branches — only the latest commit on `master` and the latest [Release](https://github.com/CharmThiekshanaPerera/cortexa/releases) are supported. If you're on an older `.exe` release and suspect a security issue, please confirm against the latest release or `master` first.

## What's not considered a vulnerability

- The UAC elevation prompt itself (it's expected, not a bypass of Windows' own security model).
- Windows SmartScreen flagging the unsigned `.exe` on first run — expected for any unsigned executable from a new publisher, not a Cortexa-specific issue.
- Claude/Ollama giving an incorrect recommendation — both are explicitly advisory; see the "AI judgment quality is bounded by the local model" note in `DEVELOPMENT.md`.
