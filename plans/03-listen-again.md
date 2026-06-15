# Plan: Listen-again audio (background TTS job)

## Why
Current narration is just-in-time sentence-by-sentence. "Listen again" from history should play a pre-rendered single MP3 with proper paragraph pacing and consistent voice. Story text is already saved in InstantDB via `/session/persist`.

## Approach

### Phase 1 — CF Worker async task (MVP, no new infra)
After `/session/persist` saves the story, fire an async background synthesis:
- Use `ctx.waitUntil()` (CF Worker's background task mechanism) to call `synthesize.ts`
- `synthesize.ts` already exists for ElevenLabs TTS — add a paragraph-aware plain-text version
- Write resulting audio URL back to the InstantDB session via admin SDK

App change: history panel checks `session.audioKey`; if present shows a play button (wiring already partially exists in `app/flutter/lib/widgets/history_panel.dart`).

### Phase 2 — Core/k8s TTS pod (better quality)
Replace the CF Worker synthesis call with a POST to a Kokoro or MeloTTS server on core:
- Kokoro (~82M, sherpa-onnx ready) — same engine family as on-device Pocket TTS
- Deploy as a k8s pod, expose via Tailscale ingress
- CF Worker POSTs story text → gets back audio URL (stored in R2 or similar)
- No app change — just swap the backend in `synthesize.ts`

### Phase 3 — Nebula (highest quality, cloud)
For premium quality: Nebula handles the TTS render job asynchronously. Same interface, better voice. Document as a paid-tier feature.

## Files
- `api/src/index.ts` — `/session/persist` route: add `ctx.waitUntil(renderAudio(...))`
- `api/src/synthesize.ts` — add paragraph-aware render function
- `app/flutter/lib/widgets/history_panel.dart` — show play button when audioKey present

## Requirements (for Phase 2+)
- Kokoro ONNX model deployed on core k8s (RAM: ~500MB, no GPU needed for inference)
- HTTP API: `POST /tts { text, voice, language } → { audioUrl }`
- R2 bucket or equivalent for audio file storage (already used for ElevenLabs audio)
