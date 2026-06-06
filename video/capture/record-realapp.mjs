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
// Setup:  npm i playwright   (uses the system Google Chrome; no browser download needed)
// Run:    node capture/record-realapp.mjs
// Output: /tmp/ywcap/videos/*.webm  +  /tmp/ywcap/marks.json (timings + greeting text)
import { chromium } from "playwright";
import { writeFileSync, mkdirSync } from "node:fs";

const OUT = "/tmp/ywcap";
mkdirSync(`${OUT}/videos`, { recursive: true });
const t0 = Date.now();
const el = () => ((Date.now() - t0) / 1000).toFixed(2);

const browser = await chromium.launch({
  channel: "chrome",
  headless: true,
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

const marks = {};
await page.goto("https://app.yarnia.quest/", { waitUntil: "load", timeout: 60000 });
await page.waitForTimeout(6500); // Flutter boot
marks.onboardReady = el();

// Onboarding: name -> age 5 -> Continue (await the real POST /child so timing is deterministic).
await page.mouse.click(195, 367);
await page.waitForTimeout(450);
await page.keyboard.type("Mira", { delay: 210 });
await page.waitForTimeout(1000);
await page.mouse.click(252, 481); // age "5"
await page.waitForTimeout(1200);
const childResp = page.waitForResponse(
  (r) => r.url().includes("/child") && r.request().method() === "POST",
  { timeout: 30000 },
);
await page.mouse.click(195, 634); // Continue
await childResp;
marks.childCreated = el();

// Greeting screen ("Good night, Mira") -> Begin -> the voice agent connects and speaks.
await page.waitForTimeout(2800);
marks.greetingShown = el();
await page.mouse.click(195, 566); // Begin
marks.beginClicked = el();
await page.waitForTimeout(2200);
marks.orbAppear = el();
await page.waitForTimeout(14000); // capture the orb while Yarnia speaks
marks.orbEnd = el();

await ctx.close(); // finalizes the webm
await browser.close();
writeFileSync(`${OUT}/marks.json`, JSON.stringify({ marks, greeting, childId }, null, 2));
console.log(JSON.stringify({ marks, greeting, childId }, null, 2));
