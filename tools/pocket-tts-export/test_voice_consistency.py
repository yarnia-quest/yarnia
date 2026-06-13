#!/usr/bin/env python3
"""
Quality test for exported Pocket TTS models (via sherpa-onnx runtime).

Synthesizes the same text used in the spike screen and checks four quality
dimensions:

  1. Intelligibility (WER)  — Whisper transcribes each sentence; word error
                              rate < 20% means the audio is intelligible.
                              This is the PRIMARY quality gate: it catches
                              garbled audio, bad intonation, and collapsed
                              decoder output that sound bad even when F0 looks
                              fine on paper.
  2. Voice consistency (F0) — pitch spread across sentences < 35Hz.
  3. Audio completeness     — each sentence lasts ≥ 0.12 s/word.
  4. Spectral cleanliness   — per-sentence spectral flatness < 0.08.

Usage:
    uv run python test_voice_consistency.py                   # DE small
    uv run python test_voice_consistency.py --model-dir models/german_24l
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

# ─── test sentences — same story used in the spike screen ────────────────────
# Use correct Unicode characters (ä ö ü ß), NOT ASCII substitutions (ae oe ue ss).

SENTENCES: dict[str, list[str]] = {
    "de": [
        "Es war einmal ein kleiner Fuchs namens Lumi, der in einer stillen Stadt am Meer nicht einschlafen konnte.",
        "Der Mond war voll, die Wellen waren sanft, und irgendwo weit weg erzählte eine Eule der Nacht ihr liebstes Geheimnis.",
        "Also schloss Lumi die Augen und lauschte, und das Geheimnis wurde langsam zu einem Traum.",
    ],
    "en": [
        "Once upon a time there was a little fox named Lumi who could not fall asleep in a quiet town by the sea.",
        "The moon was full, the waves were gentle, and somewhere far away an owl whispered its dearest secret to the night.",
        "So Lumi closed her eyes and listened, and the secret slowly became a dream.",
    ],
    "fr": [
        "Il était une fois, dans une ville tranquille au bord de la mer, un petit renard nommé Lumi qui ne pouvait pas s'endormir.",
        "La lune était pleine, les vagues étaient douces, et quelque part au loin une chouette racontait à la nuit son secret préféré.",
        "Alors Lumi ferma les yeux et écouta, et le secret devint lentement un rêve.",
    ],
    "es": [
        "Había una vez, en un pueblo tranquilo junto al mar, un pequeño zorro llamado Lumi que no podía dormirse.",
        "La luna estaba llena, las olas eran suaves, y en algún lugar lejano un búho le contaba a la noche su secreto favorito.",
        "Así que Lumi cerró los ojos y escuchó, y el secreto se fue convirtiendo lentamente en un sueño.",
    ],
}

# ─── quality thresholds ───────────────────────────────────────────────────────

WER_THRESHOLD = 0.20          # word error rate — above this = unintelligible
F0_SPREAD_THRESHOLD = 35      # Hz across sentences
F0_REF_ERROR_THRESHOLD = 50   # Hz per sentence vs reference
FLATNESS_THRESHOLD = 0.08     # spectral flatness — above = broadband noise
MIN_SECS_PER_WORD = 0.12      # below = cut-off audio

# Whisper model size to use for ASR round-trip. "base" is fast enough.
WHISPER_MODEL = "base"

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


def word_error_rate(ref: str, hyp: str) -> float:
    """Levenshtein WER on lowercased words, ignoring punctuation."""
    import re
    def tokens(s: str) -> list[str]:
        return re.sub(r"[^\w\s]", "", s.lower()).split()
    r, h = tokens(ref), tokens(hyp)
    if not r:
        return 0.0
    # DP edit distance
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r):
        nd = [i + 1]
        for j, hw in enumerate(h):
            nd.append(min(d[j] + (0 if rw == hw else 1), d[j + 1] + 1, nd[j] + 1))
        d = nd
    return d[-1] / len(r)


def transcribe_whisper(wav_path: str, language: str) -> str:
    """Transcribe with Whisper. Loads model once per process (cached globally)."""
    global _whisper_model
    if "_whisper_model" not in globals():
        import whisper
        print(f"  [whisper] loading {WHISPER_MODEL}...", end=" ", flush=True)
        _whisper_model = whisper.load_model(WHISPER_MODEL)
        print("ready")
    lang_map = {"de": "german", "en": "english", "fr": "french", "es": "spanish"}
    result = _whisper_model.transcribe(wav_path, language=lang_map.get(language, language))
    return result["text"].strip()


def detect_language(model_dir: str) -> str:
    d = model_dir.lower()
    if "french" in d or "_fr" in d or "/fr" in d:
        return "fr"
    if "spanish" in d or "_es" in d or "/es" in d:
        return "es"
    if "english" in d or "_en" in d or "/en" in d or "pocket-tts-int8" in d:
        return "en"
    return "de"


# ─── main test runner ─────────────────────────────────────────────────────────


def run_model(
    model_dir: str,
    ref_path: str,
    language: str,
    seed: int,
    steps: int,
    speed: float,
    temperature: float,
    out_dir: Path,
    skip_asr: bool = False,
) -> bool:
    sentences = SENTENCES.get(language, SENTENCES["de"])

    print(f"model    : {model_dir}")
    print(f"language : {language}")
    print(f"ref      : {ref_path}")
    print(f"seed     : {seed}  steps={steps}  speed={speed}  temperature={temperature}")
    print()

    tts = make_tts(model_dir)
    ref_y, ref_sr = librosa.load(ref_path, sr=tts.sample_rate)

    ref_f0 = get_f0(ref_y, ref_sr)
    print(f"ref F0: {ref_f0:.0f}Hz (male ~80-180Hz, female ~160-260Hz)")
    print()

    f0_means: list[float] = []
    flatnesses: list[float] = []
    durations: list[float] = []
    word_counts: list[int] = []
    wav_paths: list[str] = []

    out_dir.mkdir(parents=True, exist_ok=True)

    for i, text in enumerate(sentences):
        y, sr = synth_sentence(tts, ref_y, ref_sr, text, steps, seed, speed,
                               temperature=temperature)
        wav_path = str(out_dir / f"sentence_{i}.wav")
        sf.write(wav_path, y, sr)

        f0 = get_f0(y, sr)
        flat = spectral_flatness(y)
        dur = len(y) / sr
        wc = len(text.split())

        f0_means.append(f0)
        flatnesses.append(flat)
        durations.append(dur)
        word_counts.append(wc)
        wav_paths.append(wav_path)

        print(f"[{i}] F0={f0:.0f}Hz  flatness={flat:.4f}  dur={dur:.1f}s  words={wc}")
        print(f"     text: {text[:70]}...")

    # ── check 1: intelligibility via Whisper ASR ──────────────────────────────
    print()
    print("Check 1 — Intelligibility (Whisper ASR round-trip, WER < 20%):")
    intelligibility_pass = True
    if skip_asr:
        print("  SKIPPED (--skip-asr)")
    else:
        for i, (text, wav_path) in enumerate(zip(sentences, wav_paths)):
            transcript = transcribe_whisper(wav_path, language)
            wer = word_error_rate(text, transcript)
            ok = wer <= WER_THRESHOLD
            print(f"  [{i}] WER={wer:.0%}  {'OK' if ok else 'FAIL'}")
            print(f"       ref: {text[:80]}")
            print(f"       asr: {transcript[:80]}")
            if not ok:
                intelligibility_pass = False

    # ── check 2: voice consistency (F0 spread) ────────────────────────────────
    print()
    f0_spread = max(f0_means) - min(f0_means)
    print(f"Check 2 — Voice consistency (F0 spread < {F0_SPREAD_THRESHOLD}Hz):")
    print(f"  spread={f0_spread:.0f}Hz  ref={ref_f0:.0f}Hz")
    consistency_pass = True
    for i, f0m in enumerate(f0_means):
        err = abs(f0m - ref_f0)
        ok = err < F0_REF_ERROR_THRESHOLD
        print(f"  [{i}] F0={f0m:.0f}Hz  vs_ref={err:.0f}Hz  {'OK' if ok else 'OFF'}")
        if not ok:
            consistency_pass = False
    spread_ok = f0_spread < F0_SPREAD_THRESHOLD
    if not spread_ok:
        consistency_pass = False

    # ── check 3: audio completeness ───────────────────────────────────────────
    print()
    print(f"Check 3 — Audio completeness (≥ {MIN_SECS_PER_WORD:.2f}s/word):")
    completeness_pass = True
    for i, (dur, wc) in enumerate(zip(durations, word_counts)):
        min_dur = wc * MIN_SECS_PER_WORD
        ok = dur >= min_dur
        print(f"  [{i}] {dur:.1f}s / {wc} words = {dur/wc:.2f}s/word  min={min_dur:.1f}s  {'OK' if ok else 'CUT-OFF'}")
        if not ok:
            completeness_pass = False

    # ── check 4: spectral cleanliness ─────────────────────────────────────────
    print()
    print(f"Check 4 — Spectral cleanliness (flatness < {FLATNESS_THRESHOLD:.2f}):")
    cleanliness_pass = True
    for i, flat in enumerate(flatnesses):
        ok = flat < FLATNESS_THRESHOLD
        print(f"  [{i}] flatness={flat:.4f}  {'OK' if ok else 'NOISY'}")
        if not ok:
            cleanliness_pass = False

    # ── overall ───────────────────────────────────────────────────────────────
    print()
    all_pass = intelligibility_pass and consistency_pass and completeness_pass and cleanliness_pass
    if all_pass:
        print("RESULT: PASS")
    else:
        fails = []
        if not intelligibility_pass:
            fails.append("unintelligible (high WER)")
        if not consistency_pass:
            fails.append(f"voice inconsistency (spread={f0_spread:.0f}Hz)")
        if not completeness_pass:
            fails.append("audio cut-off")
        if not cleanliness_pass:
            fails.append("background noise")
        print(f"RESULT: FAIL — {'; '.join(fails)}")
    return all_pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", default="models/german")
    ap.add_argument("--ref", default=None)
    ap.add_argument("--language", default=None,
                    help="de|en|fr|es  (auto-detected from model-dir)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--temperature", type=float, default=0.25)
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--speed", type=float, default=0.9)
    ap.add_argument("--out-dir", default="/tmp/voice_consistency")
    ap.add_argument("--skip-asr", action="store_true",
                    help="skip Whisper round-trip (faster, but misses quality issues)")
    ap.add_argument("--en-baseline", action="store_true",
                    help="also run official EN model as passing baseline")
    args = ap.parse_args()

    language = args.language or detect_language(args.model_dir)
    ref_path = args.ref or f"{args.model_dir}/test_wavs/juergen.wav"
    if not Path(ref_path).exists():
        sys.exit(f"reference wav not found: {ref_path}")

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
        skip_asr=args.skip_asr,
    )

    if args.en_baseline:
        en_dir = "/tmp/sherpa-onnx-pocket-tts-int8-2026-01-26"
        en_ref = f"{en_dir}/test_wavs/bria.wav"
        if not Path(en_dir).exists():
            print(f"\n[EN baseline] SKIP — not found at {en_dir}")
        else:
            print(f"\n{'='*60}")
            print("EN BASELINE (must PASS)")
            print("=" * 60)
            en_ok = run_model(
                model_dir=en_dir,
                ref_path=en_ref,
                language="en",
                seed=args.seed,
                steps=args.steps,
                speed=args.speed,
                temperature=args.temperature,
                out_dir=Path(args.out_dir) / "en_baseline",
                skip_asr=args.skip_asr,
            )
            if not en_ok:
                print("  WARNING: EN baseline FAILED — test thresholds may be wrong")
            ok = ok and en_ok

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
