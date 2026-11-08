# Changelog

All notable changes to Realtek Audio Console RPC Fix are documented here.

## 1.0.0 - 2026-11-08

- First public release.
- `-Action Diagnose`: read-only report of the service, the logon task, the per-user
  RPC helper, Windows Audio, the app package and the Realtek endpoints.
- `-Action Fix`: enables `RtkAudUService64_BG`, relaxes its battery/time-limit
  settings, starts the helper immediately, and verifies the result.
- Automatic fallback logon task (`RealtekAudioConsoleRpcHelper`) when the vendor task
  is missing.
- `-ResetApp` resets the Realtek Audio Console UWP package state.
- `-LaunchApp` opens the console after a successful repair.
- `-Action Restore` disables the task and stops the helper.
- Self-elevation, timestamped logging to
  `%ProgramData%\RealtekAudioConsoleRpcFix\fix.log`, and clear exit codes.
- One-click launchers: `Run-Fix.cmd` and `Run-Diagnose.cmd`.
