/* X4Switch - choose how X4: Foundations starts (three-monitor cockpit, or single monitor + browser dashboard).
 * Plain C + Win32, built with zig cc. Shared declarations. Unofficial fan project, not affiliated with Egosoft. */
#ifndef X4SWITCH_H
#define X4SWITCH_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stddef.h>

#define X4S_VERSION L"0.1.0"
#define X4S_PATH 1024

/* ------------------------------------------------------------------ json.c */
typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } JType;
typedef struct JVal {
    JType t;
    int b;
    double num;
    wchar_t *str;
    struct JVal **items;   /* array items or object values */
    wchar_t **keys;        /* object keys (NULL for arrays) */
    int n, cap;
} JVal;

JVal *json_parse(const char *utf8, size_t len, char *err, int errCap);
void json_free(JVal *v);
JVal *jget(const JVal *obj, const wchar_t *key);               /* NULL if absent / not an object */
JVal *jpath(const JVal *obj, const wchar_t *dotted);          /* "triple.ok" */
const wchar_t *jstr(const JVal *obj, const wchar_t *key, const wchar_t *def);
double jnum(const JVal *obj, const wchar_t *key, double def);
int jbool(const JVal *obj, const wchar_t *key, int def);
JVal *jnew(JType t);
void jset(JVal *obj, const wchar_t *key, JVal *val);           /* replaces or appends; takes ownership */
void jset_str(JVal *obj, const wchar_t *key, const wchar_t *s);
void jset_num(JVal *obj, const wchar_t *key, double d);
void jset_bool(JVal *obj, const wchar_t *key, int b);
void jpush(JVal *arr, JVal *val);
char *json_write(const JVal *v, int pretty);                   /* UTF-8, HeapAlloc'd (x4_free) */

/* ------------------------------------------------------------------ i18n.c */
typedef enum {
    S_APP_TITLE, S_SUBTITLE, S_LANG_TOGGLE,
    S_COCKPIT_TITLE, S_COCKPIT_DESC, S_SINGLE_TITLE, S_SINGLE_DESC,
    S_START_FMT, S_WORKING, S_SWITCH_ONLY, S_OPEN_DASH, S_CHECK_MON, S_OPEN_LOGS, S_SETTINGS, S_REFRESH,
    S_STATUS, S_ST_GAME, S_ST_CONFIG, S_ST_MONITORS, S_ST_DASH, S_ST_HOOK, S_DETAILS, S_HINT,
    S_CHECKING,
    S_GAME_NOT_RUNNING, S_GAME_RUNNING_COCKPIT, S_GAME_RUNNING_COCKPIT_NOHOOK, S_GAME_RUNNING_NORMAL, S_GAME_NOT_FOUND,
    S_CFG_ON, S_CFG_ON_DIFF, S_CFG_OFF, S_CFG_KIT_MISSING, S_CFG_UNKNOWN, S_CFG_FLAG_STALE,
    S_MON_OK, S_MON_OK_GEO, S_MON_BAD, S_MON_UNKNOWN, S_MON_RECT,
    S_DASH_SERVER_UP, S_DASH_SERVER_DOWN, S_DASH_WATCHER_ON, S_DASH_WATCHER_OFF, S_DASH_WINDOW_OPEN, S_DASH_WINDOW_NONE,
    S_DASH_NOT_INSTALLED,
    S_HOOK_OK, S_HOOK_MISSING,
    S_CARD_RUNNING, S_CARD_CLOSE_FIRST, S_CARD_READY, S_CARD_NOT_READY, S_CARD_SINGLE_WATCHER, S_CARD_SINGLE_SELF, S_CARD_SINGLE_NODASH,
    S_R_LAYOUT, S_R_HOOK, S_R_KIT, S_R_GAME,
    /* action messages */
    M_GAME_EXE_MISSING, M_GAME_RUNNING, M_KIT_MISSING, M_HOOK_MISSING, M_RECT_BAD, M_RECT_USED,
    M_LAYOUT_CHECK, M_LAYOUT_OK, M_LAYOUT_BAD, M_CFG_ON, M_CFG_OFF, M_CFG_ALREADY_OFF, M_CFG_REFUSED, M_CFG_ERROR,
    M_SWITCHED_COCKPIT, M_SWITCHED_SINGLE, M_LAUNCHING_COCKPIT, M_HOOK_ACTIVE, M_HOOK_FAILSAFE, M_LAUNCH_REFUSED,
    M_LAUNCH_ERROR, M_STARTING_GAME, M_GAME_STARTED, M_GAME_START_FAILED, M_GAME_EXITED_EARLY,
    M_DASH_NONE, M_DASH_WATCHER, M_DASH_WAIT_OK, M_DASH_WAIT_TIMEOUT, M_DASH_SELF, M_DASH_OPENED, M_DASH_PRESENT,
    M_DASH_FAILED, M_DASH_DRY, M_DRY_RUN, M_DRY_GAME_CMD, M_BUSY, M_SKIP_KIT_SINGLE,
    M_KIT_KEEPS_GAME_SAFE, M_SCRIPT_TIMEOUT, M_SCRIPT_FAILED,
    /* settings window */
    S_SET_TITLE, S_SET_GAME, S_SET_BROWSE, S_SET_ARGS, S_SET_ARGS_HINT, S_SET_RECT, S_SET_RECT_HINT, S_SET_LANG,
    S_SET_LANG_AUTO, S_SET_CLOSE, S_SET_SAVE, S_SET_CANCEL, S_SET_PATHS, S_SET_BAD_RECT, S_YES, S_NO,
    S_COUNT
} StrId;

void i18n_set(const wchar_t *lang);          /* "en" | "hu" | "" (= Windows UI language) */
const wchar_t *i18n_lang(void);               /* the effective language: "en" or "hu" */
const wchar_t *tr(StrId id);
const wchar_t *tr_lang(const wchar_t *lang, StrId id);
int i18n_selftest(wchar_t *msg, int cap);     /* 1 = both tables complete and consistent */

/* ------------------------------------------------------------------ core.c */
typedef struct {
    /* where we are */
    wchar_t exeDir[X4S_PATH];
    wchar_t settingsPath[X4S_PATH];
    wchar_t logDir[X4S_PATH];
    JVal *doc;                       /* the parsed settings.json (unknown keys are kept on save) */
    /* user settings */
    wchar_t language[8];
    wchar_t lastMode[16];
    wchar_t gameExe[X4S_PATH];
    wchar_t gameArgs[1024];
    wchar_t rect[64];
    int closeAfterStart;
    wchar_t cockpitDir[X4S_PATH];
    wchar_t companionDir[X4S_PATH];
    int dashboardPort;
    /* advanced / tests (normally empty) */
    wchar_t cockpitSettingsFile[X4S_PATH];
    wchar_t monitorsJson[X4S_PATH];
    wchar_t cockpitLogDir[X4S_PATH];
    wchar_t companionStateDir[X4S_PATH];
    wchar_t companionLogDir[X4S_PATH];
    wchar_t companionMutex[128];
    wchar_t powershellExe[X4S_PATH];
    int launchWaitSeconds;
    int dashboardWaitSeconds;
    /* resolved */
    wchar_t rGameExe[X4S_PATH];
    wchar_t rGameDir[X4S_PATH];
    wchar_t rCockpitDir[X4S_PATH];
    wchar_t rCompanionDir[X4S_PATH];
    wchar_t rCompanionState[X4S_PATH];
    wchar_t rLauncherLogDir[X4S_PATH];
    wchar_t rWindowTitle[128];
    int rPort;
    wchar_t loadError[256];
} Settings;

void settings_init(Settings *s, const wchar_t *exeDir, const wchar_t *settingsFile, const wchar_t *logDir);
int  settings_load(Settings *s);              /* 0 = no file (defaults), 1 = loaded, -1 = unreadable (defaults) */
void settings_resolve(Settings *s);
int  settings_save(Settings *s);              /* writes settings.json (keeps unknown keys) */
int  rect_valid(const wchar_t *r);            /* "x,y,w,h" with ints, w,h >= 16; "" counts as valid (= none) */

/* logging (own folder, size-capped) */
void log_init(const wchar_t *dir);
void log_line(const wchar_t *fmt, ...);

/* status */
enum { GM_NONE = 0, GM_COCKPIT_ACTIVE, GM_COCKPIT_NOHOOK, GM_NORMAL };
typedef struct {
    int gameExePresent;
    int gameRunning; DWORD gamePid; int gameMode;
    int kitPresent;
    int cfgKnown, cfgOn, cfgValuesMatch, cfgFlagPresent, cfgMismatchCount;
    wchar_t cfgSince[40], cfgMismatch[200], cfgError[300];
    int layoutKnown, layoutOk, layoutGeo, layoutFromRect;
    wchar_t layoutSummary[300], layoutProblem[600];
    int companionInstalled, serverUp, watcherRunning, dashWindow;
    int hookPresent; wchar_t hookMissing[X4S_PATH];
    int slowDone;
} Status;

void status_quick(const Settings *s, Status *st);  /* processes, files, port, mutex, window (no child processes) */
void status_slow(const Settings *s, Status *st);   /* + cockpit.ps1 status -Json and x4cockpit3.ps1 -Json (in parallel) */
void status_lines(const Status *st, const Settings *s, wchar_t lines[5][700], int colors[5]);
void status_card(const Status *st, int mode, wchar_t *out, int cap, int *color);
JVal *status_json(const Status *st, const Settings *s);
enum { C_IDLE = 0, C_OK, C_WARN, C_BAD, C_INFO };

/* actions */
enum { MODE_COCKPIT = 0, MODE_SINGLE = 1 };
enum { K_INFO = 0, K_OK, K_WARN, K_ERR, K_DETAIL, K_STEP };
typedef void (*ReportFn)(void *ctx, int kind, const wchar_t *text);
typedef struct { ReportFn fn; void *ctx; } Reporter;
void rep(const Reporter *r, int kind, const wchar_t *fmt, ...);

enum { RC_OK = 0, RC_ERROR = 1, RC_REFUSED = 2, RC_FAILSAFE = 3, RC_USAGE = 4, RC_INSTANCE = 5 };
typedef struct { int code; wchar_t result[64]; wchar_t summary[800]; DWORD gamePid; int hookActive; } ActionResult;

void action_mode(const Settings *s, int mode, int start, int dryRun, const Reporter *r, ActionResult *res);
void action_open_dashboard(const Settings *s, int dryRun, const Reporter *r, ActionResult *res);
void action_check_monitors(const Settings *s, const Reporter *r, ActionResult *res);

/* utilities shared with the GUI / CLI */
int  file_exists(const wchar_t *p);
int  dir_exists(const wchar_t *p);
void path_join(wchar_t *out, int cap, const wchar_t *a, const wchar_t *b);
int  port_open(int port, int timeoutMs);
DWORD find_game_pid(const wchar_t *exe);
int  find_window_prefix(const wchar_t *prefix);
int  mutex_exists(const wchar_t *name);
void *x4_alloc(size_t n);
void x4_free(void *p);
wchar_t *utf8_to_w(const char *s, int len);
char *w_to_utf8(const wchar_t *s);
int  wmi_create_process(const wchar_t *cmdline, const wchar_t *cwd, int hidden, DWORD *pid, wchar_t *err, int errCap);
void quote_arg(wchar_t *out, int cap, const wchar_t *arg);   /* CommandLineToArgvW-compatible */
int  core_selftest(const Reporter *r);

#endif
