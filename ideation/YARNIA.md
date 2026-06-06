# YARNIA.md — Detailed Build & Execution Plan

> Canonical execution doc for **Yarnia**, the bedtime-story ritual for parents. Strategy/decision history → `PLAN.md`. Rules/rubric → `CLAUDE.md`.
> **One sentence:** *"We help a parent at 8pm get their kid to sleep with a personalized, screen-off voice story that remembers their child — instead of handing them an iPad."*

---

## ⚠️ Rules compliance (read first)
- The **product (the Yarnia app) must be built June 6** with meaningful commit history from that day. No prebuilt product code, no importing an existing codebase, no faked evidence.
- A **waitlist landing page is customer validation, not the project** — and no-code tools + waitlists are explicitly allowed/encouraged. Still, to keep the project repo's June-6 history clean: **write NO product code before the event.**
- **Tonight = only unambiguously-allowed prep** (notes, copy, accounts/keys, channel list). Optional zero-risk head start: a **no-code** (Tally/Carrd) waitlist — separate from the project repo.
- Everything in §"Step 1" below is built **during the event**.

---

## STEP 1 (FIRST THING TOMORROW — before any app code) — Landing page + signups
**Why first:** the 15% evidence slot is our weak spot, and signups need lead time. Get the page live ~10:00 so it collects waitlist signups in the background all day, feeding the slide-5 evidence and the in-demo share loop. **Keep it lean (≤45 min) so it doesn't eat app build time.**
- **Build:** one page. Hero = *"Open the app. Screen goes off. It talks to you."* → the parent-at-8pm promise → email capture → "send to grandma" hook → €8/mo tease. Static (or no-code) — deploy to Vercel/Cloudflare Pages.
- **Signup backend:** Formspree / Tally / InstantDB — whatever's fastest (decide at kickoff).
- **Drive traffic immediately:** post in parent communities (r/Parenting, r/toddlers, Hamburg/DE parent groups), Burhan's network, a Show-HN-style post. Re-post mid-afternoon.
- **Capture for the pitch:** screenshot the live signup count at ~18:00; quote any "I'd pay for this" message verbatim.
- **In-event loop:** every shared story link points back to the landing page → organic signups, demoed live.

---

## The product (single wedge — everything else is roadmap)
**The wedge, one sentence:** *"Yarnia is the only bedtime app where your kid helps invent a story starring themselves, and it remembers them night after night."* (Generative + per-child memory — the thing pre-recorded catalogs structurally can't do.)

The experience: open → screen dims → a warm voice greets the child by name → **light** co-creation up front ("who's in tonight's story, an owl or a dragon?") → Yarnia narrates a personalized story → session saved + shareable link → "send to grandma."

**⚠️ Bounded co-creation (design rule):** bedtime = wind DOWN. Active inventing can rev a kid up right when you want them calming (Moshi's whole thesis is passive/soothing on purpose). So keep co-creation to a quick, low-key setup at the start, then go **calm and passive** for the narration. Name this on stage before a parent/judge raises it.

**In scope for the demo:** kids' bedtime only.
**Roadmap (NOT pitched):** adult wind-down, ambient soundscapes, guided relaxation, novel suggestions, public publishing.

## The moat — per-child memory stack (make it REAL and VISIBLE)
Defensibility = the memory layer. After a few nights Yarnia knows the child; leaving means starting over.
- **Data model (InstantDB):**
  - `user` → `child { name, age, favorite_characters[], themes[], fears_to_avoid[], voice_pref, pace_pref }`
  - `child` → `session { date, story_summary, characters_used[], liked?, fell_asleep_signal }`
- **Loop:** on each story → retrieve child profile → inject into the generation prompt → after the session, update preferences (explicit "did Lisa like it?" + implicit signals).
- **DEMO MOVE (critical):** **seed a child "Lisa" with 3 prior sessions** so the live run opens with *"Another dragon story like last time? I'll keep the thunder out."* That single line *is* the moat on screen. (Real-time write-back = nice-to-have; seeding is enough to prove it.)

## Architecture / stack
- **Frontend:** Flutter (Dart) — screen-dim + audio-first UI (one codebase: iOS, Android, web). (Planning note: an earlier draft considered Expo/React Native; the build shipped on Flutter.)
- **DB / Auth / Realtime / Storage:** InstantDB (users, children, sessions, audio URLs).
- **Voice / TTS:** ElevenLabs (greeting + narration; expressive).
- **Story generation:** OpenAI or Qwen (both sponsors).
- **Backend:** Cloudflare Worker — thin: take intent + child profile → call LLM for story → call ElevenLabs for audio → upload to InstantDB storage → return audio URL.
- **Data flow:** app → Worker (`/story`: childId + intent) → LLM (story text, profile-injected) → ElevenLabs (audio) → InstantDB (store) → URL back to app → play.

## Build order (June 6, after Step 1)
| Time | Goal |
|---|---|
| 09:00–09:45 | Kickoff: confirm scope, assign **pitch owner**, create public repo + README. |
| 09:45–10:30 | **STEP 1: landing page live + posted** (≤45 min, then it runs all day). |
| 10:30–11:15 | Riskiest spike: open → screen dims → ElevenLabs voice greeting plays end-to-end. |
| 11:15–13:00 | Conversational co-creation loop → LLM story → ElevenLabs narration. Commit often. |
| 13:00–13:30 | Lunch; pitch owner starts deck. |
| 13:30–15:30 | InstantDB session save + shareable link. |
| 15:30–16:30 | **Seed "Lisa" memory** + wire retrieval so the moat shows live. |
| 16:30–17:00 | Evidence sprint: re-drive landing-page traffic; screenshot signups; grab quotes. |
| 17:00–18:30 | Freeze. **Record 60–90s backup demo video.** Finalize ≤7 slides. Rehearse pitch ×2. |
| 18:45–19:00 | Submit repo + deck (+ hosted URL). Hard cut. |

**Must-ship:** voice greeting · co-creation loop · LLM story + ElevenLabs narration · **content-safety guardrail** · session saved · shareable link · **seeded memory shown.**
**Cut if behind:** soundscapes · public publishing · real-time memory write-back (seed instead) · shareable link (mock it in the demo).
**Voice latency go/no-go (~11:15):** if ElevenLabs realtime feels laggy, fall back to pre-generated audio playback. Keep the demo, lose the conversational feel. Decide fast.

## Demo script + safety
1. Open app → screen dims → voice greets.
2. "What should tonight's story be about?" → co-create ("an owl & a cat lost in Hamburg?") → approve.
3. Narrated story plays (ElevenLabs).
4. Show the **memory**: Yarnia references Lisa's past ("dragons, no thunder").
5. Session saved → shareable link → "send to grandma" (open link, hear it).
6. **Live closer:** *"Yarnia, we're about to pitch you to some judges — give us a one-minute intro."* It introduces itself, live.
- **Safety:** venue wifi + live voice is risky → **record a backup video** of steps 1–6 and have it ready.

## Deck — 7 slides
1. **Problem + customer** — parent at 8pm, kid won't sleep, reaching for the iPad they regret.
2. **Solution + product** — Yarnia, the screen-off voice ritual; demo/QR.
3. **Why-now** — real-time *expressive* voice (ElevenLabs) + cheap generation make a conversational, memory-driven bedtime ritual possible only now; anti-attention moment.
4. **Market + competition:** REAL incumbents are the kids-audio category: **Moshi (Moshi Twilight), Yoto, Toniebox, Calm Kids, Spotify Sleep** (NOT Calm-for-adults/ChatGPT, naming the wrong competitors loses credibility instantly). Why they can't follow: they're **pre-recorded catalogs / fixed content cards** (same story for every kid); Yarnia is **generative + per-child memory**, a different product shape that's costly for a catalog / kid-safety business to retrofit. Bottom-up: # parents × €8/mo. Never say "no competitors."
5. **Business model + evidence** — €8/mo (Calm €8, Spotify €10); landing-page signups + quotes.
6. **Go-to-market** — the share loop (story → grandma → new parent) + parent communities.
7. **Team** — **Burhan, dad of two (founder-fit + build)** + Cansin (eng). Contact.

## Pitch opener (first 30 seconds — install founder-fit)
> *"I'm Burhan — a father of two daughters. Bedtime is the one ritual I refuse to outsource to a screen. So we built the opposite of a screen: you open Yarnia, the screen goes dark, and a voice tells your kid a story made just for them — one that remembers them."*

## Weakest points (name them yourself on stage)
- *"Moshi/Yoto already own kids' bedtime audio"* → they're pre-recorded catalogs / fixed cards; we're generative + per-child memory (the kid is the hero, and it remembers them). Different product shape, not a feature they toggle on.
- *"Co-creation will hype my kid up at bedtime"* → co-creation is bounded to a quick, low-key setup, then calm passive narration. Wind-down preserved.
- *Consumer CAC* → the "send to grandma" share loop is built-in distribution; show it live.
- *Retention/novelty* → per-child memory + nightly habit is the moat; the longer you use it, the worse switching gets.

## CEO review verdict (HOLD + evidence-first, locked Jun 5)
Posture: keep scope tight, ring-fence ~2 hrs for evidence, **out-evidence the room, don't out-engineer it** (70% of the score is non-build).
- **Existential risk to answer on stage: content safety.** Parents trust Moshi because it's curated and kid-safe. "AI improvises a story for my 4-year-old" triggers a safety fear. So content-safety is now must-ship: system-prompt constraints (age-appropriate, no violence/scary triggers, honor the child's `fears_to_avoid`) + a fixed safe-mode for the live demo. On-stage line: *"every story runs through age and safety constraints, and Yarnia avoids the exact things that scare your kid, because it remembers them."* Turn the risk into a feature.
- **Hour-1 go/no-go: realtime voice latency** (see build order). Have the pre-generated-audio fallback ready; don't sink the morning chasing low latency.
- **Evidence is first-class, not a 30-min afterthought.** Ring-fence ~2 hrs: landing-page signups (live from tonight, driven all day), a 90s backup demo video, and any parent who tries the prototype on the day. The evidence slide + the content-safety answer are what get you to finals.
- **The demo has one job:** the memory moment (*"it already knows Lisa: dragons, no thunder"*). Center the 3-minute pitch on it; it's the only thing Moshi/Yoto structurally can't do.
- **Verdict:** wedge is sharp, founder-fit is real (Burhan). The only gaps are demand evidence + the safety answer, both closable by 19:00. Greenlit on HOLD + evidence-first.

## Tonight — allowed prep only (NO product code)
- [x] Landing page + signup backend built (`marketing/index.html` + `marketing/worker/`, **InstantDB + Cloudflare Worker**) → add the `signups` entity to InstantDB schema, deploy the Worker (set `INSTANT_ADMIN_TOKEN` as a secret), set the page's Worker URL, deploy the page on Cloudflare Pages. Steps in `marketing/worker/README.md`.
- [x] Deck skeleton drafted (`DECK.md`).
- [ ] Post the recruiting message in Discord #find-your-team + add the tagline to the team board (both in `PLAN.md §7`).
- [ ] Send Hendrik the DM (no-em-dash version); get a yes/no.
- [ ] Set up accounts/API keys: ElevenLabs, OpenAI/Qwen, InstantDB, Cloudflare, Expo, Vercel.
- [ ] Decide who is **pitch/evidence owner**.
- [ ] gstack: base install on both machines (Cansin done, Burhan to do). Team-mode repo bootstrap is a *tomorrow* step (see `CLAUDE.md`).
- Note: the parent-observation test needs the prototype + Burhan's kids, so it's a day-of step, not tonight.
