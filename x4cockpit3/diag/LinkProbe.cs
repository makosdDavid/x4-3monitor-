// LinkProbe.cs - READ-ONLY display link probe (DisplayConfig + NVAPI query functions only).
// Nothing in here sets a mode, a colour, a topology or any driver state.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class LinkProbe
{
    // ------------------------------------------------------------------ DisplayConfig
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Num; public uint Den; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_TARGET { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public RATIONAL refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO { public PATH_SOURCE source; public PATH_TARGET target; public uint flags; }
    [StructLayout(LayoutKind.Explicit, Size = 64)] public struct MODE_INFO
    {
        [FieldOffset(0)] public uint infoType; [FieldOffset(4)] public uint id; [FieldOffset(8)] public LUID adapterId;
        [FieldOffset(16)] public ulong pixelRate; [FieldOffset(24)] public RATIONAL hSync; [FieldOffset(32)] public RATIONAL vSync;
        [FieldOffset(40)] public uint activeCx; [FieldOffset(44)] public uint activeCy; [FieldOffset(48)] public uint totalCx; [FieldOffset(52)] public uint totalCy;
        [FieldOffset(56)] public uint videoStandard; [FieldOffset(60)] public uint scanLine;
        [FieldOffset(16)] public uint srcW; [FieldOffset(20)] public uint srcH; [FieldOffset(24)] public uint pixFmt; [FieldOffset(28)] public int posX; [FieldOffset(32)] public int posY;
    }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPath, [Out] PATH_INFO[] paths, ref uint numMode, [Out] MODE_INFO[] modes, IntPtr topo);
    [DllImport("user32.dll", EntryPoint = "QueryDisplayConfig")] static extern int QueryDisplayConfigTopo(uint flags, ref uint numPath, [Out] PATH_INFO[] paths, ref uint numMode, [Out] MODE_INFO[] modes, out uint topo);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(IntPtr p);

    static IntPtr Req(uint type, int size, LUID a, uint id)
    {
        IntPtr p = Marshal.AllocHGlobal(size);
        for (int i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
        Marshal.WriteInt32(p, 0, (int)type); Marshal.WriteInt32(p, 4, size);
        Marshal.WriteInt32(p, 8, (int)a.Low); Marshal.WriteInt32(p, 12, a.High); Marshal.WriteInt32(p, 16, (int)id);
        return p;
    }
    static string Str(IntPtr p, int off, int chars) { string s = Marshal.PtrToStringUni(new IntPtr(p.ToInt64() + off), chars); int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s; }
    static uint U32(IntPtr p, int off) { return (uint)Marshal.ReadInt32(p, off); }

    public static string Tech(uint t)
    {
        switch (t)
        {
            case 0: return "VGA"; case 4: return "DVI"; case 5: return "HDMI"; case 6: return "LVDS";
            case 10: return "DP-external"; case 11: return "DP-embedded(eDP)"; case 15: return "Miracast";
            case 16: return "indirect-wired"; case 17: return "indirect-virtual"; case 18: return "DP-USB-tunnel";
            case 0x80000000: return "internal"; case 0xFFFFFFFF: return "other";
        }
        return "tech" + t;
    }
    static string Edid3(ushort m) { int v = ((m & 0xFF) << 8) | (m >> 8); return "" + (char)(((v >> 10) & 31) + 64) + (char)(((v >> 5) & 31) + 64) + (char)((v & 31) + 64); }
    static string LuidKey(LUID l) { return l.High.ToString("X") + ":" + l.Low.ToString("X8"); }

    public static string AdapterName(LUID a)
    {
        IntPtr p = Req(4, 20 + 256, a, 0);
        try { return DisplayConfigGetDeviceInfo(p) == 0 ? Str(p, 20, 128) : "?"; } finally { Marshal.FreeHGlobal(p); }
    }
    public static string SourceName(LUID a, uint id)
    {
        IntPtr p = Req(1, 20 + 64, a, id);
        try { return DisplayConfigGetDeviceInfo(p) == 0 ? Str(p, 20, 32) : "?"; } finally { Marshal.FreeHGlobal(p); }
    }
    // returns code|friendly|devicePath|connectorInstance|outTech|flags
    public static string[] TargetName(LUID a, uint id)
    {
        IntPtr p = Req(2, 420, a, id);
        try
        {
            if (DisplayConfigGetDeviceInfo(p) != 0) return new string[] { "?", "?", "?", "?", "?", "?" };
            uint flags = U32(p, 20), tech = U32(p, 24);
            ushort mfg = (ushort)Marshal.ReadInt16(p, 28), prod = (ushort)Marshal.ReadInt16(p, 30);
            uint conn = U32(p, 32);
            string code = (flags & 4) != 0 ? Edid3(mfg) + prod.ToString("X4") : "noEDID";
            return new string[] { code, Str(p, 36, 64), Str(p, 164, 128), conn.ToString(), Tech(tech), flags.ToString("X") };
        }
        finally { Marshal.FreeHGlobal(p); }
    }
    public static string BaseTech(LUID a, uint id)
    {
        IntPtr p = Req(6, 24, a, id);
        try { return DisplayConfigGetDeviceInfo(p) == 0 ? Tech(U32(p, 20)) : "?"; } finally { Marshal.FreeHGlobal(p); }
    }
    public static string PreferredMode(LUID a, uint id)
    {
        IntPtr p = Req(3, 80, a, id);
        try
        {
            if (DisplayConfigGetDeviceInfo(p) != 0) return "?";
            ulong pr = (ulong)Marshal.ReadInt64(p, 32);
            uint vn = U32(p, 48), vd = U32(p, 52);
            return U32(p, 20) + "x" + U32(p, 24) + "@" + (vd == 0 ? 0 : (double)vn / vd).ToString("0.00") + " pclk " + (pr / 1e6).ToString("0.00") + "MHz";
        }
        finally { Marshal.FreeHGlobal(p); }
    }
    public static string AdvColor(LUID a, uint id)
    {
        string r = "";
        IntPtr p = Req(9, 32, a, id);
        try
        {
            if (DisplayConfigGetDeviceInfo(p) == 0)
            {
                uint v = U32(p, 20);
                string[] enc = { "RGB", "YCbCr444", "YCbCr422", "YCbCr420", "Intensity" };
                uint e = U32(p, 24);
                r = "advColorSupported=" + (v & 1) + " advColorEnabled=" + ((v >> 1) & 1) + " wideColorEnforced=" + ((v >> 2) & 1) + " forceDisabled=" + ((v >> 3) & 1)
                    + " encoding=" + (e < 5 ? enc[e] : e.ToString()) + " bpc=" + U32(p, 28);
            }
            else r = "advColor=?";
        }
        finally { Marshal.FreeHGlobal(p); }
        p = Req(15, 36, a, id);   // GET_ADVANCED_COLOR_INFO_2 (Win11 24H2+)
        try
        {
            if (DisplayConfigGetDeviceInfo(p) == 0)
            {
                uint v = U32(p, 20);
                string[] mode = { "SDR", "WCG", "HDR" };
                uint m = U32(p, 32);
                r += " | info2: hdrSupported=" + ((v >> 4) & 1) + " hdrUserEnabled=" + ((v >> 5) & 1) + " wcgSupported=" + ((v >> 6) & 1) + " wcgUserEnabled=" + ((v >> 7) & 1)
                    + " limitedByPolicy=" + ((v >> 3) & 1) + " activeColorMode=" + (m < 3 ? mode[m] : m.ToString());
            }
        }
        finally { Marshal.FreeHGlobal(p); }
        return r;
    }

    public static List<string> DisplayConfigReport()
    {
        var o = new List<string>();
        uint np, nm;
        // ---- active paths
        uint flags = 2; // QDC_ONLY_ACTIVE_PATHS
        if (GetDisplayConfigBufferSizes(flags, out np, out nm) != 0) { o.Add("GetDisplayConfigBufferSizes failed"); return o; }
        var paths = new PATH_INFO[np]; var modes = new MODE_INFO[nm];
        int rc = QueryDisplayConfig(flags, ref np, paths, ref nm, modes, IntPtr.Zero);
        o.Add("QueryDisplayConfig(ONLY_ACTIVE) rc=" + rc + " paths=" + np + " modes=" + nm);
        var adapters = new Dictionary<string, string>();
        for (int i = 0; i < np; i++)
        {
            var pa = paths[i]; var t = pa.target;
            string ak = LuidKey(t.adapterId);
            if (!adapters.ContainsKey(ak)) adapters[ak] = AdapterName(t.adapterId);
            string[] tn = TargetName(t.adapterId, t.id);
            string src = SourceName(pa.source.adapterId, pa.source.id);
            string line = string.Format("ACTIVE {0} <- target 0x{1:X} on {2} | {3} '{4}' tech={5} base={6} connInst={7} status=0x{8:X} scaling={9} rot={10}",
                src, t.id, adapters[ak].Contains("VEN_10DE") ? "NVIDIA" : (adapters[ak].Contains("VEN_1002") ? "AMD" : ak), tn[0], tn[1], Tech(t.outputTechnology), BaseTech(t.adapterId, t.id), tn[3], t.statusFlags, t.scaling, t.rotation);
            o.Add(line);
            if (t.modeInfoIdx != 0xFFFFFFFF && t.modeInfoIdx < nm)
            {
                var m = modes[t.modeInfoIdx];
                double v = m.vSync.Den == 0 ? 0 : (double)m.vSync.Num / m.vSync.Den;
                double h = m.hSync.Den == 0 ? 0 : (double)m.hSync.Num / m.hSync.Den;
                o.Add(string.Format("       signal: active {0}x{1} total {2}x{3} pixelclock {4:0.000} MHz  vsync {5:0.000} Hz  hsync {6:0.00} kHz  videoStd={7} vDiv={8} scan={9}  -> {10:0.00} Gbit/s @24bpp, {11:0.00} @30bpp",
                    m.activeCx, m.activeCy, m.totalCx, m.totalCy, m.pixelRate / 1e6, v, h / 1000.0, m.videoStandard & 0xFFFF, (m.videoStandard >> 16) & 0x3F, m.scanLine, m.pixelRate * 24 / 1e9, m.pixelRate * 30 / 1e9));
            }
            if (pa.source.modeInfoIdx != 0xFFFFFFFF && pa.source.modeInfoIdx < nm)
            {
                var s = modes[pa.source.modeInfoIdx];
                o.Add(string.Format("       desktop: {0}x{1} at {2},{3} pixfmt={4}", s.srcW, s.srcH, s.posX, s.posY, s.pixFmt));
            }
            o.Add("       preferred(monitor): " + PreferredMode(t.adapterId, t.id));
            o.Add("       color: " + AdvColor(t.adapterId, t.id));
            o.Add("       path: " + tn[2]);
        }
        // ---- every available (connected) target, active or not
        flags = 1; // QDC_ALL_PATHS
        if (GetDisplayConfigBufferSizes(flags, out np, out nm) == 0)
        {
            paths = new PATH_INFO[np]; modes = new MODE_INFO[nm];
            rc = QueryDisplayConfig(flags, ref np, paths, ref nm, modes, IntPtr.Zero);
            var seen = new HashSet<string>();
            o.Add("QueryDisplayConfig(ALL_PATHS) rc=" + rc + " paths=" + np);
            for (int i = 0; i < np; i++)
            {
                var t = paths[i].target;
                string k = LuidKey(t.adapterId) + "/" + t.id;
                if (!seen.Add(k)) continue;
                string ak = LuidKey(t.adapterId);
                if (!adapters.ContainsKey(ak)) adapters[ak] = AdapterName(t.adapterId);
                if (t.targetAvailable == 0) continue;
                string[] tn = TargetName(t.adapterId, t.id);
                o.Add(string.Format("TARGET 0x{0:X} on {1} available | {2} '{3}' tech={4} connInst={5} status=0x{6:X}",
                    t.id, adapters[ak].Contains("VEN_10DE") ? "NVIDIA" : (adapters[ak].Contains("VEN_1002") ? "AMD" : ak), tn[0], tn[1], Tech(t.outputTechnology), tn[3], t.statusFlags));
            }
            uint topo;
            np = 0; nm = 0; GetDisplayConfigBufferSizes(4, out np, out nm);
            paths = new PATH_INFO[np]; modes = new MODE_INFO[nm];
            rc = QueryDisplayConfigTopo(4, ref np, paths, ref nm, modes, out topo);
            string[] tp = { "?", "internal", "clone", "extend", "?", "?", "?", "?", "external" };
            o.Add("Database topology (QDC_DATABASE_CURRENT) rc=" + rc + " topology=" + (topo < 9 ? tp[topo] : topo.ToString()) + " (" + topo + ")");
        }
        foreach (var kv in adapters) o.Add("ADAPTER " + kv.Key + " = " + kv.Value);
        return o;
    }

    // ------------------------------------------------------------------ NVAPI (query-only functions)
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr NvQI(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_EnumGpus([Out] IntPtr[] h, out int n);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_GpuIds(IntPtr gpu, IntPtr buf, ref uint count, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_AllIds(IntPtr gpu, IntPtr buf, ref uint count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_DpInfo(IntPtr hDisp, uint outputId, IntPtr info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Edid(IntPtr gpu, uint id, IntPtr edid);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_IdPtr(uint id, IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Ver(out uint ver, IntPtr branch64);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Name(IntPtr gpu, IntPtr name64);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_EnumDisp(uint i, out IntPtr h);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_HOut(IntPtr h, out uint outId);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_HName(IntPtr h, IntPtr name64);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_IdByName(IntPtr name, out uint id);

    static T F<T>(uint id) where T : class { IntPtr p = NvQI(id); if (p == IntPtr.Zero) return null; return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T; }
    static IntPtr Z(int n) { IntPtr p = Marshal.AllocHGlobal(n); for (int i = 0; i < n; i++) Marshal.WriteByte(p, i, 0); return p; }

    public static string Rate(uint r)
    {
        switch (r) { case 6: return "RBR 1.62"; case 0xA: return "HBR 2.70"; case 0x14: return "HBR2 5.40"; case 0x1E: return "HBR3 8.10"; case 0: return "none"; }
        return "raw0x" + r.ToString("X");
    }
    static double RateGbps(uint r) { switch (r) { case 6: return 1.62; case 0xA: return 2.7; case 0x14: return 5.4; case 0x1E: return 8.1; } return 0; }
    static string Conn(int c) { switch (c) { case 0: return "uninit"; case 1: return "VGA"; case 2: return "component"; case 3: return "S-video"; case 4: return "HDMI"; case 5: return "DVI"; case 6: return "LVDS"; case 7: return "DP"; case 8: return "composite"; case -1: return "unknown"; } return "c" + c; }

    public static Dictionary<uint, byte[]> NvEdids = new Dictionary<uint, byte[]>();

    public static List<string> NvReport(string[] gdiNames)
    {
        var o = new List<string>();
        try
        {
            var init = F<D_Init>(0x0150E828);
            if (init == null) { o.Add("NVAPI: nvapi_QueryInterface returned null for Initialize"); return o; }
            o.Add("NvAPI_Initialize = " + init());
            var ver = F<D_Ver>(0x2926AAAD);
            if (ver != null) { IntPtr b = Z(64); uint v; int r = ver(out v, b); o.Add("NvAPI_SYS_GetDriverAndBranchVersion rc=" + r + " driver=" + (v / 100) + "." + (v % 100).ToString("00") + " branch=" + Marshal.PtrToStringAnsi(b)); Marshal.FreeHGlobal(b); }
            var enumG = F<D_EnumGpus>(0xE5AC921F);
            IntPtr[] g = new IntPtr[64]; int ng;
            o.Add("NvAPI_EnumPhysicalGPUs rc=" + enumG(g, out ng) + " count=" + ng);
            var gname = F<D_Name>(0xCEEE8E9F);
            var conIds = F<D_GpuIds>(0x0078DBA2);
            var allIds = F<D_AllIds>(0x785210A2);
            var dpInfo = F<D_DpInfo>(0xC64FF367);
            var edid = F<D_Edid>(0x37D32E69);
            var color = F<D_IdPtr>(0x92F9D80D);
            var vrr = F<D_IdPtr>(0xDF8FDA57);
            var asyncData = F<D_IdPtr>(0xB73D1EE9);
            var idByName = F<D_IdByName>(0xAE457190);
            for (int gi = 0; gi < ng; gi++)
            {
                IntPtr nb = Z(64); gname(g[gi], nb); o.Add("GPU" + gi + ": " + Marshal.PtrToStringAnsi(nb)); Marshal.FreeHGlobal(nb);
                // all display ids (connected or not) - shows the connector inventory incl. MST children
                uint cnt = 0;
                int r0 = allIds(g[gi], IntPtr.Zero, ref cnt);
                o.Add("  GetAllDisplayIds(count) rc=" + r0 + " count=" + cnt);
                if (cnt > 0)
                {
                    IntPtr buf = Z(16 * (int)cnt);
                    for (int k = 0; k < cnt; k++) Marshal.WriteInt32(buf, k * 16, 16 | (3 << 16));
                    int r1 = allIds(g[gi], buf, ref cnt);
                    o.Add("  GetAllDisplayIds rc=" + r1);
                    for (int k = 0; k < cnt; k++)
                    {
                        int ct = Marshal.ReadInt32(buf, k * 16 + 4); uint id = U32(buf, k * 16 + 8); uint bits = U32(buf, k * 16 + 12);
                        o.Add(string.Format("    all  id=0x{0:X8} conn={1,-5} dynamic={2} mstRoot={3} active={4} osVisible={5} connected={6} physConnected={7} bits=0x{8:X}",
                            id, Conn(ct), bits & 1, (bits >> 1) & 1, (bits >> 2) & 1, (bits >> 4) & 1, (bits >> 6) & 1, (bits >> 17) & 1, bits));
                    }
                    Marshal.FreeHGlobal(buf);
                }
                cnt = 0;
                r0 = conIds(g[gi], IntPtr.Zero, ref cnt, 1 /*UNCACHED*/);
                o.Add("  GetConnectedDisplayIds(UNCACHED,count) rc=" + r0 + " count=" + cnt);
                if (cnt == 0) continue;
                IntPtr ids = Z(16 * (int)cnt);
                for (int k = 0; k < cnt; k++) Marshal.WriteInt32(ids, k * 16, 16 | (3 << 16));
                int rc = conIds(g[gi], ids, ref cnt, 1);
                o.Add("  GetConnectedDisplayIds rc=" + rc);
                string mstLink = "";
                for (int k = 0; k < cnt; k++)
                {
                    int ct = Marshal.ReadInt32(ids, k * 16 + 4); uint id = U32(ids, k * 16 + 8); uint bits = U32(ids, k * 16 + 12);
                    o.Add(string.Format("  DISPLAY id=0x{0:X8} conn={1} dynamic(MST)={2} mstRoot={3} active={4} osVisible={5} connected={6} physConnected={7}",
                        id, Conn(ct), bits & 1, (bits >> 1) & 1, (bits >> 2) & 1, (bits >> 4) & 1, (bits >> 6) & 1, (bits >> 17) & 1));
                    // EDID as the NVIDIA driver sees it
                    IntPtr e = Z(272); Marshal.WriteInt32(e, 0, 272 | (3 << 16));
                    int re = edid(g[gi], id, e);
                    if (re == 0)
                    {
                        int sz = Marshal.ReadInt32(e, 260); byte[] eb = new byte[256]; Marshal.Copy(new IntPtr(e.ToInt64() + 4), eb, 0, 256);
                        if (sz < 256 && sz > 0) Array.Resize(ref eb, sz);
                        NvEdids[id] = eb;
                        o.Add("     EDID(nvapi) " + sz + " bytes: " + EdidSummary(eb));
                    }
                    else o.Add("     EDID(nvapi) rc=" + re);
                    Marshal.FreeHGlobal(e);
                    // DisplayPort link info
                    IntPtr dp = Z(44); Marshal.WriteInt32(dp, 0, 44 | (1 << 16));
                    int rd = dpInfo(IntPtr.Zero, id, dp);
                    if (rd == 0)
                    {
                        uint dpcd = U32(dp, 4), maxR = U32(dp, 8), maxL = U32(dp, 12), curR = U32(dp, 16), curL = U32(dp, 20), cf = U32(dp, 24), dr = U32(dp, 28), cm = U32(dp, 32), bpc = U32(dp, 36), fl = U32(dp, 40);
                        string[] bpcs = { "default", "6", "8", "10", "12", "16" };
                        string[] cfs = { "RGB", "YCbCr422", "YCbCr444" };
                        double cap = RateGbps(curR) * curL * 0.8;
                        o.Add(string.Format("     DP: dpcd=0x{0:X2} max={1} x{2} | CURRENT={3} x{4} = {5:0.00} Gbit/s payload | colorFmt={6} range={7} colorimetry={8} bpc={9} | isDp={10} internalDp={11} colorCtrl={12} 6/8/10/12/16bpc={13}{14}{15}{16}{17} 420/422/444={18}{19}{20} flags=0x{21:X}",
                            dpcd, Rate(maxR), maxL, Rate(curR), curL, cap, cf < 3 ? cfs[cf] : cf.ToString(), dr == 0 ? "VESA-full" : (dr == 1 ? "CEA-limited" : dr.ToString()), cm, bpc < 6 ? bpcs[bpc] : bpc.ToString(),
                            fl & 1, (fl >> 1) & 1, (fl >> 2) & 1, (fl >> 3) & 1, (fl >> 4) & 1, (fl >> 5) & 1, (fl >> 6) & 1, (fl >> 7) & 1, (fl >> 8) & 1, (fl >> 9) & 1, (fl >> 10) & 1, fl));
                        // for MST children the 'current' fields come back as junk (0x989680); the 'max' pair is stable and is what limits the modes
                        if ((bits & 1) == 1) mstLink = "max " + Rate(maxR) + " x" + maxL + " = " + (RateGbps(maxR) * maxL * 0.8).ToString("0.00") + " Gbit/s payload shared by ALL dock monitors (HBR3 x2 = 12.96 good-period class, HBR2 x2 = 8.64 = 'DP 1.2' class)";
                    }
                    else o.Add("     DP: GetDisplayPortInfo rc=" + rd + (rd == -6 ? " (not a DP display / not available)" : ""));
                    Marshal.FreeHGlobal(dp);
                    // NVIDIA colour state (GET only)
                    IntPtr c = Z(24); Marshal.WriteInt32(c, 0, 24 | (5 << 16)); Marshal.WriteInt16(c, 4, 24); Marshal.WriteByte(c, 6, 1 /*GET*/);
                    int rcc = color(id, c);
                    if (rcc == 0)
                    {
                        string[] nbpc = { "default", "6", "8", "10", "12", "16" };
                        string[] fmt = { "RGB", "YUV422", "YUV444", "YUV420" };
                        byte f = Marshal.ReadByte(c, 8); byte cmy = Marshal.ReadByte(c, 9); byte rng = Marshal.ReadByte(c, 10); uint b2 = U32(c, 12); uint pol = U32(c, 16); uint dep = U32(c, 20);
                        o.Add(string.Format("     NV colour: format={0} colorimetry={1} range={2} bpc={3} policy={4} desktopDepth={5}",
                            f < 4 ? fmt[f] : ("0x" + f.ToString("X")), cmy, rng == 0 ? "full" : (rng == 1 ? "limited" : "auto"), b2 < 6 ? nbpc[b2] : b2.ToString(), pol == 0 ? "USER(manual)" : (pol == 1 ? "BEST_QUALITY(default)" : pol.ToString()), dep));
                    }
                    else o.Add("     NV colour: rc=" + rcc);
                    Marshal.FreeHGlobal(c);
                    // VRR / G-SYNC state
                    IntPtr vr = Z(24); Marshal.WriteInt32(vr, 0, 24 | (1 << 16));
                    int rv = vrr(id, vr);
                    if (rv == 0) { uint vb = U32(vr, 4); o.Add(string.Format("     VRR: enabled={0} possible={1} requested={2} indicator={3} inVRRmode={4}", vb & 1, (vb >> 1) & 1, (vb >> 2) & 1, (vb >> 3) & 1, (vb >> 4) & 1)); }
                    else o.Add("     VRR: rc=" + rv);
                    Marshal.FreeHGlobal(vr);
                    IntPtr asd = Z(40); Marshal.WriteInt32(asd, 0, 40 | (1 << 16));
                    int ra = asyncData(id, asd);
                    if (ra == 0) { uint ab = U32(asd, 8); o.Add(string.Format("     AdaptiveSync: maxFrameInterval={0} disableAdaptiveSync={1} disableFrameSplitting={2}", U32(asd, 4), ab & 1, (ab >> 1) & 1)); }
                    else o.Add("     AdaptiveSync: rc=" + ra);
                    Marshal.FreeHGlobal(asd);
                }
                Marshal.FreeHGlobal(ids);
                if (mstLink != "") o.Add("  MST (dock) link as reported for its streams: " + mstLink);
            }
            if (gdiNames != null && idByName != null)
                foreach (string n in gdiNames)
                {
                    IntPtr s = Marshal.StringToHGlobalAnsi(n); uint id; int r = idByName(s, out id); Marshal.FreeHGlobal(s);
                    o.Add("  GDI " + n + " -> NV displayId " + (r == 0 ? "0x" + id.ToString("X8") : "rc=" + r));
                }
        }
        catch (Exception ex) { o.Add("NVAPI exception: " + ex.GetType().Name + ": " + ex.Message); }
        return o;
    }

    // ------------------------------------------------------------------ EDID decode (no serial numbers printed)
    public static string EdidSummary(byte[] e)
    {
        if (e == null || e.Length < 128) return "short/none";
        var sb = new StringBuilder();
        int m = (e[8] << 8) | e[9];
        sb.Append("" + (char)(((m >> 10) & 31) + 64) + (char)(((m >> 5) & 31) + 64) + (char)((m & 31) + 64) + (e[10] | (e[11] << 8)).ToString("X4"));
        sb.Append(" v" + e[18] + "." + e[19]);
        byte vi = e[20];
        if ((vi & 0x80) != 0)
        {
            if (e[19] >= 4)
            {
                string[] depth = { "undef", "6", "8", "10", "12", "14", "16", "res" };
                string[] ifc = { "undef", "DVI", "HDMIa", "HDMIb", "MDDI", "DisplayPort" };
                int it = vi & 0x0F;
                sb.Append(" input=digital(" + (it < 6 ? ifc[it] : it.ToString()) + "," + depth[(vi >> 4) & 7] + "bpc)");
            }
            else sb.Append(" input=digital(EDID1.3)");
        }
        else sb.Append(" input=analog");
        string name = "";
        for (int d = 54; d <= 108; d += 18)
        {
            if (e[d] == 0 && e[d + 1] == 0)
            {
                if (e[d + 3] == 0xFC) name = Encoding.ASCII.GetString(e, d + 5, 13).Split('\n')[0].Trim();
            }
        }
        int pc = (e[54] | (e[55] << 8)) * 10;
        int ha = e[56] | ((e[58] & 0xF0) << 4), va = e[59] | ((e[61] & 0xF0) << 4);
        int hb = e[57] | ((e[58] & 0x0F) << 8), vb = e[60] | ((e[61] & 0x0F) << 8);
        double hz = (ha + hb) * (va + vb) == 0 ? 0 : pc * 1000.0 / ((ha + hb) * (va + vb));
        sb.Append(" name='" + name + "' preferred=" + ha + "x" + va + "@" + hz.ToString("0.00") + "(" + (pc / 1000.0).ToString("0.00") + "MHz)");
        sb.Append(" ext=" + e[126]);
        for (int b = 1; b <= e[126] && (b + 1) * 128 <= e.Length; b++)
        {
            int o = b * 128;
            if (e[o] == 0x02)
            {
                sb.Append(" | CTA-861 rev" + e[o + 1] + " flags=0x" + e[o + 3].ToString("X2") + "(underscan=" + ((e[o + 3] >> 7) & 1) + ",audio=" + ((e[o + 3] >> 6) & 1) + ",444=" + ((e[o + 3] >> 5) & 1) + ",422=" + ((e[o + 3] >> 4) & 1) + ")");
                int dtd = e[o + 2]; int p = o + 4;
                var blocks = new List<string>();
                while (p < o + dtd && dtd > 4)
                {
                    int tag = e[p] >> 5, len = e[p] & 31;
                    if (tag == 3 && len >= 3)
                    {
                        int oui = e[p + 1] | (e[p + 2] << 8) | (e[p + 3] << 16);
                        if (oui == 0x000C03) blocks.Add("HDMI-VSDB(len" + len + (len >= 7 ? ",maxTMDS=" + (e[p + 7] * 5) + "MHz" : "") + ")");
                        else if (oui == 0xC45DD8) blocks.Add("HDMI-Forum-VSDB(maxTMDS=" + (e[p + 5] * 5) + "MHz" + (len >= 7 ? ",FRL=" + (e[p + 7] >> 4) : "") + (len >= 11 ? ",DSC=0x" + e[p + 11].ToString("X2") : "") + ")");
                        else if (oui == 0x00001A) blocks.Add("AMD-FreeSync-VSDB(" + (len >= 6 ? "range " + e[p + 5] + "-" + e[p + 6] + "Hz" : "") + ")");
                        else blocks.Add("VSDB-OUI-" + oui.ToString("X6"));
                    }
                    else if (tag == 7 && len >= 1)
                    {
                        int et = e[p + 1];
                        string en = et == 0 ? "VideoCap" : et == 5 ? "Colorimetry" : et == 6 ? "HDR-static" : et == 7 ? "HDR-dynamic" : et == 0x0E ? "YCbCr420-video" : et == 0x0F ? "YCbCr420-capmap" : et == 0x78 ? "HF-EEODB" : et == 0x79 ? "HF-SCDB" : ("ext" + et);
                        blocks.Add(en);
                    }
                    else blocks.Add(tag == 1 ? "Audio" : tag == 2 ? "Video(" + len + " VICs)" : tag == 4 ? "Speaker" : ("tag" + tag));
                    p += len + 1;
                }
                sb.Append(" blocks=[" + string.Join(",", blocks.ToArray()) + "]");
            }
            else if (e[o] == 0x70) sb.Append(" | DisplayID ext");
            else sb.Append(" | ext tag 0x" + e[o].ToString("X2"));
        }
        return sb.ToString();
    }
}
