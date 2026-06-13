#!/usr/bin/env python3
"""
Quality test for exported Pocket TTS models (via sherpa-onnx runtime).

Synthesizes language-appropriate sentences and checks three quality dimensions:
  1. Voice consistency  — F0 spread across sentences < 35Hz, each sentence
                          within 50Hz of the reference speaker's pitch.
  2. Audio completeness — each sentence lasts at least 0.12 s/word (a very
                          lenient minimum; a sentence cut off mid-way will fail).
  3. Spectral cleanliness — per-sentence spectral flatness < 0.08; higher
                            values indicate broadband noise / decoder artifacts.

Usage:
    uv run python test_voice_consistency.py [--model-dir models/german_24l]
    uv run python test_voice_consistency.py --model-dir /tmp/sherpa-onnx-pocket-tts-int8-2026-01-26 \\
        --ref /tmp/sherpa-onnx-pocket-tts-int8-2026-01-26/test_wavs/bria.wav --language en

Exit code: 0 = all checks PASS, 1 = any check FAIL.
"""
import argparse
import sys
from pathlib import Path

import librosa
import numpy as np
import sherpa_onnx
import soundfile as sf

# ─── language-appropriate sentence sets ──────────────────────────────────────

SENTENCES: dict[str, list[str]] = {
    "de": [
        "Es war einmal ein kleiner Fuchs namens Lumi, der in einer stillen Stadt am Meer nicht einschlafen konnte.",
        "Der Mond war voll, die Wellen waren sanft und irgendwo weit weg erzählte eine Eule der Nacht ihr liebstes Geheimnis.",
        "Lumi rollte sich unter seinem Baum zusammen und schloss langsam die Augen.",
    ],
    "en": [
        "Once upon a time there was a little fox named Lumi who could not fall asleep in a quiet town by the sea.",
        "The moon was full, the waves were gentle, and somewhere far away an owl whispered its dearest secret to the night.",
        "Lumi curled up beneath his tree and slowly closed his eyes.",
    ],
    "fr": [
        "Il était une fois un petit renard nommé Lumi qui n'arrivait pas à s'endormir dans une ville tranquille au bord de la mer.",
        "La lune était pleine, les vagues étaient douces et quelque part au loin un hibou murmurait son secret préféré à la nuit.",
        "Lumi se blottit sous son arbre et ferma lentement les yeux.",
    ],
    "es": [
        "Había una vez un pequeño zorro llamado Lumi que no podía dormirse en una tranquila ciudad junto al mar.",
        "La luna estaba llena, las olas eran suaves y en algún lugar lejano un búho susurraba su secreto favorito a la noche.",
        "Lumi se acurrucó bajo su árbol y cerró lentamente los ojos.",
    ],
}

# ─── quality thresholds ───────────────────────────────────────────────────────

F0_SPREAD_THRESHOLD = 35      # Hz — audible pitch shift above this
F0_REF_ERROR_THRESHOLD = 50   # Hz — each sentence vs reference speaker
FLATNESS_THRESHOLD = 0.08     # higher = broadband noise; clean TTS ~0.02-0.05
MIN_SECS_PER_WORD = 0.12      # very lenient; catches severely cut-off audio

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
    g = sherpa_onnx.GenerationConfig()
    g.reference_audio = ref_samples
    g.reference_sample_rate = ref_sr
    g.num_steps = num_steps
    g.speed = speed
    g.extra = {
        "max_reference_audio_len": "20",
        "seed": str(seed),
        "temperature": str(temperature),
    }
    audio = tts.generate(text, g)
    if not audio.samples:
        raise SystemExit(f"empty output for: {text[:40]}")
    return np.array(audio.samples, dtype=np.float32), audio.sample_rate


def spectral_flatness(y: np.ndarray) -> float:
    S = np.abs(librosa.stft(y, n_fft=1024)) + 1e-9
    return float(np.mean(librosa.feature.spectral_flatness(S=S)[0]))


def get_f0(y: np.ndarray, sr: int) -> float:
    f0, vf, _ = librosa.pyin(y, fmin=50, fmax=400, sr=sr)
    f0v = f0[vf & ~np.isnan(f0)] if vf is not None else np.array([])
    return float(np.mean(f0v)) if len(f0v) > 0 else 0.0


def detect_language(model_dir: str) -> str:
    d = model_dir.lower()
    if "french" in d or "_fr" in d or "/fr" in d:
        return "fr"
    if "spanish" in d or "_es" in d or "/es" in d:
        return "es"
    if "english" in d or "_en" in d or "/en" in d or "pocket-tts-int8" in d:
        return "en"
    return "de"  # default


def run_model(
    model_dir: str,
    ref_path: str,
    language: str,
    seed: int,
    steps: int,
    speed: float,
    temperature: float,
    out_dir: Path,
) -> bool:
    """
    Synthesize sentences and check all three quality dimensions.
    Returns True if all checks pass.
    """
    sentences = SENTENCES.get(language, SENTENCES["de"])

    print(f"model    : {model_dir}")
    print(f"language : {language}")
    print(f"ref      : {ref_path}")
    print(f"seed     : {seed}  steps={steps}  speed={speed}  temperature={temperature}")
    print()

    tts = make_tts(model_dir)
    ref_y, ref_sr = librosa.load(ref_path, sr=tts.sample_rate)

    ref_f0_mean = get_f0(ref_y, ref_sr)
    print(f"ref F0: {ref_f0_mean:.0f}Hz (male ~80-180Hz, female ~160-260Hz)")
    print()

    f0_means: list[float] = []
    flatnesses: list[float] = []
    durations: list[float] = []
    word_counts: list[int] = []

    out_dir.mkdir(parents=True, exist_ok=True)

    for i, text in enumerate(sentences):
        y, sr = synth_sentence(tts, ref_y, ref_sr, text, steps, seed, speed,
                               temperature=temperature)
        wav_path = out_dir / f"sentence_{i}.wav"
        sf.write(str(wav_path), y, sr)

        f0 = get_f0(y, sr)
        flat = spectral_flatness(y)
        dur = len(y) / sr
        wc = len(text.split())

        f0_means.append(f0)
        flatnesses.append(flat)
        durations.append(dur)
        word_counts.append(wc)

        min_dur = wc * MIN_SECS_PER_WORD
        dur_ok = dur >= min_dur
        flat_ok = flat < FLATNESS_THRESHOLD

        dur_flag = "OK" if dur_ok else f"SHORT(min={min_dur:.1f}s)"
        flat_flag = "OK" if flat_ok else f"NOISY(>={FLATNESS_THRESHOLD:.2f})"

        print(f"[{i}] F0={f0:.0f}Hz  flatness={flat:.4f}  dur={dur:.1f}s  words={wc}")
        print(f"     {dur_flag}  {flat_flag}")
        print(f"     text: {text[:70]}...")

    # ── check 1: voice consistency (F0 spread) ────────────────────────────────
    print()
    f0_spread = max(f0_means) - min(f0_means)
    print(f"Check 1 — Voice consistency (F0 spread across sentences):")
    print(f"  spread={f0_spread:.0f}Hz  threshold=<{F0_SPREAD_THRESHOLD}Hz")
    spread_ok = f0_spread < F0_SPREAD_THRESHOLD
    ref_errors_ok = True
    for i, f0m in enumerate(f0_means):
        err = abs(f0m - ref_f0_mean)
        ok = err < F0_REF_ERROR_THRESHOLD
        print(f"  [{i}] F0={f0m:.0f}Hz  error_vs_ref={err:.0f}Hz  {'OK' if ok else 'OFF'}")
        if not ok:
            ref_errors_ok = False
    consistency_pass = spread_ok and ref_errors_ok

    # ── check 2: audio completeness (cut-off) ────────────────────────────────
    print()
    print(f"Check 2 — Audio completeness (min {MIN_SECS_PER_WORD:.2f}s/word):")
    completeness_pass = True
    for i, (dur, wc) in enumerate(zip(durations, word_counts)):
        min_dur = wc * MIN_SECS_PER_WORD
        ok = dur >= min_dur
        rate = dur / wc
        print(f"  [{i}] dur={dur:.1f}s  words={wc}  rate={rate:.2f}s/word  min={min_dur:.1f}s  {'OK' if ok else 'CUT-OFF'}")
        if not ok:
            completeness_pass = False

    # ── check 3: spectral cleanliness (noise) ────────────────────────────────
    print()
    print(f"Check 3 — Spectral cleanliness (flatness < {FLATNESS_THRESHOLD:.2f}):")
    cleanliness_pass = True
    for i, flat in enumerate(flatnesses):
        ok = flat < FLATNESS_THRESHOLD
        print(f"  [{i}] flatness={flat:.4f}  {'OK' if ok else 'NOISY'}")
        if not ok:
            cleanliness_pass = False

    # ── overall result ────────────────────────────────────────────────────────
    print()
    all_pass = consistency_pass and completeness_pass and cleanliness_pass
    if all_pass:
        print("RESULT: PASS — all three quality checks passed")
    else:
        fails = []
        if not consistency_pass:
            fails.append(f"voice inconsistency (spread={f0_spread:.0f}Hz)")
        if not completeness_pass:
            fails.append("audio cut-off")
        if not cleanliness_pass:
            fails.append("background noise")
        print(f"RESULT: FAIL — {'; '.join(fails)}")
    return all_pass


# ─── main ────────────────────────────────────────────────────────────────────


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", default="models/german_24l")
    ap.add_argument("--ref", default=None,
                    help="reference wav (default: <model-dir>/test_wavs/juergen.wav)")
    ap.add_argument("--language", default=None,
                    help="sentence language: de|en|fr|es (auto-detected from model-dir if omitted)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--temperature", type=float, default=0.25)
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--speed", type=float, default=0.9)
    ap.add_argument("--out-dir", default="/tmp/voice_consistency")
    ap.add_argument("--en-baseline", action="store_true",
                    help="also run the official EN model as a sanity baseline "
                         "(expects /tmp/sherpa-onnx-pocket-tts-int8-2026-01-26)")
    args = ap.parse_args()

    language = args.language or detect_language(args.model_dir)
    ref_path = args.ref or f"{args.model_dir}/test_wavs/juergen.wav"

    if not Path(ref_path).exists():
        sys.exit(f"reference wav not found: {ref_path}")

    overall_pass = True

    # ── primary model ─────────────────────────────────────────────────────────
    out_dir = Path(args.out_dir) / Path(args.model_dir).name
    ok = run_model(
        model_dir=args.model_dir,
        ref_path=ref_path,
        language=language,
        seed=args.seed,
        steps=args.steps,
        speed=args.speed,
        temperature=args.temperature,
        out_dir=out_dir,
    )
    overall_pass = overall_pass and ok

    # ── EN baseline (optional sanity check) ───────────────────────────────────
    if args.en_baseline:
        en_dir = "/tmp/sherpa-onnx-pocket-tts-int8-2026-01-26"
        en_ref = f"{en_dir}/test_wavs/bria.wav"
        if not Path(en_dir).exists():
            print(f"\n[EN baseline] SKIP — model not found at {en_dir}")
        else:
            print(f"\n{'='*60}")
            print("EN BASELINE (should PASS on all checks)")
            print("="*60)
            en_out = Path(args.out_dir) / "en_baseline"
            en_ok = run_model(
                model_dir=en_dir,
                ref_path=en_ref,
                language="en",
                seed=args.seed,
                steps=args.steps,
                speed=args.speed,
                temperature=args.temperature,
                out_dir=en_out,
            )
            if not en_ok:
                print("  WARNING: EN baseline FAILED — something is wrong with the test itself")
            overall_pass = overall_pass and en_ok

    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
