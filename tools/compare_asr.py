#!/usr/bin/env python3
"""Compares SenseVoice (what MyWisper heard) with Whisper on recordings saved by MyWisper.

Turn on Settings › General › Save recordings, dictate as usual for a while, then run this with a
Python that has mlx-whisper installed (`pip install mlx-whisper`):

    python3 tools/compare_asr.py                     # all recordings, HTML report next to them
    python3 tools/compare_asr.py --vocab "GitHub, Homebridge, Bambuddy"

Everything runs locally. The Whisper model is read from the Hugging Face cache; if it isn't there,
mlx-whisper downloads it once.
"""
import argparse
import html
import json
import pathlib
import time
import wave

import mlx_whisper
import numpy as np

DEFAULT_DIR = pathlib.Path.home() / "Library/Application Support/MyWisper/Recordings"
MIXED_PROMPT = "以下是普通话的句子，中间夹杂一些English单词。"


def load_wav(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return pcm.astype(np.float32) / 32768.0


def whisper(audio, model, language=None, prompt=None):
    start = time.perf_counter()
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=model, language=language, initial_prompt=prompt,
                                    condition_on_previous_text=False, temperature=0.0, verbose=None)
    return result["text"].strip(), time.perf_counter() - start


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", type=pathlib.Path, default=DEFAULT_DIR)
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo")
    parser.add_argument("--vocab", default="", help="words Whisper should prefer, added to its prompt")
    parser.add_argument("--out", type=pathlib.Path, help="HTML report (default: <dir>/compare.html)")
    args = parser.parse_args()

    clips = sorted(args.dir.glob("*.wav"))
    if not clips:
        raise SystemExit(f"no recordings in {args.dir}")
    prompt = MIXED_PROMPT + (f" {args.vocab}" if args.vocab else "")

    whisper(np.zeros(16000, dtype=np.float32), args.model)  # load the model before timing anything
    rows = []
    for clip in clips:
        info_path = clip.with_suffix(".json")
        info = json.loads(info_path.read_text()) if info_path.exists() else {}
        audio = load_wav(clip)
        auto, auto_time = whisper(audio, args.model)
        mixed, mixed_time = whisper(audio, args.model, language="zh", prompt=prompt)
        rows.append({"clip": clip.name, "duration": len(audio) / 16000, "sensevoice": info.get("typed", "?"),
                     "auto": auto, "auto_time": auto_time, "mixed": mixed, "mixed_time": mixed_time})
        print(f"\n{clip.name} ({rows[-1]['duration']:.1f}s)\n"
              f"  SenseVoice      {rows[-1]['sensevoice']}\n"
              f"  Whisper auto    {auto}  [{auto_time * 1000:.0f} ms]\n"
              f"  Whisper zh+提示 {mixed}  [{mixed_time * 1000:.0f} ms]")

    out = args.out or args.dir / "compare.html"
    cell = lambda s: f"<td>{html.escape(s)}</td>"
    body = "".join(
        f"<tr><td class=m>{html.escape(r['clip'])}<br>{r['duration']:.1f} s</td>{cell(r['sensevoice'])}"
        f"<td>{html.escape(r['auto'])}<div class=m>{r['auto_time'] * 1000:.0f} ms</div></td>"
        f"<td>{html.escape(r['mixed'])}<div class=m>{r['mixed_time'] * 1000:.0f} ms</div></td></tr>"
        for r in rows)
    out.write_text(f"""<!doctype html><meta charset=utf-8><title>MyWisper ASR comparison</title>
<style>body{{font:15px -apple-system,sans-serif;margin:24px}}table{{border-collapse:collapse}}
td,th{{border:1px solid #ccc;padding:8px;vertical-align:top;max-width:420px}}.m{{color:#888;font-size:12px}}</style>
<h2>SenseVoice vs Whisper ({html.escape(args.model)})</h2>
<p class=m>Whisper zh+提示 prompt: {html.escape(prompt)}</p>
<table><tr><th>Clip</th><th>SenseVoice (typed)</th><th>Whisper auto</th><th>Whisper zh + prompt</th></tr>{body}</table>
""")
    print(f"\nreport: {out}")


if __name__ == "__main__":
    main()
