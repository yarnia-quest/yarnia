import { useEffect, useRef, useState } from "preact/hooks";

const API_BASE = import.meta.env.PUBLIC_API_BASE_URL ?? "http://localhost:8787";

const CHOICES = [
  { id: "dragon", emoji: "🐉", label: "a dragon" },
  { id: "owl", emoji: "🦉", label: "an owl" },
  { id: "fox", emoji: "🦊", label: "a fox" },
  { id: "bear", emoji: "🐻", label: "a bear" },
];

const DEMO_CHILD = { id: "lisa-seed", name: "Lisa" };

type Screen = "greeting" | "cocreation" | "playback" | "loading";

interface StoryResult {
  text: string;
  audioBase64?: string;
  audioUrl?: string;
}

// Web Speech API has no standard TS types
interface SpeechRecognitionEvent {
  results: { [index: number]: { [index: number]: { transcript: string } } };
}
interface SpeechRecognitionInstance {
  lang: string;
  interimResults: boolean;
  onstart: () => void;
  onend: () => void;
  onresult: (e: SpeechRecognitionEvent) => void;
  start: () => void;
  stop: () => void;
}
interface SpeechRecognitionWindow {
  SpeechRecognition?: new () => SpeechRecognitionInstance;
  webkitSpeechRecognition?: new () => SpeechRecognitionInstance;
}

// ─── Stars ────────────────────────────────────────────────────────────────────

function Starfield() {
  const stars = Array.from({ length: 80 }, (_, i) => {
    const seed = i * 2654435761;
    return {
      x: ((seed >>> 0) % 1000) / 10,
      y: (((seed * 1234567) >>> 0) % 1000) / 10,
      r: (((seed * 987654) >>> 0) % 3) + 1,
      o: ((((seed * 123456) >>> 0) % 60) + 30) / 100,
    };
  });

  return (
    <svg
      style={{
        position: "fixed",
        inset: 0,
        width: "100%",
        height: "100%",
        pointerEvents: "none",
      }}
      aria-hidden="true"
      role="presentation"
    >
      {stars.map((s, i) => (
        <circle key={i} cx={`${s.x}%`} cy={`${s.y}%`} r={s.r} fill="white" opacity={s.o} />
      ))}
    </svg>
  );
}

// ─── Greeting ─────────────────────────────────────────────────────────────────

function GreetingScreen({ onBegin }: { onBegin: () => void }) {
  return (
    <div class="screen flex flex-col items-center justify-center text-center px-8 gap-8">
      <div style={{ fontSize: 72, lineHeight: 1 }}>🌙</div>

      <div>
        <h1
          class="font-display"
          style={{
            fontSize: "clamp(2rem, 8vw, 4rem)",
            color: "var(--color-cream)",
            fontWeight: 700,
          }}
        >
          Hello, {DEMO_CHILD.name}
        </h1>
        <p
          class="font-body"
          style={{
            color: "var(--color-cream)",
            opacity: 0.6,
            marginTop: "0.75rem",
            fontSize: "1.1rem",
          }}
        >
          Ready for tonight's story?
        </p>
      </div>

      <button type="button" class="btn-primary" onClick={onBegin}>
        Begin
      </button>
    </div>
  );
}

// ─── Co-creation ──────────────────────────────────────────────────────────────

function CoCreationScreen({ onChoice }: { onChoice: (choice: string) => void }) {
  const [listening, setListening] = useState(false);
  const [transcript, setTranscript] = useState("");
  const recogRef = useRef<SpeechRecognitionInstance | null>(null);

  function startListening() {
    const win = window as SpeechRecognitionWindow;
    const Ctor = win.SpeechRecognition ?? win.webkitSpeechRecognition;
    if (!Ctor) return;
    const rec = new Ctor();
    rec.lang = "en-US";
    rec.interimResults = true;
    rec.onstart = () => setListening(true);
    rec.onend = () => setListening(false);
    rec.onresult = (e: SpeechRecognitionEvent) => {
      const text = Array.from(
        { length: e.results.length },
        (_, i) => e.results[i][0].transcript,
      ).join(" ");
      setTranscript(text);
    };
    rec.start();
    recogRef.current = rec;
  }

  function stopListening() {
    recogRef.current?.stop();
  }

  function submitVoice() {
    const t = transcript.trim().toLowerCase();
    const match = CHOICES.find((c) => t.includes(c.id) || t.includes(c.label));
    onChoice(match?.id ?? (transcript || "dragon"));
  }

  return (
    <div class="screen flex flex-col items-center justify-center text-center px-8 gap-10">
      <div>
        <p
          class="font-body"
          style={{
            color: "var(--color-gold)",
            opacity: 0.8,
            letterSpacing: "0.1em",
            fontSize: "0.85rem",
            textTransform: "uppercase",
          }}
        >
          Tonight's story will have
        </p>
        <h2
          class="font-display"
          style={{
            fontSize: "clamp(1.5rem, 5vw, 2.5rem)",
            color: "var(--color-cream)",
            marginTop: "0.5rem",
          }}
        >
          Who should {DEMO_CHILD.name} meet?
        </h2>
      </div>

      {/* Chips */}
      <div style={{ display: "flex", flexWrap: "wrap", gap: "0.75rem", justifyContent: "center" }}>
        {CHOICES.map((c) => (
          <button type="button" key={c.id} class="chip" onClick={() => onChoice(c.id)}>
            {c.emoji} {c.label}
          </button>
        ))}
      </div>

      {/* Mic */}
      <div
        style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "0.5rem" }}
      >
        <button
          type="button"
          class={listening ? "mic-btn mic-btn--active" : "mic-btn"}
          onClick={listening ? stopListening : startListening}
          aria-label={listening ? "Stop listening" : "Speak your choice"}
        >
          🎙
        </button>
        {transcript && (
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              gap: "0.5rem",
            }}
          >
            <p
              class="font-body"
              style={{ color: "var(--color-cream)", opacity: 0.7, fontSize: "0.95rem" }}
            >
              "{transcript}"
            </p>
            <button
              type="button"
              class="btn-primary"
              style={{ fontSize: "0.9rem", padding: "0.5rem 1.5rem" }}
              onClick={submitVoice}
            >
              Use this
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Loading ──────────────────────────────────────────────────────────────────

function LoadingScreen() {
  const [dots, setDots] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setDots((d) => (d + 1) % 4), 500);
    return () => clearInterval(id);
  }, []);

  return (
    <div class="screen flex flex-col items-center justify-center gap-6 text-center px-8">
      <div style={{ fontSize: 56 }}>✨</div>
      <p class="font-display" style={{ fontSize: "1.5rem", color: "var(--color-cream)" }}>
        Weaving the story{".".repeat(dots)}
      </p>
      <p
        class="font-body"
        style={{ color: "var(--color-cream)", opacity: 0.5, fontSize: "0.9rem" }}
      >
        This takes about 10 seconds
      </p>
    </div>
  );
}

// ─── Playback ─────────────────────────────────────────────────────────────────

function PlaybackScreen({ story, onRestart }: { story: StoryResult; onRestart: () => void }) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [shared, setShared] = useState(false);

  useEffect(() => {
    const src = story.audioBase64
      ? `data:audio/mpeg;base64,${story.audioBase64}`
      : (story.audioUrl ?? null);
    if (src) {
      const a = new Audio(src);
      audioRef.current = a;
      a.play().catch(() => {});
    }
    return () => {
      audioRef.current?.pause();
    };
  }, []);

  async function share() {
    try {
      await navigator.share?.({
        title: "Yarnia",
        text: `Yarnia told ${DEMO_CHILD.name} a bedtime story tonight. 🌙`,
      });
      setShared(true);
    } catch (_) {}
  }

  return (
    <div class="screen flex flex-col items-center px-8 pt-16 pb-20 gap-8">
      <div style={{ fontSize: 36, opacity: 0.7 }}>🌙</div>

      <div
        style={{
          flex: 1,
          width: "100%",
          maxWidth: 560,
          overflowY: "auto",
          WebkitOverflowScrolling: "touch",
        }}
      >
        <p
          class="font-body"
          style={{
            color: "var(--color-cream)",
            fontSize: "1.1rem",
            lineHeight: 1.75,
            textAlign: "center",
            opacity: 0.9,
            fontStyle: "italic",
          }}
        >
          {story.text ?? "Once upon a time, in a land between the last yawn and the first dream…"}
        </p>
      </div>

      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "1rem" }}>
        <button type="button" class="btn-outline" onClick={share}>
          {shared ? "Sent ✓" : "Send to grandma"}
        </button>
        <button
          type="button"
          class="font-body"
          style={{
            background: "none",
            border: "none",
            color: "var(--color-cream)",
            opacity: 0.4,
            fontSize: "0.85rem",
            cursor: "pointer",
          }}
          onClick={onRestart}
        >
          Another night →
        </button>
      </div>
    </div>
  );
}

// ─── Root ──────────────────────────────────────────────────────────────────────

export default function YarniaApp() {
  const [screen, setScreen] = useState<Screen>("greeting");
  const [story, setStory] = useState<StoryResult | null>(null);

  async function handleChoice(choice: string) {
    setScreen("loading");
    try {
      const res = await fetch(`${API_BASE}/story`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ childId: DEMO_CHILD.id, choice }),
      });
      if (!res.ok) throw new Error(`API ${res.status}`);
      const data = await res.json();
      setStory(data);
      setScreen("playback");
    } catch (err) {
      console.warn("Story fetch failed:", err);
      setStory({ text: "Once upon a time, in a land between the last yawn and the first dream…" });
      setScreen("playback");
    }
  }

  function restart() {
    setStory(null);
    setScreen("greeting");
  }

  return (
    <div style={{ position: "relative", minHeight: "100dvh" }}>
      <Starfield />
      <div style={{ position: "relative", zIndex: 1, minHeight: "100dvh" }}>
        {screen === "greeting" && <GreetingScreen onBegin={() => setScreen("cocreation")} />}
        {screen === "cocreation" && <CoCreationScreen onChoice={handleChoice} />}
        {screen === "loading" && <LoadingScreen />}
        {screen === "playback" && story && <PlaybackScreen story={story} onRestart={restart} />}
      </div>
    </div>
  );
}
