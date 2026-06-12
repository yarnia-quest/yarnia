"""
End-to-end ONNX inference test for Pocket TTS exported models.

Pipeline (3-phase):
  1. Voice prime:   encoder.onnx(audio) → voice_latents [1, T_voice, 1024]
                    lm_main(seq=empty, text=voice_latents) → fills KV cache
  2. Text prime:    text_conditioner.onnx(token_ids) → text_emb [1, T_text, 1024]
                    lm_main(seq=empty, text=text_emb) → fills KV cache
  3. Generate:      lm_main(seq=[BOS/prev_latent], text=empty)
                    → conditioning [1, 1024] + updated states
                    lm_flow.onnx(c, s, t, x) → flow_dir  (Euler: noise → latent)
                    latents → decoder.onnx → audio [1, 1, T_samples]

EOS: fires when eos_logit > -4.0 (DEFAULT_EOS_THRESHOLD from pocket_tts).
Offset: now auto-updated by T_text + T_seq inside lm_main (fixed in export).

Usage:
    uv run python test_onnx_inference.py --model-dir models/german \\
        --voice-ref models/german/test_wavs/bria.wav \\
        --text "Hallo, wie geht es dir?"
    uv run python test_onnx_inference.py --model-dir models/spanish \\
        --voice-ref models/spanish/test_wavs/bria.wav \\
        --text "Hola, ¿cómo estás?"
"""

import argparse
import json
import wave
from pathlib import Path

import numpy as np
import onnxruntime as ort

SAMPLE_RATE = 24000
FLOW_STEPS = 16
EOS_THRESHOLD = -4.0   # logit threshold; EOS fires when logit > this


def _make_session(path: Path) -> ort.InferenceSession:
    opts = ort.SessionOptions()
    opts.inter_op_num_threads = 4
    opts.intra_op_num_threads = 4
    return ort.InferenceSession(str(path), opts)


def _init_states(sess: ort.InferenceSession, skip: int) -> list[np.ndarray]:
    """Zero-initialise all state tensors with correct dtypes. Keeps 0-sized dims as 0."""
    out = []
    for inp in sess.get_inputs()[skip:]:
        shape = [d if isinstance(d, int) else 1 for d in inp.shape]
        if inp.type == "tensor(int64)":
            out.append(np.zeros(shape, dtype=np.int64))
        elif inp.type == "tensor(bool)":
            out.append(np.zeros(shape, dtype=bool))
        else:
            out.append(np.zeros(shape, dtype=np.float32))
    return out


def tokenize(vocab_path: Path, text: str) -> np.ndarray:
    vocab = json.loads(vocab_path.read_text())
    tokens = []
    i = 0
    while i < len(text):
        matched = False
        for length in range(min(20, len(text) - i), 0, -1):
            chunk = text[i : i + length]
            if chunk in vocab:
                tokens.append(vocab[chunk])
                i += length
                matched = True
                break
        if not matched:
            tokens.append(vocab.get("<unk>", 0))
            i += 1
    bos = vocab.get("<bos>", vocab.get("<s>", 1))
    eos = vocab.get("<eos>", vocab.get("</s>", 2))
    return np.array([bos] + tokens + [eos], dtype=np.int64)[None]   # [1, T]


def run_lm(sess, seq, text_emb, states):
    in_names = [i.name for i in sess.get_inputs()]
    feed = {in_names[0]: seq, in_names[1]: text_emb}
    for k, s in enumerate(states):
        feed[in_names[2 + k]] = s
    out = sess.run(None, feed)
    return out[0], out[1], list(out[2:])   # cond, eos_logit, new_states


def run_flow(sess, c, s_val, t_val, x):
    return sess.run(None, {
        "c": c,
        "s": np.array([[s_val]], dtype=np.float32),
        "t": np.array([[t_val]], dtype=np.float32),
        "x": x,
    })[0]


def flow_match(flow_sess, conditioning: np.ndarray, n_steps: int) -> np.ndarray:
    """Euler integration: noise → latent conditioned on `conditioning`."""
    x = np.random.randn(1, 32).astype(np.float32)
    dt = 1.0 / n_steps
    for step in range(n_steps):
        v = run_flow(flow_sess, conditioning, step * dt, (step + 1) * dt, x)
        x = x + v * dt
    return x   # [1, 32]


def run_decoder(sess, latents, states):
    in_names = [i.name for i in sess.get_inputs()]
    feed = {in_names[0]: latents}
    for k, s in enumerate(states):
        feed[in_names[1 + k]] = s
    out = sess.run(None, feed)
    return out[0], list(out[1:])


def load_audio_24k(path: Path, max_seconds: float = 10.0) -> np.ndarray:
    """Load audio file, resample to 24 kHz mono."""
    try:
        import soundfile as sf
        audio, sr = sf.read(str(path))
        if audio.ndim > 1:
            audio = audio[:, 0]
        if sr != SAMPLE_RATE:
            import scipy.signal
            audio = scipy.signal.resample(audio, int(len(audio) * SAMPLE_RATE / sr))
    except ImportError:
        import wave as wavmod
        with wavmod.open(str(path), "r") as wf:
            sr = wf.getframerate()
            frames = wf.readframes(wf.getnframes())
            audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
            if sr != SAMPLE_RATE:
                import scipy.signal
                audio = scipy.signal.resample(audio, int(len(audio) * SAMPLE_RATE / sr))
    max_samples = int(max_seconds * SAMPLE_RATE)
    return audio[:max_samples].astype(np.float32)


def write_wav(path: Path, audio: np.ndarray) -> None:
    audio = np.clip(audio.flatten(), -1.0, 1.0)
    pcm = (audio * 32767).astype(np.int16)
    with wave.open(str(path), "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm.tobytes())


def run_inference(
    model_dir: Path,
    voice_ref: Path,
    text: str,
    out_wav: Path,
    max_steps: int = 300,
    flow_steps: int = FLOW_STEPS,
    eos_threshold: float = EOS_THRESHOLD,
    seed: int = 42,
) -> None:
    print(f"Model:     {model_dir}")
    print(f"Voice:     {voice_ref}")
    print(f"Text:      {repr(text)}")

    tc_sess   = _make_session(model_dir / "text_conditioner.onnx")
    enc_sess  = _make_session(model_dir / "encoder.onnx")
    lm_sess   = _make_session(model_dir / "lm_main.int8.onnx")
    flow_sess = _make_session(model_dir / "lm_flow.int8.onnx")
    dec_sess  = _make_session(model_dir / "decoder.int8.onnx")

    # --- Phase 1: Voice priming ---
    audio = load_audio_24k(voice_ref)
    print(f"Voice ref: {len(audio)/SAMPLE_RATE:.1f}s")
    voice_in = audio[None, None, :]                              # [1, 1, T_audio]
    voice_latents = enc_sess.run(None, {"audio": voice_in})[0]  # [1, T_voice, 1024] — output named "latents"
    print(f"Voice latents: {voice_latents.shape}")

    lm_states = _init_states(lm_sess, skip=2)
    empty_seq = np.zeros((1, 0, 32), dtype=np.float32)
    empty_emb = np.zeros((1, 0, 1024), dtype=np.float32)

    _, _, lm_states = run_lm(lm_sess, empty_seq, voice_latents, lm_states)
    print(f"Voice prime done: offset={lm_states[0][0]}")

    # --- Phase 2: Text priming ---
    token_ids = tokenize(model_dir / "vocab.json", text)
    text_emb = tc_sess.run(None, {"token_ids": token_ids})[0]   # [1, T_text, 1024]
    print(f"Text emb: {text_emb.shape}")

    _, _, lm_states = run_lm(lm_sess, empty_seq, text_emb, lm_states)
    print(f"Text prime done: offset={lm_states[0][0]}")

    # --- Phase 3: Autoregressive generation ---
    dec_states = _init_states(dec_sess, skip=1)
    np.random.seed(seed)
    seq = np.full((1, 1, 32), float("nan"), dtype=np.float32)   # BOS NaN
    latents = []

    frames_after_eos: int = 2
    eos_step = None
    print(f"Generating (max {max_steps} steps, flow_steps={flow_steps}, eos_thresh={eos_threshold})...")
    for step in range(max_steps):
        cond, eos_logit, lm_states = run_lm(lm_sess, seq, empty_emb, lm_states)
        raw_eos = float(eos_logit.flat[0])

        latent = flow_match(flow_sess, cond, flow_steps)   # [1, 32]
        latents.append(latent[0])
        seq = latent[:, None, :]

        if step % 10 == 0 or (raw_eos > eos_threshold - 1.0):
            print(f"  step {step:4d}  eos_logit={raw_eos:7.3f}  offset={lm_states[0][0]}")

        if raw_eos > eos_threshold and step > 3 and eos_step is None:
            print(f"  => EOS at step {step}, continuing {frames_after_eos} more frames")
            eos_step = step
        if eos_step is not None and step >= eos_step + frames_after_eos:
            break

    print(f"Generated {len(latents)} latent frames  (~{len(latents)/12.5:.1f}s)")

    if not latents:
        print("ERROR: no latents generated")
        return

    # Decode one frame at a time (streaming) to avoid decoder KV cache overflow.
    # The decoder transformer upsamples latents 16× internally before attention,
    # so batching N frames fills 16N cache slots — overflow at N≈62 with 1000-slot cache.
    print(f"Decoding {len(latents)} frames (streaming)...")
    audio_chunks = []
    for i, latent in enumerate(latents):
        frame = latent[None, None, :]                            # [1, 1, 32]
        chunk, dec_states = run_decoder(dec_sess, frame, dec_states)
        audio_chunks.append(chunk.flatten())
    audio_out = np.concatenate(audio_chunks)
    print(f"Audio: {audio_out.shape}  ({len(audio_out) / SAMPLE_RATE:.2f}s)")

    write_wav(out_wav, audio_out[None])
    print(f"Saved: {out_wav}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--voice-ref", type=Path, default=None,
                        help="Voice reference WAV. Defaults to <model-dir>/test_wavs/bria.wav")
    parser.add_argument("--text", default="Hallo, wie geht es dir?")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--max-steps", type=int, default=300)
    parser.add_argument("--flow-steps", type=int, default=FLOW_STEPS)
    parser.add_argument("--eos-threshold", type=float, default=EOS_THRESHOLD)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    model_dir = args.model_dir
    voice_ref = args.voice_ref or (model_dir / "test_wavs" / "bria.wav")
    out_wav = args.out or (model_dir / "test_output.wav")
    run_inference(model_dir, voice_ref, args.text, out_wav,
                  args.max_steps, args.flow_steps, args.eos_threshold, args.seed)


if __name__ == "__main__":
    main()
