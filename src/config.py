import json
import os
from pathlib import Path
from typing import Any, Dict

DEFAULT_CONFIG: Dict[str, Any] = {
    "hotkey": "alt_r",              # 触发热键: "alt_r" (右Option), "f8", "f9", "ctrl_space"
    "trigger_mode": "auto",         # 交互模式: "auto" (短按切换/长按即说), "push_to_talk" (按住说话), "toggle" (单击启停)
    "play_sound": True,             # 是否播放提示音 (开始/结束/提示)
    "auto_paste": True,             # 识别完成后是否自动粘贴到当前光标位置 (类似 Wispr Flow)
    "restore_clipboard": False,     # 粘贴后是否恢复原有剪贴板内容 (设为False可保留识别内容方便再次粘贴)
    "language": "auto",             # 识别语言: "auto", "zh", "en", "ja", "ko", "yue"
    "model_path": "models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx",
    "tokens_path": "models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt",
    "num_threads": 4,               # 推理线程数 (Apple Silicon M系列推荐4线程)
    "min_audio_duration": 0.25,     # 最小有效录音时长(秒)，防止误触
    "silence_threshold": 0.001,     # 静音检测能量阈值 (RMS)
}

CONFIG_FILE = Path(__file__).resolve().parent.parent / "config.json"


def load_config() -> Dict[str, Any]:
    """加载配置文件，若不存在则创建默认配置"""
    config = dict(DEFAULT_CONFIG)
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                user_cfg = json.load(f)
                config.update(user_cfg)
        except Exception as e:
            print(f"[Config] 加载配置文件失败，将使用默认配置: {e}")
    else:
        save_config(config)
    return config


def save_config(config: Dict[str, Any]) -> None:
    """保存配置到文件"""
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=4, ensure_ascii=False)
    except Exception as e:
        print(f"[Config] 保存配置失败: {e}")
