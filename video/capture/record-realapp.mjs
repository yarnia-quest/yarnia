// Records the REAL app at https://app.yarnia.quest in a mobile-emulated browser, driving the
// actual onboarding -> greeting -> voice agent, and saves a video of it. This is the "real app"
// alternative to the Remotion recreation in ../src/yarnia.
//
// How it works:
//  - Playwright drives the installed Google Chrome (channel:"chrome") with fake media flags, so
//    the mic is auto-granted and the ElevenLabs voice agent actually connects (Yarnia speaks).
//  - The context emulates an iPhone-ish portrait viewport (390x844) and records video.
//  - Network responses are awaited (POST /child, /agent/session) so taps don't race latency.
//
// IMPORTANT LIMITATIONS:
//  - Playwright video has NO audio track, so the agent's voice is not captured. The real greeting
//    is dubbed in afterward (see the ffmpeg steps in ../README.md), using the exact greeting text
//    this script logs to marks.json.
//  - The taps use fixed coordinates for the CURRENT Flutter layout (it renders to <canvas>, so
//    there are no DOM selectors). If the UI moves, re-screenshot and update the coordinates.
//
// Setup (local):  npm i playwright   then set PW_CHANNEL=chrome to use the system Google Chrome.
// Setup (CI):      npm i playwright && npx playwright install chromium   (bundled Chromium, default).
// Run:    node capture/record-realapp.mjs
// Output: /tmp/ywcap/videos/*.webm  +  /tmp/ywcap/marks.json (timings + greeting text)
import { chromium } from "playwright";
import { writeFileSync, mkdirSync } from "node:fs";

const OUT = "/tmp/ywcap";
mkdirSync(`${OUT}/videos`, { recursive: true });
mkdirSync(`${OUT}/shots`, { recursive: true });
const t0 = Date.now();
const el = () => ((Date.now() - t0) / 1000).toFixed(2);

// PW_CHANNEL=chrome drives the installed Google Chrome; unset uses Playwright's bundled Chromium.
// We run HEADED (headless:false) because the app is Flutter web (CanvasKit/WebGL to <canvas>), which
// is unreliable in chrome-headless-shell; in CI this script is wrapped in xvfb-run for a display.
// The fake-media flags auto-grant the mic and let the ElevenLabs voice agent connect.
const HEADLESS = process.env.PW_HEADLESS === "1";
const browser = await chromium.launch({
  channel: process.env.PW_CHANNEL || undefined,
  headless: HEADLESS,
  args: [
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--autoplay-policy=no-user-gesture-required",
  ],
});
const ctx = await browser.newContext({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  isMobile: true,
  hasTouch: true,
  permissions: ["microphone"],
  recordVideo: { dir: `${OUT}/videos`, size: { width: 390, height: 844 } }, // == CSS viewport, else it letterboxes
});
const page = await ctx.newPage();

let greeting = null;
let childId = null;
page.on("response", async (r) => {
  if (r.url().includes("/agent/session")) {
    try {
      const j = await r.json();
      greeting = j.dynamicVariables?.greeting;
      childId = j.dynamicVariables?.child_id;
    } catch {
      /* ignore */
    }
  }
});

const shot = async (name) => {
  try {
    await page.screenshot({ path: `${OUT}/shots/${name}.png` });
  } catch {
    /* best-effort diagnostics */
  }
};

const marks = {};
await page.goto("https://app.yarnia.quest/", { waitUntil: "load", timeout: 60000 });
// CanvasKit downloads + initializes on first paint; CI runners are slower than a dev laptop, so
// wait generously for the canvas to become interactive before the blind coordinate taps.
await page.waitForTimeout(Number(process.env.BOOT_WAIT_MS || 12000));
marks.onboardReady = el();
await shot("01-onboard");

// Onboarding: name -> age 5 -> Continue (await the real POST /child so timing is deterministic).
await page.mouse.click(195, 367);
await page.waitForTimeout(450);
await page.keyboard.type("Mira", { delay: 210 });
await page.waitForTimeout(1000);
await shot("02-name");
await page.mouse.click(252, 481); // age "5"
await page.waitForTimeout(1200);
await shot("03-age");

// The onboarding form is a long scrollable (name -> age -> favorite characters -> loves stories
// about -> ...); the Continue button is below the fold. Scroll to the bottom to reveal it. Flutter
// clamps overscroll, so a big wheel delta reliably lands at the end regardless of content height.
await page.mouse.move(195, 450);
await page.mouse.wheel(0, 4000);
await page.waitForTimeout(1500);
await shot("03b-scrolled");

const CONTINUE_X = Number(process.env.CONTINUE_X || 195);
const CONTINUE_Y = Number(process.env.CONTINUE_Y || 795);
const childResp = page.waitForResponse(
  (r) => r.url().includes("/child") && r.request().method() === "POST",
  { timeout: 30000 },
);
await page.mouse.click(CONTINUE_X, CONTINUE_Y); // Continue (at the bottom of the scrolled form)
await childResp.catch(async (e) => {
  await shot("04-continue-failed");
  throw e;
});
marks.childCreated = el();
await shot("04-child-created");

// Greeting screen ("Good night, Mira") -> Begin -> the voice agent connects and speaks.
await page.waitForTimeout(2800);
marks.greetingShown = el();
await shot("05-greeting");
await page.mouse.click(195, 566); // Begin
marks.beginClicked = el();
await page.waitForTimeout(2200);
marks.orbAppear = el();
await shot("06-orb");
await page.waitForTimeout(14000); // capture the orb while Yarnia speaks
marks.orbEnd = el();
await shot("07-orb-end");

await ctx.close(); // finalizes the webm
await browser.close();
writeFileSync(`${OUT}/marks.json`, JSON.stringify({ marks, greeting, childId }, null, 2));
console.log(JSON.stringify({ marks, greeting, childId }, null, 2));
