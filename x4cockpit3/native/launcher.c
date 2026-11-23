/* launcher.c - starts X4.exe with x4c3hook.dll loaded into it.
 *
 *   launcher.exe --exe <absolute path of X4.exe> --rect x,y,w,h [options] [-- <game arguments>]
 *
 * Steps: verify the exe (absolute, exists, file name X4.exe), put the configuration into this process's environment
 * (the game inherits it; see x4c3.h), CreateProcessW(CREATE_SUSPENDED) with the exe's folder as working directory,
 * write the DLL path into the game, run LoadLibraryW there with CreateRemoteThread and wait for it, then resume the
 * game's main thread. The game's own code has not run at that point, so every window call it makes goes through
 * the hooks. (A remote thread in a process that has not started yet first completes the normal process start-up -
 * loading the exe's own DLLs - and then calls LoadLibraryW; the exe's entry point runs only after ResumeThread.)
 *
 * Fail-safe: if the rectangle is invalid, the DLL is missing, the injection fails or the DLL declines, the game is
 * still started (resumed) and simply runs as without the launcher. The reason goes to the log.
 * Refused (nothing started): unknown option, exe not absolute / missing / not named X4.exe, game already running.
 *
 * Exit code: 0 = game started with the hook active, 3 = game started WITHOUT the hook, 2 = refused, 1 = start failed.
 * GUI subsystem (no console window); messages go to launcher.log in --log-dir (and to stdout if it is redirected).
 */
#include "x4c3.h"
#include <tlhelp32.h>

static X4C3Log g_log;
static HANDLE g_out;

static void say(const char *fmt, ...) {
    char buf[1200]; va_list ap; DWORD w;
    va_start(ap, fmt); x4c3_log_v(&g_log, fmt, ap); va_end(ap);
    if (g_out && g_out != INVALID_HANDLE_VALUE) {
        va_start(ap, fmt); int n = vsnprintf(buf, sizeof buf - 2, fmt, ap); va_end(ap);
        if (n < 0) return;
        if (n > (int)sizeof buf - 3) n = (int)sizeof buf - 3;
        buf[n++] = '\r'; buf[n++] = '\n';
        WriteFile(g_out, buf, (DWORD)n, &w, NULL);
    }
}

static int file_exists(const wchar_t *p) {
    DWORD a = GetFileAttributesW(p);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
static int is_absolute(const wchar_t *p) {
    return (((p[0] | 0x20) >= L'a' && (p[0] | 0x20) <= L'z') && p[1] == L':' && (p[2] == L'\\' || p[2] == L'/')) ||
           (p[0] == L'\\' && p[1] == L'\\');
}

/* Is a process with this exact image path already running? */
static DWORD running_pid(const wchar_t *exe) {
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W pe; pe.dwSize = sizeof pe; DWORD found = 0;
    if (s == INVALID_HANDLE_VALUE) return 0;
    for (BOOL ok = Process32FirstW(s, &pe); ok && !found; ok = Process32NextW(s, &pe)) {
        if (lstrcmpiW(pe.szExeFile, x4c3_basename(exe)) != 0) continue;
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
        if (!h) continue;
        wchar_t p[MAX_PATH * 2]; DWORD n = MAX_PATH * 2;
        if (QueryFullProcessImageNameW(h, 0, p, &n) && lstrcmpiW(p, exe) == 0) found = pe.th32ProcessID;
        CloseHandle(h);
    }
    CloseHandle(s);
    return found;
}

static int module_loaded(DWORD pid, const wchar_t *dll) {
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, pid);
    MODULEENTRY32W me; me.dwSize = sizeof me; int found = 0;
    if (s == INVALID_HANDLE_VALUE) return 0;
    for (BOOL ok = Module32FirstW(s, &me); ok && !found; ok = Module32NextW(s, &me))
        if (lstrcmpiW(me.szExePath, dll) == 0) found = 1;
    CloseHandle(s);
    return found;
}

/* LoadLibraryW(dll) inside the suspended game. Returns 1 if the DLL is loaded (= it accepted and hooked). */
static int inject(HANDLE hp, DWORD pid, const wchar_t *dll) {
    SIZE_T size = (wcslen(dll) + 1) * sizeof(wchar_t), wr = 0;
    void *mem = VirtualAllocEx(hp, NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!mem) { say("injection: VirtualAllocEx failed (error %lu)", GetLastError()); return 0; }
    if (!WriteProcessMemory(hp, mem, dll, size, &wr) || wr != size) {
        say("injection: WriteProcessMemory failed (error %lu)", GetLastError());
        VirtualFreeEx(hp, mem, 0, MEM_RELEASE); return 0;
    }
    /* kernel32 is mapped at the same address in every process of this session and architecture */
    LPTHREAD_START_ROUTINE ll = (LPTHREAD_START_ROUTINE)(void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
    HANDLE ht = ll ? CreateRemoteThread(hp, NULL, 0, ll, mem, 0, NULL) : NULL;
    if (!ht) { say("injection: CreateRemoteThread failed (error %lu)", GetLastError()); VirtualFreeEx(hp, mem, 0, MEM_RELEASE); return 0; }
    DWORD wait = WaitForSingleObject(ht, 20000), code = 0;
    if (wait != WAIT_OBJECT_0) {
        say("injection: LoadLibraryW did not finish within 20 s - resuming the game anyway (hook state unknown)");
        CloseHandle(ht); return 0;   /* the buffer stays allocated: the remote thread may still read it */
    }
    GetExitCodeThread(ht, &code);
    CloseHandle(ht);
    VirtualFreeEx(hp, mem, 0, MEM_RELEASE);
    /* the exit code is the low 32 bits of the module handle; 0 can (very rarely) be a valid handle, so ask */
    if (code != 0) return 1;
    return module_loaded(pid, dll);
}

static void usage(void) {
    say("usage: launcher.exe --exe <absolute path of X4.exe> --rect x,y,w,h [--dll <path>] [--log-dir <dir>] [--log-cap <bytes>]"
        " [--watchdog-ms <100..5000>] [--match <window class/title>] [--opts nomodes,nowndproc,nowatchdog] [--watch-exit-ms <ms>]"
        " [-- <game arguments>]");
}

int main(void) {
    static X4C3Arg args[64];
    const wchar_t *cl = GetCommandLineW();
    int argc = x4c3_split_cmdline(cl, args, 64);
    const wchar_t *exeArg = NULL, *rectArg = NULL, *dllArg = NULL, *logDir = NULL, *capArg = NULL, *wdArg = NULL,
                  *matchArg = NULL, *optsArg = NULL, *watchArg = NULL, *pass = L"", *badArg = NULL;
    int testTarget = 0, failInject = 0, failHooks = 0, rawRect = 0, wrongEnv = 0, bad = 0;
    wchar_t self[MAX_PATH * 2], dir[MAX_PATH * 2], logPath[MAX_PATH * 2 + 32];
    long v; const wchar_t *e;

    g_out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (g_out && GetFileType(g_out) == FILE_TYPE_UNKNOWN) g_out = NULL;
    GetModuleFileNameW(NULL, self, MAX_PATH * 2);
    lstrcpyW(dir, self); *(wchar_t *)x4c3_basename(dir) = 0;

    for (int i = 0; i < argc; i++) {
        const wchar_t *a = args[i].val;
        const wchar_t *nx = (i + 1 < argc) ? args[i + 1].val : NULL;
#define TAKE(var) do { if (!nx) { bad = 1; } else { var = nx; i++; } } while (0)
        if (!lstrcmpW(a, L"--")) { pass = args[i].end; while (*pass == L' ' || *pass == L'\t') pass++; break; }
        else if (!lstrcmpW(a, L"--exe")) TAKE(exeArg);
        else if (!lstrcmpW(a, L"--rect")) TAKE(rectArg);
        else if (!lstrcmpW(a, L"--dll")) TAKE(dllArg);
        else if (!lstrcmpW(a, L"--log-dir")) TAKE(logDir);
        else if (!lstrcmpW(a, L"--log-cap")) TAKE(capArg);
        else if (!lstrcmpW(a, L"--watchdog-ms")) TAKE(wdArg);
        else if (!lstrcmpW(a, L"--match")) TAKE(matchArg);
        else if (!lstrcmpW(a, L"--opts")) TAKE(optsArg);
        else if (!lstrcmpW(a, L"--watch-exit-ms")) TAKE(watchArg);
        else if (!lstrcmpW(a, L"--test-target")) testTarget = 1;
        else if (!lstrcmpW(a, L"--test-fail-inject")) failInject = 1;
        else if (!lstrcmpW(a, L"--test-fail-hooks")) failHooks = 1;
        else if (!lstrcmpW(a, L"--test-raw-rect")) rawRect = 1;
        else if (!lstrcmpW(a, L"--test-wrong-exe-env")) wrongEnv = 1;
        else { bad = 1; if (!badArg) badArg = a; }   /* keep parsing: --log-dir may still follow */
#undef TAKE
    }

    /* log first, so even a refusal is recorded */
    LONGLONG cap = X4C3_LOGCAP_DEFAULT; int capBad = 0;
    if (capArg) { if (x4c3_parse_int(capArg, &e, X4C3_LOGCAP_MIN, X4C3_LOGCAP_MAX, &v) && !*e) cap = v; else capBad = 1; }
    wchar_t ld[MAX_PATH * 2];
    if (logDir && logDir[0]) { DWORD n = GetFullPathNameW(logDir, MAX_PATH * 2, ld, NULL); if (!n || n >= MAX_PATH * 2) lstrcpyW(ld, dir); }
    else lstrcpyW(ld, dir);
    if (ld[wcslen(ld) - 1] != L'\\') wcscat(ld, L"\\");
    CreateDirectoryW(ld, NULL);
    _snwprintf(logPath, sizeof logPath / sizeof logPath[0], L"%lslauncher.log", ld);
    logPath[sizeof logPath / sizeof logPath[0] - 1] = 0;
    x4c3_log_open(&g_log, logPath, cap);
    say("==== x4c3 launcher %s: %ls", X4C3_VERSION, cl);

    if (bad) { say("REFUSED: unknown option or missing value (%ls)", badArg ? badArg : L"missing value"); usage(); return 2; }
    if ((failInject || failHooks || rawRect || wrongEnv) && !testTarget) { say("REFUSED: --test-* options need --test-target"); return 2; }
    if (capBad) { say("REFUSED: --log-cap must be %d..%d", X4C3_LOGCAP_MIN, X4C3_LOGCAP_MAX); return 2; }

    /* ---- the exe */
    wchar_t exe[MAX_PATH * 2];
    if (!exeArg || !is_absolute(exeArg)) { say("REFUSED: --exe must be an absolute path (got \"%ls\")", exeArg ? exeArg : L""); usage(); return 2; }
    DWORD fn = GetFullPathNameW(exeArg, MAX_PATH * 2, exe, NULL);
    if (!fn || fn >= MAX_PATH * 2 || !file_exists(exe)) { say("REFUSED: exe not found: %ls", exeArg); return 2; }
    const wchar_t *bn = x4c3_basename(exe);
    int nameOk = !lstrcmpiW(bn, L"X4.exe") || (testTarget && !lstrcmpiW(bn, L"testtarget.exe"));
    if (!nameOk) { say("REFUSED: the exe must be named X4.exe%ls (got \"%ls\")", testTarget ? L" or testtarget.exe" : L"", bn); return 2; }
    DWORD other = running_pid(exe);
    if (other) { say("REFUSED: %ls is already running (pid %lu). Close it first - the hook must be in place before the window exists.", exe, other); return 2; }
    wchar_t exeDir[MAX_PATH * 2]; lstrcpyW(exeDir, exe); *(wchar_t *)x4c3_basename(exeDir) = 0;

    /* ---- hook prerequisites: problems here do not stop the game, they only disable the hook */
    int hook = 1; const char *why = "";
    X4C3Rect r;
    if (!rectArg || !x4c3_parse_rect(rectArg, &r)) {
        if (rawRect && rectArg) say("TEST: passing the unchecked rectangle \"%ls\" to the DLL", rectArg);
        else { hook = 0; why = "invalid or missing --rect (expected x,y,w,h with w,h 16..32767)"; say("rectangle \"%ls\" is invalid", rectArg ? rectArg : L""); }
    } else say("rectangle: (%d,%d) %dx%d", r.x, r.y, r.w, r.h);
    wchar_t dll[MAX_PATH * 2];
    if (hook) {
        if (dllArg) { DWORD n = GetFullPathNameW(dllArg, MAX_PATH * 2, dll, NULL); if (!n || n >= MAX_PATH * 2) dll[0] = 0; }
        else _snwprintf(dll, MAX_PATH * 2, L"%lsx4c3hook.dll", dir);
        dll[MAX_PATH * 2 - 1] = 0;
        if (!dll[0] || !file_exists(dll)) { hook = 0; why = "hook DLL not found"; say("hook DLL not found: %ls", dll[0] ? dll : (dllArg ? dllArg : L"")); }
    }
    if (hook && wdArg && !(x4c3_parse_int(wdArg, &e, 100, 5000, &v) && !*e)) { say("--watchdog-ms ignored (must be 100..5000)"); wdArg = NULL; }
    if (hook && optsArg) for (const wchar_t *p = optsArg; *p; p++)
        if (!((*p >= L'a' && *p <= L'z') || *p == L',')) { say("--opts ignored (lower-case words and commas only)"); optsArg = NULL; break; }
    if (hook && matchArg && (wcslen(matchArg) == 0 || wcslen(matchArg) > 60)) { say("--match ignored (1..60 characters)"); matchArg = NULL; }

    /* ---- configuration for the DLL: environment of this process, inherited by the game only */
    if (hook) {
        wchar_t optsBuf[300] = L"", capBuf[32];
        SetEnvironmentVariableW(X4C3_ENV_RECT, rectArg);
        SetEnvironmentVariableW(X4C3_ENV_EXE, wrongEnv ? L"(test: not the started exe)\\X4.exe" : exe);
        SetEnvironmentVariableW(X4C3_ENV_LOGDIR, ld);
        _snwprintf(capBuf, 32, L"%lld", cap); capBuf[31] = 0;
        SetEnvironmentVariableW(X4C3_ENV_LOGCAP, capBuf);
        if (wdArg) SetEnvironmentVariableW(X4C3_ENV_WATCHDOG, wdArg);
        if (matchArg) SetEnvironmentVariableW(X4C3_ENV_MATCH, matchArg);
        if (optsArg) lstrcpynW(optsBuf, optsArg, 256);
        if (failHooks) wcscat(optsBuf, L",testfail");
        if (optsBuf[0]) SetEnvironmentVariableW(X4C3_ENV_OPTS, optsBuf);
    } else say("starting the game WITHOUT the hook: %s", why);

    /* ---- start (suspended when hooking) */
    /* argv[0] = the quoted exe path (a Windows file name cannot contain '"'), then the game arguments verbatim */
    size_t cmdCap = wcslen(exe) + wcslen(pass) + 8;
    wchar_t *cmd = (wchar_t *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, cmdCap * sizeof(wchar_t));
    if (!cmd) { say("out of memory"); return 1; }
    _snwprintf(cmd, cmdCap, *pass ? L"\"%ls\" %ls" : L"\"%ls\"", exe, pass);
    cmd[cmdCap - 1] = 0;
    STARTUPINFOW si; PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si); si.cb = sizeof si; memset(&pi, 0, sizeof pi);
    say("starting: %ls  (working directory %ls)", cmd, exeDir);
    if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, hook ? CREATE_SUSPENDED : 0, NULL, exeDir, &si, &pi)) {
        say("ERROR: CreateProcessW failed (error %lu)", GetLastError()); return 1;
    }
    say("game process started: pid=%lu", pi.dwProcessId);

    int active = 0;
    if (hook) {
        if (failInject) say("TEST: simulated injection failure");
        else {
            active = inject(pi.hProcess, pi.dwProcessId, dll);
            if (!active) say("the hook DLL did not load or declined (see x4c3hook.log in %ls)", ld);
        }
        if (ResumeThread(pi.hThread) == (DWORD)-1) {
            say("ERROR: ResumeThread failed (error %lu) - terminating the suspended game", GetLastError());
            TerminateProcess(pi.hProcess, 1); return 1;
        }
    }
    say("pid=%lu hook=%s", pi.dwProcessId, active ? "ACTIVE" : "NOT active - the game runs as without the launcher");

    /* optional: report an early exit (e.g. a store launcher relaunching the game - that new process is not hooked) */
    DWORD watch = 15000;
    if (watchArg && x4c3_parse_int(watchArg, &e, 0, 120000, &v) && !*e) watch = (DWORD)v;
    if (watch && WaitForSingleObject(pi.hProcess, watch) == WAIT_OBJECT_0) {
        DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
        say("note: the game process exited within %lu ms (exit code %lu). If it restarted itself through a store client, the new process is NOT hooked.", watch, code);
    }
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    x4c3_log_close(&g_log);
    return active ? 0 : 3;
}
