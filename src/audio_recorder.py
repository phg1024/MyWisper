import queue
import threading
import time
from typing import Optional, Tuple
import numpy as np
import sounddevice as sd


class AudioRecorder:
    """基于 sounddevice 的轻量级音频录制器"""

    def __init__(self, sample_rate: int = 16000, device: Optional[int] = None):
        self.sample_rate = sample_rate
        self.device = device
        self.is_recording = False
        self._audio_queue: queue.Queue = queue.Queue()
        self._stream: Optional[sd.InputStream] = None
        self._lock = threading.Lock()
        self._start_time: float = 0.0

    def _audio_callback(self, indata, frames, time_info, status):
        """音频输入流回调函数"""
        if self.is_recording:
            # indata shape: (frames, channels), dtype float32
            self._audio_queue.put(indata.copy())

    def start(self) -> bool:
        """开始录音"""
        with self._lock:
            if self.is_recording:
                return False
            # 清空旧数据
            while not self._audio_queue.empty():
                try:
                    self._audio_queue.get_nowait()
                except queue.Empty:
                    break

            try:
                self._stream = sd.InputStream(
                    samplerate=self.sample_rate,
                    channels=1,
                    dtype="float32",
                    device=self.device,
                    callback=self._audio_callback,
                    blocksize=1024,
                )
                self._stream.start()
                self.is_recording = True
                self._start_time = time.time()
                return True
            except Exception as e:
                print(f"[AudioRecorder] 启动麦克风录音失败: {e}")
                self.is_recording = False
                return False

    def stop(self) -> Tuple[Optional[np.ndarray], float, float]:
        """
        停止录音并返回音频数据
        :return: (samples, duration_seconds, rms_energy)
        """
        with self._lock:
            if not self.is_recording:
                return None, 0.0, 0.0

            self.is_recording = False
            duration = time.time() - self._start_time

            if self._stream is not None:
                try:
                    self._stream.stop()
                    self._stream.close()
                except Exception as e:
                    print(f"[AudioRecorder] 关闭音频流异常: {e}")
                self._stream = None

        chunks = []
        while not self._audio_queue.empty():
            try:
                chunks.append(self._audio_queue.get_nowait())
            except queue.Empty:
                break

        if not chunks:
            return None, duration, 0.0

        # 合并所有 chunk 为一维单声道数组
        samples = np.concatenate(chunks, axis=0).flatten()

        # 计算 RMS 能量
        rms = float(np.sqrt(np.mean(samples**2))) if len(samples) > 0 else 0.0

        return samples, duration, rms
