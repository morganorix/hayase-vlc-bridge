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

VERSION="1.0.0"

# ============================================================
# CONFIG (modifiable uniquement ici)
# ============================================================

# 0 = no file logging
# 1 = simple logs
# 2 = detailed logs
LOG_VERBOSITY=0

# Log file location
# You can freely change both the directory and filename.
LOG_DIR="${HOME}/<YOUR_LOCAL_DIRECTORY_LOGS>"
LOG_FILE="${LOG_DIR}/hayase-vlc-bridge.log"

REMOTE_HOST="<URL_REMOTE>"
WS_URL="ws://${REMOTE_HOST}"

# IP reachable from Apple TV
STREAM_HOST="<YOUR_LOCAL_IP>"

# VLC local command
# Default uses Flatpak.
# If you installed VLC natively, replace with for example:
# VLC_LOCAL=(vlc --one-instance)
VLC_LOCAL=(flatpak run org.videolan.VLC --one-instance)

# ============================================================
# Ignore environment overrides
# ============================================================
unset HAYASE_LOG_LEVEL HAYASE_LOG_ENABLED HAYASE_LOG_VERBOSITY

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

normalize_url() {
  python3 -c 'import sys,urllib.parse;
u=urllib.parse.unquote(sys.argv[1]);
print(urllib.parse.quote(u, safe=":/%?=&"))' "$1"
}

require_cmd_or_fallback() {
  command -v "$1" >/dev/null 2>&1 || fallback "$2"
}

require_cmd_or_abort() {
  command -v "$1" >/dev/null 2>&1 || abort "$2"
}

# Create log directory only if logging is enabled
# If it fails, disable file logging and continue (do not break playback).
if logs_enabled; then
  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    printf 'WARN: cannot create LOG_DIR (%s). Disabling file logging.\n' "$LOG_DIR" >&2
    LOG_VERBOSITY=0
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
# Configuration validation
# ------------------------------------------------------------
step "Checking configuration…"

[[ "$REMOTE_HOST" != "<URL_REMOTE>" ]] \
  || abort "REMOTE_HOST is not configured. Please edit the script."

[[ "$STREAM_HOST" != "<YOUR_LOCAL_IP>" ]] \
  || abort "STREAM_HOST is not configured. Please edit the script."

[[ "$LOG_DIR" != *"<YOUR_LOCAL_DIRECTORY_LOGS>"* ]] \
  || abort "LOG_DIR is not configured. Please edit the script."

ok "Configuration valid."

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

target="$(normalize_url "$target")" \
  || abort "Malformed stream: URL normalization failed."

[[ -n "$target" ]] \
  || abort "Malformed stream: empty URL after normalization."

ok "Stream parsed."

log_line INFO  "URL(final)=<$(shorten "$target")>"
log_debug "URL(final-full)=<$target>"

# ------------------------------------------------------------
# Step 3 — Remote playback
# ------------------------------------------------------------
step "Checking remote VLC server availability…"

curl -fsS --max-time 2 "http://${REMOTE_HOST}/" >/dev/null 2>&1 \
  || fallback "Remote VLC server unreachable (http://${REMOTE_HOST}/)."

ok "Remote VLC reachable."

step "Checking websocat dependency…"

require_cmd_or_fallback websocat "websocat missing (cannot send to remote VLC)."
ok "websocat detected."

step "Sending stream to remote VLC via WebSocket…"

json_cmd="$(python3 -c 'import json,sys; print(json.dumps({"type":"openURL","url":sys.argv[1]}))' "$target")"

log_debug "WS url=<$WS_URL>"
log_debug "WS json=<$json_cmd>"

resp="$(printf '%s\n' "$json_cmd" | websocat -n1 "$WS_URL" 2>&1)" \
  || fallback "WebSocket transmission failed."

log_line INFO "VLC response=<$resp>"

echo "$resp" | grep -qiE "INVALID REQUEST|error|failed" \
  && fallback "WebSocket response indicates an error."

ok "Command successfully sent to remote VLC."

finish_block
exit 0
