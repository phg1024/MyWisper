import json
import time
from pathlib import Path
from typing import Any, Dict, List

HISTORY_FILE = Path(__file__).resolve().parent.parent / "history.json"
MAX_HISTORY_ENTRIES = 100


class HistoryManager:
    """语音识别历史记录管理器"""

    def __init__(self, max_entries: int = MAX_HISTORY_ENTRIES):
        self.max_entries = max_entries
        self.history: List[Dict[str, Any]] = self._load()

    def _load(self) -> List[Dict[str, Any]]:
        if HISTORY_FILE.exists():
            try:
                with open(HISTORY_FILE, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return []
        return []

    def save(self) -> None:
        try:
            with open(HISTORY_FILE, "w", encoding="utf-8") as f:
                json.dump(self.history, f, indent=2, ensure_ascii=False)
        except Exception as e:
            print(f"[History] 保存历史记录失败: {e}")

    def add_entry(self, text: str, stats: Dict[str, Any]) -> None:
        if not text:
            return
        entry = {
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "text": text,
            "duration": stats.get("duration", 0.0),
            "latency": stats.get("latency", 0.0),
            "rtf": stats.get("rtf", 0.0),
        }
        self.history.insert(0, entry)
        if len(self.history) > self.max_entries:
            self.history = self.history[: self.max_entries]
        self.save()

    def get_recent(self, count: int = 10) -> List[Dict[str, Any]]:
        return self.history[:count]
