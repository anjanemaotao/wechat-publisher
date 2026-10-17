#Requires -Version 7.0
<#
.SYNOPSIS
    清空 Obsidian「临时仓库」中指定子文件夹的内容，全部送入 Windows 回收站。

.DESCRIPTION
    硬编码安全边界：
      - 只允许操作根目录 D:\obsidian-vault\临时仓库（传入其它路径直接抛错退出）
      - 只处理 01 02 03 04 05 06 external-notes-temp 这 7 个文件夹
      - 只删除这 7 个文件夹的「直接子项」，文件夹本身保留
      - .obsidian 及任何其它路径一律不碰
      - 删除走回收站（可恢复），不做永久删除
      - 软链接（ReparsePoint）一律保留，不删除（用户明确指示：软链接的文件不用删除）

.PARAMETER VaultPath
    目标仓库根目录。只接受默认值，传其它值会被拒绝。

.PARAMETER DryRun
    只列出将要删除的条目，不实际删除。

.PARAMETER LogDir
    日志输出目录，默认 D:\software\workBuddyWorkspace\logs\obsidian-clear-notes

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\clear_temp_notes.ps1
#>
[CmdletBinding()]
param(
    [string]$VaultPath = 'D:\obsidian-vault\临时仓库',
    [switch]$DryRun,
    [string]$LogDir = 'D:\software\workBuddyWorkspace\logs\obsidian-clear-notes'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 安全常量
$AllowedRoot   = 'D:\obsidian-vault\临时仓库'
$TargetFolders = @('01', '02', '03', '04', '05', '06', 'external-notes-temp')
$ProtectedDirs = @('.obsidian')

# ---------------------------------------------------------------- 日志
$lines = [System.Collections.Generic.List[string]]::new()
function Write-Log([string]$msg) {
    $lines.Add($msg)
    Write-Host $msg
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $LogFile = Join-Path $LogDir "clear-notes-$stamp.txt"
} catch {
    $LogDir = Join-Path $env:TEMP 'obsidian-clear-notes'
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $LogFile = Join-Path $LogDir "clear-notes-$stamp.txt"
}

function Normalize-FullPath([string]$p) {
    $full = [System.IO.Path]::GetFullPath($p)
    return $full.TrimEnd([char]'\', [char]'/')
}

# 软链接 / junction 判定：带 ReparsePoint 属性的条目一律保留，不删
function Test-IsLink([System.IO.FileSystemInfo]$item) {
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# ---------------------------------------------------------------- 1. 校验根目录
try {
    $root    = Normalize-FullPath $VaultPath
    $allowed = Normalize-FullPath $AllowedRoot
} catch {
    $root = ''
    $allowed = Normalize-FullPath $AllowedRoot
}

Write-Log "=== 清空笔记（送入回收站） $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Write-Log "目标根目录 : $root"
Write-Log "允许根目录 : $allowed"
Write-Log "DryRun     : $([bool]$DryRun)"
Write-Log ""

if ($root -ne $allowed) {
    Write-Log "!! 拒绝执行：目标根目录与允许目录不一致。本技能只允许操作 $allowed"
    $lines | Set-Content -LiteralPath $LogFile -Encoding utf8
    throw "路径校验失败：$root != $allowed"
}
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Log "!! 拒绝执行：$root 不存在或不是文件夹"
    $lines | Set-Content -LiteralPath $LogFile -Encoding utf8
    throw "目标根目录不存在：$root"
}

# ---------------------------------------------------------------- 2. 记录 .obsidian 基线
$obsidianPath = Join-Path $root '.obsidian'
$obsidianBefore = -1
if (Test-Path -LiteralPath $obsidianPath -PathType Container) {
    $obsidianBefore = @(Get-ChildItem -LiteralPath $obsidianPath -Recurse -Force -ErrorAction SilentlyContinue).Count
}
Write-Log "受保护目录 .obsidian 基线条目数: $obsidianBefore"
Write-Log ""

# ---------------------------------------------------------------- 3. 删除引擎
Add-Type -AssemblyName Microsoft.VisualBasic
$UIOpt = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
$RbOpt = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin

$stat = [ordered]@{}
$failed = [System.Collections.Generic.List[string]]::new()
$keptLinks = [System.Collections.Generic.List[string]]::new()

function Send-ToRecycleBin([System.IO.FileSystemInfo]$item) {
    if ($item.PSIsContainer) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($item.FullName, $UIOpt, $RbOpt)
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($item.FullName, $UIOpt, $RbOpt)
    }
}

function Remove-ItemToRecycleBin([System.IO.FileSystemInfo]$item) {
    # 返回 'ok' | 'missing' | 'failed'
    if (-not (Test-Path -LiteralPath $item.FullName)) { return 'missing' }
    try {
        Send-ToRecycleBin $item
    } catch {
        # 已知怪癖：条目其实已进回收站，但包装器仍抛 "Unable to find the specified file"
        if (-not (Test-Path -LiteralPath $item.FullName)) { return 'ok' }

        # 只读属性可能挡住删除，清掉属性后重试一次
        try {
            $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            Send-ToRecycleBin $item
        } catch { }
    }
    if (-not (Test-Path -LiteralPath $item.FullName)) { return 'ok' }
    return 'failed'
}

# ---------------------------------------------------------------- 4. 逐个文件夹清空
foreach ($name in $TargetFolders) {
    $dir = Join-Path $root $name

    # 双重保险：绝不允许越出根目录，也绝不允许踩到受保护目录
    $dirFull = Normalize-FullPath $dir
    if (-not $dirFull.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "!! 跳过 $name ：解析后路径越界（$dirFull）"
        continue
    }
    if ($ProtectedDirs -contains $name) {
        Write-Log "!! 跳过 $name ：属受保护目录"
        continue
    }

    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Log "[$name] 不存在，跳过"
        $stat[$name] = [PSCustomObject]@{ Deleted = 0; Skipped = 0; Failed = 0 }
        continue
    }

    Write-Log "[$name] 开始处理 $dirFull"
    $deleted = 0; $skipped = 0; $fail = 0

    $children = @(Get-ChildItem -LiteralPath $dirFull -Force -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) { Write-Log "  (空)" }

    foreach ($child in $children) {
        $childFull = Normalize-FullPath $child.FullName
        if (-not $childFull.StartsWith($dirFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "  !! 越界，跳过: $childFull"
            $fail++
            continue
        }

        # 软链接（符号链接 / junction）：按用户明确指示一律保留，既不删链接本身，
        # 也不跟随链接去删它指向的目标文件。
        if (Test-IsLink $child) {
            Write-Log "  保留软链接（不删除）: $childFull"
            $keptLinks.Add($childFull)
            $skipped++
            continue
        }

        if ($DryRun) {
            Write-Log "  [dry-run] 将删除: $childFull"
            $deleted++
            continue
        }

        $r = Remove-ItemToRecycleBin $child
        switch ($r) {
            'ok'      { Write-Log "  已送回收站: $childFull"; $deleted++ }
            'missing' { Write-Log "  已不存在: $childFull"; $skipped++ }
            'failed'  { Write-Log "  !! 删除失败: $childFull"; $fail++; $failed.Add($childFull) }
        }
    }

    Write-Log "[$name] 完成：删除 $deleted / 跳过 $skipped / 失败 $fail"
    Write-Log ""
    $stat[$name] = [PSCustomObject]@{ Deleted = $deleted; Skipped = $skipped; Failed = $fail }
}

# ---------------------------------------------------------------- 5. 收尾校验
$obsidianAfter = -1
if (Test-Path -LiteralPath $obsidianPath -PathType Container) {
    $obsidianAfter = @(Get-ChildItem -LiteralPath $obsidianPath -Recurse -Force -ErrorAction SilentlyContinue).Count
}
$obsidianOk = ($obsidianBefore -eq $obsidianAfter)

$totalDel = ($stat.Values | Measure-Object -Property Deleted -Sum).Sum
$totalFail = ($stat.Values | Measure-Object -Property Failed -Sum).Sum

Write-Log "=== 汇总 ==="
foreach ($k in $stat.Keys) {
    $v = $stat[$k]
    Write-Log ("{0,-20} 删除 {1,-5} 跳过 {2,-5} 失败 {3}" -f $k, $v.Deleted, $v.Skipped, $v.Failed)
}
Write-Log ""
Write-Log "总计送入回收站条目: $totalDel"
Write-Log "失败条目           : $totalFail"
Write-Log ".obsidian 条目数   : $obsidianBefore -> $obsidianAfter  ($(if ($obsidianOk) { '未改动 OK' } else { '!! 发生变化，请检查' }))"
Write-Log "保留的软链接条目   : $($keptLinks.Count)（按用户指示不删除）"
foreach ($l in $keptLinks) { Write-Log "  - $l" }

# 统计残留时排除软链接：软链接属于「应保留」，不算残留
$leftInTargets = 0
$leftLinks = 0
foreach ($name in $TargetFolders) {
    $d = Join-Path $root $name
    if (Test-Path -LiteralPath $d -PathType Container) {
        $rest = @(Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue)
        foreach ($r in $rest) {
            if (Test-IsLink $r) { $leftLinks++; continue }
            $leftInTargets++
        }
    }
}
Write-Log "7 个目标文件夹内剩余条目: $leftInTargets $(if ($DryRun) { '(dry-run，未真删)' } elseif ($leftInTargets -eq 0) { 'OK' } else { '!! 仍有残留' })"
Write-Log "  其中软链接（保留）      : $leftLinks"
Write-Log "7 个文件夹本身          : $((@($TargetFolders | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Container })).Count)/7 保留"
Write-Log ""
Write-Log "日志: $LogFile"

$lines | Set-Content -LiteralPath $LogFile -Encoding utf8
Write-Host ""
Write-Host "LOG_FILE=$LogFile"
if ($totalFail -gt 0 -or -not $obsidianOk -or (-not $DryRun -and $leftInTargets -gt 0)) { exit 2 }
exit 0
