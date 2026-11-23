/* X4Switch - UI texts. English is the default; Hungarian is picked from the setting or the Windows UI language.
 * Every token must exist in both tables with the same printf conversions (checked by --selftest). */
#include "x4switch.h"
#include <wchar.h>

typedef struct { const wchar_t *en, *hu; } Tok;

static const Tok T[S_COUNT] = {
    [S_APP_TITLE] = { L"X4 Launch Manager", L"X4 indítókezelő" },
    [S_SUBTITLE] = { L"Choose how X4: Foundations starts.", L"Válaszd ki, hogyan induljon az X4: Foundations." },
    [S_LANG_TOGGLE] = { L"Magyar", L"English" },
    [S_COCKPIT_TITLE] = { L"Cockpit – three monitors", L"Pilótafülke – három monitor" },
    [S_COCKPIT_DESC] = { L"One borderless game window across the side | centre | side monitors.",
                         L"Egyetlen keret nélküli játékablak a bal | középső | jobb monitoron." },
    [S_SINGLE_TITLE] = { L"Single monitor + dashboard", L"Egy monitor + műszerfal" },
    [S_SINGLE_DESC] = { L"The normal game on the main monitor, the X4 Companion map in a browser window.",
                        L"A szokásos játék a fő monitoron, az X4 Companion térkép böngészőablakban." },
    [S_START_FMT] = { L"Start:  %ls", L"Indítás:  %ls" },
    [S_WORKING] = { L"Working…", L"Folyamatban…" },
    [S_SWITCH_ONLY] = { L"Switch mode without starting", L"Mód váltása indítás nélkül" },
    [S_OPEN_DASH] = { L"Open dashboard window", L"Műszerfal ablak megnyitása" },
    [S_CHECK_MON] = { L"Check monitors", L"Monitorok ellenőrzése" },
    [S_OPEN_LOGS] = { L"Open logs folder", L"Naplómappa megnyitása" },
    [S_SETTINGS] = { L"Settings", L"Beállítások" },
    [S_REFRESH] = { L"Refresh", L"Frissítés" },
    [S_STATUS] = { L"Status", L"Állapot" },
    [S_ST_GAME] = { L"Game", L"Játék" },
    [S_ST_CONFIG] = { L"Config mode", L"Konfig mód" },
    [S_ST_MONITORS] = { L"Monitors", L"Monitorok" },
    [S_ST_DASH] = { L"Dashboard", L"Műszerfal" },
    [S_ST_HOOK] = { L"Hook files", L"Hook fájlok" },
    [S_DETAILS] = { L"Details", L"Részletek" },
    [S_HINT] = { L"Enter: start   ·   ← / →: choose   ·   F5: refresh", L"Enter: indítás   ·   ← / →: választás   ·   F5: frissítés" },
    [S_CHECKING] = { L"checking…", L"ellenőrzés…" },
    [S_GAME_NOT_RUNNING] = { L"not running", L"nem fut" },
    [S_GAME_RUNNING_COCKPIT] = { L"running (pid %lu) – cockpit mode, window hook ACTIVE", L"fut (pid %lu) – pilótafülke mód, ablak-hook AKTÍV" },
    [S_GAME_RUNNING_COCKPIT_NOHOOK] = { L"running (pid %lu) – started by the cockpit launcher, hook NOT active",
                                        L"fut (pid %lu) – a pilótafülke-indító indította, a hook NEM aktív" },
    [S_GAME_RUNNING_NORMAL] = { L"running (pid %lu) – normal start", L"fut (pid %lu) – normál indítás" },
    [S_GAME_NOT_FOUND] = { L"game not found: %ls – set the game path in Settings", L"a játék nem található: %ls – add meg a Beállításokban" },
    [S_CFG_ON] = { L"cockpit ON since %ls (all values set)", L"pilótafülke BE %ls óta (minden érték beállítva)" },
    [S_CFG_ON_DIFF] = { L"cockpit ON since %ls, but differs: %ls", L"pilótafülke BE %ls óta, de eltér: %ls" },
    [S_CFG_OFF] = { L"cockpit OFF (normal values)", L"pilótafülke KI (normál értékek)" },
    [S_CFG_KIT_MISSING] = { L"cockpit kit not found: %ls", L"a pilótafülke-csomag nem található: %ls" },
    [S_CFG_UNKNOWN] = { L"unknown: %ls", L"ismeretlen: %ls" },
    [S_CFG_FLAG_STALE] = { L" – the dashboard skip flag is still present", L" – a műszerfal-tiltó jelzőfájl még megvan" },
    [S_MON_OK] = { L"%ls – OK", L"%ls – rendben" },
    [S_MON_OK_GEO] = { L"%ls – OK (recognised by geometry)", L"%ls – rendben (geometria alapján felismerve)" },
    [S_MON_BAD] = { L"%ls – does not fit: %ls", L"%ls – nem megfelelő: %ls" },
    [S_MON_UNKNOWN] = { L"could not check: %ls", L"nem ellenőrizhető: %ls" },
    [S_MON_RECT] = { L"rectangle from Settings: %ls (arrangement not checked)", L"téglalap a Beállításokból: %ls (elrendezés nincs ellenőrizve)" },
    [S_DASH_SERVER_UP] = { L"server up on 127.0.0.1:%d", L"szerver fut: 127.0.0.1:%d" },
    [S_DASH_SERVER_DOWN] = { L"server down (127.0.0.1:%d)", L"szerver nem fut (127.0.0.1:%d)" },
    [S_DASH_WATCHER_ON] = { L"watcher running", L"figyelő fut" },
    [S_DASH_WATCHER_OFF] = { L"watcher not running", L"figyelő nem fut" },
    [S_DASH_WINDOW_OPEN] = { L"window open", L"ablak nyitva" },
    [S_DASH_WINDOW_NONE] = { L"no window", L"nincs ablak" },
    [S_DASH_NOT_INSTALLED] = { L"X4 Companion not found: %ls", L"X4 Companion nem található: %ls" },
    [S_HOOK_OK] = { L"launcher.exe + x4c3hook.dll present", L"launcher.exe + x4c3hook.dll megvan" },
    [S_HOOK_MISSING] = { L"missing: %ls – build it with native\\build.cmd", L"hiányzik: %ls – fordítsd le: native\\build.cmd" },
    [S_CARD_RUNNING] = { L"Running now", L"Most fut" },
    [S_CARD_CLOSE_FIRST] = { L"The game is running – close it to switch", L"A játék fut – zárd be a váltáshoz" },
    [S_CARD_READY] = { L"Ready", L"Indításra kész" },
    [S_CARD_NOT_READY] = { L"Not ready: %ls", L"Nem indítható: %ls" },
    [S_CARD_SINGLE_WATCHER] = { L"Ready – dashboard via the companion watcher", L"Kész – műszerfal a Companion figyelővel" },
    [S_CARD_SINGLE_SELF] = { L"Ready – the dashboard opens from here", L"Kész – a műszerfal innen nyílik meg" },
    [S_CARD_SINGLE_NODASH] = { L"Ready – no dashboard (companion not found)", L"Kész – műszerfal nélkül (nincs Companion)" },
    [S_R_LAYOUT] = { L"monitor arrangement", L"monitor-elrendezés" },
    [S_R_HOOK] = { L"hook files missing", L"hiányzó hook fájlok" },
    [S_R_KIT] = { L"cockpit kit missing", L"hiányzó pilótafülke-csomag" },
    [S_R_GAME] = { L"game not found", L"a játék nem található" },

    [M_GAME_EXE_MISSING] = { L"The game was not found at %ls. Set the game path in Settings.",
                             L"A játék nem található itt: %ls. Add meg az útvonalat a Beállításokban." },
    [M_GAME_RUNNING] = { L"X4 is running (pid %lu). Close the game first – this manager never closes it.",
                         L"Az X4 fut (pid %lu). Előbb zárd be a játékot – a kezelő soha nem zárja be." },
    [M_KIT_MISSING] = { L"The cockpit kit was not found at %ls.", L"A pilótafülke-csomag nem található itt: %ls." },
    [M_HOOK_MISSING] = { L"Hook file missing: %ls – build it with native\\build.cmd in the cockpit kit.",
                         L"Hiányzó hook fájl: %ls – fordítsd le a csomag native\\build.cmd parancsával." },
    [M_RECT_BAD] = { L"The rectangle in Settings is invalid (%ls) – expected x,y,w,h.", L"A Beállításokban megadott téglalap hibás (%ls) – x,y,w,h formában kell." },
    [M_RECT_USED] = { L"Using the rectangle from Settings: %ls (monitor arrangement not checked).",
                      L"A Beállítások téglalapja: %ls (a monitor-elrendezés nincs ellenőrizve)." },
    [M_LAYOUT_CHECK] = { L"Checking the monitor arrangement…", L"A monitor-elrendezés ellenőrzése…" },
    [M_LAYOUT_OK] = { L"Monitors: %ls – OK.", L"Monitorok: %ls – rendben." },
    [M_LAYOUT_BAD] = { L"The monitor arrangement does not fit the cockpit: %ls", L"A monitor-elrendezés nem megfelelő a pilótafülkéhez: %ls" },
    [M_CFG_ON] = { L"Cockpit values are set in config.xml (%ls).", L"A pilótafülke-értékek a config.xml-ben (%ls)." },
    [M_CFG_OFF] = { L"Normal values are back in config.xml (%ls).", L"A normál értékek visszakerültek a config.xml-be (%ls)." },
    [M_CFG_ALREADY_OFF] = { L"config.xml is already in normal mode – nothing to restore.", L"A config.xml már normál módban van – nincs mit visszaállítani." },
    [M_CFG_REFUSED] = { L"The cockpit kit refused: %ls", L"A pilótafülke-csomag megtagadta: %ls" },
    [M_CFG_ERROR] = { L"Switching config.xml failed: %ls", L"A config.xml átállítása nem sikerült: %ls" },
    [M_SWITCHED_COCKPIT] = { L"Cockpit mode is set. The game was not started.", L"Pilótafülke mód beállítva. A játék nem indult el." },
    [M_SWITCHED_SINGLE] = { L"Single-monitor mode is set. The game was not started.", L"Egymonitoros mód beállítva. A játék nem indult el." },
    [M_LAUNCHING_COCKPIT] = { L"Starting X4 through the window-hook launcher…", L"Az X4 indítása az ablak-hook indítóval…" },
    [M_HOOK_ACTIVE] = { L"X4 started in cockpit mode – window hook ACTIVE (game pid %lu).", L"Az X4 pilótafülke módban indult – ablak-hook AKTÍV (játék pid %lu)." },
    [M_HOOK_FAILSAFE] = { L"X4 started, but WITHOUT the window hook (fail-safe): %ls", L"Az X4 elindult, de ablak-hook NÉLKÜL (biztonsági mód): %ls" },
    [M_LAUNCH_REFUSED] = { L"The cockpit launch was refused: %ls", L"A pilótafülke-indítás elutasítva: %ls" },
    [M_LAUNCH_ERROR] = { L"Starting through the launcher failed: %ls", L"Az indítás az indítón keresztül nem sikerült: %ls" },
    [M_STARTING_GAME] = { L"Starting X4 normally: %ls", L"Az X4 normál indítása: %ls" },
    [M_GAME_STARTED] = { L"X4 started (pid %lu), detached from this manager.", L"Az X4 elindult (pid %lu), a kezelőtől függetlenül." },
    [M_GAME_START_FAILED] = { L"Starting X4 failed: %ls", L"Az X4 indítása nem sikerült: %ls" },
    [M_GAME_EXITED_EARLY] = { L"Note: the game process (pid %lu) exited within a few seconds.", L"Megjegyzés: a játékfolyamat (pid %lu) néhány másodpercen belül kilépett." },
    [M_DASH_NONE] = { L"No dashboard: X4 Companion not found at %ls.", L"Nincs műszerfal: az X4 Companion nem található itt: %ls." },
    [M_DASH_WATCHER] = { L"The companion watcher is running – it starts the server and opens the dashboard.",
                         L"A Companion figyelő fut – ő indítja a szervert és nyitja meg a műszerfalat." },
    [M_DASH_WAIT_OK] = { L"The dashboard is open.", L"A műszerfal nyitva van." },
    [M_DASH_WAIT_TIMEOUT] = { L"The dashboard did not appear within %d s – see the companion's logs\\watcher.log.",
                              L"A műszerfal %d mp alatt nem jelent meg – lásd a Companion logs\\watcher.log fájlját." },
    [M_DASH_SELF] = { L"The companion watcher is not running – starting the dashboard from here…",
                      L"A Companion figyelő nem fut – a műszerfalat innen indítjuk…" },
    [M_DASH_OPENED] = { L"Dashboard window opened.", L"A műszerfal ablak megnyílt." },
    [M_DASH_PRESENT] = { L"The dashboard window was already open.", L"A műszerfal ablak már nyitva volt." },
    [M_DASH_FAILED] = { L"The dashboard could not be opened: %ls", L"A műszerfalat nem sikerült megnyitni: %ls" },
    [M_DASH_DRY] = { L"Dashboard: %ls", L"Műszerfal: %ls" },
    [M_DRY_RUN] = { L"DRY RUN – nothing is changed or started.", L"PRÓBAFUTÁS – semmi nem változik, semmi nem indul." },
    [M_DRY_GAME_CMD] = { L"Would start: %ls", L"Ezt indítaná: %ls" },
    [M_BUSY] = { L"Another action is still running.", L"Egy másik művelet még fut." },
    [M_SKIP_KIT_SINGLE] = { L"Cockpit kit not found – config.xml is not touched.", L"A pilótafülke-csomag nem található – a config.xml nem változik." },
    [M_KIT_KEEPS_GAME_SAFE] = { L"The game keeps running when this manager is closed.", L"A játék tovább fut, ha a kezelőt bezárod." },
    [M_SCRIPT_TIMEOUT] = { L"%ls did not finish within %d s.", L"%ls nem fejeződött be %d mp alatt." },
    [M_SCRIPT_FAILED] = { L"%ls gave no usable result (exit code %lu).", L"%ls nem adott használható eredményt (kilépési kód %lu)." },

    [S_SET_TITLE] = { L"Settings", L"Beállítások" },
    [S_SET_GAME] = { L"Game (X4.exe)", L"Játék (X4.exe)" },
    [S_SET_BROWSE] = { L"Browse…", L"Tallózás…" },
    [S_SET_ARGS] = { L"Game arguments", L"A játék indítási paraméterei" },
    [S_SET_ARGS_HINT] = { L"for example  -debug all -logfile debug.log   (empty = none)", L"például  -debug all -logfile debug.log   (üres = nincs)" },
    [S_SET_RECT] = { L"Cockpit rectangle override", L"Pilótafülke-téglalap felülbírálása" },
    [S_SET_RECT_HINT] = { L"x,y,w,h   (empty = from the live monitor arrangement)", L"x,y,w,h   (üres = az élő monitor-elrendezésből)" },
    [S_SET_LANG] = { L"Language", L"Nyelv" },
    [S_SET_LANG_AUTO] = { L"Automatic", L"Automatikus" },
    [S_SET_CLOSE] = { L"Close the manager after starting the game", L"A kezelő bezárása a játék indítása után" },
    [S_SET_SAVE] = { L"Save", L"Mentés" },
    [S_SET_CANCEL] = { L"Cancel", L"Mégse" },
    [S_SET_PATHS] = { L"Cockpit kit: %ls\nCompanion: %ls\nSettings file: %ls", L"Pilótafülke-csomag: %ls\nCompanion: %ls\nBeállításfájl: %ls" },
    [S_SET_BAD_RECT] = { L"Invalid rectangle – use x,y,w,h (w and h at least 16) or leave it empty.",
                         L"Hibás téglalap – x,y,w,h formában (w és h legalább 16), vagy hagyd üresen." },
    [S_YES] = { L"On", L"Be" },
    [S_NO] = { L"Off", L"Ki" },
};

static int g_hu = 0;

void i18n_set(const wchar_t *lang) {
    if (lang && !_wcsicmp(lang, L"hu")) g_hu = 1;
    else if (lang && !_wcsicmp(lang, L"en")) g_hu = 0;
    else g_hu = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_HUNGARIAN;
}
const wchar_t *i18n_lang(void) { return g_hu ? L"hu" : L"en"; }
const wchar_t *tr_lang(const wchar_t *lang, StrId id) {
    if (id < 0 || id >= S_COUNT) return L"?";
    int hu = lang && !_wcsicmp(lang, L"hu");
    const wchar_t *s = hu ? T[id].hu : T[id].en;
    return s ? s : (T[id].en ? T[id].en : L"?");
}
const wchar_t *tr(StrId id) { return tr_lang(g_hu ? L"hu" : L"en", id); }

static void convs(const wchar_t *s, wchar_t *out, int cap) {
    int k = 0;
    for (; s && *s && k < cap - 4; s++) {
        if (*s != L'%') continue;
        s++;
        if (*s == L'%') continue;
        while (*s && wcschr(L"lh0123456789-.", *s)) out[k++] = *s++;
        if (*s) out[k++] = *s;
        out[k++] = L' ';
        if (!*s) break;
    }
    out[k] = 0;
}

int i18n_selftest(wchar_t *msg, int cap) {
    for (int i = 0; i < S_COUNT; i++) {
        if (!T[i].en || !T[i].en[0] || !T[i].hu || !T[i].hu[0]) { _snwprintf(msg, cap, L"token %d is missing in %ls", i, (!T[i].en || !T[i].en[0]) ? L"en" : L"hu"); msg[cap - 1] = 0; return 0; }
        wchar_t a[64], b[64];
        convs(T[i].en, a, 64); convs(T[i].hu, b, 64);
        if (wcscmp(a, b)) { _snwprintf(msg, cap, L"token %d: conversions differ (en '%ls', hu '%ls')", i, a, b); msg[cap - 1] = 0; return 0; }
    }
    _snwprintf(msg, cap, L"%d tokens complete in en and hu, same conversions", (int)S_COUNT); msg[cap - 1] = 0;
    return 1;
}
