import subprocess
import time
from typing import Optional


class TextInjector:
    """macOS 文本自动输入与剪贴板注入器 (Wispr Flow 核心能力)"""

    def __init__(self, auto_paste: bool = True, restore_clipboard: bool = False):
        self.auto_paste = auto_paste
        self.restore_clipboard = restore_clipboard

    @staticmethod
    def get_clipboard() -> str:
        """获取当前系统剪贴板文本"""
        try:
            p = subprocess.run(
                ["/usr/bin/pbpaste"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=True,
            )
            return p.stdout.decode("utf-8")
        except Exception:
            return ""

    @staticmethod
    def set_clipboard(text: str) -> bool:
        """设置系统剪贴板文本"""
        try:
            p = subprocess.run(
                ["/usr/bin/pbcopy"],
                input=text.encode("utf-8"),
                stderr=subprocess.DEVNULL,
                check=True,
            )
            return p.returncode == 0
        except Exception as e:
            print(f"[TextInjector] 设置剪贴板失败: {e}")
            return False

    @staticmethod
    def simulate_paste_applescript() -> bool:
        """通过 AppleScript 模拟 Command+V 粘贴操作"""
        script = 'tell application "System Events" to keystroke "v" using command down'
        try:
            res = subprocess.run(
                ["/usr/bin/osascript", "-e", script],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return res.returncode == 0
        except Exception as e:
            print(f"[TextInjector] 模拟粘贴失败: {e}")
            return False

    @staticmethod
    def simulate_paste_quartz() -> bool:
        """通过 macOS Quartz CGEvent 模拟 Command+V 粘贴"""
        try:
            from Quartz import (
                CGEventCreateKeyboardEvent,
                CGEventPost,
                kCGHIDEventTap,
                CGEventSetFlags,
                kCGEventFlagMaskCommand,
            )
            cmd_down = CGEventCreateKeyboardEvent(None, 55, True)
            v_down = CGEventCreateKeyboardEvent(None, 9, True)
            CGEventSetFlags(v_down, kCGEventFlagMaskCommand)
            v_up = CGEventCreateKeyboardEvent(None, 9, False)
            CGEventSetFlags(v_up, kCGEventFlagMaskCommand)
            cmd_up = CGEventCreateKeyboardEvent(None, 55, False)

            CGEventPost(kCGHIDEventTap, cmd_down)
            CGEventPost(kCGHIDEventTap, v_down)
            CGEventPost(kCGHIDEventTap, v_up)
            CGEventPost(kCGHIDEventTap, cmd_up)
            return True
        except Exception:
            return False

    def inject(self, text: str) -> bool:
        """
        核心输入流水线:
        1. 备份当前剪贴板 (可选)
        2. 将识别文本写入剪贴板
        3. 模拟触发 Command+V 粘贴到当前活动光标位置
        4. 恢复原剪贴板 (若配置要求)
        """
        if not text:
            return False

        old_clipboard: Optional[str] = None
        if self.restore_clipboard:
            old_clipboard = self.get_clipboard()

        # 写入剪贴板
        if not self.set_clipboard(text):
            return False

        if not self.auto_paste:
            # 仅复制到剪贴板，不自动按键
            return True

        # 等待剪贴板就绪
        time.sleep(0.03)

        # 优先使用 AppleScript 模拟粘贴 (更兼容各沙箱应用与外接键盘)，失败则尝试 Quartz
        pasted = self.simulate_paste_applescript()
        if not pasted:
            pasted = self.simulate_paste_quartz()

        # 如果需要恢复原有剪贴板内容，等待当前宿主程序消费完毕后恢复
        if self.restore_clipboard and old_clipboard is not None:
            time.sleep(0.12)
            self.set_clipboard(old_clipboard)

        return pasted
