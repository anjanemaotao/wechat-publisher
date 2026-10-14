# 案例库与判据

排查新问题前先扫一遍，避免重复走弯路。所有内容均为本机实测得出，不是通用猜测。

---

## 判据速查表（两个数字定断点）

取两个数字：**应用的会话音量**（`volume` / `muted`）与**设备实际电平峰值**（`峰值`）。

| 会话音量 | muted | 设备峰值 | 结论 |
| --- | --- | --- | --- |
| 0.0000 | False | 0.0000 | **应用音量被置 0** —— 最常见的「浏览器没声音」根因。用 Fix-Audio.ps1 修复 |
| 任意 | True | 0.0000 | 该应用在音量合成器里被静音。Fix-Audio.ps1 会一并取消静音 |
| 1.0000 | False | 0.0000 | 音量正常但送出的仍是静音 → 静音发生在**应用内部**（浏览器标签页/站点静音） |
| 1.0000 | False | > 0.0000 | 数字通路完全正常 → 问题在**下游**（声卡面板路由 / HP 推子 / 耳机 / ASIO 独占） |
| — | — | 无任何活动端点 | 驱动或音频服务未就绪 |

> **判断"修好了"的唯一标准是峰值 > 0**，不是脚本退出码，也不是"看起来改了"。

---

## 案例 1：Edge 网页视频无声，音乐播放器正常（2026-10-14，已解决）

### 现象

- B 站网页视频：网页播放器自己的声音开关是开的，但完全听不到声音。
- 本地音乐播放器 **AIMP** 放音乐：正常出声。
- 声卡控制面板显示声音路由到 `Playback 5-6`（= 耳机所在通道）。

### 实测证据

| 检查项 | 实测值 |
| --- | --- |
| Windows 默认播放设备 | `{aed17973…}` = **Playback 5-6**（IXI MEGA M2 PLUS）→ 与耳机一致，本来就对 |
| AIMP 会话 | state=Idle，volume=**1.0000**，muted=False |
| **msedge 会话** | state=**Active（正在播放）**，volume=**0.0000**，muted=False |
| 默认设备峰值（Edge 播放中，采样 6 秒 × 每 200ms） | **0.0000（全程纯静音）** |
| 把 msedge 音量改回 1.0 后重新采样 | 0.128 → 0.226 → 0.351 → 最大值 **0.5762** |
| 修复后连续 12 秒复查 | volume 稳定 1.000，未被打回 0 |

### 根因

**Edge 在 Windows 里的「应用音量」被压到了 0。**
音频流处于"正在播放"状态，但送往声卡的是纯静音 —— 所以声卡面板没有电平、耳机没声。

### 为什么"只有浏览器这样"

AIMP 与 Edge 用的是**同一个设备**（Windows 默认 = Playback 5-6），差别不在通道，只在音量。
Chromium 系浏览器（Edge / Chrome）实现「标签页 / 站点静音」的方式，是**把该音频流的音量设为 0**，
而**不会**点亮系统那个「静音」标志 —— 与实测的 `muted=False + volume=0.0000` 完全吻合。
所以网页播放器自己的开关是开的，却一点声音都没有。

### 该案例中已被逐项排除（附排除依据）

| 被排除项 | 依据 |
| --- | --- |
| 声道路由 / 通道设置 | 默认设备就是 Playback 5-6，与耳机一致 |
| 声卡面板路由 | 软件播放 5-6 → 硬件输出 5/6 → HP，面板设置正确 |
| 耳机 / 功放硬件 | AIMP 能正常出声，物理通路无问题 |
| 浏览器网站声音权限 | Edge `Preferences` 的 `content_settings.exceptions.sound` 为空，未屏蔽任何站点；`default_content_setting_values` 里也没有 `sound:2` |
| 应用级「输出设备」被指到别处 | 注册表 `PolicyConfig\PropertyStore` 中针对 msedge 的条目都只有默认值、无任何持久化音量/设备覆盖 |
| Windows 通信降音 | `UserDuckingPreference = 3`（= 不执行任何操作） |
| 音频服务 | `Audiosrv` / `AudioEndpointBuilder` 均 Running |
| AIMP 的独占模式占用 | 修复时 AIMP 会话为 Idle，未占用设备 |

### 修复动作

把 msedge 会话的 master volume 从 0 设为 1.0（不需要重启 Edge，立即生效）。

---

## 为什么"音量被置 0 但 muted=False"这个组合很关键

Windows 的「静音」和「音量为 0」是**两个独立的东西**：

- **muted=True** = 有人点了音量合成器里的静音图标（会持久化到注册表）。
- **volume=0.0000 + muted=False** = 音量被程序/系统**临时**设成了 0，静音标志没动。

本机注册表 `PropertyStore` 全部 800+ 个子键里**带值（Volume/Mute）的条目数为 0**，
说明**从来没有人用音量合成器手工改过任何应用的音量**。
因此出现 `volume=0.0000` 时，几乎可以确定是**程序侧（浏览器标签页/站点静音）或系统临时降音**造成的，
而不是用户的持久化设置 —— 这也解释了为什么它"昨天还好、今天就没了"，且重启 Edge 后可能又正常。

---

## 关于本机的多通道声卡（容易误判的地方）

- IXI MEGA M2 PLUS 会创建**多个同名端点**（例如多个条目都叫 `Playback 5-6`），
  它们是不同驱动版本 / 不同端口留下的历史记录（`DeviceState` 非 1 的都不是当前活动端点）。
  排查时**只看 `DeviceState` 为活动的那个**，不要被重名条目误导。
- 驱动为每对通道、每种采样率生成独立的 KS pin（`pcm_out_XX_*_sdY_44100/48000`），
  注册表里会出现大量按"端点实例 + 应用"的历史记录，**这些不是"把应用指到别的设备"的配置**，不用管。
- 面板里 `Playback 5-6` 这条"软件播放"对应 Windows 混音器的 5-6 通道；
  `硬件输出` 只有 `HP` 与 `OTG Out` 两项，耳机接 `HP`。

---

## 未证实的假设（下次遇到再验证，不要当结论用）

以下情况在本机**尚未出现过**，属于合理怀疑方向，仅在实际命中相应证据时才采用：

- 浏览器标签页 / 站点静音（预期表现：Fix-Audio 改回 1.0 后又自动变回 0，且标签页有静音图标）。
- 声卡被宿主软件以 ASIO / 独占模式占用（预期表现：会话音量正常、峰值也为 0，但看不到明显静音源）。
- 某些"直播 / 录屏 / 语音输入"类软件会临时接管或压低其他应用音量。
  本机存在一个 `voiceinput`（chatterfly 组件）会持有系统声音会话，可在排查时留意。

---

## 常用命令

```powershell
# 完整体检（报告写到 %TEMP%，用 Read 读该文件）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Diagnose-Audio.ps1

# 预览异常应用
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Fix-Audio.ps1 -WhatIfMode

# 只修 Edge
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Fix-Audio.ps1 -Process msedge

# 设为指定音量 / 处理全部端点
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Fix-Audio.ps1 -Process msedge -Volume 0.6 -Force -AllEndpoints
```

**注意**：`reg.exe` 在本机被安全策略拉黑，不要使用；读注册表请走 PowerShell 的 `HKLM:` / `HKCU:` 或 `[Microsoft.Win32.Registry]`。
