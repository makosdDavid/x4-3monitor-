/* X4Switch - the window: two large choices, a status panel, secondary actions, a details log, and a settings
 * window. Plain Win32 + GDI, owner-drawn controls, dark theme, per-monitor DPI aware, keyboard usable. */
#include "x4switch.h"
#include <commdlg.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <shellapi.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

int gui_run(Settings *s, const wchar_t *smokeFile, const wchar_t *renderFile, int holdMs);

/* ---- colours */
#define RGBC(r, g, b) RGB(r, g, b)
static const COLORREF CBG = RGBC(0x15, 0x17, 0x1c), CSURF = RGBC(0x1e, 0x22, 0x2a), CSURF2 = RGBC(0x26, 0x2b, 0x35),
                      CSURF3 = RGBC(0x2e, 0x34, 0x40), CBORDER = RGBC(0x34, 0x3a, 0x47), CTEXT = RGBC(0xe8, 0xeb, 0xf0),
                      CMUTED = RGBC(0x98, 0xa1, 0xb0), CACC = RGBC(0x3d, 0x8b, 0xfd), CACC2 = RGBC(0x5c, 0x9e, 0xff),
                      COK = RGBC(0x3f, 0xb9, 0x50), CWARN = RGBC(0xd2, 0x99, 0x22), CBAD = RGBC(0xf8, 0x51, 0x49),
                      CIDLE = RGBC(0x6e, 0x76, 0x81), CINFO = RGBC(0x58, 0xa6, 0xff), CEDIT = RGBC(0x12, 0x14, 0x18);
static COLORREF level_color(int c) { switch (c) { case C_OK: return COK; case C_WARN: return CWARN; case C_BAD: return CBAD; case C_INFO: return CINFO; default: return CIDLE; } }

/* ---- ids */
enum { ID_CARD_C = 101, ID_CARD_S, ID_START, ID_SWITCH, ID_DASH, ID_MON, ID_LOGS, ID_SETTINGS, ID_REFRESH, ID_LANG,
       ID_ROW0 = 120, ID_DETAILS = 130,
       ID_S_GAME = 201, ID_S_BROWSE, ID_S_ARGS, ID_S_RECT, ID_S_LAUTO, ID_S_LEN, ID_S_LHU, ID_S_CLOSE, ID_S_SAVE, ID_S_CANCEL,
       ID_S_L1, ID_S_L2, ID_S_L3, ID_S_L4, ID_S_H2, ID_S_H3, ID_S_PATHS, ID_S_ERR };
#define WM_APP_LINE (WM_APP + 1)
#define WM_APP_DONE (WM_APP + 2)
#define WM_APP_STATUS (WM_APP + 3)
#define TIMER_QUICK 1
#define TIMER_CLOSE 2

typedef struct {
    HWND hwnd, set;
    Settings *s;
    Status st;
    int sel, busy, statusBusy, pendingSlow, dpi, smoke;
    HFONT fTitle, fSub, fCardTitle, fBody, fSmall, fMono, fButton, fStart;
    HBRUSH brBg, brSurf, brEdit;
    HWND card[2], start, sec[6], lang, row[5], details;
    /* settings window */
    HWND sGame, sArgs, sRect, sLang[3], sClose, sErr;
    int sLangSel, sCloseOn;
    WNDPROC btnProc;
} App;
static App A;
int g_smokeSave = 0;   /* --smoke-save: the smoke test may persist the keyboard selection (tests 'remember the last choice') */

static int S(int v) { return MulDiv(v, A.dpi ? A.dpi : 96, 96); }

static HFONT mkfont(int pt10, int weight, const wchar_t *face) {
    /* pt10 = size in tenths of a point */
    return CreateFontW(-MulDiv(pt10, A.dpi ? A.dpi : 96, 720), 0, 0, 0, weight, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, face);
}
static void fonts_free(void) {
    HFONT *f[] = { &A.fTitle, &A.fSub, &A.fCardTitle, &A.fBody, &A.fSmall, &A.fMono, &A.fButton, &A.fStart };
    for (unsigned i = 0; i < sizeof f / sizeof f[0]; i++) if (*f[i]) { DeleteObject(*f[i]); *f[i] = NULL; }
}
static void fonts_make(void) {
    fonts_free();
    A.fTitle = mkfont(180, FW_SEMIBOLD, L"Segoe UI");
    A.fSub = mkfont(100, FW_NORMAL, L"Segoe UI");
    A.fCardTitle = mkfont(125, FW_SEMIBOLD, L"Segoe UI");
    A.fBody = mkfont(95, FW_NORMAL, L"Segoe UI");
    A.fSmall = mkfont(90, FW_NORMAL, L"Segoe UI");
    A.fMono = mkfont(90, FW_NORMAL, L"Consolas");
    A.fButton = mkfont(95, FW_NORMAL, L"Segoe UI");
    A.fStart = mkfont(120, FW_SEMIBOLD, L"Segoe UI");
}

/* ---- drawing helpers */
static void fill_round(HDC dc, RECT r, int rad, COLORREF fill, COLORREF border, int bw) {
    HBRUSH b = CreateSolidBrush(fill);
    HPEN p = bw ? CreatePen(PS_SOLID, bw, border) : (HPEN)GetStockObject(NULL_PEN);
    HGDIOBJ ob = SelectObject(dc, b), op = SelectObject(dc, p);
    if (bw > 1) InflateRect(&r, -(bw / 2), -(bw / 2));
    RoundRect(dc, r.left, r.top, r.right, r.bottom, rad, rad);
    SelectObject(dc, ob); SelectObject(dc, op);
    DeleteObject(b); if (bw) DeleteObject(p);
}
static void dot(HDC dc, int cx, int cy, int d, COLORREF c) {
    HBRUSH b = CreateSolidBrush(c); HGDIOBJ ob = SelectObject(dc, b), op = SelectObject(dc, GetStockObject(NULL_PEN));
    Ellipse(dc, cx - d / 2, cy - d / 2, cx + d / 2 + 1, cy + d / 2 + 1);
    SelectObject(dc, ob); SelectObject(dc, op); DeleteObject(b);
}
static void text(HDC dc, const wchar_t *t, RECT r, HFONT f, COLORREF c, UINT fmt) {
    HGDIOBJ of = SelectObject(dc, f); SetTextColor(dc, c); SetBkMode(dc, TRANSPARENT);
    DrawTextW(dc, t, -1, &r, fmt | DT_NOPREFIX);
    SelectObject(dc, of);
}
static void frame(HDC dc, int x, int y, int w, int h, COLORREF c, int pw) {
    HPEN p = CreatePen(PS_SOLID, pw, c); HGDIOBJ op = SelectObject(dc, p), ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
    Rectangle(dc, x, y, x + w, y + h);
    SelectObject(dc, op); SelectObject(dc, ob); DeleteObject(p);
}

static void draw_icon(HDC dc, int mode, int x, int y, int sel) {
    COLORREF c = sel ? CACC2 : CMUTED;
    int pw = S(2) > 1 ? S(2) : 1;
    if (mode == MODE_COCKPIT) {
        /* side | centre | side */
        frame(dc, x, y + S(8), S(18), S(20), c, pw);
        frame(dc, x + S(20), y + S(2), S(36), S(32), c, pw);
        frame(dc, x + S(58), y + S(8), S(18), S(20), c, pw);
        HBRUSH b = CreateSolidBrush(sel ? CACC : CSURF3); RECT r = { x + S(23), y + S(5), x + S(53), y + S(31) };
        FillRect(dc, &r, b); DeleteObject(b);
    } else {
        frame(dc, x + S(4), y + S(2), S(44), S(32), c, pw);
        HBRUSH b = CreateSolidBrush(sel ? CACC : CSURF3); RECT r = { x + S(7), y + S(5), x + S(45), y + S(31) };
        FillRect(dc, &r, b); DeleteObject(b);
        /* the browser dashboard beside it */
        frame(dc, x + S(54), y + S(10), S(24), S(20), c, pw);
        RECT bar = { x + S(54), y + S(10), x + S(78), y + S(14) }; HBRUSH bb = CreateSolidBrush(c); FillRect(dc, &bar, bb); DeleteObject(bb);
        dot(dc, x + S(66), y + S(22), S(6), sel ? COK : CMUTED);
    }
}

/* ---- owner-drawn controls */
static void draw_card(HDC dc, RECT rc, int mode, UINT state, int hover) {
    int sel = A.sel == mode;
    int disabled = (state & ODS_DISABLED) != 0;
    HBRUSH bg = CreateSolidBrush(CBG); FillRect(dc, &rc, bg); DeleteObject(bg);
    COLORREF fill = sel ? CSURF3 : (hover ? CSURF2 : CSURF);
    COLORREF border = sel ? CACC : (hover ? CBORDER : CSURF2);
    fill_round(dc, rc, S(14), fill, border, sel ? S(2) : 1);
    int pad = S(18);
    draw_icon(dc, mode, rc.left + pad, rc.top + S(20), sel);
    /* radio mark */
    int rx = rc.right - S(26), ry = rc.top + S(26);
    dot(dc, rx, ry, S(18), sel ? CACC : CBORDER);
    dot(dc, rx, ry, S(12), sel ? CSURF3 : fill);
    if (sel) dot(dc, rx, ry, S(8), CACC2);
    RECT t = { rc.left + pad + S(92), rc.top + S(18), rc.right - S(44), rc.top + S(44) };
    text(dc, tr(mode == MODE_COCKPIT ? S_COCKPIT_TITLE : S_SINGLE_TITLE), t, A.fCardTitle, disabled ? CMUTED : CTEXT, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    wchar_t st[300]; int col = C_IDLE;
    if (A.s) status_card(&A.st, mode, st, 300, &col); else st[0] = 0;
    dot(dc, t.left + S(5), rc.top + S(56), S(8), level_color(col));
    RECT sr = { t.left + S(16), rc.top + S(46), rc.right - S(16), rc.top + S(66) };
    text(dc, st, sr, A.fSmall, level_color(col) == CIDLE ? CMUTED : level_color(col), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    RECT d = { rc.left + pad, rc.top + S(84), rc.right - pad, rc.bottom - S(14) };
    text(dc, tr(mode == MODE_COCKPIT ? S_COCKPIT_DESC : S_SINGLE_DESC), d, A.fBody, CMUTED, DT_LEFT | DT_WORDBREAK);
    if ((state & ODS_FOCUS) && !(state & ODS_NOFOCUSRECT)) {
        RECT f = rc; InflateRect(&f, -S(5), -S(5));
        HPEN p = CreatePen(PS_DOT, 1, CTEXT); HGDIOBJ op = SelectObject(dc, p), ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
        RoundRect(dc, f.left, f.top, f.right, f.bottom, S(10), S(10)); SelectObject(dc, op); SelectObject(dc, ob); DeleteObject(p);
    }
}

static void draw_button(HDC dc, RECT rc, HWND h, UINT state, int hover, int primary, int segSel) {
    HBRUSH bg = CreateSolidBrush(GetParent(h) == A.set ? CBG : CBG); FillRect(dc, &rc, bg); DeleteObject(bg);
    int disabled = (state & ODS_DISABLED) != 0, pressed = (state & ODS_SELECTED) != 0;
    COLORREF fill, border, tc;
    if (primary) { fill = disabled ? CSURF2 : (pressed ? CACC : (hover ? CACC2 : CACC)); border = fill; tc = disabled ? CMUTED : RGB(255, 255, 255); }
    else if (segSel) { fill = CACC; border = CACC; tc = RGB(255, 255, 255); }
    else { fill = pressed ? CSURF3 : (hover ? CSURF3 : CSURF2); border = hover ? CACC : CBORDER; tc = disabled ? CIDLE : CTEXT; }
    fill_round(dc, rc, S(10), fill, border, 1);
    wchar_t t[400]; GetWindowTextW(h, t, 400);
    RECT tr_ = rc; InflateRect(&tr_, -S(8), -S(4));
    HFONT f = primary ? A.fStart : A.fButton;
    /* centre vertically, allow two lines */
    RECT calc = tr_; HGDIOBJ of = SelectObject(dc, f);
    DrawTextW(dc, t, -1, &calc, DT_CENTER | DT_WORDBREAK | DT_CALCRECT | DT_NOPREFIX);
    SelectObject(dc, of);
    int hgt = calc.bottom - calc.top; int top = tr_.top + ((tr_.bottom - tr_.top) - hgt) / 2;
    RECT dr = { tr_.left, top, tr_.right, top + hgt };
    text(dc, t, dr, f, tc, DT_CENTER | DT_WORDBREAK);
    if ((state & ODS_FOCUS) && !(state & ODS_NOFOCUSRECT)) {
        RECT fr = rc; InflateRect(&fr, -S(3), -S(3));
        HPEN p = CreatePen(PS_DOT, 1, primary ? RGB(255, 255, 255) : CTEXT); HGDIOBJ op = SelectObject(dc, p), ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
        RoundRect(dc, fr.left, fr.top, fr.right, fr.bottom, S(8), S(8)); SelectObject(dc, op); SelectObject(dc, ob); DeleteObject(p);
    }
}

static void draw_toggle(HDC dc, RECT rc, HWND h, UINT state, int hover, int on) {
    HBRUSH bg = CreateSolidBrush(CBG); FillRect(dc, &rc, bg); DeleteObject(bg);
    int tw = S(40), th = S(22), y = rc.top + (rc.bottom - rc.top - th) / 2;
    RECT tg = { rc.left, y, rc.left + tw, y + th };
    fill_round(dc, tg, th, on ? CACC : CSURF3, hover ? CACC2 : CBORDER, 1);
    dot(dc, on ? tg.right - th / 2 : tg.left + th / 2, y + th / 2, th - S(8), RGB(255, 255, 255));
    wchar_t t[300]; GetWindowTextW(h, t, 300);
    RECT tr_ = { rc.left + tw + S(12), rc.top, rc.right, rc.bottom };
    text(dc, t, tr_, A.fBody, CTEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    if ((state & ODS_FOCUS) && !(state & ODS_NOFOCUSRECT)) { RECT f = tg; InflateRect(&f, S(3), S(3)); DrawFocusRect(dc, &f); }
}

static void draw_row(HDC dc, RECT rc, HWND h) {
    HBRUSH bg = CreateSolidBrush(CSURF); FillRect(dc, &rc, bg); DeleteObject(bg);
    wchar_t t[900]; GetWindowTextW(h, t, 900);
    wchar_t *tab = wcschr(t, L'\t'); const wchar_t *val = L"";
    if (tab) { *tab = 0; val = tab + 1; }
    int col = (int)GetWindowLongPtrW(h, GWLP_USERDATA);
    int cy = (rc.top + rc.bottom) / 2;
    dot(dc, rc.left + S(6), cy, S(9), level_color(col));
    RECT lr = { rc.left + S(20), rc.top, rc.left + S(140), rc.bottom };
    text(dc, t, lr, A.fBody, CMUTED, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    RECT vr = { rc.left + S(140), rc.top, rc.right, rc.bottom };
    text(dc, val, vr, A.fBody, CTEXT, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
}

static void draw_item(DRAWITEMSTRUCT *di) {
    HWND h = di->hwndItem; int id = (int)di->CtlID;
    int hover = (int)(INT_PTR)GetPropW(h, L"x4hover");
    if (id == ID_CARD_C || id == ID_CARD_S) draw_card(di->hDC, di->rcItem, id == ID_CARD_C ? MODE_COCKPIT : MODE_SINGLE, di->itemState, hover);
    else if (id >= ID_ROW0 && id < ID_ROW0 + 5) draw_row(di->hDC, di->rcItem, h);
    else if (id == ID_S_CLOSE) draw_toggle(di->hDC, di->rcItem, h, di->itemState, hover, A.sCloseOn);
    else if (id >= ID_S_LAUTO && id <= ID_S_LHU) draw_button(di->hDC, di->rcItem, h, di->itemState, hover, 0, A.sLangSel == id - ID_S_LAUTO);
    else draw_button(di->hDC, di->rcItem, h, di->itemState, hover, id == ID_START || id == ID_S_SAVE, 0);
}

/* hover + hand cursor for every owner-drawn button */
static LRESULT CALLBACK btn_sub(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_MOUSEMOVE:
        if (!GetPropW(h, L"x4hover")) {
            SetPropW(h, L"x4hover", (HANDLE)1); InvalidateRect(h, NULL, FALSE);
            TRACKMOUSEEVENT t = { sizeof t, TME_LEAVE, h, 0 }; TrackMouseEvent(&t);
        }
        break;
    case WM_MOUSELEAVE: RemovePropW(h, L"x4hover"); InvalidateRect(h, NULL, FALSE); break;
    case WM_SETCURSOR: SetCursor(LoadCursorW(NULL, (LPCWSTR)IDC_HAND)); return TRUE;
    case WM_NCDESTROY: RemovePropW(h, L"x4hover"); break;
    }
    return CallWindowProcW(A.btnProc, h, m, w, l);
}

static HWND mkbtn(HWND parent, int id, const wchar_t *t) {
    HWND h = CreateWindowExW(0, L"BUTTON", t, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW | BS_NOTIFY, 0, 0, 10, 10, parent, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
    WNDPROC old = (WNDPROC)SetWindowLongPtrW(h, GWLP_WNDPROC, (LONG_PTR)btn_sub);
    if (!A.btnProc) A.btnProc = old;
    return h;
}

/* ---- texts */
static void set_start_text(void) {
    wchar_t t[300];
    if (A.busy) wcscpy(t, tr(S_WORKING));
    else _snwprintf(t, 300, tr(S_START_FMT), tr(A.sel == MODE_COCKPIT ? S_COCKPIT_TITLE : S_SINGLE_TITLE));
    t[299] = 0;
    SetWindowTextW(A.start, t);
    InvalidateRect(A.start, NULL, FALSE);
}

static void apply_status(void) {
    wchar_t lines[5][700]; int col[5];
    status_lines(&A.st, A.s, lines, col);
    static const StrId lab[5] = { S_ST_GAME, S_ST_CONFIG, S_ST_MONITORS, S_ST_DASH, S_ST_HOOK };
    for (int i = 0; i < 5; i++) {
        wchar_t t[900]; _snwprintf(t, 900, L"%ls\t%ls", tr(lab[i]), lines[i]); t[899] = 0;
        SetWindowTextW(A.row[i], t);
        SetWindowLongPtrW(A.row[i], GWLP_USERDATA, col[i]);
        InvalidateRect(A.row[i], NULL, FALSE);
    }
    /* card texts mirror what is drawn (for accessibility tools and the smoke test) */
    for (int m = 0; m < 2; m++) {
        wchar_t st[300], t[900]; int c;
        status_card(&A.st, m, st, 300, &c);
        _snwprintf(t, 900, L"%ls\n%ls\n%ls", tr(m == MODE_COCKPIT ? S_COCKPIT_TITLE : S_SINGLE_TITLE), tr(m == MODE_COCKPIT ? S_COCKPIT_DESC : S_SINGLE_DESC), st);
        t[899] = 0;
        SetWindowTextW(A.card[m], t);
        InvalidateRect(A.card[m], NULL, FALSE);
    }
}

static void apply_texts(void) {
    SetWindowTextW(A.hwnd, tr(S_APP_TITLE));
    static const StrId sec[6] = { S_SWITCH_ONLY, S_OPEN_DASH, S_CHECK_MON, S_OPEN_LOGS, S_SETTINGS, S_REFRESH };
    for (int i = 0; i < 6; i++) { SetWindowTextW(A.sec[i], tr(sec[i])); InvalidateRect(A.sec[i], NULL, FALSE); }
    SetWindowTextW(A.lang, tr(S_LANG_TOGGLE)); InvalidateRect(A.lang, NULL, FALSE);
    set_start_text();
    apply_status();
    InvalidateRect(A.hwnd, NULL, TRUE);
}

/* ---- layout (DIP: client 900 x 670) */
#define CW 900
#define CH 670
static void layout(void) {
    int M = S(24), W = S(CW);
    int cw = (W - 2 * M - S(16)) / 2;
    MoveWindow(A.lang, W - M - S(92), S(22), S(92), S(30), FALSE);
    MoveWindow(A.card[0], M, S(88), cw, S(156), FALSE);
    MoveWindow(A.card[1], M + cw + S(16), S(88), cw, S(156), FALSE);
    MoveWindow(A.start, M, S(258), W - 2 * M, S(52), FALSE);
    for (int i = 0; i < 5; i++) MoveWindow(A.row[i], M + S(16), S(366) + i * S(26), W - 2 * M - S(32), S(24), FALSE);
    int bw = (W - 2 * M - 5 * S(8)) / 6;
    for (int i = 0; i < 6; i++) MoveWindow(A.sec[i], M + i * (bw + S(8)), S(512), bw, S(46), FALSE);
    MoveWindow(A.details, M + S(10), S(574), W - 2 * M - S(20), S(62), FALSE);
    SendMessageW(A.details, WM_SETFONT, (WPARAM)A.fMono, FALSE);
    InvalidateRect(A.hwnd, NULL, TRUE);
}

static void paint_main(HDC dc, RECT rc) {
    HBRUSH bg = CreateSolidBrush(CBG); FillRect(dc, &rc, bg); DeleteObject(bg);
    int M = S(24), W = S(CW);
    RECT t = { M, S(16), W - M - S(110), S(50) };
    text(dc, tr(S_APP_TITLE), t, A.fTitle, CTEXT, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
    RECT st = { M, S(52), W - M - S(110), S(76) };
    text(dc, tr(S_SUBTITLE), st, A.fSub, CMUTED, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
    /* status panel */
    RECT p = { M, S(326), W - M, S(500) };
    fill_round(dc, p, S(14), CSURF, CSURF2, 1);
    RECT ph = { M + S(16), S(334), W - M - S(16), S(360) };
    text(dc, tr(S_STATUS), ph, A.fCardTitle, CTEXT, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
    /* details box */
    RECT d = { M, S(568), W - M, S(642) };
    fill_round(dc, d, S(10), CEDIT, CSURF2, 1);
    RECT h = { M, S(646), W - M, S(666) };
    text(dc, tr(S_HINT), h, A.fSmall, CIDLE, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
    wchar_t v[80]; _snwprintf(v, 80, L"X4Switch %ls", X4S_VERSION); v[79] = 0;
    text(dc, v, h, A.fSmall, CIDLE, DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
}

/* ---- details log */
static void details_add(int kind, const wchar_t *msg) {
    static const wchar_t *P[] = { L"·  ", L"[ok] ", L"[!]  ", L"[x]  ", L"     ", L"»  " };
    int len = GetWindowTextLengthW(A.details);
    if (len > 60000) { SetWindowTextW(A.details, L""); len = 0; }
    wchar_t *line = (wchar_t *)x4_alloc((wcslen(msg) + 16) * sizeof(wchar_t));
    if (!line) return;
    lstrcpyW(line, len ? L"\r\n" : L""); lstrcatW(line, P[kind < 0 || kind > 5 ? 0 : kind]); lstrcatW(line, msg);
    SendMessageW(A.details, EM_SETSEL, (WPARAM)len, (LPARAM)len);
    SendMessageW(A.details, EM_REPLACESEL, FALSE, (LPARAM)line);
    SendMessageW(A.details, EM_SCROLLCARET, 0, 0);
    x4_free(line);
}

/* ---- background work */
typedef struct { Settings s; int kind, mode, start; } Job;
enum { JOB_MODE = 1, JOB_DASH, JOB_MON };

static void gui_report(void *ctx, int kind, const wchar_t *t) {
    size_t n = wcslen(t) + 1;
    wchar_t *c = (wchar_t *)x4_alloc(n * sizeof(wchar_t));
    if (!c) return;
    memcpy(c, t, n * sizeof(wchar_t));
    if (!PostMessageW(A.hwnd, WM_APP_LINE, (WPARAM)kind, (LPARAM)c)) x4_free(c);
}

static DWORD WINAPI job_thread(LPVOID p) {
    Job *j = (Job *)p;
    HRESULT hi = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    Reporter r = { gui_report, NULL };
    ActionResult *res = (ActionResult *)x4_alloc(sizeof(ActionResult));
    if (j->kind == JOB_MODE) action_mode(&j->s, j->mode, j->start, 0, &r, res);
    else if (j->kind == JOB_DASH) action_open_dashboard(&j->s, 0, &r, res);
    else action_check_monitors(&j->s, &r, res);
    res->hookActive |= (j->kind == JOB_MODE && j->start) ? 0x100 : 0;   /* marks "a start was attempted" */
    if (SUCCEEDED(hi)) CoUninitialize();
    x4_free(j);
    if (!PostMessageW(A.hwnd, WM_APP_DONE, 0, (LPARAM)res)) x4_free(res);
    return 0;
}

typedef struct { Settings s; Status st; int slow; } StJob;
static DWORD WINAPI status_thread(LPVOID p) {
    StJob *j = (StJob *)p;
    HRESULT hi = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (j->slow) { Status fresh; memset(&fresh, 0, sizeof fresh); status_slow(&j->s, &fresh); j->st = fresh; }
    else status_quick(&j->s, &j->st);
    if (SUCCEEDED(hi)) CoUninitialize();
    Status *out = (Status *)x4_alloc(sizeof(Status));
    if (out) *out = j->st;
    x4_free(j);
    if (!out || !PostMessageW(A.hwnd, WM_APP_STATUS, 0, (LPARAM)out)) x4_free(out);
    return 0;
}

static void refresh(int slow) {
    if (A.statusBusy) { if (slow) A.pendingSlow = 1; return; }
    StJob *j = (StJob *)x4_alloc(sizeof(StJob));
    if (!j) return;
    j->s = *A.s; j->s.doc = NULL; j->st = A.st; j->slow = slow;
    A.statusBusy = 1;
    HANDLE t = CreateThread(NULL, 0, status_thread, j, 0, NULL);
    if (t) CloseHandle(t); else { A.statusBusy = 0; x4_free(j); }
}

static void set_busy(int b) {
    A.busy = b;
    int ids[] = { 0, 1 };
    for (int i = 0; i < 2; i++) EnableWindow(A.card[ids[i]], !b);
    EnableWindow(A.start, !b);
    EnableWindow(A.sec[0], !b); EnableWindow(A.sec[1], !b); EnableWindow(A.sec[2], !b); EnableWindow(A.sec[4], !b);
    set_start_text();
}

static void run_job(int kind, int mode, int start) {
    if (A.busy) { details_add(K_WARN, tr(M_BUSY)); return; }
    Job *j = (Job *)x4_alloc(sizeof(Job));
    if (!j) return;
    j->s = *A.s; j->s.doc = NULL; j->kind = kind; j->mode = mode; j->start = start;
    set_busy(1);
    HANDLE t = CreateThread(NULL, 0, job_thread, j, 0, NULL);
    if (t) CloseHandle(t); else { set_busy(0); x4_free(j); }
}

static void select_mode(int m, int save) {
    if (A.sel == m && !save) return;
    A.sel = m;
    InvalidateRect(A.card[0], NULL, FALSE); InvalidateRect(A.card[1], NULL, FALSE);
    set_start_text();
    if (save && wcscmp(A.s->lastMode, m == MODE_COCKPIT ? L"cockpit" : L"single")) {
        wcscpy(A.s->lastMode, m == MODE_COCKPIT ? L"cockpit" : L"single");
        if (!A.smoke || g_smokeSave) settings_save(A.s);
    }
}

static void open_logs(void) {
    CreateDirectoryW(A.s->logDir, NULL);
    ShellExecuteW(A.hwnd, L"open", A.s->logDir, NULL, NULL, SW_SHOWNORMAL);
}

/* ---- settings window */
static void settings_open(void);

static void toggle_lang(void) {
    const wchar_t *now = i18n_lang();
    wcscpy(A.s->language, wcscmp(now, L"hu") ? L"hu" : L"en");
    i18n_set(A.s->language);
    if (!A.smoke) settings_save(A.s);
    apply_texts();
}

static void command(int id, int code) {
    switch (id) {
    case ID_CARD_C: case ID_CARD_S: {
        int m = id == ID_CARD_C ? MODE_COCKPIT : MODE_SINGLE;
        if (code == BN_CLICKED) select_mode(m, 1);
        else if (code == BN_DOUBLECLICKED) { select_mode(m, 1); run_job(JOB_MODE, A.sel, 1); }
        break;
    }
    case ID_START: run_job(JOB_MODE, A.sel, 1); break;
    case ID_SWITCH: run_job(JOB_MODE, A.sel, 0); break;
    case ID_DASH: run_job(JOB_DASH, 0, 0); break;
    case ID_MON: run_job(JOB_MON, 0, 0); break;
    case ID_LOGS: open_logs(); break;
    case ID_SETTINGS: settings_open(); break;
    case ID_REFRESH: refresh(1); break;
    case ID_LANG: toggle_lang(); break;
    }
}

static void dpi_changed(int dpi) {
    A.dpi = dpi;
    fonts_make();
    HWND kids[] = { A.card[0], A.card[1], A.start, A.lang, A.sec[0], A.sec[1], A.sec[2], A.sec[3], A.sec[4], A.sec[5] };
    for (unsigned i = 0; i < sizeof kids / sizeof kids[0]; i++) SendMessageW(kids[i], WM_SETFONT, (WPARAM)A.fButton, FALSE);
    layout();
}

static LRESULT CALLBACK main_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        HDC mem = CreateCompatibleDC(dc); HBITMAP bmp = CreateCompatibleBitmap(dc, rc.right, rc.bottom);
        HGDIOBJ ob = SelectObject(mem, bmp);
        paint_main(mem, rc);
        BitBlt(dc, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
        SelectObject(mem, ob); DeleteObject(bmp); DeleteDC(mem);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_DRAWITEM: draw_item((DRAWITEMSTRUCT *)l); return TRUE;
    case WM_CTLCOLORSTATIC: case WM_CTLCOLOREDIT: {
        HDC dc = (HDC)w; SetTextColor(dc, CTEXT); SetBkColor(dc, CEDIT); return (LRESULT)A.brEdit;
    }
    case WM_COMMAND: command(LOWORD(w), HIWORD(w)); return 0;
    case WM_APP_LINE: details_add((int)w, (wchar_t *)l); x4_free((void *)l); return 0;
    case WM_APP_DONE: {
        ActionResult *res = (ActionResult *)l;
        int started = (res->hookActive & 0x100) != 0;
        set_busy(0);
        refresh(1);
        if (started && res->code == RC_OK && A.s->closeAfterStart) SetTimer(h, TIMER_CLOSE, 1500, NULL);
        x4_free(res);
        return 0;
    }
    case WM_APP_STATUS: {
        Status *st = (Status *)l;
        int keepSlow = !st->slowDone && A.st.slowDone;
        Status old = A.st;
        A.st = *st;
        if (keepSlow) {   /* quick refresh: keep the last slow results */
            A.st.slowDone = 1; A.st.cfgKnown = old.cfgKnown; A.st.cfgOn = old.cfgOn; A.st.cfgValuesMatch = old.cfgValuesMatch;
            A.st.cfgFlagPresent = old.cfgFlagPresent; A.st.cfgMismatchCount = old.cfgMismatchCount;
            wcscpy(A.st.cfgSince, old.cfgSince); wcscpy(A.st.cfgMismatch, old.cfgMismatch); wcscpy(A.st.cfgError, old.cfgError);
            A.st.layoutKnown = old.layoutKnown; A.st.layoutOk = old.layoutOk; A.st.layoutGeo = old.layoutGeo; A.st.layoutFromRect = old.layoutFromRect;
            wcscpy(A.st.layoutSummary, old.layoutSummary); wcscpy(A.st.layoutProblem, old.layoutProblem);
        }
        x4_free(st);
        A.statusBusy = 0;
        apply_status();
        if (A.pendingSlow) { A.pendingSlow = 0; refresh(1); }
        return 0;
    }
    case WM_TIMER:
        if (w == TIMER_QUICK && !A.busy) refresh(0);
        if (w == TIMER_CLOSE) { KillTimer(h, TIMER_CLOSE); DestroyWindow(h); }
        return 0;
    case WM_DPICHANGED: {
        RECT *r = (RECT *)l;
        dpi_changed(HIWORD(w));
        SetWindowPos(h, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_CLOSE: DestroyWindow(h); return 0;
    case WM_DESTROY: KillTimer(h, TIMER_QUICK); PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

/* ---- settings window */
static HWND mklabel(HWND p, int id, const wchar_t *t, DWORD extra) {
    HWND h = CreateWindowExW(0, L"STATIC", t, WS_CHILD | WS_VISIBLE | SS_NOPREFIX | extra, 0, 0, 10, 10, p, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(h, WM_SETFONT, (WPARAM)A.fBody, FALSE);
    return h;
}
static HWND mkedit(HWND p, int id, const wchar_t *t) {
    HWND h = CreateWindowExW(0, L"EDIT", t, WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 10, 10, p, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(h, WM_SETFONT, (WPARAM)A.fBody, FALSE);
    SendMessageW(h, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELPARAM(S(6), S(6)));
    return h;
}

#define SW_ 660
#define SH_ 470
static void settings_layout(HWND w) {
    int M = S(24), X = S(SW_) - 2 * M;
    MoveWindow(GetDlgItem(w, ID_S_L1), M, S(20), X, S(20), FALSE);
    MoveWindow(A.sGame, M, S(44), X - S(120), S(28), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_BROWSE), M + X - S(110), S(42), S(110), S(32), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_L2), M, S(86), X, S(20), FALSE);
    MoveWindow(A.sArgs, M, S(110), X, S(28), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_H2), M, S(140), X, S(18), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_L3), M, S(168), X, S(20), FALSE);
    MoveWindow(A.sRect, M, S(192), S(260), S(28), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_H3), M + S(272), S(196), X - S(272), S(20), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_L4), M, S(234), X, S(20), FALSE);
    for (int i = 0; i < 3; i++) MoveWindow(A.sLang[i], M + i * S(136), S(258), S(128), S(32), FALSE);
    MoveWindow(A.sClose, M, S(304), X, S(32), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_PATHS), M, S(346), X, S(52), FALSE);
    MoveWindow(A.sErr, M, S(400), X - S(250), S(40), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_CANCEL), M + X - S(240), S(410), S(112), S(36), FALSE);
    MoveWindow(GetDlgItem(w, ID_S_SAVE), M + X - S(118), S(410), S(118), S(36), FALSE);
}

static void settings_close(void) {
    if (!A.set) return;
    HWND w = A.set; A.set = NULL;
    EnableWindow(A.hwnd, TRUE);
    DestroyWindow(w);
    SetForegroundWindow(A.hwnd);
}

static void settings_save_ui(void) {
    wchar_t game[X4S_PATH], args[1024], rect[64];
    GetWindowTextW(A.sGame, game, X4S_PATH); GetWindowTextW(A.sArgs, args, 1024); GetWindowTextW(A.sRect, rect, 64);
    if (!rect_valid(rect)) { SetWindowTextW(A.sErr, tr(S_SET_BAD_RECT)); return; }
    /* the auto-detected path stays "auto" (empty) unless the user changed it */
    Settings probe = *A.s; probe.gameExe[0] = 0; probe.doc = NULL; settings_resolve(&probe);
    if (!_wcsicmp(game, probe.rGameExe)) game[0] = 0;
    wcscpy(A.s->gameExe, game); wcscpy(A.s->gameArgs, args); wcscpy(A.s->rect, rect);
    wcscpy(A.s->language, A.sLangSel == 1 ? L"en" : A.sLangSel == 2 ? L"hu" : L"");
    A.s->closeAfterStart = A.sCloseOn;
    settings_save(A.s);
    settings_resolve(A.s);
    i18n_set(A.s->language);
    settings_close();
    apply_texts();
    refresh(1);
}

static LRESULT CALLBACK set_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_ERASEBKGND: { RECT rc; GetClientRect(h, &rc); HBRUSH b = CreateSolidBrush(CBG); FillRect((HDC)w, &rc, b); DeleteObject(b);
        /* frames around the edit fields */
        HWND eds[] = { A.sGame, A.sArgs, A.sRect };
        for (int i = 0; i < 3; i++) { RECT r; GetWindowRect(eds[i], &r); MapWindowPoints(NULL, h, (POINT *)&r, 2); InflateRect(&r, 1, 1);
            HBRUSH fb = CreateSolidBrush(CBORDER); FrameRect((HDC)w, &r, fb); DeleteObject(fb); }
        return 1; }
    case WM_DRAWITEM: draw_item((DRAWITEMSTRUCT *)l); return TRUE;
    case WM_CTLCOLOREDIT: { HDC dc = (HDC)w; SetTextColor(dc, CTEXT); SetBkColor(dc, CEDIT); return (LRESULT)A.brEdit; }
    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)w; int id = GetDlgCtrlID((HWND)l);
        SetTextColor(dc, id == ID_S_ERR ? CBAD : (id == ID_S_H2 || id == ID_S_H3 || id == ID_S_PATHS) ? CMUTED : CTEXT);
        SetBkColor(dc, CBG); return (LRESULT)A.brBg;
    }
    case WM_COMMAND: {
        int id = LOWORD(w);
        if (id >= ID_S_LAUTO && id <= ID_S_LHU) { A.sLangSel = id - ID_S_LAUTO; for (int i = 0; i < 3; i++) InvalidateRect(A.sLang[i], NULL, FALSE); }
        else if (id == ID_S_CLOSE) { A.sCloseOn = !A.sCloseOn; InvalidateRect(A.sClose, NULL, FALSE); }
        else if (id == ID_S_SAVE) settings_save_ui();
        else if (id == ID_S_CANCEL) settings_close();
        else if (id == ID_S_BROWSE) {
            wchar_t f[X4S_PATH]; GetWindowTextW(A.sGame, f, X4S_PATH);
            OPENFILENAMEW o; memset(&o, 0, sizeof o); o.lStructSize = sizeof o; o.hwndOwner = h;
            o.lpstrFilter = L"X4.exe\0X4.exe\0*.exe\0*.exe\0"; o.lpstrFile = f; o.nMaxFile = X4S_PATH;
            o.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
            if (GetOpenFileNameW(&o)) SetWindowTextW(A.sGame, f);
        }
        return 0;
    }
    case WM_CLOSE: settings_close(); return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static void settings_open(void) {
    if (A.set) { SetForegroundWindow(A.set); return; }
    RECT pr; GetWindowRect(A.hwnd, &pr);
    RECT r = { 0, 0, S(SW_), S(SH_) };
    AdjustWindowRectExForDpi(&r, WS_CAPTION | WS_SYSMENU, FALSE, WS_EX_DLGMODALFRAME, (UINT)A.dpi);
    int ww = r.right - r.left, wh = r.bottom - r.top;
    HWND w = CreateWindowExW(WS_EX_DLGMODALFRAME, L"X4SwitchSettings", tr(S_SET_TITLE), WS_CAPTION | WS_SYSMENU | WS_POPUP,
                             pr.left + ((pr.right - pr.left) - ww) / 2, pr.top + S(60), ww, wh, A.hwnd, NULL, GetModuleHandleW(NULL), NULL);
    if (!w) return;
    A.set = w;
    BOOL dark = TRUE; DwmSetWindowAttribute(w, 20, &dark, sizeof dark);
    mklabel(w, ID_S_L1, tr(S_SET_GAME), 0);
    A.sGame = mkedit(w, ID_S_GAME, A.s->rGameExe);
    mkbtn(w, ID_S_BROWSE, tr(S_SET_BROWSE));
    mklabel(w, ID_S_L2, tr(S_SET_ARGS), 0);
    A.sArgs = mkedit(w, ID_S_ARGS, A.s->gameArgs);
    HWND h2 = mklabel(w, ID_S_H2, tr(S_SET_ARGS_HINT), 0); SendMessageW(h2, WM_SETFONT, (WPARAM)A.fSmall, FALSE);
    mklabel(w, ID_S_L3, tr(S_SET_RECT), 0);
    A.sRect = mkedit(w, ID_S_RECT, A.s->rect);
    HWND h3 = mklabel(w, ID_S_H3, tr(S_SET_RECT_HINT), 0); SendMessageW(h3, WM_SETFONT, (WPARAM)A.fSmall, FALSE);
    mklabel(w, ID_S_L4, tr(S_SET_LANG), 0);
    A.sLang[0] = mkbtn(w, ID_S_LAUTO, tr(S_SET_LANG_AUTO));
    A.sLang[1] = mkbtn(w, ID_S_LEN, L"English");
    A.sLang[2] = mkbtn(w, ID_S_LHU, L"Magyar");
    A.sLangSel = !wcscmp(A.s->language, L"en") ? 1 : !wcscmp(A.s->language, L"hu") ? 2 : 0;
    A.sClose = mkbtn(w, ID_S_CLOSE, tr(S_SET_CLOSE));
    A.sCloseOn = A.s->closeAfterStart;
    wchar_t paths[3 * X4S_PATH + 200]; _snwprintf(paths, 3 * X4S_PATH + 200, tr(S_SET_PATHS), A.s->rCockpitDir, A.s->rCompanionDir, A.s->settingsPath);
    paths[3 * X4S_PATH + 199] = 0;
    HWND hp = mklabel(w, ID_S_PATHS, paths, SS_PATHELLIPSIS); SendMessageW(hp, WM_SETFONT, (WPARAM)A.fSmall, FALSE);
    SetWindowLongPtrW(hp, GWL_STYLE, (GetWindowLongPtrW(hp, GWL_STYLE) & ~SS_PATHELLIPSIS));
    A.sErr = mklabel(w, ID_S_ERR, L"", 0); SendMessageW(A.sErr, WM_SETFONT, (WPARAM)A.fSmall, FALSE);
    mkbtn(w, ID_S_CANCEL, tr(S_SET_CANCEL));
    mkbtn(w, ID_S_SAVE, tr(S_SET_SAVE));
    settings_layout(w);
    EnableWindow(A.hwnd, FALSE);
    if (!A.smoke) { ShowWindow(w, SW_SHOW); SetFocus(A.sGame); }
}

/* ---- keyboard */
static int keydown(MSG *msg) {
    HWND root = GetAncestor(msg->hwnd, GA_ROOT);
    HWND f = GetFocus();
    if (root == A.set && A.set) {
        if (msg->wParam == VK_ESCAPE) { settings_close(); return 1; }
        if (msg->wParam == VK_RETURN) {
            int id = GetDlgCtrlID(f);
            if (id == ID_S_CANCEL || id == ID_S_BROWSE || (id >= ID_S_LAUTO && id <= ID_S_CLOSE)) SendMessageW(f, BM_CLICK, 0, 0);
            else settings_save_ui();
            return 1;
        }
        return 0;
    }
    if (root != A.hwnd) return 0;
    switch (msg->wParam) {
    case VK_F5: refresh(1); return 1;
    case VK_RETURN: {
        if (A.busy) return 1;
        int id = GetDlgCtrlID(f);
        if (f && GetParent(f) == A.hwnd && id >= ID_SWITCH && id <= ID_LANG) SendMessageW(f, BM_CLICK, 0, 0);
        else run_job(JOB_MODE, A.sel, 1);
        return 1;
    }
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN:
        if (f == A.card[0] || f == A.card[1]) {
            int m = (msg->wParam == VK_LEFT || msg->wParam == VK_UP) ? MODE_COCKPIT : MODE_SINGLE;
            select_mode(m, 1); SetFocus(A.card[m]);
            return 1;
        }
        return 0;
    }
    return 0;
}

/* ---- off-screen render (for docs/tests): the same paint code into a bitmap, nothing shown on screen */
static int render_bmp(const wchar_t *path) {
    RECT rc; GetClientRect(A.hwnd, &rc);
    int w = rc.right, h = rc.bottom;
    HDC sdc = GetDC(NULL); HDC mem = CreateCompatibleDC(sdc);
    BITMAPINFO bi; memset(&bi, 0, sizeof bi);
    bi.bmiHeader.biSize = sizeof bi.bmiHeader; bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = h;
    bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 24; bi.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    HBITMAP bmp = CreateDIBSection(sdc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, sdc);
    if (!bmp) { DeleteDC(mem); return 0; }
    HGDIOBJ ob = SelectObject(mem, bmp);
    paint_main(mem, rc);
    HWND kids[] = { A.card[0], A.card[1], A.start, A.lang, A.sec[0], A.sec[1], A.sec[2], A.sec[3], A.sec[4], A.sec[5], A.row[0], A.row[1], A.row[2], A.row[3], A.row[4] };
    for (unsigned i = 0; i < sizeof kids / sizeof kids[0]; i++) {
        RECT kr; GetWindowRect(kids[i], &kr); MapWindowPoints(NULL, A.hwnd, (POINT *)&kr, 2);
        DRAWITEMSTRUCT di; memset(&di, 0, sizeof di);
        di.CtlID = (UINT)GetDlgCtrlID(kids[i]); di.hwndItem = kids[i]; di.hDC = mem;
        di.rcItem.right = kr.right - kr.left; di.rcItem.bottom = kr.bottom - kr.top;
        di.itemState = 0;
        if (!IsWindowEnabled(kids[i])) di.itemState |= ODS_DISABLED;
        POINT old; SetViewportOrgEx(mem, kr.left, kr.top, &old);
        HRGN rg = CreateRectRgn(kr.left, kr.top, kr.right, kr.bottom); SelectClipRgn(mem, rg);
        draw_item(&di);
        SelectClipRgn(mem, NULL); DeleteObject(rg);
        SetViewportOrgEx(mem, old.x, old.y, NULL);
    }
    { /* the details text */
        RECT kr; GetWindowRect(A.details, &kr); MapWindowPoints(NULL, A.hwnd, (POINT *)&kr, 2);
        int n = GetWindowTextLengthW(A.details); wchar_t *t = (wchar_t *)x4_alloc((size_t)(n + 1) * sizeof(wchar_t));
        if (t) { GetWindowTextW(A.details, t, n + 1); text(mem, t, kr, A.fMono, CTEXT, DT_LEFT | DT_WORDBREAK | DT_EDITCONTROL); x4_free(t); }
    }
    GdiFlush();
    int stride = ((w * 3) + 3) & ~3;
    BITMAPFILEHEADER fh; memset(&fh, 0, sizeof fh);
    fh.bfType = 0x4D42; fh.bfOffBits = sizeof fh + sizeof bi.bmiHeader; fh.bfSize = fh.bfOffBits + (DWORD)(stride * h);
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    int ok = 0;
    if (f != INVALID_HANDLE_VALUE) {
        DWORD wr;
        ok = WriteFile(f, &fh, sizeof fh, &wr, NULL) && WriteFile(f, &bi.bmiHeader, sizeof bi.bmiHeader, &wr, NULL) && WriteFile(f, bits, (DWORD)(stride * h), &wr, NULL);
        CloseHandle(f);
    }
    SelectObject(mem, ob); DeleteObject(bmp); DeleteDC(mem);
    return ok;
}

/* ---- smoke test: dump every control and its text (both languages) */
typedef struct { HANDLE f; } Dump;
static void dump_w(HANDLE f, const wchar_t *t) { char *u = w_to_utf8(t); DWORD w; WriteFile(f, u, (DWORD)strlen(u), &w, NULL); x4_free(u); }
static BOOL CALLBACK dump_child(HWND h, LPARAM l) {
    Dump *d = (Dump *)l;
    wchar_t cls[64], t[1200], line[1400];
    GetClassNameW(h, cls, 64); GetWindowTextW(h, t, 1200);
    for (wchar_t *p = t; *p; p++) if (*p == L'\r' || *p == L'\n' || *p == L'\t') *p = L'|';
    RECT r; GetWindowRect(h, &r); MapWindowPoints(NULL, GetParent(h), (POINT *)&r, 2);
    _snwprintf(line, 1400, L"control id=%d class=%ls rect=%d,%d,%d,%d enabled=%d text=%ls\r\n", GetDlgCtrlID(h), cls, (int)r.left, (int)r.top, (int)(r.right - r.left), (int)(r.bottom - r.top), IsWindowEnabled(h) ? 1 : 0, t);
    line[1399] = 0;
    dump_w(d->f, line);
    return TRUE;
}
static void dump_all(HANDLE f, const wchar_t *tag) {
    wchar_t head[400]; RECT rc; GetClientRect(A.hwnd, &rc);
    wchar_t title[200]; GetWindowTextW(A.hwnd, title, 200);
    _snwprintf(head, 400, L"== %ls lang=%ls dpi=%d client=%dx%d visible=%d title=%ls\r\n", tag, i18n_lang(), A.dpi, (int)rc.right, (int)rc.bottom, IsWindowVisible(A.hwnd) ? 1 : 0, title);
    head[399] = 0;
    dump_w(f, head);
    Dump d = { f };
    EnumChildWindows(A.hwnd, dump_child, (LPARAM)&d);
    if (A.set) { dump_w(f, L"-- settings window\r\n"); EnumChildWindows(A.set, dump_child, (LPARAM)&d); }
}

/* ---- create + run */
int gui_run(Settings *s, const wchar_t *smokeFile, const wchar_t *renderFile, int holdMs) {
    memset(&A, 0, sizeof A);
    A.s = s; A.smoke = smokeFile && *smokeFile;
    A.sel = !wcscmp(s->lastMode, L"single") ? MODE_SINGLE : MODE_COCKPIT;
    A.brBg = CreateSolidBrush(CBG); A.brSurf = CreateSolidBrush(CSURF); A.brEdit = CreateSolidBrush(CEDIT);
    HINSTANCE hi = GetModuleHandleW(NULL);
    WNDCLASSEXW wc; memset(&wc, 0, sizeof wc); wc.cbSize = sizeof wc;
    wc.lpfnWndProc = main_proc; wc.hInstance = hi; wc.lpszClassName = L"X4SwitchMain";
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW); wc.hbrBackground = A.brBg;
    wc.hIcon = LoadIconW(hi, MAKEINTRESOURCEW(1)); wc.hIconSm = wc.hIcon;
    RegisterClassExW(&wc);
    wc.lpfnWndProc = set_proc; wc.lpszClassName = L"X4SwitchSettings";
    RegisterClassExW(&wc);

    /* place on the monitor under the cursor (or the primary one), centred in its work area */
    POINT cp; GetCursorPos(&cp);
    HMONITOR mon = MonitorFromPoint(cp, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi; mi.cbSize = sizeof mi; GetMonitorInfoW(mon, &mi);
    UINT dx = 96, dy = 96;
    HMODULE shc = LoadLibraryW(L"shcore.dll");
    if (shc) { typedef HRESULT(WINAPI * GDFM)(HMONITOR, int, UINT *, UINT *); GDFM f = (GDFM)(void *)GetProcAddress(shc, "GetDpiForMonitor"); if (f) f(mon, 0, &dx, &dy); }
    A.dpi = (int)dx;
    fonts_make();
    RECT r = { 0, 0, S(CW), S(CH) };
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
    AdjustWindowRectExForDpi(&r, style, FALSE, 0, (UINT)A.dpi);
    int ww = r.right - r.left, wh = r.bottom - r.top;
    int x = mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - ww) / 2, y = mi.rcWork.top + ((mi.rcWork.bottom - mi.rcWork.top) - wh) / 2;
    if (A.smoke) { x = mi.rcWork.left; y = mi.rcWork.top; }   /* never shown in smoke mode anyway */
    A.hwnd = CreateWindowExW(0, L"X4SwitchMain", tr(S_APP_TITLE), style, x, y, ww, wh, NULL, NULL, hi, NULL);
    if (!A.hwnd) return 1;
    int wdpi = (int)GetDpiForWindow(A.hwnd);
    if (wdpi && wdpi != A.dpi) { A.dpi = wdpi; fonts_make(); RECT r2 = { 0, 0, S(CW), S(CH) }; AdjustWindowRectExForDpi(&r2, style, FALSE, 0, (UINT)A.dpi); SetWindowPos(A.hwnd, NULL, 0, 0, r2.right - r2.left, r2.bottom - r2.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE); }
    BOOL dark = TRUE; DwmSetWindowAttribute(A.hwnd, 20, &dark, sizeof dark);

    A.card[0] = mkbtn(A.hwnd, ID_CARD_C, L"");
    A.card[1] = mkbtn(A.hwnd, ID_CARD_S, L"");
    A.start = mkbtn(A.hwnd, ID_START, L"");
    static const int secIds[6] = { ID_SWITCH, ID_DASH, ID_MON, ID_LOGS, ID_SETTINGS, ID_REFRESH };
    for (int i = 0; i < 6; i++) A.sec[i] = mkbtn(A.hwnd, secIds[i], L"");
    A.lang = mkbtn(A.hwnd, ID_LANG, L"");
    for (int i = 0; i < 5; i++)
        A.row[i] = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_OWNERDRAW, 0, 0, 10, 10, A.hwnd, (HMENU)(INT_PTR)(ID_ROW0 + i), hi, NULL);
    A.details = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL, 0, 0, 10, 10, A.hwnd, (HMENU)(INT_PTR)ID_DETAILS, hi, NULL);
    SetWindowTheme(A.details, L"DarkMode_Explorer", NULL);
    layout();
    apply_texts();
    if (s->loadError[0]) details_add(K_WARN, s->loadError);

    if (A.smoke) {
        HANDLE f = CreateFileW(smokeFile, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
        status_slow(s, &A.st);   /* read-only */
        apply_status();
        details_add(K_INFO, L"smoke test: window created hidden, never shown");
        if (f != INVALID_HANDLE_VALUE) {
            dump_all(f, L"main");
            const wchar_t *orig = i18n_lang();
            wchar_t keep[4]; wcscpy(keep, orig);
            i18n_set(wcscmp(keep, L"hu") ? L"hu" : L"en"); apply_texts(); dump_all(f, L"main (other language)");
            settings_open(); dump_all(f, L"main + settings"); settings_close();
            i18n_set(keep); apply_texts();
            /* keyboard: arrow on a card selects the other card, Enter is wired to start (not sent here) */
            SetFocus(A.card[0]);
            int before = A.sel;
            MSG km; memset(&km, 0, sizeof km); km.hwnd = A.card[0]; km.message = WM_KEYDOWN; km.wParam = VK_RIGHT;
            keydown(&km);
            wchar_t kl[200]; _snwprintf(kl, 200, L"keyboard: right arrow on the cockpit card -> selected %ls (before %ls)\r\n", A.sel == MODE_SINGLE ? L"single" : L"cockpit", before == MODE_SINGLE ? L"single" : L"cockpit");
            kl[199] = 0; dump_w(f, kl);
            if (!g_smokeSave) select_mode(before, 0);
            if (renderFile && *renderFile) { int ok = render_bmp(renderFile); dump_w(f, ok ? L"render: ok\r\n" : L"render: FAILED\r\n"); }
            CloseHandle(f);
        }
        if (holdMs > 0) {
            ULONGLONG t0 = GetTickCount64(); MSG m;
            while (GetTickCount64() - t0 < (ULONGLONG)holdMs) { while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageW(&m); } Sleep(20); }
        }
        DestroyWindow(A.hwnd);
        fonts_free();
        return 0;
    }

    ShowWindow(A.hwnd, SW_SHOW);
    UpdateWindow(A.hwnd);
    SetFocus(A.card[A.sel]);
    refresh(1);
    SetTimer(A.hwnd, TIMER_QUICK, 4000, NULL);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (msg.message == WM_KEYDOWN && keydown(&msg)) continue;
        HWND root = GetAncestor(msg.hwnd, GA_ROOT);
        if (root && IsDialogMessageW(root, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    fonts_free();
    return 0;
}
