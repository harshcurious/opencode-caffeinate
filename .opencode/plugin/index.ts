import type { Plugin } from "@opencode-ai/plugin";
import { SessionManager } from "./session-manager";
import { InhibitorManager, getInhibitorCommand } from "./inhibitor-manager";

export const CaffeinatePlugin: Plugin = async ({
  project,
  client,
  $,
  directory,
  worktree,
}) => {
  const SERVICE_NAME = "opencode-caffeinate";

  const logFn = (message: string, level: "info" | "warn" | "debug" | "error" = "info") => {
    client.app.log({
      body: {
        service: SERVICE_NAME,
        level,
        message,
      },
    }).catch(() => {});
  };

  if (!getInhibitorCommand(process.platform)) {
    logFn("Plugin disabled: only available on macOS and Linux", "warn");
    return {};
  }

  const sessionManager = new SessionManager();
  const inhibitorManager = new InhibitorManager();

  // Fire-and-forget log to avoid blocking initialization
  logFn("Plugin initialized", "info");

  return {
    event: async ({ event }: { event: { type: string } }) => {
      switch (event.type) {
        case "session.created":
          sessionManager.registerSession(process.pid);
          
          if (inhibitorManager.isRunning()) {
            const pid = inhibitorManager.getPid();
            logFn(`Session started. sleep inhibitor already running (PID: ${pid})`, "debug");
            return;
          }
          
          try {
            await inhibitorManager.start();
            const pid = inhibitorManager.getPid();
            logFn(`Sleep inhibitor started (PID: ${pid})`, "info");
          } catch (error) {
            logFn(`Failed to start sleep inhibitor: ${error}`, "error");
          }
          break;

        case "session.idle":
        case "session.deleted":
          sessionManager.unregisterSession(process.pid);
          
          if (sessionManager.hasActiveSessions()) {
            const activeCount = sessionManager.getActiveSessions().length;
            logFn(`Session ended. ${activeCount} active sessions remaining`, "debug");
            return;
          }
          
          if (inhibitorManager.isRunning()) {
            try {
              const pid = inhibitorManager.getPid();
              await inhibitorManager.stop();
              logFn(`Sleep inhibitor stopped (PID: ${pid})`, "info");
            } catch (error) {
              logFn(`Failed to stop sleep inhibitor: ${error}`, "error");
            }
          }
          break;
      }
    },
  };
};

export default CaffeinatePlugin;
