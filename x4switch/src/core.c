/* X4Switch - core: settings, logging, child scripts, detached starts (WMI), status, the two start modes.
 * Nothing here kills a process it did not start; long-lived processes are created by the WMI service
 * (Win32_Process.Create), so they are not in this program's process tree or job. */
#define COBJMACROS
#include "x4switch.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <objbase.h>
#include <oleauto.h>
#include <wbemidl.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <wchar.h>

/* ------------------------------------------------------------------ memory / strings */
void *x4_alloc(size_t n) { return HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, n ? n : 1); }
void x4_free(void *p) { if (p) HeapFree(GetProcessHeap(), 0, p); }

wchar_t *utf8_to_w(const char *s, int len) {
    if (!s) return NULL;
    if (len < 0) len = (int)strlen(s);
    int n = MultiByteToWideChar(CP_UTF8, 0, s, len, NULL, 0);
    wchar_t *w = (wchar_t *)x4_alloc((size_t)(n + 1) * sizeof(wchar_t));
    if (w && n) MultiByteToWideChar(CP_UTF8, 0, s, len, w, n);
    return w;
}
char *w_to_utf8(const wchar_t *s) {
    if (!s) s = L"";
    int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, NULL, 0, NULL, NULL);
    char *u = (char *)x4_alloc((size_t)n + 1);
    if (u) WideCharToMultiByte(CP_UTF8, 0, s, -1, u, n, NULL, NULL);
    return u;
}
static void wcopy(wchar_t *d, int cap, const wchar_t *s) { if (cap <= 0) return; lstrcpynW(d, s ? s : L"", cap); }
static void wcat(wchar_t *d, int cap, const wchar_t *s) {
    size_t n = wcslen(d);
    if ((int)n < cap - 1) lstrcpynW(d + n, s ? s : L"", cap - (int)n);
}
static void wfmt(wchar_t *d, int cap, const wchar_t *fmt, ...) {
    va_list a; va_start(a, fmt); _vsnwprintf(d, (size_t)cap, fmt, a); va_end(a); d[cap - 1] = 0;
}

int file_exists(const wchar_t *p) { DWORD a = GetFileAttributesW(p); return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY); }
int dir_exists(const wchar_t *p) { DWORD a = GetFileAttributesW(p); return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY); }

void path_join(wchar_t *out, int cap, const wchar_t *a, const wchar_t *b) {
    wchar_t t[X4S_PATH * 2];
    wcopy(t, X4S_PATH * 2, a);
    size_t n = wcslen(t);
    if (n && t[n - 1] != L'\\' && t[n - 1] != L'/') wcat(t, X4S_PATH * 2, L"\\");
    wcat(t, X4S_PATH * 2, b);
    DWORD k = GetFullPathNameW(t, (DWORD)cap, out, NULL);
    if (!k || (int)k >= cap) wcopy(out, cap, t);
}
static void full_path(wchar_t *out, int cap, const wchar_t *p) {
    DWORD k = GetFullPathNameW(p, (DWORD)cap, out, NULL);
    if (!k || (int)k >= cap) wcopy(out, cap, p);
}
static void parent_dir(wchar_t *out, int cap, const wchar_t *p) {
    wcopy(out, cap, p);
    wchar_t *s = wcsrchr(out, L'\\'); if (!s) s = wcsrchr(out, L'/');
    if (s) *s = 0;
}

static char *read_file(const wchar_t *path, size_t *len) {
    *len = 0;
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;
    LARGE_INTEGER sz; char *buf = NULL;
    if (GetFileSizeEx(h, &sz) && sz.QuadPart < 64 * 1024 * 1024) {
        buf = (char *)x4_alloc((size_t)sz.QuadPart + 1);
        DWORD got = 0;
        if (buf && ReadFile(h, buf, (DWORD)sz.QuadPart, &got, NULL)) *len = got;
        else { x4_free(buf); buf = NULL; }
    }
    CloseHandle(h);
    return buf;
}

void quote_arg(wchar_t *out, int cap, const wchar_t *arg) {
    /* CommandLineToArgvW rules: quote when needed; backslashes before a quote are doubled, the quote escaped. */
    int need = !arg[0];
    for (const wchar_t *p = arg; *p; p++) if (*p == L' ' || *p == L'\t' || *p == L'"') need = 1;
    if (!need) { wcopy(out, cap, arg); return; }
    int k = 0;
    if (k < cap - 1) out[k++] = L'"';
    for (const wchar_t *p = arg; ; p++) {
        int bs = 0;
        while (*p == L'\\') { bs++; p++; }
        if (!*p) { for (int i = 0; i < bs * 2 && k < cap - 2; i++) out[k++] = L'\\'; break; }
        if (*p == L'"') { for (int i = 0; i < bs * 2 + 1 && k < cap - 2; i++) out[k++] = L'\\'; if (k < cap - 2) out[k++] = L'"'; }
        else { for (int i = 0; i < bs && k < cap - 2; i++) out[k++] = L'\\'; if (k < cap - 2) out[k++] = *p; }
    }
    if (k < cap - 1) out[k++] = L'"';
    out[k] = 0;
}

/* ------------------------------------------------------------------ logging */
static CRITICAL_SECTION g_logCs; static int g_logInit; static wchar_t g_logFile[X4S_PATH];
void log_init(const wchar_t *dir) {
    if (!g_logInit) { InitializeCriticalSection(&g_logCs); g_logInit = 1; }
    CreateDirectoryW(dir, NULL);
    path_join(g_logFile, X4S_PATH, dir, L"x4switch.log");
}
void log_line(const wchar_t *fmt, ...) {
    if (!g_logInit || !g_logFile[0]) return;
    wchar_t msg[4096]; va_list a; va_start(a, fmt); _vsnwprintf(msg, 4095, fmt, a); va_end(a); msg[4095] = 0;
    SYSTEMTIME t; GetLocalTime(&t);
    wchar_t line[4300];
    _snwprintf(line, 4299, L"%04d-%02d-%02d %02d:%02d:%02d [%lu] %ls\r\n", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, GetCurrentProcessId(), msg);
    line[4299] = 0;
    char *u = w_to_utf8(line);
    EnterCriticalSection(&g_logCs);
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (GetFileAttributesExW(g_logFile, GetFileExInfoStandard, &fa) && fa.nFileSizeLow > 512 * 1024) {
        wchar_t old[X4S_PATH]; wfmt(old, X4S_PATH, L"%ls.1", g_logFile);
        MoveFileExW(g_logFile, old, MOVEFILE_REPLACE_EXISTING);
    }
    HANDLE h = CreateFileW(g_logFile, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(h, u, (DWORD)strlen(u), &w, NULL); CloseHandle(h); }
    LeaveCriticalSection(&g_logCs);
    x4_free(u);
}

void rep(const Reporter *r, int kind, const wchar_t *fmt, ...) {
    wchar_t msg[4096]; va_list a; va_start(a, fmt); _vsnwprintf(msg, 4095, fmt, a); va_end(a); msg[4095] = 0;
    static const wchar_t *K[] = { L"info", L"ok", L"WARN", L"ERROR", L"  >", L"step" };
    log_line(L"%ls: %ls", K[kind < 0 || kind > 5 ? 0 : kind], msg);
    if (r && r->fn) r->fn(r->ctx, kind, msg);
}

/* ------------------------------------------------------------------ settings */
void settings_init(Settings *s, const wchar_t *exeDir, const wchar_t *settingsFile, const wchar_t *logDir) {
    memset(s, 0, sizeof *s);
    full_path(s->exeDir, X4S_PATH, exeDir);
    if (settingsFile && *settingsFile) full_path(s->settingsPath, X4S_PATH, settingsFile);
    else path_join(s->settingsPath, X4S_PATH, s->exeDir, L"settings.json");
    if (logDir && *logDir) full_path(s->logDir, X4S_PATH, logDir);
    else path_join(s->logDir, X4S_PATH, s->exeDir, L"logs");
    wcopy(s->lastMode, 16, L"cockpit");
    s->launchWaitSeconds = 30; s->dashboardWaitSeconds = 30;
}

static void sget(const JVal *d, const wchar_t *k, wchar_t *dst, int cap) { const wchar_t *v = jstr(d, k, NULL); if (v) wcopy(dst, cap, v); }

int settings_load(Settings *s) {
    json_free(s->doc); s->doc = NULL; s->loadError[0] = 0;
    size_t len; char *buf = read_file(s->settingsPath, &len);
    if (!buf) { s->doc = jnew(J_OBJ); return 0; }
    char err[200];
    JVal *d = json_parse(buf, len, err, sizeof err);
    x4_free(buf);
    if (!d || d->t != J_OBJ) {
        json_free(d); s->doc = jnew(J_OBJ);
        wchar_t *we = utf8_to_w(err, -1); wfmt(s->loadError, 256, L"settings.json unreadable (%ls) - using defaults", we ? we : L"?"); x4_free(we);
        return -1;
    }
    s->doc = d;
    sget(d, L"language", s->language, 8);
    sget(d, L"lastMode", s->lastMode, 16);
    if (wcscmp(s->lastMode, L"single")) wcopy(s->lastMode, 16, L"cockpit");
    sget(d, L"gameExe", s->gameExe, X4S_PATH);
    sget(d, L"gameArgs", s->gameArgs, 1024);
    sget(d, L"rect", s->rect, 64);
    s->closeAfterStart = jbool(d, L"closeAfterStart", 0);
    sget(d, L"cockpitDir", s->cockpitDir, X4S_PATH);
    sget(d, L"companionDir", s->companionDir, X4S_PATH);
    s->dashboardPort = (int)jnum(d, L"dashboardPort", 0);
    sget(d, L"cockpitSettingsFile", s->cockpitSettingsFile, X4S_PATH);
    sget(d, L"monitorsJson", s->monitorsJson, X4S_PATH);
    sget(d, L"cockpitLogDir", s->cockpitLogDir, X4S_PATH);
    sget(d, L"companionStateDir", s->companionStateDir, X4S_PATH);
    sget(d, L"companionLogDir", s->companionLogDir, X4S_PATH);
    sget(d, L"companionMutex", s->companionMutex, 128);
    sget(d, L"powershellExe", s->powershellExe, X4S_PATH);
    s->launchWaitSeconds = (int)jnum(d, L"launchWaitSeconds", 30);
    s->dashboardWaitSeconds = (int)jnum(d, L"dashboardWaitSeconds", 30);
    if (s->launchWaitSeconds < 5 || s->launchWaitSeconds > 300) s->launchWaitSeconds = 30;
    if (s->dashboardWaitSeconds < 1 || s->dashboardWaitSeconds > 300) s->dashboardWaitSeconds = 30;
    return 1;
}

void settings_resolve(Settings *s) {
    wchar_t up1[X4S_PATH], up2[X4S_PATH];
    path_join(up1, X4S_PATH, s->exeDir, L"..");
    path_join(up2, X4S_PATH, s->exeDir, L"..\\..");
    if (s->cockpitDir[0]) full_path(s->rCockpitDir, X4S_PATH, s->cockpitDir); else path_join(s->rCockpitDir, X4S_PATH, up1, L"x4cockpit3");
    if (s->companionDir[0]) full_path(s->rCompanionDir, X4S_PATH, s->companionDir); else path_join(s->rCompanionDir, X4S_PATH, up1, L"x4companion");
    if (s->gameExe[0]) full_path(s->rGameExe, X4S_PATH, s->gameExe); else path_join(s->rGameExe, X4S_PATH, up2, L"X4.exe");
    parent_dir(s->rGameDir, X4S_PATH, s->rGameExe);
    if (s->companionStateDir[0]) full_path(s->rCompanionState, X4S_PATH, s->companionStateDir);
    else path_join(s->rCompanionState, X4S_PATH, s->rCompanionDir, L"state");
    if (s->cockpitLogDir[0]) full_path(s->rLauncherLogDir, X4S_PATH, s->cockpitLogDir);
    else path_join(s->rLauncherLogDir, X4S_PATH, s->rCockpitDir, L"native\\out");
    if (!s->companionMutex[0]) wcopy(s->companionMutex, 128, L"Local\\X4CompanionWatcher");
    if (!s->powershellExe[0]) {
        wchar_t sys[MAX_PATH]; GetSystemDirectoryW(sys, MAX_PATH);
        path_join(s->powershellExe, X4S_PATH, sys, L"WindowsPowerShell\\v1.0\\powershell.exe");
    }
    /* the companion's own settings: port and window title (read-only) */
    s->rPort = 8788; wcopy(s->rWindowTitle, 128, L"X4 Companion");
    wchar_t wj[X4S_PATH]; path_join(wj, X4S_PATH, s->rCompanionState, L"watcher.json");
    size_t len; char *buf = read_file(wj, &len);
    if (buf) {
        JVal *d = json_parse(buf, len, NULL, 0);
        if (d) { int p = (int)jnum(d, L"port", 0); if (p > 0 && p < 65536) s->rPort = p; sget(d, L"windowTitle", s->rWindowTitle, 128); if (!s->rWindowTitle[0]) wcopy(s->rWindowTitle, 128, L"X4 Companion"); json_free(d); }
        x4_free(buf);
    }
    if (s->dashboardPort > 0 && s->dashboardPort < 65536) s->rPort = s->dashboardPort;
}

int settings_save(Settings *s) {
    if (!s->doc) s->doc = jnew(J_OBJ);
    JVal *d = s->doc;
    jset_str(d, L"language", s->language);
    jset_str(d, L"lastMode", s->lastMode);
    jset_str(d, L"gameExe", s->gameExe);
    jset_str(d, L"gameArgs", s->gameArgs);
    jset_str(d, L"rect", s->rect);
    jset_bool(d, L"closeAfterStart", s->closeAfterStart);
    jset_str(d, L"cockpitDir", s->cockpitDir);
    jset_str(d, L"companionDir", s->companionDir);
    jset_num(d, L"dashboardPort", s->dashboardPort);
    char *u = json_write(d, 1);
    if (!u) return 0;
    wchar_t tmp[X4S_PATH]; wfmt(tmp, X4S_PATH, L"%ls.tmp", s->settingsPath);
    int ok = 0;
    HANDLE h = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD w; ok = WriteFile(h, u, (DWORD)strlen(u), &w, NULL) && w == strlen(u);
        CloseHandle(h);
        if (ok) ok = MoveFileExW(tmp, s->settingsPath, MOVEFILE_REPLACE_EXISTING);
        if (!ok) DeleteFileW(tmp);
    }
    x4_free(u);
    log_line(L"settings saved to %ls: %ls", s->settingsPath, ok ? L"ok" : L"FAILED");
    return ok;
}

int rect_valid(const wchar_t *r) {
    if (!r || !*r) return 1;
    long v[4]; int n = 0; const wchar_t *p = r;
    while (n < 4) {
        while (*p == L' ') p++;
        wchar_t *e; long x = wcstol(p, &e, 10);
        if (e == p) return 0;
        v[n++] = x; p = e;
        while (*p == L' ') p++;
        if (n < 4) { if (*p != L',') return 0; p++; }
    }
    if (*p) return 0;
    return v[2] >= 16 && v[3] >= 16 && v[2] <= 32767 && v[3] <= 32767 && v[0] > -32768 && v[0] < 32768 && v[1] > -32768 && v[1] < 32768;
}

/* ------------------------------------------------------------------ probes (read-only) */
static int g_wsa;
int port_open(int port, int timeoutMs) {
    if (!g_wsa) { WSADATA w; if (WSAStartup(MAKEWORD(2, 2), &w)) return 0; g_wsa = 1; }
    SOCKET so = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (so == INVALID_SOCKET) return 0;
    u_long nb = 1; ioctlsocket(so, FIONBIO, &nb);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((u_short)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int ok = 0;
    if (connect(so, (struct sockaddr *)&a, sizeof a) == 0) ok = 1;
    else if (WSAGetLastError() == WSAEWOULDBLOCK) {
        fd_set wr, ex; FD_ZERO(&wr); FD_ZERO(&ex); FD_SET(so, &wr); FD_SET(so, &ex);
        struct timeval tv = { timeoutMs / 1000, (timeoutMs % 1000) * 1000 };
        if (select(0, NULL, &wr, &ex, &tv) > 0 && FD_ISSET(so, &wr)) {
            int e = 0, el = sizeof e;
            if (!getsockopt(so, SOL_SOCKET, SO_ERROR, (char *)&e, &el) && !e) ok = 1;
        }
    }
    closesocket(so);
    return ok;
}

DWORD find_game_pid(const wchar_t *exe) {
    const wchar_t *base = wcsrchr(exe, L'\\'); base = base ? base + 1 : exe;
    HANDLE sn = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (sn == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W pe; pe.dwSize = sizeof pe; DWORD found = 0;
    if (Process32FirstW(sn, &pe)) do {
        if (_wcsicmp(pe.szExeFile, base)) continue;
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
        if (!h) { found = pe.th32ProcessID; break; }           /* path unreadable: count it (conservative, as the kit does) */
        wchar_t p[X4S_PATH]; DWORD n = X4S_PATH;
        BOOL ok = QueryFullProcessImageNameW(h, 0, p, &n);
        CloseHandle(h);
        if (!ok || !_wcsicmp(p, exe)) { found = pe.th32ProcessID; break; }
    } while (Process32NextW(sn, &pe));
    CloseHandle(sn);
    return found;
}

typedef struct { const wchar_t *prefix; int found; } WinFind;
static BOOL CALLBACK win_cb(HWND h, LPARAM l) {
    WinFind *f = (WinFind *)l;
    if (!IsWindowVisible(h)) return TRUE;
    wchar_t t[512]; GetWindowTextW(h, t, 512);
    size_t n = wcslen(f->prefix);
    if (n && !_wcsnicmp(t, f->prefix, n)) { f->found = 1; return FALSE; }
    return TRUE;
}
int find_window_prefix(const wchar_t *prefix) { WinFind f = { prefix, 0 }; EnumWindows(win_cb, (LPARAM)&f); return f.found; }

int mutex_exists(const wchar_t *name) {
    HANDLE h = OpenMutexW(SYNCHRONIZE, FALSE, name);
    if (h) { CloseHandle(h); return 1; }
    return GetLastError() == ERROR_ACCESS_DENIED;
}

static int game_mode(const Settings *s, DWORD pid) {
    wchar_t lp[X4S_PATH]; path_join(lp, X4S_PATH, s->rLauncherLogDir, L"launcher.log");
    size_t len; char *buf = read_file(lp, &len);
    if (buf) {
        char needle[64]; _snprintf(needle, sizeof needle, "pid=%lu hook=", pid); needle[63] = 0;
        char *last = NULL, *p = buf;
        while ((p = strstr(p, needle)) != NULL) { last = p; p++; }
        int m = 0;
        if (last) m = (last[strlen(needle)] == 'A') ? GM_COCKPIT_ACTIVE : GM_COCKPIT_NOHOOK;
        x4_free(buf);
        if (m) return m;
    }
    /* not in the launcher log (log started over?): is our hook DLL loaded in the game process? (read-only) */
    HANDLE sn = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (sn != INVALID_HANDLE_VALUE) {
        MODULEENTRY32W me; me.dwSize = sizeof me; int hook = 0;
        if (Module32FirstW(sn, &me)) do { if (!_wcsicmp(me.szModule, L"x4c3hook.dll")) { hook = 1; break; } } while (Module32NextW(sn, &me));
        CloseHandle(sn);
        if (hook) return GM_COCKPIT_ACTIVE;
    }
    return GM_NORMAL;
}

/* ------------------------------------------------------------------ child scripts (hidden, output captured) */
typedef struct { DWORD exitCode; int timedOut, started; JVal *json; char *text; size_t textLen; } ScriptRun;

static void emit_line(const Reporter *r, ScriptRun *out, char *line, size_t n, int quiet) {
    while (n && (line[n - 1] == '\r' || line[n - 1] == '\n')) n--;
    line[n] = 0;
    if (!strncmp(line, "@@X4JSON ", 9)) {
        json_free(out->json);
        out->json = json_parse(line + 9, n - 9, NULL, 0);
        return;
    }
    if (!n) return;
    int k = MultiByteToWideChar(CP_OEMCP, 0, line, (int)n, NULL, 0);
    wchar_t *w = (wchar_t *)x4_alloc((size_t)(k + 1) * sizeof(wchar_t));
    if (!w) return;
    MultiByteToWideChar(CP_OEMCP, 0, line, (int)n, w, k);
    if (!quiet) rep(r, K_DETAIL, L"%ls", w); else log_line(L"  > %ls", w);
    x4_free(w);
}

static void script_free(ScriptRun *o) { json_free(o->json); x4_free(o->text); memset(o, 0, sizeof *o); }

static int run_script(const Settings *s, const wchar_t *script, const wchar_t *args, int timeoutSec, const Reporter *r, int quiet, ScriptRun *out) {
    memset(out, 0, sizeof *out);
    size_t cap = wcslen(s->powershellExe) + wcslen(script) + wcslen(args) + 200;
    wchar_t *cmd = (wchar_t *)x4_alloc(cap * sizeof(wchar_t));
    wchar_t qps[X4S_PATH + 4], qsc[X4S_PATH + 4];
    quote_arg(qps, X4S_PATH + 4, s->powershellExe); quote_arg(qsc, X4S_PATH + 4, script);
    _snwprintf(cmd, cap, L"%ls -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %ls %ls", qps, qsc, args);
    cmd[cap - 1] = 0;
    log_line(L"run: %ls", cmd);
    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    HANDLE rd = NULL, wr = NULL;
    if (!CreatePipe(&rd, &wr, &sa, 0)) { x4_free(cmd); return 0; }
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
    /* only these two handles are inherited */
    SIZE_T asz = 0; InitializeProcThreadAttributeList(NULL, 1, 0, &asz);
    LPPROC_THREAD_ATTRIBUTE_LIST al = (LPPROC_THREAD_ATTRIBUTE_LIST)x4_alloc(asz);
    HANDLE inh[2] = { wr, nul };
    STARTUPINFOEXW si; memset(&si, 0, sizeof si); si.StartupInfo.cb = sizeof si;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW; si.StartupInfo.wShowWindow = SW_HIDE;
    si.StartupInfo.hStdInput = nul; si.StartupInfo.hStdOutput = wr; si.StartupInfo.hStdError = wr;
    DWORD flags = CREATE_NO_WINDOW;
    if (al && InitializeProcThreadAttributeList(al, 1, 0, &asz) &&
        UpdateProcThreadAttribute(al, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inh, sizeof inh, NULL, NULL)) {
        si.lpAttributeList = al; flags |= EXTENDED_STARTUPINFO_PRESENT;
    }
    wchar_t dir[X4S_PATH]; parent_dir(dir, X4S_PATH, script);
    PROCESS_INFORMATION pi; memset(&pi, 0, sizeof pi);
    BOOL ok = CreateProcessW(NULL, cmd, NULL, NULL, TRUE, flags, NULL, dir, &si.StartupInfo, &pi);
    DWORD cerr = GetLastError();
    CloseHandle(wr);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (si.lpAttributeList) DeleteProcThreadAttributeList(al);
    x4_free(al);
    x4_free(cmd);
    if (!ok) { CloseHandle(rd); log_line(L"run failed: CreateProcess error %lu", cerr); return 0; }
    out->started = 1;
    size_t tcap = 65536; out->text = (char *)x4_alloc(tcap); out->textLen = 0;
    char line[16384]; size_t ln = 0;
    ULONGLONG t0 = GetTickCount64();
    int exited = 0;
    for (;;) {
        DWORD avail = 0;
        if (!PeekNamedPipe(rd, NULL, 0, NULL, &avail, NULL)) avail = 0;
        if (avail) {
            char buf[4096]; DWORD got = 0;
            if (!ReadFile(rd, buf, avail < sizeof buf ? avail : sizeof buf, &got, NULL) || !got) break;
            if (out->textLen + got + 1 > tcap) {
                size_t nc = tcap * 2; while (nc < out->textLen + got + 1) nc *= 2;
                char *nt = (char *)x4_alloc(nc); if (nt) { memcpy(nt, out->text, out->textLen); x4_free(out->text); out->text = nt; tcap = nc; }
            }
            if (out->textLen + got + 1 <= tcap) { memcpy(out->text + out->textLen, buf, got); out->textLen += got; out->text[out->textLen] = 0; }
            for (DWORD i = 0; i < got; i++) {
                if (buf[i] == '\n' || ln >= sizeof line - 2) { line[ln] = 0; emit_line(r, out, line, ln, quiet); ln = 0; if (buf[i] == '\n') continue; }
                line[ln++] = buf[i];
            }
            continue;
        }
        if (exited) break;
        if (WaitForSingleObject(pi.hProcess, 40) == WAIT_OBJECT_0) { exited = 1; continue; }   /* one more drain */
        if (GetTickCount64() - t0 > (ULONGLONG)timeoutSec * 1000) {
            out->timedOut = 1;
            TerminateProcess(pi.hProcess, 1);            /* our own child script, by its handle */
            WaitForSingleObject(pi.hProcess, 3000);
            break;
        }
    }
    if (ln) emit_line(r, out, line, ln, quiet);
    GetExitCodeProcess(pi.hProcess, &out->exitCode);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(rd);
    log_line(L"run: exit %lu%ls%ls", out->exitCode, out->timedOut ? L" (TIMEOUT)" : L"", out->json ? L", json ok" : L", no json");
    return 1;
}

/* builds " -Name value" into args */
static void arg_add(wchar_t *args, int cap, const wchar_t *name, const wchar_t *value) {
    wcat(args, cap, L" "); wcat(args, cap, name);
    if (value) { wchar_t q[2400]; quote_arg(q, 2400, value); wcat(args, cap, L" "); wcat(args, cap, q); }
}

/* ------------------------------------------------------------------ detached start through WMI */
static const GUID X_CLSID_WbemLocator = { 0x4590f811, 0x1d3a, 0x11d0, { 0x89, 0x1f, 0x00, 0xaa, 0x00, 0x4b, 0x2e, 0x24 } };
static const GUID X_IID_IWbemLocator = { 0xdc12a687, 0x737f, 0x11cf, { 0x88, 0x4d, 0x00, 0xaa, 0x00, 0x4b, 0x2e, 0x24 } };

int wmi_create_process(const wchar_t *cmdline, const wchar_t *cwd, int hidden, DWORD *pid, wchar_t *err, int errCap) {
    *pid = 0; if (errCap > 0) err[0] = 0;
    HRESULT hrInit = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IWbemLocator *loc = NULL; IWbemServices *svc = NULL;
    IWbemClassObject *cls = NULL, *inDef = NULL, *in = NULL, *outp = NULL, *suCls = NULL, *su = NULL;
    BSTR ns = SysAllocString(L"ROOT\\CIMV2"), cn = SysAllocString(L"Win32_Process"), mn = SysAllocString(L"Create"), sn = SysAllocString(L"Win32_ProcessStartup");
    int ok = 0; HRESULT hr; const wchar_t *stage = L"";
    VARIANT v;
#define WMI_STEP(name, call) do { stage = name; hr = (call); if (FAILED(hr)) goto done; } while (0)
    WMI_STEP(L"CoCreateInstance(WbemLocator)", CoCreateInstance(&X_CLSID_WbemLocator, NULL, CLSCTX_INPROC_SERVER, &X_IID_IWbemLocator, (void **)&loc));
    WMI_STEP(L"ConnectServer(ROOT\\CIMV2)", IWbemLocator_ConnectServer(loc, ns, NULL, NULL, NULL, 0, NULL, NULL, &svc));
    WMI_STEP(L"CoSetProxyBlanket", CoSetProxyBlanket((IUnknown *)svc, RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE, NULL, RPC_C_AUTHN_LEVEL_CALL, RPC_C_IMP_LEVEL_IMPERSONATE, NULL, EOAC_NONE));
    WMI_STEP(L"GetObject(Win32_Process)", IWbemServices_GetObject(svc, cn, 0, NULL, &cls, NULL));
    WMI_STEP(L"GetMethod(Create)", IWbemClassObject_GetMethod(cls, L"Create", 0, &inDef, NULL));
    WMI_STEP(L"SpawnInstance(in)", IWbemClassObject_SpawnInstance(inDef, 0, &in));
    VariantInit(&v); v.vt = VT_BSTR; v.bstrVal = SysAllocString(cmdline);
    hr = IWbemClassObject_Put(in, L"CommandLine", 0, &v, 0); VariantClear(&v); stage = L"Put(CommandLine)"; if (FAILED(hr)) goto done;
    if (cwd && *cwd) { VariantInit(&v); v.vt = VT_BSTR; v.bstrVal = SysAllocString(cwd); hr = IWbemClassObject_Put(in, L"CurrentDirectory", 0, &v, 0); VariantClear(&v); stage = L"Put(CurrentDirectory)"; if (FAILED(hr)) goto done; }
    if (hidden) {
        WMI_STEP(L"GetObject(Win32_ProcessStartup)", IWbemServices_GetObject(svc, sn, 0, NULL, &suCls, NULL));
        WMI_STEP(L"SpawnInstance(startup)", IWbemClassObject_SpawnInstance(suCls, 0, &su));
        VariantInit(&v); v.vt = VT_I4; v.lVal = 0;   /* SW_HIDE */
        WMI_STEP(L"Put(ShowWindow)", IWbemClassObject_Put(su, L"ShowWindow", 0, &v, 0));
        VariantInit(&v); v.vt = VT_UNKNOWN; v.punkVal = (IUnknown *)su; IWbemClassObject_AddRef(su);
        hr = IWbemClassObject_Put(in, L"ProcessStartupInformation", 0, &v, 0); VariantClear(&v); stage = L"Put(ProcessStartupInformation)"; if (FAILED(hr)) goto done;
    }
    WMI_STEP(L"ExecMethod(Win32_Process.Create)", IWbemServices_ExecMethod(svc, cn, mn, 0, NULL, in, &outp, NULL));
    {
        VARIANT rv, pv; VariantInit(&rv); VariantInit(&pv);
        long ret = -1;
        if (SUCCEEDED(IWbemClassObject_Get(outp, L"ReturnValue", 0, &rv, NULL, NULL)) && (rv.vt == VT_I4 || rv.vt == VT_UI4)) ret = rv.lVal;
        if (SUCCEEDED(IWbemClassObject_Get(outp, L"ProcessId", 0, &pv, NULL, NULL)) && (pv.vt == VT_I4 || pv.vt == VT_UI4)) *pid = (DWORD)pv.lVal;
        VariantClear(&rv); VariantClear(&pv);
        if (ret != 0) { _snwprintf(err, errCap, L"Win32_Process.Create returned %ld", ret); stage = NULL; hr = S_OK; goto done; }
        ok = 1;
    }
done:
    if (!ok && stage && errCap > 0) { _snwprintf(err, errCap, L"%ls failed (0x%08lx)", stage, (unsigned long)hr); }
    if (errCap > 0) err[errCap - 1] = 0;
#undef WMI_STEP
    if (su) IWbemClassObject_Release(su);
    if (suCls) IWbemClassObject_Release(suCls);
    if (outp) IWbemClassObject_Release(outp);
    if (in) IWbemClassObject_Release(in);
    if (inDef) IWbemClassObject_Release(inDef);
    if (cls) IWbemClassObject_Release(cls);
    if (svc) IWbemServices_Release(svc);
    if (loc) IWbemLocator_Release(loc);
    SysFreeString(ns); SysFreeString(cn); SysFreeString(mn); SysFreeString(sn);
    if (SUCCEEDED(hrInit)) CoUninitialize();
    log_line(L"wmi create%ls: %ls -> %ls pid %lu %ls", hidden ? L" (hidden)" : L"", cmdline, ok ? L"ok" : L"FAILED", *pid, ok ? L"" : err);
    return ok;
}

/* ------------------------------------------------------------------ status */
static void kit_path(const Settings *s, const wchar_t *rel, wchar_t *out) { path_join(out, X4S_PATH, s->rCockpitDir, rel); }

void status_quick(const Settings *s, Status *st) {
    wchar_t p[X4S_PATH], q[X4S_PATH];
    st->gameExePresent = file_exists(s->rGameExe);
    st->gamePid = find_game_pid(s->rGameExe);
    st->gameRunning = st->gamePid != 0;
    st->gameMode = st->gameRunning ? game_mode(s, st->gamePid) : GM_NONE;
    kit_path(s, L"cockpit.ps1", p); kit_path(s, L"cockpit-launch.ps1", q);
    st->kitPresent = file_exists(p) && file_exists(q);
    kit_path(s, L"native\\out\\launcher.exe", p); kit_path(s, L"native\\out\\x4c3hook.dll", q);
    st->hookMissing[0] = 0;
    if (!file_exists(p)) wcopy(st->hookMissing, X4S_PATH, p);
    else if (!file_exists(q)) wcopy(st->hookMissing, X4S_PATH, q);
    st->hookPresent = !st->hookMissing[0];
    path_join(p, X4S_PATH, s->rCompanionDir, L"watch_x4.ps1");
    st->companionInstalled = file_exists(p);
    st->serverUp = port_open(s->rPort, 400);
    st->watcherRunning = mutex_exists(s->companionMutex);
    st->dashWindow = find_window_prefix(s->rWindowTitle);
}

static void join_arr(const JVal *a, wchar_t *out, int cap, const wchar_t *sep, int max) {
    out[0] = 0;
    if (!a || a->t != J_ARR) return;
    for (int i = 0; i < a->n && i < max; i++) {
        if (a->items[i]->t != J_STR) continue;
        if (out[0]) wcat(out, cap, sep);
        wcat(out, cap, a->items[i]->str);
    }
}

static void cockpit_common_args(const Settings *s, wchar_t *args, int cap) {
    if (s->cockpitSettingsFile[0]) arg_add(args, cap, L"-SettingsFile", s->cockpitSettingsFile);
}

typedef struct { const Settings *s; Status *st; } SlowCtx;

static DWORD WINAPI slow_cfg(LPVOID p) {
    SlowCtx *c = (SlowCtx *)p; const Settings *s = c->s; Status *st = c->st;
    HRESULT hi = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    wchar_t sc[X4S_PATH], args[3000] = L"status -Json";
    kit_path(s, L"cockpit.ps1", sc);
    cockpit_common_args(s, args, 3000);
    ScriptRun r;
    if (!file_exists(sc)) { st->cfgKnown = 0; wcopy(st->cfgError, 300, sc); }
    else if (run_script(s, sc, args, 60, NULL, 1, &r) && r.json) {
        const wchar_t *res = jstr(r.json, L"result", L"");
        if (!wcscmp(res, L"on") || !wcscmp(res, L"off")) {
            st->cfgKnown = 1;
            st->cfgOn = !wcscmp(jstr(r.json, L"mode", L""), L"on");
            st->cfgValuesMatch = jbool(r.json, L"valuesMatch", 0);
            st->cfgFlagPresent = jbool(r.json, L"flagPresent", 0);
            wcopy(st->cfgSince, 40, jstr(r.json, L"since", L""));
            JVal *mm = jget(r.json, L"mismatch");
            st->cfgMismatchCount = mm && mm->t == J_ARR ? mm->n : 0;
            join_arr(mm, st->cfgMismatch, 200, L", ", 8);
        } else { st->cfgKnown = 0; wcopy(st->cfgError, 300, jstr(r.json, L"message", res)); }
        script_free(&r);
    } else { st->cfgKnown = 0; wfmt(st->cfgError, 300, L"cockpit.ps1 status: exit %lu", r.exitCode); script_free(&r); }
    if (SUCCEEDED(hi)) CoUninitialize();
    return 0;
}

static void layout_from_json(const JVal *j, Status *st) {
    JVal *tr_ = jget(j, L"triple");
    st->layoutKnown = tr_ != NULL;
    st->layoutOk = jbool(tr_, L"ok", 0);
    wcopy(st->layoutSummary, 300, jstr(j, L"summary", L"?"));
    join_arr(jget(tr_, L"problems"), st->layoutProblem, 600, L" | ", 4);
    st->layoutGeo = 0;
    JVal *notes = jget(tr_, L"notes");
    if (notes && notes->t == J_ARR) for (int i = 0; i < notes->n; i++)
        if (notes->items[i]->t == J_STR && wcsstr(notes->items[i]->str, L"recognised by geometry")) st->layoutGeo = 1;
}

static void layout_args(const Settings *s, wchar_t *args, int cap) {
    wcopy(args, cap, L"-Json");
    cockpit_common_args(s, args, cap);
    if (s->monitorsJson[0]) arg_add(args, cap, L"-MonitorsJson", s->monitorsJson);
}

static DWORD WINAPI slow_layout(LPVOID p) {
    SlowCtx *c = (SlowCtx *)p; const Settings *s = c->s; Status *st = c->st;
    if (s->rect[0]) {
        st->layoutKnown = 1; st->layoutFromRect = 1; st->layoutOk = rect_valid(s->rect);
        wcopy(st->layoutSummary, 300, s->rect);
        return 0;
    }
    wchar_t sc[X4S_PATH], args[3000];
    kit_path(s, L"x4cockpit3.ps1", sc);
    layout_args(s, args, 3000);
    ScriptRun r;
    if (!file_exists(sc)) { st->layoutKnown = 0; wcopy(st->layoutProblem, 600, sc); return 0; }
    if (run_script(s, sc, args, 60, NULL, 1, &r) && r.json && jget(r.json, L"triple")) layout_from_json(r.json, st);
    else { st->layoutKnown = 0; wfmt(st->layoutProblem, 600, L"x4cockpit3.ps1: %ls", r.json ? jstr(r.json, L"error", L"no result") : L"no result"); }
    script_free(&r);
    return 0;
}

void status_slow(const Settings *s, Status *st) {
    status_quick(s, st);
    SlowCtx c = { s, st };
    HANDLE t[2];
    t[0] = CreateThread(NULL, 0, slow_cfg, &c, 0, NULL);
    t[1] = CreateThread(NULL, 0, slow_layout, &c, 0, NULL);
    for (int i = 0; i < 2; i++) if (t[i]) { WaitForSingleObject(t[i], INFINITE); CloseHandle(t[i]); }
    st->slowDone = 1;
}

void status_lines(const Status *st, const Settings *s, wchar_t L_[5][700], int col[5]) {
    /* 0 game */
    if (!st->gameExePresent && !st->gameRunning) { wfmt(L_[0], 700, tr(S_GAME_NOT_FOUND), s->rGameExe); col[0] = C_BAD; }
    else if (!st->gameRunning) { wcopy(L_[0], 700, tr(S_GAME_NOT_RUNNING)); col[0] = C_IDLE; }
    else if (st->gameMode == GM_COCKPIT_ACTIVE) { wfmt(L_[0], 700, tr(S_GAME_RUNNING_COCKPIT), st->gamePid); col[0] = C_OK; }
    else if (st->gameMode == GM_COCKPIT_NOHOOK) { wfmt(L_[0], 700, tr(S_GAME_RUNNING_COCKPIT_NOHOOK), st->gamePid); col[0] = C_WARN; }
    else { wfmt(L_[0], 700, tr(S_GAME_RUNNING_NORMAL), st->gamePid); col[0] = C_INFO; }
    /* 1 config */
    if (!st->kitPresent) { wfmt(L_[1], 700, tr(S_CFG_KIT_MISSING), s->rCockpitDir); col[1] = C_WARN; }
    else if (!st->slowDone) { wcopy(L_[1], 700, tr(S_CHECKING)); col[1] = C_IDLE; }
    else if (!st->cfgKnown) { wfmt(L_[1], 700, tr(S_CFG_UNKNOWN), st->cfgError); col[1] = C_WARN; }
    else if (st->cfgOn && st->cfgValuesMatch) { wfmt(L_[1], 700, tr(S_CFG_ON), st->cfgSince); col[1] = C_OK; }
    else if (st->cfgOn) { wfmt(L_[1], 700, tr(S_CFG_ON_DIFF), st->cfgSince, st->cfgMismatch); col[1] = C_WARN; }
    else { wcopy(L_[1], 700, tr(S_CFG_OFF)); col[1] = C_INFO; if (st->cfgFlagPresent) { wcat(L_[1], 700, tr(S_CFG_FLAG_STALE)); col[1] = C_WARN; } }
    /* 2 monitors */
    if (!st->slowDone) { wcopy(L_[2], 700, tr(S_CHECKING)); col[2] = C_IDLE; }
    else if (st->layoutFromRect) { wfmt(L_[2], 700, tr(S_MON_RECT), st->layoutSummary); col[2] = st->layoutOk ? C_INFO : C_BAD; }
    else if (!st->layoutKnown) { wfmt(L_[2], 700, tr(S_MON_UNKNOWN), st->layoutProblem); col[2] = C_WARN; }
    else if (st->layoutOk) { wfmt(L_[2], 700, tr(st->layoutGeo ? S_MON_OK_GEO : S_MON_OK), st->layoutSummary); col[2] = C_OK; }
    else { wfmt(L_[2], 700, tr(S_MON_BAD), st->layoutSummary, st->layoutProblem); col[2] = C_BAD; }
    /* 3 dashboard */
    if (!st->companionInstalled) { wfmt(L_[3], 700, tr(S_DASH_NOT_INSTALLED), s->rCompanionDir); col[3] = C_IDLE; }
    else {
        wchar_t a[120];
        wfmt(a, 120, tr(st->serverUp ? S_DASH_SERVER_UP : S_DASH_SERVER_DOWN), s->rPort);
        wfmt(L_[3], 700, L"%ls  ·  %ls  ·  %ls", a, tr(st->watcherRunning ? S_DASH_WATCHER_ON : S_DASH_WATCHER_OFF), tr(st->dashWindow ? S_DASH_WINDOW_OPEN : S_DASH_WINDOW_NONE));
        col[3] = st->serverUp ? C_OK : C_IDLE;
    }
    /* 4 hook */
    if (!st->kitPresent) { wfmt(L_[4], 700, tr(S_CFG_KIT_MISSING), s->rCockpitDir); col[4] = C_WARN; }
    else if (st->hookPresent) { wcopy(L_[4], 700, tr(S_HOOK_OK)); col[4] = C_OK; }
    else { wfmt(L_[4], 700, tr(S_HOOK_MISSING), st->hookMissing); col[4] = C_BAD; }
}

void status_card(const Status *st, int mode, wchar_t *out, int cap, int *color) {
    if (st->gameRunning) {
        int mine = mode == MODE_COCKPIT ? (st->gameMode == GM_COCKPIT_ACTIVE || st->gameMode == GM_COCKPIT_NOHOOK) : st->gameMode == GM_NORMAL;
        wcopy(out, cap, tr(mine ? S_CARD_RUNNING : S_CARD_CLOSE_FIRST)); *color = mine ? C_OK : C_WARN; return;
    }
    if (!st->gameExePresent) { wfmt(out, cap, tr(S_CARD_NOT_READY), tr(S_R_GAME)); *color = C_BAD; return; }
    if (mode == MODE_COCKPIT) {
        if (!st->kitPresent) { wfmt(out, cap, tr(S_CARD_NOT_READY), tr(S_R_KIT)); *color = C_BAD; return; }
        if (!st->hookPresent) { wfmt(out, cap, tr(S_CARD_NOT_READY), tr(S_R_HOOK)); *color = C_BAD; return; }
        if (!st->slowDone) { wcopy(out, cap, tr(S_CHECKING)); *color = C_IDLE; return; }
        if (st->layoutKnown && !st->layoutOk) { wfmt(out, cap, tr(S_CARD_NOT_READY), tr(S_R_LAYOUT)); *color = C_BAD; return; }
        wcopy(out, cap, tr(S_CARD_READY)); *color = C_OK; return;
    }
    if (!st->companionInstalled) { wcopy(out, cap, tr(S_CARD_SINGLE_NODASH)); *color = C_INFO; return; }
    wcopy(out, cap, tr(st->watcherRunning ? S_CARD_SINGLE_WATCHER : S_CARD_SINGLE_SELF)); *color = C_OK;
}

JVal *status_json(const Status *st, const Settings *s) {
    JVal *o = jnew(J_OBJ), *g = jnew(J_OBJ), *c = jnew(J_OBJ), *l = jnew(J_OBJ), *d = jnew(J_OBJ), *h = jnew(J_OBJ), *p = jnew(J_OBJ);
    jset_str(o, L"tool", L"x4switch"); jset_str(o, L"version", X4S_VERSION); jset_str(o, L"language", i18n_lang());
    jset_str(p, L"exeDir", s->exeDir); jset_str(p, L"settings", s->settingsPath); jset_str(p, L"logDir", s->logDir);
    jset_str(p, L"gameExe", s->rGameExe); jset_str(p, L"cockpitDir", s->rCockpitDir); jset_str(p, L"companionDir", s->rCompanionDir);
    jset_str(p, L"launcherLogDir", s->rLauncherLogDir);
    jset(o, L"paths", p);
    jset_bool(g, L"exePresent", st->gameExePresent); jset_bool(g, L"running", st->gameRunning); jset_num(g, L"pid", st->gamePid);
    jset_str(g, L"startedAs", st->gameMode == GM_COCKPIT_ACTIVE ? L"cockpit" : st->gameMode == GM_COCKPIT_NOHOOK ? L"cockpit-nohook" : st->gameMode == GM_NORMAL ? L"normal" : L"");
    jset(o, L"game", g);
    jset_bool(c, L"kitPresent", st->kitPresent); jset_bool(c, L"known", st->cfgKnown);
    jset_str(c, L"mode", !st->cfgKnown ? L"unknown" : st->cfgOn ? L"on" : L"off");
    jset_bool(c, L"valuesMatch", st->cfgValuesMatch); jset_str(c, L"since", st->cfgSince); jset_str(c, L"mismatch", st->cfgMismatch);
    jset_bool(c, L"flagPresent", st->cfgFlagPresent); jset_str(c, L"error", st->cfgError);
    jset(o, L"config", c);
    jset_bool(l, L"known", st->layoutKnown); jset_bool(l, L"ok", st->layoutOk); jset_bool(l, L"byGeometry", st->layoutGeo);
    jset_bool(l, L"fromRect", st->layoutFromRect); jset_str(l, L"summary", st->layoutSummary); jset_str(l, L"problems", st->layoutProblem);
    jset(o, L"layout", l);
    jset_bool(d, L"companionInstalled", st->companionInstalled); jset_num(d, L"port", s->rPort); jset_bool(d, L"serverUp", st->serverUp);
    jset_bool(d, L"watcherRunning", st->watcherRunning); jset_bool(d, L"windowOpen", st->dashWindow);
    jset(o, L"dashboard", d);
    jset_bool(h, L"present", st->hookPresent); jset_str(h, L"missing", st->hookMissing);
    jset(o, L"hook", h);
    wchar_t lines[5][700]; int col[5];
    status_lines(st, s, lines, col);
    JVal *ls = jnew(J_ARR);
    for (int i = 0; i < 5; i++) { JVal *x = jnew(J_STR); x->str = (wchar_t *)x4_alloc((wcslen(lines[i]) + 1) * sizeof(wchar_t)); wcscpy(x->str, lines[i]); jpush(ls, x); }
    jset(o, L"lines", ls);
    wchar_t card[300]; int cc;
    status_card(st, MODE_COCKPIT, card, 300, &cc); jset_str(o, L"cockpitCard", card);
    status_card(st, MODE_SINGLE, card, 300, &cc); jset_str(o, L"singleCard", card);
    return o;
}

/* ------------------------------------------------------------------ actions */
static void res_set(ActionResult *res, int code, const wchar_t *result, const wchar_t *summary) {
    res->code = code; wcopy(res->result, 64, result); if (summary) wcopy(res->summary, 800, summary);
}

static int run_kit(const Settings *s, const wchar_t *script, const wchar_t *args, int timeout, const Reporter *r, ScriptRun *out, ActionResult *res) {
    wchar_t sc[X4S_PATH]; kit_path(s, script, sc);
    if (!run_script(s, sc, args, timeout, r, 0, out)) {
        wchar_t m[600]; wfmt(m, 600, tr(M_SCRIPT_FAILED), script, (DWORD)0xFFFFFFFF);
        rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, L"script-failed", m); return 0;
    }
    if (out->timedOut) {
        wchar_t m[600]; wfmt(m, 600, tr(M_SCRIPT_TIMEOUT), script, timeout);
        rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, L"script-timeout", m); script_free(out); return 0;
    }
    if (!out->json) {
        wchar_t m[600]; wfmt(m, 600, tr(M_SCRIPT_FAILED), script, out->exitCode);
        rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, L"script-no-result", m); script_free(out); return 0;
    }
    return 1;
}

static int check_layout(const Settings *s, const Reporter *r, ActionResult *res, int *ok) {
    wchar_t args[3000]; layout_args(s, args, 3000);
    ScriptRun o;
    rep(r, K_STEP, L"%ls", tr(M_LAYOUT_CHECK));
    if (!run_kit(s, L"x4cockpit3.ps1", args, 90, r, &o, res)) return 0;
    Status st; memset(&st, 0, sizeof st);
    if (!jget(o.json, L"triple")) {
        wchar_t m[600]; wfmt(m, 600, tr(M_SCRIPT_FAILED), L"x4cockpit3.ps1", o.exitCode);
        rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, L"layout-unknown", m); script_free(&o); return 0;
    }
    layout_from_json(o.json, &st);
    *ok = st.layoutOk;
    wchar_t m[1200];
    if (st.layoutOk) { wfmt(m, 1200, tr(M_LAYOUT_OK), st.layoutSummary); rep(r, K_OK, L"%ls", m); res_set(res, RC_OK, L"layout-ok", m); }
    else {
        wchar_t probs[900]; join_arr(jget(jget(o.json, L"triple"), L"problems"), probs, 900, L" | ", 6);
        wfmt(m, 1200, tr(M_LAYOUT_BAD), probs); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"layout-mismatch", m);
    }
    script_free(&o);
    return 1;
}

typedef struct { int opened, present, other, failed, gameMissing; wchar_t last[700]; } DashOut;

static void dash_parse(const ScriptRun *o, DashOut *d) {
    memset(d, 0, sizeof *d);
    const char *t = o->text ? o->text : "";
    d->opened = strstr(t, "window opened") != NULL;
    d->present = strstr(t, "window present") != NULL;
    d->other = strstr(t, "another watcher is already running") != NULL;
    d->gameMissing = strstr(t, "game not running") != NULL;
    d->failed = strstr(t, "server did NOT answer") != NULL || strstr(t, "not opening one") != NULL || strstr(t, "error:") != NULL || strstr(t, "skip flag") != NULL;
    /* the last non-empty output line (the watcher's verdict) */
    const char *end = t + strlen(t), *e = end;
    while (e > t && (e[-1] == '\n' || e[-1] == '\r')) e--;
    const char *b = e; while (b > t && b[-1] != '\n') b--;
    int n = (int)(e - b); if (n > 690) { b = e - 690; n = 690; }
    MultiByteToWideChar(CP_OEMCP, 0, b, n, d->last, 699);
    d->last[n < 699 ? n : 699] = 0;
}

static void companion_args(const Settings *s, wchar_t *args, int cap, const wchar_t *mode, int dry) {
    wcopy(args, cap, mode);
    if (dry) wcat(args, cap, L" -DryRun");
    arg_add(args, cap, L"-GameExe", s->rGameExe);
    if (s->companionStateDir[0]) arg_add(args, cap, L"-StateDir", s->rCompanionState);
    if (s->companionLogDir[0]) arg_add(args, cap, L"-LogDir", s->companionLogDir);
    if (wcscmp(s->companionMutex, L"Local\\X4CompanionWatcher")) arg_add(args, cap, L"-MutexName", s->companionMutex);
    if (s->dashboardPort > 0) { wchar_t pt[16]; wfmt(pt, 16, L"%d", s->dashboardPort); arg_add(args, cap, L"-Port", pt); }
}

static int wait_dashboard(const Settings *s, int seconds) {
    ULONGLONG t0 = GetTickCount64();
    for (;;) {
        if (port_open(s->rPort, 300) && find_window_prefix(s->rWindowTitle)) return 1;
        if (GetTickCount64() - t0 > (ULONGLONG)seconds * 1000) return 0;
        Sleep(500);
    }
}

/* returns 1 if the dashboard is (now) open */
static int run_companion(const Settings *s, const wchar_t *mode, int dry, const Reporter *r) {
    wchar_t sc[X4S_PATH], args[3000];
    path_join(sc, X4S_PATH, s->rCompanionDir, L"watch_x4.ps1");
    companion_args(s, args, 3000, mode, dry);
    ScriptRun o;
    if (!run_script(s, sc, args, 150, r, 0, &o)) { wchar_t m[600]; wfmt(m, 600, tr(M_SCRIPT_FAILED), L"watch_x4.ps1", (DWORD)0xFFFFFFFF); rep(r, K_WARN, tr(M_DASH_FAILED), m); return 0; }
    DashOut d; dash_parse(&o, &d);
    int okk = 0;
    if (dry) rep(r, K_INFO, tr(M_DASH_DRY), d.last);
    else if (d.opened) { rep(r, K_OK, L"%ls", tr(M_DASH_OPENED)); okk = 1; }
    else if (d.present) { rep(r, K_OK, L"%ls", tr(M_DASH_PRESENT)); okk = 1; }
    else if (d.other) {
        rep(r, K_INFO, L"%ls", tr(M_DASH_WATCHER));
        if (wait_dashboard(s, s->dashboardWaitSeconds)) { rep(r, K_OK, L"%ls", tr(M_DASH_WAIT_OK)); okk = 1; }
        else rep(r, K_WARN, tr(M_DASH_WAIT_TIMEOUT), s->dashboardWaitSeconds);
    } else rep(r, K_WARN, tr(M_DASH_FAILED), o.timedOut ? L"timeout" : d.last);
    script_free(&o);
    return okk;
}

void action_mode(const Settings *s, int mode, int start, int dryRun, const Reporter *r, ActionResult *res) {
    memset(res, 0, sizeof *res);
    wchar_t m[1500], args[3000];
    log_line(L"action: mode=%ls start=%d dry=%d", mode == MODE_COCKPIT ? L"cockpit" : L"single", start, dryRun);
    if (dryRun) rep(r, K_WARN, L"%ls", tr(M_DRY_RUN));
    if (!file_exists(s->rGameExe)) { wfmt(m, 1500, tr(M_GAME_EXE_MISSING), s->rGameExe); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"refused-game-missing", m); return; }
    DWORD pid = find_game_pid(s->rGameExe);
    if (pid) { wfmt(m, 1500, tr(M_GAME_RUNNING), pid); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"refused-game-running", m); res->gamePid = pid; return; }
    wchar_t sc[X4S_PATH]; kit_path(s, L"cockpit.ps1", sc);
    int kit = file_exists(sc);

    if (mode == MODE_COCKPIT) {
        wchar_t lp[X4S_PATH]; kit_path(s, L"cockpit-launch.ps1", lp);
        if (!kit || !file_exists(lp)) { wfmt(m, 1500, tr(M_KIT_MISSING), s->rCockpitDir); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"refused-kit-missing", m); return; }
        if (start) {
            wchar_t a[X4S_PATH], b[X4S_PATH]; kit_path(s, L"native\\out\\launcher.exe", a); kit_path(s, L"native\\out\\x4c3hook.dll", b);
            const wchar_t *miss = !file_exists(a) ? a : !file_exists(b) ? b : NULL;
            if (miss) { wfmt(m, 1500, tr(M_HOOK_MISSING), miss); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"refused-hook-missing", m); return; }
        }
        if (s->rect[0]) {
            if (!rect_valid(s->rect)) { wfmt(m, 1500, tr(M_RECT_BAD), s->rect); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"refused-rect", m); return; }
            rep(r, K_INFO, tr(M_RECT_USED), s->rect);
        } else {
            int ok = 0;
            if (!check_layout(s, r, res, &ok)) return;
            if (!ok) { wcopy(res->result, 64, L"refused-layout"); return; }
        }
        /* config.xml -> cockpit values (the kit makes the backup, writes only its keys, sets the companion flag) */
        wcopy(args, 3000, L"on -Json"); if (dryRun) wcat(args, 3000, L" -WhatIf");
        cockpit_common_args(s, args, 3000);
        ScriptRun o;
        if (!run_kit(s, L"cockpit.ps1", args, 90, r, &o, res)) return;
        const wchar_t *cr = jstr(o.json, L"result", L"");
        if (!wcscmp(cr, L"on") || !wcscmp(cr, L"whatif")) {
            const wchar_t *bk = jstr(o.json, L"backup", L"");
            wchar_t what[X4S_PATH + 40];
            if (!wcscmp(cr, L"whatif")) wfmt(what, X4S_PATH + 40, L"WhatIf, %d change(s)", (int)jnum(o.json, L"changed", 0));
            else if (bk[0]) wfmt(what, X4S_PATH + 40, L"backup %ls", bk);
            else wcopy(what, X4S_PATH + 40, L"already set");
            wfmt(m, 1500, tr(M_CFG_ON), what); rep(r, K_OK, L"%ls", m);
        } else if (!wcsncmp(cr, L"refused", 7)) {
            wfmt(m, 1500, tr(M_CFG_REFUSED), jstr(o.json, L"message", cr)); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, cr, m); script_free(&o); return;
        } else {
            wfmt(m, 1500, tr(M_CFG_ERROR), jstr(o.json, L"message", cr)); rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, L"config-error", m); script_free(&o); return;
        }
        script_free(&o);
        if (!start) { rep(r, K_OK, L"%ls", tr(M_SWITCHED_COCKPIT)); res_set(res, RC_OK, dryRun ? L"whatif" : L"switched", tr(M_SWITCHED_COCKPIT)); return; }

        /* start through the kit's launcher (it starts launcher.exe detached via WMI and reports the hook result) */
        wcopy(args, 3000, L"-Json");
        if (dryRun) wcat(args, 3000, L" -WhatIf");
        cockpit_common_args(s, args, 3000);
        if (s->gameArgs[0]) { wchar_t q[2400]; quote_arg(q, 2400, s->gameArgs); wcat(args, 3000, L" -GameArgs:"); wcat(args, 3000, q); }
        if (s->rect[0]) arg_add(args, 3000, L"-Rect", s->rect);
        else if (s->monitorsJson[0]) arg_add(args, 3000, L"-MonitorsJson", s->monitorsJson);
        if (s->cockpitLogDir[0]) arg_add(args, 3000, L"-LogDir", s->cockpitLogDir);
        { wchar_t ws_[16]; wfmt(ws_, 16, L"%d", s->launchWaitSeconds); arg_add(args, 3000, L"-WaitSeconds", ws_); }
        rep(r, K_STEP, L"%ls", tr(M_LAUNCHING_COCKPIT));
        if (!run_kit(s, L"cockpit-launch.ps1", args, s->launchWaitSeconds + 60, r, &o, res)) return;
        const wchar_t *lr = jstr(o.json, L"result", L"");
        wchar_t why[1000]; join_arr(jget(o.json, L"reason"), why, 1000, L"; ", 8);
        if (!why[0]) join_arr(jget(o.json, L"problems"), why, 1000, L"; ", 6);
        if (!why[0]) wcopy(why, 1000, jstr(o.json, L"message", lr));
        res->gamePid = (DWORD)jnum(o.json, L"gamePid", 0);
        if (!wcscmp(lr, L"active")) { wfmt(m, 1500, tr(M_HOOK_ACTIVE), res->gamePid); rep(r, K_OK, L"%ls", m); res_set(res, RC_OK, L"active", m); res->hookActive = 1; rep(r, K_INFO, L"%ls", tr(M_KIT_KEEPS_GAME_SAFE)); }
        else if (!wcscmp(lr, L"whatif")) { wfmt(m, 1500, tr(M_DRY_GAME_CMD), jstr(o.json, L"command", L"?")); rep(r, K_INFO, L"%ls", m); res_set(res, RC_OK, L"whatif", m); }
        else if (!wcscmp(lr, L"failsafe")) { wfmt(m, 1500, tr(M_HOOK_FAILSAFE), why); rep(r, K_WARN, L"%ls", m); res_set(res, RC_FAILSAFE, L"failsafe", m); }
        else if (!wcsncmp(lr, L"refused", 7)) { wchar_t t2[1100]; wfmt(t2, 1100, L"%ls (%ls)", lr, why); wfmt(m, 1500, tr(M_LAUNCH_REFUSED), t2); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, lr, m); }
        else { wchar_t t2[1100]; wfmt(t2, 1100, L"%ls (%ls)", lr, why); wfmt(m, 1500, tr(M_LAUNCH_ERROR), t2); rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, lr[0] ? lr : L"launch-error", m); }
        script_free(&o);
        return;
    }

    /* ---- single monitor + dashboard */
    if (kit) {
        wcopy(args, 3000, L"off -Json"); if (dryRun) wcat(args, 3000, L" -WhatIf");
        cockpit_common_args(s, args, 3000);
        ScriptRun o;
        if (!run_kit(s, L"cockpit.ps1", args, 90, r, &o, res)) return;
        const wchar_t *cr = jstr(o.json, L"result", L"");
        if (!wcscmp(cr, L"off")) {
            const wchar_t *bk = jstr(o.json, L"backup", L""); wchar_t what[X4S_PATH + 40];
            if (bk[0]) wfmt(what, X4S_PATH + 40, L"backup %ls", bk); else wcopy(what, X4S_PATH + 40, L"no value had to change");
            wfmt(m, 1500, tr(M_CFG_OFF), what); rep(r, K_OK, L"%ls", m);
        }
        else if (!wcscmp(cr, L"already-off")) rep(r, K_OK, L"%ls", tr(M_CFG_ALREADY_OFF));
        else if (!wcscmp(cr, L"whatif")) { wchar_t w2[80]; wfmt(w2, 80, L"WhatIf, %d change(s)", (int)jnum(o.json, L"changed", 0)); wfmt(m, 1500, tr(M_CFG_OFF), w2); rep(r, K_INFO, L"%ls", m); }
        else if (!wcsncmp(cr, L"refused", 7)) { wfmt(m, 1500, tr(M_CFG_REFUSED), jstr(o.json, L"message", cr)); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, cr, m); script_free(&o); return; }
        else { wfmt(m, 1500, tr(M_CFG_ERROR), jstr(o.json, L"message", cr)); rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, L"config-error", m); script_free(&o); return; }
        script_free(&o);
    } else rep(r, K_WARN, L"%ls", tr(M_SKIP_KIT_SINGLE));
    if (!start) { rep(r, K_OK, L"%ls", tr(M_SWITCHED_SINGLE)); res_set(res, RC_OK, dryRun ? L"whatif" : L"switched", tr(M_SWITCHED_SINGLE)); return; }

    wchar_t cmd[X4S_PATH + 1100], q[X4S_PATH + 4];
    quote_arg(q, X4S_PATH + 4, s->rGameExe);
    if (s->gameArgs[0]) wfmt(cmd, X4S_PATH + 1100, L"%ls %ls", q, s->gameArgs); else wcopy(cmd, X4S_PATH + 1100, q);
    HANDLE gh = NULL;
    if (dryRun) { wfmt(m, 1500, tr(M_DRY_GAME_CMD), cmd); rep(r, K_INFO, L"%ls", m); res_set(res, RC_OK, L"whatif", m); }
    else {
        rep(r, K_STEP, tr(M_STARTING_GAME), cmd);
        DWORD gp = 0; wchar_t err[400];
        if (!wmi_create_process(cmd, s->rGameDir, 0, &gp, err, 400)) { wfmt(m, 1500, tr(M_GAME_START_FAILED), err); rep(r, K_ERR, L"%ls", m); res_set(res, RC_ERROR, L"start-failed", m); return; }
        res->gamePid = gp;
        gh = OpenProcess(SYNCHRONIZE, FALSE, gp);
        wfmt(m, 1500, tr(M_GAME_STARTED), gp); rep(r, K_OK, L"%ls", m); res_set(res, RC_OK, L"started", m);
    }
    /* dashboard */
    wchar_t wsc[X4S_PATH]; path_join(wsc, X4S_PATH, s->rCompanionDir, L"watch_x4.ps1");
    if (!file_exists(wsc)) rep(r, K_INFO, tr(M_DASH_NONE), s->rCompanionDir);
    else if (mutex_exists(s->companionMutex)) {
        rep(r, K_INFO, L"%ls", tr(M_DASH_WATCHER));
        if (!dryRun) {
            if (wait_dashboard(s, s->dashboardWaitSeconds)) rep(r, K_OK, L"%ls", tr(M_DASH_WAIT_OK));
            else rep(r, K_WARN, tr(M_DASH_WAIT_TIMEOUT), s->dashboardWaitSeconds);
        }
    } else {
        rep(r, K_STEP, L"%ls", tr(M_DASH_SELF));
        run_companion(s, dryRun ? L"-OpenNow" : L"-Once", dryRun, r);
    }
    if (gh) {
        if (WaitForSingleObject(gh, 0) == WAIT_OBJECT_0) rep(r, K_WARN, tr(M_GAME_EXITED_EARLY), res->gamePid);
        else rep(r, K_INFO, L"%ls", tr(M_KIT_KEEPS_GAME_SAFE));
        CloseHandle(gh);
    }
}

void action_open_dashboard(const Settings *s, int dryRun, const Reporter *r, ActionResult *res) {
    memset(res, 0, sizeof *res);
    log_line(L"action: open dashboard dry=%d", dryRun);
    wchar_t wsc[X4S_PATH], m[1200]; path_join(wsc, X4S_PATH, s->rCompanionDir, L"watch_x4.ps1");
    if (!file_exists(wsc)) { wfmt(m, 1200, tr(M_DASH_NONE), s->rCompanionDir); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"refused-no-companion", m); return; }
    if (dryRun) rep(r, K_WARN, L"%ls", tr(M_DRY_RUN));
    int ok = run_companion(s, L"-OpenNow", dryRun, r);
    res_set(res, (ok || dryRun) ? RC_OK : RC_ERROR, dryRun ? L"whatif" : ok ? L"open" : L"failed", NULL);
}

void action_check_monitors(const Settings *s, const Reporter *r, ActionResult *res) {
    memset(res, 0, sizeof *res);
    if (s->rect[0]) rep(r, K_INFO, tr(M_RECT_USED), s->rect);
    wchar_t sc[X4S_PATH]; kit_path(s, L"x4cockpit3.ps1", sc);
    if (!file_exists(sc)) { wchar_t m[1200]; wfmt(m, 1200, tr(M_KIT_MISSING), s->rCockpitDir); rep(r, K_ERR, L"%ls", m); res_set(res, RC_REFUSED, L"refused-kit-missing", m); return; }
    int ok = 0;
    check_layout(s, r, res, &ok);
}

/* ------------------------------------------------------------------ selftest (pure functions) */
int core_selftest(const Reporter *r) {
    int fail = 0, n = 0;
#define CHECK(cond, name) do { n++; if (cond) rep(r, K_OK, L"PASS %ls", name); else { fail++; rep(r, K_ERR, L"FAIL %ls", name); } } while (0)
    const char *js = "{\"a\":\"x\\u00e9\\\"y\",\"n\":-12.5,\"b\":true,\"arr\":[1,\"two\",null],\"o\":{\"k\":\"\xc3\xa1\"}}";
    JVal *v = json_parse(js, strlen(js), NULL, 0);
    CHECK(v && !wcscmp(jstr(v, L"a", L""), L"x\u00e9\"y"), L"json: string escapes (\\u, \\\")");
    CHECK(v && jnum(v, L"n", 0) == -12.5 && jbool(v, L"b", 0) == 1, L"json: number and bool");
    CHECK(v && jget(v, L"arr") && jget(v, L"arr")->n == 3, L"json: array");
    CHECK(v && !wcscmp(jstr(jget(v, L"o"), L"k", L""), L"\u00e1"), L"json: UTF-8 input");
    CHECK(v && jpath(v, L"o.k") != NULL, L"json: dotted path");
    if (v) {
        jset_str(v, L"new", L"P\u00edl\u00f3ta");
        char *w = json_write(v, 1);
        JVal *v2 = w ? json_parse(w, strlen(w), NULL, 0) : NULL;
        CHECK(v2 && !wcscmp(jstr(v2, L"new", L""), L"P\u00edl\u00f3ta") && !wcscmp(jstr(v2, L"a", L""), L"x\u00e9\"y"), L"json: write + re-read round trip");
        json_free(v2); x4_free(w);
    }
    json_free(v);
    char err[100];
    CHECK(json_parse("{\"a\":", 5, err, 100) == NULL && err[0], L"json: truncated input rejected");
    CHECK(json_parse("{} x", 4, err, 100) == NULL, L"json: trailing garbage rejected");
    CHECK(rect_valid(L"-1920,0,7280,1440") && rect_valid(L"") && rect_valid(L" 0, 0, 640, 360 "), L"rect: valid forms");
    CHECK(!rect_valid(L"1,2,3") && !rect_valid(L"0,0,10,100") && !rect_valid(L"a,b,c,d") && !rect_valid(L"0,0,640,360,1"), L"rect: invalid forms");
    wchar_t q[200];
    quote_arg(q, 200, L"plain"); CHECK(!wcscmp(q, L"plain"), L"quote: plain token unchanged");
    quote_arg(q, 200, L"a b"); CHECK(!wcscmp(q, L"\"a b\""), L"quote: space");
    quote_arg(q, 200, L"say \"hi\""); CHECK(!wcscmp(q, L"\"say \\\"hi\\\"\""), L"quote: inner quotes escaped");
    quote_arg(q, 200, L"C:\\dir with space\\"); CHECK(!wcscmp(q, L"\"C:\\dir with space\\\\\""), L"quote: trailing backslash doubled");
    quote_arg(q, 200, L""); CHECK(!wcscmp(q, L"\"\""), L"quote: empty");
    wchar_t msg[300];
    CHECK(i18n_selftest(msg, 300), msg);
    Settings s; settings_init(&s, L"C:\\Games\\X4\\tools\\x4switch", L"C:\\nowhere\\x4switch-selftest-settings.json", L"C:\\nowhere\\logs");
    settings_load(&s); settings_resolve(&s);
    CHECK(!_wcsicmp(s.rGameExe, L"C:\\Games\\X4\\X4.exe"), L"paths: game = two levels up\\X4.exe");
    CHECK(!_wcsicmp(s.rCockpitDir, L"C:\\Games\\X4\\tools\\x4cockpit3"), L"paths: sibling x4cockpit3");
    CHECK(!_wcsicmp(s.rCompanionDir, L"C:\\Games\\X4\\tools\\x4companion"), L"paths: sibling x4companion");
    CHECK(!_wcsicmp(s.rLauncherLogDir, L"C:\\Games\\X4\\tools\\x4cockpit3\\native\\out"), L"paths: launcher log dir");
    CHECK(s.rPort == 8788 && !wcscmp(s.rWindowTitle, L"X4 Companion"), L"paths: companion defaults (port 8788, title)");
    json_free(s.doc);
    CHECK(wcscmp(tr_lang(L"en", S_COCKPIT_TITLE), tr_lang(L"hu", S_COCKPIT_TITLE)) != 0, L"i18n: en and hu differ");
#undef CHECK
    rep(r, fail ? K_ERR : K_OK, L"selftest: %d checks, %d failed", n, fail);
    return fail;
}
