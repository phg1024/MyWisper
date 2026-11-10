import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TYPE_CHECKING
import numpy as np

if TYPE_CHECKING:
    from src.app_controller import AppController


class MyWisperHTTPHandler(BaseHTTPRequestHandler):
    controller: "AppController" = None  # 由外部注入

    def log_message(self, format, *args):
        # 屏蔽日常心跳日志，避免终端刷屏
        pass

    def _send_json(self, status_code: int, data: dict):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))

    def do_GET(self):
        if self.path == "/" or self.path == "/status":
            res = {
                "status": self.controller.current_state,
                "hotkey": self.controller.config.get("hotkey"),
                "trigger_mode": self.controller.config.get("trigger_mode"),
                "language": self.controller.config.get("language"),
                "auto_paste": self.controller.config.get("auto_paste"),
            }
            self._send_json(200, res)
        elif self.path == "/history":
            recent = self.controller.history.get_recent(20)
            self._send_json(200, {"history": recent})
        else:
            self._send_json(404, {"error": "Not Found"})

    def do_POST(self):
        if self.path == "/toggle":
            # 切换录音/停止状态 (可完美用于 Raycast / Alfred / 快捷指令 / 鼠标侧键)
            if self.controller.current_state == "recording":
                threading.Thread(target=self.controller.stop_recording, daemon=True).start()
                self._send_json(200, {"action": "stopping", "message": "已触发停止录音并转写"})
            elif self.controller.current_state == "idle":
                threading.Thread(target=self.controller.start_recording, daemon=True).start()
                self._send_json(200, {"action": "recording", "message": "已触发开始录音"})
            else:
                self._send_json(409, {"status": self.controller.current_state, "message": "当前处于转写处理中"})
        elif self.path == "/start":
            threading.Thread(target=self.controller.start_recording, daemon=True).start()
            self._send_json(200, {"action": "recording"})
        elif self.path == "/stop":
            threading.Thread(target=self.controller.stop_recording, daemon=True).start()
            self._send_json(200, {"action": "stopping"})
        else:
            self._send_json(404, {"error": "Not Found"})


def start_api_server(controller: "AppController", host: str = "127.0.0.1", port: int = 18233) -> ThreadingHTTPServer:
    """启动本地轻量级 REST API 服务 (无需第三方库，原生 http.server)"""
    MyWisperHTTPHandler.controller = controller
    try:
        server = ThreadingHTTPServer((host, port), MyWisperHTTPHandler)
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        print(f"[API Server] 本地日常调用接口已就绪: http://{host}:{port}/")
        print(f"            - 启停切换: POST http://{host}:{port}/toggle")
        print(f"            - 查看状态: GET  http://{host}:{port}/status")
        return server
    except Exception as e:
        print(f"[API Server] 启动 HTTP 接口失败 (端口可能被占用): {e}")
        return None
