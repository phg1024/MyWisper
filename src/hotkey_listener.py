import threading
import time
from typing import Callable, Optional, Set
from pynput import keyboard


class HotkeyListener:
    """全局热键监听器，支持按住说话 (Push-to-Talk)、单击启停 (Toggle) 以及智能自适应模式 (Auto)"""

    def __init__(
        self,
        hotkey_name: str = "alt_r",
        trigger_mode: str = "auto",
        on_start: Optional[Callable[[], None]] = None,
        on_stop: Optional[Callable[[], None]] = None,
    ):
        self.hotkey_name = hotkey_name.lower()
        self.trigger_mode = trigger_mode.lower()
        self.on_start = on_start
        self.on_stop = on_stop

        self.is_recording = False
        self._state = "idle"  # "idle", "holding", "toggled_recording"
        self._press_start_time = 0.0
        self._active_keys: Set[keyboard.Key] = set()
        self._lock = threading.Lock()
        self._listener: Optional[keyboard.Listener] = None

    def _matches_target_key(self, key) -> bool:
        """检查按键是否匹配目标热键"""
        if self.hotkey_name in ("alt_r", "right_alt", "right_option"):
            return key == keyboard.Key.alt_r
        elif self.hotkey_name in ("alt_l", "left_alt", "left_option"):
            return key == keyboard.Key.alt_l
        elif self.hotkey_name == "f8":
            return key == keyboard.Key.f8
        elif self.hotkey_name == "f9":
            return key == keyboard.Key.f9
        elif self.hotkey_name == "f10":
            return key == keyboard.Key.f10
        elif self.hotkey_name == "ctrl_space":
            # 组合键 Ctrl + Space
            is_ctrl = keyboard.Key.ctrl in self._active_keys or keyboard.Key.ctrl_l in self._active_keys or keyboard.Key.ctrl_r in self._active_keys
            return is_ctrl and key == keyboard.Key.space
        else:
            # 兼容字符或字符串匹配
            try:
                if hasattr(key, "name") and key.name == self.hotkey_name:
                    return True
                if hasattr(key, "char") and key.char == self.hotkey_name:
                    return True
            except Exception:
                pass
            return False

    def _handle_press(self, key):
        self._active_keys.add(key)
        if not self._matches_target_key(key):
            return

        with self._lock:
            now = time.time()
            if self.trigger_mode == "push_to_talk":
                if not self.is_recording:
                    self.is_recording = True
                    self._state = "holding"
                    if self.on_start:
                        threading.Thread(target=self.on_start, daemon=True).start()

            elif self.trigger_mode == "toggle":
                if not self.is_recording:
                    self.is_recording = True
                    self._state = "toggled_recording"
                    if self.on_start:
                        threading.Thread(target=self.on_start, daemon=True).start()
                else:
                    self.is_recording = False
                    self._state = "idle"
                    if self.on_stop:
                        threading.Thread(target=self.on_stop, daemon=True).start()

            else:  # "auto" 智能模式 (短按切换，长按即说)
                if not self.is_recording:
                    self.is_recording = True
                    self._state = "holding"
                    self._press_start_time = now
                    if self.on_start:
                        threading.Thread(target=self.on_start, daemon=True).start()
                elif self._state == "toggled_recording":
                    # 当前正处于短按持续录音状态，再次按下则停止
                    self.is_recording = False
                    self._state = "idle"
                    if self.on_stop:
                        threading.Thread(target=self.on_stop, daemon=True).start()

    def _handle_release(self, key):
        # 释放按键
        is_target = self._matches_target_key(key)
        self._active_keys.discard(key)

        if not is_target:
            return

        with self._lock:
            now = time.time()
            if self.trigger_mode == "push_to_talk":
                if self.is_recording:
                    self.is_recording = False
                    self._state = "idle"
                    if self.on_stop:
                        threading.Thread(target=self.on_stop, daemon=True).start()

            elif self.trigger_mode == "toggle":
                pass  # toggle 模式在 release 时无动作

            else:  # "auto" 模式
                if self._state == "holding":
                    duration = now - self._press_start_time
                    if duration >= 0.35:
                        # 超过 0.35s，判定为按住说话，松开即触发停止
                        self.is_recording = False
                        self._state = "idle"
                        if self.on_stop:
                            threading.Thread(target=self.on_stop, daemon=True).start()
                    else:
                        # 小于 0.35s，判定为单击短按，转为持续录音状态，等待下一次按键
                        self._state = "toggled_recording"

    def start(self):
        """启动键盘事件监听线程"""
        if self._listener is not None:
            return
        self._listener = keyboard.Listener(
            on_press=self._handle_press,
            on_release=self._handle_release,
        )
        self._listener.start()

    def stop(self):
        """停止键盘事件监听"""
        if self._listener is not None:
            self._listener.stop()
            self._listener = None
