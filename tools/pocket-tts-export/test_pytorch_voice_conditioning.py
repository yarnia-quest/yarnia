#!/usr/bin/env python3
"""
Test whether the PyTorch DE 24L model's voice conditioning actually works.

We run the encoder with two very different reference speakers (juergen ~117Hz male,
bria ~195Hz female) and measure:
1. How different the encoder output embeddings are (should be very different)
2. We run the full synthesis for one sentence with each reference and check
   if the output pitch differs (if not, conditioning is broken at PyTorch level)

This tells us whether the bug is in the ONNX export or in the pretrained model.

Usage:
    uv run python test_pytorch_voice_conditioning.py
"""
import sys
import logging
import torch
import torch.nn.functional as F
import numpy as np
import librosa
import soundfile as sf
from pathlib import Path

logging.basicConfig(level=logging.WARNING)
log = logging.getLogger(__name__)

TEXT = "Lumi rollte sich unter seinem Baum zusammen und schloss langsam die Augen."
LANGUAGE = "german_24l"
JUERGEN = "/home/o/Projects/hackathon/yarnia/tools/pocket-tts-export/models/german_24l/test_wavs/juergen.wav"
BRIA = "/home/o/Projects/hackathon/yarnia/tools/pocket-tts-export/models/german_24l/test_wavs/bria.wav"
OUT_DIR = Path("/tmp/pytorch_voice_test")


def get_f0(y: np.ndarray, sr: int) -> float:
    f0, vf, _ = librosa.pyin(y, fmin=50, fmax=400, sr=sr)
    f0v = f0[vf & ~np.isnan(f0)] if vf is not None else np.array([])
    return float(np.mean(f0v)) if len(f0v) > 0 else 0.0


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print("Loading DE 24L model via pocket_tts...")
    # Strip beartype (needed for ONNX export but not synthesis — skip here)
    from pocket_tts.models.tts_model import TTSModel
    model = TTSModel.load_model(language=LANGUAGE)
    model.eval().cpu()
    print("  loaded")

    sr = model.mimi.sample_rate
    print(f"  sample_rate={sr}")

    # --- 1. Compare encoder embeddings ----------------------------------------
    print("\n--- Encoder embedding comparison ---")
    refs = {"juergen": JUERGEN, "bria": BRIA}
    embeddings = {}
    for name, path in refs.items():
        if not Path(path).exists():
            print(f"  SKIP: {path} not found")
            continue
        audio, _ = librosa.load(path, sr=sr, mono=True)
        # Take up to 20s (same as app's max_reference_audio_len)
        audio = audio[:sr * 20]
        audio_t = torch.from_numpy(audio).unsqueeze(0).unsqueeze(0).float()

        with torch.no_grad():
            latents = model.mimi.encode_to_latent(audio_t)     # [1, 32, T]
            latents = latents.transpose(-1, -2).float()         # [1, T, 32]
            cond = F.linear(latents, model.flow_lm.speaker_proj_weight)  # [1, T, d_model]
            insert_bos = model.flow_lm.insert_bos_before_voice
            if insert_bos:
                cond = torch.cat([model.flow_lm.bos_before_voice, cond], dim=1)

        emb = cond[0].mean(dim=0)  # mean pool → [d_model]
        embeddings[name] = emb
        norm = emb.norm().item()
        print(f"  {name}: frames={cond.shape[1]} d_model={cond.shape[2]} norm={norm:.3f}")

    if len(embeddings) == 2:
        j, b = embeddings["juergen"], embeddings["bria"]
        cos = F.cosine_similarity(j.unsqueeze(0), b.unsqueeze(0)).item()
        l2 = (j - b).norm().item()
        print(f"\n  cosine(juergen, bria) = {cos:.4f}  (1.0=identical, 0.0=orthogonal)")
        print(f"  L2(juergen, bria)     = {l2:.4f}")
        if cos > 0.95:
            print("  WARNING: embeddings nearly identical — voice conditioning will have no effect")
        elif cos < 0.70:
            print("  OK: embeddings are quite different — conditioning should work if LM uses them")
        else:
            print("  MARGINAL: embeddings differ somewhat but conditioning may be weak")

    # --- 2. Full synthesis with each reference --------------------------------
    print("\n--- Full synthesis F0 comparison ---")
    print(f"  text: {TEXT[:60]}...")

    f0s = {}
    for name, path in refs.items():
        if not Path(path).exists():
            continue

        print(f"\n  synthesising with ref={name}...")
        try:
            # pocket_tts public API: get_state_for_audio_prompt + generate_audio
            voice_state = model.get_state_for_audio_prompt(path)
            audio_chunks = list(model.generate_audio(
                model_state=voice_state,
                text_to_generate=TEXT,
                frames_after_eos=2,
                copy_state=True,
            ))
            y = np.concatenate([np.array(c, dtype=np.float32) for c in audio_chunks])

            out_path = OUT_DIR / f"pytorch_{name}.wav"
            sf.write(str(out_path), y, sr)
            f0 = get_f0(y, sr)
            f0s[name] = f0
            print(f"    F0={f0:.0f}Hz  dur={len(y)/sr:.1f}s  → {out_path}")
        except Exception as e:
            print(f"    ERROR: {e}")
            import traceback
            traceback.print_exc()

    if len(f0s) == 2:
        diff = abs(f0s.get("juergen", 0) - f0s.get("bria", 0))
        print(f"\n  F0 diff (juergen vs bria): {diff:.0f}Hz")
        if diff < 20:
            print("  FAIL: voice conditioning has no effect even in PyTorch — model quality issue")
        elif diff > 40:
            print("  OK: voice conditioning works in PyTorch — bug is in ONNX export")
        else:
            print("  PARTIAL: slight conditioning effect in PyTorch")

    return 0


if __name__ == "__main__":
    sys.exit(main())
