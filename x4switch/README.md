# X4Switch — choose how X4: Foundations starts

A small Windows program (`X4Switch.exe`, plain C + Win32, ~350 KB, no installer, no .NET, no downloads) that starts
**X4: Foundations** in one of two ways, so you never run scripts by hand:

| Choice | What happens |
|---|---|
| **Cockpit – three monitors** | One borderless game window across side \| centre \| side monitors (the [x4cockpit3](../x4cockpit3) kit's window hook). |
| **Single monitor + dashboard** | The normal game on the main monitor, the [X4 Companion](../x4companion) map in a browser window beside it. |

## Why an external program (and not a switch inside the game)

The cockpit needs the game window's size and the window hook **when the game process starts**: the hook DLL is
loaded before X4's own code runs, and X4 fixes its window/render size at start. A running game cannot be moved from
one mode to the other. So the switch is a small launcher that sets the mode and then starts the game.

## How the two modes work

**Cockpit** (the game must be closed — X4Switch never closes or kills it):
1. checks the game exe, the kit and the hook files (`native\out\launcher.exe`, `x4c3hook.dll`);
2. checks the monitor arrangement with the kit (`x4cockpit3.ps1 -Json`) — unless a rectangle is set in Settings;
3. runs the kit's `cockpit.ps1 on` (config.xml backup, cockpit values, companion "skip window" flag);
4. starts the game through the kit's `cockpit-launch.ps1` (launcher started **detached** via WMI) and shows its
   result: hook **ACTIVE**, or "started without the hook" with the reason from the launcher/hook logs.

**Single monitor + dashboard** (game closed):
1. runs the kit's `cockpit.ps1 off` (previous config values back, flag removed; "already off" is fine);
2. starts `X4.exe` normally and **detached** (WMI `Win32_Process.Create`) with your game arguments;
3. the dashboard: if the companion watcher is running, it opens the dashboard (X4Switch only waits until it is
   there); otherwise X4Switch runs the companion's own `watch_x4.ps1 -Once`, which starts the server hidden and
   opens the window — the companion's checks prevent a second server or a second window. Without the companion the
   choice still works as "single monitor, no dashboard" and says so.

**Detached** means: the game, the launcher, the server and the browser window are created by the WMI service, not as
children of X4Switch — closing (or killing) X4Switch never closes the game.

## Relation to the two mods

X4Switch is the common piece; it contains no mode logic of its own. Everything mode-specific stays in the two
projects, called as hidden child processes through a small machine-readable contract (one `@@X4JSON {...}` line):

- **x4cockpit3** works on its own (`cockpit-on.cmd`, `cockpit-launch.cmd`, `cockpit-off.cmd`), with or without X4Switch.
- **X4 Companion** works on its own (its watcher in the Startup folder, `run.cmd`), with or without X4Switch.
- Either project may be missing: the window shows what is not available, and the other choice still works.

## Start

Double-click `X4Switch.exe` (in `<X4 game folder>\tools\x4switch\`). Pick a card, press **Start** (or Enter, or
double-click the card). The last choice is remembered.

Keyboard: **← / →** choose, **Enter** start, **Tab** move between buttons, **F5** refresh the status, **Esc** closes Settings.

The window shows:
- the two choices, each with a one-line description and a live status line ("Ready", "Not ready: monitor
  arrangement", "Running now", "The game is running – close it to switch", …);
- a status panel: game (running? started in which mode?), config mode (cockpit ON/OFF from the kit), monitor
  arrangement in plain words (e.g. `DELL P2714H | VG34VQL3A | DELL P2714H – OK`), dashboard (server up/down,
  watcher, window), hook files present/missing;
- secondary actions: *Switch mode without starting*, *Open dashboard window*, *Check monitors*, *Open logs folder*,
  *Settings*, *Refresh*; and a details box with everything the last action did (including the scripts' own output).

English is the default; Hungarian follows the Windows UI language or the Settings / the header button.

## Command line (scripts and tests)

```bat
X4Switch.exe --mode cockpit|single [--no-start] [--dry-run] [--json]
X4Switch.exe --status [--json]          :: read-only (also: --dry-run alone)
X4Switch.exe --open-dashboard [--dry-run]
X4Switch.exe --check-monitors
X4Switch.exe --selftest
:: common: --settings <file> --log-dir <dir> --lang en|hu --instance <mutex name>
```

`--no-start` = "switch mode without starting". `--dry-run` changes and starts nothing (the kit's `-WhatIf`, the
companion's `-DryRun`) and prints the exact commands. `--json` adds one `@@X4SWITCH {...}` result line.
Exit codes: 0 ok, 1 error, 2 refused (game running, arrangement, missing files, …), 3 started **without** the window
hook, 4 usage, 5 another X4Switch instance is busy.

## Settings

`settings.json` next to the exe (machine-local, gitignored; created when you pick a mode or save Settings).
All keys are optional — see `settings.example.json`. Defaults are relative to X4Switch's own folder:
the game is `..\..\X4.exe`, the kit `..\x4cockpit3`, the companion `..\x4companion`. Nothing user- or drive-specific
is compiled in. The Settings window edits: game path, game arguments (none unless you set them), cockpit rectangle
override, language, and "close the manager after starting the game".

## What it never does

No network (only a 127.0.0.1 port probe for the dashboard server), no registry writes, no autostart, no shortcuts,
no elevation (`asInvoker`), never kills or closes the game. Single instance (a second start brings the first window
forward; a second command-line change is refused with exit 5). Its own log: `logs\x4switch.log`, capped at 512 KB
(one previous file kept).

## Build

```bat
build.cmd            :: zig cc (x86_64-windows-gnu) -> X4Switch.exe next to it
```

Zig is the only tool (tested with 0.17.1). `build.ps1` finds `zig.exe` from `-Zig`, `X4SWITCH_ZIG`, `X4C3_ZIG`, a
`zig.path` file here or in `..\x4cockpit3\native\`, or PATH. Sources: `src\main.c` (entry, command line),
`src\core.c` (settings, child scripts, WMI start, status, the two modes), `src\gui.c` (window), `src\json.c`,
`src\i18n.c` (EN/HU text table), `src\x4switch.rc` + manifest (PerMonitorV2 DPI, asInvoker).

## Tests

`tests\run-tests.cmd [-WorkDir <dir>] [-Port 8797]` (about a minute) drives `X4Switch.exe` through its command line
against fakes only: the kit's `testtarget.exe` as a fake `X4.exe` (fully transparent, click-through, exits by
itself), copies of the kit and companion scripts in a temporary game tree, a synthetic `config.xml`, synthetic monitor
layouts, a PowerShell stub server on a test port, a stub browser window (transparent, off-screen) and a test mutex
name. It covers both modes, switch without starting, dry runs, every refusal (game running, arrangement, missing hook
file, invalid rectangle, missing companion), the fail-safe result, the watcher-running path (exactly one window),
detached starts surviving a killed manager (kill-on-close job), single instance, settings auto-detection, language
selection, remembering the last choice, log rotation, and a GUI smoke test (window created hidden and never shown,
every control text dumped in both languages, an off-screen render of the window). `X4Switch.exe --selftest` runs the
internal checks (JSON, quoting, rectangle parsing, the EN/HU token table, path defaults).

## Limits

- The dashboard window is detected by its title (`windowTitle` from the companion's `watcher.json`).
- "Started in which mode" comes from the kit's launcher log (`pid=… hook=ACTIVE`), or from the hook DLL being
  loaded in the game process.
- The status panel refreshes the cheap checks every 4 s; the kit checks (config, monitors) run at start, after every
  action and on F5 / Refresh.
- If X4 is restarted by a store client, that new process is not hooked (a limit of the kit, see its README).

## Disclaimer

This is an unofficial fan project. It is not affiliated with, endorsed, or supported by Egosoft.
It is provided "as is", without warranty of any kind; you use it at your own risk.
X4: Foundations and Egosoft are trademarks or registered trademarks of Egosoft GmbH; all other trademarks are the
property of their respective owners. This project contains no Egosoft game data.
