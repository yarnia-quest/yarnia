import { describe, it, expect } from "vitest";
import { generateChildToken, hashToken, verifyChildToken } from "../src/auth";

describe("per-child auth tokens", () => {
  it("generates a 64-char hex token", () => {
    const t = generateChildToken();
    expect(t).toMatch(/^[0-9a-f]{64}$/);
    expect(generateChildToken()).not.toBe(t); // random
  });

  it("hashes deterministically to SHA-256 hex", async () => {
    const h = await hashToken("abc");
    expect(h).toMatch(/^[0-9a-f]{64}$/);
    expect(await hashToken("abc")).toBe(h);
    expect(await hashToken("abd")).not.toBe(h);
  });

  it("accepts a token whose hash matches the stored hash", async () => {
    const t = generateChildToken();
    const h = await hashToken(t);
    expect(await verifyChildToken(h, t)).toBe(true);
  });

  it("rejects a wrong or missing token when a hash is stored", async () => {
    const h = await hashToken(generateChildToken());
    expect(await verifyChildToken(h, "wrong")).toBe(false);
    expect(await verifyChildToken(h, undefined)).toBe(false);
  });

  it("allows legacy children that have no stored hash", async () => {
    expect(await verifyChildToken(null, undefined)).toBe(true);
    expect(await verifyChildToken(undefined, "anything")).toBe(true);
  });
});
