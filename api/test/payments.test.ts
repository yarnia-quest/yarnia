import { describe, it, expect, vi } from "vitest";
import { createCheckout } from "../src/payments";

function okFetch(href = "https://www.mollie.com/checkout/abc") {
  return vi.fn(async () => new Response(JSON.stringify({ id: "tr_123", _links: { checkout: { href } } }), { status: 201 }));
}

describe("createCheckout (Mollie)", () => {
  it("posts an EUR 8.00 payment with a Bearer key and returns the checkout url", async () => {
    const f = okFetch();
    const out = await createCheckout({ apiKey: "test_key", redirectUrl: "https://app.yarnia.quest/welcome", fetch: f });
    expect(out.checkoutUrl).toBe("https://www.mollie.com/checkout/abc");
    expect(out.paymentId).toBe("tr_123");
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("api.mollie.com/v2/payments");
    expect((init.headers as Record<string, string>).authorization).toBe("Bearer test_key");
    const body = JSON.parse(init.body as string);
    expect(body.amount).toEqual({ currency: "EUR", value: "8.00" });
    expect(body.redirectUrl).toBe("https://app.yarnia.quest/welcome");
  });

  it("throws when Mollie returns an error", async () => {
    const f = vi.fn(async () => new Response("nope", { status: 401 }));
    await expect(createCheckout({ apiKey: "bad", redirectUrl: "https://x", fetch: f })).rejects.toThrow(/Mollie payment failed: 401/);
  });
});
