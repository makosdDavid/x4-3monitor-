# Hárommonitoros pilótafülke — élő teszt a natív ablak-hookkal

> A régi út (az ablak kívülről nyújtása, `x4cockpit3.cmd triple`) 9.00 alatt nem működik (2026-11-22). Ez a
> protokoll az új utat teszteli: a `cockpit-launch` maga indítja a játékot, és egy DLL-lel a játékon belül
> irányítja át az ablakhívásokat. Ha bármi gond van: zárd be a játékot (Alt+F4), és indítsd a megszokott módon —
> úgy semmi sem töltődik be belőle.

Minden parancsot ebben a mappában futtass (PowerShell: `cd "<X4 mappa>\tools\x4cockpit3"`, a parancsok elé `.\`).
Minden lépés végén egy kérdésre válaszolj.

1. **Előkészítés (a játék BEZÁRVA).** Ha nyitva van a Companion-ablak, zárd be. Ha a cockpit mód még nincs bekapcsolva:
   `cockpit-on.cmd`. Utána: `cockpit-launch.cmd -WhatIf -GameArgs "-debug all -logfile debug.log"`
   **Kérdés:** a végén ott van-e `rect   : (-1920,0) 7280x1440`, `mode   : cockpit ON` és `WhatIf: nothing started`?
   (Ha „REFUSED” áll ott, a „!” sorok megmondják, mit kell a Windows kijelzőbeállításaiban áthelyezni.)

2. **Csak a főmenüig.** `cockpit-launch.cmd -GameArgs "-debug all -logfile debug.log"` — várd meg a főmenüt,
   **ne tölts be mentést**, majd lépj ki a játékból.
   **Átment, ha mindkettő igaz:**
   - `native\out\x4c3hook.log`-ban van egy sor: `window created as borderless popup at the rectangle: ...
     window=(-1920,0) 7280x1440 client=7280x1440`;
   - a játék `debug.log`-jában (a profilmappában, a `config.xml` mellett) a `Resolution:` szó után (szóközökkel kitöltve) `7280 x 1440` áll (eddig: `3424 x 1353`). Gyors keresés: `Select-String -Path <profilmappa>\debug.log -Pattern "Resolution:"`
   **Kérdés:** a főmenü mindhárom monitoron egy képként jelent-e meg, és igaz-e a fenti két napló-feltétel?
   Ha nem: küldd el a két naplót (`x4c3hook.log`, `debug.log`) és a `native\out\launcher.log`-ot.

3. **Menük, HUD, térkép.** Indítsd újra ugyanígy, töltsd be a mentést. Nyisd meg: térkép (M), enciklopédia, egy
   kereskedelmi menü; jelölj ki egy célpontot; nézd meg a külső nézetet.
   **Kérdés:** a menük az ultrawide-on maradnak-e, látszik-e a térkép tartalma, és hol van kényelmetlen a HUD?

4. **Egér és ablak.** Repülj egérrel, vidd a kurzort mindkét Dellre, kattints ott is. Alt+Tab ki, majd vissza.
   **Kérdés:** a kurzor eléri-e a Delleket, működik-e ott a kattintás, és Alt+Tab után ugyanott van-e a kép?

5. **FPS.** Jegyezd fel az FPS-t egy üres szektorban és egy állomásnál (DLSS: Performance).
   **Kérdés:** mennyi az FPS, és akad-e a kép a Delleken?

6. **Visszaállítás.** Lépj ki a játékból, majd `cockpit-off.cmd`, végül
   `powershell -ExecutionPolicy Bypass -File cockpit.ps1 status`
   **Kérdés:** „mode   : OFF” áll-e, és a következő, megszokott indításkor a játék a régi módon (Borderless, 120°)
   indul-e, a Companion-ablakkal együtt?
