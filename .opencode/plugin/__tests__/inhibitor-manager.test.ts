import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { InhibitorManager, getInhibitorCommand } from "../inhibitor-manager";

const TEST_PID_FILE = "/tmp/opencode-caffeinate-test.pid";

describe("getInhibitorCommand", () => {
  test("returns caffeinate command on macOS", () => {
    expect(getInhibitorCommand("darwin")).toEqual(["caffeinate", "-dim"]);
  });

  test("returns systemd-inhibit command on Linux", () => {
    expect(getInhibitorCommand("linux")).toEqual([
      "systemd-inhibit",
      "--what=idle:sleep",
      "--who=OpenCode",
      "--why=Prevent sleep while OpenCode sessions are active",
      "--mode=block",
      "sleep",
      "infinity",
    ]);
  });

  test("returns null on unsupported platforms", () => {
    expect(getInhibitorCommand("win32")).toBeNull();
  });
});

describe("InhibitorManager", () => {
  let inhibitorManager: InhibitorManager;

  beforeEach(() => {
    if (existsSync(TEST_PID_FILE)) {
      rmSync(TEST_PID_FILE, { force: true });
    }

    inhibitorManager = new InhibitorManager({
      pidFile: TEST_PID_FILE,
      platform: process.platform,
    });
  });

  afterEach(async () => {
    await inhibitorManager.stop();
    if (existsSync(TEST_PID_FILE)) {
      rmSync(TEST_PID_FILE, { force: true });
    }
  });

  test("start creates a PID file when the platform is supported", async () => {
    await inhibitorManager.start();

    expect(existsSync(TEST_PID_FILE)).toBe(true);
    expect(inhibitorManager.isRunning()).toBe(true);
  });

  test("start does nothing if already running", async () => {
    await inhibitorManager.start();
    const firstPid = inhibitorManager.getPid();

    await inhibitorManager.start();
    const secondPid = inhibitorManager.getPid();

    expect(firstPid).toBe(secondPid);
  });

  test("stop kills process and removes PID file", async () => {
    await inhibitorManager.start();
    expect(inhibitorManager.isRunning()).toBe(true);

    await inhibitorManager.stop();

    expect(inhibitorManager.isRunning()).toBe(false);
    expect(existsSync(TEST_PID_FILE)).toBe(false);
  });

  test("isRunning returns false for unsupported platforms", () => {
    const unsupportedManager = new InhibitorManager({
      pidFile: TEST_PID_FILE,
      platform: "win32",
    });

    expect(unsupportedManager.isRunning()).toBe(false);
  });

  test("start throws on unsupported platforms", async () => {
    const unsupportedManager = new InhibitorManager({
      pidFile: TEST_PID_FILE,
      platform: "win32",
    });

    await expect(unsupportedManager.start()).rejects.toThrow(
      "No sleep inhibitor backend is available for platform: win32",
    );
  });

  test("start creates the PID file directory when missing", async () => {
    const nestedPidFile = join(TEST_PID_FILE, "nested", "inhibitor.pid");
    const managerWithNestedPath = new InhibitorManager({
      pidFile: nestedPidFile,
      platform: "linux",
      command: ["sleep", "infinity"],
    });

    await managerWithNestedPath.start();

    expect(existsSync(nestedPidFile)).toBe(true);

    await managerWithNestedPath.stop();
    rmSync(TEST_PID_FILE, { recursive: true, force: true });
  });

  test("start rejects when the inhibitor process exits immediately", async () => {
    const failingManager = new InhibitorManager({
      pidFile: TEST_PID_FILE,
      platform: "linux",
      command: ["sh", "-c", "exit 1"],
    });

    await expect(failingManager.start()).rejects.toThrow(
      "Failed to start sleep inhibitor: Error: inhibitor process exited immediately",
    );

    expect(existsSync(TEST_PID_FILE)).toBe(false);
  });

  test("handles orphaned PID file (process died)", () => {
    writeFileSync(TEST_PID_FILE, "999999");

    expect(inhibitorManager.isRunning()).toBe(false);
  });

  test("isRunning rejects live processes that are not the expected inhibitor", () => {
    writeFileSync(TEST_PID_FILE, String(process.pid));

    expect(inhibitorManager.isRunning()).toBe(false);
  });

  test("isRunning rejects matching executables with different command lines", () => {
    const commandSensitiveManager = new InhibitorManager({
      pidFile: TEST_PID_FILE,
      platform: process.platform,
      command: ["bun", "--definitely-not-the-current-command"],
    });

    writeFileSync(TEST_PID_FILE, String(process.pid));

    expect(commandSensitiveManager.isRunning()).toBe(false);
  });

  test("handles corrupted PID file gracefully", () => {
    writeFileSync(TEST_PID_FILE, "not-a-number");

    expect(inhibitorManager.isRunning()).toBe(false);
  });
});
