/* hook.c - x4c3hook.dll: makes X4 (or the test target) create and keep ONE borderless window at a configured
 * rectangle, and makes the game believe that rectangle is its monitor.
 *
 * How: the launcher loads this DLL into the freshly created, still suspended game process. In DllMain the DLL
 * rewrites entries of the EXE's OWN import address table (IAT) for a few user32 functions, so the game's calls
 * land here first. Nothing else is patched: no code bytes, no other module, no file on disk.
 *
 * What IAT patching cannot see, and why that is fine here (X4.exe 9.00 import table, read with peimports.py):
 *  - calls from other DLLs (Vulkan loader/driver, Steam, Tobii, OpenAL): they see the REAL window, which really
 *    is the requested size, so the swapchain gets the right extent from the real client rectangle;
 *  - functions resolved with GetProcAddress: X4.exe contains no name string of any window/monitor function it does
 *    not import (MoveWindow, SetWindowPlacement, DeferWindowPos, EnumDisplayMonitors, MonitorFromPoint, ...);
 *  - what Windows does inside DefWindowProc (WM_GETMINMAXINFO, WM_WINDOWPOSCHANGING clamping): covered by wrapping
 *    the game's window procedure at RegisterClassExW (option "nowndproc" turns this off);
 *  - moves from outside the process (user, Windows on a display change): covered by the watchdog thread.
 *
 * Safety: does nothing (DllMain returns FALSE, so the DLL is unloaded again) unless it is inside the exe the
 * launcher named, that exe is X4.exe or testtarget.exe, and it got a valid rectangle. Any failure while patching
 * rolls back every entry already written. No network, registry, threads other than the watchdog, or files other
 * than one size-capped log.
 */
#include "x4c3.h"

/* ------------------------------------------------------------------ state */
static X4C3Rect R;
static RECT RR;                     /* R as a RECT */
static HMODULE g_self;
static volatile HWND g_game;        /* the captured top-level game window */
static WNDPROC g_gameProc;          /* the game's own window procedure (class "X4"), when wrapped */
static wchar_t g_match[64] = L"X4";
static int opt_modes = 1, opt_wndproc = 1, opt_watchdog = 1, opt_testfail = 0;
static DWORD g_watch_ms = 500;
static X4C3Log g_log;
static volatile LONG n_cw, n_swp, n_swl, n_show, n_adj, n_gmi, n_mfw, n_mfr, n_gsm, n_spi, n_eds, n_cds, n_wd, n_wp;

#define LOG(...) x4c3_log(__VA_ARGS__)
static void x4c3_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); x4c3_log_v(&g_log, fmt, ap); va_end(ap); }
/* log only the first few calls of a hook in detail; counters cover the rest (written by the watchdog) */
#define FIRST(counter, n) (InterlockedIncrement(&(counter)) <= (n))

/* ------------------------------------------------------------------ style rules */
#define FRAME_BITS (WS_CAPTION | WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MAXIMIZE) /* WS_CAPTION = BORDER|DLGFRAME */
#define EXFRAME_BITS (WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE)
/* Borderless popup. WS_SYSMENU / WS_MINIMIZEBOX are kept: without a caption they draw nothing, but they let the
 * taskbar and Alt+Tab minimise/restore the game as usual. WS_MAXIMIZEBOX goes, so Windows never maximises it to one
 * monitor. */
static LONG_PTR fix_style(LONG_PTR s) { return (s & ~(LONG_PTR)FRAME_BITS & ~(LONG_PTR)WS_CHILD) | WS_POPUP; }
static LONG_PTR fix_ex(LONG_PTR e) { return e & ~(LONG_PTR)EXFRAME_BITS; }

static int name_is_match(LPCWSTR s) { return s && !IS_INTRESOURCE(s) && lstrcmpiW(s, g_match) == 0; }

/* The monitor that "becomes" the wide rectangle: the real monitor under the rectangle's centre (nearest if the
 * centre is off-screen). Recomputed on every use, because monitor handles change when monitors come and go. */
static HMONITOR anchor_monitor(void) {
    POINT p = { R.x + R.w / 2, R.y + R.h / 2 };
    return MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
}

/* Put the window at the rectangle with our own (unhooked) user32 imports. */
static void apply_rect(HWND h, int async) {
    LONG_PTR st = GetWindowLongPtrW(h, GWL_STYLE), ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
    UINT f = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER;
    if (fix_style(st) != st || fix_ex(ex) != ex) {
        SetWindowLongPtrW(h, GWL_STYLE, fix_style(st));
        SetWindowLongPtrW(h, GWL_EXSTYLE, fix_ex(ex));
        f |= SWP_FRAMECHANGED;
    }
    if (async) f |= SWP_ASYNCWINDOWPOS;
    SetWindowPos(h, NULL, R.x, R.y, R.w, R.h, f);
}

static void log_window(const char *what, HWND h) {
    RECT wr = { 0 }, cr = { 0 };
    GetWindowRect(h, &wr); GetClientRect(h, &cr);
    LOG("%s hwnd=0x%llx window=(%ld,%ld) %ldx%ld client=%ldx%ld style=0x%08llx ex=0x%08llx", what,
        (unsigned long long)(ULONG_PTR)h, wr.left, wr.top, wr.right - wr.left, wr.bottom - wr.top, cr.right, cr.bottom,
        (unsigned long long)GetWindowLongPtrW(h, GWL_STYLE), (unsigned long long)GetWindowLongPtrW(h, GWL_EXSTYLE));
}

/* ------------------------------------------------------------------ originals (filled from the IAT) */
static HWND(WINAPI *O_CreateWindowExW)(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
static ATOM(WINAPI *O_RegisterClassExW)(const WNDCLASSEXW *);
static BOOL(WINAPI *O_SetWindowPos)(HWND, HWND, int, int, int, int, UINT);
static LONG_PTR(WINAPI *O_SetWindowLongPtrW)(HWND, int, LONG_PTR);
static BOOL(WINAPI *O_ShowWindow)(HWND, int);
static BOOL(WINAPI *O_AdjustWindowRect)(LPRECT, DWORD, BOOL);
static BOOL(WINAPI *O_GetMonitorInfoW)(HMONITOR, LPMONITORINFO);
static HMONITOR(WINAPI *O_MonitorFromWindow)(HWND, DWORD);
static HMONITOR(WINAPI *O_MonitorFromRect)(LPCRECT, DWORD);
static int(WINAPI *O_GetSystemMetrics)(int);
static BOOL(WINAPI *O_SystemParametersInfoW)(UINT, UINT, PVOID, UINT);
static BOOL(WINAPI *O_SystemParametersInfoA)(UINT, UINT, PVOID, UINT);
static BOOL(WINAPI *O_EnumDisplaySettingsW)(LPCWSTR, DWORD, DEVMODEW *);
static BOOL(WINAPI *O_EnumDisplaySettingsExW)(LPCWSTR, DWORD, DEVMODEW *, DWORD);
static LONG(WINAPI *O_ChangeDisplaySettingsW)(DEVMODEW *, DWORD);
static LONG(WINAPI *O_ChangeDisplaySettingsExW)(LPCWSTR, DEVMODEW *, HWND, DWORD, LPVOID);

/* ------------------------------------------------------------------ window procedure wrapper */
static LRESULT CALLBACK H_WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_NCCREATE) {
        const CREATESTRUCTW *cs = (const CREATESTRUCTW *)l;
        if (!(cs->style & WS_CHILD) && !cs->hwndParent && g_game != h) {
            g_game = h;
            LOG("captured game window 0x%llx at WM_NCCREATE", (unsigned long long)(ULONG_PTR)h);
        }
    }
    LRESULT r = CallWindowProcW(g_gameProc, h, m, w, l);
    if (h == g_game) {
        if (m == WM_WINDOWPOSCHANGING) {
            /* after the game (and DefWindowProc) had their say: whatever moves/sizes the window goes to R.
             * Minimising is left alone (iconic, or the -32000 parking position). */
            WINDOWPOS *wp = (WINDOWPOS *)l;
            if (!IsIconic(h) && wp->x > -30000 && wp->y > -30000) {
                int changed = 0;
                if (!(wp->flags & SWP_NOMOVE) && (wp->x != R.x || wp->y != R.y)) { wp->x = R.x; wp->y = R.y; changed = 1; }
                if (!(wp->flags & SWP_NOSIZE) && (wp->cx != R.w || wp->cy != R.h)) { wp->cx = R.w; wp->cy = R.h; changed = 1; }
                if (changed && FIRST(n_wp, 5)) LOG("WM_WINDOWPOSCHANGING: move/size redirected to the rectangle");
            }
        } else if (m == WM_GETMINMAXINFO) {
            MINMAXINFO *mm = (MINMAXINFO *)l;
            if (mm->ptMaxTrackSize.x < R.w) mm->ptMaxTrackSize.x = R.w;
            if (mm->ptMaxTrackSize.y < R.h) mm->ptMaxTrackSize.y = R.h;
            mm->ptMaxSize.x = R.w; mm->ptMaxSize.y = R.h;
        }
    }
    return r;
}

/* ------------------------------------------------------------------ hooks */
static ATOM WINAPI H_RegisterClassExW(const WNDCLASSEXW *wc) {
    if (opt_wndproc && wc && wc->cbSize >= sizeof(WNDCLASSEXW) && name_is_match(wc->lpszClassName) &&
        wc->lpfnWndProc && wc->lpfnWndProc != H_WndProc) {
        WNDCLASSEXW c = *wc;
        g_gameProc = c.lpfnWndProc;
        c.lpfnWndProc = H_WndProc;
        LOG("RegisterClassExW(\"%ls\"): window procedure wrapped", wc->lpszClassName);
        return O_RegisterClassExW(&c);
    }
    return O_RegisterClassExW(wc);
}

static HWND WINAPI H_CreateWindowExW(DWORD ex, LPCWSTR cls, LPCWSTR title, DWORD style, int x, int y, int w, int h,
                                     HWND parent, HMENU menu, HINSTANCE inst, LPVOID param) {
    int match = !(style & WS_CHILD) && !parent && (name_is_match(cls) || name_is_match(title));
    if (!match) return O_CreateWindowExW(ex, cls, title, style, x, y, w, h, parent, menu, inst, param);
    InterlockedIncrement(&n_cw);
    LOG("CreateWindowExW: game asked class=%ls title=%ls at (%d,%d) %dx%d style=0x%08lx ex=0x%08lx",
        IS_INTRESOURCE(cls) ? L"(atom)" : cls, title ? title : L"(null)", x, y, w, h, style, ex);
    DWORD ns = (DWORD)fix_style(style), nex = (DWORD)fix_ex(ex);
    HWND hw = O_CreateWindowExW(nex, cls, title, ns, R.x, R.y, R.w, R.h, parent, menu, inst, param);
    if (hw) {
        g_game = hw;
        log_window("CreateWindowExW: window created as borderless popup at the rectangle:", hw);
        RECT wr; GetWindowRect(hw, &wr);
        if (wr.left != R.x || wr.top != R.y || wr.right - wr.left != R.w || wr.bottom - wr.top != R.h) {
            LOG("CreateWindowExW: Windows did not give the exact rectangle - re-applying");
            apply_rect(hw, 0);
            log_window("  now", hw);
        }
    } else LOG("CreateWindowExW failed: error %lu", GetLastError());
    return hw;
}

static BOOL WINAPI H_SetWindowPos(HWND h, HWND after, int x, int y, int cx, int cy, UINT f) {
    if (h && h == g_game && !IsIconic(h)) {
        if (FIRST(n_swp, 8)) LOG("SetWindowPos by the game: (%d,%d) %dx%d flags=0x%x -> rewritten to the rectangle", x, y, cx, cy, f);
        f &= ~(UINT)(SWP_NOMOVE | SWP_NOSIZE);
        x = R.x; y = R.y; cx = R.w; cy = R.h;
    }
    return O_SetWindowPos(h, after, x, y, cx, cy, f);
}

static LONG_PTR WINAPI H_SetWindowLongPtrW(HWND h, int idx, LONG_PTR v) {
    if (h && h == g_game) {
        LONG_PTR nv = v;
        if (idx == GWL_STYLE) nv = fix_style(v);
        else if (idx == GWL_EXSTYLE) nv = fix_ex(v);
        if (nv != v && FIRST(n_swl, 8)) LOG("SetWindowLongPtrW(%d, 0x%llx) by the game -> 0x%llx (kept borderless)", idx, (unsigned long long)v, (unsigned long long)nv);
        v = nv;
    }
    return O_SetWindowLongPtrW(h, idx, v);
}

static BOOL WINAPI H_ShowWindow(HWND h, int cmd) {
    if (h && h == g_game) {
        int orig = cmd;
        if (cmd == SW_MAXIMIZE) cmd = SW_SHOWNORMAL;   /* SW_MAXIMIZE == SW_SHOWMAXIMIZED: would fit it to one monitor */
        if (FIRST(n_show, 8)) LOG("ShowWindow(%d) by the game%s", orig, cmd != orig ? " -> SW_SHOWNORMAL" : "");
        BOOL r = O_ShowWindow(h, cmd);
        if (cmd != SW_HIDE && cmd != SW_MINIMIZE && cmd != SW_SHOWMINIMIZED && cmd != SW_SHOWMINNOACTIVE &&
            cmd != SW_FORCEMINIMIZE && !IsIconic(h)) apply_rect(h, 0);
        return r;
    }
    return O_ShowWindow(h, cmd);
}

/* Borderless: the window rectangle IS the client rectangle, whatever style the game asks about. */
static BOOL WINAPI H_AdjustWindowRect(LPRECT rc, DWORD style, BOOL menu) {
    if (FIRST(n_adj, 4) && rc) LOG("AdjustWindowRect(%ld,%ld,%ld,%ld style=0x%08lx) -> unchanged (borderless)", rc->left, rc->top, rc->right, rc->bottom, style);
    (void)menu;
    return rc != NULL;
}

static BOOL WINAPI H_GetMonitorInfoW(HMONITOR m, LPMONITORINFO mi) {
    BOOL ok = O_GetMonitorInfoW(m, mi);
    if (ok && mi && m == anchor_monitor()) {
        if (FIRST(n_gmi, 4)) LOG("GetMonitorInfoW(anchor): real monitor (%ld,%ld)-(%ld,%ld) work (%ld,%ld)-(%ld,%ld) -> rcMonitor = rcWork = the rectangle",
                                 mi->rcMonitor.left, mi->rcMonitor.top, mi->rcMonitor.right, mi->rcMonitor.bottom,
                                 mi->rcWork.left, mi->rcWork.top, mi->rcWork.right, mi->rcWork.bottom);
        mi->rcMonitor = RR; mi->rcWork = RR;
    }
    return ok;
}

static HMONITOR WINAPI H_MonitorFromWindow(HWND h, DWORD f) {
    if (h && h == g_game) { InterlockedIncrement(&n_mfw); return anchor_monitor(); }
    return O_MonitorFromWindow(h, f);
}

/* A rectangle that contains the anchor monitor's centre (e.g. the game's own window rectangle) is "on" the wide
 * monitor; any other rectangle (another real monitor) gets the real answer. */
static HMONITOR WINAPI H_MonitorFromRect(LPCRECT rc, DWORD f) {
    HMONITOR a = anchor_monitor();
    MONITORINFO mi = { sizeof mi };
    if (rc && O_GetMonitorInfoW(a, &mi)) {
        POINT c = { (mi.rcMonitor.left + mi.rcMonitor.right) / 2, (mi.rcMonitor.top + mi.rcMonitor.bottom) / 2 };
        if (PtInRect(rc, c)) { InterlockedIncrement(&n_mfr); return a; }
    }
    return O_MonitorFromRect(rc, f);
}

static int WINAPI H_GetSystemMetrics(int i) {
    int v = O_GetSystemMetrics(i);
    switch (i) {
    case SM_CXSCREEN: case SM_CXFULLSCREEN: v = R.w; break;
    case SM_CYSCREEN: case SM_CYFULLSCREEN: v = R.h; break;
    case SM_CXMAXTRACK: case SM_CXMAXIMIZED: if (v < R.w) v = R.w; break;
    case SM_CYMAXTRACK: case SM_CYMAXIMIZED: if (v < R.h) v = R.h; break;
    case SM_XVIRTUALSCREEN: if (v > R.x) v = R.x; break;
    case SM_YVIRTUALSCREEN: if (v > R.y) v = R.y; break;
    case SM_CXVIRTUALSCREEN: {   /* union of the real virtual desktop and the rectangle */
        int x0 = O_GetSystemMetrics(SM_XVIRTUALSCREEN), x1 = x0 + v;
        if (R.x < x0) x0 = R.x; if (R.x + R.w > x1) x1 = R.x + R.w; v = x1 - x0; break; }
    case SM_CYVIRTUALSCREEN: {
        int y0 = O_GetSystemMetrics(SM_YVIRTUALSCREEN), y1 = y0 + v;
        if (R.y < y0) y0 = R.y; if (R.y + R.h > y1) y1 = R.y + R.h; v = y1 - y0; break; }
    default: return v;
    }
    if (FIRST(n_gsm, 12)) LOG("GetSystemMetrics(%d) -> %d", i, v);
    return v;
}

static BOOL spi_common(UINT a, PVOID pv) {
    if (a == SPI_GETWORKAREA && pv) {
        *(RECT *)pv = RR;
        if (FIRST(n_spi, 4)) LOG("SystemParametersInfo(SPI_GETWORKAREA) -> the rectangle");
        return TRUE;
    }
    return FALSE;
}
static BOOL WINAPI H_SystemParametersInfoW(UINT a, UINT ui, PVOID pv, UINT wi) {
    if (spi_common(a, pv)) return TRUE;
    return O_SystemParametersInfoW(a, ui, pv, wi);
}
static BOOL WINAPI H_SystemParametersInfoA(UINT a, UINT ui, PVOID pv, UINT wi) {
    if (spi_common(a, pv)) return TRUE;
    return O_SystemParametersInfoA(a, ui, pv, wi);
}

/* Current/registry mode of the anchor monitor's display device reports the rectangle's size and position; the
 * list of real modes (index >= 0) is untouched. Option "nomodes" turns this off. */
static void eds_fix(LPCWSTR dev, DWORD mode, DEVMODEW *dm, BOOL ok) {
    if (!ok || !opt_modes || !dm || (mode != ENUM_CURRENT_SETTINGS && mode != ENUM_REGISTRY_SETTINGS)) return;
    MONITORINFOEXW mi; mi.cbSize = sizeof mi;
    HMONITOR a = anchor_monitor();
    if (!O_GetMonitorInfoW(a, (LPMONITORINFO)&mi)) return;
    if (dev ? lstrcmpiW(dev, mi.szDevice) != 0 : !(mi.dwFlags & MONITORINFOF_PRIMARY)) return;
    if (FIRST(n_eds, 4)) LOG("EnumDisplaySettings(%ls, %ld): real %lux%lu at (%ld,%ld) -> reported as %dx%d at (%d,%d)",
                             dev ? dev : L"(primary)", (long)mode, dm->dmPelsWidth, dm->dmPelsHeight,
                             dm->dmPosition.x, dm->dmPosition.y, R.w, R.h, R.x, R.y);
    dm->dmPelsWidth = (DWORD)R.w; dm->dmPelsHeight = (DWORD)R.h;
    dm->dmPosition.x = R.x; dm->dmPosition.y = R.y;
}
static BOOL WINAPI H_EnumDisplaySettingsW(LPCWSTR dev, DWORD mode, DEVMODEW *dm) {
    BOOL ok = O_EnumDisplaySettingsW(dev, mode, dm);
    eds_fix(dev, mode, dm, ok);
    return ok;
}
static BOOL WINAPI H_EnumDisplaySettingsExW(LPCWSTR dev, DWORD mode, DEVMODEW *dm, DWORD fl) {
    BOOL ok = O_EnumDisplaySettingsExW(dev, mode, dm, fl);
    eds_fix(dev, mode, dm, ok);
    return ok;
}

/* The game never changes a real display mode while hooked: the call is not forwarded, success is reported. */
static LONG WINAPI H_ChangeDisplaySettingsW(DEVMODEW *dm, DWORD fl) {
    if (FIRST(n_cds, 8)) LOG("ChangeDisplaySettingsW(%s, flags=0x%lx) blocked (not forwarded), DISP_CHANGE_SUCCESSFUL returned", dm ? "mode" : "NULL", fl);
    return DISP_CHANGE_SUCCESSFUL;
}
static LONG WINAPI H_ChangeDisplaySettingsExW(LPCWSTR dev, DEVMODEW *dm, HWND hw, DWORD fl, LPVOID p) {
    (void)hw; (void)p;
    if (FIRST(n_cds, 8)) LOG("ChangeDisplaySettingsExW(%ls, %s, flags=0x%lx) blocked (not forwarded), DISP_CHANGE_SUCCESSFUL returned", dev ? dev : L"NULL", dm ? "mode" : "NULL", fl);
    return DISP_CHANGE_SUCCESSFUL;
}

/* ------------------------------------------------------------------ IAT patching */
typedef struct { const char *name; void *hook; void **orig; int required; ULONG_PTR *slot; ULONG_PTR saved; int done; } Hook;
#define H(n, req) { #n, (void *)H_##n, (void **)&O_##n, req, NULL, 0, 0 }
static Hook g_hooks[] = {
    H(CreateWindowExW, 1), H(SetWindowPos, 1), H(GetMonitorInfoW, 1),
    H(RegisterClassExW, 0), H(SetWindowLongPtrW, 0), H(ShowWindow, 0), H(AdjustWindowRect, 0),
    H(MonitorFromWindow, 0), H(MonitorFromRect, 0), H(GetSystemMetrics, 0),
    H(SystemParametersInfoW, 0), H(SystemParametersInfoA, 0),
    H(EnumDisplaySettingsW, 0), H(EnumDisplaySettingsExW, 0),
    H(ChangeDisplaySettingsW, 0), H(ChangeDisplaySettingsExW, 0),
};
#define NHOOKS ((int)(sizeof g_hooks / sizeof g_hooks[0]))

static int write_slot(ULONG_PTR *slot, ULONG_PTR v) {
    DWORD old, tmp;
    if (!VirtualProtect(slot, sizeof *slot, PAGE_READWRITE, &old)) return 0;
    InterlockedExchangePointer((PVOID *)slot, (PVOID)v);
    VirtualProtect(slot, sizeof *slot, old, &tmp);
    return *slot == v;
}

static int rollback(void) {
    int n = 0;
    for (int i = 0; i < NHOOKS; i++)
        if (g_hooks[i].done) { if (write_slot(g_hooks[i].slot, g_hooks[i].saved)) n++; g_hooks[i].done = 0; }
    return n;
}

/* Finds the IAT slots of our functions in the exe's user32 import descriptors (by name through the import name
 * table; by address if a descriptor has no name table) and redirects them. Returns 1 on success. */
static int install_hooks(void) {
    BYTE *base = (BYTE *)GetModuleHandleW(NULL);
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    if (!u32 || dos->e_magic != IMAGE_DOS_SIGNATURE) { LOG("ERROR: no user32 / bad image"); return 0; }
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) { LOG("ERROR: not a PE32+ image"); return 0; }
    IMAGE_DATA_DIRECTORY dd = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dd.VirtualAddress) { LOG("ERROR: the exe has no import table"); return 0; }
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(base + dd.VirtualAddress); d->Name; d++) {
        if (lstrcmpiA((const char *)(base + d->Name), "user32.dll") != 0) continue;
        IMAGE_THUNK_DATA64 *iat = (IMAGE_THUNK_DATA64 *)(base + d->FirstThunk);
        IMAGE_THUNK_DATA64 *nameT = d->OriginalFirstThunk ? (IMAGE_THUNK_DATA64 *)(base + d->OriginalFirstThunk) : NULL;
        for (int i = 0; iat[i].u1.Function; i++) {
            const char *fn = NULL;
            if (nameT && !IMAGE_SNAP_BY_ORDINAL64(nameT[i].u1.Ordinal))
                fn = (const char *)((IMAGE_IMPORT_BY_NAME *)(base + nameT[i].u1.AddressOfData))->Name;
            for (int k = 0; k < NHOOKS; k++) {
                if (g_hooks[k].slot) continue;
                int hit = fn ? strcmp(fn, g_hooks[k].name) == 0
                             : iat[i].u1.Function == (ULONGLONG)(ULONG_PTR)GetProcAddress(u32, g_hooks[k].name);
                if (hit) g_hooks[k].slot = (ULONG_PTR *)&iat[i].u1.Function;
            }
        }
    }
    for (int k = 0; k < NHOOKS; k++)
        if (g_hooks[k].required && !g_hooks[k].slot) { LOG("ERROR: the exe does not import %s - not hooking anything", g_hooks[k].name); return 0; }
    int n = 0;
    for (int k = 0; k < NHOOKS; k++) {
        Hook *h = &g_hooks[k];
        if (!h->slot) { LOG("  %-26s not imported by the exe - no hook needed", h->name); continue; }
        h->saved = *h->slot;
        *h->orig = (void *)h->saved;                 /* the hook calls whatever the slot pointed to before */
        if (!write_slot(h->slot, (ULONG_PTR)h->hook)) {
            LOG("ERROR: could not write the IAT slot of %s (error %lu) - rolling back", h->name, GetLastError());
            LOG("rolled back %d slot(s)", rollback());
            return 0;
        }
        h->done = 1; n++;
        LOG("  %-26s hooked (IAT slot %p)", h->name, (void *)h->slot);
    }
    LOG("%d IAT entries redirected", n);
    return 1;
}

/* ------------------------------------------------------------------ watchdog */
static DWORD WINAPI watchdog(LPVOID unused) {
    (void)unused;
    DWORD last_stats = GetTickCount();
    LONG prev_total = -1;
    for (;;) {
        Sleep(g_watch_ms);
        HWND h = g_game;
        if (h && IsWindow(h) && IsWindowVisible(h) && !IsIconic(h)) {
            if (IsZoomed(h)) { ShowWindowAsync(h, SW_RESTORE); continue; }
            RECT wr; GetWindowRect(h, &wr);
            LONG_PTR st = GetWindowLongPtrW(h, GWL_STYLE), ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
            int bad_rect = !EqualRect(&wr, &RR), bad_style = fix_style(st) != st || fix_ex(ex) != ex;
            if (bad_rect || bad_style) {
                LONG n = InterlockedIncrement(&n_wd);
                if (n <= 20 || n % 100 == 0)
                    LOG("watchdog #%ld: window (%ld,%ld) %ldx%ld style=0x%08llx -> re-applied the rectangle%s", n, wr.left, wr.top,
                        wr.right - wr.left, wr.bottom - wr.top, (unsigned long long)st, bad_style ? " and borderless style" : "");
                apply_rect(h, 1);
            }
        }
        if (GetTickCount() - last_stats > 30000) {
            last_stats = GetTickCount();
            LONG total = n_swp + n_swl + n_show + n_adj + n_gmi + n_mfw + n_mfr + n_gsm + n_spi + n_eds + n_cds + n_wd + n_wp;
            if (total != prev_total) {
                prev_total = total;
                LOG("stats: SetWindowPos %ld, SetWindowLongPtr %ld, ShowWindow %ld, AdjustWindowRect %ld, GetMonitorInfo %ld, MonitorFromWindow %ld, "
                    "MonitorFromRect %ld, GetSystemMetrics %ld, SPI %ld, EnumDisplaySettings %ld, ChangeDisplaySettings %ld, wndproc %ld, watchdog %ld",
                    n_swp, n_swl, n_show, n_adj, n_gmi, n_mfw, n_mfr, n_gsm, n_spi, n_eds, n_cds, n_wp, n_wd);
            }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ init */
static int get_env(const wchar_t *name, wchar_t *buf, DWORD cap) {
    DWORD n = GetEnvironmentVariableW(name, buf, cap);
    if (n == 0 || n >= cap) { buf[0] = 0; return 0; }
    return 1;
}

static void clear_env(void) {
    static const wchar_t *names[] = { X4C3_ENV_RECT, X4C3_ENV_EXE, X4C3_ENV_LOGDIR, X4C3_ENV_LOGCAP,
                                      X4C3_ENV_WATCHDOG, X4C3_ENV_MATCH, X4C3_ENV_OPTS };
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) SetEnvironmentVariableW(names[i], NULL);
}

static BOOL init(void) {
    wchar_t rect[128], exe[MAX_PATH * 2], logdir[MAX_PATH * 2], cap[32], wd[32], opts[256], self[MAX_PATH * 2], logpath[MAX_PATH * 2 + 32];
    long v; const wchar_t *e;
    int have_rect = get_env(X4C3_ENV_RECT, rect, 128);
    get_env(X4C3_ENV_EXE, exe, MAX_PATH * 2);
    get_env(X4C3_ENV_OPTS, opts, 256);
    LONGLONG logcap = X4C3_LOGCAP_DEFAULT;
    if (get_env(X4C3_ENV_LOGCAP, cap, 32) && x4c3_parse_int(cap, &e, X4C3_LOGCAP_MIN, X4C3_LOGCAP_MAX, &v) && !*e) logcap = v;

    /* log file: X4C3_LOGDIR, else the DLL's own folder */
    if (!get_env(X4C3_ENV_LOGDIR, logdir, MAX_PATH * 2)) {
        DWORD n = GetModuleFileNameW(g_self, logdir, MAX_PATH * 2);
        if (!n || n >= MAX_PATH * 2) return FALSE;
        *(wchar_t *)x4c3_basename(logdir) = 0;
    }
    size_t ld = wcslen(logdir);
    if (ld && logdir[ld - 1] != L'\\') wcscat(logdir, L"\\");
    _snwprintf(logpath, sizeof logpath / sizeof logpath[0], L"%lsx4c3hook.log", logdir);
    logpath[sizeof logpath / sizeof logpath[0] - 1] = 0;
    x4c3_log_open(&g_log, logpath, logcap);

    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH * 2);
    LOG("==== x4c3hook %s loaded into %ls", X4C3_VERSION, n ? self : L"(unknown)");
    clear_env();   /* the game and anything it starts no longer see our variables */

    /* 1. the intended process? */
    const wchar_t *bn = x4c3_basename(self);
    int name_ok = lstrcmpiW(bn, L"X4.exe") == 0 || lstrcmpiW(bn, L"testtarget.exe") == 0;
    if (!n || !exe[0] || lstrcmpiW(self, exe) != 0 || !name_ok) {
        LOG("not the intended process (expected \"%ls\", this is \"%ls\") - doing nothing, DLL unloads", exe[0] ? exe : L"(not set)", self);
        return FALSE;
    }
    /* 2. a valid rectangle? */
    if (!have_rect || !x4c3_parse_rect(rect, &R)) {
        LOG("invalid or missing rectangle \"%ls\" - doing nothing, DLL unloads", rect);
        return FALSE;
    }
    SetRect(&RR, R.x, R.y, R.x + R.w, R.y + R.h);
    if (get_env(X4C3_ENV_MATCH, g_match, 64) == 0) lstrcpyW(g_match, L"X4");
    if (get_env(X4C3_ENV_WATCHDOG, wd, 32) && x4c3_parse_int(wd, &e, 100, 5000, &v) && !*e) g_watch_ms = (DWORD)v;
    if (wcsstr(opts, L"nomodes")) opt_modes = 0;
    if (wcsstr(opts, L"nowndproc")) opt_wndproc = 0;
    if (wcsstr(opts, L"nowatchdog")) opt_watchdog = 0;
    if (wcsstr(opts, L"testfail")) opt_testfail = 1;
    LOG("rectangle (%d,%d) %dx%d, window match \"%ls\", watchdog %s %lu ms, display-mode report %s, wndproc wrapper %s",
        R.x, R.y, R.w, R.h, g_match, opt_watchdog ? "on" : "off", g_watch_ms, opt_modes ? "on" : "off", opt_wndproc ? "on" : "off");

    /* 3. redirect the IAT entries */
    if (!install_hooks()) { LOG("hook installation FAILED - the game runs unchanged"); return FALSE; }
    if (opt_testfail) {
        int k = rollback();
        LOG("TEST: simulated hook installation failure after the IAT was patched - rolled back %d slot(s), the game runs unchanged", k);
        return FALSE;
    }
    if (opt_watchdog) {
        HANDLE t = CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
        if (t) CloseHandle(t); else LOG("watchdog thread could not be started (error %lu) - hooks stay active", GetLastError());
    }
    LOG("hooks ACTIVE");
    return TRUE;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID reserved) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = h;
        DisableThreadLibraryCalls(h);
        BOOL ok = init();
        if (!ok) x4c3_log_close(&g_log);
        return ok;
    }
    if (reason == DLL_PROCESS_DETACH && reserved == NULL) rollback();   /* FreeLibrary: undo; process exit: nothing */
    return TRUE;
}
