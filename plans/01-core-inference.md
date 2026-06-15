# Plan: Core machine as local inference backend

## Why
RTX 5070 8GB runs Qwen2.5-7B Q4 locally. Faster than DashScope, zero cost, no internet needed for dev. Pixie reaches core directly via Tailscale (100.69.215.24). k3s cluster available for containerized jobs.

## What was done
- Added `LLM_BASE_URL` and `LLM_MODEL` optional bindings to `Bindings` in `api/src/index.ts`
- Threaded both into `generate`, `generateGreeting`, `generateAgentTurn` in `defaultDeps`
- `.dev.vars` now overrides to `http://localhost:11434/v1` + `qwen2.5:7b` (Ollama)
- `dart_defines/core.json` added: `API_BASE = http://core:8787` (Tailscale, no adb reverse)
- `justfile`: `flutter-core` (run against core) + `build-core` (build + install both devices)
- `generate.ts` already accepted `opts.baseUrl` + `opts.model` — no change needed there

## Setup (one-time)
```bash
# On core
ollama serve             # start daemon (already running after first pull)
ollama pull qwen2.5:7b  # ~4.4GB, fits in RTX 5070 8GB VRAM
```

## Dev workflow
```bash
just api         # starts Wrangler dev — now routes LLM calls to Ollama on core
just build-core  # builds APK with core.json, installs on both devices
# OR for live reload:
just flutter-core  # runs flutter on pixie, API at http://core:8787
```

## Production / bigger workloads
Deploy Ollama as a k8s pod on the cluster for async TTS/recap jobs:
- `kubectl apply -f infra/k8s/ollama.yaml` (to create)
- Expose via ClusterIP + Tailscale ingress
- Document as requirement if RTX 5070 8GB is insufficient (e.g. for 13B+ models)

## NPU (AMD 370HX)
Not yet used. AMD XDNA NPU supports ONNX Runtime EP — relevant for Whisper / Pocket TTS inference offload. Requires `onnxruntime-directml` or ROCm EP. Document as future optimization.
