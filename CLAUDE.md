# CLAUDE.md — AI BEAVERS Founder Hackathon Operating Manual

> Idea-agnostic playbook + reference material. Read this first, every time. These are the rules and the bar that hold no matter which idea we land on. The research landscape, idea-evaluation scorecard, and candidate idea pool to iterate on live in `ideation/PLAN.md`.

## Repo layout
- `ideation/` — strategy + planning: `PLAN.md` (hackathon strategy + room map), `YARNIA.md` (build/evidence/review verdicts), `DECK.md` (pitch).
- `marketing/` — waitlist landing page (`index.html`) + its signup `worker/` (Cloudflare Worker → InstantDB).
- `client/` — the Yarnia app (Expo). Built June 6.
- `server/` — product backend Worker (story gen + voice + InstantDB + safety). Built June 6.
- `infra/` — config, secrets, CI. Source of truth: root `.env` (gitignored) + `.env.example`; GitHub repo secrets mirror those keys.
- `CLAUDE.md` (root) — this operating manual, auto-loaded by Claude Code.

## Mission & hard constraints
- **Team:** 2 engineers. **Event:** House of AI, Hamburg · Sat **June 6, 2026** · 09:00–21:00.
- **~9 hours of real build time.** Submission is a **hard cut at 19:00** — no extensions. Submit *something* whatever state it's in.
- **Required at submission:** public **GitHub repo** (README + commit history *from June 6*) + **pitch deck, ≤7 slides**.
- **Preferred (optional):** hosted preview / live demo URL.
- **Pitch:** everyone pitches live. Prelims = **3 min, no Q&A**. Finals (≈6–7 teams) = **3 min + 2 min Q&A**.

## North star — the judging rubric (this IS the spec)
| Criterion | Weight |
|---|---|
| Problem & customer clarity | 20% |
| Market & business potential | 20% |
| Product execution & demo | 20% |
| AI-native leverage & technical approach | 15% |
| Evidence, insight & founder edge | 15% |
| Pitch clarity | 10% |

**40% is buyer + business; only 20% is the demo.** A rough product with a razor-sharp buyer beats a glossy demo with no buyer logic. Optimize accordingly.

## How to win (the 6 moves)
1. **Name one buyer in one painful moment.** First-sentence template: *"We help **[specific customer]** do **[specific painful job]** because today they're stuck with **[bad current workaround]**."*
2. **Sell the work, not a copilot.** The product *does the job*; it isn't an "assistant for" it.
3. **Narrow wedge, not a platform.** One workflow, end-to-end. Then show how the wedge grows into a system of record.
4. **Bring one non-copyable evidence point.** A stranger saying "when can I try it / take my money" *in writing*, this week. Compliments ≠ evidence.
5. **Bottom-up market math:** # customers × revenue/customer. Never "1% of a $50B market."
6. **Name your own weakest point** + the test you'd run Monday. Learning velocity > defensiveness.

## 7-slide deck structure
1. **Problem + customer** — specific pain, who has it (role/size/industry), what they do today.
2. **Solution + product** — what we built; demo link/QR.
3. **Why now** — new API / regulation / cost collapse. For AI: why this is more than a wrapper.
4. **Market + competition** — bottom-up sizing; direct + indirect + status-quo competitors; why we win. Never "no competitors."
5. **Business model + traction/evidence** — who pays, how much, how often, what we validated.
6. **Go-to-market** — how the first 50 customers find us (a channel we can actually run).
7. **Team** — why this team has the edge. End with contact info.

## Guardrails — do NOT build these
**Weak-idea patterns:** ChatGPT-for-X wrapper · "AI [job title]" with no named human · feature-not-company · big-number-no-plan · solution-looking-for-a-problem · generic horizontal "for everyone" · second-mover-with-no-edge ("like X but cheaper").

**Crowded categories (avoid):** generic chatbots · AI note-takers / meeting summarizers · resume builders · AI companions · generic SEO/content writers · code-gen copilots (Copilot owns it) · generic LLM observability (Langfuse/LangSmith/Braintrust own it).

## Day-of integrity rules
- Build **fresh from scratch** on June 6. Idea notes/sketches/research prepared beforehand are allowed; **code is not**.
- **Meaningful commit history from June 6** — judges may inspect the repo.
- No importing a private existing codebase. No faked commit history, demo, users, or evidence.

## Our edge & roles (idea LOCKED: Yarnia — see `ideation/PLAN.md`)
- **Founder-market fit:** **Burhan is a dad of two daughters** → bedtime is lived pain. Open every pitch with this in the first 30 seconds; it's our strongest signal to the angel judges.
- **Team = 2 engineers (Burhan + Cansin), no GTM teammate.** Since 70% of the score is non-build (buyer 20% + market 20% + evidence 15% + pitch 10%), **designate one of us as pitch/evidence owner** for the day — that person also runs the landing-page signups.
- Both build the demo critical path; the pitch owner also owns deck + evidence.
- Both must explain the problem in one sentence: *"We help a parent at 8pm get their kid to sleep with a screen-off voice story that remembers their child."*

## Sponsor cheat-sheet (design for a side prize too)
- **ElevenLabs** — voice AI agents. *Highest-value overlap with our voice lane.* Killer demo = a voice agent that runs a whole workflow + calls tools.
- **Mollie** — European payments/checkout (iDEAL, SEPA, Bancontact, Apple/Google Pay). Easy to bolt a real checkout onto any product.
- **Qwen** — open models + Qwen Code agent CLI. "Zero vendor lock-in" angle judges like.
- **Bilt** — describe an app → native iOS/Android. For a publish-to-store mobile demo.
- **OpenAI** — frontier models / realtime voice API.
- **Cursor** — AI IDE (Agent/Plan mode) for fast multi-file build.
- **SAGEOBOT** — AI search visibility (GEO/AEO).
- **Winning combos:** ElevenLabs + Mollie ("voice + payments") · Cursor + Qwen (fast agentic build) · Bilt + ElevenLabs (mobile + voice).

## Tooling: gstack (shared dev setup)
- **Base install (every machine, required):** needs Bun (`curl -fsSL https://bun.sh/install | bash`), then
  `git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup`
  This is what gives you `/office-hours`, `/plan-ceo-review`, `/review`, `/qa`, `/ship`, etc. **Cansin: done. Burhan: run this (Bun first).**
- **Team mode is NOT a different install** — it's a one-time *repo* bootstrap that makes new teammates auto-install. For two people who both ran the base install, you already have everything; team mode mainly matters for onboarding extra teammates (e.g. if Hendrik joins and clones).
- **If you want it, run it ONCE on the shared repo tomorrow** (after `git init` + first commit), not tonight (no repo yet, and we keep June-6 commit history clean):
  `(cd ~/.claude/skills/gstack && ./setup --team) && ~/.claude/skills/gstack/bin/gstack-team-init optional && git add .claude/ CLAUDE.md && git commit -m "chore: gstack team setup"`
  Use **optional**, never `required` — `required` blocks a teammate from working if their install hiccups, which you don't want on hackathon day.
- **Nothing in your current setup is broken.** Base install on both machines is all you need.

## Links
- Ideas & Strategy guide: https://docs.google.com/document/d/1K3fbTFPysRgACCj0FzxrL0VB2-ebbUDw_tRNqpYJ7YQ
- Logistics guide: https://docs.google.com/document/d/1xEX2bykI6tyfQ-xJvUFWknXLcZQGA6DhtCDKMYuAbpE
- Judging & Scoring guide: https://docs.google.com/document/d/1oYZ8MwMlcYTdA2wAQIUTBexxxzLDJrz9i4SZZdjNZnA
- Discord: https://discord.gg/MCYGuUQ2vd · Event: https://luma.com/hmqh70k1
