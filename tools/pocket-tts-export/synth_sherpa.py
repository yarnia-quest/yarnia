#!/usr/bin/env python3
"""
Synthesize + quality-check an exported Pocket TTS model via the REAL sherpa-onnx
runtime (the same C++ engine the Flutter app uses through the sherpa_onnx plugin).

This is the faithful local test for an export: if it sounds clean here, it sounds
clean on device. Spectral flatness is a cheap noise proxy (pure noise -> ~1.0,
clean tonal speech -> < ~0.15; our clean EN baseline is ~0.04).

Usage:
  uv run python synth_sherpa.py --model-dir models/german \
      --text "Gute Nacht, kleiner Baer." --out /tmp/de.wav
  # default voice reference is the official EN bria.wav if --ref omitted
"""
import argparse
import time
from pathlib import Path

import librosa
import numpy as np
import sherpa_onnx
import soundfile as sf

DEFAULT_REF = "/tmp/sherpa-onnx-pocket-tts-int8-2026-01-26/test_wavs/bria.wav"


def spectral_flatness(y: np.ndarray) -> float:
    S = np.abs(librosa.stft(y, n_fft=1024)) + 1e-9
    return float(np.mean(librosa.feature.spectral_flatness(S=S)[0]))


def synth(model_dir: str, ref: str, text: str, out: str, steps: int = 8) -> float:
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
            debug=False, num_threads=4, provider="cpu",
        )
    )
    if not cfg.validate():
        raise SystemExit("sherpa-onnx config invalid (see messages above)")
    tts = sherpa_onnx.OfflineTts(cfg)
    r, sr = librosa.load(ref, sr=tts.sample_rate)
    g = sherpa_onnx.GenerationConfig()
    g.reference_audio = r
    g.reference_sample_rate = sr
    g.num_steps = steps
    t0 = time.time()
    audio = tts.generate(text, g)
    dt = time.time() - t0
    y = np.asarray(audio.samples, dtype=np.float32)
    if len(y) == 0:
        raise SystemExit("EMPTY OUTPUT - export is broken")
    dur = len(y) / audio.sample_rate
    sf.write(out, y, audio.sample_rate, subtype="PCM_16")
    fl = spectral_flatness(y)
    print(f"{model_dir}: dur={dur:.2f}s rtf={dt/dur:.2f} flatness={fl:.4f} -> {out}")
    print("  (clean speech < ~0.15; conv-quantized noise was ~0.07; EN baseline ~0.04)")
    return fl


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--model-dir", required=True)
    p.add_argument("--ref", default=DEFAULT_REF)
    p.add_argument("--text", default="Gute Nacht, kleiner Baer, schlaf jetzt ein.")
    p.add_argument("--out", default="/tmp/synth.wav")
    p.add_argument("--steps", type=int, default=8)
    a = p.parse_args()
    if not Path(a.ref).is_file():
        raise SystemExit(f"reference wav not found: {a.ref}")
    synth(a.model_dir, a.ref, a.text, a.out, a.steps)
