#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# Hayase VLC Bridge
# Sends Hayase stream URLs to a remote VLC instance
# with automatic local fallback.
#
# Requirements:
# - bash >= 4
# - python3
# - curl
# - websocat
# - VLC
# ------------------------------------------------------------

VERSION="1.1.0"

# ============================================================
# CONFIG (loaded from .env next to this script)
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

[[ -f "$ENV_FILE" ]] || { printf 'ERROR: missing .env next to script. Copy .env.example to .env.\n' >&2; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

# Compute/normalize a few derived values (minimal, non-invasive)
WS_URL="${WS_URL:-ws://${REMOTE_HOST}}"
LOG_DIR="${LOG_DIR%/}"                         # remove trailing slash if any
LOG_FILE="${LOG_FILE:-$LOG_DIR/hayase-vlc-bridge.log}"

# VLC command from .env (simple space-splitting)
read -r -a VLC_LOCAL <<<"${VLC_LOCAL_CMD:-}"

# ============================================================
# Ignore environment overrides
# ============================================================
unset HAYASE_LOG_LEVEL HAYASE_LOG_ENABLED HAYASE_LOG_VERBOSITY

# Secure defaults for created files (logs)
umask 077

ts() { date -Is; }

logs_enabled() { [[ "${LOG_VERBOSITY:-0}" -ge 1 ]]; }
logs_debug()   { [[ "${LOG_VERBOSITY:-0}" -ge 2 ]]; }

shorten() {
  local s="$1" max=160
  if [[ ${#s} -le $max ]]; then printf '%s' "$s"
  else printf '%s…%s' "${s:0:120}" "${s: -30}"; fi
}

log_line() {
  local lvl="$1"; shift
  logs_enabled || return 0
  printf '[%s] %-5s %s\n' "$(ts)" "$lvl" "$*" >> "$LOG_FILE"
}

log_debug() { logs_debug && log_line DEBUG "$*" || true; }

blank() { logs_enabled && printf '\n' >> "$LOG_FILE" || true; }
sep()   { logs_enabled && printf '============================================================\n' >> "$LOG_FILE" || true; }

step() { log_line INFO  "• $*"; }
ok()   { log_line INFO  "✓ $*"; }
warn() { log_line WARN  "⚠ $*"; }
err()  { log_line ERROR "✗ $*"; printf 'ERROR: %s\n' "$*" >&2; }

finish_block() {
  log_line INFO "===== END ====="
  sep
  blank
}

RAW_TARGET=""

abort() {
  err "$1"
  finish_block
  exit 1
}

fallback() {
  warn "$1"
  warn "Fallback: launching local VLC."
  log_debug "URL(local)=<${RAW_TARGET}>"
  finish_block
  exec "${VLC_LOCAL[@]}" "${RAW_TARGET}"
}

# Speed: normalize URL + build WS JSON in ONE python call (instead of 2).
# Prints:
#   line 1: normalized URL
#   line 2: json payload
normalize_and_build_json() {
  python3 - <<'PY' "$1"
import json,sys,urllib.parse
u = urllib.parse.unquote(sys.argv[1])
u = urllib.parse.quote(u, safe=":/%?=&")
print(u)
print(json.dumps({"type":"openURL","url":u}))
PY
}

require_cmd_or_fallback() {
  command -v "$1" >/dev/null 2>&1 || fallback "$2"
}

require_cmd_or_abort() {
  command -v "$1" >/dev/null 2>&1 || abort "$2"
}

# ------------------------------------------------------------
# Configuration validation (from .env)
# ------------------------------------------------------------

[[ -n "${REMOTE_HOST:-}" && "$REMOTE_HOST" != "<URL_REMOTE>" ]] \
  || { printf 'ERROR: REMOTE_HOST is not configured in .env.\n' >&2; exit 1; }

[[ -n "${STREAM_HOST:-}" && "$STREAM_HOST" != "<YOUR_LOCAL_IP>" ]] \
  || { printf 'ERROR: STREAM_HOST is not configured in .env.\n' >&2; exit 1; }

[[ -n "${LOG_DIR:-}" && "$LOG_DIR" != *"<YOUR_LOCAL_DIRECTORY_LOGS>"* ]] \
  || { printf 'ERROR: LOG_DIR is not configured in .env.\n' >&2; exit 1; }

[[ -n "${VLC_LOCAL_CMD:-}" ]] \
  || { printf 'ERROR: VLC_LOCAL_CMD is not configured in .env.\n' >&2; exit 1; }

# Create log directory/file only if logging is enabled.
# If it fails, disable file logging and continue (do not break playback).
if logs_enabled; then
  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    printf 'WARN: cannot create LOG_DIR (%s). Disabling file logging.\n' "$LOG_DIR" >&2
    LOG_VERBOSITY=0
  elif ! touch "$LOG_FILE" 2>/dev/null; then
    printf 'WARN: cannot create LOG_FILE (%s). Disabling file logging.\n' "$LOG_FILE" >&2
    LOG_VERBOSITY=0
  else
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
fi

# ============================================================
# START
# ============================================================
blank
sep
log_line INFO "Hayase VLC Bridge v${VERSION}"
log_line INFO "===== START ====="
log_line INFO "Args: $#"
log_debug "CONFIG: LOG_VERBOSITY=$LOG_VERBOSITY STREAM_HOST=$STREAM_HOST REMOTE_HOST=$REMOTE_HOST"

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------
step "Checking required dependencies…"

require_cmd_or_abort python3 "python3 is required for URL normalization."
require_cmd_or_abort curl "curl is required to check remote VLC."

ok "Core dependencies detected."

# ------------------------------------------------------------
# Step 1 — Retrieve stream
# ------------------------------------------------------------
step "Retrieving stream source from Hayase…"

[[ $# -ge 1 ]] || abort "Stream retrieval failed: no URL provided."

RAW_TARGET="$*"
log_debug "URL(raw)=<${RAW_TARGET}>"

[[ "$RAW_TARGET" == *"://"* ]] \
  || abort "Invalid stream source: argument is not a valid URL."

ok "Stream source detected."

# ------------------------------------------------------------
# Step 2 — Prepare / parse URL
# ------------------------------------------------------------
step "Rewriting URL for Apple TV network access…"

target="$RAW_TARGET"
target="${target/http:\/\/localhost:/http:\/\/$STREAM_HOST:}"
target="${target/http:\/\/127.0.0.1:/http:\/\/$STREAM_HOST:}"

log_debug "URL(rewrite-host)=<$target>"
ok "Host rewritten."

step "Normalizing URL encoding…"

# Speed: single python call returns normalized URL + JSON
mapfile -t __norm < <(normalize_and_build_json "$target") \
  || abort "Malformed stream: URL normalization failed."

target="${__norm[0]:-}"
json_cmd="${__norm[1]:-}"

[[ -n "$target" ]] \
  || abort "Malformed stream: empty URL after normalization."

[[ -n "$json_cmd" ]] \
  || abort "Malformed stream: empty JSON after normalization."

ok "Stream parsed."

log_line INFO  "URL(final)=<$(shorten "$target")>"
log_debug "URL(final-full)=<$target>"

# ------------------------------------------------------------
# Step 3 — Remote playback
# ------------------------------------------------------------
step "Checking remote VLC server availability…"

# Speed: faster fail when remote is down
curl -fsS --connect-timeout 0.3 --max-time 0.8 "http://${REMOTE_HOST}/" >/dev/null 2>&1 \
  || fallback "Remote VLC server unreachable (http://${REMOTE_HOST}/)."

ok "Remote VLC reachable."

step "Checking websocat dependency…"

require_cmd_or_fallback websocat "websocat missing (cannot send to remote VLC)."
ok "websocat detected."

step "Sending stream to remote VLC via WebSocket…"

log_debug "WS url=<$WS_URL>"
log_debug "WS json=<$json_cmd>"

resp="$(printf '%s\n' "$json_cmd" | websocat -n1 "$WS_URL" 2>&1)" \
  || fallback "WebSocket transmission failed."

log_line INFO "VLC response=<$resp>"

# Speed: avoid spawning grep
shopt -s nocasematch
if [[ "$resp" == *"INVALID REQUEST"* || "$resp" == *"error"* || "$resp" == *"failed"* ]]; then
  shopt -u nocasematch
  fallback "WebSocket response indicates an error."
fi
shopt -u nocasematch

ok "Command successfully sent to remote VLC."

finish_block
exit 0
