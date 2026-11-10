import threading
import time
from typing import Callable, Dict, List, Optional
from src.asr_engine import ASREngine
from src.audio_recorder import AudioRecorder
from src.config import load_config, save_config
from src.history_manager import HistoryManager
from src.hotkey_listener import HotkeyListener
from src.sound_effects import SoundEffects
from src.text_injector import TextInjector


class AppController:
    """MyWisper 核心调度器: 整合录音、ASR 推理、热键监听、输入模拟与历史管理"""

    def __init__(self, config_override: Optional[Dict] = None):
        self.config = load_config()
        if config_override:
            self.config.update(config_override)

        # 状态回调: 供 GUI 或 CLI 监听状态变化 (status: str, message: str)
        self.status_listeners: List[Callable[[str, str], None]] = []

        print("[AppController] 初始化各核心子系统...")
        self.sounds = SoundEffects(enabled=self.config.get("play_sound", True))
        self.history = HistoryManager()
        self.injector = TextInjector(
            auto_paste=self.config.get("auto_paste", True),
            restore_clipboard=self.config.get("restore_clipboard", False),
        )
        self.recorder = AudioRecorder(sample_rate=16000)
        self.asr = ASREngine(
            model_path=self.config.get("model_path"),
            tokens_path=self.config.get("tokens_path"),
            num_threads=self.config.get("num_threads", 4),
            use_itn=True,
        )

        self.hotkey_listener = HotkeyListener(
            hotkey_name=self.config.get("hotkey", "alt_r"),
            trigger_mode=self.config.get("trigger_mode", "auto"),
            on_start=self.start_recording,
            on_stop=self.stop_recording,
        )

        self._processing_lock = threading.Lock()
        self.current_state = "idle"  # "idle", "recording", "transcribing"

    def register_status_listener(self, callback: Callable[[str, str], None]):
        """注册状态监听回调"""
        self.status_listeners.append(callback)

    def _notify_status(self, status: str, message: str):
        self.current_state = status
        for cb in self.status_listeners:
            try:
                cb(status, message)
            except Exception:
                pass

    def start_recording(self):
        """开始录音流程"""
        with self._processing_lock:
            if self.current_state != "idle":
                return
            success = self.recorder.start()
            if success:
                self.sounds.play_start()
                self._notify_status("recording", "正在录音... 请说话")
                print("\n[🎙️ 录音中] 正在捕获麦克风输入...")

    def stop_recording(self):
        """停止录音并触发转写与自动输入"""
        with self._processing_lock:
            if self.current_state != "recording":
                return
            self._notify_status("transcribing", "正在转写并输入...")
            print("[⏳ 转写中] 停止录音，开始 SenseVoice-Small 推理...")

            samples, duration, rms = self.recorder.stop()

            # 校验音频有效性
            min_dur = self.config.get("min_audio_duration", 0.25)
            silence_thresh = self.config.get("silence_threshold", 0.001)

            if samples is None or duration < min_dur or rms < silence_thresh:
                self.sounds.play_error()
                msg = f"录音过短({duration:.2f}s)或未检测到声音(RMS:{rms:.4f})"
                print(f"[⚠️ 提示] {msg}")
                self._notify_status("idle", msg)
                return

            self.sounds.play_stop()

            # 执行 SenseVoice-Small ASR 转写
            try:
                cleaned_text, stats = self.asr.transcribe(
                    samples=samples,
                    sample_rate=16000,
                    language=self.config.get("language", "auto"),
                )
            except Exception as e:
                print(f"[❌ 错误] 转写异常: {e}")
                self.sounds.play_error()
                self._notify_status("idle", f"转写失败: {e}")
                return

            if not cleaned_text:
                print("[⚠️ 提示] 未识别出有效文本")
                self._notify_status("idle", "未识别出文字")
                return

            # 输出识别详情
            print(f"[✅ 识别成功] 文本: \"{cleaned_text}\"")
            print(f"             音频时长: {stats['duration']}s | 推理耗时: {stats['latency']}s | RTF: {stats['rtf']}")

            # 记录历史
            self.history.add_entry(cleaned_text, stats)

            # 自动输入到当前活动窗口光标处
            if self.config.get("auto_paste", True):
                pasted = self.injector.inject(cleaned_text)
                if pasted:
                    print("[🚀 自动键入] 已成功输入至当前活动窗口光标处！")
                else:
                    print("[📋 剪贴板] 已将文本复制至剪贴板，请手动 Cmd+V 粘贴")
            else:
                self.injector.set_clipboard(cleaned_text)
                print("[📋 剪贴板] 自动粘贴已关闭，文本已存入剪贴板")

            self._notify_status("idle", f"已输入: {cleaned_text[:20]}...")

    def update_config(self, key: str, value):
        """动态更新配置"""
        self.config[key] = value
        save_config(self.config)
        if key == "play_sound":
            self.sounds.enabled = value
        elif key == "auto_paste":
            self.injector.auto_paste = value
        elif key == "restore_clipboard":
            self.injector.restore_clipboard = value
        elif key in ("hotkey", "trigger_mode"):
            self.hotkey_listener.stop()
            self.hotkey_listener = HotkeyListener(
                hotkey_name=self.config.get("hotkey", "alt_r"),
                trigger_mode=self.config.get("trigger_mode", "auto"),
                on_start=self.start_recording,
                on_stop=self.stop_recording,
            )
            self.hotkey_listener.start()

    def start(self):
        """启动后台监听服务与本地API接口"""
        from src.api_server import start_api_server
        start_api_server(self)
        print(f"[MyWisper] 启动成功！当前热键: [{self.config.get('hotkey')}] | 交互模式: [{self.config.get('trigger_mode')}]")
        print("[MyWisper] 提示: 按下或按住热键开始说话，松开或再次按下即可直接在任何 App 中自动打字。")
        self.hotkey_listener.start()

    def stop(self):
        """停止服务"""
        self.hotkey_listener.stop()
        if self.recorder.is_recording:
            self.recorder.stop()
        print("[MyWisper] 服务已退出")
