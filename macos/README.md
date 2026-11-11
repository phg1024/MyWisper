# MyWisper for macOS（原生版）

菜单栏语音输入：按住快捷键说话，松开后文字出现在光标处。识别用 SenseVoice-Small（int8，sherpa-onnx C API），全部在本机完成。

## 构建和安装

```bash
cd macos
./build.sh install     # 生成 build/MyWisper.app，并复制到 ~/Applications
```

需要 Xcode 和上一级目录里 Python 版的 `venv/`（提供 sherpa-onnx 的 C 库）和 `models/`（SenseVoice 模型，会打包进 App，约 230MB）。

第一次打开会出现欢迎窗口，按提示授权：
- **麦克风**：录音。
- **辅助功能**：全局快捷键，以及模拟 ⌘V 把文字粘贴到光标处。

这台 Mac 上没有开发者证书，App 是 ad-hoc 签名。**每次重新构建后，系统会把它当成新程序**：要到 系统设置 › 隐私与安全性 › 辅助功能 里用「−」删掉旧的 MyWisper，再重新授权。

## 用法

- 默认快捷键是**右 Option**，用法「自适应」：按住说话、松开结束；或者短按一下开始，说完再按一下结束。
- 可以换成左 Option、右 Command、左/右 Control 或 Fn，最省事是在 设置 › 通用 点「按键设置…」后直接按那个键（用 Fn 要先在 系统设置 › 键盘 里把「按下 🌐 键时」设成「无操作」）。按下后约 0.12 秒才开麦，所以 ⌃C、⌥E 这类组合键不会碰到麦克风。
- 按住快捷键时又按了别的键（比如 ⌥E、⌘C），这次录音自动作废，所以不会妨碍正常的快捷键；录音时按 esc 取消。
- 屏幕底部的提示条显示录音波形、时长和识别结果。没有辅助功能权限时，文字只复制到剪贴板。
- 菜单栏图标里有开始按钮和最近 5 条记录（点一下复制）；完整历史在「全部记录」里，可以搜索、删除。
- 历史记录存在 `~/Library/Application Support/MyWisper/history.json`（只有本人可读），可以在设置里关掉或清空。

## 命令行

```bash
MyWisper.app/Contents/MacOS/MyWisper --transcribe a.wav b.wav [--language zh]   # 测识别
MyWisper.app/Contents/MacOS/MyWisper --snapshot /tmp/shots                    # 把各个界面渲染成 PNG
```

## 和 Python 版的区别

Python 版（`../main.py`）的这些问题在这里都不存在：菜单栏模式起不来（rumps 的 `clear()` 报错后退回终端模式）、热键状态和实际录音状态对不上、转写期间说的话会丢、本地 HTTP 接口没有认证还开了 `Access-Control-Allow-Origin: *`（任何网页都能读听写历史、远程开麦）。原生版没有 HTTP 接口。

「识别语言」在两个版本里效果都很弱：SenseVoice 会自己判断语言，强制指定基本不改变结果（2026-11-10 用 Python 和 C 接口都测过），所以原生版把它放在设置里，叫「语言提示」。
