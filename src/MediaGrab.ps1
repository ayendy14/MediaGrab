param([string]$ExePath)
# MediaGrab - press the shortcut on a YouTube or Spotify tab (or with a link copied) to download it.
# Runs from MediaGrab.exe. yt-dlp and ffmpeg are downloaded automatically on first run.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System; using System.Windows.Forms; using System.Runtime.InteropServices;
public class Hotkey : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    public static void Hint(TextBox box, string text) { SendMessage(box.Handle, 0x1501, (IntPtr)1, text); }
    public event EventHandler Pressed;
    public bool Register(uint mod, uint vk) {
        if (Handle == IntPtr.Zero) CreateHandle(new CreateParams());
        UnregisterHotKey(Handle, 1); return RegisterHotKey(Handle, 1, mod | 0x4000, vk);
    }
    protected override void WndProc(ref Message m) { if (m.Msg == 0x312 && Pressed != null) Pressed(this, null); base.WndProc(ref m); }
}
'@
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$Mutex = New-Object Threading.Mutex($false, 'MediaGrab-SingleInstance')
if (-not $Mutex.WaitOne(0)) { exit }   # already running

# ============================ Settings ============================
$App      = "$env:LOCALAPPDATA\MediaGrab"
$Bin      = "$App\bin"
$CfgFile  = "$App\settings.json"
$HistFile = "$App\history.json"
$RunKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$Choices  = @{ Format = 'mp3', 'm4a', 'opus', 'flac', 'wav', 'mp4'; VideoQuality = 'Best', '1080p', '720p', '480p', '360p'; EmbedInfo = 'Yes', 'No' }
$C = [ordered]@{
    Hotkey = 'Ctrl+Alt+Y'; SaveDir = "$env:USERPROFILE\Downloads"; Format = 'mp3'; VideoQuality = 'Best'; AudioQuality = '0'; EmbedInfo = 'Yes'
    StartTime = ''; EndTime = ''; FileName = ''; MatchTolerance = '3'; Browsers = 'chrome, msedge, firefox, brave, opera, vivaldi'
}
if (Test-Path $CfgFile) { (Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | Where-Object { $C.Contains($_.Name) } | ForEach-Object { $C[$_.Name] = "$($_.Value)" } }
function Save-Config { New-Item $App -ItemType Directory -Force | Out-Null; $C | ConvertTo-Json | Set-Content $CfgFile -Encoding UTF8 }

$S   = @{ Active = [Collections.ArrayList]@() }
$UIA = [Windows.Automation.AutomationElement]

# ============================ Helpers =============================
function Get-TabUrl {
    $win = $UIA::FromHandle([Hotkey]::GetForegroundWindow())
    if ((Get-Process -Id $win.Current.ProcessId).Name -notin ($C.Browsers -split '\s*,\s*')) { return }
    $edit = $win.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)))
    $url  = $edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($url -notmatch '^\w+://') { $url = "https://$url" }
    $url
}

function Get-Kind($url) {
    if ($url -match '^https?://([\w-]+\.)*(youtube\.com|youtu\.be)/') { 'youtube' }
    elseif ($url -match '^https?://open\.spotify\.com/(intl-\w+/)?track/') { 'spotify' }
}

function Start-YtDlp([string]$arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo "$Bin\yt-dlp.exe", "--encoding utf-8 --ffmpeg-location `"$Bin`" $arguments" -Property @{
        UseShellExecute = $false; CreateNoWindow = $true; RedirectStandardOutput = $true; StandardOutputEncoding = [Text.Encoding]::UTF8 }
    [Diagnostics.Process]::Start($psi)
}

function Format-Len($sec) { if (-not $sec) { return '?' }; $t = [TimeSpan]::FromSeconds([double]$sec); if ($t.Hours) { $t.ToString('h\:mm\:ss') } else { $t.ToString('m\:ss') } }
function Notify($title, $text) { $Tray.ShowBalloonTip(3000, $title, $text, 'Info') }
function Test-Time($t) { -not $t -or $t -match '^\d+(:\d{1,2}){0,2}(\.\d+)?$' }
function Open-Dir($dir) { New-Item $dir -ItemType Directory -Force | Out-Null; Start-Process explorer "`"$dir`"" }
function Add-Ctl($form, $type, $props) { $c = New-Object "Windows.Forms.$type" -Property $props; $form.Controls.Add($c); $c }
function Color($hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
function New-Window($title, $size) {
    New-Object Windows.Forms.Form -Property @{ Text = $title; ClientSize = $size; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        StartPosition = 'CenterScreen'; BackColor = 'White'; Font = New-Object Drawing.Font('Segoe UI', 9.5) }
}

function Set-Hotkey($text) {
    $keys = $text -split '\s*\+\s*'; $mods = 0
    foreach ($k in $keys[0..($keys.Count - 2)]) { $m = @{ Alt = 1; Ctrl = 2; Shift = 4; Win = 8 }[$k]; if (-not $m) { return $false }; $mods += $m }
    try { $vk = [int][Windows.Forms.Keys]$keys[-1] } catch { return $false }
    $Tray.Text = "MediaGrab ($text)"
    $hk.Register($mods, $vk)
}

# ========== First run: download yt-dlp + ffmpeg / update yt-dlp (in background) ==========
$S.Setup = Start-Job -ArgumentList $Bin -ScriptBlock {
    param($bin)
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    New-Item $bin -ItemType Directory -Force | Out-Null
    $web = New-Object Net.WebClient
    if (Test-Path "$bin\yt-dlp.exe") { & "$bin\yt-dlp.exe" -U | Out-Null }
    else { $web.DownloadFile('https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe', "$bin\yt-dlp.exe") }
    if (-not (Test-Path "$bin\ffmpeg.exe")) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $web.DownloadFile('https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip', "$bin\ffmpeg.zip")
        $zip = [IO.Compression.ZipFile]::OpenRead("$bin\ffmpeg.zip")
        $zip.Entries | Where-Object { $_.Name -in 'ffmpeg.exe', 'ffprobe.exe' } | ForEach-Object { [IO.Compression.ZipFileExtensions]::ExtractToFile($_, "$bin\$($_.Name)", $true) }
        $zip.Dispose(); Remove-Item "$bin\ffmpeg.zip"
    }
}

# ===================== Downloads window (progress + history) =====================
$D = New-Window 'MediaGrab - Downloads' '640,360'
$D.FormBorderStyle = 'Sizable'; $D.MinimumSize = '480,260'; $D.MaximizeBox = $true
$List = Add-Ctl $D ListView @{ View = 'Details'; FullRowSelect = $true; Location = '12,12'; Size = '616,290'; Anchor = 'Top,Bottom,Left,Right'; BorderStyle = 'FixedSingle' }
foreach ($col in ('Name', 320), ('Status', 160), ('Date', 115)) { [void]$List.Columns.Add($col[0], $col[1]) }
$ShowBtn  = Add-Ctl $D Button @{ Text = 'Show in folder'; Location = '12,314'; Size = '120,32'; Anchor = 'Bottom,Left'; FlatStyle = 'Flat' }
$ClearBtn = Add-Ctl $D Button @{ Text = 'Clear history'; Location = '140,314'; Size = '110,32'; Anchor = 'Bottom,Left'; FlatStyle = 'Flat' }
$D.Add_FormClosing({ if ($_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $D.Hide() } })

function Show-Downloads { $D.Show(); $D.WindowState = 'Normal'; $D.Activate() }
function Add-Entry($e) {
    $e.Item = New-Object Windows.Forms.ListViewItem($e.Name)
    [void]$e.Item.SubItems.Add($e.Status); [void]$e.Item.SubItems.Add($e.Date)
    $e.Item.Tag = $e; $List.Items.Insert(0, $e.Item)
}
function Set-Status($e, $text) { $e.Status = $text; $e.Item.SubItems[1].Text = $text }
function Get-Entries { $List.Items | ForEach-Object Tag }
function Save-History {
    $h = @(Get-Entries | Where-Object { $_.Status -eq 'Done' } | Select-Object -First 500 | ForEach-Object { [ordered]@{ Name = $_.Name; Path = $_.Path; Dir = $_.Dir; Key = $_.Key; Date = $_.Date } })
    New-Item $App -ItemType Directory -Force | Out-Null
    ConvertTo-Json -InputObject $h | Set-Content $HistFile -Encoding UTF8
}
function Show-InFolder($e) {
    if ($e.Path -and (Test-Path -LiteralPath $e.Path)) { Start-Process explorer "/select,`"$($e.Path)`"" } else { Open-Dir $e.Dir }
}
$ShowBtn.Add_Click({ if ($List.SelectedItems.Count) { Show-InFolder $List.SelectedItems[0].Tag } })
$List.Add_DoubleClick({ if ($List.SelectedItems.Count) { Show-InFolder $List.SelectedItems[0].Tag } })
$ClearBtn.Add_Click({
    foreach ($it in @($List.Items)) { if ($it.Tag.Status -in 'Done', 'Failed') { $List.Items.Remove($it) } }
    Save-History
})
if (Test-Path $HistFile) {
    $old = @((Get-Content $HistFile -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ }); [array]::Reverse($old)
    foreach ($h in $old) { Add-Entry @{ Name = $h.Name; Path = $h.Path; Dir = $h.Dir; Key = $h.Key; Date = $h.Date; Status = 'Done' } }
}

# ========================= Download window ========================
$F = New-Window 'MediaGrab' '640,316'
$F.TopMost = $true
$U = @{
    Pic   = Add-Ctl $F PictureBox @{ Location = '16,16'; Size = '192,108'; SizeMode = 'Zoom'; BackColor = 'WhiteSmoke' }
    Title = Add-Ctl $F Label    @{ Location = '224,12'; Size = '400,44'; AutoEllipsis = $true; Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold) }
    Info  = Add-Ctl $F Label    @{ Location = '224,58'; Size = '400,20'; ForeColor = 'DimGray'; AutoEllipsis = $true }
    Match = Add-Ctl $F ComboBox @{ Location = '224,79'; Width = 400; DropDownStyle = 'DropDownList' }
    Url   = Add-Ctl $F Label    @{ Location = '224,108'; Size = '400,18'; ForeColor = 'Gray'; AutoEllipsis = $true }
    Start = Add-Ctl $F TextBox  @{ Location = '62,144'; Width = 90 }
    End   = Add-Ctl $F TextBox  @{ Location = '200,144'; Width = 90 }
    Type  = Add-Ctl $F ComboBox @{ Location = '344,143'; Width = 80; DropDownStyle = 'DropDownList' }
    VQ    = Add-Ctl $F ComboBox @{ Location = '484,143'; Width = 140; DropDownStyle = 'DropDownList' }
    Dir   = Add-Ctl $F TextBox  @{ Location = '62,180'; Width = 470 }
    Name  = Add-Ctl $F TextBox  @{ Location = '62,214'; Width = 470 }
    Ext   = Add-Ctl $F Label    @{ Location = '538,217'; AutoSize = $true; ForeColor = 'DimGray' }
    Go    = Add-Ctl $F Button   @{ Location = '444,264'; Size = '100,36'; Text = 'Download'; FlatStyle = 'Flat'; ForeColor = 'White' }
    Close = Add-Ctl $F Button   @{ Location = '552,264'; Size = '72,36'; Text = 'Close'; FlatStyle = 'Flat'; DialogResult = 'Cancel' }
}
$Browse = Add-Ctl $F Button @{ Location = '540,179'; Size = '84,26'; Text = 'Browse'; FlatStyle = 'Flat' }
foreach ($l in ('Start', 16, 147), ('End', 166, 147), ('Type', 306, 147), ('Video', 440, 147), ('Folder', 16, 183), ('Name', 16, 217)) {
    [void](Add-Ctl $F Label @{ Text = $l[0]; Location = "$($l[1]),$($l[2])"; AutoSize = $true; ForeColor = 'DimGray' })
}
$U.Type.Items.AddRange([object[]]$Choices.Format)
$U.VQ.Items.AddRange([object[]]$Choices.VideoQuality)
$U.Type.Add_SelectedIndexChanged({ $U.Ext.Text = ".$($U.Type.Text)"; $U.VQ.Enabled = $U.Type.Text -eq 'mp4' })
$U.Go.FlatAppearance.BorderSize = 0
$F.AcceptButton = $U.Go
$F.CancelButton = $U.Close

function Set-Hints {
    [Hotkey]::Hint($U.Start, $(if ($C.StartTime) { $C.StartTime } else { 'beginning (e.g. 1:30)' }))
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

$U.Go.Add_Click({
    $from, $to, $dir, $name = ($U.Start, $U.End, $U.Dir, $U.Name).Text.Trim()
    if (-not $from) { $from = $C.StartTime }; if (-not $to) { $to = $C.EndTime }
    if (-not $dir)  { $dir = $C.SaveDir };    if (-not $name) { $name = if ($C.FileName) { $C.FileName } else { $S.Name } }
    foreach ($t in $from, $to) { if (-not (Test-Time $t)) { [void][Windows.Forms.MessageBox]::Show($F, "'$t' is not a valid time. Use 90 or 1:30.", 'MediaGrab'); return } }

    $key = if ($S.Kind -eq 'spotify') { $S.Url -replace '\?.*' } else { $S.Target -replace '&.*' }
    $dup = Get-Entries | Where-Object { $_.Key -eq $key -and $_.Status -eq 'Done' } | Select-Object -First 1
    if ($dup -and [Windows.Forms.MessageBox]::Show($F, "You already downloaded this on $($dup.Date):`n$($dup.Name)`n`nDownload it again?", 'MediaGrab', 'YesNo') -ne 'Yes') { return }

    $fmt   = $U.Type.Text
    $sort  = if ($U.VQ.Text -eq 'Best') { 'ext:mp4:m4a' } else { "res:$($U.VQ.Text -replace 'p'),ext:mp4:m4a" }
    $type  = if ($fmt -eq 'mp4') { "-S `"$sort`" --merge-output-format mp4" } else { "-x --audio-format $fmt --audio-quality $($C.AudioQuality)" }
    $cut   = if ($from -or $to) { "--download-sections `"*$(if ($from) { $from } else { 0 })-$(if ($to) { $to } else { 'inf' })`"" }
    $info  = if ($C.EmbedInfo -eq 'Yes' -and $fmt -ne 'wav') {
        '--embed-metadata --embed-thumbnail' + $(if ($S.Kind -eq 'spotify') { (Meta-Arg title $S.SpTitle) + (Meta-Arg artist $S.SpArtist) + (Meta-Arg album $S.SpAlbum) })
    }
    $clean = if ($name) { $name -replace '[\\/:*?"<>|]', '_' -replace "\.$fmt$" }
    $out   = if ($clean) { $clean -replace '%', '%%' } else { '%(title)s' }
    $dir   = $dir.TrimEnd('\')
    New-Item $dir -ItemType Directory -Force | Out-Null

    $e = @{ Name = $(if ($clean) { "$clean.$fmt" } else { $S.Url }); Path = $(if ($clean) { "$dir\$clean.$fmt" }); Dir = $dir; Key = $key
            Date = Get-Date -Format 'yyyy-MM-dd HH:mm'; Status = 'Starting...' }
    $e.P = Start-YtDlp "$type $info $cut --no-playlist --newline --progress-template `"download:P|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s`" -o `"$dir\$out.%(ext)s`" `"$($S.Target)`""
    $e.Line = $e.P.StandardOutput.ReadLineAsync()
    Add-Entry $e; [void]$S.Active.Add($e)
    $S.Started = $true
    $F.Close()
})

# Fills in details once yt-dlp answers (for Spotify: lists YouTube results, picks the one closest in length)
$Poll = New-Object Windows.Forms.Timer -Property @{ Interval = 250 }
$Poll.Add_Tick({
    if (-not $S.Meta.IsCompleted) { return }
    $Poll.Stop()
    $seen = @{}
    $S.Found = @($S.Meta.Result -split "`r?`n" | Where-Object { $_ } | ForEach-Object {
        $id, $dur, $title = $_ -split '\|', 3; $dur = $dur -as [double]
        [pscustomobject]@{ Id = $id; Dur = $dur; Title = $title; Diff = $(if ($dur -and $S.SpDur) { [math]::Abs($dur - $S.SpDur) } else { 1e9 }) }
    } | Where-Object { -not $seen[$_.Id] -and ($seen[$_.Id] = 1) })
    if (-not $S.Found) { $U.Info.Text = 'Could not find this online.'; return }
    $best = @($S.Found | Where-Object { $_.Diff -le [double]$C.MatchTolerance })[0]    # first result with matching length
    if (-not $best) { $best = $S.Found | Sort-Object Diff | Select-Object -First 1 }
    if ($S.Kind -eq 'spotify') {
        $U.Info.Text = "Spotify length: $(Format-Len $S.SpDur)   -   YouTube match (change if wrong):"
        $U.Match.Items.Clear()
        foreach ($m in $S.Found) { [void]$U.Match.Items.Add("$($m.Title)  ($(Format-Len $m.Dur))") }
        $U.Match.SelectedIndex = @(0..($S.Found.Count - 1) | Where-Object { $S.Found[$_].Id -eq $best.Id })[0]
        $U.Go.Enabled = $true
    } else {
        $S.Name = $U.Title.Text = $best.Title
        Use-Match $best
        $U.Info.Text = "Length: $($S.Len)"
        $U.Pic.LoadAsync("https://i.ytimg.com/vi/$($best.Id)/hqdefault.jpg")
    }
})

function Get-Meta($html, $name) { [Net.WebUtility]::HtmlDecode([regex]::Match($html, "$name`" content=`"([^`"]*)").Groups[1].Value) }

function Show-Dialog($url, $kind) {
    foreach ($k in 'Name', 'Len', 'SpDur', 'SpTitle', 'SpArtist', 'SpAlbum', 'Started') { $S[$k] = $null }
    $S.Url = $S.Target = $url; $S.Kind = $kind
    foreach ($b in $U.Start, $U.End, $U.Name) { $b.Text = '' }
    $U.Type.SelectedItem = $C.Format;     if ($U.Type.SelectedIndex -lt 0) { $U.Type.SelectedIndex = 0 }
    $U.VQ.SelectedItem = $C.VideoQuality; if ($U.VQ.SelectedIndex -lt 0) { $U.VQ.SelectedIndex = 0 }
    $U.Pic.Image = $null; $U.Url.Text = $url; $U.Title.Text = 'Loading...'; $U.Info.Text = ''
    $U.Match.Items.Clear(); $U.Match.Visible = $kind -eq 'spotify'
    $U.Go.BackColor = Color $(if ($kind -eq 'spotify') { '#1DB954' } else { '#E62117' })
    $U.Go.Enabled = $kind -eq 'youtube'   # Spotify waits until a YouTube match is found
    $fields = '--print "%(id)s|%(duration)s|%(title)s"'
    $query  = "--no-playlist $fields `"$url`""

    if ($kind -eq 'spotify') {
        try {
            $html = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 8).Content
            $page = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '<title>(.*?)</title>').Groups[1].Value)
            if ($page -match '^(.+) - song(?: and lyrics)? by (.+?) \| Spotify') { $S.SpTitle, $S.SpArtist = $Matches[1], $Matches[2] }
            else { $S.SpTitle = Get-Meta $html 'og:title' }
            $desc = (Get-Meta $html 'og:description') -split " $([char]0xB7) "
            if ($desc.Count -ge 4 -and $desc[0] -notlike 'Listen to*') { if (-not $S.SpArtist) { $S.SpArtist = $desc[0] }; $S.SpAlbum = $desc[1] }
            $S.SpDur = [regex]::Match($html, 'music:duration" content="(\d+)').Groups[1].Value -as [double]
            $img = Get-Meta $html 'og:image'
            if ($img) { $U.Pic.LoadAsync($img) }
        } catch { }
        if (-not $S.SpTitle) { Notify 'MediaGrab' 'Could not read this Spotify page.'; return }
        $S.Name = $U.Title.Text = $(if ($S.SpArtist) { "$($S.SpArtist) - $($S.SpTitle)" } else { $S.SpTitle })
        $q = $S.Name -replace '"'
        $query = "--flat-playlist -i --playlist-items 1:5 $fields `"https://music.youtube.com/search?q=$([Uri]::EscapeDataString($q))#songs`" `"ytsearch5:$q`""
    }

    $S.Meta = (Start-YtDlp $query).StandardOutput.ReadToEndAsync()
    $Poll.Start()
    [void]$F.ShowDialog()
    $Poll.Stop()
    if ($S.Started) { Show-Downloads }
}

# ========================= Settings window ========================
function Show-Settings {
    $W = New-Window 'MediaGrab - Settings' '540,470'
    $W.TopMost = $true
    $rows = [ordered]@{
        Hotkey = 'Keyboard shortcut'; SaveDir = 'Download folder'; Format = 'Default file type'; VideoQuality = 'Default video quality (mp4)'
        AudioQuality = 'Audio quality (0 best - 10 smallest)'; EmbedInfo = 'Add song info and cover to files'
        StartTime = 'Default start time'; EndTime = 'Default end time'; FileName = 'Default file name'
        MatchTolerance = 'Spotify match tolerance (seconds)'; Browsers = 'Browsers (comma separated)'
    }
    $box = @{}; $y = 16
    foreach ($k in $rows.Keys) {
        [void](Add-Ctl $W Label @{ Text = $rows[$k]; Location = "16,$($y + 3)"; AutoSize = $true; ForeColor = 'DimGray' })
        if ($Choices[$k]) {
            $box[$k] = Add-Ctl $W ComboBox @{ Location = "260,$y"; Width = 110; DropDownStyle = 'DropDownList' }
            $box[$k].Items.AddRange([object[]]$Choices[$k]); $box[$k].SelectedItem = $C[$k]
        } else {
            $box[$k] = Add-Ctl $W TextBox @{ Location = "260,$y"; Width = $(if ($k -eq 'SaveDir') { 180 } else { 264 }); Text = $C[$k] }
        }
        $y += 34
    }
    $b = Add-Ctl $W Button @{ Location = '448,49'; Size = '76,26'; Text = 'Browse'; FlatStyle = 'Flat' }
    $b.Add_Click({ Pick-Folder $box.SaveDir $W })
    $auto = Add-Ctl $W CheckBox @{ Location = "16,$($y + 4)"; AutoSize = $true; Text = 'Start MediaGrab with Windows'; Enabled = [bool]$ExePath
                                   Checked = [bool](Get-ItemProperty $RunKey -Name MediaGrab -ErrorAction SilentlyContinue) }
    $save = Add-Ctl $W Button @{ Location = '348,420'; Size = '100,36'; Text = 'Save'; FlatStyle = 'Flat'; ForeColor = 'White'; BackColor = Color '#2B2B2B' }
    $W.CancelButton = Add-Ctl $W Button @{ Location = '456,420'; Size = '68,36'; Text = 'Cancel'; FlatStyle = 'Flat'; DialogResult = 'Cancel' }
    $W.AcceptButton = $save

    $save.Add_Click({
        $new = @{}; foreach ($k in $box.Keys) { $new[$k] = $box[$k].Text.Trim() }
        $err = if ($new.AudioQuality -notmatch '^(10|\d)$') { 'Audio quality must be a number from 0 to 10.' }
               elseif ($new.MatchTolerance -notmatch '^\d+(\.\d+)?$') { 'Match tolerance must be a number.' }
               elseif (-not ((Test-Time $new.StartTime) -and (Test-Time $new.EndTime))) { 'Times must look like 90 or 1:30.' }
               elseif (-not $new.SaveDir) { 'Choose a download folder.' }
               elseif (-not (Set-Hotkey $new.Hotkey)) { [void](Set-Hotkey $C.Hotkey); "Shortcut '$($new.Hotkey)' is invalid or used by another program. Example: Ctrl+Shift+D" }
        if ($err) { [void][Windows.Forms.MessageBox]::Show($W, $err, 'MediaGrab'); return }
        foreach ($k in $new.Keys) { $C[$k] = $new[$k] }
        Save-Config
        if ($auto.Checked) { Set-ItemProperty $RunKey MediaGrab "`"$ExePath`"" } else { Remove-ItemProperty $RunKey MediaGrab -ErrorAction SilentlyContinue }
        $W.Close()
    })
    [void]$W.ShowDialog(); $W.Dispose()
}

# ===================== Tray icon and background work =====================
$bmp = New-Object Drawing.Bitmap 32, 32; $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
$g.FillEllipse((New-Object Drawing.SolidBrush (Color '#E62117')), 1, 1, 30, 30)
$g.FillPolygon([Drawing.Brushes]::White, [Drawing.Point[]]@('13,7', '19,7', '19,15', '24,15', '16,24', '8,15', '13,15'))
$Tray = New-Object Windows.Forms.NotifyIcon -Property @{ Visible = $true; ContextMenuStrip = New-Object Windows.Forms.ContextMenuStrip; Icon = [Drawing.Icon]::FromHandle($bmp.GetHicon()) }
$D.Icon = $Tray.Icon; $F.Icon = $Tray.Icon
foreach ($m in ('Downloads', { Show-Downloads }), ('Settings', { Show-Settings }), ('Open download folder', { Open-Dir $C.SaveDir }), ('Exit', { $Tray.Visible = $false; [Windows.Forms.Application]::Exit() })) {
    [void]$Tray.ContextMenuStrip.Items.Add($m[0], $null, $m[1])
}
$Tray.Add_BalloonTipClicked({ Show-Downloads })
$Tray.Add_MouseDoubleClick({ Show-Downloads })

# Every half second: finish setup, update progress of running downloads
$Tick = New-Object Windows.Forms.Timer -Property @{ Interval = 500 }
$Tick.Add_Tick({
    if ($S.Setup -and $S.Setup.State -ne 'Running') {
        if (-not (Test-Path "$Bin\ffmpeg.exe")) { Notify 'Setup failed' 'Could not download yt-dlp / ffmpeg. Check your internet and restart MediaGrab.' }
        elseif ($S.FirstRun) { Notify 'MediaGrab is ready' "Press $($C.Hotkey) on a YouTube or Spotify tab." }
        Remove-Job $S.Setup -Force; $S.Setup = $null
    }
    foreach ($e in @($S.Active)) {
        while ($e.Line.IsCompleted) {
            $line = $e.Line.Result
            if ($null -eq $line) { break }
            $line = $line -replace '\x1b\[[0-9;]*m'
            if ($line -like 'P|*') {
                $null, $pct, $speed, $eta = $line.Split('|').Trim()
                Set-Status $e $(if ($pct -notmatch '\d') { 'Downloading...' } elseif ($pct -like '100*') { 'Processing...' } else { "$pct   $speed   ETA $eta" })
            }
            elseif ($line -match '^\[(ExtractAudio|Merger|VideoConvertor)\]') { Set-Status $e 'Converting...' }
            elseif ($line -match '^\[(Metadata|EmbedThumbnail)\]') { Set-Status $e 'Adding info...' }
            $e.Line = $e.P.StandardOutput.ReadLineAsync()
        }
        if ($e.Line.IsCompleted -and $e.P.HasExited) {
            $S.Active.Remove($e)
            if ($e.P.ExitCode -eq 0) { Set-Status $e 'Done'; Save-History; Notify 'Download ready' $e.Name }
            else { Set-Status $e 'Failed'; Notify 'Download failed' $e.Name }
        }
    }
})
$Tick.Start()

# ============================ Shortcut ============================
$hk = New-Object Hotkey
$hk.add_Pressed({
    if ($F.Visible) { return }
    if ($S.Setup -and -not (Test-Path "$Bin\ffmpeg.exe")) { Notify 'Still setting up' 'Downloading yt-dlp and ffmpeg, please wait a minute.'; return }
    $url = $null; try { $url = Get-TabUrl } catch { }
    if (-not (Get-Kind $url)) { $url = "$([Windows.Forms.Clipboard]::GetText())".Trim() }   # no matching tab: try a copied link
    $kind = Get-Kind $url
    if ($kind) { Show-Dialog $url $kind } else { Notify 'MediaGrab' 'Open a YouTube video or Spotify song, or copy its link, then press the shortcut.' }
})

$S.FirstRun = -not (Test-Path "$Bin\ffmpeg.exe")
if ($S.FirstRun) { Notify 'Setting up MediaGrab' 'Downloading yt-dlp and ffmpeg (one time, about a minute)...' }
else { Notify 'MediaGrab is running' "Press $($C.Hotkey) on a YouTube or Spotify tab." }
if (-not (Set-Hotkey $C.Hotkey)) { [void][Windows.Forms.MessageBox]::Show("Shortcut $($C.Hotkey) is unavailable. Please choose another one.", 'MediaGrab'); Show-Settings }

[Windows.Forms.Application]::Run()
