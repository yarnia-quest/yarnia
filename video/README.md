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
Drives the live app in a mobile-emulated browser via Playwright (fake mic flags so the ElevenLabs
voice agent actually connects). Playwright video has no audio, so the session's speech is dubbed in
afterward. The dub covers the **whole turn-taking loop**: Yarnia's greeting, the child asking for a
story, then Yarnia telling it.

The orb is a turn-state indicator (gold "Yarnia is speaking" / cream "Your turn..."), so the dub
is assembled to keep audio and orb-state in sync: Yarnia's voice only plays over the gold orb, the
child's only over the cream one. The story reuses (loops) the gold window — same color, so the only
seams are the orb's own pulse, never a state jump.

### Re-render it (one button): the `Render real-app demo` GitHub Action
`.github/workflows/render-realapp-demo.yml` runs the whole pipeline on a runner (open internet +
real headless Chromium + ffmpeg), reuses the committed dub clips, and commits both
`out/yarnia-realapp-demo.mp4` and `marketing/public/video.mp4`. Trigger it from the Actions tab
(`workflow_dispatch`). This is the supported way to re-render, since the live app and browser
downloads are off the Claude Code sandbox's egress allowlist.

### Run it locally
1. `npm i playwright && npx playwright install chromium` (or set `PW_CHANNEL=chrome` to use the
   system Google Chrome).
2. `node capture/record-realapp.mjs` → records `/tmp/ywcap/videos/*.webm` and logs the greeting
   text + orb timings to `/tmp/ywcap/marks.json`.
3. `node scripts/build-realapp-demo.mjs` → upscales the capture, lays the committed dub clips over
   the matching orb states, and writes `out/yarnia-realapp-demo.mp4` (49.6s, 780x1688). It reads
   the newest webm + `marks.json` automatically; override with `WEBM=`, `MARKS=`, `OUT=`. Then
   `cp out/yarnia-realapp-demo.mp4 ../marketing/public/video.mp4` to update the served copy.

`build-realapp-demo.mjs` is the reproducible form of the ffmpeg recipe (boot trim + 2x upscale,
then a state-matched concat of pre-roll + gold/cream/looped-gold, then `adelay`+`amix` of the dub
clips). All offsets are derived from the measured dub-clip durations, so the cut is deterministic.

### Regenerate the dub clips (only if the live greeting wording drifts)
The three clips (`public/realapp-{greeting,kid,story}.mp3`) are committed and reused as-is. If the
live agent's greeting no longer matches `realapp-greeting.mp3` (the capture logs it to marks.json),
edit the greeting line in `scripts/gen-realapp-audio.mjs`, run `node scripts/gen-realapp-audio.mjs`
(Clara for Yarnia, child voice for the kid; needs `ELEVENLABS_API_KEY` in `api/.env`), and commit
the clips before re-rendering.

Note: taps use fixed coordinates for the current Flutter layout (canvas, no DOM selectors);
update them if the UI moves.
