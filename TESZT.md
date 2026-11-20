# Hárommonitoros pilótafülke — játékbeli teszt

Minden parancsot ebben a mappában futtass (PowerShell: `cd "D:\X4 Foundations Envoy Pack\tools\x4cockpit3"`,
a parancsok elé `.\`). Minden lépésnél egy kérdésre válaszolj. Ha egy lépés elbukik, ugorj a 12. lépésre.

1. **Előkészítés (a játék BEZÁRVA).** Mentés, kilépés. Ha nyitva van a Companion-ablak, zárd be.
   `cockpit-on.cmd -WhatIf`, majd `cockpit-on.cmd`
   **Kérdés:** a végén ott van-e: „Cockpit mode is ON”, és kiírt-e egy `backup :` sort?

2. **Indítás, átrendezés nélkül.** Indítsd a játékot, töltsd be a mentést. A játék keretes ablakban indul.
   **Kérdés:** elindult-e a játék és betöltődött-e a mentés, vagy összeomlott / hibát írt?

3. **Elfogadja-e a 7280 px széles ablakot?** Alt+Tab ide (a laptop-panelre), majd: `x4cockpit3.cmd uw-left-only`
   A kép a bal Dellre és az ultrawide-ra kerül; a jobb oldali 1920 px képen kívül van (ez itt rendben van).
   **Kérdés:** a Dell és az ultrawide egy összefüggő, éles képet mutat-e, a célkereszt az ultrawide közepén van-e
   (és nem nyúlt/elmosódott/fekete a kép, nem ugrott vissza az ablak)?

4. **Hor+ próba.** `x4cockpit3.cmd single`, nézd meg a középen lévő tárgyakat, majd `x4cockpit3.cmd uw-left-only`.
   **Kérdés:** a középen lévő tárgyak ugyanakkorák-e az ultrawide-on a két állapotban?

5. **Menük és HUD.** Nyisd meg: térkép (M), enciklopédia, egy kereskedelmi menü, célpont kijelölése, külső nézet.
   Jegyezd fel az FPS-t (bal felső sarok) itt és a 4. lépés `single` állapotában.
   **Kérdés:** minden menü az ultrawide-on belül marad-e, látszik-e a térkép tartalma, és mennyi a két FPS?

6. *(Opcionális)* **60° alatti FOV.** Lépj ki. A `settings.json`-ban írd át: `"fov": "0.6111"` (55°), futtasd
   `cockpit-on.cmd`, indítsd a játékot, lépj ki újra, majd: `powershell -ExecutionPolicy Bypass -File cockpit.ps1 status`
   **Kérdés:** a `fov` sor „now 0.6111”-et mutat-e (megtartotta a játék), és szűkebb volt-e a kép, mint 60°-nál?

7. **Átrendezés (te csinálod).** Kösd be a második Dellt (most a Windows csak egy Dellt lát, a harmadik kijelző
   a laptop saját panelje). Gépház → Rendszer → Kijelző: az egyik Dell az ultrawide BAL, a másik a JOBB oldalára,
   mindkettő függőlegesen középre. Utána: `x4cockpit3.cmd`
   **Kérdés:** a `triple` alatt „ARRANGEMENT: OK” áll-e? (Ha nem, a „!” sorok pontosan megmondják, mit hova tegyél.)

8. **A teljes pilótafülke.** Játék indítása, mentés betöltése, majd `x4cockpit3.cmd triple`
   **Kérdés:** mindhárom monitoron egy összefüggő kép van-e, a célkereszt az ultrawide közepén?

9. **Elhelyezés.** Ultrawide kb. 51 cm-re a szemedtől, a Dellek kb. 69 cm-re, előre nézve (nem befelé fordítva),
   a középpontjuk szemmagasságban, kifelé tolva (a középpontjuk kb. 83 cm-re a szemed vonalától).
   **Kérdés:** a Dell–ultrawide határon a vonalak (állomásélek, horizont) törés nélkül folytatódnak-e?

10. **FPS és DLSS.** Beállítások → Grafika: DLSS Quality, majd Performance; üres szektor, állomás, csata.
    **Kérdés:** mennyi az FPS a két beállítással, és akad-e a kép a Delleken?

11. **Egér.** Repülj egérrel, kattints menükben, vidd a kurzort a Dellekre.
    **Kérdés:** a kurzor az ablakban marad-e, és működik-e a kattintás a Delleken is?

12. **Visszaállítás.** Lépj ki a játékból, majd `cockpit-off.cmd`, végül
    `powershell -ExecutionPolicy Bypass -File cockpit.ps1 status`
    **Kérdés:** „mode : OFF” áll-e, és a következő játékindításkor a megszokott módon (Borderless, 120°) indul-e,
    a Companion-ablakkal együtt? Küldd el, melyik lépés bukott el, a `debug.log`-gal (`/x4-debug`).
