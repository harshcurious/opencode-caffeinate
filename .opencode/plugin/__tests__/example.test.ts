import { describe, test, expect } from "bun:test";
import { getInhibitorCommand } from "../inhibitor-manager";

describe("Test Infrastructure", () => {
  test("example test passes", () => {
    expect(1 + 1).toBe(2);
  });
  
  test("bun test is working", () => {
    expect(true).toBe(true);
  });

  test("linux is now a supported platform", () => {
    expect(getInhibitorCommand("linux")).not.toBeNull();
  });
});
