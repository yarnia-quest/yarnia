#!/usr/bin/env bash
# Test POST /story and save the narration MP3.
# Usage: ./scripts/story.sh [childId] [choice] [outfile]
#   ./scripts/story.sh
#   ./scripts/story.sh 11111111-1111-4111-8111-111111111111 dragon story.mp3
set -euo pipefail

# Default to this worktree's dev port (api/.dev.port, written by worktree-add.sh),
# so `npm run story` hits the right server. Override with API_BASE_URL.
API_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="$(cat "$API_DIR/.dev.port" 2>/dev/null || echo 8787)"
BASE="${API_BASE_URL:-http://localhost:$PORT}"
CHILD="${1:-11111111-1111-4111-8111-111111111111}"
CHOICE="${2:-dragon}"
OUT="${3:-story.mp3}"

echo "POST $BASE/story  (childId=$CHILD, choice=$CHOICE)" >&2

# One request; capture the JSON body once. -f makes curl fail on HTTP errors;
# a connection failure (server not running) is caught explicitly below.
if ! RESP="$(curl -s --max-time 120 -X POST "$BASE/story" \
  -H 'content-type: application/json' \
  -d "{\"childId\":\"$CHILD\",\"choice\":\"$CHOICE\"}")" || [ -z "$RESP" ]; then
  echo "error: no response from $BASE — is the dev server running? (cd api && npm run dev)" >&2
  exit 1
fi

# Print the story text. (node is already a dep here; no jq required.)
node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (r.error) { console.error("API error:", r.error); process.exit(1); }
  console.error("\n--- story ---\n" + r.text + "\n");
  if (!r.audio) { console.error("audio: null (TTS unavailable)"); process.exit(2); }
  // Strip the "data:audio/mpeg;base64," prefix, then write raw bytes.
  const b64 = r.audio.replace(/^data:audio\/mpeg;base64,/, "");
  process.stdout.write(Buffer.from(b64, "base64"));
' <<<"$RESP" > "$OUT"

echo "saved $(wc -c <"$OUT" | tr -d " ") bytes -> $OUT" >&2
