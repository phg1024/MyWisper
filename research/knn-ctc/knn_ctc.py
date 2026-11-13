"""kNN-CTC on the user's own recordings (https://arxiv.org/abs/2312.13560), leave-one-out.

Memory: for every recording with a known final text, the CTC forced alignment of that text gives each
non-blank frame a token; the frame's encoder output is the key, the token the value. Decoding a new
recording, every frame the model would emit a token on looks up its nearest keys and mixes their tokens
into the model's distribution, weighted by how close they are.

    python knn_ctc.py            # leave-one-out on ~/Library/Application Support/MyWisper/Recordings
"""
import re
import sys
import unicodedata
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from sensevoice import BLANK, MODEL_DIR, SenseVoice, load_wav, recordings


def align(logp: np.ndarray, labels: list[int]) -> np.ndarray | None:
    """CTC Viterbi forced alignment: the token (or blank) each frame belongs to, or None if it can't fit."""
    T, S = len(logp), 2 * len(labels) + 1
    if not labels or T < len(labels):
        return None
    ext = np.full(S, BLANK)
    ext[1::2] = labels
    # A state may skip the blank before it when the token differs from the one two states back.
    skip = np.zeros(S, bool)
    skip[3::2] = ext[3::2] != ext[1:-2:2]
    score = np.full(S, -np.inf)
    score[:2] = logp[0, ext[:2]]
    back = np.zeros((T, S), np.int8)
    for t in range(1, T):
        stay = score
        step = np.concatenate([[-np.inf], score[:-1]])
        jump = np.where(skip, np.concatenate([[-np.inf, -np.inf], score[:-2]]), -np.inf)
        cand = np.stack([stay, step, jump])
        back[t] = cand.argmax(0)
        score = cand.max(0) + logp[t, ext]
    s = S - 1 if score[S - 1] >= score[S - 2] else S - 2
    if not np.isfinite(score[s]):
        return None
    path = np.empty(T, int)
    for t in range(T - 1, -1, -1):
        path[t] = ext[s]
        s -= int(back[t, s])
    return path


def normalize(text: str) -> str:
    """For scoring: no punctuation, no spaces, lower case."""
    return "".join(c for c in text.lower() if not c.isspace() and not unicodedata.category(c).startswith("P"))


def cer(hyp: str, ref: str) -> tuple[int, int]:
    h, r = normalize(hyp), normalize(ref)
    d = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hc in enumerate(h, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (rc != hc))
    return d[len(h)], len(r)


class Memory:
    def __init__(self, keys: np.ndarray, values: np.ndarray, vocab: int):
        self.keys = keys / np.linalg.norm(keys, axis=1, keepdims=True)
        self.values = values
        self.vocab = vocab

    def decode(self, sv: SenseVoice, logp: np.ndarray, enc: np.ndarray, k=8, lam=0.5, temp=0.05, gate=0.8,
               unsure=1.0) -> list[int]:
        """`unsure`: only frames whose top probability is below this, near a frame the model emits on."""
        probs = np.exp(logp)
        near = np.convolve((probs.argmax(-1) != BLANK).astype(float), np.ones(3), "same") > 0
        emit = near & (probs.max(-1) < unsure)
        if emit.any() and len(self.keys):
            q = enc[emit] / np.linalg.norm(enc[emit], axis=1, keepdims=True)
            sims = np.nan_to_num(q @ self.keys.T, nan=-1.0)
            top = np.argsort(-sims, axis=1)[:, :k]
            top_sims = np.take_along_axis(sims, top, 1)
            w = np.exp((top_sims - top_sims[:, :1]) / temp)
            w /= w.sum(1, keepdims=True)
            knn = np.zeros((len(q), self.vocab), np.float32)
            np.add.at(knn, (np.arange(len(q))[:, None], self.values[top]), w)
            # Only frames that sound like something in memory: a far neighbour is no evidence at all.
            mix = lam * (top_sims[:, :1] >= gate)
            probs[emit] = (1 - mix) * probs[emit] + mix * knn
        return sv.greedy(np.log(probs + 1e-12))


def main():
    sv = SenseVoice()
    data = []
    for wav, info in recordings():
        logp, enc = sv.run(load_wav(wav))
        label = info["typed"]
        path = align(logp, sv.tokenize(label))
        if path is None:
            continue
        data.append(dict(name=wav.stem, label=label, logp=logp, enc=enc, path=path))
    print(f"{len(data)} recordings aligned")

    def memory(exclude: int) -> Memory:
        keys, values = [], []
        for i, d in enumerate(data):
            if i == exclude:
                continue
            # Blank frames next to a token too, so the memory also says where a word ends.
            keep = np.convolve((d["path"] != BLANK).astype(float), np.ones(3), "same") > 0
            keys.append(d["enc"][keep])
            values.append(d["path"][keep])
        return Memory(np.concatenate(keys), np.concatenate(values), len(sv.pieces))

    memories = [memory(i) for i in range(len(data))]
    base = [sv.text(sv.greedy(d["logp"])) for d in data]
    base_err = [cer(b, d["label"]) for b, d in zip(base, data)]
    total = sum(n for _, n in base_err)
    print(f"baseline CER {sum(e for e, _ in base_err) / total:.3%}")

    others = [load_wav(p) for p in sorted((MODEL_DIR / "test_wavs").glob("*.wav"))]
    others = [sv.run(x) for x in others]
    full = memory(-1)

    best = None
    for gate in (0.8, 0.9):
        for lam in (0.3, 0.6):
            for unsure in (0.6, 0.9, 1.0):
                temp = 0.05
                outs = [sv.text(m.decode(sv, d["logp"], d["enc"], lam=lam, temp=temp, gate=gate, unsure=unsure)) for m, d in zip(memories, data)]
                err = [cer(o, d["label"]) for o, d in zip(outs, data)]
                better = sum(e[0] < b[0] for e, b in zip(err, base_err))
                worse = sum(e[0] > b[0] for e, b in zip(err, base_err))
                # Other speakers (the model's own test clips) should come out exactly as before.
                changed = sum(sv.greedy(lp) != full.decode(sv, lp, en, lam=lam, temp=temp, gate=gate, unsure=unsure) for lp, en in others)
                rate = sum(e for e, _ in err) / total
                print(f"gate {gate} lam {lam} unsure {unsure}: CER {rate:.3%}  better {better} worse {worse}  other speakers changed {changed}/{len(others)}")
                if best is None or rate < best[0]:
                    best = (rate, gate, lam, temp, outs)

    rate, gate, lam, temp, outs = best
    print(f"\nbest: gate {gate} lam {lam} temp {temp}, CER {rate:.3%}\n")
    for d, b, o in zip(data, base, outs):
        if normalize(b) != normalize(o):
            print(f"{d['name']}\n  label: {d['label']}\n  base : {b}\n  knn  : {o}")


if __name__ == "__main__":
    main()
