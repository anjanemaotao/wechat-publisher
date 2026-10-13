#Requires AutoHotkey v2.0
#SingleInstance Force
;=======================================================================
; 微信操作常驻服务 —— 由 Node.js 驱动，不要单独运行
;
; 通信：文件邮箱（_drv/ 目录）。本机实测 AHK 的 stdin/stdout 管道不通，
;      FileReadLine("*") 阻塞无响应，FileAppend("*") 收不到，故用文件轮询。
;
; 协议：Node 写 cmd.txt 一行「SEQ 指令 参数...」
;      AHK 把结果写到 res/SEQ.txt，Node 轮询该文件出现
;      错误经 try/catch 捕获写入 ERROR= 回报，绝不重试、绝不重复最大化/置前
;=======================================================================

Emit(k, v, seq) {
    global g_resDir
    FileAppend(k "=" v "`n", g_resDir "\" seq ".txt", "UTF-8-RAW")
}

GetRect(h) {
    r := Buffer(16, 0)
    DllCall("user32\GetWindowRect", "Ptr", h, "Ptr", r.Ptr)
    return {
        x: NumGet(r, 0, "Int"), y: NumGet(r, 4, "Int"),
        w: NumGet(r, 8, "Int") - NumGet(r, 0, "Int"),
        h: NumGet(r, 12, "Int") - NumGet(r, 4, "Int"),
    }
}

; 关残留弹窗，仅 FOCUS 调用 —— 关掉搜索下拉会让已算好的坐标失效
CloseStale() {
    global g_stale, g_popup
    Loop {
        p := DllCall("user32\FindWindow", "Str", g_stale, "Ptr", 0, "Ptr")
        if !p
            break
        DllCall("user32\PostMessage", "Ptr", p, "UInt", 0x0010, "UInt", 0, "Ptr", 0)
        Sleep(300)
    }
    Loop {
        p := DllCall("user32\FindWindow", "Str", g_popup, "Ptr", 0, "Ptr")
        if !p
            break
        DllCall("user32\PostMessage", "Ptr", p, "UInt", 0x0010, "UInt", 0, "Ptr", 0)
        Sleep(200)
    }
}

FindMain() {
    global g_class
    DetectHiddenWindows(true)
    for t in WinGetList() {
        if WinGetClass("ahk_id " t) != g_class
            continue
        r := GetRect(t)
        if r.w >= 800 && r.h >= 600 {
            DetectHiddenWindows(false)
            return t
        }
    }
    DetectHiddenWindows(false)
    for _, exe in ["Weixin.exe", "WeChat.exe"] {
        best := 0, bestArea := 0
        for t in WinGetList("ahk_exe " exe) {
            if !DllCall("user32\IsWindowVisible", "Ptr", t, "Int")
                continue
            r := GetRect(t)
            if r.w * r.h > bestArea {
                bestArea := r.w * r.h
                best := t
            }
        }
        if best
            return best
    }
    return 0
}

;---- FOCUS ----
DoFocus() {
    global g_hwnd
    CloseStale()
    g_hwnd := FindMain()
    if !g_hwnd
        throw Error("未找到微信主窗口（类名 " g_class "）")

    id := "ahk_id " g_hwnd
    try {
        WinRestore(id)
        WinMaximize(id)
        WinActivate(id)
        WinWaitActive(id, , 2)
        if DllCall("user32\GetForegroundWindow", "Ptr") != g_hwnd {
            DllCall("user32\BringWindowToTop", "Ptr", g_hwnd)
            WinActivate(id)
            WinWaitActive(id, , 1)
        }
    } catch as e {
        throw Error("置前微信失败: " e.Message)
    }
    Sleep(250)
    Emit("STEP", "FOCUSED", g_seq)
    Emit("WECHAT_SIZE", GetRect(g_hwnd).w "x" GetRect(g_hwnd).h, g_seq)
}

;---- CLICK：只点，不碰窗口状态 ----
DoClick(x, y, ms) {
    Click x, y
    Sleep(ms)
    Emit("STEP", "CLICKED", g_seq)
    Emit("CLICKED_X", x, g_seq)
    Emit("CLICKED_Y", y, g_seq)
}

;---- PASTE：点搜索框 → 粘贴 → 等搜索结果
DoPaste(x, y, name) {
    global g_group, g_waitSearch
    g_group := name
    Click x, y
    Sleep(60)
    A_Clipboard := name
    ClipWait 0.5
    Send "^v"
    Sleep(g_waitSearch)
    Emit("STEP", "SEARCHED", g_seq)
}

;================================================================ 主循环

; ★目录必须由脚本自身位置推导（A_ScriptDir），绝不能硬编码绝对路径。
;   历史踩坑：本行曾硬编码 ...\skills\wechat-qrcode\scripts\_drv，而 skill 目录
;   早已改名成 wechat-qrcode-yashu。AHK 于是把 up.txt 写进一个没人读的旧目录，
;   Node 侧轮询自己脚本目录下的 up.txt 永远等不到 —— 表现为「脚本卡住、没反应」，
;   且 stderr 全空、无任何报错，极难定位。A_ScriptDir 随文件走，改名/搬家都不会再错。
g_drvDir := A_ScriptDir "\_drv"
g_resDir := g_drvDir "\res"
g_cmdFile := g_drvDir "\cmd.txt"
g_hwnd := 0
g_class := "Qt51514QWindowIcon"
g_stale := "MMUIRenderSubWindowHW1"
g_popup := "Qt51514QWindowToolSaveBits"
g_waitSearch := 2000
g_waitPanel := 1500
g_group := ""
g_seq := ""

DirCreate(g_resDir)
if FileExist(g_cmdFile)
    FileDelete(g_cmdFile)
Loop Files, g_resDir "\*.txt", "FR"
    FileDelete(A_LoopFileFullPath)
FileAppend("UP", g_drvDir "\up.txt", "UTF-8-RAW")

while true {
    if !FileExist(g_cmdFile) {
        Sleep(300)
        continue
    }
    line := Trim(FileRead(g_cmdFile, "UTF-8"))
    FileDelete(g_cmdFile)
    if !line
        continue

    ; 行格式：SEQ<空格>指令 参数...
    ; 注意别用 StrSplit(line, " ", 2) 想切两段 —— 第三个参数是 maxParts（最多切几段），
    ; 传 2 会只得到 2 段且 sp[2] 越界。手动按首个空格切。
    i := InStr(line, " ")
    if i = 0 {
        g_seq := line
        rest := ""
    } else {
        g_seq := SubStr(line, 1, i - 1)
        rest := SubStr(line, i + 1)
    }
    parts := StrSplit(rest, " ")
    if !parts.Length
        continue
    cmd := parts[1]

    try {
        switch cmd {
            case "CONFIG":
                g_class := parts[2]
                g_stale := parts[3]
                g_popup := parts[4]
                g_waitSearch := Number(parts[5])
                g_waitPanel := Number(parts[6])
                Emit("STEP", "CONFIGURED", g_seq)
            case "PING":
                Emit("STEP", "PONG", g_seq)
            case "FOCUS":
                DoFocus()
            case "CLICK":
                DoClick(Number(parts[2]), Number(parts[3]), Number(parts[4]))
            case "PASTE":
                ; 群名可能含空格，第 4 段起重新拼回。
                ; AHK v2 无 StrJoin 也无 Array.Join()，只能用 .= 循环拼。
                ; 注意 for 第二变量才是值，第一变量是索引。
                nm := ""
                for idx, val in parts {
                    if idx < 4
                        continue
                    if nm != ""
                        nm .= " "
                    nm .= val
                }
                if nm = ""
                    nm := g_group
                DoPaste(Number(parts[2]), Number(parts[3]), nm)
            case "QUIT":
                Emit("STEP", "BYE", g_seq)
                ExitApp 0
            default:
                throw Error("未知指令: " cmd)
        }
        Emit("END", "OK", g_seq)
    } catch as e {
        ; 错误只回报不重试，现场保持原样便于排查
        ; v2 错误对象属性是 .Line / .What / .Message / .File，没有 .WhatLine（那是 v1 语法）
        Emit("ERROR", e.What " | " e.Message " | 行 " e.Line, g_seq)
        Emit("END", "FAULT", g_seq)
    }
    FileAppend("1", g_drvDir "\up.txt", "UTF-8-RAW")
}