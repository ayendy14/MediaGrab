param([string]$ExePath)
# MediaGrab - press the shortcut on a YouTube or Spotify tab (or with a link copied) to download it.
# Runs from MediaGrab.exe. yt-dlp and ffmpeg are downloaded automatically on first run.
# Keep this file plain ASCII: Windows PowerShell reads it without a byte-order mark.

$Version = '1.0.0'
$App = "$env:LOCALAPPDATA\MediaGrab"
New-Item $App -ItemType Directory -Force | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# A short diary of what MediaGrab did, to track down problems: %LOCALAPPDATA%\MediaGrab\log.txt
$LogFile = "$App\log.txt"
try { if ((Get-Item $LogFile -ErrorAction Ignore).Length -gt 500KB) { Move-Item $LogFile "$LogFile.old" -Force } } catch { }
function Log($text) { try { Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $text" -Encoding UTF8 } catch { } }

# Only one MediaGrab at a time. A newly started copy asks the running one to close, then takes over.
$Mutex = New-Object Threading.Mutex($false, 'MediaGrab-SingleInstance')
$QuitEvent = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'MediaGrab-Quit')
function Get-Mutex($ms) { try { $Mutex.WaitOne($ms) } catch { $true } }   # an abandoned mutex (a copy that crashed) counts as ours
if (-not (Get-Mutex 0)) {
    [void]$QuitEvent.Set()
    if (-not (Get-Mutex 8000)) {
        Log 'Another MediaGrab is running and did not close'
        [void][Windows.Forms.MessageBox]::Show("An older MediaGrab is still running.`n`nRight-click the red MediaGrab icon next to the clock, choose Exit, then start MediaGrab again.", 'MediaGrab', 'OK', 'Information', 'Button1', 'DefaultDesktopOnly')
        exit
    }
}
[void]$QuitEvent.Reset()
$Error.Clear()
Log "MediaGrab $Version started"

# Window controls, written in C#. Compiled once and kept as a DLL, so later starts are faster.
$UiCode = @'
using System; using System.ComponentModel; using System.Drawing; using System.Drawing.Drawing2D;
using System.Globalization; using System.Windows.Forms; using System.Runtime.InteropServices;

public class Hotkey : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    public static void Hint(TextBox box, string text) { SendMessage(box.Handle, 0x1501, (IntPtr)1, text); }
    public event EventHandler Pressed;
    public bool Register(uint mod, uint vk) {
        if (Handle == IntPtr.Zero) CreateHandle(new CreateParams());
        UnregisterHotKey(Handle, 1); return RegisterHotKey(Handle, 1, mod | 0x4000, vk);
    }
    public void Unregister() { if (Handle != IntPtr.Zero) UnregisterHotKey(Handle, 1); }
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static void Tap(byte[] keys) {   // presses keys like a person (used by the self-test)
        foreach (byte k in keys) keybd_event(k, 0, 0, UIntPtr.Zero);
        for (int i = keys.Length - 1; i >= 0; i--) keybd_event(keys[i], 0, 2, UIntPtr.Zero);
    }
    protected override void WndProc(ref Message m) { if (m.Msg == 0x312 && Pressed != null) Pressed(this, null); base.WndProc(ref m); }
}

// Drawing helpers shared by the controls below
public static class MgUi {
    public static float Scale = 1f;   // display scaling (1 = 100%, 1.5 = 150%)
    public static float S(float v) { return v * Scale; }
    public static int Px(float v) { return (int)Math.Round(v * Scale); }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);
    public static void DarkTitle(IntPtr h) { int on = 1; if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4); }
    public static void DarkScroll(IntPtr h) { SetWindowTheme(h, "DarkMode_Explorer", null); }
    public static void DarkCombo(IntPtr h) { SetWindowTheme(h, "DarkMode_CFD", null); }
    public static GraphicsPath Round(RectangleF r, float radius) {
        GraphicsPath p = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0.5f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
    public static Color Mix(Color a, Color b, double t) {
        return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
    public static Color Under(Control c) { return c.Parent != null ? c.Parent.BackColor : SystemColors.Control; }
}

// Button with rounded corners and a hover color
public class MgButton : Button {
    Color fill = Color.Gray, hover = Color.DimGray; bool over;
    public Color Fill { get { return fill; } set { fill = value; Invalidate(); } }
    public Color Hover { get { return hover; } set { hover = value; Invalidate(); } }
    public int Radius { get; set; }
    public MgButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand; Radius = 8;
    }
    protected override void OnMouseEnter(EventArgs e) { over = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { over = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; Color under = MgUi.Under(this);
        g.Clear(under); g.SmoothingMode = SmoothingMode.AntiAlias;
        Color c = !Enabled ? MgUi.Mix(fill, under, 0.55) : (over ? hover : fill);
        using (GraphicsPath p = MgUi.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), MgUi.S(Radius)))
        using (SolidBrush b = new SolidBrush(c)) g.FillPath(b, p);
        float i = MgUi.S(2.5f);
        if (Focused && ShowFocusCues)
            using (GraphicsPath p = MgUi.Round(new RectangleF(i, i, Width - 2 * i - 0.5f, Height - 2 * i - 0.5f), MgUi.S(Math.Max(Radius - 2, 1))))
            using (Pen pen = new Pen(MgUi.Mix(c, ForeColor, 0.5), MgUi.S(1.5f))) g.DrawPath(pen, p);
        Color t = Enabled ? ForeColor : MgUi.Mix(ForeColor, c, 0.45);
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, t, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
    }
}

// Text box inside a rounded frame that lights up while typing
public class MgField : Panel {
    public readonly TextBox Box = new TextBox();
    Color border = Color.Silver, focusColor = Color.RoyalBlue;
    public Color Border { get { return border; } set { border = value; Invalidate(); } }
    public Color FocusColor { get { return focusColor; } set { focusColor = value; Invalidate(); } }
    public Color Fill { get { return Box.BackColor; } set { Box.BackColor = value; Invalidate(); } }
    public MgField() {
        DoubleBuffered = true; ResizeRedraw = true; Height = 32; Cursor = Cursors.IBeam;
        Box.BorderStyle = BorderStyle.None; Controls.Add(Box);
        Box.SizeChanged += delegate { PerformLayout(); };
        Box.GotFocus += delegate { Invalidate(); }; Box.LostFocus += delegate { Invalidate(); };
        Click += delegate { Box.Focus(); };
    }
    protected override void OnLayout(LayoutEventArgs e) {   // text box centred vertically, with room on the sides
        base.OnLayout(e);
        int pad = MgUi.Px(10);
        Box.SetBounds(pad, Math.Max(0, (Height - Box.Height) / 2), Math.Max(10, Width - 2 * pad), Box.Height);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.Clear(MgUi.Under(this)); g.SmoothingMode = SmoothingMode.AntiAlias;
        bool f = Box.Focused; float w = MgUi.S(f ? 1.5f : 1f);
        using (GraphicsPath p = MgUi.Round(new RectangleF(w / 2, w / 2, Width - w - 0.5f, Height - w - 0.5f), MgUi.S(7)))
        using (SolidBrush b = new SolidBrush(Box.BackColor))
        using (Pen pen = new Pen(f ? focusColor : border, w)) { g.FillPath(b, p); g.DrawPath(pen, p); }
    }
}

// Shortcut box: click it, then press the keys you want (e.g. Ctrl+Shift+D)
public class MgKeyField : MgField {
    [DllImport("user32.dll")] static extern short GetKeyState(int key);
    string value = "";
    public string Prompt { get; set; }
    public string Value { get { return value; } set { this.value = value ?? ""; if (!Box.Focused) Box.Text = this.value; } }
    public MgKeyField() {
        Prompt = "Press the new shortcut...";
        Box.ReadOnly = true; Box.ShortcutsEnabled = false; Box.Cursor = Cursors.Hand; Cursor = Cursors.Hand;
        Box.PreviewKeyDown += delegate(object s, PreviewKeyDownEventArgs e) {
            bool plain = !e.Control && !e.Alt && !Win();
            if (plain && (e.KeyCode == Keys.Tab || e.KeyCode == Keys.Enter || e.KeyCode == Keys.Escape)) return;
            e.IsInputKey = true;   // keep keys like Alt+letter from moving focus
        };
        Box.KeyDown += OnKey;
        Box.KeyUp += delegate { if (Box.Focused && Box.Text.EndsWith("+")) Box.Text = Prompt; };
        Box.GotFocus += delegate { Box.Text = Prompt; };
        Box.LostFocus += delegate { Box.Text = value; };
    }
    static bool Win() { return (GetKeyState(0x5B) & 0x8000) != 0 || (GetKeyState(0x5C) & 0x8000) != 0; }
    void OnKey(object s, KeyEventArgs e) {
        Keys k = e.KeyCode; bool win = Win();
        bool plain = !e.Control && !e.Alt && !win;
        if (plain && (k == Keys.Tab || k == Keys.Enter || k == Keys.Escape)) return;
        e.Handled = true; e.SuppressKeyPress = true;
        string mods = (e.Control ? "Ctrl+" : "") + (e.Alt ? "Alt+" : "") + (e.Shift ? "Shift+" : "") + (win ? "Win+" : "");
        if (k == Keys.ControlKey || k == Keys.ShiftKey || k == Keys.Menu || k == Keys.LWin || k == Keys.RWin) { Box.Text = mods; return; }
        if (plain) { Box.Text = "Also hold Ctrl, Alt or Win"; return; }
        string name = (k >= Keys.D0 && k <= Keys.D9) ? ((int)(k - Keys.D0)).ToString() : k.ToString();
        value = mods + name; Box.Text = value;
    }
}

// A row of options where one is picked (like a segmented switch)
public class MgSegments : Control {
    string[] items = new string[0]; int sel = -1, hot = -1;
    public Color Track { get; set; }
    public Color Pill { get; set; }
    public Color PillText { get; set; }
    public Color Sub { get; set; }
    public event EventHandler Changed;
    public MgSegments() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false); TabStop = false;
        Cursor = Cursors.Hand; Height = 32; Track = Color.Gainsboro; Pill = Color.White; PillText = Color.Black; Sub = Color.DimGray;
    }
    public string[] Items { get { return items; } set { items = value ?? new string[0]; sel = items.Length > 0 ? 0 : -1; Invalidate(); } }
    public string Value {
        get { return sel >= 0 && sel < items.Length ? items[sel] : null; }
        set { int i = Array.IndexOf(items, value); Pick(i >= 0 ? i : (items.Length > 0 ? 0 : -1)); }
    }
    void Pick(int i) { sel = i; Invalidate(); if (Changed != null) Changed(this, EventArgs.Empty); }
    RectangleF Cell(int i) { float m = MgUi.S(3), w = (Width - 2 * m) / items.Length; return new RectangleF(m + i * w, m, w, Height - 2 * m); }
    int At(Point p) {
        if (items.Length == 0) return -1;
        float m = MgUi.S(3);
        int i = (int)((p.X - m) * items.Length / Math.Max(1f, Width - 2 * m));
        return Math.Max(0, Math.Min(items.Length - 1, i));
    }
    protected override void OnMouseMove(MouseEventArgs e) { int h = At(e.Location); if (h != hot) { hot = h; Invalidate(); } base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = -1; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left && items.Length > 0) Pick(At(e.Location)); base.OnMouseDown(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.Clear(MgUi.Under(this)); g.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath p = MgUi.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), MgUi.S(8)))
        using (SolidBrush b = new SolidBrush(Track)) g.FillPath(b, p);
        for (int i = 0; i < items.Length; i++) {
            RectangleF r = Cell(i); Color tc = Sub;
            if (i == sel) {
                using (GraphicsPath p = MgUi.Round(r, MgUi.S(6)))
                using (SolidBrush b = new SolidBrush(Enabled ? Pill : MgUi.Mix(Pill, Track, 0.6))) g.FillPath(b, p);
                tc = PillText;
            } else if (i == hot && Enabled) tc = ForeColor;
            if (!Enabled) tc = MgUi.Mix(tc, Track, 0.55);
            TextRenderer.DrawText(g, items[i], Font, Rectangle.Round(r), tc, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
    }
}

// Picture with rounded corners, loaded from the internet in the background
public class MgThumb : Control {
    Image img; PictureBox current;
    public bool Crop { get; set; }
    public Color Empty { get; set; }
    public MgThumb() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false); TabStop = false;
        Crop = true; Empty = Color.Gainsboro;
    }
    public void ClearImage() { current = null; img = null; Invalidate(); }
    public void LoadUrl(string url) {
        ClearImage();
        PictureBox pb = new PictureBox(); current = pb;
        pb.LoadCompleted += delegate(object s, AsyncCompletedEventArgs e) {
            if (pb == current && e.Error == null && !e.Cancelled) { img = pb.Image; Invalidate(); }
        };
        try { pb.LoadAsync(url); } catch { }
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.Clear(MgUi.Under(this));
        g.SmoothingMode = SmoothingMode.AntiAlias; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        using (GraphicsPath p = MgUi.Round(new RectangleF(0, 0, Width - 0.5f, Height - 0.5f), MgUi.S(10))) {
            using (SolidBrush b = new SolidBrush(Empty)) g.FillPath(b, p);
            if (img == null || img.Width == 0 || img.Height == 0) return;
            float sx = (float)Width / img.Width, sy = (float)Height / img.Height;
            float s = Crop ? Math.Max(sx, sy) : Math.Min(sx, sy);
            float w = img.Width * s, h = img.Height * s, x = (Width - w) / 2, y = (Height - h) / 2;
            using (TextureBrush tb = new TextureBrush(img, WrapMode.Clamp)) {
                tb.TranslateTransform(x, y); tb.ScaleTransform(s, s);
                if (Crop) g.FillPath(tb, p);
                else using (GraphicsPath q = MgUi.Round(new RectangleF(x, y, w, h), MgUi.S(8))) g.FillPath(tb, q);
            }
        }
    }
}

// Download list with taller rows, colored status and a progress bar
public class MgList : ListView {
    ListViewItem hotItem;
    public Color Head { get; set; }
    public Color Line { get; set; }
    public Color Sub { get; set; }
    public Color Accent { get; set; }
    public Color Track { get; set; }
    public Color Sel { get; set; }
    public Color Good { get; set; }
    public Color Bad { get; set; }
    public string EmptyText { get; set; }
    public int RowHeight {
        get { return SmallImageList.ImageSize.Height; }
        set { SmallImageList.ImageSize = new Size(1, Math.Max(16, Math.Min(256, value))); }
    }
    public MgList() {
        OwnerDraw = true; DoubleBuffered = true; View = View.Details; FullRowSelect = true; MultiSelect = false;
        HeaderStyle = ColumnHeaderStyle.Nonclickable; BorderStyle = BorderStyle.None;
        SmallImageList = new ImageList(); SmallImageList.ImageSize = new Size(1, 42);
        Head = Color.White; Line = Color.Gainsboro; Sub = Color.Gray; Accent = Color.RoyalBlue; Track = Color.Gainsboro;
        Sel = Color.AliceBlue; Good = Color.Green; Bad = Color.Firebrick;
    }
    public int StatusWidth { get; set; }
    public void FitColumns() {   // date keeps its width; name and status share the rest
        if (Columns.Count < 3) return;
        int rest = ClientSize.Width - Columns[2].Width;
        int status = Math.Max(80, Math.Min(StatusWidth > 0 ? StatusWidth : 260, rest / 2));
        if (rest - status < 80) return;
        if (Columns[1].Width != status) Columns[1].Width = status;
        if (Columns[0].Width != rest - status) Columns[0].Width = rest - status;
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); FitColumns(); }
    protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e) {
        Graphics g = e.Graphics;
        using (SolidBrush b = new SolidBrush(Head)) g.FillRectangle(b, e.Bounds);
        Rectangle r = new Rectangle(e.Bounds.X + MgUi.Px(12), e.Bounds.Y, Math.Max(0, e.Bounds.Width - MgUi.Px(12)), e.Bounds.Height);
        TextRenderer.DrawText(g, e.Header.Text, Font, r, Sub, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        using (Pen p = new Pen(Line)) g.DrawLine(p, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
    }
    protected override void OnDrawItem(DrawListViewItemEventArgs e) { }
    protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e) {
        Graphics g = e.Graphics; Rectangle r = e.Bounds;
        if (e.ColumnIndex == 0) r.Width = Columns[0].Width;
        using (SolidBrush b = new SolidBrush(e.Item.Selected ? Sel : BackColor)) g.FillRectangle(b, r);
        using (Pen p = new Pen(Line)) g.DrawLine(p, r.Left, r.Bottom - 1, r.Right, r.Bottom - 1);
        string text = e.SubItem.Text ?? "";
        Color c = ForeColor;
        Rectangle tr = new Rectangle(r.X + MgUi.Px(12), r.Y, Math.Max(0, r.Width - MgUi.Px(18)), r.Height);
        if (e.ColumnIndex == 1) {
            c = text == "Done" ? Good : (text.StartsWith("Failed") ? Bad : Sub);
            string tag = e.SubItem.Tag as string; double pct;
            if (tag != null && double.TryParse(tag, NumberStyles.Float, CultureInfo.InvariantCulture, out pct)) {
                int zone = MgUi.Px(16);   // space for the bar under the text
                tr = new Rectangle(tr.X, r.Y + MgUi.Px(2), tr.Width, r.Height - zone);
                RectangleF bar = new RectangleF(tr.X, r.Bottom - zone + MgUi.S(2), Math.Max(10, tr.Width - MgUi.Px(6)), MgUi.S(4));
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (GraphicsPath p = MgUi.Round(bar, MgUi.S(2))) using (SolidBrush b = new SolidBrush(Track)) g.FillPath(b, p);
                float w = (float)(bar.Width * Math.Max(0, Math.Min(100, pct)) / 100);
                if (w >= 1)
                    using (GraphicsPath p = MgUi.Round(new RectangleF(bar.X, bar.Y, w, bar.Height), MgUi.S(2)))
                    using (SolidBrush b = new SolidBrush(Accent)) g.FillPath(b, p);
                g.SmoothingMode = SmoothingMode.Default;
            }
        } else if (e.ColumnIndex == 2) c = Sub;
        TextRenderer.DrawText(g, text, Font, tr, c, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
    }
    protected override void OnMouseMove(MouseEventArgs e) {   // works around rows not repainting fully on hover
        base.OnMouseMove(e);
        ListViewItem it = GetItemAt(e.X, e.Y);
        if (it != hotItem) {
            if (hotItem != null && hotItem.ListView == this) Invalidate(hotItem.Bounds);
            hotItem = it; if (it != null) Invalidate(it.Bounds);
        }
    }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg != 0x000F) return;
        // below the last row: plain background (the dark theme would draw column lines there), or the "no downloads" text
        int top = Items.Count > 0 ? Items[Items.Count - 1].Bounds.Bottom : Font.Height * 2;
        if (top >= ClientSize.Height) return;
        using (Graphics g = CreateGraphics())
        using (SolidBrush b = new SolidBrush(BackColor)) {
            g.FillRectangle(b, 0, top, ClientSize.Width, ClientSize.Height - top);
            if (Items.Count == 0 && !string.IsNullOrEmpty(EmptyText)) {
                int side = MgUi.Px(20);
                Rectangle r = new Rectangle(side, Font.Height * 3, Math.Max(0, ClientSize.Width - 2 * side), Math.Max(0, ClientSize.Height - Font.Height * 3));
                TextRenderer.DrawText(g, EmptyText, Font, r, Sub, TextFormatFlags.HorizontalCenter | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
            }
        }
    }
}
'@
function Import-Ui {
    $sha  = New-Object Security.Cryptography.SHA1Managed
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($UiCode))).Replace('-', '').Substring(0, 12)
    $dll  = "$App\ui-$hash.dll"   # the name changes whenever the code changes
    if (-not (Test-Path $dll)) {
        Get-ChildItem "$App\ui-*.dll" | Remove-Item -Force -ErrorAction Ignore   # left over from older versions
        $tmp = "$env:TEMP\mediagrab-ui-$hash-$PID.dll"
        $opt = New-Object CodeDom.Compiler.CompilerParameters -Property @{ OutputAssembly = $tmp; GenerateInMemory = $false }
        $opt.ReferencedAssemblies.AddRange([string[]]('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll'))
        $res = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromSource($opt, $UiCode)
        if ($res.Errors.HasErrors) { throw ($res.Errors | Out-String) }
        Move-Item $tmp $dll -Force
    }
    Add-Type -Path $dll
}
try { Import-Ui }
catch {   # could not use the saved copy: compile in memory this time
    Log "Window controls: $_"
    Get-ChildItem "$App\ui-*.dll" -ErrorAction Ignore | Remove-Item -Force -ErrorAction Ignore
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $UiCode
}
# Draw at the screen's real resolution (otherwise Windows stretches the windows and text looks blurry)
[void][Hotkey]::SetProcessDPIAware()
# When a program is started with "start hidden", Windows hides the first window it shows. Use that
# up on an invisible placeholder, so the download window is never the one that gets hidden.
$first = New-Object Windows.Forms.NativeWindow; $first.CreateHandle((New-Object Windows.Forms.CreateParams))
[void][Hotkey]::ShowWindow($first.Handle, 0); $first.DestroyHandle()
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

# ============================ Settings ============================
$Bin      = "$App\bin"
$CfgFile  = "$App\settings.json"
$HistFile = "$App\history.json"
$RunKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$Choices  = @{ Format = 'mp3', 'm4a', 'opus', 'flac', 'wav', 'mp4'; VideoQuality = 'Best', '1080p', '720p', '480p', '360p'; EmbedInfo = 'Yes', 'No' }
$C = [ordered]@{
    Hotkey = 'Ctrl+Alt+Y'; SaveDir = "$env:USERPROFILE\Downloads"; Format = 'mp3'; VideoQuality = 'Best'; AudioQuality = '0'; EmbedInfo = 'Yes'
    StartTime = ''; EndTime = ''; FileName = ''; MatchTolerance = '3'; Browsers = 'chrome, msedge, firefox, brave, opera, vivaldi'
}
if (Test-Path $CfgFile) {   # a damaged settings file falls back to the defaults
    try { (Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | Where-Object { $C.Contains($_.Name) -and "$($_.Value)" -ne '' -or $_.Name -in 'StartTime', 'EndTime', 'FileName' } | ForEach-Object { $C[$_.Name] = "$($_.Value)" } }
    catch { Log "Settings file could not be read: $_" }
}
function Save-Config { $C | ConvertTo-Json | Set-Content $CfgFile -Encoding UTF8 }

$S   = @{ Active = [Collections.ArrayList]@() }
$Dot = "   $([char]0xB7)   "
$ErrorLog = [Collections.ArrayList]@()
# Moves script errors into the log file (and a list the self-test reads)
function Flush-Errors {
    if ($Error.Count -eq 0) { return }
    foreach ($er in @($Error)) { $text = "$er  [line $($er.InvocationInfo.ScriptLineNumber)]"; [void]$ErrorLog.Add($text); Log "Error: $text" }
    $Error.Clear()
}

# ============================ Look and feel ============================
# Follows the Windows light / dark app setting
function Color($hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
$Dark = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Ignore).AppsUseLightTheme -eq 0
if ($env:MEDIAGRAB_THEME) { $Dark = $env:MEDIAGRAB_THEME -eq 'dark' }   # set by the automatic build check
$Palette = if ($Dark) {
    @{ Bg = '#1B1C1F'; Card = '#232428'; Field = '#2A2C31'; Border = '#3B3E45'; Line = '#2E3035'; Text = '#ECEDEF'; Sub = '#A2A7AE'; Faint = '#70757C'
       Track = '#2A2C31'; Pill = '#43464D'; Btn = '#2E3036'; BtnHover = '#3A3D44'; Primary = '#ECEDEF'; PrimaryHover = '#D2D4D8'; PrimaryText = '#16171A'
       Focus = '#5B9BFF'; Sel = '#2D3340'; Good = '#4ADE80'; Bad = '#F87171' }
} else {
    @{ Bg = '#F4F5F7'; Card = '#FFFFFF'; Field = '#FFFFFF'; Border = '#D5D8DE'; Line = '#E3E5E9'; Text = '#1A1C20'; Sub = '#5F6670'; Faint = '#959BA3'
       Track = '#E6E8EC'; Pill = '#FFFFFF'; Btn = '#E6E8EC'; BtnHover = '#DADDE2'; Primary = '#1A1C20'; PrimaryHover = '#363940'; PrimaryText = '#FFFFFF'
       Focus = '#2563EB'; Sel = '#EAF0FC'; Good = '#15803D'; Bad = '#C62828' }
}
$Palette += @{ YouTube = '#E62117'; YouTubeHover = '#C41B12'; Spotify = '#1DB954'; SpotifyHover = '#18A148' }
$T = @{}; foreach ($k in $Palette.Keys) { $T[$k] = Color $Palette[$k] }
# Display scaling: 1 at 100%, 1.5 at 150%. MEDIAGRAB_SCALE lets the build check try other sizes.
$gfx = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $Z = $gfx.DpiX / 96; $gfx.Dispose()
$FontZ = if ($env:MEDIAGRAB_SCALE) { [double]$env:MEDIAGRAB_SCALE } else { 1 }
$Z *= $FontZ; [MgUi]::Scale = $Z
function Px($n) { [int][math]::Round($n * $Z) }
function New-Font($size, $bold) { New-Object Drawing.Font($(if ($bold) { 'Segoe UI Semibold' } else { 'Segoe UI' }), [single]($size * $FontZ)) }
$Fonts = @{
    Base   = New-Font 10.5
    Small  = New-Font 9 $true
    Url    = New-Font 9
    Button = New-Font 10 $true
    Head   = New-Font 12 $true
    Title  = New-Font 15 $true
}
$CtlH = [math]::Max((Px 36), $Fonts.Base.Height + (Px 14))   # height of boxes, buttons and switches
Log "Display scale $([math]::Round($Z, 2)), $(if ($Dark) { 'dark' } else { 'light' }) mode"

# ============================ Helpers =============================
function Get-Kind($url) {
    if ($url -match '^https?://([\w-]+\.)*(youtube\.com|youtu\.be)/') { 'youtube' }
    elseif ($url -match '^https?://open\.spotify\.com/(intl-[\w-]+/)?track/') { 'spotify' }
}

# Starts yt-dlp hidden. Returns the process (P) and its error output (Err), read in the background.
function Start-YtDlp([string]$arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo "$Bin\yt-dlp.exe", "--encoding utf-8 --ffmpeg-location `"$Bin`" $arguments" -Property @{
        UseShellExecute = $false; CreateNoWindow = $true; RedirectStandardOutput = $true; RedirectStandardError = $true
        StandardOutputEncoding = [Text.Encoding]::UTF8; StandardErrorEncoding = [Text.Encoding]::UTF8 }
    $p = [Diagnostics.Process]::Start($psi)
    @{ P = $p; Err = $p.StandardError.ReadToEndAsync() }
}

# The reason yt-dlp gave for failing, in short (e.g. "Video unavailable")
function Get-YtError($task) {
    if (-not $task -or -not $task.IsCompleted) { return }
    $last = @($task.Result -split "`r?`n" | Where-Object { $_ -match '^ERROR:' })[-1]
    if (-not $last) { return }
    $msg = ($last -replace '^ERROR:\s*(\[[^\]]+\]\s*)?([\w-]{6,}:\s*)?' -replace '\s+(Use --|See\s+http|Also see|Please report).*$').Trim()
    if ($msg -match 'not a bot') { $msg = 'YouTube asked to confirm you are not a bot. Wait a few minutes and try again.' }
    $msg
}

function Test-Tools { -not ('yt-dlp', 'ffmpeg', 'ffprobe' | Where-Object { -not (Test-Path "$Bin\$_.exe") }) }
function Format-Len($sec) { if (-not $sec) { return '?' }; $t = [TimeSpan]::FromSeconds([double]$sec); if ($t.Hours) { $t.ToString('h\:mm\:ss') } else { $t.ToString('m\:ss') } }
function Notify($title, $text) { $text = "$text"; if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }; $Tray.ShowBalloonTip(3000, $title, $text, 'Info') }
function Test-Time($t) { -not $t -or $t -match '^\d+(:\d{1,2}){0,2}(\.\d+)?$' }
function Open-Dir($dir) { New-Item $dir -ItemType Directory -Force | Out-Null; Start-Process explorer "`"$dir`"" }
function Add-Ctl($parent, $type, $props) {
    $name = if ($type -like 'Mg*') { $type } else { "Windows.Forms.$type" }
    $c = New-Object $name -Property $props; $parent.Controls.Add($c); $c
}
# Everything below takes positions in real pixels; sizes come from Px (scaled) or measured text
function TextW($text, $font) { [Windows.Forms.TextRenderer]::MeasureText("$text", $font).Width }
function Add-Label($parent, $text, $x, $y, $props = @{}) {
    $p = @{ Text = $text; Location = New-Object Drawing.Point($x, $y); AutoSize = $true; ForeColor = $T.Sub; UseMnemonic = $false }
    foreach ($k in $props.Keys) { $p[$k] = $props[$k] }
    Add-Ctl $parent Label $p
}
# A label centred on a row of boxes that starts at $y
function Add-RowLabel($parent, $text, $x, $y, $props = @{}) {
    $l = Add-Label $parent $text $x $y $props
    $l.Top = $y + [int](($CtlH - $l.Font.Height) / 2); $l
}
function Add-Field($parent, $x, $y, $w) {
    $f = Add-Ctl $parent MgField @{ Location = New-Object Drawing.Point($x, $y); Size = New-Object Drawing.Size($w, $CtlH); Border = $T.Border; FocusColor = $T.Focus; Fill = $T.Field }
    $f.Box.ForeColor = $T.Text; $f.Box.Font = $Fonts.Base
    $f.Box
}
function ButtonW($text, $min = 90) { [math]::Max((Px $min), (TextW $text $Fonts.Button) + (Px 36)) }
function Add-Button($parent, $text, $x, $y, $w = 0, $style = 'neutral') {
    if (-not $w) { $w = ButtonW $text }
    $fill, $hover, $fg = if ($style -eq 'primary') { $T.Primary, $T.PrimaryHover, $T.PrimaryText } else { $T.Btn, $T.BtnHover, $T.Text }
    Add-Ctl $parent MgButton @{ Text = $text; Location = New-Object Drawing.Point($x, $y); Size = New-Object Drawing.Size($w, $CtlH)
        Fill = $fill; Hover = $hover; ForeColor = $fg; Font = $Fonts.Button }
}
# Width a row of options needs so every word fits
function SegW($items) { $items.Count * (($items | ForEach-Object { TextW $_ $Fonts.Base } | Measure-Object -Maximum).Maximum + (Px 22)) + (Px 6) }
function Add-Segments($parent, $items, $x, $y, $w) {
    $s = Add-Ctl $parent MgSegments @{ Location = New-Object Drawing.Point($x, $y); Size = New-Object Drawing.Size([math]::Max($w, (SegW $items)), $CtlH)
        Track = $T.Track; Pill = $T.Pill; PillText = $T.Text; Sub = $T.Sub; ForeColor = $T.Text; Font = $Fonts.Base }
    $s.Items = [string[]]$items
    $s
}
function New-Window($title, $w, $h, [switch]$Sizable) {
    $f = New-Object Windows.Forms.Form -Property @{ Text = $title; MaximizeBox = $false; MinimizeBox = $false
        StartPosition = 'CenterScreen'; BackColor = $T.Bg; ForeColor = $T.Text; Font = $Fonts.Base }
    $f.FormBorderStyle = if ($Sizable) { 'Sizable' } else { 'FixedSingle' }
    $f.ClientSize = New-Object Drawing.Size($w, $h)
    if ($Dark) { $f.Add_HandleCreated({ [MgUi]::DarkTitle($this.Handle) }) }
    $f.Add_Shown({ if (-not [Hotkey]::IsWindowVisible($this.Handle)) { Log "$($this.Text): forced visible"; [void][Hotkey]::ShowWindow($this.Handle, 5) } })
    $f
}
# The part of a window above its buttons. It gets a scroll bar when the screen is too small,
# while the buttons stay in place below it.
function New-Page($form, $w) {
    $p = New-Object Windows.Forms.Panel -Property @{ Location = New-Object Drawing.Point(0, 0); Size = New-Object Drawing.Size($w, 100); BackColor = $T.Bg }
    $form.Controls.Add($p); $p
}
function Fit-Page($form, $page, $contentH, $barH) {
    $chrome = $form.Height - $form.ClientSize.Height   # title bar and borders
    $max = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - (Px 40) - $chrome - $barH
    $w = $page.Width
    if ($contentH -gt $max) {
        $page.AutoScroll = $true
        $w += [Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        $page.Size = New-Object Drawing.Size($w, $max)
    } else { $page.Size = New-Object Drawing.Size($w, $contentH) }
    $form.ClientSize = New-Object Drawing.Size($w, ($page.Height + $barH))
    [void](Add-Ctl $form Panel @{ Location = New-Object Drawing.Point(0, $page.Height); Size = New-Object Drawing.Size($w, 1); BackColor = $T.Line })
}
# A message on top of everything (MediaGrab has no main window to show it over)
function Show-Message($text, $owner) {
    Log "Message: $text"
    if ($env:MEDIAGRAB_SELFTEST) { [void]$ErrorLog.Add("Unexpected message: $text"); return }   # nobody there to click OK
    if ($owner) { [void][Windows.Forms.MessageBox]::Show($owner, $text, 'MediaGrab') }
    else { [void][Windows.Forms.MessageBox]::Show($text, 'MediaGrab', 'OK', 'Information', 'Button1', 'DefaultDesktopOnly') }
}

# Registers the global keyboard shortcut, e.g. 'Ctrl+Alt+Y'. Returns $false if it is invalid or taken.
function Set-Hotkey($text) {
    $keys = "$text" -split '\s*\+\s*'
    if ($keys.Count -lt 2) { return $false }
    $mods = 0
    foreach ($k in $keys[0..($keys.Count - 2)]) { $m = @{ Alt = 1; Ctrl = 2; Shift = 4; Win = 8 }[$k]; if (-not $m) { return $false }; $mods = $mods -bor $m }
    if (-not ($mods -band 11)) { return $false }   # needs Ctrl, Alt or Win
    $key = if ($keys[-1] -match '^\d$') { "D$($keys[-1])" } else { $keys[-1] }
    try { $vk = [int][Windows.Forms.Keys]$key } catch { $Error.RemoveAt(0); return $false }
    $ok = $hk.Register($mods, $vk)
    if ($ok) {
        $Tray.Text = "MediaGrab ($text)"
        $List.EmptyText = "No downloads yet.`nPress $text on a YouTube video or Spotify song to start."
        $List.Invalidate()
    }
    $ok
}

# ========== Setup: download yt-dlp + ffmpeg the first time, then only check yt-dlp for updates ==========
# Runs on a background thread inside MediaGrab (no second PowerShell process, which does not work
# when MediaGrab runs without a console window). Every step has a time limit, so it can never hang.
$SetupScript = {
    param($bin)
    $ErrorActionPreference = 'Stop'
    try {
        [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
        New-Item $bin -ItemType Directory -Force | Out-Null
        # Saves under a temporary name first, so a cut-off download never looks finished; gives up if the connection stalls
        function Get-File($url, $dest) {
            $req = [Net.HttpWebRequest]::Create($url); $req.Timeout = 30000; $req.ReadWriteTimeout = 60000; $req.UserAgent = 'MediaGrab'
            $res = $req.GetResponse()
            try {
                $in = $res.GetResponseStream(); $out = [IO.File]::Create("$dest.part")
                try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
            } finally { $res.Dispose() }
            Move-Item "$dest.part" $dest -Force
        }
        # Runs a program without a window, waiting at most $seconds; returns its exit code (-1 if it cannot run or takes too long)
        function Invoke-Hidden($exe, $arg, $seconds) {
            try {
                $psi = New-Object Diagnostics.ProcessStartInfo $exe, $arg -Property @{ UseShellExecute = $false; CreateNoWindow = $true; RedirectStandardOutput = $true; RedirectStandardError = $true }
                $p = [Diagnostics.Process]::Start($psi)
                [void]$p.StandardOutput.ReadToEndAsync(); [void]$p.StandardError.ReadToEndAsync()
                if ($p.WaitForExit($seconds * 1000)) { $p.ExitCode } else { try { $p.Kill() } catch { }; -1 }
            } catch { -1 }
        }

        $yt = "$bin\yt-dlp.exe"
        # Update check; if that fails, see whether yt-dlp runs at all (the update check also fails when offline)
        if ((Test-Path $yt) -and (Invoke-Hidden $yt '-U' 90) -ne 0 -and (Invoke-Hidden $yt '--version' 30) -ne 0) { Remove-Item $yt -Force }   # damaged: get a fresh copy
        if (-not (Test-Path $yt)) { Get-File 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' $yt }

        $ok = $true
        foreach ($n in 'ffmpeg', 'ffprobe') { if (-not (Test-Path "$bin\$n.exe") -or (Invoke-Hidden "$bin\$n.exe" '-version' 30) -ne 0) { $ok = $false } }
        if (-not $ok) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            Get-File 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' "$bin\ffmpeg.zip"
            $zip = [IO.Compression.ZipFile]::OpenRead("$bin\ffmpeg.zip")
            try {
                foreach ($n in 'ffmpeg.exe', 'ffprobe.exe') {
                    $entry = $zip.Entries | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                    if (-not $entry) { throw "$n is missing from the ffmpeg download" }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, "$bin\$n.part", $true)
                    Move-Item "$bin\$n.part" "$bin\$n" -Force
                }
            } finally { $zip.Dispose(); Remove-Item "$bin\ffmpeg.zip" -Force -ErrorAction SilentlyContinue }
        }
        'ready'
    } catch { "failed: $($_.Exception.Message)" }
}
function Start-Setup {
    $S.FirstRun = -not (Test-Tools); $S.SetupError = $null; $S.SetupStart = Get-Date
    Log "Setup started ($(if ($S.FirstRun) { 'downloading yt-dlp and ffmpeg' } else { 'checking yt-dlp for updates' }))"
    $ps = [PowerShell]::Create().AddScript($SetupScript.ToString()).AddArgument($Bin)
    $S.Setup = @{ PS = $ps; Result = $ps.BeginInvoke() }
}
Start-Setup

# ===================== Downloads window (progress + history) =====================
$M = Px 20; $G = Px 10
$WA = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$DW = [math]::Min((Px 780), $WA.Width - (Px 40)); $DH = [math]::Min((Px 500), $WA.Height - (Px 80))
$D = New-Window 'MediaGrab - Downloads' $DW $DH -Sizable
$D.MinimumSize = New-Object Drawing.Size([math]::Min((Px 600), $DW), [math]::Min((Px 360), $DH)); $D.MaximizeBox = $true; $D.MinimizeBox = $true
$head = Add-Label $D 'Downloads' $M $M @{ Font = $Fonts.Title; ForeColor = $T.Text }
$listTop = $M + $head.PreferredHeight + $G
$btnY = $D.ClientSize.Height - $M - $CtlH
$List = Add-Ctl $D MgList @{ Location = New-Object Drawing.Point($M, $listTop); Size = New-Object Drawing.Size(($D.ClientSize.Width - 2 * $M), ($btnY - $G - $listTop))
    Anchor = 'Top,Bottom,Left,Right'; BackColor = $T.Card; ForeColor = $T.Text; RowHeight = $Fonts.Base.Height * 2 + (Px 12)
    Head = $T.Card; Line = $T.Line; Sub = $T.Sub; Accent = $T.Focus; Track = $T.Track; Sel = $T.Sel; Good = $T.Good; Bad = $T.Bad; ShowItemToolTips = $true }
$dateW = (TextW '2026-12-31 23:59' $Fonts.Base) + (Px 36)
$List.StatusWidth = Px 290
foreach ($col in ('Name', 300), ('Status', (Px 290)), ('Date', $dateW)) { [void]$List.Columns.Add($col[0], $col[1]) }
$List.FitColumns()
if ($Dark) { $List.Add_HandleCreated({ [MgUi]::DarkScroll($this.Handle) }) }
$ShowBtn  = Add-Button $D 'Show in folder' $M $btnY
$ClearBtn = Add-Button $D 'Clear finished' ($ShowBtn.Right + $G) $btnY
$openW    = ButtonW 'Open download folder'
$OpenBtn  = Add-Button $D 'Open download folder' ($D.ClientSize.Width - $M - $openW) $btnY $openW
$ShowBtn.Anchor = $ClearBtn.Anchor = 'Bottom,Left'; $OpenBtn.Anchor = 'Bottom,Right'
$D.Add_FormClosing({ if ($_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $D.Hide() } })

function Show-Downloads {
    $D.Show(); $D.WindowState = 'Normal'
    if (-not [Hotkey]::IsWindowVisible($D.Handle)) { [void][Hotkey]::ShowWindow($D.Handle, 5) }
    $D.Activate()
}
function Add-Entry($e) {
    $e.Item = New-Object Windows.Forms.ListViewItem($e.Name)
    [void]$e.Item.SubItems.Add($e.Status); [void]$e.Item.SubItems.Add($e.Date)
    $e.Item.Tag = $e; [void]$List.Items.Insert(0, $e.Item); $List.Invalidate()
}
# $pct (e.g. '42.5') shows a progress bar under the status
function Set-Status($e, $text, $pct = $null) {
    $e.Status = $text; $e.Item.SubItems[1].Tag = $pct; $e.Item.SubItems[1].Text = $text
    $List.Invalidate($e.Item.Bounds)
}
function Get-Entries { $List.Items | ForEach-Object Tag }
function Save-History {
    $h = @(Get-Entries | Where-Object { $_.Status -eq 'Done' } | Select-Object -First 500 | ForEach-Object { [ordered]@{ Name = $_.Name; Path = $_.Path; Dir = $_.Dir; Key = $_.Key; Date = $_.Date } })
    ConvertTo-Json -InputObject $h | Set-Content $HistFile -Encoding UTF8
}
function Show-InFolder($e) {
    if ($e.Error) { Show-Message "$($e.Name)`n`n$($e.Error)" $D; return }
    if ($e.Path -and (Test-Path -LiteralPath $e.Path)) { Start-Process explorer "/select,`"$($e.Path)`"" } else { Open-Dir $e.Dir }
}
$ShowBtn.Add_Click({ if ($List.SelectedItems.Count) { Show-InFolder $List.SelectedItems[0].Tag } })
$OpenBtn.Add_Click({ Open-Dir $C.SaveDir })
$List.Add_DoubleClick({ if ($List.SelectedItems.Count) { Show-InFolder $List.SelectedItems[0].Tag } })
$ClearBtn.Add_Click({
    foreach ($it in @($List.Items)) { if ($it.Tag.Status -eq 'Done' -or $it.Tag.Status -like 'Failed*') { $List.Items.Remove($it) } }
    $List.Invalidate(); Save-History
})
if (Test-Path $HistFile) {   # a damaged history file is ignored
    try {
        $old = @((Get-Content $HistFile -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ }); [array]::Reverse($old)
        foreach ($h in $old) { if ($h) { Add-Entry @{ Name = $h.Name; Path = $h.Path; Dir = $h.Dir; Key = $h.Key; Date = $h.Date; Status = 'Done' } } }
    } catch { Log "History file could not be read: $_" }
}

# ========================= Download window ========================
$M = Px 24; $G = Px 12; $RowGap = Px 10
$rowNames = 'FILE TYPE', 'VIDEO', 'TRIM', 'SAVE TO', 'FILE NAME'
$LW  = ($rowNames | ForEach-Object { TextW $_ $Fonts.Small } | Measure-Object -Maximum).Maximum + (Px 20)   # label column
$CW  = [math]::Max((Px 500), [math]::Max((SegW $Choices.Format), (SegW $Choices.VideoQuality)))           # box column
$X0  = $M + $LW; $FW = $X0 + $CW + $M                                                                       # window width
$F = New-Window 'MediaGrab' $FW (Px 500)
$F.TopMost = $true
$FP = New-Page $F $FW
$thumbW = Px 208; $thumbH = Px 117; $HX = $M + $thumbW + (Px 16); $HW = $FW - $M - $HX
$U = @{ Pic = Add-Ctl $FP MgThumb @{ Location = New-Object Drawing.Point($M, $M); Size = New-Object Drawing.Size($thumbW, $thumbH); Empty = $T.Track } }
$U.Title = Add-Ctl $FP Label @{ Location = New-Object Drawing.Point($HX, ($M - (Px 3))); Size = New-Object Drawing.Size($HW, ($Fonts.Title.Height * 2 + (Px 4)))
    AutoEllipsis = $true; Font = $Fonts.Title; ForeColor = $T.Text; UseMnemonic = $false }
$U.Info  = Add-Ctl $FP Label @{ Location = New-Object Drawing.Point($HX, ($U.Title.Bottom + (Px 2))); Size = New-Object Drawing.Size($HW, ($Fonts.Base.Height + (Px 4)))
    AutoEllipsis = $true; ForeColor = $T.Sub; UseMnemonic = $false }
$y = $U.Info.Bottom + (Px 4)
$U.Match = Add-Ctl $FP ComboBox @{ Location = New-Object Drawing.Point($HX, $y); Width = $HW; DropDownStyle = 'DropDownList'; Font = $Fonts.Base }
if ($Dark) { $U.Match.BackColor = $T.Field; $U.Match.ForeColor = $T.Text; $U.Match.Add_HandleCreated({ [MgUi]::DarkCombo($this.Handle) }) }
$U.Url   = Add-Ctl $FP Label @{ Location = New-Object Drawing.Point($HX, $y); Size = New-Object Drawing.Size($HW, ($Fonts.Url.Height + (Px 4)))
    AutoEllipsis = $true; ForeColor = $T.Faint; Font = $Fonts.Url; UseMnemonic = $false }
$InfoH = $U.Info.Height; $UrlTop = $U.Url.Top
$y = [math]::Max(($M + $thumbH), $U.Match.Bottom) + (Px 16)
[void](Add-Ctl $FP Panel @{ Location = New-Object Drawing.Point($M, $y); Size = New-Object Drawing.Size(($FW - 2 * $M), 1); BackColor = $T.Line })
$y += Px 16
$rowY = @{}
foreach ($n in $rowNames) { $rowY[$n] = $y; [void](Add-RowLabel $FP $n $M $y @{ Font = $Fonts.Small }); $y += $CtlH + $RowGap }
$U.Type  = Add-Segments $FP $Choices.Format $X0 $rowY['FILE TYPE'] $CW
$U.VQ    = Add-Segments $FP $Choices.VideoQuality $X0 $rowY['VIDEO'] $CW
$toW     = TextW 'to' $Fonts.Base
$trimW   = [int](($CW - $toW - 2 * $G) / 2)
$U.Start = Add-Field $FP $X0 $rowY['TRIM'] $trimW
[void](Add-RowLabel $FP 'to' ($X0 + $trimW + $G) $rowY['TRIM'])
$U.End   = Add-Field $FP ($X0 + $CW - $trimW) $rowY['TRIM'] $trimW
$browseW = ButtonW 'Browse'
$U.Dir   = Add-Field $FP $X0 $rowY['SAVE TO'] ($CW - $browseW - $G)
$Browse  = Add-Button $FP 'Browse' ($X0 + $CW - $browseW) $rowY['SAVE TO'] $browseW
$extW    = (TextW '.flac' $Fonts.Base) + (Px 8)
$U.Name  = Add-Field $FP $X0 $rowY['FILE NAME'] ($CW - $extW - $G)
$U.Ext   = Add-RowLabel $FP '.mp3' ($X0 + $CW - $extW) $rowY['FILE NAME']
$barH = (Px 14) + $CtlH + $M
Fit-Page $F $FP ($y - $RowGap + (Px 10)) $barH
$by = $FP.Bottom + (Px 14)
$goW = ButtonW 'Download' 110; $closeW = ButtonW 'Close'
$U.Go    = Add-Button $F 'Download' ($F.ClientSize.Width - $M - $goW) $by $goW
$U.Close = Add-Button $F 'Close' ($U.Go.Left - $G - $closeW) $by $closeW
$U.Go.ForeColor = 'White'; $U.Close.DialogResult = 'Cancel'
$U.Type.Add_Changed({ $U.Ext.Text = ".$($U.Type.Value)"; $U.VQ.Enabled = $U.Type.Value -eq 'mp4' })
$F.AcceptButton = $U.Go
$F.CancelButton = $U.Close

function Set-Hints {
    [Hotkey]::Hint($U.Start, $(if ($C.StartTime) { $C.StartTime } else { 'start (e.g. 1:30)' }))
    [Hotkey]::Hint($U.End,   $(if ($C.EndTime) { $C.EndTime } elseif ($S.Len) { "end ($($S.Len))" } else { 'end' }))
    [Hotkey]::Hint($U.Dir,   $C.SaveDir)
    [Hotkey]::Hint($U.Name,  $(if ($C.FileName) { $C.FileName } elseif ($S.Name) { $S.Name } else { 'title' }))
}
$F.Add_VisibleChanged({ if ($F.Visible) { Set-Hints; $F.Activate() } })

function Pick-Folder($box, $owner) {
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ SelectedPath = $(if ($box.Text) { $box.Text } else { $C.SaveDir }) }
    if ($d.ShowDialog($owner) -eq 'OK') { $box.Text = $d.SelectedPath }
}
$Browse.Add_Click({ Pick-Folder $U.Dir $F })

function Use-Match($m) { $S.Target = "https://www.youtube.com/watch?v=$($m.Id)"; $S.Len = Format-Len $m.Dur; Set-Hints }
$U.Match.Add_SelectedIndexChanged({ if ($U.Match.SelectedIndex -ge 0) { Use-Match $S.Found[$U.Match.SelectedIndex] } })

# Sets a tag inside the file (used for Spotify title / artist / album)
function Meta-Arg($field, $value) {
    # the trailing # stops yt-dlp from reading a one-word value as a field name
    if ($value) { " --parse-metadata `"$($value -replace '[\\"]' -replace '%', '%%' -replace ':', '\:')#:(?P<meta_$field>.+)#`"" }
}

# Starts the download with the choices in the Download window
function Start-Download {
    $from, $to, $dir, $name = ($U.Start, $U.End, $U.Dir, $U.Name).Text.Trim()
    if (-not $from) { $from = $C.StartTime }; if (-not $to) { $to = $C.EndTime }
    if (-not $dir)  { $dir = $C.SaveDir };    if (-not $name) { $name = if ($C.FileName) { $C.FileName } else { $S.Name } }
    foreach ($t in $from, $to) { if (-not (Test-Time $t)) { Show-Message "'$t' is not a valid time. Use 90 or 1:30." $F; return } }

    $key = if ($S.Kind -eq 'spotify') { $S.Url -replace '\?.*' } else { $S.Target -replace '&.*' }
    $dup = Get-Entries | Where-Object { $_.Key -eq $key -and $_.Status -eq 'Done' } | Select-Object -First 1
    if ($dup -and -not $env:MEDIAGRAB_SELFTEST -and [Windows.Forms.MessageBox]::Show($F, "You already downloaded this on $($dup.Date):`n$($dup.Name)`n`nDownload it again?", 'MediaGrab', 'YesNo') -ne 'Yes') { return }

    $fmt   = $U.Type.Value
    $sort  = if ($U.VQ.Value -eq 'Best') { 'ext:mp4:m4a' } else { "res:$($U.VQ.Value -replace 'p'),ext:mp4:m4a" }
    $type  = if ($fmt -eq 'mp4') { "-S `"$sort`" --merge-output-format mp4" } else { "-x --audio-format $fmt --audio-quality $($C.AudioQuality)" }
    $cut   = if ($from -or $to) { "--download-sections `"*$(if ($from) { $from } else { 0 })-$(if ($to) { $to } else { 'inf' })`"" }
    $info  = if ($C.EmbedInfo -eq 'Yes' -and $fmt -ne 'wav') {
        '--embed-metadata --embed-thumbnail' + $(if ($S.Kind -eq 'spotify') { (Meta-Arg title $S.SpTitle) + (Meta-Arg artist $S.SpArtist) + (Meta-Arg album $S.SpAlbum) })
    }
    $clean = if ($name) { $name -replace '[\\/:*?"<>|]', '_' -replace "\.$fmt$" }
    $out   = if ($clean) { $clean -replace '%', '%%' } else { '%(title)s' }
    $dir   = $dir.TrimEnd('\')
    try { New-Item $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    catch { Show-Message "Cannot use the folder '$dir'.`n$($_.Exception.Message)" $F; return }

    try { $run = Start-YtDlp "$type $info $cut --no-playlist --newline --progress-template `"download:P|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s`" -o `"$dir\$out.%(ext)s`" `"$($S.Target)`"" }
    catch { Show-Message "yt-dlp could not start: $($_.Exception.Message)" $F; return }
    $e = @{ Name = $(if ($clean) { "$clean.$fmt" } else { $S.Name }); Path = $(if ($clean) { "$dir\$clean.$fmt" }); Dir = $dir; Key = $key
            Date = Get-Date -Format 'yyyy-MM-dd HH:mm'; Status = 'Starting...'; P = $run.P; Err = $run.Err }
    $e.Line = $e.P.StandardOutput.ReadLineAsync()
    Add-Entry $e; [void]$S.Active.Add($e)
    Log "Download started: $($e.Name) ($($S.Target))"
    $S.Started = $true
    $F.DialogResult = 'OK'   # ends the dialog without destroying the window
}
$U.Go.Add_Click({ Start-Download })

# ---- Filling in the download window: setup -> link -> details (all without freezing the window) ----
$Fields = '--print "%(id)s|%(duration)s|%(title)s"'
function Get-Meta($html, $name) { [Net.WebUtility]::HtmlDecode([regex]::Match($html, "$name`" content=`"([^`"]*)").Groups[1].Value) }

# Shows what went wrong in the open window
function Show-Problem($title, $text, $hint = '', [switch]$Calm) {
    $Load.Stop(); $Poll.Stop()
    Log "Download window: $title - $text $hint"
    $U.Title.Text = $title; $U.Info.Text = $text; $U.Info.ForeColor = $(if ($Calm) { $T.Sub } else { $T.Bad })
    $U.Info.Height = $Fonts.Base.Height * 2 + (Px 4); $U.Url.Top = $U.Info.Bottom + (Px 2)   # room for two lines
    $U.Url.Text = $hint; $U.Url.Visible = $true; $U.Match.Visible = $false; $U.Go.Enabled = $false
}

# Reads the address bar of the browser window that was in front, on a background thread
$UrlScript = {
    param($hwnd, $browsers)
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $uia = [Windows.Automation.AutomationElement]
    $win = $uia::FromHandle($hwnd)
    if ((Get-Process -Id $win.Current.ProcessId).Name -notin ($browsers -split '\s*,\s*')) { return }
    $edit = $win.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition($uia::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)))
    $url = $edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($url -and $url -notmatch '^\w+://') { $url = "https://$url" }
    $url
}
function Start-UrlRead {
    $ps = [PowerShell]::Create().AddScript($UrlScript.ToString()).AddArgument($S.Fg).AddArgument($C.Browsers)
    $S.UrlRead = @{ PS = $ps; Result = $ps.BeginInvoke(); Started = Get-Date }
}
function Stop-UrlRead {
    if (-not $S.UrlRead) { return }
    try { if ($S.UrlRead.Result.IsCompleted) { $S.UrlRead.PS.Dispose() } else { [void]$S.UrlRead.PS.BeginStop($null, $null) } } catch { }
    $S.UrlRead = $null
}
# The address once it has been read: $null while still reading, '' if there is none
function Get-UrlRead {
    $r = $S.UrlRead
    if (-not $r.Result.IsCompleted -and ((Get-Date) - $r.Started).TotalSeconds -lt 6) { return $null }
    $url = ''
    if ($r.Result.IsCompleted) { try { $url = "$(@($r.PS.EndInvoke($r.Result))[-1])" } catch { Log "Reading the browser address failed: $_"; $Error.RemoveAt(0) } }
    else { Log 'Reading the browser address took too long' }
    Stop-UrlRead
    $url
}

# Asks yt-dlp for the id, length and title (in the background)
function Start-Lookup($query) {
    try { $run = Start-YtDlp $query }
    catch { Show-Problem 'yt-dlp could not start' $_.Exception.Message; return }
    $S.Meta = $run.P.StandardOutput.ReadToEndAsync(); $S.MetaErr = $run.Err
    $Poll.Start()
}
# Reads title, artist, album, length and cover from a Spotify song page
function Read-SpotifyPage($html) {
    if (-not $html) { return }
    $page = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '<title>(.*?)</title>').Groups[1].Value)
    if ($page -match '^(.+) - song(?: and lyrics)? by (.+?) \| Spotify') { $S.SpTitle, $S.SpArtist = $Matches[1], $Matches[2] }
    else { $S.SpTitle = Get-Meta $html 'og:title' }
    $desc = (Get-Meta $html 'og:description') -split " $([char]0xB7) "
    if ($desc.Count -ge 4 -and $desc[0] -notlike 'Listen to*') { if (-not $S.SpArtist) { $S.SpArtist = $desc[0] }; $S.SpAlbum = $desc[1] }
    $S.SpDur = [regex]::Match($html, 'music:duration" content="(\d+)').Groups[1].Value -as [double]
    $img = Get-Meta $html 'og:image'
    if ($img) { $U.Pic.LoadUrl($img) }
}
# Starts looking up a link from the browser or the clipboard
function Use-Link($url) {
    if (-not (Get-Kind $url)) { try { $url = "$([Windows.Forms.Clipboard]::GetText())".Trim() } catch { $Error.RemoveAt(0) } }   # no matching tab: try a copied link
    $kind = Get-Kind $url
    Log "Link: $(if ($kind) { "$kind $url" } else { 'none found' })"
    if (-not $kind) { Show-Problem 'No video or song found' "Open a YouTube video or Spotify song in your browser, or copy its link, then press $($C.Hotkey) again." -Calm; return }
    $S.Url = $S.Target = $url; $S.Kind = $kind
    $U.Url.Text = $url; $U.Pic.Crop = $kind -eq 'youtube'
    $U.Go.Fill  = if ($kind -eq 'spotify') { $T.Spotify } else { $T.YouTube }
    $U.Go.Hover = if ($kind -eq 'spotify') { $T.SpotifyHover } else { $T.YouTubeHover }
    if ($kind -eq 'spotify') {
        $U.Info.Text = 'Reading the song from Spotify...'
        $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        $S.Page = $wc.DownloadStringTaskAsync($url)
        $Poll.Start()
    } else {
        $U.Info.Text = 'Looking up the video...'
        $U.Go.Enabled = $true
        Start-Lookup "--no-playlist $Fields `"$url`""
    }
}

# Step 1 and 2, checked several times a second while the window is open:
# wait until yt-dlp and ffmpeg are ready, then read the browser's address
$Load = New-Object Windows.Forms.Timer -Property @{ Interval = 100 }
$Load.Add_Tick({
    if ($S.Stage -eq 'setup') {
        if ($S.Setup) { $U.Info.Text = $(if ($S.FirstRun) { 'Downloading yt-dlp and ffmpeg (one time, about a minute)...' } else { 'Checking yt-dlp for updates...' }); return }
        if (-not (Test-Tools)) {
            if ($S.SetupError) { Show-Problem 'Setup failed' 'Could not download yt-dlp and ffmpeg. Check your internet and try again.' $S.SetupError; $S.SetupError = $null; return }
            Start-Setup; return
        }
        $U.Info.Text = 'Reading the link from your browser...'
        Start-UrlRead; $S.Stage = 'url'; return
    }
    if ($S.Stage -eq 'url') {
        $url = Get-UrlRead
        if ($null -eq $url) { return }
        $Load.Stop(); $S.Stage = 'lookup'
        Use-Link $url
    }
})

# Step 3: fills in details once Spotify / yt-dlp answer (for Spotify: lists YouTube results, picks the one closest in length)
$Poll = New-Object Windows.Forms.Timer -Property @{ Interval = 250 }
$Poll.Add_Tick({
    if ($S.Page) {   # Spotify page, downloaded in the background
        if (-not $S.Page.IsCompleted) { return }
        $task = $S.Page; $S.Page = $null
        Read-SpotifyPage $(if ($task.Status -eq 'RanToCompletion') { $task.Result })
        if (-not $S.SpTitle) { Show-Problem 'Could not read this Spotify song' 'Check your internet connection and try again.'; return }
        $S.Name = $U.Title.Text = $(if ($S.SpArtist) { "$($S.SpArtist) - $($S.SpTitle)" } else { $S.SpTitle })
        $U.Info.Text = 'Finding the song on YouTube...'
        $q = $S.Name -replace '"'
        Start-Lookup "--flat-playlist -i --playlist-items 1:5 $Fields `"https://music.youtube.com/search?q=$([Uri]::EscapeDataString($q))#songs`" `"ytsearch5:$q`""
        return
    }
    if (-not ($S.Meta.IsCompleted -and $S.MetaErr.IsCompleted)) { return }
    $Poll.Stop()
    $seen = @{}
    $S.Found = @($S.Meta.Result -split "`r?`n" | Where-Object { $_ } | ForEach-Object {
        $id, $dur, $title = $_ -split '\|', 3; $dur = $dur -as [double]
        [pscustomobject]@{ Id = $id; Dur = $dur; Title = $title; Diff = $(if ($dur -and $S.SpDur) { [math]::Abs($dur - $S.SpDur) } else { 1e9 }) }
    } | Where-Object { -not $seen[$_.Id] -and ($seen[$_.Id] = 1) })
    if (-not $S.Found) {
        $why = Get-YtError $S.MetaErr
        Show-Problem $(if ($S.Kind -eq 'youtube') { 'Not available' } else { $U.Title.Text }) $(if ($why) { $why } else { 'Could not find this on YouTube.' }) $S.Url
        return
    }
    $best = @($S.Found | Where-Object { $_.Diff -le [double]$C.MatchTolerance })[0]    # first result with matching length
    if (-not $best) { $best = $S.Found | Sort-Object Diff | Select-Object -First 1 }
    if ($S.Kind -eq 'spotify') {
        $U.Info.Text = "Spotify $(Format-Len $S.SpDur)$($Dot)YouTube match:"
        $U.Url.Visible = $false; $U.Match.Visible = $true
        $U.Match.Items.Clear()
        foreach ($m in $S.Found) { [void]$U.Match.Items.Add("$($m.Title)  ($(Format-Len $m.Dur))") }
        $U.Match.SelectedIndex = @(0..($S.Found.Count - 1) | Where-Object { $S.Found[$_].Id -eq $best.Id })[0]
        $U.Go.Enabled = $true
    } else {
        $S.Name = $U.Title.Text = $best.Title
        Use-Match $best
        $U.Info.Text = "YouTube$($Dot)$($S.Len)"
        $U.Pic.LoadUrl("https://i.ytimg.com/vi/$($best.Id)/hqdefault.jpg")
    }
    Log "Found: $($U.Title.Text)"
})

# Opens the download window at once, so it is clear the shortcut worked; the rest fills in while it is open
function Show-Dialog {
    if ($F.Visible) {   # already open: bring it forward (and make sure it really is on screen)
        if (-not [Hotkey]::IsWindowVisible($F.Handle)) { Log 'Download window was open but not on screen'; [void][Hotkey]::ShowWindow($F.Handle, 5) }
        $F.Activate(); return
    }
    $S.Fg = [Hotkey]::GetForegroundWindow()   # the browser, before our window takes its place
    foreach ($k in 'Url', 'Target', 'Kind', 'Name', 'Len', 'SpDur', 'SpTitle', 'SpArtist', 'SpAlbum', 'Started', 'Meta', 'MetaErr', 'Page', 'Found') { $S[$k] = $null }
    foreach ($b in $U.Start, $U.End, $U.Name) { $b.Text = '' }
    $U.Type.Value = $C.Format
    $U.VQ.Value = $C.VideoQuality
    $U.Pic.ClearImage()
    $U.Title.Text = 'Loading...'; $U.Info.Text = 'Reading the link from your browser...'; $U.Info.ForeColor = $T.Sub
    $U.Info.Height = $InfoH; $U.Url.Top = $UrlTop
    $U.Url.Text = ''; $U.Url.Visible = $true; $U.Match.Items.Clear(); $U.Match.Visible = $false
    $U.Go.Fill = $T.Primary; $U.Go.Hover = $T.PrimaryHover; $U.Go.Enabled = $false
    $S.Stage = 'setup'
    $Load.Start()
    [void]$F.ShowDialog()
    $Load.Stop(); $Poll.Stop(); Stop-UrlRead
    if ($S.Started) { Show-Downloads }
}

# ========================= Settings window ========================
function Show-Settings {
    $rows = @(
        @('#', 'General'), @('Hotkey', 'Keyboard shortcut'), @('SaveDir', 'Download folder'), @('FileName', 'Default file name'), @('Browsers', 'Browsers (comma separated)'),
        @('#', 'Audio and video'), @('Format', 'Default file type'), @('VideoQuality', 'Default video quality'), @('AudioQuality', 'Audio quality (0 best, 10 smallest)'), @('EmbedInfo', 'Add song info and cover art'),
        @('#', 'Trim and Spotify'), @('StartTime', 'Default start time'), @('EndTime', 'Default end time'), @('MatchTolerance', 'Spotify match tolerance (seconds)')
    )
    $M = Px 24; $G = Px 12
    $LW = ($rows | Where-Object { $_[0] -ne '#' } | ForEach-Object { TextW $_[1] $Fonts.Base } | Measure-Object -Maximum).Maximum + (Px 24)
    $CW = [math]::Max((Px 320), [math]::Max((SegW $Choices.Format), (SegW $Choices.VideoQuality)))
    $X0 = $M + $LW; $SW = $X0 + $CW + $M
    $W = New-Window 'MediaGrab - Settings' $SW (Px 600)
    $W.TopMost = $true; $W.Icon = $Tray.Icon
    $P = New-Page $W $SW
    $box = @{}; $y = Px 8
    foreach ($r in $rows) {
        if ($r[0] -eq '#') { [void](Add-Label $P $r[1] $M ($y + (Px 12)) @{ Font = $Fonts.Head; ForeColor = $T.Text }); $y += $Fonts.Head.Height + (Px 22); continue }
        $k = $r[0]
        [void](Add-RowLabel $P $r[1] $M $y)
        if ($Choices[$k]) { $box[$k] = Add-Segments $P $Choices[$k] $X0 $y $CW; $box[$k].Value = $C[$k] }
        elseif ($k -eq 'Hotkey') {
            $kf = Add-Ctl $P MgKeyField @{ Location = New-Object Drawing.Point($X0, $y); Size = New-Object Drawing.Size($CW, $CtlH); Border = $T.Border; FocusColor = $T.Focus; Fill = $T.Field }
            $kf.Box.ForeColor = $T.Text; $kf.Box.Font = $Fonts.Base; $kf.Value = $C.Hotkey
            $box[$k] = $kf
        }
        elseif ($k -eq 'SaveDir') {
            $bw = ButtonW 'Browse'
            $box[$k] = Add-Field $P $X0 $y ($CW - $bw - $G); $box[$k].Text = $C[$k]
            $b = Add-Button $P 'Browse' ($X0 + $CW - $bw) $y $bw; $b.Add_Click({ Pick-Folder $box.SaveDir $W })
        }
        else { $box[$k] = Add-Field $P $X0 $y $CW; $box[$k].Text = $C[$k] }
        $y += $CtlH + (Px 8)
    }
    $auto = Add-Ctl $P CheckBox @{ Location = New-Object Drawing.Point($M, ($y + (Px 10))); AutoSize = $true; Text = 'Start MediaGrab when Windows starts'; ForeColor = $T.Text
                                   Enabled = [bool]$ExePath; Checked = [bool](Get-ItemProperty $RunKey -Name MediaGrab -ErrorAction Ignore) }
    $barH = (Px 14) + $CtlH + $M
    Fit-Page $W $P ($auto.Bottom + (Px 16)) $barH
    $by = $P.Bottom + (Px 14); $right = $W.ClientSize.Width - $M
    $cancelW = ButtonW 'Cancel'; $saveW = ButtonW 'Save'
    $cancel = Add-Button $W 'Cancel' ($right - $cancelW) $by $cancelW
    $save = Add-Button $W 'Save' ($cancel.Left - $G - $saveW) $by $saveW 'primary'
    $cancel.DialogResult = 'Cancel'
    $W.CancelButton = $cancel; $W.AcceptButton = $save
    $W.ActiveControl = $save   # don't start inside the shortcut box
    [void](Add-RowLabel $W "MediaGrab $Version" $M $by @{ ForeColor = $T.Faint })

    $save.Add_Click({
        $new = @{}; foreach ($k in $box.Keys) { $new[$k] = if ($box[$k] -is [MgSegments] -or $box[$k] -is [MgKeyField]) { $box[$k].Value } else { $box[$k].Text.Trim() } }
        $err = if ($new.AudioQuality -notmatch '^(10|\d)$') { 'Audio quality must be a number from 0 to 10.' }
               elseif ($new.MatchTolerance -notmatch '^\d+(\.\d+)?$') { 'Match tolerance must be a number.' }
               elseif (-not ((Test-Time $new.StartTime) -and (Test-Time $new.EndTime))) { 'Times must look like 90 or 1:30.' }
               elseif (-not $new.SaveDir) { 'Choose a download folder.' }
               elseif (-not (Set-Hotkey $new.Hotkey)) { $hk.Unregister(); "The shortcut $($new.Hotkey) is already used by Windows or another program. Click the shortcut box and press a different one." }
        if ($err) { Show-Message $err $W; return }
        foreach ($k in $new.Keys) { $C[$k] = $new[$k] }
        Save-Config
        if ($auto.Checked) { Set-ItemProperty $RunKey MediaGrab "`"$ExePath`"" } else { Remove-ItemProperty $RunKey MediaGrab -ErrorAction Ignore }
        Log "Settings saved (shortcut $($C.Hotkey))"
        $W.Close()
    })
    $hk.Unregister()   # the shortcut is paused while Settings is open, so it can be pressed in the shortcut box
    $script:SettingsUi = @{ W = $W; Key = $kf; Save = $save }
    [void]$W.ShowDialog()
    $script:SettingsUi = $null
    $W.Dispose()
    $ok = Set-Hotkey $C.Hotkey   # turn the (new) shortcut on again
    Log "Settings closed; shortcut $($C.Hotkey) $(if ($ok) { 'active' } else { 'could not be turned on' })"
}

# ===================== Tray icon and background work =====================
$bmp = New-Object Drawing.Bitmap 32, 32; $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
$g.FillEllipse((New-Object Drawing.SolidBrush $T.YouTube), 1, 1, 30, 30)
$g.FillPolygon([Drawing.Brushes]::White, [Drawing.Point[]]@('13,6', '19,6', '19,14', '24,14', '16,22', '8,14', '13,14'))
$g.FillRectangle([Drawing.Brushes]::White, 9, 24, 14, 3)
$Tray = New-Object Windows.Forms.NotifyIcon -Property @{ Visible = $true; Text = 'MediaGrab'; ContextMenuStrip = New-Object Windows.Forms.ContextMenuStrip; Icon = [Drawing.Icon]::FromHandle($bmp.GetHicon()) }
$Tray.ContextMenuStrip.Font = $Fonts.Base
$D.Icon = $Tray.Icon; $F.Icon = $Tray.Icon
function Quit-App { Log 'Closing'; $Tray.Visible = $false; [Windows.Forms.Application]::Exit() }
foreach ($m in ('Download copied link', { Show-Dialog }), ('Downloads', { Show-Downloads }), ('Settings', { Show-Settings }), ('Open download folder', { Open-Dir $C.SaveDir }), ('Exit', { Quit-App })) {
    [void]$Tray.ContextMenuStrip.Items.Add($m[0], $null, $m[1])
}
$Tray.Add_BalloonTipClicked({ Show-Downloads })
$Tray.Add_MouseDoubleClick({ Show-Downloads })

# Every half second: close if a newer copy started, finish setup, update running downloads
$Tick = New-Object Windows.Forms.Timer -Property @{ Interval = 500 }
$Tick.Add_Tick({
    if ($QuitEvent.WaitOne(0)) { Log 'A newer copy of MediaGrab started'; Quit-App; return }
    Flush-Errors
    if ($S.Setup -and $S.Setup.Result.IsCompleted) {
        $out = ''
        try { $out = "$(@($S.Setup.PS.EndInvoke($S.Setup.Result))[-1])" } catch { $out = "failed: $($_.Exception.Message)"; $Error.RemoveAt(0) }
        try { $S.Setup.PS.Dispose() } catch { }
        $why = if ($out -like 'failed:*') { $out.Substring(8) } elseif ($out -ne 'ready') { 'no answer' }
        $ok = Test-Tools
        Log "Setup finished after $([int]((Get-Date) - $S.SetupStart).TotalSeconds) s: $(if ($ok) { 'ready' } else { "failed ($why)" })"
        if (-not $ok) {
            $S.SetupError = $(if ($why) { $why } else { 'unknown error' })
            if (-not $F.Visible) { Notify 'Setup failed' "Could not download yt-dlp / ffmpeg ($($S.SetupError)). MediaGrab tries again when you press $($C.Hotkey)." }
        }
        elseif ($S.FirstRun -and -not $F.Visible) { Notify 'MediaGrab is ready' "Press $($C.Hotkey) on a YouTube or Spotify tab." }
        $S.Setup = $null
    }
    foreach ($e in @($S.Active)) {
        while ($e.Line.IsCompleted) {
            $line = $e.Line.Result
            if ($null -eq $line) { break }
            $line = $line -replace '\x1b\[[0-9;]*m'
            if ($line -like 'P|*') {
                $null, $pct, $speed, $eta = $line.Split('|').Trim()
                $n = $pct -replace '[^\d.]'
                if (-not $n) { Set-Status $e 'Downloading...' }
                elseif (($n -as [double]) -ge 100) { Set-Status $e 'Processing...' }
                else { Set-Status $e "$pct$($Dot)$speed$($Dot)$eta left" $n }
            }
            elseif ($line -match '^\[(ExtractAudio|Merger|VideoConvertor)\]') { Set-Status $e 'Converting...' }
            elseif ($line -match '^\[(Metadata|EmbedThumbnail)\]') { Set-Status $e 'Adding info...' }
            $e.Line = $e.P.StandardOutput.ReadLineAsync()
        }
        if ($e.Line.IsCompleted -and $e.Err.IsCompleted -and $e.P.HasExited) {
            $S.Active.Remove($e)
            if ($e.P.ExitCode -eq 0) { Set-Status $e 'Done'; Save-History; Notify 'Download ready' $e.Name; Log "Download finished: $($e.Name)" }
            else {
                $e.Error = Get-YtError $e.Err
                if (-not $e.Error) { $e.Error = "yt-dlp stopped with error code $($e.P.ExitCode)." }
                Set-Status $e "Failed: $($e.Error)"
                Notify 'Download failed' "$($e.Name)`n$($e.Error)"
                Log "Download failed: $($e.Name): $($e.Error)"
            }
        }
    }
})
$Tick.Start()

# ============================ Shortcut ============================
$hk = New-Object Hotkey
$hk.add_Pressed({ Log 'Shortcut pressed'; Show-Dialog })
$HotkeyOk = Set-Hotkey $C.Hotkey
Log "Shortcut $($C.Hotkey): $(if ($HotkeyOk) { 'active' } else { 'could not be turned on (used by another program?)' })"
if ($S.FirstRun) { Notify 'Setting up MediaGrab' 'Downloading yt-dlp and ffmpeg (one time, about a minute)...' }
elseif ($HotkeyOk) { Notify 'MediaGrab is running' "Press $($C.Hotkey) on a YouTube or Spotify tab." }

# ===================== Self-test (used only by the automatic build check on GitHub) =====================
if ($env:MEDIAGRAB_SELFTEST) {
    $Out = $env:MEDIAGRAB_SELFTEST
    $Log = [Collections.ArrayList]@(); $Fails = 0
    function Check($ok, $what) { $line = "$(if ($ok) { 'PASS' } else { 'FAIL' })  $what"; [void]$Log.Add($line); Log "TEST $line"; if (-not $ok) { $script:Fails++ } }
    function Note($ok, $what) { $line = "$(if ($ok) { 'PASS' } else { 'WARN' })  $what"; [void]$Log.Add($line); Log "TEST $line" }   # depends on YouTube / Spotify, so only a warning
    Log "TEST self-test started (launched by $(if ($ExePath) { 'MediaGrab.exe' } else { 'PowerShell' }))"
    function Wait-Until([scriptblock]$done, $seconds) {
        $end = (Get-Date).AddSeconds($seconds)
        while (-not (& $done) -and (Get-Date) -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        [bool](& $done)
    }
    function Save-Shot($form, $name) {
        if (-not $form.Visible) { $form.Show() }
        $form.Activate()
        foreach ($i in 1..10) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
        $shot = New-Object Drawing.Bitmap $form.Width, $form.Height
        $gr = [Drawing.Graphics]::FromImage($shot); $gr.CopyFromScreen($form.Location, [Drawing.Point]::Empty, $form.Size); $gr.Dispose()
        $shot.Save("$Out\$name.png"); $shot.Dispose()
        Test-Layout $form $name
    }
    # Finds text or boxes that overlap, stick out of their area, or are cut off
    function Test-Layout($form, $name) {
        $bad = [Collections.ArrayList]@()
        $what = { param($c) "$($c.GetType().Name) '$($c.Text)' at $($c.Left),$($c.Top) size $($c.Width)x$($c.Height)" }
        $walk = {
            param($box)
            $cs = @($box.Controls | Where-Object { $_.Visible -and $_.Height -gt 1 -and $_.Width -gt 1 })
            for ($i = 0; $i -lt $cs.Count; $i++) {
                $a = $cs[$i]
                for ($j = $i + 1; $j -lt $cs.Count; $j++) { if ($a.Bounds.IntersectsWith($cs[$j].Bounds)) { [void]$bad.Add("$(& $what $a) overlaps $(& $what $cs[$j])") } }
                if (-not $box.AutoScroll -and ($a.Left -lt 0 -or $a.Top -lt 0 -or $a.Right -gt $box.ClientSize.Width -or $a.Bottom -gt $box.ClientSize.Height)) { [void]$bad.Add("$(& $what $a) sticks out of its area") }
                if ($a -is [Windows.Forms.Label] -and -not $a.AutoEllipsis -and $a.PreferredWidth -gt $a.Width + 1) { [void]$bad.Add("$(& $what $a) is cut off") }
                if ($a -is [MgButton] -and (TextW $a.Text $a.Font) -gt $a.Width - (Px 8)) { [void]$bad.Add("$(& $what $a) text does not fit") }
                if ($a.GetType() -eq [Windows.Forms.Panel]) { & $walk $a }
            }
        }
        & $walk $form
        Check ($bad.Count -eq 0) "Layout of the '$name' window (scale $([math]::Round($Z, 2)))$(if ($bad.Count) { ': ' + ($bad -join '; ') })"
    }
    function Start-Fake($url, $name) {   # starts a download the same way the Download button does
        $S.Kind = 'youtube'; $S.Url = $S.Target = $url; $S.Name = $name; $S.Started = $null
        foreach ($b in $U.Start, $U.End, $U.Name) { $b.Text = '' }
        $U.Type.Value = 'mp3'
        Start-Download
        @(Get-Entries)[0]
    }
    function Press($keys) { [Hotkey]::Tap([byte[]]$keys) }
    $CtrlAltY = 0x11, 0x12, 0x59; $CtrlAltK = 0x11, 0x12, 0x4B
    $YouTubeLink = 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
    $SpotifyLink = 'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT'
    function Copy-Text($text) { [Windows.Forms.Clipboard]::SetText($text) }

    $C.SaveDir = "$Out\downloads"
    Check $HotkeyOk "Keyboard shortcut $($C.Hotkey) turned on at start"
    Check ((Set-Hotkey 'Ctrl+Shift+1') -and -not (Set-Hotkey 'Shift+K') -and -not (Set-Hotkey 'K') -and (Set-Hotkey $C.Hotkey)) 'Shortcuts with numbers work; ones without Ctrl, Alt or Win are refused'
    Check (Wait-Until { -not $S.Setup } 240) 'Setup finished within 4 minutes'
    Check (Test-Tools) 'yt-dlp, ffmpeg and ffprobe are installed'
    try { $r = Start-YtDlp '--version'; $r.P.WaitForExit(); Check ($r.P.ExitCode -eq 0) "yt-dlp runs (version $($r.P.StandardOutput.ReadToEnd().Trim()))" }
    catch { Check $false "yt-dlp runs: $($_.Exception.Message)" }

    $bad = Start-Fake 'https://www.youtube.com/watch?v=0000000000x' 'Selftest broken link'
    Check (Wait-Until { $bad.Status -like 'Failed*' } 120) "A broken link fails with a reason: $($bad.Status)"
    Check ([bool]$bad.Error) 'The failure reason was captured'
    $good = Start-Fake $YouTubeLink 'Selftest'
    [void](Wait-Until { $good.Status -eq 'Done' -or $good.Status -like 'Failed*' } 300)
    Note ($good.Status -eq 'Done') "Real download (mp3): $($good.Status)"
    if ($good.Status -eq 'Done') { Check (Test-Path "$($C.SaveDir)\Selftest.mp3") 'The mp3 file was saved' }

    # Screenshots with sample content
    $demo = @{ Name = 'Example Artist - Example Song.mp3'; Dir = $C.SaveDir; Date = Get-Date -Format 'yyyy-MM-dd HH:mm'; Status = 'Starting...' }
    Add-Entry $demo; Set-Status $demo "42.5%$($Dot)3.10MiB/s$($Dot)00:12 left" '42.5'
    Save-Shot $D 'downloads'
    $U.Title.Text = 'Example Artist - Example Song (Official Video)'; $U.Info.Text = "YouTube$($Dot)3:45"; $U.Url.Text = 'https://www.youtube.com/watch?v=example'
    $U.Type.Value = 'mp4'; $U.VQ.Value = 'Best'; $U.Go.Fill = $T.YouTube; $U.Go.Hover = $T.YouTubeHover; $U.Go.Enabled = $true; $U.Match.Visible = $false; $U.Url.Visible = $true
    Set-Hints; Save-Shot $F 'download-sample'; $F.Hide()

    # Then use MediaGrab like a person: press the shortcut, change it in Settings, press the new one.
    # Each step runs on a timer, so it also runs while a window is open and waiting.
    $Steps = [Collections.ArrayList]@(); $StepAt = 0; $StepStart = Get-Date; $Running = @{}
    function Add-Step($name, $seconds, $do) { [void]$Steps.Add(@{ Name = $name; Seconds = $seconds; Do = $do }) }
    $StepTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 150 }
    $StepTimer.Add_Tick({
        $i = $script:StepAt
        if ($i -ge $Steps.Count) { $StepTimer.Stop(); return }
        if ($Running[$i]) { return }   # this step is still busy (e.g. taking a screenshot)
        $Running[$i] = $true
        $st = $Steps[$i]
        if (-not $Running.Count -and ((Get-Date) - $script:StepStart).TotalMilliseconds -lt 200) { Log "TEST step: $($st.Name)" }
        try { $done = [bool](& $st.Do) } catch { Check $false "$($st.Name): $_"; $done = $true }
        $Running.Remove($i)
        if (-not $done -and ((Get-Date) - $script:StepStart).TotalSeconds -gt $st.Seconds) {
            Check $false "$($st.Name): did not happen within $($st.Seconds) s (window title: '$($U.Title.Text)', info: '$($U.Info.Text)')"
            $done = $true
            if ($script:SettingsUi) { $script:SettingsUi.W.Close() } elseif ($F.Visible) { $F.DialogResult = 'Cancel' }
        }
        if ($done -and $script:StepAt -eq $i) { $script:StepAt++; $script:StepStart = Get-Date }
    })
    function Wait-Idle { -not $Load.Enabled -and -not $Poll.Enabled }

    Add-Step 'Press Ctrl+Alt+Y with a YouTube link copied' 5 { Copy-Text $YouTubeLink; Show-Downloads; $script:Pressed = Get-Date; Press $CtrlAltY; $true }
    Add-Step 'The download window opens at once' 5 {
        if (-not $F.Visible) { return $false }
        $ms = [int]((Get-Date) - $script:Pressed).TotalMilliseconds
        Check ($ms -lt 2000) "Pressing the shortcut opened the download window after $ms ms (shows '$($U.Title.Text)')"
        Check ([Hotkey]::IsWindowVisible($F.Handle)) 'The download window is really on screen'; $true }
    Add-Step 'The YouTube link is looked up' 90 {
        if (-not (Wait-Idle)) { return $false }
        Check ($S.Url -eq $YouTubeLink) "The copied YouTube link was used: $($S.Url)"
        Note ($U.Title.Text -notin 'Not available', 'Loading...') "YouTube details: '$($U.Title.Text)' / '$($U.Info.Text)'"
        Save-Shot $F 'download-youtube'; $F.DialogResult = 'Cancel'; $true }
    Add-Step 'The window closes' 5 { -not $F.Visible }
    Add-Step 'Press Ctrl+Alt+Y with a Spotify link copied' 5 { Copy-Text $SpotifyLink; Show-Downloads; Press $CtrlAltY; $true }
    Add-Step 'The Spotify song is looked up' 90 {
        if (-not $F.Visible -or -not (Wait-Idle)) { return $false }
        Check ($S.Kind -eq 'spotify') "The copied Spotify link was used: $($S.Url)"
        Note ([bool]$S.SpTitle) "Spotify details: '$($U.Title.Text)' / '$($U.Info.Text)'"
        Save-Shot $F 'download-spotify'; $F.DialogResult = 'Cancel'; $true }
    Add-Step 'The window closes' 5 { -not $F.Visible }
    Add-Step 'Press Ctrl+Alt+Y with nothing useful copied' 5 { Copy-Text 'hello'; Show-Downloads; Press $CtrlAltY; $true }
    Add-Step 'The window explains what to do' 30 {
        if (-not $F.Visible -or -not (Wait-Idle)) { return $false }
        Check ($U.Title.Text -eq 'No video or song found') "With no link, the window says: '$($U.Title.Text)' / '$($U.Info.Text)'"
        Save-Shot $F 'download-no-link'; $F.DialogResult = 'Cancel'; $true }
    Add-Step 'The window closes' 5 { -not $F.Visible }
    Add-Step 'Click "Download copied link" in the tray menu' 5 { Copy-Text $YouTubeLink; $Tray.ContextMenuStrip.Items[0].PerformClick(); $true }
    Add-Step 'The tray menu item opens the window' 5 {
        if (-not $F.Visible) { return $false }
        Check ([Hotkey]::IsWindowVisible($F.Handle)) '"Download copied link" opens the download window (on screen)'; $F.DialogResult = 'Cancel'; $true }
    Add-Step 'The window closes' 5 { -not $F.Visible }
    Add-Step 'Open Settings' 5 { $script:StepAt++; $script:StepStart = Get-Date; Show-Settings; $true }   # stays open until a later step saves
    Add-Step 'Settings shows the current shortcut' 10 {
        if (-not $script:SettingsUi -or -not $script:SettingsUi.W.Visible) { return $false }
        Check ($script:SettingsUi.Key.Box.Text -eq 'Ctrl+Alt+Y') "Settings shows the shortcut '$($script:SettingsUi.Key.Box.Text)'"
        Save-Shot $script:SettingsUi.W 'settings'; $true }
    Add-Step 'Click the shortcut box and press Ctrl+Alt+K' 5 { $script:SettingsUi.W.Activate(); [void]$script:SettingsUi.Key.Box.Focus(); Press $CtrlAltK; $true }
    Add-Step 'The box shows Ctrl+Alt+K, then Save' 5 {
        if ($script:SettingsUi.Key.Value -ne 'Ctrl+Alt+K') { return $false }
        Check $true "The shortcut box shows '$($script:SettingsUi.Key.Box.Text)'"
        Save-Shot $script:SettingsUi.W 'settings-new-shortcut'; $script:SettingsUi.Save.PerformClick(); $true }
    Add-Step 'Settings closes and keeps the new shortcut' 5 {
        if ($script:SettingsUi) { return $false }
        Check ($C.Hotkey -eq 'Ctrl+Alt+K') "Saved shortcut: $($C.Hotkey)"
        Check ((Get-Content $CfgFile -Raw) -match 'Ctrl\+Alt\+K') 'The new shortcut is in the settings file'; $true }
    Add-Step 'Press the new shortcut Ctrl+Alt+K' 5 { Copy-Text $YouTubeLink; Show-Downloads; Press $CtrlAltK; $true }
    Add-Step 'The new shortcut opens the window' 5 { if (-not $F.Visible) { return $false }; Check ([Hotkey]::IsWindowVisible($F.Handle)) 'Ctrl+Alt+K opens the download window (on screen)'; $F.DialogResult = 'Cancel'; $true }
    Add-Step 'The window closes' 5 { -not $F.Visible }
    Add-Step 'Press the old shortcut Ctrl+Alt+Y' 5 { Show-Downloads; $script:Pressed = Get-Date; Press $CtrlAltY; $true }
    Add-Step 'The old shortcut does nothing now' 5 {
        if ($F.Visible) { Check $false 'The old shortcut Ctrl+Alt+Y still opens the window'; $F.DialogResult = 'Cancel'; return $true }
        if (((Get-Date) - $script:Pressed).TotalSeconds -lt 2) { return $false }
        Check $true 'The old shortcut Ctrl+Alt+Y no longer opens the window'; $true }
    Add-Step 'Change back to Ctrl+Alt+Y' 5 { $C.Hotkey = 'Ctrl+Alt+Y'; Save-Config; Check (Set-Hotkey $C.Hotkey) 'Shortcut changed back to Ctrl+Alt+Y'; $true }

    $StepTimer.Start()
    Check (Wait-Until { $script:StepAt -ge $Steps.Count } 600) "All $($Steps.Count) steps ran"
    $StepTimer.Stop(); $D.Hide()

    Flush-Errors
    foreach ($e in $ErrorLog) { [void]$Log.Add("ERROR  $e") }
    Check ($ErrorLog.Count -eq 0) "No script errors ($($ErrorLog.Count) found)"
    Copy-Item $LogFile "$Out\log.txt" -ErrorAction Ignore
    $Log | Set-Content "$Out\result.txt"
    $Log | ForEach-Object { [Console]::WriteLine($_) }
    $Tray.Visible = $false
    [Environment]::Exit([int]($Fails -gt 0))
}

if (-not $HotkeyOk) {
    Show-Message "The keyboard shortcut $($C.Hotkey) is already used by another program.`n`nIn the Settings window that opens next, click the shortcut box and press a different one."
    Show-Settings
}
[Windows.Forms.Application]::Run()
Log 'Closed'
try { $Mutex.ReleaseMutex() } catch { }
[Environment]::Exit(0)
