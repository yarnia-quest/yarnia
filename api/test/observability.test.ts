import { describe, it, expect, vi } from "vitest";
import { createTelemetry } from "../src/observability";

describe("createTelemetry", () => {
  it("forwards errors to the error webhook when configured", async () => {
    const calls: Promise<unknown>[] = [];
    const f = vi.fn(async () => new Response("{}", { status: 200 }));
    const t = createTelemetry({ errorWebhook: "https://logs.example/err", fetch: f, defer: (p) => calls.push(p) });
    t.error("story_failed", { childId: "c1" });
    await Promise.all(calls);
    expect(f).toHaveBeenCalledOnce();
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://logs.example/err");
    const body = JSON.parse(init.body as string);
    expect(body.event).toBe("story_failed");
    expect(body.level).toBe("error");
    expect(body.childId).toBe("c1");
  });

  it("forwards analytics to the analytics webhook", async () => {
    const calls: Promise<unknown>[] = [];
    const f = vi.fn(async () => new Response("{}", { status: 200 }));
    const t = createTelemetry({ analyticsWebhook: "https://a.example/ev", fetch: f, defer: (p) => calls.push(p) });
    t.track("story_created", { childId: "c1" });
    await Promise.all(calls);
    expect(f).toHaveBeenCalledOnce();
    expect(JSON.parse((f.mock.calls[0][1] as RequestInit).body as string).event).toBe("story_created");
  });

  it("is a no-op (no fetch) when no webhooks are configured", () => {
    const f = vi.fn(async () => new Response("{}"));
    const t = createTelemetry({ fetch: f });
    t.error("x");
    t.track("y");
    expect(f).not.toHaveBeenCalled();
  });
});
