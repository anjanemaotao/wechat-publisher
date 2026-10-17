---
name: obsidian-temp-notes-clear
description: 清空 Obsidian 临时仓库（D:\obsidian-vault\临时仓库）7 个笔记文件夹的内容，送回收站、留空壳、不碰 .obsidian、不动软链接。激活条件：用户消息须包含以下关键词:`清空笔记`。
disable-model-invocation: false
agent_created: true
---

# 清空 Obsidian 临时仓库

## 触发条件

用户说出`清空笔记`即视为触发（**一说到就直接执行，不需要再确认**）：

用户的明确授权（原话）：*"你直接执行不需要确认，也不需要备份，因为我里边的文件都是临时写的笔记，并不重要。"*

因此：**不要**再问"确认吗"、**不要**做备份，直接跑脚本并汇报结果。

## 唯一的硬边界（不可协商）

| 项目 | 规则 |
|---|---|
| 根目录 | **只能**是 `D:\obsidian-vault\临时仓库`。其它任何路径一律拒绝，脚本已硬编码校验，传错路径会直接抛错退出 |
| 处理对象 | `01` `02` `03` `04` `05` `06` `external-notes-temp` 共 7 个文件夹 |
| 删除粒度 | 只删这 7 个文件夹的**直接子项**（文件、图片、子文件夹，含隐藏项），**文件夹本身保留** |
| 软链接 | **一律保留，不删除**（用户明确指示：*"软链接的文件不用删除"*）。带 `ReparsePoint` 属性的条目（符号链接 / junction）脚本直接跳过：既不删链接本身，**也绝不跟随链接去删它指向的目标文件**；该条计入"跳过"，不计"失败"，也不算残留 |
| `.obsidian` | **绝对不碰**。脚本会用条目数前后对比做校验 |
| 删除方式 | 送入 **Windows 回收站**（可恢复），不做永久删除 |
| 禁止事项 | 不得修改/删除该仓库之外的任何路径；不得动 `.obsidian`；不得删软链接及其目标；不得用 `Remove-Item -Force`、`rd /s`、`rmdir` 等永久删除手段 |

## 执行方式

脚本：`scripts/clear_temp_notes.ps1`（PowerShell 7，用 `Microsoft.VisualBasic.FileIO` 送回收站；软链接走"跳过"分支）

```bash
pwsh -NoProfile -ExecutionPolicy Bypass \
  -File "C:/Users/Administrator/.workbuddy/skills/obsidian-temp-notes-clear/scripts/clear_temp_notes.ps1"
```

本机 pwsh 绝对路径：`D:\software\PowerShell\7\pwsh.exe`

有用开关：

```bash
# 只列出将删条目，不真删（排障用）
... clear_temp_notes.ps1 -DryRun

# 自定义日志目录
... clear_temp_notes.ps1 -LogDir 'D:\somewhere\logs'
```

**stdout 经常不回传**（本机已知问题），执行时把输出重定向到文件再读：

```bash
& 'D:\software\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass `
  -File 'C:\Users\Administrator\.workbuddy\skills\obsidian-temp-notes-clear\scripts\clear_temp_notes.ps1' `
  *> 'D:\software\workBuddyWorkspace\_clear.log'
```

退出码：`0` 正常 / `1` 路径校验失败 / `2` 有删除失败或 `.obsidian` 变动或目标文件夹仍有非软链接残留。**仓库里只剩软链接时不返回 2。**

## 执行后必做

1. 读日志文件（脚本最后一行会打印 `LOG_FILE=<路径>`，默认目录 `D:\software\workBuddyWorkspace\logs\obsidian-clear-notes\`）。
2. 向用户汇报三件事，简洁即可：
   - 共送回收站多少条（各文件夹分布）
   - `.obsidian` 未改动、7 个空壳文件夹已保留
   - 有无失败条目、保留了哪些软链接、日志路径
3. **不要**在仓库里留下任何日志、报告或临时文件（软链接不算此类，保持原样即可）——用户要的是干净的空壳。

## 坑与注意

- **软链接（符号链接）永远不删**：`external-notes-temp` 里存在指向 `D:\software\workBuddyWorkspace\...` 的符号链接（带 `ReparsePoint` 属性）。`Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile` 对它是无效的，而本机沙箱**禁止** `Add-Type`（编译 .NET 代码）和 COM（`New-Object -ComObject`）这类兜底手段。用户已明确指示：**软链接保持原样即可**。脚本因此把它归入"跳过"，汇总与退出码都不受影响——**不要**为它重试、也不要改用永久删除去"清干净"。
- **"Unable to find the specified file" 假报错**：`FileSystem.DeleteFile/DeleteDirectory` 在条目已成功进回收站后仍可能抛这个异常。脚本已按"事后 `Test-Path` 复核"判定真实结果，**不要**因为看到这条异常就认为删除失败或重试。
- 只读属性可能挡住删除，脚本会自动清 `ReadOnly` 属性后重试一次。
- 回收站是**按盘隔离**的，删除后条目落在 `D:\$Recycle.Bin`。要核实可配合 `recycle-bin-inspector-yashu` 技能查看。
- 该技能只在用户明确说触发词时执行；**不要**在用户只是提到"笔记""临时仓库"时误触发。
