# X4Switch – rövid használati útmutató

**Mire jó:** egy ablakból választod ki, hogyan induljon az X4:
- **Pilótafülke – három monitor**: egy keret nélküli játékablak a bal Dell | ultrawide | jobb Dell monitoron.
- **Egy monitor + műszerfal**: a szokásos játék a fő monitoron, mellette böngészőablakban az X4 Companion térkép.

Szkriptet nem kell kézzel futtatnod.

## Indítás

1. **Zárd be a játékot**, ha fut (a kezelő soha nem zárja be helyetted – ilyenkor csak szól).
2. Dupla katt: `D:\X4 Foundations Envoy Pack\tools\x4switch\X4Switch.exe`.
3. Kattints a kívánt kártyára, majd **Indítás** (vagy Enter, vagy dupla katt a kártyán).

Billentyűk: **← / →** választás, **Enter** indítás, **Tab** a gombok között, **F5** állapot frissítése.

A nyelv angol, ha a Windows angol; a jobb felső **Magyar** gombbal (vagy a Beállításokban) magyarra válthatsz – megjegyzi.

## Mit csinál a két mód

**Pilótafülke:** megnézi, jó-e a monitor-elrendezés, beírja a pilótafülke-értékeket a `config.xml`-be (előtte mentést
készít), elindítja a játékot az ablak-hookkal, és kiírja: **AKTÍV** a hook, vagy ha nem, miért nem.

**Egy monitor + műszerfal:** visszaállítja a normál `config.xml`-értékeket, elindítja a játékot normálisan, és
gondoskodik a műszerfalról: ha fut a Companion figyelő, ő nyitja meg; ha nem, a kezelő indítja el a szervert és
nyitja meg az ablakot – soha nem kettőt.

A játék a kezelőtől függetlenül indul: ha a kezelőt bezárod, a játék tovább fut.

## Többi gomb

- **Mód váltása indítás nélkül** – csak átállítja a `config.xml`-t a kiválasztott módra.
- **Műszerfal ablak megnyitása** – elindítja a szervert, ha kell, és megnyitja a térképablakot, ha nincs nyitva.
- **Monitorok ellenőrzése** – kiírja, mit lát a gép (pl. `DELL P2714H | VG34VQL3A | DELL P2714H – rendben`).
- **Naplómappa megnyitása** – a kezelő naplója (`logs\x4switch.log`).
- **Beállítások** – játék útvonala, indítási paraméterek (pl. `-debug all -logfile debug.log`), pilótafülke-téglalap
  felülbírálása (üresen hagyva az élő elrendezésből számol), nyelv, bezárás indítás után.

Lent a **Részletek** dobozban látod, mit csinált lépésről lépésre.

## Ha valami nem stimmel

- „A játék fut – zárd be a váltáshoz”: előbb lépj ki az X4-ből.
- „Nem indítható: monitor-elrendezés”: a Windows kijelzőbeállításaiban a két Dell a középső monitor bal és jobb oldalán
  legyen; a **Monitorok ellenőrzése** megmondja, mit kell elmozdítani.
- „Az X4 elindult, de ablak-hook NÉLKÜL”: a játék normál ablakban fut; az ok a Részletekben és a
  `tools\x4cockpit3\native\out\` naplókban van.
