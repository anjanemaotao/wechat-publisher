/**
 * 微信群「输入群名 → 点进群 → 点… → 点群二维码」纯点击流程
 *
 * 用法：
 *   node step-click-group.js
 *
 *   ★不接受任何命令行参数。所有配置一律读 ../config.json。
 *
 *【截图只有一处】点完「群二维码」之后截那一次，这是交付物。
 *   前三步（下拉列表、进群、群资料面板）一律不截 —— 它们只是排障用的中间状态，
 *   每截一次要0.5~2 秒，且从无用户要求。
 *   历史原因：曾用 --取证 把四处全截一遍，白花 4~5 秒；OCR 更早一步就删了
 *   （RapidOCR 稳定态单张 8~15 秒，且与图片大小无关，无法优化）。
 *
 *【截图范围是两点式】config.json 里存「左上角」「右下角」两组坐标，
 *   宽度由程序自己相减得出 —— 量坐标时拿到的天然是两个角点，不用自己算宽高。
 *
 *【坐标从哪来】全部写在 config.json。
 *
 *【失败即停】任何一步异常立刻退出，不重试、不兜底、不重复置前。
 *
 * 注意：会真实操作鼠标，执行期间请勿使用电脑。
 */
const { screen, Region } = require("@nut-tree/nut-js");
const { WechatDriver } = require("./ahk-driver-client");
const fs = require("fs");
const path = require("path");

const OUT_DIR = path.join(__dirname, "..", "output");

const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(...a);
const T = {};
let tPrev = Date.now();
let DRV = null;

function tick(name) { const n = Date.now(); T[name] = n - tPrev; tPrev = n; }

function fail(stage, reason) {
  try { if (DRV) DRV.killNow(); } catch { /* 已断 */ }
  console.error(`\n❌ [${stage}] ${reason}`);
  console.error("   已停止，不重试。");
  process.exit(2);
}

function loadCfg() {
  return JSON.parse(fs.readFileSync(path.join(__dirname, "..", "config.json"), "utf8"));
}

/**
 * 把「左上角 + 右下角」两个角点解成 captureRegion 需要的 [x, y, 宽, 高]。
 * 只认 config.json。
 */
function resolveRegion(cfg) {
  const sc = cfg["二维码截图"];
  const lt = sc["左上角"];
  const rb = sc["右下角"];

  for (const [name, v] of [["左上角", lt], ["右下角", rb]]) {
    if (!Array.isArray(v) || v.length !== 2 || v.some((n) => !Number.isFinite(n))) {
      fail("配置检查", `config.json 的「二维码截图.${name}」必须是 [x, y] 两个数字，当前 ${JSON.stringify(v)}`);
    }
  }
  // 填反了就停下并打印实际读到的值，不自动交换 —— 自动纠正会掩盖填错的意图
  if (rb[0] <= lt[0] || rb[1] <= lt[1]) {
    fail("配置检查",
      `右下角必须严格大于左上角。当前左上角=${JSON.stringify(lt)} 右下角=${JSON.stringify(rb)}，`
      + `算出宽=${rb[0] - lt[0]} 高=${rb[1] - lt[1]}。请检查是否填反了。`);
  }

  const region = [lt[0], lt[1], rb[0] - lt[0], rb[1] - lt[1]];
  log(`截图区域：左上(${lt[0]}, ${lt[1]}) → 右下(${rb[0]}, ${rb[1]})  =  ${region[2]}x${region[3]}  （来源：config.json）`);
  return region;
}

/**
 * 只截指定矩形，不截全屏。
 *
 * 为什么不用「截全屏 + PNG 裁剪」：那要先抓 2560x1440（约 3.7M 像素）、
 * 解码整张 PNG、再裁剪、再编码写出，pngjs 实测吃 1.4 秒。
 * captureRegion 让 nut-js 直接按区域抓，交给它自己的编码器，
 * 面积小一个数量级，实测降到 200~300ms。
 *
 * 注意 nut-js 的坑：fileName 传绝对路径会被当成相对路径拼到 cwd 上，
 * 所以这里传相对文件名，再用 path.join 拼绝对路径。
 */
async function shotRegion(outPath, region) {
  const rel = "_shot_tmp.png";
  const abs = path.join(process.cwd(), rel);
  if (fs.existsSync(abs)) fs.unlinkSync(abs);
  await screen.captureRegion(rel, new Region(region[0], region[1], region[2], region[3]));
  if (!fs.existsSync(abs)) throw new Error("截图文件未生成：" + abs);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.renameSync(abs, outPath);
  return outPath;
}

function printTiming() {
  log("\n---- 耗时明细 ----");
  let sum = 0;
  for (const [k, v] of Object.entries(T)) { log(`  ${k.padEnd(22, " ")} ${String(v).padStart(6)} ms`); sum += v; }
  log(`  ${"合计".padEnd(21, " ")} ${String(sum).padStart(6)} ms  (${(sum / 1000).toFixed(1)} 秒)`);
}

async function main() {
  const cfg = loadCfg();
  const w = cfg["等待毫秒"];

  // 不接收命令行参数，唯一配置来源是 config.json
  const extra = process.argv.slice(2);
  if (extra.length > 0) {
    console.log(`⚠️ 本脚本不接受任何命令行参数，已忽略：${extra.join(" ")}`);
    console.log(`   需要改配置请直接编辑 config.json。`);
  }

  const group = cfg["目标群名"]["名称"];
  const rowXY = cfg["目标群行"]["点击坐标"];
  const sbXY = cfg["搜索"]["点击坐标"];
  const infoXY = cfg["聊天信息"]["点击坐标"];
  const qrXY = cfg["群二维码"]["点击坐标"];

  log("=== 纯点击流程：输入群名 → 点进群 → 点… → 点群二维码（只截最后一张图）===");
  log(`目标群名：${group}`);
  log(`坐标：群聊行(${rowXY.join(", ")})  搜索框(${sbXY.join(", ")})  「…」(${infoXY.join(", ")})  群二维码(${qrXY.join(", ")})`);

  for (const [name, v] of [["搜索.点击坐标", sbXY], ["目标群行.点击坐标", rowXY],
                           ["聊天信息.点击坐标", infoXY], ["群二维码.点击坐标", qrXY]]) {
    if (!Array.isArray(v) || v.length !== 2 || v.some((n) => !Number.isFinite(n))) {
      fail("配置检查", `config.json 的「${name}」必须是 [x, y] 两个数字，当前 ${JSON.stringify(v)}`);
    }
  }

  // 截图区域也在这里校验 —— 放在启动 AHK 之前，配置错了就不该动鼠标
  const region = resolveRegion(cfg);
  log("");

  const drv = new WechatDriver();
  DRV = drv;
  await drv.start(cfg);
  tick("① AHK常驻启动");

  log("[1] 置前微信（整个流程只做这一次）…");
  let kv = await drv.focus();
  log(`    ✓ ${kv.STEP}  ${kv.WECHAT_SIZE}`);
  tick("② 置前");
  // AHK 的 FOCUS 里已有 WinWaitActive + Sleep(250)，这里只需极短缓冲让 Qt 完成首帧
  await sleepMs(w["置前后缓冲"] ?? 400);
  tick("③ 置前后缓冲");

  log(`[2] 点搜索框 (${sbXY.join(", ")}) 并粘贴群名…`);
  kv = await drv.paste(sbXY[0], sbXY[1], group);
  log(`    ✓ ${kv.STEP}`);
  tick("④ 粘贴+等搜索结果");

  log(`[3] 点群聊行 (${rowXY.join(", ")})…`);
  kv = await drv.click(rowXY[0], rowXY[1], w["等进入群聊"]);
  log(`    ✓ CLICKED (${kv.CLICKED_X},${kv.CLICKED_Y})`);
  tick("⑤ 点击+等进入");

  log(`[4] 点右上角「…」(${infoXY.join(", ")}) 打开群资料面板…`);
  kv = await drv.click(infoXY[0], infoXY[1], w["等聊天信息面板"]);
  log(`    ✓ CLICKED (${kv.CLICKED_X},${kv.CLICKED_Y})`);
  tick("⑥ 点击「…」+等面板");

  log(`[5] 点「群二维码」(${qrXY.join(", ")})…`);
  kv = await drv.click(qrXY[0], qrXY[1], w["等二维码渲染"]);
  log(`    ✓ CLICKED (${kv.CLICKED_X},${kv.CLICKED_Y})`);
  tick("⑦ 点击群二维码+等渲染");

  // 唯一的截图 —— 二维码弹窗是交付物，必须拍下来
  const outPath = path.join(OUT_DIR, cfg["二维码截图"]["输出文件名"] || "qrcode.png");
  await shotRegion(outPath, region);
  tick("⑦ 截二维码弹窗");

  drv.quit();
  printTiming();
  log(`\n✅ 五步完成，二维码截图已保存：`);
  log(`   ${outPath}`);
  log(`   打印路径格式： OUTPUT_PATH=${outPath}`);
}

main().catch((e) => {
  try { if (DRV) DRV.killNow(); } catch { /* 已断 */ }
  console.error("\n❌ 执行异常:", e.message || e);
  process.exit(1);
});
