#!/usr/bin/env python3
"""
Export Pocket TTS PyTorch models to ONNX for sherpa-onnx.

Exports 5 components per language into a directory compatible with
OfflineTtsPocketModelConfig:
  encoder.onnx          - Mimi encoder + voice projection + optional BOS
  text_conditioner.onnx - LUT text token embedder
  lm_main.int8.onnx     - Flow LM transformer (int8 quantised)
  lm_flow.int8.onnx     - Flow matching network (int8 quantised)
  decoder.int8.onnx     - Mimi decoder with denormalisation + quantiser (int8)
  vocab.json            - Token vocab for sherpa-onnx C++ tokeniser
  token_scores.json     - Token log-prob scores

Usage:
  uv run python export_pocket_tts.py --language german --out-dir models/german
  uv run python export_pocket_tts.py --language german_24l --out-dir models/german_24l
  uv run python export_pocket_tts.py --language spanish --out-dir models/spanish
  uv run python export_pocket_tts.py --language french_24l --out-dir models/french_24l

Available languages: english, english_2026-04, german, german_24l,
                     spanish, spanish_24l, french_24l, italian, italian_24l,
                     portuguese, portuguese_24l
"""

import argparse
import io
import json
import logging
import shutil
import sys
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from onnxruntime.quantization import QuantType, quantize_dynamic

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger(__name__)

MAX_SEQ_LEN = 1000  # KV-cache capacity (matches sherpa-onnx EN model)


# ---------------------------------------------------------------------------
# KV-cache patch
# ---------------------------------------------------------------------------

import sys
import pocket_tts.modules.transformer as _tf_mod

_ORIG_COMPLETE_KV = _tf_mod.complete_kv


def _strip_beartype():
    """
    Remove beartype wrappers from all pocket_tts functions and class methods.

    During ONNX tracing, shape dimensions (x.shape[0]) become traced Tensors.
    beartype then rejects them when they're passed as `int` parameters (e.g.,
    batch_size).  Stripping the wrappers lets tracing succeed while still
    exercising the real logic.
    """
    import types

    for mod_name, mod in list(sys.modules.items()):
        if not mod_name.startswith("pocket_tts"):
            continue
        # Unwrap module-level callables
        for attr_name in list(vars(mod).keys()):
            try:
                obj = vars(mod)[attr_name]
                if callable(obj) and hasattr(obj, "__wrapped__"):
                    setattr(mod, attr_name, obj.__wrapped__)
            except Exception:
                pass
        # Unwrap class methods
        for attr_name in list(vars(mod).keys()):
            try:
                obj = vars(mod)[attr_name]
                if not isinstance(obj, type):
                    continue
                for method_name in list(vars(obj).keys()):
                    try:
                        method = vars(obj)[method_name]
                        if callable(method) and hasattr(method, "__wrapped__"):
                            setattr(obj, method_name, method.__wrapped__)
                    except Exception:
                        pass
            except Exception:
                pass


_strip_beartype()


def _onnx_complete_kv(cache, offset, k, v):
    """
    Drop-in replacement for complete_kv that avoids .item() so torch.onnx.export
    can trace dynamic offsets.

    Uses index_put_ (in-place ScatterND) so that the cache tensor in model_state
    is mutated — the wrapper can then read it back correctly as the updated output.

    Offset is NOT incremented here; LmMainWrapper.forward does that manually.

    cache : [2, B=1, MAX_T, H, D]
    offset: [1] int64
    k, v  : [1, T, H, D]
    """
    _, T, H, D = k.shape
    positions = offset[0] + torch.arange(T, device=k.device, dtype=torch.long)
    # in-place update: cache[0,0] and cache[1,0] are mutated, state dict reflects change
    cache[0, 0].index_put_((positions,), k[0])
    cache[1, 0].index_put_((positions,), v[0])
    valid_end = offset[0] + T
    return cache[0, :, :valid_end], cache[1, :, :valid_end]


def _patch_kv():
    _tf_mod.complete_kv = _onnx_complete_kv


def _unpatch_kv():
    _tf_mod.complete_kv = _ORIG_COMPLETE_KV


# ---------------------------------------------------------------------------
# Wrapper modules
# ---------------------------------------------------------------------------

class EncoderWrapper(nn.Module):
    """
    Stateless encoder: audio → voice embeddings (+ BOS for multilingual models).

    Input : audio [1, 1, N]
    Output: latents_bos [1, T(+1), d_model]
    """

    def __init__(self, model):
        super().__init__()
        self.mimi = model.mimi
        self.speaker_proj_weight = model.flow_lm.speaker_proj_weight
        self.insert_bos = model.flow_lm.insert_bos_before_voice
        if self.insert_bos:
            self.bos_before_voice = model.flow_lm.bos_before_voice

    def forward(self, audio: torch.Tensor) -> torch.Tensor:
        latents = self.mimi.encode_to_latent(audio)                 # [1, 32, T]
        latents = latents.transpose(-1, -2).float()                 # [1, T, 32]
        cond = F.linear(latents, self.speaker_proj_weight)          # [1, T, d_model]
        if self.insert_bos:
            cond = torch.cat([self.bos_before_voice, cond], dim=1)
        return cond


class TextConditionerWrapper(nn.Module):
    """
    Stateless text token → embedding via LUT lookup.

    Input : token_ids [1, seq_len] int64
    Output: embeddings [1, seq_len, d_model]
    """

    def __init__(self, conditioner):
        super().__init__()
        # Use the embedding table directly to avoid the TokenizedText wrapper
        # that would otherwise slice the batch dim via inputs[0].
        self.embed = conditioner.embed

    def forward(self, token_ids: torch.Tensor) -> torch.Tensor:
        return self.embed(token_ids)


class FlowNetWrapper(nn.Module):
    """
    Stateless flow matching network.

    Inputs : c [B, d_model], s [B,1], t [B,1], x [B, ldim]
    Output : flow_dir [B, ldim]
    """

    def __init__(self, flow_net):
        super().__init__()
        self.flow_net = flow_net

    def forward(self, c, s, t, x):
        return self.flow_net(c, s, t, x)


class LmMainWrapper(nn.Module):
    """
    One step of the flow-LM transformer.

    State layout per layer i  (2 tensors each):
      state_{2i}  : cache  [2, 1, MAX_T, H, D]  float32
      state_{2i+1}: offset [1]                   int64

    Inputs : sequence [1, S, ldim], text_embeddings [1, T, d_model], *state_tensors
    Outputs: conditioning [1, d_model], eos_logit [1, 1], *updated_state_tensors
    """

    def __init__(self, flow_lm, state_schema: list[tuple[str, str]]):
        super().__init__()
        self.fl = flow_lm
        # Register as buffer so ONNX export can include it as an initializer
        # (parameters with requires_grad=True can't be traced as constants).
        self.register_buffer("bos_emb", flow_lm.bos_emb.detach().clone())
        self.state_schema = state_schema  # [(module_name, key), ...]

    def forward(self, sequence, text_embeddings, *state_tensors):
        model_state: dict = {}
        for i, (mod, key) in enumerate(self.state_schema):
            if mod not in model_state:
                model_state[mod] = {}
            model_state[mod][key] = state_tensors[i]

        fl = self.fl
        T = sequence.shape[1]  # sequence tokens (BOS or latent frames)
        # T_total includes text embeddings processed by the transformer this step.
        # The KV cache offset must advance by ALL tokens written, not just sequence tokens.
        T_total = text_embeddings.shape[1] + T
        sequence = torch.where(torch.isnan(sequence), self.bos_emb, sequence)
        inp = fl.input_linear(sequence)
        inp_full = torch.cat([text_embeddings, inp], dim=1)
        # transformer forward: _onnx_complete_kv mutates cache tensors in-place
        out = fl.transformer(inp_full, model_state)
        if fl.out_norm:
            out = fl.out_norm(out)
        out = out[:, -sequence.shape[1]:].float()
        last = out[:, -1]

        # collect updated states: cache is updated in-place, offset needs incrementing by T_total
        updated = []
        for mod, key in self.state_schema:
            v = model_state[mod][key]
            if key == "offset":
                updated.append(v + T_total)
            else:
                updated.append(v)
        return (last, fl.out_eos(last), *updated)


class DecoderWrapper(nn.Module):
    """
    One chunk of mimi decoding (includes denormalisation and quantiser projection).

    State: flat list from decoder-side modules only.

    Inputs : latent [1, T, ldim], *state_tensors
    Outputs: audio_frame [1, 1, T*hop], *updated_state_tensors
    """

    def __init__(self, model, state_schema: list[tuple[str, str]]):
        super().__init__()
        self.mimi = model.mimi
        self.emb_std = model.flow_lm.emb_std
        self.emb_mean = model.flow_lm.emb_mean
        self.state_schema = state_schema

    def forward(self, latent, *state_tensors):
        # latent: [1, T, ldim] — raw output of lm_flow
        T = latent.shape[1]
        x = latent * self.emb_std + self.emb_mean   # denormalise
        x = x.transpose(-1, -2)                      # [1, ldim, T]
        x = self.mimi.quantizer(x)                   # [1, 512, T]

        model_state: dict = {}
        for i, (mod, key) in enumerate(self.state_schema):
            if mod not in model_state:
                model_state[mod] = {}
            model_state[mod][key] = state_tensors[i]

        # decode_from_latent: streaming conv states mutated in-place via index_put_;
        # transformer KV offsets need explicit increment (same pattern as lm_main)
        audio = self.mimi.decode_from_latent(x, model_state)

        updated = []
        for mod, key in self.state_schema:
            v = model_state[mod][key]
            if key == "offset":
                updated.append(v + T)
            else:
                updated.append(v)
        return (audio, *updated)


# ---------------------------------------------------------------------------
# State schema helpers
# ---------------------------------------------------------------------------

def lm_main_state_schema(flow_lm) -> list[tuple[str, str]]:
    """Ordered (module_name, key) pairs for lm_main state tensors.

    Keys are relative to flow_lm (matching _module_absolute_name used by get_state).
    """
    from pocket_tts.modules.stateful_module import init_states, StatefulModule
    # Call on flow_lm so keys are like "transformer.layers.0.self_attn",
    # matching what StatefulModule.get_state looks up via _module_absolute_name.
    state_ex = init_states(flow_lm, batch_size=1, sequence_length=1)
    schema = []
    for name in state_ex:
        for key in state_ex[name]:
            schema.append((name, key))
    return schema


def decoder_state_schema(mimi) -> list[tuple[str, str]]:
    """Ordered (module_name, key) pairs for decoder-only state tensors.

    Keys are relative to mimi (as returned by init_states).
    Encoder-side modules (encoder.*, encoder_transformer.*) are excluded.
    """
    from pocket_tts.modules.stateful_module import StatefulModule, init_states
    state_ex = init_states(mimi, batch_size=1, sequence_length=1)
    schema = []
    for name in state_ex:
        if name.startswith("encoder"):  # skip encoder side
            continue
        for key in state_ex[name]:
            schema.append((name, key))
    return schema


def init_flat_state(schema, parent_module) -> list[torch.Tensor]:
    """Build initial flat state list matching schema ordering."""
    from pocket_tts.modules.stateful_module import init_states
    state = init_states(parent_module, batch_size=1, sequence_length=MAX_SEQ_LEN)
    return [state[mod][key] for mod, key in schema]


# ---------------------------------------------------------------------------
# Export helpers
# ---------------------------------------------------------------------------

def _export(wrapper, args, out_path: Path, input_names, output_names, dynamic_axes):
    """Export a wrapper module to ONNX and return the path."""
    buf = io.BytesIO()
    with torch.no_grad():
        torch.onnx.export(
            wrapper, args, buf,
            input_names=input_names,
            output_names=output_names,
            dynamic_axes=dynamic_axes,
            opset_version=18,
            do_constant_folding=True,
            dynamo=False,
        )
    out_path.write_bytes(buf.getvalue())
    log.info("  wrote %s  (%.1f MB)", out_path.name, out_path.stat().st_size / 1e6)
    return out_path


def _quantize(src: Path, dst: Path):
    quantize_dynamic(str(src), str(dst), weight_type=QuantType.QUInt8)
    log.info("  quantised → %s  (%.1f MB)", dst.name, dst.stat().st_size / 1e6)


# ---------------------------------------------------------------------------
# Tokeniser conversion (sentencepiece → sherpa-onnx JSON format)
# ---------------------------------------------------------------------------

def export_tokenizer(tokenizer_model_path: str, out_dir: Path):
    """Convert a sentencepiece .model to vocab.json + token_scores.json."""
    import sentencepiece as spm
    sp = spm.SentencePieceProcessor()
    sp.Load(tokenizer_model_path)
    n = sp.GetPieceSize()
    vocab = {}
    scores = {}
    for i in range(n):
        piece = sp.IdToPiece(i)
        score = sp.GetScore(i)
        vocab[piece] = i
        scores[piece] = score
    (out_dir / "vocab.json").write_text(json.dumps(vocab, ensure_ascii=False, indent=2))
    (out_dir / "token_scores.json").write_text(json.dumps(scores, ensure_ascii=False, indent=2))
    log.info("  wrote vocab.json + token_scores.json  (%d tokens)", n)


# ---------------------------------------------------------------------------
# Main export function
# ---------------------------------------------------------------------------

def export_language(language: str, out_dir: Path):
    from pocket_tts.utils.config import CONFIGS_DIR, load_config

    log.info("=== Exporting language: %s ===", language)
    out_dir.mkdir(parents=True, exist_ok=True)

    # ---- load model -------------------------------------------------------
    log.info("Loading model…")
    config_path = CONFIGS_DIR / f"{language}.yaml"
    if not config_path.exists():
        sys.exit(f"Unknown language '{language}'. Config not found at {config_path}")

    cfg = load_config(config_path)
    from pocket_tts.models.tts_model import TTSModel
    model = TTSModel.load_model(language=language)
    model.eval().cpu()
    log.info("  loaded  (insert_bos=%s)", cfg.flow_lm.insert_bos_before_voice)

    d_model = cfg.flow_lm.transformer.d_model
    ldim = cfg.mimi.quantizer.dimension  # 32

    # ---- state schemas ----------------------------------------------------
    lm_schema = lm_main_state_schema(model.flow_lm)
    dec_schema = decoder_state_schema(model.mimi)
    n_lm_states = len(lm_schema)
    n_dec_states = len(dec_schema)

    lm_init = init_flat_state(lm_schema, model.flow_lm)
    dec_init = init_flat_state(dec_schema, model.mimi)

    # ---- patch KV cache ---------------------------------------------------
    _patch_kv()
    try:
        # ---- encoder.onnx -------------------------------------------------
        log.info("Exporting encoder.onnx…")
        enc = EncoderWrapper(model)
        audio_dummy = torch.randn(1, 1, 24000)
        _export(enc, (audio_dummy,),
                out_dir / "encoder.onnx",
                input_names=["audio"],
                output_names=["latents"],
                dynamic_axes={"audio": {2: "audio_len"}, "latents": {1: "voice_len"}})

        # ---- text_conditioner.onnx ----------------------------------------
        log.info("Exporting text_conditioner.onnx…")
        tc = TextConditionerWrapper(model.flow_lm.conditioner)
        tok_dummy = torch.zeros(1, 10, dtype=torch.long)
        _export(tc, (tok_dummy,),
                out_dir / "text_conditioner.onnx",
                input_names=["token_ids"],
                output_names=["embeddings"],
                dynamic_axes={"token_ids": {1: "seq_len"}, "embeddings": {1: "seq_len"}})

        # ---- lm_main.onnx (fp32 then quantise) ----------------------------
        log.info("Exporting lm_main.onnx (fp32)…")
        lm_wrapper = LmMainWrapper(model.flow_lm, lm_schema)
        seq_dummy = torch.full((1, 1, ldim), float("nan"))
        text_emb_dummy = torch.randn(1, 5, d_model)
        state_names = [f"state_{i}" for i in range(n_lm_states)]
        out_state_names = [f"out_state_{i}" for i in range(n_lm_states)]
        dyn_axes = {
            "sequence": {1: "seq_len"},
            "text_embeddings": {1: "text_len"},
        }
        lm_fp32 = out_dir / "lm_main.onnx"
        _export(lm_wrapper,
                (seq_dummy, text_emb_dummy, *lm_init),
                lm_fp32,
                input_names=["sequence", "text_embeddings"] + state_names,
                output_names=["conditioning", "eos_logit"] + out_state_names,
                dynamic_axes=dyn_axes)

        log.info("Quantising lm_main → lm_main.int8.onnx…")
        _quantize(lm_fp32, out_dir / "lm_main.int8.onnx")
        lm_fp32.unlink()

        # ---- lm_flow.onnx (fp32 then quantise) ----------------------------
        log.info("Exporting lm_flow.onnx (fp32)…")
        fn_wrapper = FlowNetWrapper(model.flow_lm.flow_net)
        c_d = torch.randn(1, d_model)
        s_d = torch.tensor([[0.0]])
        t_d = torch.tensor([[1.0]])
        x_d = torch.randn(1, ldim)
        lm_flow_fp32 = out_dir / "lm_flow.onnx"
        _export(fn_wrapper, (c_d, s_d, t_d, x_d),
                lm_flow_fp32,
                input_names=["c", "s", "t", "x"],
                output_names=["flow_dir"],
                dynamic_axes={"c": {0: "batch"}, "x": {0: "batch"}, "flow_dir": {0: "batch"}})

        log.info("Quantising lm_flow → lm_flow.int8.onnx…")
        _quantize(lm_flow_fp32, out_dir / "lm_flow.int8.onnx")
        lm_flow_fp32.unlink()

        # ---- decoder.onnx (fp32 then quantise) ----------------------------
        log.info("Exporting decoder.onnx (fp32)…")
        dec_wrapper = DecoderWrapper(model, dec_schema)
        lat_dummy = torch.randn(1, 15, ldim)
        dec_state_names = [f"state_{i}" for i in range(n_dec_states)]
        out_dec_state_names = [f"out_state_{i}" for i in range(n_dec_states)]
        dec_fp32 = out_dir / "decoder.onnx"
        _export(dec_wrapper,
                (lat_dummy, *dec_init),
                dec_fp32,
                input_names=["latent"] + dec_state_names,
                output_names=["audio_frame"] + out_dec_state_names,
                dynamic_axes={"latent": {1: "seq_len"}, "audio_frame": {2: "audio_len"}})

        log.info("Quantising decoder → decoder.int8.onnx…")
        _quantize(dec_fp32, out_dir / "decoder.int8.onnx")
        dec_fp32.unlink()

    finally:
        _unpatch_kv()

    # ---- tokeniser --------------------------------------------------------
    log.info("Exporting tokeniser…")
    from pocket_tts.utils.config import load_config
    from pocket_tts.utils.utils import download_if_necessary
    tokenizer_path = str(download_if_necessary(cfg.flow_lm.lookup_table.tokenizer_path))
    export_tokenizer(tokenizer_path, out_dir)

    log.info("=== Done: %s ===\n%s", language,
             "\n".join(f"  {p.name}" for p in sorted(out_dir.iterdir())))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--language", required=True,
                   help="Pocket TTS language (e.g. german, german_24l, french_24l, spanish)")
    p.add_argument("--out-dir", required=True, type=Path,
                   help="Output directory for ONNX files")
    args = p.parse_args()
    export_language(args.language, args.out_dir)


if __name__ == "__main__":
    main()
