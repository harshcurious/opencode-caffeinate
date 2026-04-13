#!/usr/bin/env bash
set -euo pipefail

PLUGIN_TMP="/tmp/opencode-caffeinate"
PID_FILE="$PLUGIN_TMP/inhibitor.pid"
SESSIONS_DIR="$PLUGIN_TMP/sessions"
OPENCODE_BASE_URL="${OPENCODE_BASE_URL:-http://localhost:4096}"
OPENCODE_DIRECTORY="${OPENCODE_DIRECTORY:-$(pwd)}"
OPENCODE_SERVE_MODE="${OPENCODE_SERVE_MODE:-auto}"
ACTIVE_TIMEOUT_SECONDS="${ACTIVE_TIMEOUT_SECONDS:-120}"
IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS:-180}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
TARGET_SESSION_ID="${TARGET_SESSION_ID:-}"
SESSION_TITLE="${SESSION_TITLE:-Automated Linux plugin test}"
PROMPT_TEXT="${PROMPT_TEXT:-Reply with the single word done.}"
OPENCODE_SERVER_LOG="${OPENCODE_SERVER_LOG:-/tmp/opencode-caffeinate-opencode-server.log}"
EVENT_WATCH_LOG="${EVENT_WATCH_LOG:-/tmp/opencode-caffeinate-event-watch.log}"

STARTED_OPENCODE_SERVER=0
OPENCODE_SERVER_PID=""
EVENT_WATCHER_PID=""

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

cleanup() {
  if [[ -n "$EVENT_WATCHER_PID" ]]; then
    kill "$EVENT_WATCHER_PID" >/dev/null 2>&1 || true
    wait "$EVENT_WATCHER_PID" 2>/dev/null || true
  fi

  if [[ -n "$TARGET_SESSION_ID" ]]; then
    delete_session "$TARGET_SESSION_ID"
  fi

  if [[ "$STARTED_OPENCODE_SERVER" == "1" ]] && [[ -n "$OPENCODE_SERVER_PID" ]]; then
    log "Stopping opencode serve (pid $OPENCODE_SERVER_PID)"
    kill "$OPENCODE_SERVER_PID" >/dev/null 2>&1 || true
    wait "$OPENCODE_SERVER_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

fetch_session_status_json() {
  curl -fsS "$(url_with_directory "/session/status")"
}

url_with_directory() {
  local path="$1"
  python3 - "$OPENCODE_BASE_URL" "$path" "$OPENCODE_DIRECTORY" <<'PY'
from urllib.parse import urlencode
import sys

base_url, path, directory = sys.argv[1:4]
separator = '&' if '?' in path else '?'
print(f"{base_url}{path}{separator}{urlencode({'directory': directory})}")
PY
}

parsed_server_host() {
  python3 - "$OPENCODE_BASE_URL" <<'PY'
from urllib.parse import urlparse
import sys
url = urlparse(sys.argv[1])
print(url.hostname or "127.0.0.1")
PY
}

parsed_server_port() {
  python3 - "$OPENCODE_BASE_URL" <<'PY'
from urllib.parse import urlparse
import sys
url = urlparse(sys.argv[1])
if url.port:
    print(url.port)
elif url.scheme == "https":
    print(443)
else:
    print(80)
PY
}

server_is_reachable() {
  curl -fsS "$OPENCODE_BASE_URL/session/status" >/dev/null 2>&1
}

start_idle_event_watcher() {
  local session_id="$1"
  : > "$EVENT_WATCH_LOG"

  python3 - "$OPENCODE_BASE_URL" "$session_id" "$EVENT_WATCH_LOG" > /dev/null 2>&1 <<'PY' &
import json
import sys
import urllib.request

base_url, session_id, log_path = sys.argv[1:4]
url = f"{base_url}/event"
seen_busy = False

with urllib.request.urlopen(url, timeout=300) as response, open(log_path, "a", encoding="utf-8") as log_file:
    for raw in response:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue

        payload = json.loads(line[5:].strip())
        log_file.write(json.dumps(payload) + "\n")
        log_file.flush()

        if payload.get("type") == "session.status":
            props = payload.get("properties", {})
            if props.get("sessionID") != session_id:
                continue
            status = props.get("status", {}).get("type")
            if status == "busy":
                seen_busy = True
            if status == "idle" and seen_busy:
                sys.exit(0)

        if payload.get("type") == "session.idle":
            props = payload.get("properties", {})
            if props.get("sessionID") == session_id and seen_busy:
                sys.exit(0)

sys.exit(1)
PY

  EVENT_WATCHER_PID="$!"
}

start_opencode_server() {
  local host
  local port
  host="$(parsed_server_host)"
  port="$(parsed_server_port)"

  log "Starting opencode serve on http://$host:$port"
  : > "$OPENCODE_SERVER_LOG"
  opencode serve --hostname "$host" --port "$port" >"$OPENCODE_SERVER_LOG" 2>&1 &
  OPENCODE_SERVER_PID="$!"
  STARTED_OPENCODE_SERVER=1
}

create_session() {
  local payload
  payload="$(python3 - "$SESSION_TITLE" <<'PY'
import json, sys
print(json.dumps({"title": sys.argv[1]}))
PY
)"

  curl -fsS \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "$(url_with_directory "/session")"
}

start_session_work() {
  local session_id="$1"
  local payload
  payload="$(python3 - "$PROMPT_TEXT" <<'PY'
import json, sys
print(json.dumps({
  "parts": [
    {
      "type": "text",
      "text": sys.argv[1],
    }
  ]
}))
PY
)"

  curl -fsS \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "$(url_with_directory "/session/$session_id/prompt_async")" \
    >/dev/null
}

delete_session() {
  local session_id="$1"
  curl -fsS \
    --request DELETE \
    "$(url_with_directory "/session/$session_id")" \
    >/dev/null || true
}

session_status_count() {
  fetch_session_status_json | python3 -c 'import json,sys; data=json.load(sys.stdin); print(len(data))'
}

pick_busy_session_id() {
  fetch_session_status_json | python3 -c 'import json,sys; data=json.load(sys.stdin); ids=[k for k,v in data.items() if v.get("type") == "busy"]; print(ids[0] if ids else "")'
}

session_is_busy() {
  local session_id="$1"
  fetch_session_status_json | python3 -c 'import json,sys; session_id=sys.argv[1]; data=json.load(sys.stdin); print("1" if data.get(session_id, {}).get("type") == "busy" else "0")' "$session_id"
}

session_is_idle_or_absent() {
  local session_id="$1"
  fetch_session_status_json | python3 -c 'import json,sys; session_id=sys.argv[1]; data=json.load(sys.stdin); print("1" if session_id not in data or data.get(session_id, {}).get("type") == "idle" else "0")' "$session_id"
}

wait_for_server() {
  if server_is_reachable; then
    return 0
  fi

  case "$OPENCODE_SERVE_MODE" in
    auto|always)
      start_opencode_server
      ;;
    never)
      ;;
    *)
      fail "invalid OPENCODE_SERVE_MODE: $OPENCODE_SERVE_MODE (expected auto, always, or never)"
      ;;
  esac

  log "Waiting for OpenCode server at $OPENCODE_BASE_URL"
  local elapsed=0
  while (( elapsed < ACTIVE_TIMEOUT_SECONDS )); do
    if server_is_reachable; then
      return 0
    fi

    if [[ "$STARTED_OPENCODE_SERVER" == "1" ]] && [[ -n "$OPENCODE_SERVER_PID" ]] && ! kill -0 "$OPENCODE_SERVER_PID" >/dev/null 2>&1; then
      log "opencode serve exited early; log follows"
      sed 's/^/  | /' "$OPENCODE_SERVER_LOG" || true
      fail "opencode serve failed to stay running"
    fi

    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done

  if [[ -f "$OPENCODE_SERVER_LOG" ]]; then
    log "OpenCode server log"
    sed 's/^/  | /' "$OPENCODE_SERVER_LOG" || true
  fi
  fail "timed out waiting for OpenCode server at $OPENCODE_BASE_URL"
}

wait_for_quiet_baseline() {
  log "Waiting for a quiet baseline with no non-idle session statuses"
  local elapsed=0
  while (( elapsed < ACTIVE_TIMEOUT_SECONDS )); do
    if [[ "$(session_status_count)" == "0" ]]; then
      return 0
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done
  fail "OpenCode already has active session statuses; set TARGET_SESSION_ID or start from an idle baseline"
}

create_or_reuse_session() {
  if [[ -n "$TARGET_SESSION_ID" ]]; then
    log "Using provided TARGET_SESSION_ID=$TARGET_SESSION_ID"
    return 0
  fi

  log "Creating a fresh OpenCode session"
  TARGET_SESSION_ID="$(create_session | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  [[ -n "$TARGET_SESSION_ID" ]] || fail "failed to create session or parse session id"
  log "Created session: $TARGET_SESSION_ID"
}

trigger_session_work() {
  [[ -n "$TARGET_SESSION_ID" ]] || fail "cannot start work without a target session id"
  log "Starting async work in session $TARGET_SESSION_ID"
  start_session_work "$TARGET_SESSION_ID"
}

wait_for_idle_event() {
  log "Waiting up to ${IDLE_TIMEOUT_SECONDS}s for a real idle event"
  [[ -n "$EVENT_WATCHER_PID" ]] || fail "idle event watcher was not started"

  local elapsed=0
  while (( elapsed < IDLE_TIMEOUT_SECONDS )); do
    if ! kill -0 "$EVENT_WATCHER_PID" >/dev/null 2>&1; then
      if wait "$EVENT_WATCHER_PID"; then
        EVENT_WATCHER_PID=""
        log "Observed session idle event"
        return 0
      fi
      log "Event watcher log"
      sed 's/^/  | /' "$EVENT_WATCH_LOG" || true
      fail "idle event watcher exited without confirming a busy->idle transition"
    fi

    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done

  log "Event watcher log"
  sed 's/^/  | /' "$EVENT_WATCH_LOG" || true
  fail "timed out waiting for OpenCode to emit an idle event"
}

run_repo_checks() {
  log "Running repo checks"
  bun run test
  bun run --bun tsc --noEmit
  bun -e 'import { CaffeinatePlugin } from "./.opencode/plugin/index.ts"; import pluginDefault from "./.opencode/plugin/index.ts"; if (typeof CaffeinatePlugin !== "function") throw new Error("named export missing"); if (typeof pluginDefault !== "function") throw new Error("default export missing"); if (CaffeinatePlugin !== pluginDefault) throw new Error("exports do not match"); console.log("export check passed");'
}

cleanup_state() {
  log "Cleaning previous plugin temp state"
  rm -rf "$PLUGIN_TMP"
}

session_file_count() {
  if [[ ! -d "$SESSIONS_DIR" ]]; then
    echo 0
    return
  fi

  find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.session' | wc -l | tr -d ' '
}

pid_file_exists() {
  [[ -f "$PID_FILE" ]]
}

plugin_inhibitor_process_count() {
  {
    ps -eo pid=,args= \
      | grep -F 'systemd-inhibit --what=idle:sleep --who=OpenCode --why=Prevent sleep while OpenCode sessions are active --mode=block sleep infinity' \
      | grep -v grep || true
  } | wc -l | tr -d ' '
}

plugin_inhibitor_list_count() {
  {
    systemd-inhibit --list 2>/dev/null \
      | grep -F 'OpenCode' \
      | grep -F 'Prevent sleep while OpenCode sessions are active' || true
  } | wc -l | tr -d ' '
}

print_state() {
  log "Current state"
  printf '  pid file: %s\n' "$([[ -f "$PID_FILE" ]] && echo present || echo missing)"
  printf '  session files: %s\n' "$(session_file_count)"
  printf '  inhibitor processes: %s\n' "$(plugin_inhibitor_process_count)"
  printf '  inhibitor list matches: %s\n' "$(plugin_inhibitor_list_count)"
  printf '  opencode status count: %s\n' "$(session_status_count)"

  if [[ -n "$TARGET_SESSION_ID" ]]; then
    printf '  target session: %s\n' "$TARGET_SESSION_ID"
    printf '  target busy now: %s\n' "$(session_is_busy "$TARGET_SESSION_ID")"
    printf '  target idle/absent now: %s\n' "$(session_is_idle_or_absent "$TARGET_SESSION_ID")"
  fi

  if [[ -f "$PID_FILE" ]]; then
    printf '  inhibitor pid: %s\n' "$(cat "$PID_FILE")"
  fi
}

wait_for_active_state() {
  log "Waiting up to ${ACTIVE_TIMEOUT_SECONDS}s for an active OpenCode session"
  local elapsed=0

  while (( elapsed < ACTIVE_TIMEOUT_SECONDS )); do
    local pid_present=0
    local sessions=0
    local proc_count=0
    local list_count=0
    local status_count=0

    pid_file_exists && pid_present=1
    sessions="$(session_file_count)"
    proc_count="$(plugin_inhibitor_process_count)"
    list_count="$(plugin_inhibitor_list_count)"
    status_count="$(session_status_count)"

    if [[ -z "$TARGET_SESSION_ID" ]]; then
      TARGET_SESSION_ID="$(pick_busy_session_id)"
    fi

    if (( pid_present == 1 )) && (( sessions > 0 )) && (( proc_count > 0 )) && (( list_count > 0 )) && (( status_count > 0 )) && [[ -n "$TARGET_SESSION_ID" ]] && [[ "$(session_is_busy "$TARGET_SESSION_ID")" == "1" ]]; then
      log "Detected active plugin state"
      print_state
      return 0
    fi

    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done

  print_state
  fail "timed out waiting for active plugin state; start OpenCode and trigger a busy session"
}

wait_for_idle_cleanup() {
  log "Waiting up to ${IDLE_TIMEOUT_SECONDS}s for idle cleanup"
  [[ -n "$TARGET_SESSION_ID" ]] || fail "target session id was never detected"
  local elapsed=0

  while (( elapsed < IDLE_TIMEOUT_SECONDS )); do
    local sessions=0
    local proc_count=0
    local list_count=0
    local target_idle=0

    sessions="$(session_file_count)"
    proc_count="$(plugin_inhibitor_process_count)"
    list_count="$(plugin_inhibitor_list_count)"
    target_idle="$(session_is_idle_or_absent "$TARGET_SESSION_ID")"

    if ! pid_file_exists && (( sessions == 0 )) && (( proc_count == 0 )) && (( list_count == 0 )) && [[ "$target_idle" == "1" ]]; then
      log "Detected idle cleanup"
      print_state
      return 0
    fi

    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done

  print_state
  fail "timed out waiting for idle cleanup; let the session go idle or delete it"
}

main() {
  require_command bun
  require_command curl
  require_command python3
  require_command systemd-inhibit
  require_command ps
  require_command find

  log "This script can start 'opencode serve' automatically"
  log "Ensure your opencode.json enables the plugin"

  run_repo_checks
  cleanup_state
  wait_for_server
  if [[ -z "$TARGET_SESSION_ID" ]]; then
    wait_for_quiet_baseline
  fi
  create_or_reuse_session
  start_idle_event_watcher "$TARGET_SESSION_ID"

  log "Triggering a prompt in the target session"
  trigger_session_work
  wait_for_active_state

  log "Active state verified"
  wait_for_idle_event
  log "Waiting for the session to return to idle"
  wait_for_idle_cleanup

  log "Plugin behavior verified on Linux"
}

main "$@"
