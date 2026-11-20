# x4cockpit3 — X4: Foundations cockpit across three monitors

A small Windows PowerShell kit that lets **X4: Foundations 9.00** draw one wide cockpit view across
**side monitor | centre monitor | side monitor** (reference setup: Dell 27" 1080p | ASUS 34" 3440×1440 ultrawide | Dell 27" 1080p).

It is the *simple wide window* approach: one game window, one flat projection, a narrower FOV.
No driver tricks, no NVIDIA Surround, no injected code, no game files modified.

> **Status:** the tools are tested (69 automated tests, see below) but the **in-game behaviour is not verified
> yet**. Whether X4 accepts and keeps a 7280-pixel-wide window is exactly what step 2–3 of the test protocol
> (`TESZT.md`, Hungarian) decides.

## What is in the box

| File | Purpose |
|---|---|
| `x4cockpit3.ps1` / `.cmd` | Arrangement check + stretching the running game window (`triple`, `uw-left-only`, `single`, `custom`), `-Restore` |
| `cockpit.ps1`, `cockpit-on.cmd`, `cockpit-off.cmd` | Switch the game's `config.xml` into cockpit mode and back (game must be closed) |
| `settings.example.json` | All settings with explanations; copy to `settings.json` |
| `lib\` | Shared code (settings, monitor/EDID reading, layout maths, text-preserving XML edit, Win32 window calls) |
| `tests\run-tests.ps1` / `.cmd` | Automated tests (never touch the real game, its window, config or companion) |
| `TESZT.md` | Step-by-step in-game test protocol (Hungarian) |

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built in). No admin rights.
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
- The window must be stretched after every game start (`x4cockpit3.cmd triple`). The game is not modified.
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
  that without `-Handle` only the configured exe can be picked.

## Licence

Not chosen yet — see `LICENSE-TODO.md`.

## Disclaimer

This is an unofficial fan project. It is not affiliated with, endorsed, or supported by Egosoft.
It is provided "as is", without warranty of any kind; you use it at your own risk, and the authors accept no
liability for any damage, data loss or lost saves arising from its use.
X4: Foundations and Egosoft are trademarks or registered trademarks of Egosoft GmbH; all other trademarks are
the property of their respective owners.
This project contains no Egosoft game data.
