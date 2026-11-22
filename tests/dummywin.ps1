# Harmless dummy window for the window-move tests: a normal framed (sizable) top-level window, but fully
# transparent (alpha 0), click-through, never activated, not in the taskbar, at the bottom of the z-order.
# Writes its HWND to -HandleFile and closes itself after -Seconds (the test runner also stops it by PID).
# -Enforce makes it behave like X4 9.00 in the live test: it keeps its own rectangle and style (rejects them in
# WM_WINDOWPOSCHANGING / WM_STYLECHANGING), so SetWindowPos & co. return success but nothing changes.
param([Parameter(Mandatory = $true)][string]$HandleFile, [int]$Seconds = 90, [switch]$Enforce)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Windows.Forms; using System.Runtime.InteropServices;
public class X4C3DummyForm : Form {
  [StructLayout(LayoutKind.Sequential)] struct WINDOWPOS { public IntPtr hwnd, after; public int x, y, cx, cy; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] struct STYLESTRUCT { public uint styleOld, styleNew; }
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  public static void Dpi() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { } }
  public bool Enforce; bool locked; int lx, ly, lw, lh;
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams { get { var p = base.CreateParams;
    p.ExStyle |= 0x08000000 | 0x00000080 | 0x00000020; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT
    return p; } }
  public void ToBottom() { SetWindowPos(Handle, new IntPtr(1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); } // NOSIZE|NOMOVE|NOACTIVATE
  public void Lock() { lx = Left; ly = Top; lw = Width; lh = Height; locked = Enforce; }
  protected override void WndProc(ref Message m) {
    if (locked && m.Msg == 0x0046) { // WM_WINDOWPOSCHANGING: keep our own rectangle
      var wp = (WINDOWPOS)Marshal.PtrToStructure(m.LParam, typeof(WINDOWPOS));
      wp.x = lx; wp.y = ly; wp.cx = lw; wp.cy = lh; wp.flags |= 0x0001 | 0x0002; // NOSIZE|NOMOVE
      Marshal.StructureToPtr(wp, m.LParam, false);
    }
    if (locked && m.Msg == 0x007C && m.WParam.ToInt64() == -16) { // WM_STYLECHANGING (GWL_STYLE): keep our style
      var ss = (STYLESTRUCT)Marshal.PtrToStructure(m.LParam, typeof(STYLESTRUCT));
      ss.styleNew = ss.styleOld; Marshal.StructureToPtr(ss, m.LParam, false);
    }
    base.WndProc(ref m);
  }
}
'@
[X4C3DummyForm]::Dpi()
$f = New-Object X4C3DummyForm
$f.Enforce = [bool]$Enforce
$f.Text = 'x4cockpit3 test window (harmless, invisible)'
$f.ShowInTaskbar = $false
$f.Opacity = 0.0
$f.StartPosition = 'Manual'
$f.Location = New-Object System.Drawing.Point(200, 200)
$f.Size = New-Object System.Drawing.Size(320, 200)
$t = New-Object System.Windows.Forms.Timer
$t.Interval = [Math]::Max(5, $Seconds) * 1000
$t.add_Tick({ $f.Close() })
$f.add_Shown({ $f.ToBottom(); $f.Lock(); Set-Content -LiteralPath $HandleFile -Value ('0x{0:X}' -f [int64]$f.Handle); $t.Start() })
[System.Windows.Forms.Application]::Run($f)
Remove-Item -LiteralPath $HandleFile -ErrorAction SilentlyContinue
