---
name: wechat-qrcode-yashu
description: 抓取微信群二维码图片（群名 + 二维码 + 有效期）。当用户说「获取群二维码」「抓群二维码」「保存群二维码图」「微信群二维码截图」，或想把自己某个微信群的二维码存成图片时使用。只出图片，不做二维码解码。执行会真实操作鼠标，运行期间用户不能使用电脑。
---

# 微信群二维码图片抓取

执行以下命令，运行技能：

```bash
cd "C:/Users/Administrator/.workbuddy/skills/wechat-qrcode-yashu/scripts"
node step-click-group.js
```

命令执行完毕会在末尾打印群二维码图片的**绝对路径**（`OUTPUT_PATH=...`）
