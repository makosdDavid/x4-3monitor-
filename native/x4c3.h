/* x4c3.h - shared by launcher.c, hook.c and testtarget.c (header-only helpers).
 *
 * The launcher hands the configuration to the hook DLL through ENVIRONMENT VARIABLES of the game process only:
 * it sets them in its own environment right before CreateProcessW, the child inherits them, the DLL reads them
 * once in DllMain and then deletes them from the game's environment. Nothing is written to disk, nothing is
 * shared with other processes, and a stale value cannot affect a later plain game start (the variables only ever
 * exist in the launcher and in the one game process it started).
 */
#ifndef X4C3_H
#define X4C3_H

#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define X4C3_VERSION "0.1.0"

#define X4C3_ENV_RECT     L"X4C3_RECT"        /* "x,y,w,h" in physical pixels (virtual-desktop coordinates)   */
#define X4C3_ENV_EXE      L"X4C3_EXE"         /* full path of the exe the launcher started                    */
#define X4C3_ENV_LOGDIR   L"X4C3_LOGDIR"      /* folder of x4c3hook.log (default: the DLL's own folder)       */
#define X4C3_ENV_LOGCAP   L"X4C3_LOGCAP"      /* log size cap in bytes                                        */
#define X4C3_ENV_WATCHDOG L"X4C3_WATCHDOG_MS" /* watchdog period                                              */
#define X4C3_ENV_MATCH    L"X4C3_MATCH"       /* window class or title of the game window (default "X4")      */
#define X4C3_ENV_OPTS     L"X4C3_OPTS"        /* comma list: nomodes, nowndproc, nowatchdog, testfail         */

#define X4C3_LOGCAP_DEFAULT (1024 * 1024)
#define X4C3_LOGCAP_MIN     1024
#define X4C3_LOGCAP_MAX     (64 * 1024 * 1024)

typedef struct { int x, y, w, h; } X4C3Rect;

/* ------------------------------------------------------------------ parsing */

/* Strict decimal int with optional sign; the whole string must be consumed. */
static int x4c3_parse_int(const wchar_t *s, const wchar_t **end, long lo, long hi, long *out) {
    long v = 0; int neg = 0, digits = 0;
    if (*s == L'-' || *s == L'+') { neg = (*s == L'-'); s++; }
    while (*s >= L'0' && *s <= L'9') {
        v = v * 10 + (*s - L'0');
        if (v > 1000000) return 0;
        s++; digits++;
    }
    if (!digits) return 0;
    if (neg) v = -v;
    if (v < lo || v > hi) return 0;
    *out = v; *end = s;
    return 1;
}

/* "x,y,w,h": x,y in -32768..32767, w,h in 16..32767 (Windows limits a window to 32767 px; 16384 measured OK). */
static int x4c3_parse_rect(const wchar_t *s, X4C3Rect *r) {
    long v[4]; const wchar_t *p = s;
    if (!s) return 0;
    for (int i = 0; i < 4; i++) {
        long lo = (i < 2) ? -32768 : 16, hi = 32767;
        while (*p == L' ') p++;
        if (!x4c3_parse_int(p, &p, lo, hi, &v[i])) return 0;
        while (*p == L' ') p++;
        if (i < 3) { if (*p != L',') return 0; p++; }
    }
    if (*p) return 0;
    if ((long long)v[0] + v[2] > 65535 || (long long)v[1] + v[3] > 65535) return 0;
    r->x = (int)v[0]; r->y = (int)v[1]; r->w = (int)v[2]; r->h = (int)v[3];
    return 1;
}

/* Command-line tokenizer following the Microsoft C runtime rules, but also recording where each token starts in
 * the raw string, so the launcher can pass everything after "--" to the game byte-for-byte. */
typedef struct { wchar_t *val; const wchar_t *start; const wchar_t *end; } X4C3Arg;

static int x4c3_split_cmdline(const wchar_t *cl, X4C3Arg *out, int max) {
    const wchar_t *p = cl; int n = 0;
    /* argv[0]: up to the next quote if it starts with one, else up to whitespace; no escapes */
    if (*p == L'"') { p++; while (*p && *p != L'"') p++; if (*p) p++; }
    else { while (*p && *p != L' ' && *p != L'\t') p++; }
    for (;;) {
        while (*p == L' ' || *p == L'\t') p++;
        if (!*p || n >= max) break;
        size_t cap = wcslen(p) + 1;
        wchar_t *v = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, cap * sizeof(wchar_t));
        size_t k = 0; int inq = 0;
        if (!v) break;
        out[n].start = p;
        while (*p && (inq || (*p != L' ' && *p != L'\t'))) {
            if (*p == L'\\') {
                size_t bs = 0; while (*p == L'\\') { bs++; p++; }
                if (*p == L'"') {
                    for (size_t i = 0; i < bs / 2; i++) v[k++] = L'\\';
                    if (bs % 2) { v[k++] = L'"'; p++; }
                } else { for (size_t i = 0; i < bs; i++) v[k++] = L'\\'; }
            } else if (*p == L'"') {
                if (inq && p[1] == L'"') { v[k++] = L'"'; p += 2; }
                else { inq = !inq; p++; }
            } else v[k++] = *p++;
        }
        v[k] = 0;
        out[n].val = v; out[n].end = p;
        n++;
    }
    return n;
}

static inline const wchar_t *x4c3_basename(const wchar_t *path) {
    const wchar_t *b = path;
    for (const wchar_t *p = path; *p; p++) if (*p == L'\\' || *p == L'/') b = p + 1;
    return b;
}

/* ------------------------------------------------------------------ size-capped log
 * Append mode. At open: if the file is already larger than half the cap it is started over, so one file never
 * exceeds the cap and the previous session usually survives for comparison. Writes stop at the cap (one final
 * marker line is written if it still fits). Thread-safe. */
typedef struct {
    HANDLE h; CRITICAL_SECTION cs; LONGLONG size, cap; int capped, ok; DWORD pid;
} X4C3Log;

static void x4c3_log_open(X4C3Log *L, const wchar_t *path, LONGLONG cap) {
    LARGE_INTEGER sz; int restarted = 0;
    memset(L, 0, sizeof *L);
    InitializeCriticalSection(&L->cs);
    L->cap = cap; L->pid = GetCurrentProcessId();
    L->h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                       OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (L->h == INVALID_HANDLE_VALUE) return;
    if (GetFileSizeEx(L->h, &sz) && sz.QuadPart > cap / 2) {
        CloseHandle(L->h);
        HANDLE t = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (t != INVALID_HANDLE_VALUE) CloseHandle(t);
        L->h = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (L->h == INVALID_HANDLE_VALUE) return;
        sz.QuadPart = 0; restarted = 1;
    }
    L->size = sz.QuadPart; L->ok = 1;
    if (restarted) {
        static const char m[] = "---- log started over (it was larger than half its size cap)\r\n";
        DWORD w; if (WriteFile(L->h, m, sizeof m - 1, &w, NULL)) L->size += w;
    }
}

static void x4c3_log_v(X4C3Log *L, const char *fmt, va_list ap) {
    char buf[1024]; SYSTEMTIME t; int n, m; DWORD w;
    if (!L->ok) return;
    GetLocalTime(&t);
    n = snprintf(buf, sizeof buf, "%04u-%02u-%02u %02u:%02u:%02u.%03u [%lu] ", t.wYear, t.wMonth, t.wDay,
                 t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, (unsigned long)L->pid);
    if (n < 0) return;
    m = vsnprintf(buf + n, sizeof buf - n - 2, fmt, ap);
    if (m < 0) return;
    n += (m < (int)(sizeof buf - n - 2)) ? m : (int)(sizeof buf - n - 3);
    buf[n++] = '\r'; buf[n++] = '\n';
    EnterCriticalSection(&L->cs);
    if (!L->capped) {
        if (L->size + n <= L->cap - 40) {
            if (WriteFile(L->h, buf, (DWORD)n, &w, NULL)) L->size += w;
        } else {
            static const char cm[] = "---- log size cap reached, logging stops\r\n";
            if (L->size + (LONGLONG)sizeof cm - 1 <= L->cap && WriteFile(L->h, cm, sizeof cm - 1, &w, NULL)) L->size += w;
            L->capped = 1;
        }
    }
    LeaveCriticalSection(&L->cs);
}

static void x4c3_log_close(X4C3Log *L) {
    if (!L->pid) return;                     /* never opened */
    if (L->ok) { CloseHandle(L->h); L->ok = 0; }
    DeleteCriticalSection(&L->cs);
    L->pid = 0;
}

#endif
