import os
import subprocess
from pathlib import Path


class SoundEffects:
    """macOS 系统提示音效播放器，非阻塞执行"""

    SOUND_START = "/System/Library/Sounds/Tink.aiff"
    SOUND_STOP = "/System/Library/Sounds/Pop.aiff"
    SOUND_ERROR = "/System/Library/Sounds/Basso.aiff"

    def __init__(self, enabled: bool = True):
        self.enabled = enabled

    def _play(self, file_path: str):
        if not self.enabled:
            return
        if os.path.exists(file_path):
            try:
                subprocess.Popen(
                    ["/usr/bin/afplay", file_path],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass

    def play_start(self):
        """开始录音提示音"""
        self._play(self.SOUND_START)

    def play_stop(self):
        """停止录音/转写完成提示音"""
        self._play(self.SOUND_STOP)

    def play_error(self):
        """错误或无效输入提示音"""
        self._play(self.SOUND_ERROR)
