import argparse
import signal
import sys
import time
from src.app_controller import AppController


def run_cli_mode(controller: AppController):
    """终端控制台常驻模式"""
    controller.start()
    print("\n" + "=" * 60)
    print("🚀 MyWisper (SenseVoice-Small) 本地语音输入软件已在后台运行")
    print(f"👉 当前热键: [{controller.config.get('hotkey')}]")
    print(f"👉 交互模式: [{controller.config.get('trigger_mode')}] (短按切换/长按即说)")
    print(f"👉 识别语言: [{controller.config.get('language')}]")
    print("👉 提示: 在任意输入框中按下热键说话，松开或再按一次即可自动输入！")
    print("👉 按 Ctrl+C 退出程序")
    print("=" * 60 + "\n")

    def handle_exit(sig, frame):
        print("\n[MyWisper] 接收到退出信号，正在安全退出...")
        controller.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_exit)
    signal.signal(signal.SIGTERM, handle_exit)

    # 保持主线程循环运行
    while True:
        try:
            time.sleep(1)
        except (KeyboardInterrupt, SystemExit):
            break
    controller.stop()


def run_gui_mode(controller: AppController):
    """macOS 顶部菜单栏 GUI 模式"""
    try:
        from src.app_menubar import MyWisperMenuBarApp
        app = MyWisperMenuBarApp(controller)
        controller.start()
        print("[MyWisper] 顶部状态栏图标已就绪 (🎙️)")
        app.run()
    except Exception as e:
        print(f"[MyWisper] 启动菜单栏 GUI 失败: {e}，正在降级为终端控制台模式...")
        run_cli_mode(controller)


def test_file_mode(controller: AppController, audio_file: str):
    """测试指定音频文件的转写效果"""
    import wave
    import numpy as np

    print(f"\n[测试模式] 正在测试音频文件: {audio_file}")
    with wave.open(audio_file, "rb") as wf:
        sr = wf.getframerate()
        frames = wf.readframes(wf.getnframes())
        samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    text, stats = controller.asr.transcribe(samples, sample_rate=sr)
    print("=" * 50)
    print(f"转写结果: {text}")
    print(f"统计信息: 时长={stats['duration']}s, 耗时={stats['latency']}s, RTF={stats['rtf']}")
    print("=" * 50)


def main():
    parser = argparse.ArgumentParser(description="MyWisper: 本地 SenseVoice-Small 极速语音输入法 (Wispr Flow 替代品)")
    parser.add_argument("--cli", action="store_true", help="强制使用终端控制台模式运行 (无顶部菜单栏图标)")
    parser.add_argument("--gui", action="store_true", help="以 macOS 菜单栏图标模式运行")
    parser.add_argument("--test-file", type=str, default=None, help="对指定 wav 文件进行识别测试")
    args = parser.parse_args()

    controller = AppController()

    if args.test_file:
        test_file_mode(controller, args.test_file)
        return

    if args.cli:
        run_cli_mode(controller)
    else:
        run_gui_mode(controller)


if __name__ == "__main__":
    main()
