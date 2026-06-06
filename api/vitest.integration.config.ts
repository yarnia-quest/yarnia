import { defineConfig } from "vitest/config";

// Integration tests: hit real APIs. Run with `npm run test:integration`.
// setup loads api/.env so QWEN_API_KEY / ELEVENLABS_API_KEY are available.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.integration.test.ts"],
    setupFiles: ["test/setup.integration.ts"],
    // The intl endpoints (Qwen on dashscope-intl, ElevenLabs) are slow to reach from the EU:
    // TLS handshake alone can be ~8s, and POST /story chains loadChild -> Qwen -> TTS. 30s was
    // too tight for that chain, so give it real headroom.
    testTimeout: 90000,
    // These call the real internet; transient ECONNRESET on the long-haul link is expected.
    // Retry so a flaky socket doesn't fail an otherwise-green run.
    retry: 2,
  },
});
