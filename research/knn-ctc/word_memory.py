"""Whole-word memory on the user's own recordings, leave-one-out.

The memory holds words the user has corrected to, each with the stretches of encoder output where they
said it (from forced alignment of the corrected text). Decoding a new recording, every exemplar is
matched against the encoder output with subsequence DTW; where one matches closely and the model itself
finds the word plausible there (CTC score of the word on that stretch, against the best path), the
words the model wrote for that stretch are replaced by the remembered word, whole.

Compared with the text fixes the app already learns ("kiowway" → "Kilauea" only when it is misheard
exactly the same way again), this should catch the same word misheard differently.

    python word_memory.py truth.json

truth.json: [["misheard", "meant"], ...], what the user actually said, applied to the model's own output
to get each recording's reference. Kept out of the repository: it is the user's speech.
"""
import json
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from knn_ctc import cer, normalize
from sensevoice import BLANK, MODEL_DIR, SenseVoice, load_wav, recordings


def replace(text: str, pairs) -> str:
    """Text fixes as the app applies them: English as whole words in any case, other text as is."""
    for heard, meant in sorted(pairs, key=lambda p: -len(p[0])):
        if heard.isascii():
            text = re.sub(r"(?<![A-Za-z0-9])" + re.escape(heard) + r"(?![A-Za-z0-9])", meant, text, flags=re.I)
        else:
            text = text.replace(heard, meant)
    return text


def viterbi(logp: np.ndarray, labels: list[int]):
    """CTC Viterbi: (best score, the label index each frame is on or -1 for blank), or (-inf, None)."""
    T, S = len(logp), 2 * len(labels) + 1
    if not labels or T < len(labels):
        return -np.inf, None
    ext = np.full(S, BLANK)
    ext[1::2] = labels
    skip = np.zeros(S, bool)
    skip[3::2] = ext[3::2] != ext[1:-2:2]
    score = np.full(S, -np.inf)
    score[:2] = logp[0, ext[:2]]
    back = np.zeros((T, S), np.int8)
    for t in range(1, T):
        cand = np.stack([score, np.concatenate([[-np.inf], score[:-1]]),
                         np.where(skip, np.concatenate([[-np.inf, -np.inf], score[:-2]]), -np.inf)])
        back[t] = cand.argmax(0)
        score = cand.max(0) + logp[t, ext]
    s = S - 1 if score[S - 1] >= score[S - 2] else S - 2
    best = score[s]
    if not np.isfinite(best):
        return -np.inf, None
    states = np.empty(T, int)
    for t in range(T - 1, -1, -1):
        states[t] = s
        s -= int(back[t, s])
    return best, np.where(states % 2 == 1, (states - 1) // 2, -1)


def unit(x: np.ndarray) -> np.ndarray:
    return x / np.maximum(np.linalg.norm(x, axis=-1, keepdims=True), 1e-6)


def sdtw(ex: np.ndarray, q: np.ndarray):
    """Subsequence DTW of exemplar `ex` [L, D] anywhere in `q` [T, D] (both unit rows), slope between
    1/2 and 2. Returns per end frame: average cosine distance along the best path, and its start frame."""
    C = 1 - ex @ q.T
    L, T = C.shape
    inf = np.full(T, np.inf)
    D, N, S = [C[0].copy()], [np.ones(T)], [np.arange(T)]
    shift = lambda a, k, fill: np.concatenate([np.full(k, fill), a[:-k]])
    for i in range(1, L):
        # One query frame per exemplar frame, two (the user said it slower), or half (faster).
        cands = [(shift(D[i - 1], 1, np.inf) + C[i], shift(N[i - 1], 1, 1) + 1, shift(S[i - 1], 1, 0)),
                 (shift(D[i - 1], 2, np.inf) + shift(C[i], 1, np.inf) + C[i], shift(N[i - 1], 2, 1) + 2, shift(S[i - 1], 2, 0))]
        if i >= 2:
            cands.append((shift(D[i - 2], 1, np.inf) + C[i - 1] + C[i], shift(N[i - 2], 1, 1) + 2, shift(S[i - 2], 1, 0)))
        avg = np.stack([d / n for d, n, _ in cands])
        k = avg.argmin(0)
        pick = lambda j: np.choose(k, [c[j] for c in cands])
        D.append(pick(0)); N.append(pick(1)); S.append(pick(2))
    return D[-1] / N[-1], S[-1].astype(int)


class Decoded:
    """Greedy CTC output with the frame each token was emitted on."""

    def __init__(self, sv: SenseVoice, logp: np.ndarray):
        best = logp.argmax(-1)
        self.ids, self.frames = [], []
        prev = -1
        for t, k in enumerate(best):
            if k != prev and k != BLANK:
                self.ids.append(int(k)); self.frames.append(t)
            prev = k
        self.sv = sv

    def text(self) -> str:
        return self.sv.text(self.ids)

    def word_span(self, a: int, b: int) -> tuple[int, int]:
        """Token range [a, b) widened to whole English words (pieces continue a word unless they start with ▁)."""
        p = self.sv.pieces
        latin = lambda i: p[self.ids[i]].lstrip("▁")[:1].isascii() and p[self.ids[i]].lstrip("▁")[:1].isalpha()
        while 0 < a < len(self.ids) and latin(a) and not p[self.ids[a]].startswith("▁") and latin(a - 1):
            a -= 1
        while b < len(self.ids) and latin(b) and not p[self.ids[b]].startswith("▁") and b > 0 and latin(b - 1):
            b += 1
        return a, b

    def replace(self, start: int, end: int, ids: list[int]):
        """Replaces the tokens emitted on frames [start, end] by `ids`."""
        inside = [i for i, f in enumerate(self.frames) if start <= f <= end]
        if not inside:
            return False
        a, b = self.word_span(inside[0], inside[-1] + 1)
        if self.ids[a:b] == ids:
            return False
        lead = self.sv.pieces[ids[0]]
        if lead[:1].isascii() and lead[:1].isalpha() and a > 0 and self.sv.pieces[self.ids[a - 1]][-1:].isascii():
            # An English word after English: keep them apart.
            ids = [self.sv.sp.piece_to_id("▁")] + ids
        frames = list(np.linspace(self.frames[a], self.frames[b - 1], len(ids)).astype(int))
        self.ids[a:b], self.frames[a:b] = ids, frames
        return True


def main():
    truth = [tuple(p) for p in json.loads(Path(sys.argv[1]).read_text())]
    sv = SenseVoice()
    data = []
    for wav, _ in recordings():
        logp, enc = sv.run(load_wav(wav))
        base = sv.text(sv.greedy(logp))
        ref = replace(base, truth)
        data.append(dict(name=wav.stem, logp=logp, enc=unit(enc), base=base, ref=ref,
                         fixes={p for p in truth if p[0].lower() in base.lower()}))

    # Every occurrence of a corrected-to word: its encoder frames, from aligning the reference.
    words = sorted({m for _, m in truth})
    for d in data:
        d["exemplars"] = []
        ids = sv.tokenize(d["ref"])
        _, owner = viterbi(d["logp"], ids)
        if owner is None:
            continue
        pieces = [sv.pieces[i].replace("▁", " ") for i in ids]
        offsets = np.cumsum([0] + [len(p) for p in pieces])
        flat = "".join(pieces)
        for w in words:
            for m in re.finditer(re.escape(w), flat, flags=re.I if w.isascii() else 0):
                a = int(np.searchsorted(offsets, m.start(), "right") - 1)
                b = int(np.searchsorted(offsets, m.end(), "left"))
                frames = np.nonzero((owner >= a) & (owner < b))[0]
                if len(frames):
                    span = slice(max(frames[0] - 1, 0), frames[-1] + 2)
                    d["exemplars"].append((w, d["enc"][span]))
    print(f"{len(data)} recordings, exemplars: " + ", ".join(
        f"{w} {sum(e[0] == w for d in data for e in d['exemplars'])}" for w in words))

    def decode(logp, enc, memory, tau, delta, log=None) -> str:
        out = Decoded(sv, logp)
        found = []
        for w, ex in memory:
            cost, start = sdtw(ex, enc)
            end = int(cost.argmin())
            if cost[end] <= tau:
                found.append((cost[end], w, int(start[end]), end))
        taken = np.zeros(len(logp), bool)
        for c, w, s, e in sorted(found):
            if taken[s:e + 1].any():
                continue
            # The model's own say: how much worse the word scores on this stretch than its best path.
            lo, hi = max(s - 2, 0), min(e + 3, len(logp))
            ids = sv.tokenize(w)
            word, _ = viterbi(logp[lo:hi], ids)
            gap = (logp[lo:hi].max(-1).sum() - word) / (hi - lo)
            if gap <= delta and out.replace(s, e, ids):
                taken[s:e + 1] = True
                if log is not None:
                    log.append(f"{w} (dtw {c:.2f}, gap {gap:.2f})")
        return out.text()

    systems = {"model": lambda i, d: d["base"],
               "text fixes": lambda i, d: replace(d["base"], set().union(*(o["fixes"] for j, o in enumerate(data) if j != i)))}
    others = [sv.run(load_wav(p)) for p in sorted((MODEL_DIR / "test_wavs").glob("*.wav"))]
    full = [e for d in data for e in d["exemplars"]]
    total = sum(len(normalize(d["ref"])) for d in data)
    targets = [(d, w) for d in data for w in words if re.search(re.escape(w), d["ref"], re.I if w.isascii() else 0)]

    def report(name, outs):
        err = sum(cer(o, d["ref"])[0] for o, d in zip(outs, data))
        right = sum(w.lower() in o.lower() for o, (d, w) in zip([outs[data.index(d)] for d, _ in targets], targets))
        broke = sum(cer(o, d["ref"])[0] > cer(d["base"], d["ref"])[0] for o, d in zip(outs, data))
        print(f"{name:34s} CER {err / total:.3%}  words right {right}/{len(targets)}  recordings made worse {broke}")

    for name, f in systems.items():
        report(name, [f(i, d) for i, d in enumerate(data)])
    best = None
    for tau in (0.15, 0.2, 0.25, 0.3, 0.35):
        for delta in (1.0, np.inf):
            outs = []
            for i, d in enumerate(data):
                memory = [e for j, o in enumerate(data) if j != i for e in o["exemplars"]]
                outs.append(systems["text fixes"](i, dict(d, base=decode(d["logp"], d["enc"], memory, tau, delta))))
            changed = sum(sv.text(sv.greedy(lp)) != decode(lp, unit(en), full, tau, delta) for lp, en in others)
            report(f"+ memory dtw≤{tau} gap≤{delta}", outs)
            print(f"{'':34s} other speakers changed {changed}/{len(others)}")
            err = sum(cer(o, d["ref"])[0] for o, d in zip(outs, data))
            if best is None or err < best[0]:
                best = (err, tau, delta)

    _, tau, delta = best if len(sys.argv) < 3 else (0, float(sys.argv[2]), np.inf)
    print(f"\nchanges at dtw≤{tau} gap≤{delta}:")
    for i, d in enumerate(data):
        log = []
        memory = [e for j, o in enumerate(data) if j != i for e in o["exemplars"]]
        out = decode(d["logp"], d["enc"], memory, tau, delta, log)
        if out != d["base"]:
            print(f"{d['name']}  {'; '.join(log)}\n  model : {d['base']}\n  memory: {out}\n  ref   : {d['ref']}")


if __name__ == "__main__":
    main()
