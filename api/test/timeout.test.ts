import { describe, it, expect } from "vitest";
import { withTimeout, TimeoutError } from "../src/timeout";

describe("withTimeout", () => {
  it("resolves when work finishes in time", async () => {
    expect(await withTimeout(async () => 42, 1000)).toBe(42);
  });

  it("rejects with TimeoutError when work exceeds the deadline", async () => {
    const never = () => new Promise<number>(() => {});
    await expect(withTimeout(never, 10)).rejects.toBeInstanceOf(TimeoutError);
  });

  it("propagates the work's own rejection", async () => {
    await expect(withTimeout(async () => { throw new Error("boom"); }, 1000)).rejects.toThrow(/boom/);
  });

  it("disables the timeout when ms <= 0", async () => {
    expect(await withTimeout(async () => "ok", 0)).toBe("ok");
  });
});
