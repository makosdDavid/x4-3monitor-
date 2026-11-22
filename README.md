# x4cockpit3 — X4: Foundations cockpit across three monitors

A small Windows PowerShell kit that lets **X4: Foundations 9.00** draw one wide cockpit view across
**side monitor | centre monitor | side monitor** (reference setup: Dell 27" 1080p | ASUS 34" 3440×1440 ultrawide | Dell 27" 1080p).

It is the *simple wide window* approach: one game window, one flat projection, a narrower FOV.
No driver tricks, no NVIDIA Surround, no game files modified.

> **Status:** stretching the window from outside does NOT work with X4 9.00 (live test 2026-11-22, see "Live test
> result"). The **native window hook** (`cockpit-launch`, see below) is the route for 9.00: it loads a small DLL
> into the game process so the game itself opens and keeps the wide window. Built and tested against an imitation
> of X4's window behaviour; **not yet tested with the real game.**

## Native window hook (`cockpit-launch`)

**What it does, plainly:** `native\out\launcher.exe` starts `X4.exe` itself, loads our DLL `x4c3hook.dll` into the
game process before the game's own code runs, and that DLL redirects a few of the game's Windows window/monitor
calls. The game then creates ONE borderless window at the rectangle computed by the kit (7280×1440 at x=−1920,
y=0 for the reference setup), keeps it there, and is told that this rectangle is its monitor and its work area.
Nothing is written into `X4.exe` or any game file; when the game exits, nothing of it remains.

**How (for reviewers):**
- Injection: `CreateProcessW(CREATE_SUSPENDED)` → `VirtualAllocEx`/`WriteProcessMemory` (the DLL path) →
  `CreateRemoteThread(LoadLibraryW)`, wait → `ResumeThread`. The game's entry point runs only after the hooks exist.
- Hooking: the DLL rewrites entries of **X4.exe's own import address table** (IAT) for user32 functions — no code
  patching, no inline hooks, no third-party hook library. X4.exe 9.00 imports (read with `native\peimports.py`):
  `CreateWindowExW, RegisterClassExW, SetWindowPos, SetWindowLongPtrW, ShowWindow, AdjustWindowRect,
  GetMonitorInfoW, MonitorFromWindow, MonitorFromRect, GetSystemMetrics, SystemParametersInfoW/A,
  EnumDisplaySettingsW/ExW, ChangeDisplaySettingsW/ExW` (plus `EnumDisplayDevicesW, GetClientRect, ClientToScreen,
  ScreenToClient, ClipCursor, Get/SetCursorPos`, which need no change). It does **not** import `MoveWindow`,
  `SetWindowPlacement`, `DeferWindowPos`, `SetWindowLongW`, `AdjustWindowRectEx`, `MonitorFromPoint`,
  `EnumDisplayMonitors` or any DPI function, and their names do not occur anywhere in the exe (so they are not
  fetched with `GetProcAddress` either). Its manifest declares `dpiAware True/PM`: all coordinates are physical pixels.

| Hook | Effect |
|---|---|
| `CreateWindowExW` | top-level window with class or title `X4`: created as a borderless popup at the rectangle |
| `RegisterClassExW` | class `X4`: the game's window procedure is wrapped; after it ran, `WM_WINDOWPOSCHANGING` is pointed at the rectangle (not when minimising) and `WM_GETMINMAXINFO` allows the size |
| `SetWindowPos` | the game's own calls for its window are rewritten to the rectangle |
| `SetWindowLongPtrW` | style changes for its window stay borderless (`WS_CAPTION`/`WS_THICKFRAME`/maximise removed) |
| `ShowWindow` | maximise becomes "show normal", then the rectangle is re-applied |
| `AdjustWindowRect` | returns the rectangle unchanged (borderless: window = client) |
| `GetMonitorInfoW` | for the "anchor" monitor (the real monitor under the rectangle's centre): `rcMonitor` = `rcWork` = the rectangle |
| `MonitorFromWindow` / `MonitorFromRect` | the game window, or a rectangle containing the anchor's centre → the anchor monitor |
| `GetSystemMetrics` | screen size = rectangle size; virtual-screen metrics = union of the real desktop and the rectangle |
| `SystemParametersInfoW/A` | `SPI_GETWORKAREA` = the rectangle |
| `EnumDisplaySettingsW/ExW` | the anchor's *current/registry* mode reports the rectangle's size and position (the mode list stays real) |
| `ChangeDisplaySettingsW/ExW` | blocked: never forwarded, so the game cannot change a real display mode |

- A **watchdog** thread (500 ms) puts the window back if something outside the game moves it or adds a frame.
- What IAT patching cannot see, and why it does not matter here: calls made by other DLLs (Vulkan loader and
  driver, Steam, Tobii) see the real window — which really is 7280×1440, so the swapchain gets the right size;
  moves from outside the process are handled by the watchdog.
- **Configuration** is handed over in environment variables of the game process only (set by the launcher right
  before it starts the game, read once by the DLL, then deleted). No config file, nothing that outlives the game.
- **Fail-safe:** invalid rectangle, missing DLL, failed injection, a failure while patching (every slot written so far
  is put back) or "not the intended process" → the game simply starts as it would without us; the reason is logged.
  The launcher refuses (starts nothing) for anything that is not an absolute path to an existing `X4.exe`, and while
  that exe already runs.
- The DLL writes only `x4c3hook.log` (launcher: `launcher.log`), both in `native\out\`, each capped at 1 MiB. No
  network, no registry, no autostart, no elevation (`asInvoker` manifest), no Defender exclusions.

**Display mode:** stay in **Windowed** (the existing cockpit values: `fullscreen=false`, `borderless=false`,
`res_width=7280`, `res_height=1440`). Only Windowed uses `res_width`/`res_height` (Borderless disables the option and
ignores it, `gameoptions.lua` 7955–7957), and Windowed renders at the client size (measured: 3424×1353 when clamped).
With the hook the client *is* 7280×1440 and the game sees a 7280×1440 work area, so nothing clamps any more. The
borderless look comes from the hook, not from the game's Borderless mode. `cockpit.ps1`'s values therefore stay as
they are; only its closing hint now points to `cockpit-launch`.

**Build** (Zig is the only tool; outputs go to `native\out\`, gitignored):

```bat
native\build.cmd                       :: zig.exe from -Zig <path>, %X4C3_ZIG%, native\zig.path or PATH
```

**Use** (game closed):

```bat
cockpit-on.cmd                                         :: once: cockpit values into config.xml (backup first)
cockpit-launch.cmd -WhatIf                             :: checks + the exact command, starts nothing
cockpit-launch.cmd -GameArgs "-debug all -logfile debug.log"
cockpit-launch.cmd -Rect "-1920,0,7280,1440" -GameArgs "..."   :: explicit rectangle, skips the arrangement check
```

`cockpit-launch` reads the live monitor topology with the kit's layout code (`triple`), refuses a mismatching
arrangement (`-Force` or `-Rect` override), checks that cockpit mode is ON (it never edits `config.xml`), refuses
while the game runs, and starts the launcher **detached** through WMI (`Win32_Process.Create`), so closing the shell
does not close the game. It then prints the launcher's result line (`hook=ACTIVE` or the fail-safe reason).

**Turn it off:** start the game the normal way (without `cockpit-launch`) — there is nothing to uninstall. For the
usual config values: close the game, `cockpit-off.cmd`. To remove the native part completely, delete `native\out\`.

**Risks and limits:**
- A game update can change how X4 creates or enforces its window; then the hook may stop working (the log shows
  what the game called) or, at worst, the game may crash at start. Start it normally to play.
- Loading a DLL into another process is a technique malware also uses: anti-virus heuristics may react (an on-demand
  Defender scan of the three binaries found nothing on 2026-11-22; behaviour monitoring at run time is a separate
  matter). Never add exclusions for it.
- HUD and menus stretch over the full width (`menuwidthscale` keeps menus on the centre monitor); the four 1920×180
  corners above/below the Dells are rendered but invisible; the map may be awkward.
- If X4 restarts itself through a store client, the new process is not hooked (the launcher logs an early exit).
- X4 has no anti-cheat; do not use this technique with games that do.

**Credit:** window-redirection idea learned from hubertdungen/x4-triple-screen (MIT); this is an independent
implementation (own launcher, IAT patching instead of a hook library, own tests). Its source was read, not used.

## Live test result (2026-11-22)

- Config: Windowed, `res_width` 7280, `res_height` 1440. X4 created a framed window of exactly the primary
  monitor's **work area** (0,0 3440×1392; client 3424×1353) and rendered at that size (`debug.log`:
  "Resolution: 3424 x 1353"). `res_width` larger than the screen is silently reduced to the work area.
- `SetWindowPos` (also with `SWP_NOSENDCHANGING`), and a style change by `SetWindowLongPtr`, all returned
  success but changed nothing, immediately or 1.5 s later. Dragging the window by hand onto the side monitor did
  not work either. X4 keeps its window inside the one screen chosen in Options → Display → Screen (`adapter` key).
- An independent project reports the same clamp ("instead of reverting to a single-display 2560x1392 window") and
  works around it only by hooking inside X4.exe (github.com/hubertdungen/x4-triple-screen).
- `diag\x4winprobe.ps1` logs, for each window call, whether the change never happened or happened and was put
  back (`-Experiments`), and what happens during a hand drag (`-Watch`, passive).

## What is in the box

| File | Purpose |
|---|---|
| `x4cockpit3.ps1` / `.cmd` | Arrangement check + stretching the running game window (`triple`, `uw-left-only`, `single`, `custom`), `-Restore` |
| `cockpit.ps1`, `cockpit-on.cmd`, `cockpit-off.cmd` | Switch the game's `config.xml` into cockpit mode and back (game must be closed) |
| `settings.example.json` | All settings with explanations; copy to `settings.json` |
| `lib\` | Shared code (settings, monitor/EDID reading, layout maths, text-preserving XML edit, Win32 window calls) |
| `diag\x4winprobe.ps1` | Window-behaviour probe: `-Experiments` (logged API matrix, puts the window back) / `-Watch` (passive event log) |
| `cockpit-launch.ps1` / `.cmd` | Start X4 with the native window hook (checks, then the launcher detached via WMI) |
| `native\launcher.c`, `hook.c`, `x4c3.h` | Launcher (`launcher.exe`) and hook DLL (`x4c3hook.dll`) sources, C, built with Zig |
| `native\testtarget.c` | `testtarget.exe`: imitates X4's window behaviour through the same imports (for tests) |
| `native\peimports.py` | Read-only PE import / manifest lister (how the hook set was chosen; re-run after a game update) |
| `native\build.ps1` / `.cmd` | Reproducible build into `native\out\` |
| `native\tests\run-native-tests.ps1` / `.cmd` | Native tests (launcher, DLL, cockpit-launch against `testtarget.exe`) |
| `tests\run-tests.ps1` / `.cmd` | Automated tests (never touch the real game, its window, config or companion) |
| `TESZT.md` | Step-by-step in-game test protocol (Hungarian) |

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built in). No admin rights.
- Native window hook only: Zig (tested with 0.17.1) to build `native\` — nothing else; Python 3 optional (import audit test).
- X4: Foundations 9.00 (Vulkan renderer). Steam or GOG.
- Three monitors, the outer two of the same size; the centre one is the Windows **primary** monitor
  (or set `centreMatch`). The side monitors must be arranged left and right of it in *Windows Settings → System →
  Display* — the tool checks this but never changes display settings.

## Install

1. Copy this folder anywhere. Inside `<X4 game folder>\tools\x4cockpit3\` the game exe is found automatically;
   elsewhere set `gameExe` in `settings.json`.
2. Copy `settings.example.json` to `settings.json` and set at least `backupDir` (where config backups go) and,
   recommended, `sideMatch` (EDID code or name of your side monitors, e.g. `DELD05F|P2714H`; `x4cockpit3.cmd`
   prints the codes).
3. Optional: run `tests\run-tests.cmd` (≈1 minute; it opens one invisible dummy window for a few seconds).

## Usage

```bat
x4cockpit3.cmd                      :: check: which monitor is where, what must move, coverage per monitor
x4cockpit3.cmd -Simulate target     :: the target arrangement on paper
x4cockpit3.cmd -Check -SeatMm 600   :: which fov matches your eye distance
cockpit-on.cmd -WhatIf              :: show the exact config.xml line diff
cockpit-on.cmd                      :: GAME CLOSED: backup + write cockpit values + companion flag
:: start X4, load a save, then:
x4cockpit3.cmd uw-left-only         :: first test, no rearranging needed
x4cockpit3.cmd triple               :: full cockpit (after arranging the monitors)
x4cockpit3.cmd -Restore             :: window back to how it was
cockpit-off.cmd                     :: GAME CLOSED: previous values back, flag removed
cockpit.ps1 status                  :: current mode / values / game / companion window
```

`cockpit-on` refuses while the configured `X4.exe` runs (X4 rewrites `config.xml` when it exits). It writes
exactly these keys and nothing else: `fullscreen`, `borderless`, `res_width`, `res_height`, `fov`,
`menuwidthscale`, `confinemouse`. The edit is textual: other lines, comments, line endings and BOM stay
byte-for-byte; `on` followed by `off` gives back a byte-identical file (tested). Every write is preceded by a
timestamped backup in `backupDir`; the tool never deletes backups.

`x4cockpit3` computes the window from the live monitor topology (centre = primary or `centreMatch`, sides by
EDID code/name), refuses to stretch over a mismatching arrangement unless `-Force`, makes the window borderless
and gives it exactly the requested client rectangle (adds `WS_POPUP` when the window is larger than the
virtual desktop). A vertical offset of a side monitor is not an error as long as its rows lie inside the window:
the tool then tells you how many millimetres to raise or lower that monitor instead.

## Recommended values for the reference setup

Dell P2714H: 598×336 mm, 0.3115 mm/px. ASUS VG34VQL3A: 797×334 mm, 0.2317 mm/px (EDID, read from the registry).
Window: 7280×1440 at x=−1920 (Dell at x=−1920 / y=180, ultrawide at 0/0, Dell at x=3440 / y=180).

| Key | Value | Why |
|---|---|---|
| `fullscreen` / `borderless` | `false` / `false` (Windowed) | Only Windowed uses `res_width`; the resolution option is disabled in Borderless (`gameoptions.lua` 7955–7957). |
| `res_width` × `res_height` | `7280` × `1440` | 1920 + 3440 + 1920; the swapchain then matches the stretched client area 1:1. |
| `fov` | `0.6667` (60°) | Lowest value of the in-game slider (60–120°, `gameoptions.lua` 7059–7072). At 60° the flat projection is undistorted from 51 cm; 120° would give the side monitors only 11.8° each at 25× edge stretch. |
| `menuwidthscale` | `0.47` | Menus are centred and `width × scale` wide (`widget_fullscreen.lua` 8675–8682): 0.47 × 7280 = 3422 px ≤ 3440, so menus stay on the centre monitor. |
| `confinemouse` | `true` | Keeps the cursor inside the game window. Needed in the `uw-left-only` test (a monitor lies outside the window); harmless in `triple`, where the window covers every monitor. |
| DLSS (set in game) | **Performance** | 10.48 MP = 2.12× today; Performance renders 2.62 MP internally vs 2.20 MP today at Quality. Quality would render 4.66 MP (≈ half the frame rate when GPU-bound). |

Coverage (Hor+ assumption, see below):

| fov | vertical | centre | each side | total | edge stretch | undistorted eye distance (centre / sides) |
|---|---|---|---|---|---|---|
| 0.6667 (60°) | 36.0° | 75.6° | 20.9° | 117.3° | 3.7× | 51 cm / 69 cm |
| 0.7222 (65°) | 39.4° | 81.1° | 20.5° | 122.2° | 4.3× | 47 cm / 63 cm |
| 0.8333 (75°) | 46.7° | 91.8° | 19.5° | 130.8° | 5.8× | 39 cm / 52 cm |
| 1.3333 (120°) | 88.5° | 133.5° | 11.8° | 157.0° | 25× | 17 cm / 23 cm |

**Placement for a geometrically continuous image:** the Dells show everything 1.344× larger than the ultrawide
(0.3115 / 0.2317 mm per pixel). Keep all three screens facing forward (parallel), centres at eye height, and put
the side monitors 1.344× farther away than the centre one, shifted outwards: at fov 60° the ultrawide 51 cm from
the eyes, each Dell 69 cm away with its centre 83 cm left/right of the eye axis. By similar triangles the picture
is then continuous from the eye point. Angling the side monitors inwards needs a per-monitor correction the
simple wide window cannot do. For a normal 60 cm eye distance the matching fov is 0.5845 (52.6°) — below the
slider minimum; whether the game keeps such a value from `config.xml` is **not verified** (optional test step).

**Frame rate:** 2.12× the pixels of the ultrawide alone; 13% of the window (the corners above/below the Dells)
is rendered but never visible. Side monitors refresh at 60 Hz, the ultrawide at 100 Hz — expect the periphery to
judder slightly (not verified).

## What the engine does — evidence and open points

Lua references are to the 9.00 `08.cat` UI files (`ui/addons/ego_gameoptions/gameoptions.lua`,
`ui/widget/lua/widget_fullscreen.lua`, `ui/core/lua/compass.lua`), MD5-checked against the installed catalogue.

| Assumption | Basis | Confidence |
|---|---|---|
| `fov`, `res_width`, `res_height`, `fullscreen`, `borderless`, `confinemouse` are config keys | present in the user's `config.xml` and as strings in `X4.exe` | verified |
| `menuwidthscale` is a `config.xml` key (absent = default 1.0) | string in `X4.exe` among other config keys (`colorblindmode`, `separateRadar`, `hudscale`, `orderqueue`) at 0x2a6a908; the UI sets it via `C.SetMenuWidthScale` (`gameoptions.lua` 8327), range 0.10–1.00 (6674) | ~85% — confirmed when the game keeps it after a restart |
| degrees = `fov` × 90, slider 60–120 | `gameoptions.lua` 7059–7072, 8704–8706 | verified (code) |
| values < 60° survive | the UI only clamps the slider's *display* (7062–7063); no evidence about the engine | open — in-game |
| Hor+ (vertical angle fixed, wider = more horizontal view), 16:9 base | HUD code compensates only below 4:3 (`compass.lua` 451–453, `widget_fullscreen.lua` 8696); 16:9 base from a search snippet only | ~70% — in-game (step 4) |
| a `res_width` larger than the primary monitor is accepted | the setter only rejects negative / >32-bit values (`X4.exe` string "SetResolutionOption(): Width exceeds exceeds 32-bit or is negative"); a 2021 forum report of spanning up to ~10 000 px without Surround | open — in-game (step 2–3) |
| the game adapts to the stretched client area | — | open — in-game (step 3) |
| a framed (Windowed) window is capped by Windows at virtual-desktop height + 20 px | measured on a dummy window: asking for a 7280×1440 client gives 7280×1421; after `x4cockpit3` removes the frame the client is exactly 7280×1440 | measured |
| menus/HUD stay on the centre monitor | `menuwidthscale` maths above; cockpit monitors anchored to the centre; the external-view info bar sits at 80% of the half width and will land on the side monitors | open — in-game (step 5) |

## Companion window integration

`cockpit-on` creates a flag file (`companionSkipFlag`, default `state\cockpit-active.flag`); `cockpit-off`
removes it. A companion launcher can skip opening its window while the flag exists. For the X4 Companion
watcher (`watch_x4.ps1`) the change is one line before `$win = Find-CompanionWindow` in `Invoke-GameStarted`:

```powershell
    $skip = [string](Get-Cfg 'skipWindowFlag' ''); if ($skip -and (Test-Path -LiteralPath $skip)) { Write-Log "game running, $srv, cockpit flag $skip present - not opening the window"; return }
```

plus `"skipWindowFlag": "<full path of the flag file>"` in its `watcher.json` (read at watcher start). The
server still starts; only the window is skipped. `cockpit-on` also reports (never closes) a companion window
that is already open.

## Limits

- One flat projection: correct only from one eye point, and only with forward-facing side monitors.
- The side monitors show the middle 1080 of the 1440 rows; the corners are rendered for nothing.
- External route: the window must be stretched after every game start (`x4cockpit3.cmd triple`) — refused by
  9.00. Hook route: `cockpit-launch` at every start. In both the game files are not modified.
- Map content was reported invisible on multi-monitor setups in older versions (4.10–5.10); not checked for 9.00.
- Distortion correction for angled side monitors (ReShade shader / Vulkan layer) is out of scope.

## Tests

`tests\run-tests.cmd [-WorkDir <dir>] [-SourceConfig <config.xml>] [-SkipWindow]`

- **A** layout logic on synthetic topologies: both side monitors left, target, swapped, top/bottom aligned,
  outside the window, 5 px offset, missing monitor, a non-matching monitor, a gap, simulated target, maths.
- **B** the config switcher on *copies* in a temp folder: `-WhatIf` changes nothing; on/off round trip is
  byte-identical; refuses while a fake `X4.exe` from the configured path runs; idempotent `on`; restore after the
  game changed values; BOM/LF/tabs/self-closing elements; duplicate keys refused; profile auto-detection;
  settings validation.
- **C** the real window code on an invisible, non-activating dummy window: exact client rectangles for
  `uw-left-only`, `single` and an over-sized `custom`, `-Restore`, refusal over a mismatching arrangement, and
  that without `-Handle` only the configured exe can be picked. (A few C assertions depend on the live monitor
  arrangement, so the total can differ by one or two between arrangements; failures cannot.)

`native\tests\run-native-tests.cmd [-WorkDir <dir>] [-SkipBuild] [-Visible]` (≈2 minutes; all windows invisible
and click-through unless `-Visible`, every started process stopped by PID; never starts `X4.exe`):

- **N** build; import audit (no network/registry/shell DLLs; the target imports what X4 imports, same DPI
  manifest); the target **without** the hook reproduces the clamp (framed window = work area, external
  `SetWindowPos` refused); **with** the hook at 640×360 and at the real −1920,0 7280×1440: borderless, window =
  client = rectangle, what the target sees from `GetMonitorInfoW`/`GetSystemMetrics`/`SPI_GETWORKAREA`/
  `AdjustWindowRect`/`EnumDisplaySettingsW`, `ChangeDisplaySettingsExW` blocked, rectangle kept after external
  `SetWindowPos` and style changes and after the target's own re-apply timer; the watchdog alone; an `X4.exe`-named
  copy with game arguments passed through verbatim.
- **F** missing DLL, wrong exe name, relative/missing exe, four invalid rectangles, invalid rectangle reaching the
  DLL, simulated hook-install failure (rollback verified from inside the target), simulated injection failure, DLL
  in the wrong process, unknown/test-only options, exe already running.
- **L** both logs capped; a log over half its cap starts over next session.
- **C** `cockpit-launch`: cockpit mode off → refused; target/mismatching arrangement (+`-Force`); `-Rect`; config
  resolution warning; game already running; a real detached start through WMI (parent of the launcher is
  `WmiPrvSE.exe`).

## Licence

Not chosen yet — see `LICENSE-TODO.md`.

## Disclaimer

This is an unofficial fan project. It is not affiliated with, endorsed, or supported by Egosoft.
It is provided "as is", without warranty of any kind; you use it at your own risk, and the authors accept no
liability for any damage, data loss or lost saves arising from its use.
X4: Foundations and Egosoft are trademarks or registered trademarks of Egosoft GmbH; all other trademarks are
the property of their respective owners.
This project contains no Egosoft game data.
