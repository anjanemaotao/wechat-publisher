/**
 * AHK 常驻服务客户端（文件邮箱协议）
 *
 * 常驻化原因：原来每步都 execFileSync 起一个 AHK 进程，冷启动 3~8 秒，
 * 一个流程调 3 次 = 17 秒，占总耗时 45%。
 *
 * 为何走文件而非管道：本机实测 AHK 的 stdin/stdout 双向管道都不通
 *   - FileReadLine("*") 阻塞无响应
 *   - FileAppend(..., "*") 即使 Start-Process -RedirectStandardOutput 也收不到
 *   - AHK 写普通文件正常
 *
 * 失败即停：指令返回 FAULT 时抛异常，由上层处理，这里绝不重试。
 */
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const AHK_EXE = process.env.AHK_PATH
  || "C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe";
const DRIVER = path.join(__dirname, "wechat-driver.ahk");
const DRV_DIR = path.join(__dirname, "_drv");
const RES_DIR = path.join(DRV_DIR, "res");
const CMD_FILE = path.join(DRV_DIR, "cmd.txt");
const UP_FILE = path.join(DRV_DIR, "up.txt");

const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));

class WechatDriver {
  constructor() {
    this.proc = null;
    this.seq = 0;
    this.alive = false;
  }

  /** 启动服务进程（不阻塞等就绪，发指令时自然同步） */
  async start(cfg) {
    if (this.alive) return;
    if (!fs.existsSync(AHK_EXE)) throw new Error(`没找到 AutoHotkey v2：${AHK_EXE}`);

    fs.mkdirSync(RES_DIR, { recursive: true });
    for (const f of [CMD_FILE, UP_FILE]) {
      if (fs.existsSync(f)) fs.unlinkSync(f);
    }
    for (const f of fs.readdirSync(RES_DIR)) {
      if (f.endsWith(".txt")) fs.unlinkSync(path.join(RES_DIR, f));
    }

    // 故意不加 /ErrorStdOut 或 --ErrorStdOut：
    //   /ErrorStdOut  —— / 被 AHK 当路径分隔符，解析成 <cwd>/ErrorStdOut，
    //                    找不到就弹「Script file not found」对话框，进程永不退出；
    //   --ErrorStdOut —— AHK v2 不认，直接当成要运行的脚本名，同样弹错。
    //   两种都试过，都会卡死并弹出 GUI 框（用户可见）。
    // 改为不传开关：语法错改为靠「5 秒内 up.txt 无 UP」快速失败来暴露，
    // 见下方 ready 判定。
    this.proc = spawn(AHK_EXE, [DRIVER],
      { stdio: ["ignore", "ignore", "pipe"], windowsHide: true });
    this.stderr = "";
    this.proc.stderr.on("data", (d) => { this.stderr += d.toString(); });
    this.proc.on("exit", () => { this.alive = false; });
    this.alive = true;

    // 等服务起来（写 up.txt 表示初始化完成）。
    // 必须超时就抛错：静默放行会走到下面的 _send，而 _send 要再干等 60 秒才报错，
    // 表现为「脚本卡住没反应」，排障时看不出到底是没起来还是起来后卡住。
    let ready = false;
    for (let i = 0; i < 100; i++) {
      if (fs.existsSync(UP_FILE) && fs.readFileSync(UP_FILE, "utf8").includes("UP")) { ready = true; break; }
      if (!this.alive) throw new Error("AHK 服务启动即退出：" + this.stderr);
      await sleepMs(50);
    }
    if (!ready) {
      this.killNow();   // 弹窗场景下进程仍活着，不杀会一直挡在桌面上
      throw new Error(`AHK 服务 5 秒内未就绪（up.txt 无 UP）。`
        + (this.stderr ? `stderr: ${this.stderr}` : "stderr 为空，多半是 AHK 弹了 GUI 对话框把进程卡住了。"));
    }

    const w = cfg["窗口识别"];
    const t = cfg["等待毫秒"];
    await this._send(`CONFIG ${w["微信主窗口类名"]} ${w["残留二维码弹窗类名"]} `
      + `${w["搜索下拉弹窗类名"]} ${t["等搜索结果"]} ${t["等聊天信息面板"]}`);
  }

  /** 发一条指令，轮询 res/SEQ.txt 出现 */
  async _send(cmd, timeoutMs = 60000) {
    if (!this.alive) throw new Error("AHK 服务未运行");
    this.seq += 1;
    const mySeq = this.seq;
    const resFile = path.join(RES_DIR, `${mySeq}.txt`);
    if (fs.existsSync(resFile)) fs.unlinkSync(resFile);

    fs.writeFileSync(CMD_FILE, `${mySeq} ${cmd}`, "utf8");

    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      if (fs.existsSync(resFile)) {
        await sleepMs(50);   // 等 AHK 把 END= 写完
        const txt = fs.readFileSync(resFile, "utf8");
        const kv = {};
        let end = "";
        for (const line of txt.split(/\r?\n/)) {
          const eq = line.indexOf("=");
          if (eq <= 0) continue;
          const k = line.slice(0, eq), v = line.slice(eq + 1);
          if (k === "END") { end = v; continue; }
          kv[k] = v;
        }
        fs.unlinkSync(resFile);
        if (end === "FAULT" || kv.ERROR) throw new Error(kv.ERROR || "AHK 指令失败");
        return kv;
      }
      if (!this.alive) throw new Error("AHK 服务已退出：" + this.stderr);
      await sleepMs(50);
    }
    throw new Error(`AHK 指令超时(${timeoutMs}ms)：${cmd}`
      + (this.stderr ? `\n   stderr: ${this.stderr}` : ""));
  }

  focus() { return this._send("FOCUS"); }
  click(x, y, ms) { return this._send(`CLICK ${x} ${y} ${ms}`); }
  paste(x, y, name) { return this._send(`PASTE ${x} ${y} ${name}`); }

  quit() {
    if (!this.alive) return;
    try { fs.writeFileSync(CMD_FILE, `${++this.seq} QUIT`, "utf8"); } catch { /* 已断 */ }
    setTimeout(() => { try { this.proc.kill(); } catch { /* 已死 */ } }, 200);
    this.alive = false;
  }

  /** 兜底杀进程：主流程抛异常走 process.exit 时不会调 quit()，AHK 会残留并持有搜索下拉。 */
  killNow() {
    this.alive = false;
    try { this.proc.kill(); } catch { /* 已死 */ }
  }
}

module.exports = { WechatDriver, AHK_EXE, DRIVER };