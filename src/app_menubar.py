import os
import threading
from typing import Optional
import rumps
from src.app_controller import AppController


class MyWisperMenuBarApp(rumps.App):
    """MyWisper macOS 顶部菜单栏驻留应用"""

    def __init__(self, controller: AppController):
        super(MyWisperMenuBarApp, self).__init__("MyWisper", title="🎙️")
        self.controller = controller
        self.controller.register_status_listener(self._on_status_change)

        # 构建菜单项
        self.status_item = rumps.MenuItem("状态: 空闲 (待命)", callback=None)
        self.manual_toggle_item = rumps.MenuItem("开始录音 / 停止", callback=self.toggle_recording)

        # 模式切换子菜单
        self.mode_menu = rumps.MenuItem("交互模式")
        self.mode_auto = rumps.MenuItem("自适应 (短按切换/长按即说)", callback=self.set_mode)
        self.mode_ptt = rumps.MenuItem("按住说话 (Push-to-Talk)", callback=self.set_mode)
        self.mode_toggle = rumps.MenuItem("单击启停 (Toggle)", callback=self.set_mode)
        self.mode_menu.update([self.mode_auto, self.mode_ptt, self.mode_toggle])

        # 热键子菜单
        self.hotkey_menu = rumps.MenuItem("触发热键")
        self.hk_alt_r = rumps.MenuItem("右 Option 键 (推荐)", callback=self.set_hotkey)
        self.hk_f8 = rumps.MenuItem("F8 键", callback=self.set_hotkey)
        self.hk_f9 = rumps.MenuItem("F9 键", callback=self.set_hotkey)
        self.hk_ctrl_space = rumps.MenuItem("Ctrl + Space", callback=self.set_hotkey)
        self.hotkey_menu.update([self.hk_alt_r, self.hk_f8, self.hk_f9, self.hk_ctrl_space])

        # 语言子菜单
        self.lang_menu = rumps.MenuItem("识别语言")
        self.lang_auto = rumps.MenuItem("自动识别", callback=self.set_language)
        self.lang_zh = rumps.MenuItem("中文 (普通话)", callback=self.set_language)
        self.lang_en = rumps.MenuItem("English", callback=self.set_language)
        self.lang_yue = rumps.MenuItem("粤语", callback=self.set_language)
        self.lang_ja = rumps.MenuItem("日本語", callback=self.set_language)
        self.lang_menu.update([self.lang_auto, self.lang_zh, self.lang_en, self.lang_yue, self.lang_ja])

        # 功能开关
        self.sound_toggle = rumps.MenuItem("提示音效", callback=self.toggle_sound)
        self.paste_toggle = rumps.MenuItem("自动键入至光标处", callback=self.toggle_paste)

        # 历史记录子菜单
        self.history_menu = rumps.MenuItem("最近输入历史")

        # 装配菜单
        self.menu = [
            self.status_item,
            self.manual_toggle_item,
            None,  # 分隔线
            self.mode_menu,
            self.hotkey_menu,
            self.lang_menu,
            self.sound_toggle,
            self.paste_toggle,
            None,  # 分隔线
            self.history_menu,
        ]

        self._refresh_menu_states()
        self._refresh_history_menu()

    def _refresh_menu_states(self):
        """同步配置状态到菜单勾选标记"""
        cur_mode = self.controller.config.get("trigger_mode", "auto")
        self.mode_auto.state = 1 if cur_mode == "auto" else 0
        self.mode_ptt.state = 1 if cur_mode == "push_to_talk" else 0
        self.mode_toggle.state = 1 if cur_mode == "toggle" else 0

        cur_hk = self.controller.config.get("hotkey", "alt_r")
        self.hk_alt_r.state = 1 if cur_hk == "alt_r" else 0
        self.hk_f8.state = 1 if cur_hk == "f8" else 0
        self.hk_f9.state = 1 if cur_hk == "f9" else 0
        self.hk_ctrl_space.state = 1 if cur_hk == "ctrl_space" else 0

        cur_lang = self.controller.config.get("language", "auto")
        self.lang_auto.state = 1 if cur_lang == "auto" else 0
        self.lang_zh.state = 1 if cur_lang == "zh" else 0
        self.lang_en.state = 1 if cur_lang == "en" else 0
        self.lang_yue.state = 1 if cur_lang == "yue" else 0
        self.lang_ja.state = 1 if cur_lang == "ja" else 0

        self.sound_toggle.state = 1 if self.controller.config.get("play_sound", True) else 0
        self.paste_toggle.state = 1 if self.controller.config.get("auto_paste", True) else 0

    def _refresh_history_menu(self):
        """刷新最近历史菜单列表"""
        self.history_menu.clear()
        recent = self.controller.history.get_recent(5)
        if not recent:
            self.history_menu.add(rumps.MenuItem("(暂无历史记录)"))
            return

        for item in recent:
            txt = item["text"]
            disp = txt if len(txt) <= 25 else txt[:22] + "..."
            menu_item = rumps.MenuItem(
                f"{item['timestamp'][-8:]} {disp}",
                callback=lambda sender, full_text=txt: self._copy_history_item(full_text),
            )
            self.history_menu.add(menu_item)

    def _copy_history_item(self, text: str):
        self.controller.injector.set_clipboard(text)
        rumps.notification("MyWisper", "已复制到剪贴板", text)

    def _on_status_change(self, status: str, message: str):
        """接收控制器状态变化更新标题与图标"""
        if status == "recording":
            self.title = "🔴"
            self.status_item.title = "状态: 🎙️ 录音中 (请说话...)"
        elif status == "transcribing":
            self.title = "⏳"
            self.status_item.title = "状态: ⏳ 转写中..."
        else:
            self.title = "🎙️"
            self.status_item.title = f"状态: 空闲 ({message})"
            self._refresh_history_menu()

    def toggle_recording(self, sender):
        """从菜单栏手动启停录音"""
        if self.controller.current_state == "recording":
            self.controller.stop_recording()
        elif self.controller.current_state == "idle":
            self.controller.start_recording()

    def set_mode(self, sender):
        if sender == self.mode_auto:
            self.controller.update_config("trigger_mode", "auto")
        elif sender == self.mode_ptt:
            self.controller.update_config("trigger_mode", "push_to_talk")
        elif sender == self.mode_toggle:
            self.controller.update_config("trigger_mode", "toggle")
        self._refresh_menu_states()

    def set_hotkey(self, sender):
        if sender == self.hk_alt_r:
            self.controller.update_config("hotkey", "alt_r")
        elif sender == self.hk_f8:
            self.controller.update_config("hotkey", "f8")
        elif sender == self.hk_f9:
            self.controller.update_config("hotkey", "f9")
        elif sender == self.hk_ctrl_space:
            self.controller.update_config("hotkey", "ctrl_space")
        self._refresh_menu_states()

    def set_language(self, sender):
        if sender == self.lang_auto:
            self.controller.update_config("language", "auto")
        elif sender == self.lang_zh:
            self.controller.update_config("language", "zh")
        elif sender == self.lang_en:
            self.controller.update_config("language", "en")
        elif sender == self.lang_yue:
            self.controller.update_config("language", "yue")
        elif sender == self.lang_ja:
            self.controller.update_config("language", "ja")
        self._refresh_menu_states()

    def toggle_sound(self, sender):
        new_val = not bool(self.sound_toggle.state)
        self.controller.update_config("play_sound", new_val)
        self._refresh_menu_states()

    def toggle_paste(self, sender):
        new_val = not bool(self.paste_toggle.state)
        self.controller.update_config("auto_paste", new_val)
        self._refresh_menu_states()
