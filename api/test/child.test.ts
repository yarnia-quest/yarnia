import { describe, it, expect, vi } from "vitest";
import { loadChild } from "../src/child";

const lisaRow = {
  id: "lisa-1",
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon", "owl"],
  themes: ["friendship"],
  fearsToAvoid: ["thunder"],
  sessions: [
    { summary: "newer one", charactersUsed: ["owl"], createdAt: 200 },
    { summary: "older one", charactersUsed: ["dragon"], createdAt: 100 },
  ],
};

const fakeQuery = (result: unknown) => vi.fn(async () => result);

describe("loadChild", () => {
  it("queries the child by id and includes their sessions", async () => {
    const q = fakeQuery({ children: [lisaRow] });
    await loadChild("lisa-1", q);
    expect(q).toHaveBeenCalledOnce();
    expect(q.mock.calls[0][0]).toEqual({
      children: { $: { where: { id: "lisa-1" } }, sessions: {} },
    });
  });

  it("maps the row into the Child shape buildStoryPrompt consumes", async () => {
    const child = await loadChild("lisa-1", fakeQuery({ children: [lisaRow] }));
    expect(child).toMatchObject({
      name: "Lisa",
      age: 4,
      favoriteCharacters: ["dragon", "owl"],
      themes: ["friendship"],
      fearsToAvoid: ["thunder"],
    });
  });

  it("orders pastSessions oldest->newest so the last is the most recent", async () => {
    const child = await loadChild("lisa-1", fakeQuery({ children: [lisaRow] }));
    expect(child?.pastSessions.map((s) => s.summary)).toEqual(["older one", "newer one"]);
  });

  it("returns null when the child is not found", async () => {
    expect(await loadChild("nope", fakeQuery({ children: [] }))).toBeNull();
  });

  it("carries each session's continuityNotes into the recall layer", async () => {
    const row = {
      id: "lisa-1",
      name: "Lisa",
      age: 4,
      sessions: [
        {
          summary: "a dragon shared his stones",
          charactersUsed: ["dragon"],
          continuityNotes: ["the dragon shared his sparkly stones", "they became friends"],
          createdAt: 100,
        },
      ],
    };
    const child = await loadChild("lisa-1", fakeQuery({ children: [row] }));
    expect(child?.pastSessions[0].continuityNotes).toEqual([
      "the dragon shared his sparkly stones",
      "they became friends",
    ]);
  });

  it("defaults a session's missing continuityNotes to an empty array", async () => {
    const child = await loadChild("lisa-1", fakeQuery({ children: [lisaRow] }));
    expect(child?.pastSessions[0].continuityNotes).toEqual([]);
  });

  it("defaults missing array fields to empty arrays", async () => {
    const child = await loadChild("x", fakeQuery({ children: [{ id: "x", name: "Max", age: 6 }] }));
    expect(child).toMatchObject({
      favoriteCharacters: [],
      themes: [],
      fearsToAvoid: [],
      pastSessions: [],
    });
  });
});
