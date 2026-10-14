# Diagnose-Audio.ps1
# 用途：对本机（Windows 11 + 多通道声卡）做一次完整的音频链路体检，输出可读报告。
# 判定层次：默认播放设备 -> 通路端点 -> 每个应用的会话音量/静音 -> 设备实际电平(峰值)
# 用法：
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\Diagnose-Audio.ps1
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\Diagnose-Audio.ps1 -SampleSeconds 8 -ExpectDefaultName "Playback 5-6"
#
# 重要：本机 stdout 经常不回传。脚本一定会把报告写到文件，并打印文件路径；
#       读取报告请用 Read 工具读那个文件，不要依赖终端回显。

param(
    [int]$SampleSeconds = 6,
    [string]$ExpectDefaultName = 'Playback 5-6',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutFile) {
    $OutFile = Join-Path $env:TEMP ("audio-diagnose-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")
}

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class AudioProbe
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { int GetCount(out int c); int Item(int i, out IMMDevice d); }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr ap, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IntPtr props);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        int GetPeakValue(out float peak);
        int GetMeteringChannelCount(out int count);
        int GetChannelsPeakValues(int count, [Out] float[] peaks);
        int QueryHardwareSupport(out int mask);
    }
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 {
        int GetAudioSessionControl(ref Guid g, int f, out IntPtr c);
        int GetSimpleAudioVolume(ref Guid g, int f, out IntPtr v);
        int GetSessionEnumerator(out IAudioSessionEnumerator e);
        int RegisterSessionNotification(IntPtr n);
        int UnregisterSessionNotification(IntPtr n);
        int RegisterDuckNotification(IntPtr a, IntPtr b);
        int UnregisterDuckNotification(IntPtr n);
    }
    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator { int GetCount(out int c); int GetSession(int i, out IAudioSessionControl s); }
    [Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl {
        int GetState(out int s);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string n);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string v, ref Guid e);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string p);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string v, ref Guid e);
        int GetGroupingParam(out Guid g);
        int SetGroupingParam(ref Guid g, ref Guid e);
        int RegisterAudioSessionNotification(IntPtr n);
        int UnregisterAudioSessionNotification(IntPtr n);
    }
    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume {
        int SetMasterVolume(float v, ref Guid e);
        int GetMasterVolume(out float v);
        int SetMute(bool m, ref Guid e);
        int GetMute(out bool m);
    }
    [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        int GetState(out int s);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string n);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string v, ref Guid e);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string p);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string v, ref Guid e);
        int GetGroupingParam(out Guid g);
        int SetGroupingParam(ref Guid g, ref Guid e);
        int RegisterAudioSessionNotification(IntPtr n);
        int UnregisterAudioSessionNotification(IntPtr n);
        int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetProcessId(out int pid);
        int IsSystemSoundsSession();
        int SetDuckingPreference(bool opt);
    }

    static Guid IID_Meter = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
    static Guid IID_Mgr = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");

    static IMMDeviceEnumerator Enumerator()
    {
        return (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
    }

    // 返回: E|<deviceId>|<isDefault>  以及  S|<deviceId>|<pid>|<state>|<volume>|<muted>
    public static List<string> Snapshot(out string err)
    {
        err = "";
        var res = new List<string>();
        try
        {
            var en = Enumerator();
            string defId = "";
            IMMDevice def;
            if (en.GetDefaultAudioEndpoint(0, 0, out def) == 0) def.GetId(out defId);

            IMMDeviceCollection coll;
            int hr = en.EnumAudioEndpoints(0, 1, out coll);
            if (hr != 0) { err = "EnumAudioEndpoints failed 0x" + hr.ToString("X8"); return res; }

            int n; coll.GetCount(out n);
            for (int i = 0; i < n; i++)
            {
                IMMDevice dev; coll.Item(i, out dev);
                string id = null; dev.GetId(out id);
                res.Add("E|" + id + "|" + (id == defId ? "1" : "0"));

                object o; Guid g = IID_Mgr;
                if (dev.Activate(ref g, 0, IntPtr.Zero, out o) != 0) continue;
                var mgr = (IAudioSessionManager2)o;
                IAudioSessionEnumerator se;
                if (mgr.GetSessionEnumerator(out se) != 0) continue;
                int sc; se.GetCount(out sc);
                for (int j = 0; j < sc; j++)
                {
                    IAudioSessionControl ctl; se.GetSession(j, out ctl);
                    var c2 = ctl as IAudioSessionControl2;
                    var vol = ctl as ISimpleAudioVolume;
                    int st = -1; try { ctl.GetState(out st); } catch { }
                    int pid = -1;
                    if (c2 != null) { try { c2.GetProcessId(out pid); } catch { } }
                    float v = -1; bool mu = false;
                    if (vol != null) { try { vol.GetMasterVolume(out v); } catch { } try { vol.GetMute(out mu); } catch { } }
                    res.Add("S|" + id + "|" + pid + "|" + st + "|" + v.ToString("F4") + "|" + mu);
                }
            }
        }
        catch (Exception ex) { err = ex.Message; }
        return res;
    }

    // 对每个活动端点采样 ms 毫秒，返回 P|<deviceId>|<maxPeak>
    public static List<string> PeakScan(int ms)
    {
        var res = new List<string>();
        try
        {
            var en = Enumerator();
            IMMDeviceCollection coll;
            if (en.EnumAudioEndpoints(0, 1, out coll) != 0) return res;
            int n; coll.GetCount(out n);

            var devs = new List<IMMDevice>();
            var ids = new List<string>();
            var meters = new List<IAudioMeterInformation>();
            for (int i = 0; i < n; i++)
            {
                IMMDevice dev; coll.Item(i, out dev);
                string id = null; dev.GetId(out id);
                object o; Guid g = IID_Meter;
                if (dev.Activate(ref g, 0, IntPtr.Zero, out o) != 0) continue;
                devs.Add(dev); ids.Add(id); meters.Add((IAudioMeterInformation)o);
            }

            double[] max = new double[ids.Count];
            int steps = Math.Max(1, ms / 100);
            for (int t = 0; t < steps; t++)
            {
                for (int k = 0; k < meters.Count; k++)
                {
                    float p = -1;
                    try { meters[k].GetPeakValue(out p); } catch { continue; }
                    if (p > max[k]) max[k] = p;
                }
                Thread.Sleep(100);
            }
            for (int k = 0; k < ids.Count; k++)
                res.Add("P|" + ids[k] + "|" + max[k].ToString("F4"));
        }
        catch { }
        return res;
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp | Out-Null

$L = New-Object System.Collections.Generic.List[string]
function Add-Line($s) { $L.Add($s) }

Add-Line "================ Windows 音频链路体检报告 ================"
Add-Line ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ("期望默认设备名称: " + $ExpectDefaultName)
Add-Line ""

# ---------- 1. 服务 ----------
Add-Line "---------- [1] 音频服务 ----------"
foreach ($n in @('Audiosrv', 'AudioEndpointBuilder')) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { Add-Line ("  " + $n + " = " + $s.Status) } else { Add-Line ("  " + $n + " = 未找到") }
}
Add-Line ""

# ---------- 2. 端点与友好名 ----------
Add-Line "---------- [2] 活动播放端点（Render / ACTIVE）----------"
$friendly = @{}
$desc = @{}
$mmRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
Get-ChildItem $mmRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty -Path ($_.PSPath + '\Properties') -ErrorAction SilentlyContinue
    $guid = $_.PSChildName -replace '^\{|\}$', ''
    $guid = $guid.ToLower()
    $friendly[$guid] = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    $desc[$guid] = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
}

$err = ''
$snap = [AudioProbe]::Snapshot([ref]$err)
if ($err) { Add-Line ("  !! 枚举失败: " + $err) }

$endpoints = @()
$sessionsAll = @()
foreach ($line in $snap) {
    $f = $line -split '\|'
    if ($f[0] -eq 'E') { $endpoints += , $f }
    elseif ($f[0] -eq 'S') { $sessionsAll += , $f }
}

function Get-Name($id) {
    $m = [regex]::Match([string]$id, '\{([0-9a-fA-F\-]{36})\}')
    if (-not $m.Success) { return [string]$id }
    $g = $m.Groups[1].Value.ToLower()
    if ($friendly.ContainsKey($g) -and $friendly[$g]) { return "$($friendly[$g])  [$($desc[$g])]" }
    return $g
}

$defaultId = ''
foreach ($e in $endpoints) {
    $isDef = $e[2] -eq '1'
    if ($isDef) { $defaultId = $e[1] }
    Add-Line ("  " + $(if ($isDef) { '*默认* ' } else { '        ' }) + (Get-Name $e[1]))
}
Add-Line ("  活动端点数: " + $endpoints.Count)
Add-Line ""

# ---------- 3. 会话明细 ----------
Add-Line "---------- [3] 每个应用的音频会话（会话音量 / 静音 / 状态）----------"
function Get-ProcName($pid_) {
    if ($pid_ -le 0) { return 'Idle/系统' }
    try { return (Get-Process -Id $pid_ -ErrorAction Stop).ProcessName } catch { return ('pid' + $pid_) }
}
function Get-StateText($s) {
    switch ([int]$s) { 0 { 'Idle' } 1 { 'Active(正在播放)' } 2 { 'Expired' } default { "state=$s" } }
}

$byEndpoint = @{}
foreach ($s in $sessionsAll) {
    $id = $s[1]
    if (-not $byEndpoint.ContainsKey($id)) { $byEndpoint[$id] = @() }
    $byEndpoint[$id] += , $s
}

$activeZeroVol = @()
$activeMuted = @()

foreach ($e in $endpoints) {
    $id = $e[1]
    Add-Line ("  ▼ " + (Get-Name $id))
    if (-not $byEndpoint.ContainsKey($id)) { Add-Line "      (无会话)"; continue }
    foreach ($s in $byEndpoint[$id]) {
        $pid_ = [int]$s[2]; $st = [int]$s[3]; $vol = [double]$s[4]; $mu = ($s[5] -eq 'True')
        $pn = Get-ProcName $pid_
        $flag = ''
        if ($st -eq 1 -and $vol -ge 0 -and $vol -lt 0.001) { $flag = '  <== 异常：正在播放但音量为 0'; $activeZeroVol += , ($pn + ' pid=' + $pid_) }
        if ($st -eq 1 -and $mu) { $flag = '  <== 异常：正在播放但被静音'; $activeMuted += , ($pn + ' pid=' + $pid_) }
        Add-Line ("      {0,-22} pid={1,-7} {2,-16} volume={3:F4} muted={4}{5}" -f $pn, $pid_, (Get-StateText $st), $vol, $mu, $flag)
    }
}
Add-Line ""

# ---------- 4. 电平采样 ----------
Add-Line ("---------- [4] 设备实际电平（采样 " + $SampleSeconds + " 秒，峰值；0.0000 = 收到的就是静音）----------")
$peaks = @{}
foreach ($line in ([AudioProbe]::PeakScan($SampleSeconds * 1000))) {
    $f = $line -split '\|'
    if ($f[0] -eq 'P') { $peaks[$f[1]] = [double]$f[2] }
}
foreach ($e in $endpoints) {
    $id = $e[1]
    $pk = if ($peaks.ContainsKey($id)) { $peaks[$id] } else { -1 }
    $mark = ''
    if ($e[2] -eq '1') {
        $anyActive = $false
        if ($byEndpoint.ContainsKey($id)) { foreach ($s in $byEndpoint[$id]) { if ([int]$s[3] -eq 1) { $anyActive = $true } } }
        if ($anyActive -and $pk -le 0.0001) { $mark = '   <== 有应用在播放，但设备收到的是纯静音' }
    }
    Add-Line ("  {0,-9} {1,-45} 峰值={2:F4}{3}" -f $(if ($e[2] -eq '1') { '*默认*' } else { '' }), (Get-Name $id), $pk, $mark)
}
Add-Line ""

# ---------- 5. 系统开关 ----------
Add-Line "---------- [5] 系统级相关开关 ----------"
$duckKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Multimedia\Audio')
if ($duckKey) {
    $dp = $duckKey.GetValue('UserDuckingPreference')
    $map = @{ 0 = '静音所有其他声音'; 1 = '其他声音降低 80%'; 2 = '其他声音降低 50%'; 3 = '不执行任何操作（正常）' }
    $txt = if ($null -ne $dp -and $map.ContainsKey([int]$dp)) { $map[[int]$dp] } else { "$dp" }
    Add-Line ("  通信降音(UserDuckingPreference) = $dp  -> $txt")
    if ([int]$dp -ne 3) { Add-Line "      <== 该项非「不执行任何操作」：语音/会议类软件一活动就会压低或静音其他应用" }
} else {
    Add-Line "  通信降音: 未设置（默认）"
}

$psStore = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore')
if ($psStore) {
    $withVal = 0
    foreach ($k in $psStore.GetSubKeyNames()) {
        $sk = $psStore.OpenSubKey($k)
        foreach ($vn in $sk.GetValueNames()) { if ($vn -ne '') { $withVal++ } }
    }
    Add-Line ("  音量合成器持久化记录(PropertyStore)带值的条目数 = $withVal / $($psStore.SubKeyCount)")
    if ($withVal -eq 0) { Add-Line "      （=0 说明没人用音量合成器手工改过任何应用的音量，异常音量多半由程序/系统临时设置）" }
} else {
    Add-Line "  音量合成器持久化记录: 无"
}
Add-Line ""

# ---------- 6. 结论 ----------
Add-Line "================ 结论与建议 ================"
$verdictCount = 0

if ($endpoints.Count -eq 0) {
    Add-Line "  [1] 没有任何活动播放端点 —— 声卡驱动/设备未就绪。先重插 USB 声卡、重装/重启驱动，或重启 Audiosrv。"
    $verdictCount++
}

$defName = ''
if ($defaultId) { $defName = Get-Name $defaultId }
if ($defaultId -and $ExpectDefaultName -and ($defName -notlike "*$ExpectDefaultName*")) {
    Add-Line ("  [{0}] 默认播放设备不是期望的「{1}」，实际是: {2}" -f ($verdictCount + 1), $ExpectDefaultName, $defName)
    Add-Line "        -> 浏览器等只会跟随「默认设备」；默认设备若不是耳机所在通道，就会出现「播放器有声、浏览器没声」。"
    $verdictCount++
}

if ($activeZeroVol.Count -gt 0) {
    Add-Line ("  [{0}] 有应用正在播放但会话音量为 0: {1}" -f ($verdictCount + 1), ($activeZeroVol -join ', '))
    Add-Line "        -> 这就是最常见的「网页视频没声音」根因。执行 Fix-Audio.ps1 可一键恢复为 100%。"
    $verdictCount++
}

if ($activeMuted.Count -gt 0) {
    Add-Line ("  [{0}] 有应用正在播放但被静音: {1}" -f ($verdictCount + 1), ($activeMuted -join ', '))
    $verdictCount++
}

if ($verdictCount -eq 0) {
    Add-Line "  未发现音量/静音层面的异常。"
    Add-Line "  若仍然听不到声音，问题在「下游」，按顺序核对："
    Add-Line "    1) 声卡控制面板：软件播放 <耳机通道> 的推子是否拉满、是否被 Mute；该通道是否被送到「硬件输出」的 HP"
    Add-Line "    2) 面板里「硬件输出 HP」的推子/旋钮是否被拉到 0；耳机插的是不是 HP 口"
    Add-Line "    3) 拔插耳机确认插头到位；换一个耳机/音箱做交叉验证"
    Add-Line "    4) 声卡是否被其他软件以 ASIO/独占模式占用（关掉正在用 ASIO 的宿主软件再试）"
}
Add-Line ""
Add-Line "（如果这份报告里没有你要测的那个应用，先让该应用开始播放，再重新跑一次脚本。）"

Set-Content -Path $OutFile -Value $L -Encoding UTF8
Write-Host ("报告已写入: " + $OutFile)
Write-Host ($L -join "`r`n")
