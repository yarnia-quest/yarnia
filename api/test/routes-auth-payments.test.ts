import { describe, it, expect, vi } from "vitest";
import { createApp } from "../src/index";
import { hashToken } from "../src/auth";

const lisa = {
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon"],
  themes: [],
  fearsToAvoid: [],
  pastSessions: [],
};

function appWith(overrides: Record<string, unknown> = {}) {
  return createApp(() => ({
    loadChild: async () => lisa,
    generate: async () => "A cozy story about a fox.",
    synthesize: async () => "AUDIO",
    agentId: "agent_test",
    getSignedUrl: async () => "wss://signed",
    saveSession: async () => "session-id",
    updateSessionAudio: async () => {},
    storeAudio: async (k: string) => k,
    getAudioUrl: async () => "https://fake",
    createChild: async () => "child-id",
    ...overrides,
  }) as never);
}

function post(app: ReturnType<typeof createApp>, path: string, body: unknown, headers: Record<string, string> = {}) {
  return app.request(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

describe("per-child token enforcement", () => {
  it("rejects /story for a token-protected child with no or wrong token", async () => {
    const tokenHash = await hashToken("the-real-token");
    const app = appWith({ loadChildAuth: async () => ({ tokenHash }) });
    expect((await post(app, "/story", { childId: "lisa-1", choice: "a fox" })).status).toBe(401);
    expect((await post(app, "/story", { childId: "lisa-1", choice: "a fox" }, { "x-child-token": "nope" })).status).toBe(401);
  });

  it("allows /story with the correct child token", async () => {
    const tokenHash = await hashToken("the-real-token");
    const app = appWith({ loadChildAuth: async () => ({ tokenHash }) });
    const res = await post(app, "/story", { childId: "lisa-1", choice: "a fox" }, { "x-child-token": "the-real-token" });
    expect(res.status).toBe(200);
  });

  it("allows legacy children (no stored hash) without a token", async () => {
    const app = appWith({ loadChildAuth: async () => ({ tokenHash: null }) });
    expect((await post(app, "/story", { childId: "lisa-1", choice: "a fox" })).status).toBe(200);
  });

  it("gates GET /child/:id/sessions and GET /agent/session too", async () => {
    const tokenHash = await hashToken("t");
    const app = appWith({ loadChildAuth: async () => ({ tokenHash }) });
    expect((await app.request("/child/lisa-1/sessions")).status).toBe(401);
    expect((await app.request("/agent/session?childId=lisa-1")).status).toBe(401);
    // Anonymous agent session (no childId) stays open.
    expect((await app.request("/agent/session")).status).toBe(200);
  });
});

function childWith(n: number, subscribed = false) {
  return { ...lisa, subscribed, pastSessions: Array.from({ length: n }, () => ({ summary: "s", charactersUsed: [] })) };
}

describe("free-tier quota + subscription gating", () => {
  it("402s once the free story limit is reached for a non-subscriber", async () => {
    const app = appWith({ loadChild: async () => childWith(5, false) });
    const res = await post(app, "/story", { childId: "lisa-1", choice: "a fox" });
    expect(res.status).toBe(402);
    expect((await res.json() as { error: string }).error).toBe("subscription_required");
  });

  it("allows unlimited stories for a subscriber", async () => {
    const app = appWith({ loadChild: async () => childWith(50, true) });
    expect((await post(app, "/story", { childId: "lisa-1", choice: "a fox" })).status).toBe(200);
  });
});

describe("GET /healthz", () => {
  it("reports dependency checks and is 503 when core deps are missing", async () => {
    const res = await appWith().request("/healthz");
    const json = (await res.json()) as { ok: boolean; checks: Record<string, boolean> };
    expect(json.checks).toHaveProperty("instant");
    expect(json.checks).toHaveProperty("payments");
    // No env wired in this test -> not ready.
    expect(res.status).toBe(503);
    expect(json.ok).toBe(false);
  });
});

describe("POST /payments/webhook", () => {
  it("marks the child subscribed when Mollie confirms a paid payment", async () => {
    const marked: string[] = [];
    const app = appWith({
      paymentStatus: async () => ({ status: "paid", metadata: { childId: "child-9" } }),
      markSubscribed: async (id: string) => { marked.push(id); },
    });
    const res = await app.request("/payments/webhook", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "id=tr_123",
    });
    expect(res.status).toBe(200);
    expect(marked).toEqual(["child-9"]);
  });

  it("does not subscribe when the payment is not paid", async () => {
    const marked: string[] = [];
    const app = appWith({
      paymentStatus: async () => ({ status: "open", metadata: { childId: "child-9" } }),
      markSubscribed: async (id: string) => { marked.push(id); },
    });
    const res = await app.request("/payments/webhook", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "id=tr_123",
    });
    expect(res.status).toBe(200);
    expect(marked).toEqual([]);
  });
});

describe("POST /checkout", () => {
  it("returns a live Mollie checkout url when configured", async () => {
    const checkout = vi.fn(async () => ({ checkoutUrl: "https://mollie/checkout/x", paymentId: "tr_1" }));
    const res = await post(appWith({ checkout }), "/checkout", {});
    expect(res.status).toBe(200);
    const json = (await res.json()) as { checkoutUrl: string; mode: string };
    expect(json.checkoutUrl).toBe("https://mollie/checkout/x");
    expect(json.mode).toBe("live");
  });

  it("falls back to a static payment link when no live key", async () => {
    const res = await post(appWith({ paymentLink: "https://pay.example/sub" }), "/checkout", {});
    const json = (await res.json()) as { checkoutUrl: string; mode: string };
    expect(json.checkoutUrl).toBe("https://pay.example/sub");
    expect(json.mode).toBe("static");
  });

  it("503s when payments are not configured", async () => {
    expect((await post(appWith(), "/checkout", {})).status).toBe(503);
  });
});
