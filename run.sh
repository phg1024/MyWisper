#!/usr/bin/env bash
# ==============================================================================
# MyWisper: 本地 SenseVoice-Small 极速语音输入法 (Wispr Flow 替代方案)
# 一键启动脚本
# ==============================================================================

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# 检查虚拟环境
if [ ! -d "venv" ]; then
    echo "❌ 未检测到虚拟环境，正在运行初始化..."
    python3 -m venv venv
    ./venv/bin/pip install --upgrade pip
    ./venv/bin/pip install sherpa-onnx sounddevice numpy pyperclip pynput rumps
fi

# 检查模型文件
if [ ! -f "models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx" ]; then
    echo "❌ 未检测到 SenseVoice-Small 模型，请先下载模型文件。"
    exit 1
fi

echo "🚀 启动 MyWisper..."
exec ./venv/bin/python main.py "$@"
