# PLAN.md — Hackathon Strategy & Competitive Map

> General strategy for the AI BEAVERS hackathon: the room, the rubric play, what to avoid, recruiting, and the day-of. **The chosen idea's detailed build plan lives in `YARNIA.md`.** Rules + rubric live in `CLAUDE.md`.

---

## 1. The room — competitive map (team board, Jun 5 2026)
19 teams forming. Grouped by cluster:

| Cluster | Teams | Notes |
|---|---|---|
| **Agent-infra / dev-tooling** | 1 (OpenAPI/MCP gateway, *2 engineers*), 8 (prompt-eng workspace), 11 (OrchSec agent-security scanner), 10 (autonomous GTM) + free-agent **pulko** (agent harness) | **Most crowded cluster.** Team 1 is the only other strong all-eng team. |
| **Voice** | 6 (EarCoach workouts), 9 (blue-collar admin), 15 (elderly autobiography), 19 (family health check-in) | Crowded; ElevenLabs prize contested here. **No kids/bedtime entry → our lane is open.** |
| **Vertical / other** | 2 (data-sci edu), 3 (roboadvisor), 4 (strategy-ops), 5 (warehouse CV), 7 (women's fintech), 12 (industrial robotics), 13 (DSGVO DACH), 14 (urban planning), 16 (cross-family LLM medical), 17 (website auditing), 18 (event rec) | Mostly **solo non-technical owners** with generic ideas. |

**Strategic read:**
1. Agent-infra + voice are the two most contested clusters — but **bedtime/kids voice is empty**, so Yarnia differentiates inside a hot lane.
2. We're one of only ~2 strong all-engineer teams; most teams are 1 non-tech owner recruiting devs. **Our scarce asset is execution.**
3. **Prelim risk = pattern-matching:** judges see many similar pitches; only the sharpest, best-evidenced, most legible survives.

---

## 2. Positioning strategy (rubric-driven)
Score weights: Problem/customer 20% · Market/business 20% · Product/demo 20% · AI-leverage 15% · Evidence/founder-edge 15% · Pitch 10%. → **70% is non-build.**
1. **Name one buyer in one painful moment** (first sentence: *"We help [customer] do [painful job] because today they're stuck with [bad workaround]."*).
2. **Narrow wedge, not a platform**; show how it grows into a system of record.
3. **Bring one non-copyable evidence point** (a stranger saying "take my money" in writing) — our weakest, heavily-weighted slot.
4. **Bottom-up market math** (# customers × revenue), never "1% of $X B."
5. **Sponsor prize: dropped** unless the chosen idea fits naturally — optimize the main rubric; don't bend the idea for a side prize.
6. **Name our own weakest point** + the test we'd run next (judges reward this).

---

## 3. Our filters
| Input | Value |
|---|---|
| Team | 2 engineers (Burhan + Cansin); strong build/execution |
| Founder edge | dev/infra/agents by trade; **Burhan = dad of two** (the founder-fit for the chosen idea) |
| Buyer access | remote/global → buyer reachable online (communities, share loops) |
| Time | ~9 hr, 19:00 hard cut |
| Win condition | top ~6–7 finalist → top, via a sharp wedge + real evidence + a pitch that lands |

## 4. Idea scorecard (score any candidate 1–5; mirrors the rubric)
Wedge · Buyer · Demand · Why-now · Founder-fit · **Evidence-by-19:00** · 9-hr buildable · **Room-differentiation** · Pitch-legibility.
**Auto-kill:** anything on §5, or that fails Buyer / Why-now / Evidence / Room-differentiation.

---

## 5. Do NOT build — solved in market OR taken in the room
**Solved by big players (researched Jun 5 2026):**
- Voice incident response → PagerDuty AI suite, incident.io ($62M), Rootly, Datadog Bits AI SRE.
- OpenAPI→tooling / MCP gateways / code-exec sandboxes → Anthropic *bought Stainless ($300M)*, Speakeasy ($15M), Kong/Cloudflare/E2B/Daytona/Modal.
- Skills registry → skills.sh (679k skills) + Anthropic/AWS/Google/JFrog.
- Voice-agent testing → 7+ funded (Coval, Hamming, Cekura, Retell Assure, Bluejay, Braintrust).
- Skills/agent security scanning → Snyk⊃Invariant, Cisco⊃Lakera, Microsoft, NVIDIA.

**Taken in our room:** OpenAPI/MCP gateway (Team 1) · agent-security scanner (Team 11) · prompt-eng workspace (Team 8) · autonomous GTM (Team 10) · agent harness (pulko) · the voice verticals (Teams 6/9/15/19).

**Lesson:** agent infra is consolidating into hyperscalers/Anthropic AND is the room's most crowded lane — avoid head-on.

---

## 6. Ideas explored → DECISION
We scored two directions against §4:
- **Agent-reliability tools** (silent tool-call failures / "git-diff for agents" regression-diff / replay debugger) — strong founder-fit + defensible, but dry to pitch, and the room is heavy on agent-infra. Best scorer: regression-diff (~39/45).
- **Yarnia — bedtime ritual for parents** — best demo, real founder-fit (Burhan, dad of two), open in the room, ElevenLabs fit; weaker on consumer CAC + same-day evidence (~30/45, lifts with the parent founder-fit + a memory-moat + a signups page).

**Decision: Yarnia.** Chosen for genuine founder-fit + the most resonant live demo + an open slot in the room, accepting the consumer-CAC trade. **Full build/deck/evidence plan → `YARNIA.md`.**

---

## 7. Recruiting (we're eng-heavy; 70% of score is non-build)
If we want to strengthen pitch/GTM/evidence, top unattached non-engineers from the board/Discord:
- **Hendrik** (Hamburg, GTM/sales): ~$1.6M ARR in 16 mo, idea-agnostic, wants to own problem/customer + pitch + GTM. Best fit.
- **S** — marketing/business/UI/presenting (backup).
- **Katharina F** — marketing @ AI.GROUP/AI.HAMBURG; owns Team 18, so only if she'd jump.
- If we stay 2-person: **designate a pitch/evidence owner** for the day.

**Generic Discord #find-your-team post (recruit a GTM/pitch teammate):**
> Hey all 👋 We're 2 engineers (one's a dad of two) building **Yarnia** at the hackathon: a screen-off voice app that tells your kid a personalized bedtime story and remembers them, instead of handing them an iPad. Build and idea are locked. We're looking for one person to own the GTM/pitch/customer side and make the deck land. If that's you, DM us. [early waitlist: <landing URL>]

**Team-board "Idea" cell tagline (Excel sheet):**
> Yarnia (screen-off AI bedtime stories that remember your kid)

**Direct DM to Hendrik (warmer, targeted):** see the no-em-dash version we drafted; lead with "your GTM/pitch background is exactly what we're missing," end with "Want in?"

## 8. Day-of timeline (general skeleton; Yarnia-specific order in `YARNIA.md`)
| Time | Goal |
|---|---|
| 09:00–10:00 | Lock scope + one-sentence pitch; public repo + README; assign roles. |
| 10:00–10:45 | Stand up the evidence/landing page early so signups run all day (see `YARNIA.md` Step 1). |
| 10:45–13:00 | Build the core happy path of ONE workflow. Commit often. |
| 13:00–16:30 | Make the demo *believable*; pitch owner drafts deck + evidence post. |
| 16:30–17:00 | **Evidence sprint:** drive signups / community post; capture quotes + counts. |
| 17:00–18:30 | Freeze. Record a 60–90s backup demo video. Finalize ≤7 slides. Rehearse pitch ×2. |
| 18:45–19:00 | Submit repo + deck (+ hosted URL). Hard cut — submit something whatever state. |
| 19:15+ | Pitch (3 min, no Q&A). If finalist: 3 min + 2 min Q&A. |

**Pre-event prep (allowed: notes/accounts only, NO product code):** lock idea, draft deck skeleton + landing-page copy + community posts, set up API keys, list signup channels, decide pitch owner. (See `YARNIA.md` "Tonight" checklist.)

## Links
- Ideas & Strategy: https://docs.google.com/document/d/1K3fbTFPysRgACCj0FzxrL0VB2-ebbUDw_tRNqpYJ7YQ
- Logistics: https://docs.google.com/document/d/1xEX2bykI6tyfQ-xJvUFWknXLcZQGA6DhtCDKMYuAbpE
- Judging & Scoring: https://docs.google.com/document/d/1oYZ8MwMlcYTdA2wAQIUTBexxxzLDJrz9i4SZZdjNZnA
- Team board: https://docs.google.com/spreadsheets/d/1uKK4qRIkh-hTNrl-O5KjxoHzNkDCduv2/edit
- Discord: https://discord.gg/MCYGuUQ2vd · Event: https://luma.com/hmqh70k1
