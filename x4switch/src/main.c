/* X4Switch - entry point: GUI by default, command-line equivalents for scripting and tests.
 *
 *   X4Switch.exe                                   the window
 *   X4Switch.exe --mode cockpit|single [--no-start] [--dry-run] [--json]
 *   X4Switch.exe --status [--json]                 read-only status (also: --dry-run alone)
 *   X4Switch.exe --open-dashboard [--dry-run]      start the companion server if needed, open its window if none
 *   X4Switch.exe --check-monitors                  the kit's arrangement check
 *   X4Switch.exe --selftest                        internal checks (no files, no processes)
 *   X4Switch.exe --gui-smoke <file> [--render <bmp>] [--hold-ms <n>]   window created hidden, controls dumped
 *   common: --settings <file>  --log-dir <dir>  --lang en|hu  --instance <name>  --help
 *
 * Exit codes: 0 ok, 1 error, 2 refused (game running, arrangement, missing files, ...), 3 started WITHOUT the window
 * hook (fail-safe), 4 bad usage, 5 another X4Switch instance is busy. */
#include "x4switch.h"
#include <objbase.h>
#include <shellapi.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

int gui_run(Settings *s, const wchar_t *smokeFile, const wchar_t *renderFile, int holdMs);
extern int g_smokeSave;

static HANDLE g_out = NULL; static int g_console = 0, g_outInit = 0;
static void out_init(void) {
    if (g_outInit) return;
    g_outInit = 1;
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    if (h && h != INVALID_HANDLE_VALUE && GetFileType(h) != FILE_TYPE_UNKNOWN) { g_out = h; DWORD m; g_console = GetConsoleMode(h, &m); return; }
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
        g_out = CreateFileW(L"CONOUT$", GENERIC_WRITE, FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        g_console = g_out != INVALID_HANDLE_VALUE;
    }
}
static void out_w(const wchar_t *t) {
    out_init();
    if (!g_out || g_out == INVALID_HANDLE_VALUE) return;
    DWORD w;
    if (g_console) WriteConsoleW(g_out, t, (DWORD)wcslen(t), &w, NULL);
    else { char *u = w_to_utf8(t); WriteFile(g_out, u, (DWORD)strlen(u), &w, NULL); x4_free(u); }
}
static void out_line(const wchar_t *t) { out_w(t); out_w(L"\r\n"); }

static void cli_report(void *ctx, int kind, const wchar_t *t) {
    static const wchar_t *P[] = { L"   ", L"OK ", L"!  ", L"XX ", L"     ", L">> " };
    wchar_t *b = (wchar_t *)x4_alloc((wcslen(t) + 16) * sizeof(wchar_t));
    if (!b) return;
    lstrcpyW(b, P[kind < 0 || kind > 5 ? 0 : kind]); lstrcatW(b, t);
    out_line(b); x4_free(b);
}

static void usage(void) {
    out_line(L"X4Switch " X4S_VERSION L" - choose how X4: Foundations starts (unofficial fan project).");
    out_line(L"  X4Switch.exe                                  the window");
    out_line(L"  X4Switch.exe --mode cockpit|single [--no-start] [--dry-run] [--json]");
    out_line(L"  X4Switch.exe --status [--json]                read-only status (also --dry-run alone)");
    out_line(L"  X4Switch.exe --open-dashboard [--dry-run]");
    out_line(L"  X4Switch.exe --check-monitors");
    out_line(L"  X4Switch.exe --selftest");
    out_line(L"  X4Switch.exe --gui-smoke <file> [--render <bmp>] [--hold-ms <n>]");
    out_line(L"  common: --settings <file> --log-dir <dir> --lang en|hu --instance <name>");
    out_line(L"exit: 0 ok, 1 error, 2 refused, 3 started without the window hook, 4 usage, 5 another instance busy");
}

static void emit_json(JVal *o) {
    char *u = json_write(o, 0);
    wchar_t *w = utf8_to_w(u, -1);
    wchar_t *line = (wchar_t *)x4_alloc((wcslen(w) + 16) * sizeof(wchar_t));
    lstrcpyW(line, L"@@X4SWITCH "); lstrcatW(line, w);
    out_line(line);
    x4_free(line); x4_free(w); x4_free(u);
}

int main(void) {
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    const wchar_t *mode = NULL, *settingsFile = NULL, *logDir = NULL, *lang = NULL, *instance = L"Local\\X4Switch", *smoke = NULL, *render = NULL;
    int noStart = 0, dry = 0, json = 0, status = 0, openDash = 0, checkMon = 0, selftest = 0, help = 0, holdMs = 0, bad = 0;
    for (int i = 1; i < argc; i++) {
        const wchar_t *a = argv[i];
        int more = i + 1 < argc;
        if (!wcscmp(a, L"--mode") && more) mode = argv[++i];
        else if (!wcscmp(a, L"--no-start")) noStart = 1;
        else if (!wcscmp(a, L"--dry-run")) dry = 1;
        else if (!wcscmp(a, L"--json")) json = 1;
        else if (!wcscmp(a, L"--status")) status = 1;
        else if (!wcscmp(a, L"--open-dashboard")) openDash = 1;
        else if (!wcscmp(a, L"--check-monitors")) checkMon = 1;
        else if (!wcscmp(a, L"--selftest")) selftest = 1;
        else if (!wcscmp(a, L"--settings") && more) settingsFile = argv[++i];
        else if (!wcscmp(a, L"--log-dir") && more) logDir = argv[++i];
        else if (!wcscmp(a, L"--lang") && more) lang = argv[++i];
        else if (!wcscmp(a, L"--instance") && more) instance = argv[++i];
        else if (!wcscmp(a, L"--gui-smoke") && more) smoke = argv[++i];
        else if (!wcscmp(a, L"--render") && more) render = argv[++i];
        else if (!wcscmp(a, L"--hold-ms") && more) holdMs = _wtoi(argv[++i]);
        else if (!wcscmp(a, L"--smoke-save")) g_smokeSave = 1;
        else if (!wcscmp(a, L"--help") || !wcscmp(a, L"-h") || !wcscmp(a, L"/?")) help = 1;
        else bad = 1;
    }
    int modeId = -1;
    if (mode) { if (!_wcsicmp(mode, L"cockpit")) modeId = MODE_COCKPIT; else if (!_wcsicmp(mode, L"single")) modeId = MODE_SINGLE; else bad = 1; }
    if (lang && _wcsicmp(lang, L"en") && _wcsicmp(lang, L"hu")) bad = 1;
    if (help || bad) { usage(); return bad ? RC_USAGE : RC_OK; }

    int cli = mode || status || openDash || checkMon || selftest || (dry && !smoke);
    /* GUI and console: physical pixels everywhere (the manifest says PerMonitorV2 too) */
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(NULL, cli ? COINIT_MULTITHREADED : COINIT_APARTMENTTHREADED);
    CoInitializeSecurity(NULL, -1, NULL, NULL, RPC_C_AUTHN_LEVEL_DEFAULT, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE, NULL);

    wchar_t exe[X4S_PATH], exeDir[X4S_PATH];
    GetModuleFileNameW(NULL, exe, X4S_PATH);
    lstrcpynW(exeDir, exe, X4S_PATH);
    wchar_t *sl = wcsrchr(exeDir, L'\\'); if (sl) *sl = 0;
    static Settings s;
    settings_init(&s, exeDir, settingsFile, logDir);
    int loaded = settings_load(&s);
    settings_resolve(&s);
    log_init(s.logDir);
    i18n_set(lang ? lang : s.language);
    log_line(L"==== X4Switch %ls start: %ls", X4S_VERSION, GetCommandLineW());
    log_line(L"settings %ls (%ls); game %ls; kit %ls; companion %ls; language %ls", s.settingsPath,
             loaded > 0 ? L"loaded" : loaded == 0 ? L"none, defaults" : L"UNREADABLE, defaults", s.rGameExe, s.rCockpitDir, s.rCompanionDir, i18n_lang());
    Reporter r = { cli_report, NULL };
    if (s.loadError[0] && cli) rep(&r, K_WARN, L"%ls", s.loadError);

    if (selftest) { int f = core_selftest(&r); return f ? RC_ERROR : RC_OK; }

    if (status || (dry && !mode && !openDash && !checkMon && !smoke)) {
        Status st; memset(&st, 0, sizeof st);
        status_slow(&s, &st);
        wchar_t lines[5][700]; int col[5];
        status_lines(&st, &s, lines, col);
        static const StrId lab[5] = { S_ST_GAME, S_ST_CONFIG, S_ST_MONITORS, S_ST_DASH, S_ST_HOOK };
        static const wchar_t *C[] = { L"idle", L"ok", L"warn", L"BAD", L"info" };
        for (int i = 0; i < 5; i++) {
            wchar_t b[900]; _snwprintf(b, 900, L"%-12ls [%ls] %ls", tr(lab[i]), C[col[i]], lines[i]); b[899] = 0; out_line(b);
        }
        wchar_t card[300]; int cc;
        status_card(&st, MODE_COCKPIT, card, 300, &cc); { wchar_t b[400]; _snwprintf(b, 400, L"%-12ls %ls", L"cockpit:", card); b[399] = 0; out_line(b); }
        status_card(&st, MODE_SINGLE, card, 300, &cc); { wchar_t b[400]; _snwprintf(b, 400, L"%-12ls %ls", L"single:", card); b[399] = 0; out_line(b); }
        if (json) { JVal *o = status_json(&st, &s); emit_json(o); json_free(o); }
        return RC_OK;
    }

    if (checkMon) {
        ActionResult res; action_check_monitors(&s, &r, &res);
        if (json) { JVal *o = jnew(J_OBJ); jset_str(o, L"action", L"check-monitors"); jset_num(o, L"exit", res.code); jset_str(o, L"result", res.result); jset_str(o, L"summary", res.summary); emit_json(o); json_free(o); }
        return res.code;
    }

    /* everything below changes something (or shows the GUI): one instance at a time */
    HANDLE mtx = NULL;
    if (!dry || smoke) {
        mtx = CreateMutexW(NULL, FALSE, instance);
        if (mtx && GetLastError() == ERROR_ALREADY_EXISTS) {
            log_line(L"another instance holds %ls", instance);
            if (!cli && !smoke) {
                HWND w = FindWindowW(L"X4SwitchMain", NULL);
                if (w) { ShowWindow(w, IsIconic(w) ? SW_RESTORE : SW_SHOW); SetForegroundWindow(w); }
                return RC_OK;
            }
            rep(&r, K_ERR, L"another X4Switch instance is running (%ls) - close it first", instance);
            if (json) { JVal *o = jnew(J_OBJ); jset_str(o, L"result", L"refused-instance"); jset_num(o, L"exit", RC_INSTANCE); emit_json(o); json_free(o); }
            return RC_INSTANCE;
        }
    }

    if (openDash) {
        ActionResult res; action_open_dashboard(&s, dry, &r, &res);
        if (json) { JVal *o = jnew(J_OBJ); jset_str(o, L"action", L"open-dashboard"); jset_num(o, L"exit", res.code); jset_str(o, L"result", res.result); emit_json(o); json_free(o); }
        return res.code;
    }

    if (mode) {
        ActionResult res; action_mode(&s, modeId, !noStart, dry, &r, &res);
        if (json) {
            JVal *o = jnew(J_OBJ);
            jset_str(o, L"tool", L"x4switch"); jset_str(o, L"action", L"mode"); jset_str(o, L"mode", modeId == MODE_COCKPIT ? L"cockpit" : L"single");
            jset_bool(o, L"start", !noStart); jset_bool(o, L"dryRun", dry); jset_num(o, L"exit", res.code); jset_str(o, L"result", res.result);
            jset_str(o, L"summary", res.summary); jset_num(o, L"gamePid", res.gamePid); jset_bool(o, L"hookActive", res.hookActive & 1);
            emit_json(o); json_free(o);
        }
        log_line(L"exit %d (%ls)", res.code, res.result);
        return res.code;
    }

    int rc = gui_run(&s, smoke, render, holdMs);
    if (mtx) CloseHandle(mtx);
    return rc;
}
