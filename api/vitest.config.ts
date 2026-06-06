import { defineConfig } from "vitest/config";

// Tests run the Hono app in-process via app.request() — no workers runtime needed.
// Fake bindings are injected per-request (3rd arg), so OpenAI/ElevenLabs are mocked.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    // Integration tests (real APIs) run separately via vitest.integration.config.ts.
    exclude: ["test/**/*.integration.test.ts", "node_modules/**"],
  },
});
