// Reads what each monitor says about ITSELF over its control channel (DDC/CI). Read-only.
// Measured on the Dell P2714H behind the dock: power=1 while it shows a picture, power=4 while it is dark
// although Windows keeps sending its signal. That makes "dark monitor" detectable without looking at it.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class MonDdc
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
    delegate bool MonProc(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr d);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonProc p, IntPtr d);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);
    [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYSICAL_MONITOR[] a);

    // one entry per physical monitor: "x,y|power|input"; power/input are -1 when the monitor does not answer.
    // power: 1 = on, 2-5 = standby/off.  input: 15 = DisplayPort, 3 = DVI, 17/18 = HDMI.
    public static string[] Read()
    {
        var o = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hm, IntPtr hdc, ref RECT r, IntPtr d)
        {
            uint n;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) return true;
            var a = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, n, a)) return true;
            foreach (var m in a)
            {
                uint t, cur, max; int power = -1, input = -1;
                if (GetVCPFeatureAndVCPFeatureReply(m.h, 0xD6, out t, out cur, out max)) power = (int)cur;
                if (GetVCPFeatureAndVCPFeatureReply(m.h, 0x60, out t, out cur, out max)) input = (int)cur;
                o.Add(r.l + "," + r.t + "|" + power + "|" + input);
            }
            DestroyPhysicalMonitors(n, a);
            return true;
        }, IntPtr.Zero);
        return o.ToArray();
    }
}
