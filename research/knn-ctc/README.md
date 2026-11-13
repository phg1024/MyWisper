# kNN-CTC memory experiment

Can a memory of the user's own confirmed recordings, consulted at decoding time, make SenseVoice better
for that user without changing the model? Method from [kNN-CTC](https://arxiv.org/abs/2312.13560).

```bash
python3 -m venv /tmp/knn && /tmp/knn/bin/pip install onnx onnxruntime numpy soundfile kaldi-native-fbank sentencepiece
curl -fLO https://huggingface.co/FunAudioLLM/SenseVoiceSmall/resolve/main/chn_jpn_yue_eng_ko_spectok.bpe.model
/tmp/knn/bin/python knn_ctc.py
```

- `sensevoice.py`: the sherpa-onnx int8 model with the encoder output exposed; features as sherpa-onnx
  computes them (44 of 61 recordings decode identically to the app, the rest differ on near-tied frames).
- `knn_ctc.py`: forced-aligns each recording's final text, keeps (encoder frame → token) pairs, and
  decodes every recording with a memory built from all the others.

## 2026-11-12, 61 recordings, labels = the text that was typed

Baseline CER 11.1%. With memory, 12.0–16.6% depending on settings: worse. Other speakers (the model's
test clips) are left unchanged by every setting with a similarity gate ≥ 0.8.

Why it doesn't help yet:
- The labels are what was typed, including the correction model's wrong guesses (比亚迪, 基拉韦厄).
  The memory faithfully learns those. Needs text the user actually confirmed (Training/, label `edited`).
- Frame-level mixing replaces single frames, so a word the model splits differently comes out half
  replaced ("christian" → "Christianristian"). Memory has to work on whole words or spans.
