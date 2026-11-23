/* X4Switch - a small JSON reader/writer (UTF-8 in/out, UTF-16 strings in memory). Enough for settings.json and the
 * "@@X4JSON" result lines of the cockpit kit. No external library. */
#include "x4switch.h"
#include <stdio.h>
#include <string.h>
#include <wchar.h>

typedef struct { const char *p, *end; char *err; int errCap; } P;

static void perr(P *p, const char *m) {
    if (p->err && p->errCap > 0 && !p->err[0]) _snprintf(p->err, p->errCap - 1, "%s at offset %d", m, (int)(p->end - p->p));
}
static void ws(P *p) { while (p->p < p->end && (*p->p == ' ' || *p->p == '\t' || *p->p == '\r' || *p->p == '\n')) p->p++; }

JVal *jnew(JType t) { JVal *v = (JVal *)x4_alloc(sizeof(JVal)); if (v) v->t = t; return v; }

static int grow(JVal *v) {
    if (v->n < v->cap) return 1;
    int nc = v->cap ? v->cap * 2 : 8;
    JVal **ni = (JVal **)x4_alloc(sizeof(JVal *) * nc);
    wchar_t **nk = v->t == J_OBJ ? (wchar_t **)x4_alloc(sizeof(wchar_t *) * nc) : NULL;
    if (!ni || (v->t == J_OBJ && !nk)) return 0;
    if (v->n) { memcpy(ni, v->items, sizeof(JVal *) * v->n); if (nk) memcpy(nk, v->keys, sizeof(wchar_t *) * v->n); }
    x4_free(v->items); x4_free(v->keys);
    v->items = ni; v->keys = nk; v->cap = nc;
    return 1;
}

static wchar_t *wdup(const wchar_t *s) {
    size_t n = wcslen(s);
    wchar_t *d = (wchar_t *)x4_alloc((n + 1) * sizeof(wchar_t));
    if (d) memcpy(d, s, (n + 1) * sizeof(wchar_t));
    return d;
}

static JVal *pval(P *p, int depth);

static wchar_t *pstr(P *p) {
    /* p->p at the opening quote. Decodes escapes; UTF-8 bytes are converted to UTF-16. */
    p->p++;
    const char *s = p->p;
    size_t cap = 16; size_t n = 0;
    for (const char *q = s; q < p->end && *q != '"'; q++) { cap++; if (*q == '\\') q++; }
    wchar_t *out = (wchar_t *)x4_alloc((cap + 1) * sizeof(wchar_t));
    char *raw = (char *)x4_alloc(cap * 4 + 8);
    if (!out || !raw) { x4_free(out); x4_free(raw); perr(p, "out of memory"); return NULL; }
    /* first collect raw UTF-8 for non-escaped runs, converting runs as they end */
    size_t rn = 0;
    while (p->p < p->end && *p->p != '"') {
        unsigned char c = (unsigned char)*p->p;
        if (c < 0x20) { perr(p, "control character in string"); x4_free(out); x4_free(raw); return NULL; }
        if (c == '\\') {
            if (rn) { int k = MultiByteToWideChar(CP_UTF8, 0, raw, (int)rn, out + n, (int)(cap - n)); n += k; rn = 0; }
            p->p++;
            if (p->p >= p->end) break;
            char e = *p->p++;
            wchar_t w = 0;
            switch (e) {
            case '"': w = L'"'; break; case '\\': w = L'\\'; break; case '/': w = L'/'; break;
            case 'b': w = L'\b'; break; case 'f': w = L'\f'; break; case 'n': w = L'\n'; break;
            case 'r': w = L'\r'; break; case 't': w = L'\t'; break;
            case 'u': {
                if (p->end - p->p < 4) { perr(p, "bad \\u escape"); x4_free(out); x4_free(raw); return NULL; }
                unsigned v = 0;
                for (int i = 0; i < 4; i++) {
                    char h = p->p[i]; v <<= 4;
                    if (h >= '0' && h <= '9') v |= (unsigned)(h - '0');
                    else if (h >= 'a' && h <= 'f') v |= (unsigned)(h - 'a' + 10);
                    else if (h >= 'A' && h <= 'F') v |= (unsigned)(h - 'A' + 10);
                    else { perr(p, "bad \\u escape"); x4_free(out); x4_free(raw); return NULL; }
                }
                p->p += 4; w = (wchar_t)v; break;
            }
            default: perr(p, "bad escape"); x4_free(out); x4_free(raw); return NULL;
            }
            if (n < cap) out[n++] = w;
            continue;
        }
        raw[rn++] = (char)c; p->p++;
    }
    if (p->p >= p->end) { perr(p, "unterminated string"); x4_free(out); x4_free(raw); return NULL; }
    if (rn) { int k = MultiByteToWideChar(CP_UTF8, 0, raw, (int)rn, out + n, (int)(cap - n)); n += k; }
    out[n] = 0;
    p->p++;   /* closing quote */
    x4_free(raw);
    return out;
}

static JVal *pval(P *p, int depth) {
    if (depth > 64) { perr(p, "too deep"); return NULL; }
    ws(p);
    if (p->p >= p->end) { perr(p, "unexpected end"); return NULL; }
    char c = *p->p;
    if (c == '{' || c == '[') {
        int obj = c == '{';
        JVal *v = jnew(obj ? J_OBJ : J_ARR);
        if (!v) return NULL;
        p->p++; ws(p);
        if (p->p < p->end && *p->p == (obj ? '}' : ']')) { p->p++; return v; }
        for (;;) {
            wchar_t *key = NULL;
            ws(p);
            if (obj) {
                if (p->p >= p->end || *p->p != '"') { perr(p, "expected a key"); json_free(v); return NULL; }
                key = pstr(p);
                if (!key) { json_free(v); return NULL; }
                ws(p);
                if (p->p >= p->end || *p->p != ':') { perr(p, "expected ':'"); x4_free(key); json_free(v); return NULL; }
                p->p++;
            }
            JVal *item = pval(p, depth + 1);
            if (!item || !grow(v)) { x4_free(key); json_free(item); json_free(v); return NULL; }
            v->items[v->n] = item; if (obj) v->keys[v->n] = key; v->n++;
            ws(p);
            if (p->p < p->end && *p->p == ',') { p->p++; continue; }
            if (p->p < p->end && *p->p == (obj ? '}' : ']')) { p->p++; return v; }
            perr(p, obj ? "expected ',' or '}'" : "expected ',' or ']'"); json_free(v); return NULL;
        }
    }
    if (c == '"') { wchar_t *s = pstr(p); if (!s) return NULL; JVal *v = jnew(J_STR); if (v) v->str = s; return v; }
    if (!strncmp(p->p, "true", 4) && p->end - p->p >= 4) { p->p += 4; JVal *v = jnew(J_BOOL); if (v) v->b = 1; return v; }
    if (!strncmp(p->p, "false", 5) && p->end - p->p >= 5) { p->p += 5; return jnew(J_BOOL); }
    if (!strncmp(p->p, "null", 4) && p->end - p->p >= 4) { p->p += 4; return jnew(J_NULL); }
    if (c == '-' || (c >= '0' && c <= '9')) {
        char buf[64]; int k = 0;
        while (p->p < p->end && k < 63 && ((*p->p && strchr("+-.eE", *p->p)) ||(*p->p >= '0' && *p->p <= '9'))) buf[k++] = *p->p++;
        buf[k] = 0;
        char *e = NULL; double d = strtod(buf, &e);
        if (!e || *e) { perr(p, "bad number"); return NULL; }
        JVal *v = jnew(J_NUM); if (v) v->num = d; return v;
    }
    perr(p, "unexpected character");
    return NULL;
}

JVal *json_parse(const char *utf8, size_t len, char *err, int errCap) {
    if (err && errCap > 0) err[0] = 0;
    P p = { utf8, utf8 + len, err, errCap };
    if (len >= 3 && (unsigned char)utf8[0] == 0xEF && (unsigned char)utf8[1] == 0xBB && (unsigned char)utf8[2] == 0xBF) p.p += 3;
    JVal *v = pval(&p, 0);
    if (!v) return NULL;
    ws(&p);
    if (p.p != p.end) { perr(&p, "trailing characters"); json_free(v); return NULL; }
    return v;
}

void json_free(JVal *v) {
    if (!v) return;
    for (int i = 0; i < v->n; i++) { json_free(v->items[i]); if (v->keys) x4_free(v->keys[i]); }
    x4_free(v->items); x4_free(v->keys); x4_free(v->str); x4_free(v);
}

JVal *jget(const JVal *o, const wchar_t *key) {
    if (!o || o->t != J_OBJ) return NULL;
    for (int i = 0; i < o->n; i++) if (!wcscmp(o->keys[i], key)) return o->items[i];
    return NULL;
}

JVal *jpath(const JVal *o, const wchar_t *dotted) {
    wchar_t part[128]; const wchar_t *s = dotted; const JVal *cur = o;
    while (cur && *s) {
        int k = 0;
        while (*s && *s != L'.' && k < 127) part[k++] = *s++;
        part[k] = 0; if (*s == L'.') s++;
        cur = jget(cur, part);
    }
    return (JVal *)cur;
}

const wchar_t *jstr(const JVal *o, const wchar_t *key, const wchar_t *def) {
    JVal *v = jget(o, key);
    return (v && v->t == J_STR && v->str) ? v->str : def;
}
double jnum(const JVal *o, const wchar_t *key, double def) {
    JVal *v = jget(o, key);
    if (v && v->t == J_NUM) return v->num;
    if (v && v->t == J_STR && v->str && v->str[0]) { wchar_t *e; double d = wcstod(v->str, &e); if (!*e) return d; }
    return def;
}
int jbool(const JVal *o, const wchar_t *key, int def) {
    JVal *v = jget(o, key);
    if (v && v->t == J_BOOL) return v->b;
    if (v && v->t == J_STR && v->str) { if (!_wcsicmp(v->str, L"true")) return 1; if (!_wcsicmp(v->str, L"false")) return 0; }
    if (v && v->t == J_NUM) return v->num != 0;
    return def;
}

void jset(JVal *o, const wchar_t *key, JVal *val) {
    if (!o || o->t != J_OBJ || !val) { json_free(val); return; }
    for (int i = 0; i < o->n; i++) if (!wcscmp(o->keys[i], key)) { json_free(o->items[i]); o->items[i] = val; return; }
    if (!grow(o)) { json_free(val); return; }
    o->keys[o->n] = wdup(key); o->items[o->n] = val; o->n++;
}
void jset_str(JVal *o, const wchar_t *key, const wchar_t *s) { JVal *v = jnew(J_STR); if (v) v->str = wdup(s ? s : L""); jset(o, key, v); }
void jset_num(JVal *o, const wchar_t *key, double d) { JVal *v = jnew(J_NUM); if (v) v->num = d; jset(o, key, v); }
void jset_bool(JVal *o, const wchar_t *key, int b) { JVal *v = jnew(J_BOOL); if (v) v->b = !!b; jset(o, key, v); }
void jpush(JVal *a, JVal *val) {
    if (!a || a->t != J_ARR || !val || !grow(a)) { json_free(val); return; }
    a->items[a->n++] = val;
}

/* ---- writer */
typedef struct { char *b; size_t n, cap; } B;
static void bput(B *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 256; while (nc < b->n + n + 1) nc *= 2;
        char *nb = (char *)x4_alloc(nc); if (!nb) return;
        if (b->n) memcpy(nb, b->b, b->n);
        x4_free(b->b); b->b = nb; b->cap = nc;
    }
    memcpy(b->b + b->n, s, n); b->n += n; b->b[b->n] = 0;
}
static void bputs(B *b, const char *s) { bput(b, s, strlen(s)); }
static void wstr(B *b, const wchar_t *s) {
    bputs(b, "\"");
    for (const wchar_t *q = s ? s : L""; *q; q++) {
        wchar_t c = *q; char t[16];
        if (c == L'"') bputs(b, "\\\""); else if (c == L'\\') bputs(b, "\\\\");
        else if (c == L'\n') bputs(b, "\\n"); else if (c == L'\r') bputs(b, "\\r"); else if (c == L'\t') bputs(b, "\\t");
        else if (c < 0x20) { _snprintf(t, sizeof t, "\\u%04x", (unsigned)c); bputs(b, t); }
        else if (c < 0x80) { t[0] = (char)c; bput(b, t, 1); }
        else {
            /* UTF-16 -> UTF-8 (a surrogate pair is converted together) */
            int len = (c >= 0xD800 && c <= 0xDBFF && q[1] >= 0xDC00 && q[1] <= 0xDFFF) ? 2 : 1;
            int k = WideCharToMultiByte(CP_UTF8, 0, q, len, t, sizeof t, NULL, NULL);
            bput(b, t, (size_t)k); q += len - 1;
        }
    }
    bputs(b, "\"");
}
static void indent(B *b, int pretty, int d) { if (!pretty) return; bputs(b, "\n"); for (int i = 0; i < d; i++) bputs(b, "  "); }
static void wval(B *b, const JVal *v, int pretty, int d) {
    char t[64];
    switch (v ? v->t : J_NULL) {
    case J_NULL: bputs(b, "null"); break;
    case J_BOOL: bputs(b, v->b ? "true" : "false"); break;
    case J_NUM:
        if (v->num == (double)(long long)v->num && v->num > -1e15 && v->num < 1e15) _snprintf(t, sizeof t, "%lld", (long long)v->num);
        else _snprintf(t, sizeof t, "%.10g", v->num);
        bputs(b, t); break;
    case J_STR: wstr(b, v->str); break;
    case J_ARR: case J_OBJ: {
        int obj = v->t == J_OBJ;
        bputs(b, obj ? "{" : "[");
        for (int i = 0; i < v->n; i++) {
            if (i) bputs(b, ",");
            indent(b, pretty, d + 1);
            if (obj) { wstr(b, v->keys[i]); bputs(b, pretty ? ": " : ":"); }
            wval(b, v->items[i], pretty, d + 1);
        }
        if (v->n) indent(b, pretty, d);
        bputs(b, obj ? "}" : "]");
        break;
    }
    }
}
char *json_write(const JVal *v, int pretty) {
    B b = { 0 };
    wval(&b, v, pretty, 0);
    if (pretty) bputs(&b, "\n");
    return b.b;
}
