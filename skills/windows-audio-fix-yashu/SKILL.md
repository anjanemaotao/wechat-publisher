---
name: windows-audio-fix-yashu
description: 本机（Windows 11 + IXI MEGA M2 PLUS 多通道声卡）音频「没声音」问题的专用排查与修复技能。当用户说「电脑没声音」「网页视频没声音」「浏览器播放视频听不到声音」「Edge/Chrome 放视频没声音」「音乐播放器有声音但浏览器没声音」「耳机没声」「声音输出设备不对」「音量合成器」「声卡面板路由」「放视频没有声音」等任何音频无声 / 音频异常场景时使用。覆盖：默认播放设备与多通道声卡路由诊断、应用级会话音量被置 0 / 被静音、Chromium 标签页与站点静音、Windows 通信降音、音频服务与驱动状态，并可用脚本一键把音量恢复。
agent_created: true
---

# Windows 音频无声排查与修复（本机专用）

## 用途

在本机（Windows 11 + **IXI MEGA M2 PLUS** 声卡）上定位并修复「某个应用没声音」的问题。
核心方法：**不要猜，取两个数字就能定位断点** ——「应用的会话音量」和「设备实际电平峰值」。

## 本机既定配置（判断基线）

- 声卡 **IXI MEGA M2 PLUS** 给 Windows 暴露 **4 个独立播放端点**：`Playback 1-2` / `Playback 3-4` / `Playback 5-6` / `Playback 7-8`。
- **耳机挂在 `Playback 5-6`**，因此 **Windows 默认播放设备也应该是 `Playback 5-6`**。
- 声卡控制面板链路：`软件播放 <通道>` → `硬件输出 5/6` → `HP`（耳机）；`OTG Out` 对应 7/8（手机侧）。
- 音乐播放器是 **AIMP**，输出设备设为 `Windows Default`。
- 本机还装了 **VoiceMeeter**（VAIO / AUX / VAIO3）与 **NVIDIA Broadcast** 虚拟音频设备，排查时容易被误认成"设备不对"。

> 浏览器只能跟随 Windows「默认设备」，没有手动选通道的能力；本地播放器可以自己指定通道。
> 这是「播放器有声音、浏览器没声音」这类现象的结构性来源。

## 工作流

### 第 0 步：先问清现象（一句话即可，不要展开盘问）

需要知道：**哪个应用没声音？其他应用（尤其音乐播放器）有没有声音？耳机插在声卡哪个口？**

如果用户说"只有浏览器没声音、本地播放器正常"，可以直接进入下一步 —— 这类现象 **90% 是会话音量被置 0**。

### 第 1 步：跑体检脚本

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\Diagnose-Audio.ps1"
```

可选参数：`-SampleSeconds 8`（电平采样时长）、`-ExpectDefaultName "Playback 5-6"`。

**关键：本机 stdout 经常不回传。** 脚本一定会把报告写到文件并打印路径
（默认 `%TEMP%\audio-diagnose-<时间戳>.txt`）。**必须用 Read 工具读那个文件**，不要依赖终端回显，也不要因为"没输出"就重复重跑。

### 第 2 步：按报告结论分支处理

报告末尾的「结论与建议」会直接给出判定。对照下表执行：

| 报告特征 | 根因 | 处理 |
| --- | --- | --- |
| 某应用 `state=Active` 且 `volume=0.0000`、`muted=False` | **应用音量被置 0**（最常见，浏览器网页视频无声的典型根因） | 跑 `Fix-Audio.ps1 -Process <进程名>` |
| 某应用 `state=Active` 且 `muted=True` | 该应用在音量合成器里被静音 | 同上（脚本会一并取消静音） |
| 默认设备不是 `Playback 5-6` | 默认设备被切到了别处 | 引导用户：设置 → 系统 → 声音 → 输出 → 选 `Playback 5-6` |
| 默认设备对，某应用 `Active`，但该设备 `峰值=0.0000` | 音频流是活的，送出的却是静音 → 静音发生在应用内部 | 按下面「浏览器内部静音」引导 |
| 默认设备对、应用 `Active`、`峰值>0`，但用户仍听不到 | 问题在**下游**（声卡面板 / 硬件输出 / 耳机 / ASIO 独占） | 按下面「下游无声」引导 |
| 活动端点数为 0 / 服务未 Running | 驱动或音频服务未就绪 | 重插 USB 声卡、重启 `Audiosrv`，必要时重装驱动 |
| 报告里没有目标应用 | 该应用当前没有在播放（无音频会话） | 让用户先播放，再重跑脚本 |

### 第 3 步：修复

```powershell
# 先预览（不改任何东西）
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\Fix-Audio.ps1" -WhatIfMode
# 只修一个应用
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\Fix-Audio.ps1" -Process msedge
# 修所有异常应用
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\Fix-Audio.ps1"
```

同样：**读脚本写出的报告文件**确认结果。

### 第 4 步：修复后必须复验

**判据是「设备峰值 > 0」，不是"脚本说好了"。**
若目标应用正在播放，重跑 `Diagnose-Audio.ps1`，确认默认设备那行峰值 **不为 0.0000**。
若峰值仍为 0，说明静音发生在应用内部（浏览器标签页/站点静音），继续按下面引导。

### 浏览器内部静音（脚本改不回来的情况）

按顺序引导用户自查，不要一次抛 4 条：

1. 看标签页上有没有**带斜杠的小喇叭**；`Ctrl+M` 或右键标签页 → 取消静音
2. `edge://settings/content/sound` → 确认「网站可以播放声音」是开启的
3. `edge://settings/content/mediaAutoplay` → 确认没被限制
4. 站点权限里该网站的声音是否被改成「阻止」

### 下游无声（音量与峰值都正常但仍听不到）

按顺序核对：

1. 声卡面板：`软件播放 5-6` 的推子是否拉满、是否被 Mute；是否被送到 `硬件输出 5/6`
2. 面板里 `硬件输出 HP` 的推子/旋钮是否被拉到 0；耳机插的是不是 `HP` 口
3. 拔插耳机、换一副耳机或音箱做交叉验证
4. 声卡是否被其他软件以 **ASIO / 独占模式** 占用（关掉正在用 ASIO 的宿主软件再试）

## 环境注意事项（本机特有，务必遵守）

- **stdout 常不回传**：所有脚本/命令的输出一律**重定向到文件再用 Read 读**。出现"命令成功但零输出"是常态，判断成败看**副作用**（文件是否生成），不要反复重试同一条命令。
- **`reg.exe` 被安全策略拉黑**，不允许调用，也不要用其它 shell 绕过。读注册表请用 PowerShell 的 `[Microsoft.Win32.Registry]` 或 `HKLM:` / `HKCU:` 提供程序。
- **终端命令一律用 PowerShell 7**：解释器 `D:\software\PowerShell\7\pwsh.exe`。
- 本技能的脚本**不需要管理员权限**（只操作 Core Audio 会话音量与 HKCU）。
- 写报告时区分两件事：**「脚本已执行成功」≠「声音已恢复」**。只有峰值数字能证明。

## 资源

- `scripts/Diagnose-Audio.ps1` — 完整体检：服务、活动端点、每个应用的会话音量/静音/状态、设备实际电平峰值、通信降音开关，并给出结论。
- `scripts/Fix-Audio.ps1` — 把异常应用（音量≈0 或 muted）恢复为指定音量（默认 100%）并取消静音；支持 `-Process` 定向、`-WhatIfMode` 预览、`-AllEndpoints` 全端点。
- `references/cases.md` — 已实证的案例、判据速查表、现象成因，以及已排除项清单。排查新问题前先扫一遍，避免重复走弯路。
