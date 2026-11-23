"""peimports.py - read-only PE import lister (stdlib only).

Lists the imports of a PE32+ / PE32 file, optionally only those of chosen DLLs, plus the facts that matter for
the window hook: subsystem, DLL characteristics, and whether the embedded manifest declares DPI awareness.
The file is opened read-only; nothing is written.

  python peimports.py X4.exe                    # every import, grouped by DLL
  python peimports.py X4.exe --dll user32.dll --dll gdi32.dll --dll shcore.dll
  python peimports.py X4.exe --window           # only window / monitor / DPI / display-mode related imports
"""
import argparse
import re
import struct
import sys

WINDOW_RX = re.compile(
    r"(Window|Monitor|Display|SystemMetrics|SystemParametersInfo|AdjustWindowRect|Dpi|DPI|Awareness|"
    r"ClipCursor|ShowWindow|MoveWindow|DeferWindowPos|EnumDisplay|ChangeDisplay|GetClientRect|ClientToScreen|"
    r"ScreenToClient|SetWindowLong|GetWindowLong|SetWindowPlacement|GetWindowPlacement|DwmSet|DwmGet|"
    r"BringWindowToTop|SetForegroundWindow|SetFocus|GetCursorPos|SetCursorPos)")


def rd(f, off, n):
    f.seek(off)
    b = f.read(n)
    if len(b) != n:
        raise ValueError("truncated file at 0x%x" % off)
    return b


def cstr(f, off, limit=512):
    f.seek(off)
    b = f.read(limit)
    return b.split(b"\0", 1)[0].decode("latin-1")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exe")
    ap.add_argument("--dll", action="append", default=[], help="only this DLL (repeatable, case-insensitive)")
    ap.add_argument("--window", action="store_true", help="only window/monitor/DPI/display related functions")
    a = ap.parse_args()
    want = {d.lower() for d in a.dll}

    with open(a.exe, "rb") as f:
        if rd(f, 0, 2) != b"MZ":
            sys.exit("not an MZ file")
        pe = struct.unpack("<I", rd(f, 0x3C, 4))[0]
        if rd(f, pe, 4) != b"PE\0\0":
            sys.exit("no PE signature")
        machine, nsec, _, _, _, optsize, chars = struct.unpack("<HHIIIHH", rd(f, pe + 4, 20))
        opt = pe + 24
        magic = struct.unpack("<H", rd(f, opt, 2))[0]
        pe64 = magic == 0x20B
        subsystem, dllchars = struct.unpack("<HH", rd(f, opt + 68, 4))
        ddir = opt + (112 if pe64 else 96)
        imp_rva, imp_size = struct.unpack("<II", rd(f, ddir + 8, 8))
        res_rva, res_size = struct.unpack("<II", rd(f, ddir + 16, 8))
        secs = []
        for i in range(nsec):
            s = rd(f, opt + optsize + 40 * i, 40)
            name = s[:8].rstrip(b"\0").decode("latin-1")
            vsize, va, rawsize, rawptr = struct.unpack("<IIII", s[8:24])
            secs.append((name, va, max(vsize, rawsize), rawptr, rawsize))

        def off(rva):
            for _, va, size, raw, _ in secs:
                if va <= rva < va + size:
                    return raw + (rva - va)
            raise ValueError("rva 0x%x not in any section" % rva)

        print("file      : %s" % a.exe)
        print("machine   : 0x%04x (%s), subsystem %d (%s)" % (
            machine, "x64" if machine == 0x8664 else "other", subsystem,
            {2: "GUI", 3: "console"}.get(subsystem, "?")))
        print("dllchars  : 0x%04x (ASLR=%s, NX=%s, CFG=%s)" % (
            dllchars, bool(dllchars & 0x40), bool(dllchars & 0x100), bool(dllchars & 0x4000)))

        # ---- imports
        d = off(imp_rva)
        total = 0
        while True:
            oft, _, _, name_rva, ft = struct.unpack("<IIIII", rd(f, d, 20))
            if name_rva == 0:
                break
            dll = cstr(f, off(name_rva))
            d += 20
            if want and dll.lower() not in want:
                continue
            thunk = off(oft or ft)
            names = []
            while True:
                if pe64:
                    v = struct.unpack("<Q", rd(f, thunk, 8))[0]
                    thunk += 8
                    ordflag = 1 << 63
                else:
                    v = struct.unpack("<I", rd(f, thunk, 4))[0]
                    thunk += 4
                    ordflag = 1 << 31
                if v == 0:
                    break
                if v & ordflag:
                    names.append("#%d (by ordinal)" % (v & 0xFFFF))
                else:
                    names.append(cstr(f, off(v & 0x7FFFFFFF) + 2))
            shown = [n for n in names if not a.window or WINDOW_RX.search(n)]
            if not shown:
                continue
            print("\n%s  (%d imports%s)" % (dll, len(names), ", %d shown" % len(shown) if a.window else ""))
            for n in sorted(shown, key=str.lower):
                print("   " + n)
            total += len(shown)
        print("\n%d function(s) listed" % total)

        # ---- manifest (RT_MANIFEST = 24): crude scan of the resource section for the XML
        if res_rva:
            raw = rd(f, off(res_rva), res_size)
            m = re.search(rb"<assembly.*?</assembly>", raw, re.S)
            if m:
                xml = m.group(0).decode("utf-8", "replace")
                for tag in ("dpiAware", "dpiAwareness", "gdiScaling", "longPathAware"):
                    for v in re.findall(r"<(?:\w+:)?%s[^>]*>([^<]*)<" % tag, xml):
                        print("manifest  : %s = %s" % (tag, v.strip()))
                if not re.search(r"dpiAware", xml):
                    print("manifest  : no dpiAware/dpiAwareness element")
            else:
                print("manifest  : none found in the resource section")


if __name__ == "__main__":
    main()
