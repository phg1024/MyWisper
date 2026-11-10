import os
import re
import time
from pathlib import Path
from typing import Dict, Optional, Tuple
import numpy as np
import sherpa_onnx


class ASREngine:
    """SenseVoice-Small ASR 推理引擎封装 (基于 sherpa-onnx)"""

    def __init__(
        self,
        model_path: str,
        tokens_path: str,
        num_threads: int = 4,
        use_itn: bool = True,
    ):
        base_dir = Path(__file__).resolve().parent.parent
        self.model_path = str((base_dir / model_path).resolve()) if not os.path.isabs(model_path) else model_path
        self.tokens_path = str((base_dir / tokens_path).resolve()) if not os.path.isabs(tokens_path) else tokens_path
        self.num_threads = num_threads
        self.use_itn = use_itn

        if not os.path.exists(self.model_path):
            raise FileNotFoundError(f"SenseVoice 模型未找到: {self.model_path}")
        if not os.path.exists(self.tokens_path):
            raise FileNotFoundError(f"词表文件未找到: {self.tokens_path}")

        print(f"[ASREngine] 正在加载 SenseVoice-Small 模型: {os.path.basename(self.model_path)} (线程: {num_threads})...")
        t0 = time.time()
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=self.model_path,
            tokens=self.tokens_path,
            num_threads=self.num_threads,
            use_itn=self.use_itn,
        )
        print(f"[ASREngine] 模型就绪，耗时 {time.time() - t0:.2f} 秒")

    def clean_text(self, text: str) -> str:
        """清洗文本，移除特殊标签，如 <|zh|>, <|NEUTRAL|>, <|Speech|> 等"""
        if not text:
            return ""
        # 移除 <|...|> 标签
        cleaned = re.sub(r"<\|.*?\|>", "", text)
        # 去除两端空白字符
        cleaned = cleaned.strip()
        return cleaned

    def transcribe(
        self,
        samples: np.ndarray,
        sample_rate: int = 16000,
        language: str = "auto",
    ) -> Tuple[str, Dict[str, float]]:
        """
        进行音频转写
        :param samples: 归一化为 [-1.0, 1.0] 的 float32 numpy 数组 (单声道)
        :param sample_rate: 采样率，默认为 16000
        :param language: 语言提示 (auto, zh, en, ja, ko, yue)
        :return: (转写后清洗纯文本, 统计信息字典)
        """
        if samples is None or len(samples) == 0:
            return "", {"duration": 0.0, "latency": 0.0, "rtf": 0.0}

        audio_duration = len(samples) / float(sample_rate)
        t_start = time.time()

        stream = self.recognizer.create_stream()
        stream.accept_waveform(sample_rate, samples)
        self.recognizer.decode_stream(stream)

        raw_text = stream.result.text
        cleaned_text = self.clean_text(raw_text)
        latency = time.time() - t_start
        rtf = latency / audio_duration if audio_duration > 0 else 0.0

        stats = {
            "duration": round(audio_duration, 2),
            "latency": round(latency, 3),
            "rtf": round(rtf, 3),
            "raw_text": raw_text,
        }
        return cleaned_text, stats
