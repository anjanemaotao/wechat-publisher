# Fix-Audio.ps1
# 用途：修复「某个应用没声音」的最常见根因——该应用的 Windows 会话音量被置 0 或被静音。
#       典型场景：Edge/Chrome 网页视频没声音，但本地音乐播放器正常。
#
# 用法：
#   # 1) 预览：列出所有应用的会话音量与静音状态，不做任何修改
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\Fix-Audio.ps1 -WhatIfMode
#   # 2) 修复所有异常应用（音量≈0 或 muted 的），恢复为 100%
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\Fix-Audio.ps1
#   # 3) 只修一个应用（进程名，不带 .exe，大小写不敏感）
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\Fix-Audio.ps1 -Process msedge
#   # 4) 强制把某应用设为指定音量（0~1）
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\Fix-Audio.ps1 -Process msedge -Volume 0.6 -Force
#   # 5) 处理所有活动端点上的会话（默认只处理 Windows 默认播放设备）
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\Fix-Audio.ps1 -AllEndpoints
#
# 注意：目标应用必须已经在播放（有活动音频会话），否则会话列表里看不到它。

param(
    [string[]]$Process = @(),
    [double]$Volume = 1.0,
    [switch]$Force,
    [switch]$AllEndpoints,
    [switch]$WhatIfMode,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
if ($Volume -lt 0 -or $Volume -gt 1) { throw "-Volume 取值范围 0 ~ 1" }
if (-not $OutFile) {
    $OutFile = Join-Path $env:TEMP ("audio-fix-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")
}

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class AudioRepair
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

    static Guid IID_Mgr = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");

    static List<KeyValuePair<string, IMMDevice>> Targets(bool allEndpoints)
    {
        var targets = new List<KeyValuePair<string, IMMDevice>>();
        var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        if (allEndpoints)
        {
            IMMDeviceCollection coll;
            if (en.EnumAudioEndpoints(0, 1, out coll) == 0)
            {
                int n; coll.GetCount(out n);
                for (int i = 0; i < n; i++)
                {
                    IMMDevice d; coll.Item(i, out d);
                    string id = null; d.GetId(out id);
                    targets.Add(new KeyValuePair<string, IMMDevice>(id, d));
                }
            }
        }
        else
        {
            IMMDevice d;
            if (en.GetDefaultAudioEndpoint(0, 0, out d) == 0)
            {
                string id = null; d.GetId(out id);
                targets.Add(new KeyValuePair<string, IMMDevice>(id, d));
            }
        }
        return targets;
    }

    // 返回每条: S|deviceId|pid|state|volume|muted
    public static List<string> List(bool allEndpoints)
    {
        var res = new List<string>();
        foreach (var kv in Targets(allEndpoints))
        {
            object o; Guid g = IID_Mgr;
            if (kv.Value.Activate(ref g, 0, IntPtr.Zero, out o) != 0) continue;
            var mgr = (IAudioSessionManager2)o;
            IAudioSessionEnumerator se;
            if (mgr.GetSessionEnumerator(out se) != 0) continue;
            int n; se.GetCount(out n);
            for (int j = 0; j < n; j++)
            {
                IAudioSessionControl ctl; se.GetSession(j, out ctl);
                var c2 = ctl as IAudioSessionControl2;
                var vol = ctl as ISimpleAudioVolume;
                if (c2 == null || vol == null) continue;
                int pid = -1; try { c2.GetProcessId(out pid); } catch { }
                int st = -1; try { ctl.GetState(out st); } catch { }
                float v = -1; try { vol.GetMasterVolume(out v); } catch { }
                bool mu = false; try { vol.GetMute(out mu); } catch { }
                res.Add("S|" + kv.Key + "|" + pid + "|" + st + "|" + v.ToString("F4") + "|" + mu);
            }
        }
        return res;
    }

    // 对指定设备上的指定进程会话设置音量并取消静音；返回结果文本
    public static string Set(string deviceId, int pid, double volume)
    {
        foreach (var kv in Targets(true))
        {
            if (kv.Key != deviceId) continue;
            object o; Guid g = IID_Mgr;
            if (kv.Value.Activate(ref g, 0, IntPtr.Zero, out o) != 0) return "激活设备失败";
            var mgr = (IAudioSessionManager2)o;
            IAudioSessionEnumerator se;
            if (mgr.GetSessionEnumerator(out se) != 0) return "无会话";
            int n; se.GetCount(out n);
            for (int j = 0; j < n; j++)
            {
                IAudioSessionControl ctl; se.GetSession(j, out ctl);
                var c2 = ctl as IAudioSessionControl2;
                var vol = ctl as ISimpleAudioVolume;
                if (c2 == null || vol == null) continue;
                int p = -1; try { c2.GetProcessId(out p); } catch { }
                if (p != pid) continue;
                Guid none = Guid.Empty;
                int h1 = vol.SetMasterVolume((float)volume, ref none);
                int h2 = vol.SetMute(false, ref none);
                float nv = -1; try { vol.GetMasterVolume(out nv); } catch { }
                bool nm = true; try { vol.GetMute(out nm); } catch { }
                return string.Format("hr=0x{0:X8}/0x{1:X8} -> volume={2:F4} muted={3}", h1, h2, nv, nm);
            }
        }
        return "未找到该设备上的目标会话";
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp | Out-Null

function Get-ProcName($p) {
    if ($p -le 0) { return 'Idle/系统' }
    try { return (Get-Process -Id $p -ErrorAction Stop).ProcessName } catch { return ('pid' + $p) }
}

$want = @($Process | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
$doFix = -not $WhatIfMode

$L = New-Object System.Collections.Generic.List[string]
$L.Add("================ 应用会话音量修复 ================")
$L.Add("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$L.Add("模式: " + $(if ($WhatIfMode) { '预览（不做任何修改）' } else { '执行修复' }))
$L.Add("目标音量: " + $Volume.ToString("F2") + " ; 强制全部: " + [bool]$Force + " ; 全部端点: " + [bool]$AllEndpoints)
if ($want.Count -gt 0) { $L.Add("只处理进程: " + ($want -join ', ')) }
$L.Add("")

$rows = [AudioRepair]::List([bool]$AllEndpoints) | ForEach-Object { , ($_ -split '\|') }
if ($rows.Count -eq 0) {
    $L.Add("未枚举到任何音频会话 —— 请先让目标应用开始播放（有声音产生）后重试。")
} else {
    $fixed = 0; $skipped = 0
    foreach ($r in $rows) {
        $dev = $r[1]; $pid_ = [int]$r[2]; $st = [int]$r[3]; $vol = [double]$r[4]; $mu = ($r[5] -eq 'True')
        $pn = Get-ProcName $pid_
        $stateTxt = switch ($st) { 0 { 'Idle' } 1 { 'Active' } 2 { 'Expired' } default { "s=$st" } }

        $nameOk = ($want.Count -eq 0) -or ($want -contains $pn.ToLower())
        $bad = ($vol -ge 0 -and $vol -lt 0.0001) -or $mu
        $needFix = $nameOk -and ($Force -or $bad)

        $mark = ''
        if ($bad) { $mark = '  <== 异常：音量≈0 或 已静音' }
        $L.Add(("{0,-22} pid={1,-7} {2,-8} volume={3:F4} muted={4}{5}" -f $pn, $pid_, $stateTxt, $vol, $mu, $mark))

        if (-not $needFix) { $skipped++; continue }

        if (-not $doFix) { $L.Add("        -> [预览] 将被设为 volume=" + $Volume.ToString("F2") + " muted=false"); $fixed++; continue }

        $res = [AudioRepair]::Set($dev, $pid_, $Volume)
        $L.Add("        -> 已修复: " + $res)
        $fixed++
    }
    $L.Add("")
    $L.Add($(if ($doFix) { "已修复会话数: $fixed ; 未处理: $skipped" } else { "待修复会话数(预览): $fixed ; 未处理: $skipped" }))
}

$L.Add("")
$L.Add("---- 提示 ----")
$L.Add("1) 若预览显示某浏览器进程 volume≈0 但 muted=false，正是「网页视频没声音」的典型根因，去掉 -WhatIfMode 再跑一次即可。")
$L.Add("2) 若修复后音量又变回 0，说明是浏览器内部的「标签页/站点静音」在起作用：")
$L.Add("   在浏览器里 Ctrl+M 或右键标签页取消静音，并检查 站点设置 -> 声音 是否被改为「阻止」。")
$L.Add("3) 若清单里根本没有目标应用，说明它当前没有在播放，先播放再跑。")

Set-Content -Path $OutFile -Value $L -Encoding UTF8
Write-Host ("报告已写入: " + $OutFile)
Write-Host ($L -join "`r`n")
