/* testtarget.c - imitates X4 9.00's window behaviour through the same user32 imports, for tests without the game.
 *
 * Measured X4 behaviour it reproduces (README "Live test result"): a framed top-level window, class and title "X4",
 * sized to the work area of its monitor (MonitorFromWindow + GetMonitorInfoW, cross-checked with
 * SystemParametersInfoW(SPI_GETWORKAREA)), that puts its own rectangle back whenever it is moved or resized
 * (in WM_WINDOWPOSCHANGED) and re-asserts its frame style and rectangle on a 1 s timer. Without the hook it therefore
 * refuses SetWindowPos from outside, exactly like the game; with the hook it must end up borderless at the rectangle.
 *
 * Every second it writes what it observes (client size, window rect, style, what GetMonitorInfoW / GetSystemMetrics /
 * SystemParametersInfoW / AdjustWindowRect / EnumDisplaySettingsW return to it) to --log.
 *
 *   testtarget.exe [--hidden] [--seconds N] [--log <path>] [--no-reapply] [--try-cds]
 *   --hidden     fully transparent (alpha 0), click-through, never activated, not in the taskbar, bottom of the
 *                z-order: nothing is visible even when the window spans every monitor.
 *   --seconds    exits by itself after N seconds (default 20, max 600).
 *   --no-reapply does not defend its rectangle/style (to test the hook's watchdog alone).
 *   --try-cds    calls ChangeDisplaySettingsExW(CDS_TEST, empty mode) ONLY if its import slot no longer points into
 *                user32 (i.e. the hook replaced it), so the real function is never called by this program.
 */
#include "x4c3.h"

static X4C3Log g_log;
static HWND g_hwnd;
static int o_hidden, o_noreapply, o_trycds, g_reapplies, g_stylefix, g_tick, g_inreapply;
static DWORD g_seconds = 20;

#define LOG(...) logf_(__VA_ARGS__)
static void logf_(const char *fmt, ...) { va_list ap; va_start(ap, fmt); x4c3_log_v(&g_log, fmt, ap); va_end(ap); }

/* The rectangle the "game" wants: the work area of the monitor it is on. */
static RECT target_rect(void) {
    MONITORINFO mi; mi.cbSize = sizeof mi;
    HMONITOR m = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTOPRIMARY);
    if (m && GetMonitorInfoW(m, &mi)) return mi.rcWork;
    RECT wa; SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    return wa;
}

static void reapply(int frame) {
    RECT t = target_rect();
    g_inreapply = 1; g_reapplies++;
    SetWindowPos(g_hwnd, NULL, t.left, t.top, t.right - t.left, t.bottom - t.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | (frame ? SWP_FRAMECHANGED : 0));
    g_inreapply = 0;
}

static void report(void) {
    RECT wr, cr, mon = { 0 }, work = { 0 }, spi = { 0 }, adj = { 100, 100, 500, 400 };
    MONITORINFO mi; mi.cbSize = sizeof mi;
    DEVMODEW dm; memset(&dm, 0, sizeof dm); dm.dmSize = sizeof dm;
    GetWindowRect(g_hwnd, &wr); GetClientRect(g_hwnd, &cr);
    HMONITOR m = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
    if (GetMonitorInfoW(m, &mi)) { mon = mi.rcMonitor; work = mi.rcWork; }
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &spi, 0);
    AdjustWindowRect(&adj, WS_OVERLAPPEDWINDOW, FALSE);
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &dm);
    HMONITOR mr = MonitorFromRect(&wr, MONITOR_DEFAULTTONEAREST);
    LONG_PTR st = GetWindowLongPtrW(g_hwnd, GWL_STYLE), ex = GetWindowLongPtrW(g_hwnd, GWL_EXSTYLE);
    LOG("tick=%d client=%ldx%ld window=%ld,%ld,%ld,%ld style=0x%08llx ex=0x%08llx mon=%ld,%ld,%ld,%ld work=%ld,%ld,%ld,%ld "
        "spiwork=%ld,%ld,%ld,%ld cx=%d cy=%d vx=%d vy=%d vcx=%d vcy=%d adj=%ld,%ld,%ld,%ld mode=%lux%lu@%ld,%ld mfr_eq_mfw=%d "
        "reapplies=%d stylefix=%d",
        g_tick, cr.right, cr.bottom, wr.left, wr.top, wr.right - wr.left, wr.bottom - wr.top,
        (unsigned long long)st, (unsigned long long)ex, mon.left, mon.top, mon.right, mon.bottom,
        work.left, work.top, work.right, work.bottom, spi.left, spi.top, spi.right, spi.bottom,
        GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN),
        adj.left, adj.top, adj.right, adj.bottom, dm.dmPelsWidth, dm.dmPelsHeight, dm.dmPosition.x, dm.dmPosition.y,
        mr == m, g_reapplies, g_stylefix);
}

static void try_cds(void) {
    void *slot = (void *)&ChangeDisplaySettingsExW;   /* dllimport: this reads the current import-table entry */
    void *real = (void *)GetProcAddress(GetModuleHandleW(L"user32.dll"), "ChangeDisplaySettingsExW");
    if (slot == real) { LOG("cds: import slot points into user32 (not hooked) - call skipped"); return; }
    DEVMODEW dm; memset(&dm, 0, sizeof dm); dm.dmSize = sizeof dm;   /* dmFields = 0: nothing to change even if real */
    LONG r = ChangeDisplaySettingsExW(NULL, &dm, NULL, CDS_TEST, NULL);
    LOG("cds: hooked ChangeDisplaySettingsExW(CDS_TEST) returned %ld", r);
}

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_WINDOWPOSCHANGED:
        if (g_hwnd && !o_noreapply && !g_inreapply && !IsIconic(h)) {
            RECT wr, t = target_rect(); GetWindowRect(h, &wr);
            if (!EqualRect(&wr, &t)) reapply(0);   /* like X4: put my own rectangle back at once */
        }
        break;
    case WM_TIMER:
        if (w == 1) {
            g_tick++;
            if (!o_noreapply && !IsIconic(h)) {
                LONG_PTR st = GetWindowLongPtrW(h, GWL_STYLE);
                if ((st & WS_OVERLAPPEDWINDOW) != WS_OVERLAPPEDWINDOW || (st & WS_POPUP)) {   /* re-assert my frame */
                    SetWindowLongPtrW(h, GWL_STYLE, (st & ~(LONG_PTR)WS_POPUP) | WS_OVERLAPPEDWINDOW);
                    g_stylefix++;
                }
                reapply(1);
            }
            report();
        } else if (w == 2) DestroyWindow(h);
        return 0;
    case WM_MOUSEACTIVATE:
        if (o_hidden) return MA_NOACTIVATE;
        break;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

int main(void) {
    static X4C3Arg args[32];
    int argc = x4c3_split_cmdline(GetCommandLineW(), args, 32);
    wchar_t logPath[MAX_PATH * 2], self[MAX_PATH * 2];
    long v; const wchar_t *e;
    GetModuleFileNameW(NULL, self, MAX_PATH * 2);
    lstrcpyW(logPath, self); *(wchar_t *)x4c3_basename(logPath) = 0; wcscat(logPath, L"testtarget.log");
    for (int i = 0; i < argc; i++) {
        const wchar_t *a = args[i].val, *nx = i + 1 < argc ? args[i + 1].val : NULL;
        if (!lstrcmpW(a, L"--hidden")) o_hidden = 1;
        else if (!lstrcmpW(a, L"--no-reapply")) o_noreapply = 1;
        else if (!lstrcmpW(a, L"--try-cds")) o_trycds = 1;
        else if (!lstrcmpW(a, L"--seconds") && nx) { if (x4c3_parse_int(nx, &e, 1, 600, &v) && !*e) g_seconds = (DWORD)v; i++; }
        else if (!lstrcmpW(a, L"--log") && nx) { lstrcpynW(logPath, nx, MAX_PATH * 2); i++; }
        /* anything else (e.g. the game arguments "-debug all") is ignored, like a game would */
    }
    x4c3_log_open(&g_log, logPath, 4 * 1024 * 1024);
    LOG("testtarget start pid=%lu exe=%ls hidden=%d noreapply=%d seconds=%lu cmdline=%ls", GetCurrentProcessId(), self,
        o_hidden, o_noreapply, g_seconds, GetCommandLineW());

    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSEXW wc; memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc; wc.lpfnWndProc = wndproc; wc.hInstance = inst; wc.lpszClassName = L"X4";
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW); wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    if (!RegisterClassExW(&wc)) { LOG("RegisterClassExW failed %lu", GetLastError()); return 1; }

    RECT wa; SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);   /* primary work area, as the game's first guess */
    DWORD ex = o_hidden ? (WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) : 0;
    g_hwnd = CreateWindowExW(ex, L"X4", L"X4", WS_OVERLAPPEDWINDOW, wa.left, wa.top, wa.right - wa.left,
                             wa.bottom - wa.top, NULL, NULL, inst, NULL);
    if (!g_hwnd) { LOG("CreateWindowExW failed %lu", GetLastError()); return 1; }
    if (o_hidden) SetLayeredWindowAttributes(g_hwnd, 0, 0, LWA_ALPHA);
    LOG("created hwnd=0x%llx", (unsigned long long)(ULONG_PTR)g_hwnd);
    ShowWindow(g_hwnd, o_hidden ? SW_SHOWNOACTIVATE : SW_SHOWNORMAL);
    if (o_hidden) SetWindowPos(g_hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    if (!o_noreapply) reapply(0);   /* now that it exists: fit it to the work area of its monitor */
    report();
    if (o_trycds) try_cds();
    SetTimer(g_hwnd, 1, 1000, NULL);
    SetTimer(g_hwnd, 2, g_seconds * 1000, NULL);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    LOG("testtarget exit");
    x4c3_log_close(&g_log);
    return 0;
}
