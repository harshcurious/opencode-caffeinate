import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from "fs";
import { basename, dirname } from "path";

type SpawnedProcess = {
  pid?: number;
  kill: () => void;
  exited?: Promise<number>;
};

type SpawnFunction = (command: string[]) => SpawnedProcess;

type InhibitorManagerOptions = {
  pidFile?: string;
  platform?: NodeJS.Platform;
  spawn?: SpawnFunction;
  command?: string[];
};

const DEFAULT_PID_FILE = "/tmp/opencode-caffeinate/inhibitor.pid";
const INHIBITOR_REASON = "Prevent sleep while OpenCode sessions are active";

export function getInhibitorCommand(platform: NodeJS.Platform): string[] | null {
  switch (platform) {
    case "darwin":
      return ["caffeinate", "-dim"];
    case "linux":
      return [
        "systemd-inhibit",
        "--what=idle:sleep",
        "--who=OpenCode",
        `--why=${INHIBITOR_REASON}`,
        "--mode=block",
        "sleep",
        "infinity",
      ];
    default:
      return null;
  }
}

export class InhibitorManager {
  private pidFile: string;
  private process: SpawnedProcess | null = null;
  private platform: NodeJS.Platform;
  private spawn: SpawnFunction;
  private command: string[] | null;

  constructor({
    pidFile = DEFAULT_PID_FILE,
    platform = process.platform,
    spawn = (command) => Bun.spawn(command, { stdout: "ignore", stderr: "ignore" }),
    command,
  }: InhibitorManagerOptions = {}) {
    this.pidFile = pidFile;
    this.platform = platform;
    this.spawn = spawn;
    this.command = command ?? getInhibitorCommand(platform);
  }

  async start(): Promise<void> {
    if (this.isRunning()) {
      return;
    }

    const command = this.command;
    if (!command) {
      throw new Error(`No sleep inhibitor backend is available for platform: ${this.platform}`);
    }

    try {
      this.ensurePidDirectoryExists();
      this.process = this.spawn(command);
      writeFileSync(this.pidFile, String(this.process.pid), { flag: "w" });
      await this.verifyProcessStartup();
    } catch (error) {
      this.cleanupPidFile();
      this.process = null;
      throw new Error(`Failed to start sleep inhibitor: ${error}`);
    }
  }

  async stop(): Promise<void> {
    const pid = this.getPid();
    if (pid && this.isExpectedProcess(pid)) {
      try {
        process.kill(pid, "SIGTERM");
      } catch (error: any) {
        if (error.code !== "ESRCH") {
          throw error;
        }
      }
    }

    if (this.process) {
      try {
        this.process.kill();
      } catch {}
      this.process = null;
    }

    this.cleanupPidFile();
  }

  isRunning(): boolean {
    const pid = this.getPid();
    if (!pid) {
      return false;
    }

    return this.isProcessAlive(pid) && this.isExpectedProcess(pid);
  }

  getPid(): number | null {
    if (this.process?.pid) {
      return this.process.pid;
    }

    if (!existsSync(this.pidFile)) {
      return null;
    }

    try {
      const pidStr = readFileSync(this.pidFile, "utf-8").trim();
      const pid = parseInt(pidStr, 10);
      if (isNaN(pid)) {
        return null;
      }
      return pid;
    } catch {
      return null;
    }
  }

  private isProcessAlive(pid: number): boolean {
    try {
      process.kill(pid, 0);
      return true;
    } catch (error: any) {
      if (error.code === "ESRCH") {
        return false;
      }
      if (error.code === "EPERM") {
        return true;
      }
      return false;
    }
  }

  private isExpectedProcess(pid: number): boolean {
    const command = this.command;
    const executable = command?.[0];
    if (!executable || !command) {
      return false;
    }

    try {
      const result = Bun.spawnSync(["ps", "-o", "command=", "-p", String(pid)], {
        stdout: "pipe",
        stderr: "ignore",
      });

      if (result.exitCode !== 0) {
        return false;
      }

      const runningCommand = this.normalizeCommand(result.stdout.toString());
      if (!runningCommand) {
        return false;
      }

      const expectedCommand = this.normalizeCommand(command.join(" "));
      return basename(runningCommand.split(" ")[0] ?? "") === basename(executable)
        && runningCommand.includes(expectedCommand);
    } catch {
      return false;
    }
  }

  private normalizeCommand(command: string): string {
    return command.replace(/\s+/g, " ").trim();
  }

  private ensurePidDirectoryExists(): void {
    mkdirSync(dirname(this.pidFile), { recursive: true });
  }

  private cleanupPidFile(): void {
    if (existsSync(this.pidFile)) {
      unlinkSync(this.pidFile);
    }
  }

  private async verifyProcessStartup(): Promise<void> {
    if (!this.process?.exited) {
      return;
    }

    const exitCode = await Promise.race<number | null>([
      this.process.exited,
      Bun.sleep(50).then(() => null),
    ]);

    if (exitCode !== null) {
      throw new Error("inhibitor process exited immediately");
    }
  }
}
