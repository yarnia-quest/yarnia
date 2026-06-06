# Yarnia — Submission packet (June 6, 2026)

> Everything needed to submit before the **19:00 hard cut**. Paste the block below into the Discord `#submissions` form. Check the blocker first.

---

## Required deliverables — checklist

- [x] **Public GitHub repo** with June-6 commit history → https://github.com/yarnia-quest/yarnia *(108 commits today; repo is now PUBLIC)*
- [x] **README** at repo root — present, describes product + stack
- [x] **Pitch deck, exactly 7 slides** → `ideation/results/deck.html` (interactive: press `F` for fullscreen, `←/→` to navigate) and `ideation/results/deck.pdf` (7-page 16:9 export, fonts embedded, works offline)
- [x] **Optional: hosted preview URL** → landing page live at https://yarnia.quest (the app itself demos live on the laptop + a recorded backup video)

---

## Paste-into-the-form block

```
Project: Yarnia
One-liner: Open the app, the screen goes off, and a voice tells your kid a bedtime story made just for them — one that remembers them, night after night.

Repo: https://github.com/yarnia-quest/yarnia
Deck: ideation/results/deck.pdf  (7 slides, 16:9; deck.html is the live version)
Live: https://yarnia.quest  (landing + waitlist; app demoed live on stage)

Team: Burhan (father of two, founder-market fit + build) · Cansin (engineering)
Stack: Flutter · Cloudflare Workers · InstantDB · ElevenLabs · Qwen/OpenAI
Contact: hi@ai-beavers.com
```

---

## Submission artifacts in this folder

| File | What it is |
|---|---|
| `deck.html` | The 7-slide pitch deck — projector-ready, on-brand, keyboard-navigable. **The required deliverable.** |
| `deck.pdf` | 7-page 16:9 export of the deck (Fraunces + Lora embedded; renders offline, no wifi needed). Upload this if the form wants a file. |
| `pitch-script.md` | The 3-minute spoken pitch with timing, the founder opener, and finals Q&A prep. |
| `SUBMISSION.md` | This file — the checklist + form block. |

### Re-export the PDF after any deck edit
```bash
cd ideation/results && "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="deck.pdf" --virtual-time-budget=4000 "file://$(pwd)/deck.html"
```

---

## Final-hour run sheet (before 19:00)
1. **Open `deck.html` on the presenter laptop**, fullscreen, click through once on the projector — confirm fonts load (needs network for Google Fonts; if venue wifi is flaky, present from `deck.pdf` instead — it has the fonts baked in).
2. **Record / confirm the 60–90s backup demo video** is on the laptop and plays offline.
3. **Screenshot the live signup count** from yarnia.quest and drop it onto Slide 5 (replace the Finn-&-Ella card or add beside it) if the number is strong.
4. **Submit** the form with the paste block above. Do it by ~18:45 — never at 18:59.
5. Rehearse the pitch twice against `pitch-script.md`. Protect the memory-line demo moment.
