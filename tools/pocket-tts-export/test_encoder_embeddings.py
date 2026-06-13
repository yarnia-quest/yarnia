#!/usr/bin/env python3
"""
Fast check: are DE 24L encoder outputs different for juergen vs bria?
If cosine(juergen_emb, bria_emb) ≈ 1.0, the speaker_proj is inert.

Usage: uv run python test_encoder_embeddings.py
"""
import sys
import torch
import torch.nn.functional as F
import librosa
import numpy as np
from pathlib import Path

MODELS = [
    ("DE 24L", "models/german_24l"),
    ("DE 6L",  "models/german"),
    ("EN",     "models/english_ours"),
]
REFS = {
    "juergen": "models/german_24l/test_wavs/juergen.wav",
    "bria":    "models/german_24l/test_wavs/bria.wav",
}


def encoder_emb(model, path: str, sr: int) -> torch.Tensor:
    """Run encoder, return mean-pooled embedding [d_model]."""
    audio, _ = librosa.load(path, sr=sr, mono=True)
    audio = audio[: sr * 20]
    audio_t = torch.from_numpy(audio).unsqueeze(0).unsqueeze(0).float()
    with torch.no_grad():
        latents = model.mimi.encode_to_latent(audio_t)         # [1, 32, T]
        latents = latents.transpose(-1, -2).float()            # [1, T, 32]
        cond = F.linear(latents, model.flow_lm.speaker_proj_weight)  # [1, T, d_model]
    return cond[0].mean(dim=0)  # [d_model]


def main():
    from pocket_tts.models.tts_model import TTSModel

    ref_paths = {k: v for k, v in REFS.items() if Path(v).exists()}
    if len(ref_paths) < 2:
        sys.exit("Need both reference wavs in models/german_24l/test_wavs/")

    for label, model_dir in MODELS:
        cfg_name = {
            "models/german_24l": "german_24l",
            "models/german":     "german",
            "models/english_ours": "english_2026-04",
        }.get(model_dir)
        if cfg_name is None or not Path(model_dir).exists():
            print(f"[{label}] skip (not found: {model_dir})")
            continue

        print(f"\n--- {label} ({model_dir}) ---")
        try:
            model = TTSModel.load_model(language=cfg_name)
            model.eval().cpu()
        except Exception as e:
            print(f"  load error: {e}")
            continue

        sr = model.mimi.sample_rate
        embs = {}
        for name, path in ref_paths.items():
            emb = encoder_emb(model, path, sr)
            embs[name] = emb
            print(f"  {name}: shape={list(emb.shape)} norm={emb.norm():.3f}")

        if len(embs) == 2:
            j, b = embs["juergen"], embs["bria"]
            cos = F.cosine_similarity(j.unsqueeze(0), b.unsqueeze(0)).item()
            l2 = (j - b).norm().item()
            print(f"  cosine(juergen,bria) = {cos:.4f}  L2 = {l2:.4f}")
            if cos > 0.99:
                print("  RESULT: embeddings identical → speaker_proj maps all voices to same point")
            elif cos > 0.90:
                print("  RESULT: embeddings nearly identical → very weak conditioning")
            else:
                print("  RESULT: embeddings differ → conditioning should have some effect")

        del model

    return 0


if __name__ == "__main__":
    sys.exit(main())
