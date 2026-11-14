"""SenseVoice-Small (sherpa-onnx int8 export) with the encoder output exposed, for the kNN-CTC experiment.

Features match sherpa-onnx: 80-bin kaldi fbank (hamming, snip edges, no dither, samples scaled to
int16 range), LFR 7/6 (padded as in FunASR), CMVN from the model metadata. The model prepends 4 query frames (language, emotion, event, ITN).
"""
import json
from pathlib import Path

import kaldi_native_fbank as knf
import numpy as np
import onnx
import onnxruntime as ort
import sentencepiece as spm
import soundfile as sf

MODEL_DIR = Path(__file__).resolve().parents[2] / "models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
# SentencePiece model from https://huggingface.co/FunAudioLLM/SenseVoiceSmall (not in the sherpa-onnx export).
BPE_MODEL = Path(__file__).parent / "chn_jpn_yue_eng_ko_spectok.bpe.model"
ENCODER_OUT = "/encoder/tp_norm/Add_1_output_0"
BLANK = 0
PREFIX = 4


class SenseVoice:
    def __init__(self, model_dir: Path = MODEL_DIR):
        model = onnx.load(str(model_dir / "model.int8.onnx"))
        meta = {p.key: p.value for p in model.metadata_props}
        model.graph.output.append(onnx.helper.make_tensor_value_info(ENCODER_OUT, onnx.TensorProto.FLOAT, None))
        self.session = ort.InferenceSession(model.SerializeToString(), providers=["CPUExecutionProvider"])
        self.neg_mean = np.array([float(v) for v in meta["neg_mean"].split(",")], dtype=np.float32)
        self.inv_std = np.array([float(v) for v in meta["inv_stddev"].split(",")], dtype=np.float32)
        self.with_itn = int(meta["with_itn"])
        self.pieces = [line.rsplit(" ", 1)[0] for line in (model_dir / "tokens.txt").read_text().splitlines()]
        self.sp = spm.SentencePieceProcessor(model_file=str(BPE_MODEL))

    def features(self, samples: np.ndarray) -> np.ndarray:
        opts = knf.FbankOptions()
        opts.frame_opts.dither = 0
        opts.frame_opts.snip_edges = True
        opts.frame_opts.window_type = "hamming"
        opts.frame_opts.samp_freq = 16000
        opts.mel_opts.num_bins = 80
        fbank = knf.OnlineFbank(opts)
        fbank.accept_waveform(16000, (samples * 32768).tolist())
        fbank.input_finished()
        feats = np.stack([fbank.get_frame(i) for i in range(fbank.num_frames_ready)])
        # LFR: 7 frames stacked every 6, padded with copies of the first and last frame.
        feats = np.concatenate([np.repeat(feats[:1], 3, axis=0), feats])
        n = (len(feats) - 3 + 5) // 6
        out = []
        for i in range(n):
            chunk = feats[i * 6:i * 6 + 7]
            if len(chunk) < 7:
                chunk = np.concatenate([chunk, np.repeat(feats[-1:], 7 - len(chunk), axis=0)])
            out.append(chunk.reshape(-1))
        lfr = np.stack(out).astype(np.float32)
        return (lfr + self.neg_mean) * self.inv_std

    def run(self, samples: np.ndarray):
        """Returns (log-probs [T, V], encoder output [T, 512]) without the 4 prefix frames."""
        x = self.features(samples)[None]
        logits, enc = self.session.run(None, {
            "x": x, "x_length": np.array([x.shape[1]], dtype=np.int32),
            "language": np.array([0], dtype=np.int32), "text_norm": np.array([self.with_itn], dtype=np.int32)})
        logits = logits[0, PREFIX:]
        logp = logits - np.logaddexp.reduce(logits, axis=-1, keepdims=True)
        return logp.astype(np.float32), enc[0, PREFIX:].astype(np.float32)

    def greedy(self, logp: np.ndarray) -> list[int]:
        best = logp.argmax(-1)
        out, prev = [], -1
        for t in best:
            if t != prev and t != BLANK:
                out.append(int(t))
            prev = t
        return out

    def text(self, ids: list[int]) -> str:
        return "".join(self.pieces[i] for i in ids).replace("▁", " ").strip()

    def tokenize(self, text: str) -> list[int]:
        return [i for i in self.sp.encode(text) if self.pieces[i] != "▁"]


def load_wav(path) -> np.ndarray:
    samples, rate = sf.read(str(path), dtype="float32")
    assert rate == 16000, rate
    return samples if samples.ndim == 1 else samples.mean(1)


def recordings():
    """Saved recordings with the text the user ended up sending."""
    folder = Path.home() / "Library/Application Support/MyWisper/Recordings"
    for meta in sorted(folder.glob("*.json")):
        info = json.loads(meta.read_text())
        wav = meta.with_suffix(".wav")
        if wav.exists() and info.get("typed"):
            yield wav, info
