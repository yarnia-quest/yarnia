import { describe, it, expect } from "vitest";
import app from "../src/index";

// Helper: POST JSON to a route, optionally with fake bindings (env).
function post(path: string, body: unknown, env?: Record<string, string>) {
  return app.request(
    path,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
    env,
  );
}

describe("GET /", () => {
  it("returns a health payload", async () => {
    const res = await app.request("/");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ service: "yarnia-api", ok: true });
  });
});

describe("POST /story (frozen contract)", () => {
  it("400s when childId is missing", async () => {
    const res = await post("/story", {});
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "childId required" });
  });

  it("echoes the contract shape for a valid request", async () => {
    const res = await post("/story", { childId: "lisa", choice: "dragon" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      childId: "lisa",
      choice: "dragon",
      text: null,
      audio: null,
      status: "not_implemented",
    });
  });

  it("defaults choice to null when omitted", async () => {
    const res = await post("/story", { childId: "lisa" });
    expect(await res.json()).toMatchObject({ childId: "lisa", choice: null });
  });
});
