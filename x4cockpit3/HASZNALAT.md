# Három monitor – rövid használati útmutató

Állapot: 2026-11-23. Elrendezés: bal Dell | ultrawide | jobb Dell. Az ultrawide a laptop HDMI-jén, a két Dell
a dokkolón van. Minden itt felsorolt fájl a `D:\X4 Foundations Envoy Pack\tools\x4cockpit3\` mappában található,
kivéve ahol más van írva.

## 1. Asztali ikonok – ezekre kell a legtöbbször

| Ikon | Mit csinál | Mikor |
|---|---|---|
| **Laptop kijelzo KI - 3 monitor** | Lekapcsolja a laptop saját kijelzőjét, a három külső monitort a legjobb elérhető felbontásra és a helyes sorrendbe teszi. | Gépindítás után, vagy ha szétesett az elrendezés / rossz a felbontás. |
| **Laptop kijelzo BE** | Visszakapcsolja a laptop kijelzőjét a három külső mellé. | Ha a laptop kijelzője is kell. |
| **Dokkolo ujradugasa szoftverbol** | Újraindítja a laptop USB-C portját, a dokkolót, végül a videokártyát – amíg a monitorok újra képet nem adnak. Admin jogot kér. | Ha egy dokkolós monitor sötét marad (pl. alvás után). Ha minden monitor ad képet, nem csinál semmit. |

Az első kettő a végén megkérdezi: „Jó a kép mindegyik monitoron?” – **Megtartom** vagy **Vissza az előzőre**.
Ha 20 másodpercig nem válaszolsz, magától visszaáll. Egyszerre csak egy példány fut, dupla kattintás nem árt.

## 2. Játékindító

`D:\X4 Foundations Envoy Pack\tools\x4switch\X4Switch.exe` – ablak, amiben kiválasztod: **pilótafülke három
monitoron** vagy **egy monitor + műszerfal**. Leírása: `tools\x4switch\HASZNALAT.md`.
Valódi játékkal még nem próbáltuk ki.

## 3. Amit eddig átállítottunk a gépen – és hogyan vonható vissza

| Mit | Mikor | Visszavonás |
|---|---|---|
| NVIDIA DSC-tiltás kikapcsolva (`DISABLE_DSC` 1 → 0). Ettől kapott a két Dell újra 1920×1080-at. | 11-22 23:03 | `dsc-test.ps1 -Off`, majd újraindítás |
| Hálózati áramon nincs automatikus alvás (30 perc → soha). Az alvás utáni ébredés sötétítette el a Delleket. | 11-23 10:39 | `dock-replug.ps1 -RestoreSleep` |
| Monitorok felbontása és sorrendje | több alkalommal | `fix-displays.ps1 -Revert` |

**Fontos:** minden NVIDIA driver-telepítés visszaírja a DSC-tiltást. Ha driverfrissítés után a Dellek megint csak
kis felbontást kapnak: `dsc-test.ps1 -On`, újraindítás, aztán a „Laptop kijelzo KI” ikon.

## 4. Parancsok

Mindegyik így indul (PowerShell-ablakból, a fenti mappában):
`powershell -ExecutionPolicy Bypass -File <fájl> <kapcsoló>`

| Fájl és kapcsoló | Mit csinál | Változtat? |
|---|---|---|
| `fix-displays.ps1 -NoLaptop` | Ugyanaz, mint a „KI” ikon. | igen |
| `fix-displays.ps1` | Ugyanaz, mint a „BE” ikon. | igen |
| `fix-displays.ps1 -WhatIf` | Megmutatja, mit állítana be és mit fogad el a driver. | nem |
| `fix-displays.ps1 -Revert` | Vissza az utolsó beállítás előtti állapotra. | igen |
| `fix-displays.ps1 -Swap` | Felcseréli a bal és a jobb Dellt. | igen |
| `fix-displays.ps1 -SideMode 1280x720` | A két Dell legfeljebb ekkora felbontást kap (ha a dokkoló nem bír többet). | igen |
| `dsc-test.ps1` | Kiírja a DSC-kapcsoló állását. | nem |
| `dsc-test.ps1 -On` / `-Off` | DSC engedélyezése / gyári tiltás vissza. Admin jog + újraindítás kell, előtte mentést készít. | igen |
| `dock-replug.ps1` | Ugyanaz, mint a „Dokkolo ujradugasa” ikon. | igen |
| `dock-replug.ps1 -WhatIf` | Megmutatja, melyik monitor ad képet, és mit indítana újra. | nem |
| `dock-replug.ps1 -NoAutoSleep` / `-RestoreSleep` | Automatikus alvás hálózatról: soha / vissza az előzőre. | igen |
| `diag\watch-displays.ps1` | Háttérben naplóz minden monitor- és USB-változást, és azt is, ha egy monitor sötét. | nem |
| `diag\watch-displays.ps1 -Stop` | Leállítja a naplózót. | nem |
| `diag\linkstate.ps1` | Pillanatkép: melyik monitor min lóg, milyen jelet kap. | nem |
| `cockpit-on.cmd` / `cockpit-off.cmd` | A játék beállításait pilótafülke módra / vissza normálra írja (mentéssel). Az X4Switch ezt magától intézi. | a játék `config.xml`-jét |
| `cockpit-launch.cmd` | A játékot a háromképernyős ablakkal indítja. Az X4Switch ezt magától intézi. | nem |

A `x4cockpit3.cmd` és a `probe-dell.ps1` régi kísérlet, nem kell hozzájuk nyúlni.

## 5. Ha baj van

- **A két Dell kis felbontáson van** → „Laptop kijelzo KI - 3 monitor” ikon. Ha így is kicsi marad:
  `dsc-test.ps1` (ha 1-et ír ki: `dsc-test.ps1 -On` + újraindítás).
- **Egy vagy két Dell sötét, pedig a Windows látja** → „Dokkolo ujradugasa szoftverbol” ikon.
  Ha az sem segít: a dokkoló USB-C csatlakozóját kihúzni és visszadugni.
- **Rossz sorrend (bal-jobb felcserélve)** → `fix-displays.ps1 -NoLaptop -Swap`.
- **A laptop kijelzője nem jön vissza** → „Laptop kijelzo BE” ikon.

## 6. Naplók

Mind a `state\` mappában:
`fix-displays.log` (mit állított be), `dock-replug.log` (melyik lépés hozta vissza a képet),
`watch-displays.log` (folyamatos napló), `dsc-test.log` és `nvidia-0000-*.reg` (a DSC-kapcsoló mentése).

## 7. Amit még nem tudunk

- A „Dokkolo ujradugasa” ikon a valódi hibán még nem futott, csak szárazon.
- A „Laptop kijelzo BE” új változata élesben még nem futott (a driver próbája elfogadta).
- Nem tudjuk, hogy a kézi hibernálás utáni ébredés is elsötétíti-e a Delleket; a napló meg fogja mutatni.
- A naplózó újraindítás után nem indul el magától.
