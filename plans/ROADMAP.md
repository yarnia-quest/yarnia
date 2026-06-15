# Yarnia — roadmap

Current state: `on-device-voice-stack` tag. Greet → chat (Qwen3/Ollama) → agree → generate → narrate → interrupt. No ElevenLabs. Pocket TTS / Piper / Whisper on-device. Cloud CF Worker for LLM quality turns.

## Tracks

| # | Plan | Status | Summary |
|---|------|--------|---------|
| A | [Repo hygiene](00-hygiene.md) | ✅ done | Committed loose files, .gitignore models/, plans/ created |
| B | [Core inference](01-core-inference.md) | 🔄 in progress | Ollama on RTX 5070 as local LLM backend; `LLM_BASE_URL`/`LLM_MODEL` wired |
| C | [Agent prompt quality](02-agent-prompt.md) | ⬜ next | Port ElevenLabs prompt structure (returning/first_time, one-question rule, safety) |
| D | [Listen-again audio](03-listen-again.md) | ⬜ queued | Background TTS job → full story MP3 saved to InstantDB |

## Hardware
- **core** (this laptop, Tailscale): RTX 5070 8GB, AMD 370HX 24-core, 93GB RAM, k3s 3-node cluster
- **pixie** (Pixel 9 Pro, Tailscale): test device, direct connection to core at 100.69.215.24
- **Huawei** (USB): weak device, tests system TTS / Piper path

## Key constraints
- Context window on-device: ekv1280 (~1280 tokens) — keep prompts tight
- Offline-first: everything works without network; cloud is quality boost only
- No ElevenLabs in the Flutter app — on-device TTS only (Pocket / Piper / System)
- Nebula / bigger machines: use for async background jobs, not real-time turns
