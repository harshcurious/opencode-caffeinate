# Scope / purpose
- OpenCode plugin repo for macOS and Linux(systemd); published entrypoint is `.opencode/plugin/index.ts`.
- There is no conventional `src/` directory; plugin code lives under `.opencode/`.
- Keep guidance repo-specific; avoid generic JavaScript advice.

# Key paths
- `.opencode/plugin/index.ts`: OpenCode event wiring and platform gating.
- `.opencode/plugin/session-manager.ts`: session PID file tracking in `/tmp/opencode-caffeinate/sessions`.
- `.opencode/plugin/inhibitor-manager.ts`: platform-specific inhibitor command selection and PID tracking in `/tmp/opencode-caffeinate/inhibitor.pid`.
- `.opencode/plugin/__tests__/`: Bun test suite.
- `.opencode/package.json`: runtime dependency pin for `@opencode-ai/plugin`.

# Commands
- `bun install`
- `bun run test`
- `bun run --bun tsc --noEmit`

# Verification expectations
- Verify on the target OS when possible: macOS uses `caffeinate`, Linux support assumes a usable `systemd-inhibit` / logind environment.
- CI runs on `macos-latest` and `ubuntu-latest`, and executes typecheck, `bun run test`, and the Bun inline export check for `.opencode/plugin/index.ts`.

# Repo quirks / gotchas
- `index.ts` only enables the plugin on `darwin` and `linux`.
- Integration-style tests call the real platform inhibitor command through `InhibitorManager.start()`; they depend on `caffeinate` on macOS or `systemd-inhibit` on Linux.
- If OpenCode runtime/plugin behavior changes, check both root `package.json` and `.opencode/package.json` for needed updates.
- Do not invent lint or formatter commands; none are configured in the reviewed files.

# Release notes
- Release workflow runs on macOS, typechecks, bumps version, generates `CHANGELOG.md`, amends the release commit, force-pushes, pushes the tag, and publishes to npm with provenance.
