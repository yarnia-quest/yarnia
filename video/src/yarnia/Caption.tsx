import { interpolate, useCurrentFrame } from "remotion";
import { cream, gold } from "./theme";

// A soft, bedtime-appropriate caption. Fades in/out within its own Sequence. Yarnia's words
// read in calm cream; the child's lines are smaller, warm gold, and italic — a "little voice".
export const Caption: React.FC<{
  text: string;
  speaker: "yarnia" | "kid";
  durationInFrames: number;
}> = ({ text, speaker, durationInFrames }) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(
    frame,
    [0, 8, Math.max(9, durationInFrames - 10), durationInFrames],
    [0, 1, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const isKid = speaker === "kid";

  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: 220,
        padding: "0 120px",
        textAlign: "center",
        opacity,
      }}
    >
      <div
        style={{
          fontFamily: "Georgia, 'Times New Roman', serif",
          color: isKid ? gold : cream,
          fontSize: isKid ? 38 : 46,
          fontStyle: isKid ? "italic" : "normal",
          fontWeight: isKid ? 400 : 500,
          lineHeight: 1.4,
          letterSpacing: 0.3,
          textShadow: "0 2px 24px rgba(0,0,0,0.6)",
        }}
      >
        {text}
      </div>
    </div>
  );
};
