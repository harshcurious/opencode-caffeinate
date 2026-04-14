# opencode-caffeinate

Keep OpenCode sessions awake on macOS and Linux.

## Overview

This plugin starts a platform-specific sleep inhibitor when an OpenCode session begins and stops it when the last session ends.

### Supported backends

- macOS: `caffeinate -dim`
- Linux: `systemd-inhibit --what=idle:sleep --mode=block sleep infinity`

### macOS flags

- `-d`: prevent display sleep
- `-i`: prevent idle sleep
- `-m`: prevent disk sleep

## Installation

### npm

Add the plugin to `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-caffeinate"]
}
```

### Local install

Clone the repo into your OpenCode plugins directory:

```bash
git clone https://github.com/nguyenphutrong/opencode-caffeinate.git ~/.config/opencode/plugins/opencode-caffeinate
```

For a project-level install, use:

```bash
git clone https://github.com/nguyenphutrong/opencode-caffeinate.git .opencode/plugins/opencode-caffeinate
```

## Requirements

- OpenCode with plugin support
- Bun 1.0 or later
- macOS with `caffeinate`, or Linux with `systemd-inhibit` and logind access

## Usage

No manual start is needed. Once installed, the plugin activates on session events and manages the inhibitor automatically.

## How it works

1. On `session.created`, the plugin records the session in `/tmp/opencode-caffeinate/sessions/`
2. If no inhibitor is running, it starts one and writes its PID to `/tmp/opencode-caffeinate/inhibitor.pid`
3. Session state is shared across OpenCode processes, so multiple instances can run at once
4. On `session.idle` or `session.deleted`, the plugin removes the session record
5. When the last active session ends, the inhibitor stops

The file-based session tracker also ignores stale entries from crashed processes.

## Development

```bash
bun install
bun run test
bun run --bun tsc --noEmit
```

## License

MIT
