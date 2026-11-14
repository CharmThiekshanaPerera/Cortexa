# Contributing to Cortexa

Thanks for taking a look. This is a single-maintainer personal project, so there's no CI pipeline or formal review board — the checklist below is what the maintainer runs by hand before every commit, and contributions are expected to follow the same bar.

## Before you start

- Read `DEVELOPMENT.md` first — it documents the file layout, the "AI only ever suggests" safety architecture, and five real bug classes that have bitten this codebase before (array-unwrap, module-scope `$script:` variables, scriptblock closures, `$matches` collision, `Get-ChildItem` on malformed paths). Repeating one of those is the most likely way a PR gets bounced.
- Read `TESTING.md` for how to validate a change (syntax check, headless XAML load, the real checks to run against your own machine before calling something done).
- For anything beyond a small fix, open an issue first describing what you want to change and why — this is a tool that runs with admin rights on real machines, so design discussion before code saves everyone time.

## Development setup

- Windows 10/11, PowerShell 5.1+ (built in) or PowerShell 7+.
- No build step for development: run `powershell -ExecutionPolicy Bypass -File PCGuard-GUI.ps1` directly from a clone.
- Optional: [Ollama](https://ollama.com) to test the local AI Agent tab; an Anthropic API key to test the Claude-powered agents (Network Monitor, Storage Manager, Security Monitor) — **never commit a real key**, see below.

## The pattern for adding a feature

From `DEVELOPMENT.md`, this is the order that keeps the module/GUI/watchdog split intact:

1. Write the function in `PCGuardCore.psm1`. Add it to the `Export-ModuleMember` list at the end of the file.
2. Test it standalone against your real system before touching the GUI:
   ```powershell
   Import-Module "C:\path\to\PCGuardCore.psm1" -Force
   Your-NewFunction -SomeParam value
   ```
3. Add the XAML inside the relevant `<TabItem>` (or a new one). Give every interactive element an `x:Name`.
4. Add every new control name to the big `foreach ($n in @(...))` `FindName` list — a name missing from this list means `$ControlName` is silently `$null` later, not an error at load time.
5. Write the code-behind handler. Anything touching the OS that might take >100ms goes through the `Start-AiJob`-style background job pattern, not synchronously on the UI thread.
6. Wrap every `ListView`/`ListBox` `.ItemsSource` assignment in `@(...)` — see the array-unwrap gotcha in `DEVELOPMENT.md`.
7. Validate per `TESTING.md`: PowerShell syntax check on all three files (`PCGuard-GUI.ps1`, `PCGuardCore.psm1`, `PCGuard.ps1`) and a headless XAML load confirming every new named control resolves, at minimum.
8. Update `README.md` (if it changes what a tab does) and add a `CHANGELOG.md` entry.

## Security - read before your first commit

- **Never commit an Anthropic API key, or any other secret.** `config.json` is gitignored for exactly this reason — don't work around that.
- Before every commit that touches Claude-related code or config handling, run:
  ```bash
  git diff --cached | grep -i "sk-ant-"
  ```
  and confirm it finds nothing. After pushing, `git show HEAD | grep -i "sk-ant-"` should also come back empty.
- If you're not sure whether something is sensitive, ask in your PR description rather than pushing it.
- See `SECURITY.md` for the fuller security design and how to report an actual vulnerability (not via a public issue).

## Code style

- No enforced linter/formatter — match the existing style in the file you're editing (4-ish-char indentation isn't a hard rule, but single-quoted strings by default, `[string]`/`[int]`-typed params, PascalCase function names following PowerShell's `Verb-Noun` convention).
- Prefer a real exported function in `PCGuardCore.psm1` over inline logic in the GUI script, even for something small — the module is meant to stay the single source of truth so the watchdog (`PCGuard.ps1`) can reuse it too.
- Comments should explain *why*, not *what* — a comment restating the next line in English isn't useful; a comment explaining a non-obvious constraint (like the ones already in the codebase about `$script:` scope or the array-unwrap bug) is.

## Pull requests

- Keep PRs focused — one feature or fix per PR is much easier to review than a bundle.
- Describe what you tested and how (which tab, what real data you saw it handle) in the PR description; "should work" isn't enough for a tool that runs with admin rights.
- Don't bump the version/changelog header for an in-progress PR — that's finalized when it's merged.

## License

By contributing, you agree your contribution is licensed under this project's MIT License (see `LICENSE`).
