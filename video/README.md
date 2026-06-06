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

## Commands
- **Preview/iterate:** `npm install` then `npm run dev` (Remotion Studio — scrub + live edit).
- **Re-render:** `npx remotion render YarniaDemo out/yarnia-demo.mp4`
- **Regenerate audio** (edit the `SCRIPT` in `scripts/gen-audio.mjs` first):
  `node scripts/gen-audio.mjs` — reads `ELEVENLABS_API_KEY` from `../api/.env`.
- **Swap in a real kid recording:** drop `kid-1.mp3` etc. into `public/` (same names), re-render.
