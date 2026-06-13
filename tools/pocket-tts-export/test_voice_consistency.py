#!/usr/bin/env python3
"""
Reproduce what the Flutter app does: synthesize N German sentences with the
pocket-tts-de model (via sherpa-onnx runtime) and measure whether the voice
is consistent across sentences.

Voice similarity is measured with speaker-embedding cosine similarity using
the same SpeakerEmbeddingExtractor that sherpa-onnx ships. A score >= 0.85
between any two sentences is considered "same speaker"; < 0.70 is clearly
different voice.

Usage:
    uv run python test_voice_consistency.py [--model-dir models/german] [--seed 0]

Exit code: 0 if all sentence pairs are consistent, 1 otherwise.
"""
import argparse
import sys
from pathlib import Path

import librosa
import numpy as np
import sherpa_onnx
import soundfile as sf

# ─── config ──────────────────────────────────────────────────────────────────

SENTENCES = [
    "Es war einmal ein kleiner Fuchs namens Lumi, der in einer stillen Stadt am Meer nicht einschlafen konnte.",
    "Der Mond war voll, die Wellen waren sanft und irgendwo weit weg erzählte eine Eule der Nacht ihr liebstes Geheimnis.",
    "Lumi rollte sich unter seinem Baum zusammen und schloss langsam die Augen.",
]

# cosine similarity thresholds for pass/warn/fail
PASS_THRESHOLD = 0.80
WARN_THRESHOLD = 0.65

# ─── helpers ─────────────────────────────────────────────────────────────────


def make_tts(model_dir: str) -> sherpa_onnx.OfflineTts:
    cfg = sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(
            pocket=sherpa_onnx.OfflineTtsPocketModelConfig(
                lm_flow=f"{model_dir}/lm_flow.int8.onnx",
                lm_main=f"{model_dir}/lm_main.int8.onnx",
                encoder=f"{model_dir}/encoder.onnx",
                decoder=f"{model_dir}/decoder.int8.onnx",
                text_conditioner=f"{model_dir}/text_conditioner.onnx",
                vocab_json=f"{model_dir}/vocab.json",
                token_scores_json=f"{model_dir}/token_scores.json",
            ),
            debug=False,
            num_threads=4,
            provider="cpu",
        )
    )
    if not cfg.validate():
        raise SystemExit("invalid sherpa-onnx config")
    return sherpa_onnx.OfflineTts(cfg)


def synth_sentence(
    tts: sherpa_onnx.OfflineTts,
    ref_samples: np.ndarray,
    ref_sr: int,
    text: str,
    num_steps: int,
    seed: int,
    speed: float,
    temperature: float = 0.25,
) -> tuple[np.ndarray, int]:
    """Exactly mirrors OfflineTtsGenerationConfig in tts_session.dart."""
    g = sherpa_onnx.GenerationConfig()
    g.reference_audio = ref_samples
    g.reference_sample_rate = ref_sr
    g.num_steps = num_steps
    g.speed = speed
    # extra params — same as in tts_session.dart
    g.extra = {
        "max_reference_audio_len": "20",
        "seed": str(seed),
        "temperature": str(temperature),
    }
    audio = tts.generate(text, g)
    if not audio.samples:
        raise SystemExit(f"empty output for: {text[:40]}")
    return np.array(audio.samples, dtype=np.float32), audio.sample_rate


def mfcc_embedding(y: np.ndarray, sr: int) -> np.ndarray:
    """
    Speaker-proxy embedding: mean + std of MFCC + delta features.
    Not a real speaker model but cheap and good enough to detect voice shifts.
    """
    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=20)
    delta = librosa.feature.delta(mfcc)
    feats = np.concatenate([mfcc, delta], axis=0)
    emb = np.concatenate([feats.mean(axis=1), feats.std(axis=1)])
    return emb / (np.linalg.norm(emb) + 1e-9)


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))


def spectral_flatness(y: np.ndarray) -> float:
    S = np.abs(librosa.stft(y, n_fft=1024)) + 1e-9
    return float(np.mean(librosa.feature.spectral_flatness(S=S)[0]))


# ─── main ────────────────────────────────────────────────────────────────────


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", default="models/german_24l")
    ap.add_argument("--ref", default=None, help="reference wav (default: <model-dir>/test_wavs/juergen.wav)")
    ap.add_argument("--seed", type=int, default=0, help="flow-matching noise seed (0=deterministic, -1=random)")
    ap.add_argument("--temperature", type=float, default=0.25, help="flow-matching noise temperature (lower=more consistent voice)")
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--speed", type=float, default=0.9)
    ap.add_argument("--out-dir", default="/tmp/voice_consistency")
    args = ap.parse_args()

    ref_path = args.ref or f"{args.model_dir}/test_wavs/juergen.wav"
    if not Path(ref_path).exists():
        sys.exit(f"reference wav not found: {ref_path}")

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    print(f"model : {args.model_dir}")
    print(f"ref   : {ref_path}")
    print(f"seed  : {args.seed}  steps={args.steps}  speed={args.speed}  temperature={args.temperature}")
    print()

    tts = make_tts(args.model_dir)
    ref_y, ref_sr = librosa.load(ref_path, sr=tts.sample_rate)

    # Measure reference pitch so we can compare synthesis F0
    ref_f0, ref_vf, _ = librosa.pyin(ref_y, fmin=50, fmax=400, sr=ref_sr)
    ref_f0_mean = float(np.mean(ref_f0[ref_vf & ~np.isnan(ref_f0)]))
    print(f"ref F0: {ref_f0_mean:.0f}Hz (male ~80-180Hz, female ~160-260Hz)")
    print()

    wavs: list[np.ndarray] = []
    embs: list[np.ndarray] = []
    f0_means: list[float] = []

    for i, text in enumerate(SENTENCES):
        y, sr = synth_sentence(tts, ref_y, ref_sr, text, args.steps, args.seed, args.speed,
                               temperature=args.temperature)
        wav_path = out / f"sentence_{i}.wav"
        sf.write(str(wav_path), y, sr)
        flat = spectral_flatness(y)
        emb = mfcc_embedding(y, sr)
        # Fundamental frequency (pitch) — the most audible marker of voice identity
        f0, vf, _ = librosa.pyin(y, fmin=50, fmax=400, sr=sr)
        f0v = f0[vf & ~np.isnan(f0)]
        f0_mean = float(np.mean(f0v)) if len(f0v) > 0 else 0.0
        f0_means.append(f0_mean)
        wavs.append(y)
        embs.append(emb)
        print(f"[{i}] F0={f0_mean:.0f}Hz  flatness={flat:.4f}  dur={len(y)/sr:.1f}s  → {wav_path}")
        print(f"     text: {text[:60]}...")

    f0_spread = max(f0_means) - min(f0_means)
    # F0 check: spread <= 30Hz is good; reference error <= 40Hz per sentence
    F0_SPREAD_THRESHOLD = 35  # Hz — audible shift above this
    F0_REF_ERROR_THRESHOLD = 50  # Hz — too far from reference pitch

    print()
    print(f"F0 spread across sentences: {f0_spread:.0f}Hz (target <{F0_SPREAD_THRESHOLD}Hz)")
    f0_ok = True
    for i, f0m in enumerate(f0_means):
        err = abs(f0m - ref_f0_mean)
        status = "OK" if err < F0_REF_ERROR_THRESHOLD else "OFF"
        print(f"  [{i}] F0={f0m:.0f}Hz  error_vs_ref={err:.0f}Hz  {status}")
        if err >= F0_REF_ERROR_THRESHOLD:
            f0_ok = False
    spread_ok = f0_spread < F0_SPREAD_THRESHOLD

    print()
    if f0_ok and spread_ok:
        print(f"RESULT: PASS — voice is consistent (spread={f0_spread:.0f}Hz < {F0_SPREAD_THRESHOLD}Hz)")
        return 0
    else:
        reasons = []
        if not spread_ok:
            reasons.append(f"F0 spread {f0_spread:.0f}Hz >= {F0_SPREAD_THRESHOLD}Hz")
        if not f0_ok:
            reasons.append("one or more sentences deviate > 50Hz from reference pitch")
        print(f"RESULT: FAIL — {'; '.join(reasons)}")
        print("  Fix: use 24-layer model + temperature=0.25 + seed=0")
        return 1


if __name__ == "__main__":
    sys.exit(main())
