# video/ — Yarnia demo video (Remotion)

A scripted ~53s portrait (1080x1920) demo of a child's bedtime session with Yarnia. It is
**not** a recording of the live app: the audio is pre-generated and the UI is recreated in
React, then Remotion renders it frame-by-frame to MP4. This is deterministic and re-renderable.

## What's here
- `src/yarnia/` — the composition: `Starfield`, `Orb` (gold while Yarnia speaks, cream on the
  child's turn — ported from `app/flutter`), `Caption`, `timeline.ts`, `YarniaDemo.tsx`.
- `src/yarnia/theme.ts` — brand colors copied from `app/flutter/lib/theme.dart`.
- `public/*.mp3` — generated speech clips (Yarnia in the real **Clara** voice; child voice).
- `src/yarnia/manifest.json` — per-clip durations + word timings (drives the timeline; the
  word timings are unused yet — available for karaoke-style captions).
- `out/yarnia-demo.mp4` — the rendered video (tracked in git on purpose).

## Two videos
- **`out/yarnia-demo.mp4`** — the Remotion *recreation* (this project renders it).
- **`out/yarnia-realapp-demo.mp4`** — a capture of the **real app** at app.yarnia.quest, driven
  in a mobile-emulated browser (real onboarding → greeting → the live voice agent connecting →
  "Yarnia is speaking"). See "Real-app capture" below.

## Commands
- **Preview/iterate:** `npm install` then `npm run dev` (Remotion Studio — scrub + live edit).
- **Re-render:** `npx remotion render YarniaDemo out/yarnia-demo.mp4`
- **Regenerate audio** (edit the `SCRIPT` in `scripts/gen-audio.mjs` first):
  `node scripts/gen-audio.mjs` — reads `ELEVENLABS_API_KEY` from `../api/.env`.
- **Swap in a real kid recording:** drop `kid-1.mp3` etc. into `public/` (same names), re-render.

## Real-app capture (out/yarnia-realapp-demo.mp4)
Drives the live app in a mobile-emulated browser via Playwright + the system Google Chrome
(fake mic flags so the ElevenLabs voice agent actually connects). Playwright video has no audio,
so the session's speech is dubbed in afterward. The dub covers the **whole turn-taking loop**:
Yarnia's greeting, the child asking for a story, then Yarnia telling it.

The orb is a turn-state indicator (gold "Yarnia is speaking" / cream "Your turn..."), so the dub
is assembled to keep audio and orb-state in sync: Yarnia's voice only plays over the gold orb, the
child's only over the cream one. The story reuses (loops) the gold window — same color, so the only
seams are the orb's own pulse, never a state jump.

1. `npm i playwright` (uses system Chrome; no browser download).
2. `node capture/record-realapp.mjs` → records `/tmp/ywcap/videos/*.webm` and logs the exact
   greeting text + timings to `/tmp/ywcap/marks.json`.
3. Generate the dub clips (Clara for Yarnia, child voice for the kid): edit the greeting line in
   `scripts/gen-realapp-audio.mjs` to match marks.json if it changed, then
   `node scripts/gen-realapp-audio.mjs` → `public/realapp-{greeting,kid,story}.mp3`.
4. Trim boot + 2x upscale to `/tmp/ywcap/vid.mp4` (orb appears ~12.2s in; gold turn ~12.2–21.3s,
   cream turn ~21.5–25s):
   ```
   WEBM=$(ls -S /tmp/ywcap/videos/*.webm | head -1)
   npx remotion ffmpeg -y -ss 5 -i "$WEBM" -t 25 -vf "scale=780:1688:flags=lanczos" -an \
     -r 30 -c:v libx264 -crf 20 -pix_fmt yuv420p /tmp/ywcap/vid.mp4
   ```
5. Assemble a state-matched visual track from `vid.mp4` — pre-roll (0→12.2) + gold greeting slice +
   looped cream slice for the kid + looped gold slice for the story — then mix the three clips onto
   it at their offsets (greeting 12.23s, kid 20.62s, story 24.87s) with `adelay`+`amix`. The exact
   ffmpeg recipe lives in this repo's history (the commit that added the full dub); re-run it to
   re-render `out/yarnia-realapp-demo.mp4`.

Note: taps use fixed coordinates for the current Flutter layout (canvas, no DOM selectors);
update them if the UI moves.
