import { defineConfig } from "vitest/config";

// Integration tests: hit real APIs. Run with `npm run test:integration`.
// setup loads api/.env so QWEN_API_KEY / ELEVENLABS_API_KEY are available.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.integration.test.ts"],
    setupFiles: ["test/setup.integration.ts"],
    testTimeout: 30000,
  },
});
