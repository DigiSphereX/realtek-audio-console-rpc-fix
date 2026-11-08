# Contributing

Thanks for taking the time to improve this project.

## Ground rules

- **English only** in code, comments, commits, issues and documentation.
- Keep the script compatible with **Windows PowerShell 5.1** (no `&&`, no ternary
  operator, no PowerShell 7-only cmdlets).
- Test on a real Windows 10/11 machine with Realtek audio before opening a pull request.
- Never commit secrets, tokens, personal paths or log files.

## Reporting a problem

Please include:

1. Windows version and build (`winver`).
2. Realtek driver version (Device Manager -> Sound, video and game controllers ->
   Realtek(R) Audio -> Properties -> Driver).
3. Output of `.\src\Fix-RealtekAudioConsole.ps1 -Action Diagnose`.
4. The exact error text from Realtek Audio Console.

## Pull requests

1. Fork the repository and create a topic branch.
2. Keep the change focused and update `CHANGELOG.md`.
3. Run the diagnostic before and after your change.
4. Open the pull request with a short description and the diagnostic output.

## Code style

- 4-space indentation, `PascalCase` functions, `$camelCase` variables.
- Comment every non-obvious system change.
- Fail soft: a missing optional component must not abort the whole repair.
