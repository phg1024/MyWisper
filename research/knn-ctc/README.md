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

## Whole-word memory (`word_memory.py`), 2026-11-12, 64 recordings

The memory holds the words the user corrected to, each with the encoder frames where they said it
(forced alignment of the corrected text). A new recording is searched for every exemplar with
subsequence DTW (cosine distance, slope 1/2–2); a close match replaces the words the model wrote for
that stretch, whole. Leave-one-out: a recording only sees exemplars from the others.

References: the model's own output with what was actually said put in by hand (`truth.json`, kept out of
the repository). Text fixes = what the app does today, the exact misheard string replaced.

| | CER | target words right | recordings made worse | other speakers changed |
|---|---|---|---|---|
| model | 3.36% | 8/29 | – | – |
| text fixes | 3.12% | 9/29 | 0 | – |
| + word memory, DTW ≤ 0.2 | **1.72%** | 16/29 | 0 | 0/5 |
| + word memory, DTW ≤ 0.3 | 1.82% | 18/29 | 2 | 0/5 |

- It generalizes where text fixes can't: "kiowway", "killkiowway" and "killlow away" all become
  Kilauea from one exemplar of each of the others; "好华一", "haii", "哈哇伊" become Hawaii; 大道 → 大岛.
- The misses are words said in only one recording (deploy, Flipper, random...), which leave-one-out
  can't fix by construction.
- Asking the model whether the word is plausible there (CTC score against the best path) doesn't work
  as a check: the model finds the right word implausible exactly where it misheard it.
- The margin is thin. True matches score 0.10–0.23; the worst false one, "clipper" (really said) →
  Flipper, scores 0.20. A word that sounds like a remembered one is the risk, so: replace only on very
  close matches, and hand weaker ones to the correction model as a hint, not an answer.
