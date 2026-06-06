# BUILD-DAY.md — June 6 demo build plan (2 engineers)

> The day-of execution split for the Yarnia demo. Strategy/scope -> `YARNIA.md`. Pitch -> `DECK.md`.
> **Goal:** a frozen, rehearsed demo by 17:00, then 17:00 to 19:00 for deck + rehearsal. Hard cut 19:00.
> **Team:** Cansin + Burhan (2 engineers, no separate PM/GTM). All non-build work folds onto the two of us.

## Locked decisions (do not relitigate mid-build)
- **Demo surface:** Expo **Web** on the presenter laptop (Chrome). No real-device or Expo Go dependency for the live run. Screen-dim still happens in-app.
- **Co-creation input:** **live voice via the browser Web Speech API** (on-device transcription in Chrome, no key, low latency, no audio streamed over venue wifi). **Tap chips ("owl / dragon") render under the mic as a visible fallback** so a misfire never stalls the demo.
- **Output voice:** ElevenLabs (the expressive narration the judges hear). This is the part that must sound good.
- **Story gen:** OpenAI (Qwen as backup if a key is missing).
- **Memory:** seed a child "Lisa" with 3 prior sessions in InstantDB and inject on retrieval. Real-time write-back is a nice-to-have, cut if behind.
- **Keys:** set just-in-time in repo-root `.env` (and `api/.dev.vars` for `wrangler dev`) as each integration is wired. Never hardcode.

## The demo shape (what we are building)
```
[Expo Web app]  open -> screen dims -> moon UI -> warm voice greets "Lisa" by name
   |             co-creation: "Who's in tonight's story?"  [mic] + [owl][dragon] chips
   |                  -> THE MOAT LINE: "Another dragon? I'll keep the thunder out."  (seeded memory)
   v
[Worker POST /story]  load Lisa's profile -> OpenAI (safety-constrained prompt + fears_to_avoid)
   |                  -> ElevenLabs TTS -> return audio + text
   v
[Expo Web app]  calm narrated story plays, screen dark -> "send to grandma" share link
```
**What wins, in priority order:** (1) the memory line on open, (2) the calm screen-off narration, (3) the safety guardrail we name on stage. Everything else is cuttable.

## Track split

### Cansin -> backend / voice / memory (`api/` + `instant/`)  ·  also DEMO-LEAD
Owns the laptop that runs the live demo + records the backup video.
- `api/` Cloudflare Worker, `POST /story`: load child profile -> OpenAI story-gen with a **content-safety system prompt** (age band, no violence/scary triggers, honor `fears_to_avoid`) -> ElevenLabs TTS -> return `{ audioUrl|audioBase64, text }`.
- Follow the `marketing/` pattern: `wrangler.toml` with no hardcoded ids, secrets via `wrangler secret put` / `.dev.vars` locally. Deploy target `api.yarnia.quest`.
- `instant/`: extend schema with `child` and `session` entities + links; **seed "Lisa" with 3 sessions**; write the retrieval that produces the opening memory line.

### Burhan -> app / UX (`app/`)  ·  also PITCH-LEAD
Drives the deck and rehearsal pacing in the 17:00 block; delivers the founder-fit opener.
- `app/` Expo **Web** app inheriting the marketing brand (navy `#12132a`, moon-gold `#f1c673`, cream `#f6efe0`, Fraunces display + Lora body, starfield).
- Open -> **screen-dim** -> moon greeting. **Web Speech API mic** + tap-chip fallback for co-creation. Call `/story`. Calm passive narration screen with audio playback. "Send to grandma" share link (mock the link page if tight).

(Swap tracks if you prefer; Burhan as pitch-lead matches the founder-fit opener.)

## Sync points (integrate here, do not drift)
1. **~11:15 — audio end-to-end.** Worker returns ElevenLabs audio for a hardcoded prompt; the app plays it.
2. **~12:30 — real story flows.** A tap or voice choice -> OpenAI story -> narration.
3. **~14:00 — the moat shows.** Seeded Lisa renders the memory line on open.

Agree the `/story` request + response shape at the first sync and freeze it so both sides can mock the other.

## Timeline (demo frozen 17:00 · 17:00 to 19:00 prezo · hard cut 19:00)

| Time | Cansin (backend/voice/memory) | Burhan (app/UX) |
|---|---|---|
| 09:45-10:15 | Scaffold `api/` Worker + extend `instant/` schema; first commit. | Scaffold `app/` Expo Web; night-sky shell; first commit. |
| 10:15-11:15 | `/story` -> ElevenLabs audio for a hardcoded prompt. | Screen-dim moon UI + audio playback. **Sync 1.** |
| 11:15-12:30 | OpenAI gen + **safety system prompt**; choice -> story. | Web Speech mic + tap-chip fallback; call `/story`. **Sync 2.** |
| 12:30-13:00 | Lunch. Pitch-lead opens DECK.md. | Lunch. |
| 13:00-14:00 | **Seed Lisa + retrieval -> opening memory line. Protect this hour.** | Session-save + "send to grandma" link. **Sync 3.** |
| 14:00-15:00 | Greeting voice + run full demo script top to bottom. | Polish transitions; demo script clean. |
| 15:00-15:30 | **Record 60-90s backup video** (one clean take of the happy path). | |
| 15:30-17:00 | Buffer / fix / re-drive landing traffic + screenshot signup count. | Buffer / polish. |
| 17:00-19:00 | **Freeze.** Finalize <=7 slides · rehearse pitch x2 · dry-run on the projector. | Same. |

## Must-ship (in order) / cut-if-behind
- **Must-ship:** seeded memory line · ElevenLabs narration · content-safety guardrail · co-creation (voice + tap fallback) · screen-dim UI.
- **Cut-if-behind:** real-time memory write-back (seed only) · live share link (show the page statically) · greeting personalization (bake into the first story line).

## Evidence (runs in the background, low effort)
- Landing page is already live at yarnia.quest collecting signups. Re-drive parent communities + Burhan's network mid-morning and ~16:00.
- Screenshot the signup count at ~16:30 for slide 5. Quote any "I'd pay for this" message verbatim.

## On-stage answers (rehearse these)
- **Safety:** "every story runs through age and safety constraints, and Yarnia avoids the exact things that scare your kid, because it remembers them."
- **Moshi/Yoto:** pre-recorded catalogs / fixed cards; we are generative + per-child memory. Different product shape, not a feature they toggle on.
- **Co-creation hypes the kid up:** bounded to a quick low-key setup, then calm passive narration. Wind-down preserved.

## Integrity reminder
Product code (`app/` + `api/`) is built today with real June-6 commit history. Commit often and meaningfully. `marketing/`, `instant/` waitlist, and `ideation/` were allowed pre-event prep.
