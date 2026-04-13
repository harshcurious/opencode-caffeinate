# opencode-caffeinate

Prevent macOS and Linux systems from sleeping while OpenCode sessions are active.

## What it does

This plugin automatically starts a platform-specific sleep inhibitor when an OpenCode session starts, keeping your machine awake during long AI coding sessions. When all sessions end, the inhibitor is stopped to restore normal power management.

**Backends used:**
- macOS: `caffeinate -dim`
- Linux (systemd): `systemd-inhibit --what=idle:sleep --mode=block sleep infinity`

**macOS flags used:**
- `-d`: Prevent display sleep
- `-i`: Prevent idle sleep
- `-m`: Prevent disk sleep

## Installation

### From npm (recommended)

Add to your `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-caffeinate"]
}
```

### From local files

Clone this repo to your plugins directory:

```bash
# Global plugins
git clone https://github.com/nguyenphutrong/opencode-caffeinate.git ~/.config/opencode/plugins/opencode-caffeinate

# Or project-level
git clone https://github.com/nguyenphutrong/opencode-caffeinate.git .opencode/plugins/opencode-caffeinate
```

## Requirements

- **macOS** with `caffeinate`, or **Linux** with a usable `systemd-inhibit` / logind environment
- **Bun** >= 1.0.0
- **OpenCode** with plugin support

## How it works

1. When a session is created (`session.created` event), the plugin registers the session in `/tmp/opencode-caffeinate/sessions/`
2. A single inhibitor process is spawned if not already running (tracked via PID file at `/tmp/opencode-caffeinate/inhibitor.pid`)
3. Multiple parallel OpenCode instances are supported - sessions are tracked across processes
4. When a session ends (`session.idle` or `session.deleted` events), the session is unregistered
5. When all sessions across all instances end, the inhibitor is stopped automatically

**Cross-process synchronization:** The plugin uses file-based session tracking to correctly handle multiple OpenCode instances running in parallel. Each session creates a PID file, and stale sessions (crashed processes) are automatically detected and ignored.

**Linux scope:** Linux support currently targets systems where `systemd-inhibit` is available in `PATH` and can talk to logind.

## Development

```bash
# Install dependencies
bun install

# Run tests
bun run test

# Type check
bun run --bun tsc --noEmit
```

## License

MIT
