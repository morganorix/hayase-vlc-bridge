#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# Hayase VLC Bridge
# ------------------------------------------------------------
# Purpose:
#   Send a Hayase stream URL to a remote VLC instance (WebSocket),
#   with automatic local fallback if remote is unreachable.
#
# Requirements:
#   - bash >= 4
#   - python3
#   - curl
#   - websocat
#   - VLC (local playback fallback)
#
# Notes:
#   - This script optionally loads configuration from a trusted ".env" file.
#   - The ".env" file is sourced as bash (it can execute code). Only use
#     a .env you fully trust.
# ------------------------------------------------------------

VERSION="1.1.0"

# ============================================================
# Ignore environment overrides
# ============================================================
# These variables may be set by other tools/environments. We clear them
# to avoid unexpected behavior. The script config is defined by:
#   1) the .env file (if present) and
#   2) defaults inside this script
unset HAYASE_LOG_LEVEL HAYASE_LOG_ENABLED HAYASE_LOG_VERBOSITY

# ============================================================
# .env loading (trusted file)
# ============================================================
# Default location: ".env" next to the script.
# Override path with:
#   HAYASE_ENV_FILE="/path/to/.env" ./hayase-vlc-bridge.sh <url>
ENV_FILE="${HAYASE_ENV_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.env}"

# load_env <file>
# Loads the .env file if it exists. Uses "source", so the file is executed
# as bash. This enables variable expansion like:
#   LOG_DIR="$HOME/.local/logs"
# but also means arbitrary commands could run.
load_env() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

load_env "$ENV_FILE"

# ============================================================
# External variables (with defaults)
# ============================================================
# These variables can be provided via the .env file. If missing, defaults
# are applied here.

# LOG_VERBOSITY:
#   0 = no file logs
#   1 = info logs
#   2 = debug logs (includes masked config dump)
: "${LOG_VERBOSITY:=0}"

# LOG_DIR / LOG_FILE:
# Where logs are written when LOG_VERBOSITY >= 1.
: "${LOG_DIR:="${HOME}/.local/logs/"}"
LOG_DIR="${LOG_DIR%/}/"
: "${LOG_FILE:="${LOG_DIR%/}/hayase-vlc-bridge.log"}"

# Remote VLC endpoint:
#   REMOTE_HOST is used for the HTTP reachability check.
#   WS_URL is used for the WebSocket connection (websocat).
: "${REMOTE_HOST:=}"
: "${WS_URL:="ws://${REMOTE_HOST}"}"

# STREAM_HOST:
# Local IP address reachable from the Apple TV.
# The script rewrites "localhost" and "127.0.0.1" to this host.
: "${STREAM_HOST:=}"

# VLC_LOCAL_CMD:
# Local fallback command (string) to start VLC.
# We parse it with python/shlex to preserve quoted arguments correctly.
: "${VLC_LOCAL_CMD:="flatpak run org.videolan.VLC --one-instance"}"

# Build VLC_LOCAL array from VLC_LOCAL_CMD using a robust split (shlex).
# This avoids bash word-splitting pitfalls and preserves quotes.
mapfile -t VLC_LOCAL < <(
  python3 - <<'PY'
import os, shlex
cmd = os.environ.get("VLC_LOCAL_CMD","")
for a in shlex.split(cmd):
    print(a)
PY
)

# ============================================================
# Logging helpers
# ============================================================

# ts
# RFC3339-ish timestamp with timezone (ISO 8601).
ts() { date -Is; }

# logs_enabled / logs_debug
# Central place to interpret verbosity levels.
logs_enabled() { [[ "${LOG_VERBOSITY:-0}" -ge 1 ]]; }
logs_debug()   { [[ "${LOG_VERBOSITY:-0}" -ge 2 ]]; }

# shorten <string>
# Shortens long URLs for readable INFO logs without losing the beginning/end.
shorten() {
  local s="$1" max=160
  if [[ ${#s} -le $max ]]; then printf '%s' "$s"
  else printf '%s…%s' "${s:0:120}" "${s: -30}"; fi
}

# log_line <LEVEL> <message...>
# Appends a single line to the log file (only when LOG_VERBOSITY >= 1).
log_line() {
  local lvl="$1"; shift
  logs_enabled || return 0
  printf '[%s] %-5s %s\n' "$(ts)" "$lvl" "$*" >> "$LOG_FILE"
}

# log_debug <message...>
# Debug logging is only emitted when LOG_VERBOSITY >= 2.
log_debug() { logs_debug && log_line DEBUG "$*" || true; }

# blank / sep
# Adds spacing/separators to the log file for readability.
blank() { logs_enabled && printf '\n' >> "$LOG_FILE" || true; }
sep()   { logs_enabled && printf '============================================================\n' >> "$LOG_FILE" || true; }

# Convenience log wrappers
step() { log_line INFO  "• $*"; }
ok()   { log_line INFO  "✓ $*"; }
warn() { log_line WARN  "⚠ $*"; }

# err <message...>
# Logs the error to the log file (if enabled) and always prints to stderr.
err()  { log_line ERROR "✗ $*"; printf 'ERROR: %s\n' "$*" >&2; }

# finish_block
# Marks the end of one execution block in the log file.
finish_block() {
  log_line INFO "===== END ====="
  sep
  blank
}

# ============================================================
# Config report (masked)
# ============================================================

# mask <value>
# Always masks values, while keeping a tiny bit of context:
#   - empty => "<empty>"
#   - <= 4 chars => "****"
#   - <= 8 chars => first 2 + "****"
#   - else => first 4 + "****" + last 2
mask() {
  local s="${1-}"
  [[ -z "$s" ]] && { printf '<empty>'; return 0; }

  local n=${#s}
  if (( n <= 4 )); then
    printf '****'
  elif (( n <= 8 )); then
    printf '%s****' "${s:0:2}"
  else
    printf '%s****%s' "${s:0:4}" "${s: -2}"
  fi
}

# log_multiline_debug
# Sends each line of a multi-line string as an independent DEBUG log line.
# This preserves timestamps/levels per line (handy for log aggregators).
log_multiline_debug() {
  local line
  while IFS= read -r line; do
    log_line DEBUG "$line"
  done
}

# config_report
# - LOG_VERBOSITY=2: dumps masked configuration to DEBUG (and stderr).
# - LOG_VERBOSITY=1: prints a single "OK" line.
# - LOG_VERBOSITY=0: prints nothing.
config_report() {
  if logs_debug; then
    local dump
    dump=$(
      cat <<EOF
===================================================
External variables:
  ENV_FILE      = $(mask "${ENV_FILE:-}")
  LOG_VERBOSITY = ${LOG_VERBOSITY:-}
  LOG_DIR       = $(mask "${LOG_DIR:-}")
  LOG_FILE      = $(mask "${LOG_FILE:-}")
  REMOTE_HOST   = $(mask "${REMOTE_HOST:-}")
  WS_URL        = $(mask "${WS_URL:-}")
  STREAM_HOST   = $(mask "${STREAM_HOST:-}")
  VLC_LOCAL_CMD = $(mask "${VLC_LOCAL_CMD:-}")
===================================================
EOF
    )

    # DEBUG log (file)
    printf '%s\n' "$dump" | log_multiline_debug

    # Also print to stderr to remain visible even if file logging can't write
    printf '%s\n' "$dump" >&2
    return 0
  fi

  if logs_enabled; then
    ok "External variables loaded: OK."
  fi
}

# ============================================================
# Core helpers
# ============================================================

RAW_TARGET=""

# abort <message>
# Stops execution with an error and writes an END block to the log file.
abort() {
  err "$1"
  finish_block
  exit 1
}

# fallback <reason>
# Called when remote playback fails. Logs the reason, then launches local VLC.
# Uses exec to replace the current process with VLC (no extra shell layer).
fallback() {
  warn "$1"
  warn "Fallback: launching local VLC."
  log_debug "URL(local)=<${RAW_TARGET}>"
  finish_block
  exec "${VLC_LOCAL[@]}" "${RAW_TARGET}"
}

# normalize_and_build_json <url>
# Normalizes URL encoding and builds the JSON command for the VLC bridge.
# Output:
#   line 1: normalized URL
#   line 2: JSON payload {"type":"openURL","url":"..."}
normalize_and_build_json() {
  python3 - <<'PY' "$1"
import json,sys,urllib.parse
u = urllib.parse.unquote(sys.argv[1])
u = urllib.parse.quote(u, safe=":/%?=&")
print(u)
print(json.dumps({"type":"openURL","url":u}))
PY
}

# require_cmd_or_fallback <cmd> <message>
# If a command is missing, fallback to local playback.
require_cmd_or_fallback() {
  command -v "$1" >/dev/null 2>&1 || fallback "$2"
}

# require_cmd_or_abort <cmd> <message>
# If a required command is missing for any playback mode, abort.
require_cmd_or_abort() {
  command -v "$1" >/dev/null 2>&1 || abort "$2"
}

# ============================================================
# Logging directory bootstrap
# ============================================================
# Create log directory only if logging is enabled. If creation fails, disable
# file logging and continue (do not break playback).
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
log_debug "CONFIG: LOG_VERBOSITY=$LOG_VERBOSITY STREAM_HOST=$STREAM_HOST REMOTE_HOST=$REMOTE_HOST"

# Report loaded variables depending on verbosity level
config_report

# ------------------------------------------------------------
# Configuration validation
# ------------------------------------------------------------
step "Checking configuration…"

[[ -n "${REMOTE_HOST:-}" ]] || abort "REMOTE_HOST is not configured (empty). Set it in .env or in the script."
[[ -n "${STREAM_HOST:-}" ]] || abort "STREAM_HOST is not configured (empty). Set it in .env or in the script."
[[ -n "${LOG_DIR:-}" ]]     || abort "LOG_DIR is not configured (empty). Set it in .env or in the script."
[[ -n "${WS_URL:-}" ]]      || abort "WS_URL is empty. Set it in .env or in the script."

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

# Preserve the raw user argument(s). Typically it is a single URL argument.
RAW_TARGET="$*"
log_debug "URL(raw)=<${RAW_TARGET}>"

[[ "$RAW_TARGET" == *"://"* ]] || abort "Invalid stream source: argument is not a valid URL."

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

mapfile -t __norm < <(normalize_and_build_json "$target") \
  || abort "Malformed stream: URL normalization failed."

target="${__norm[0]:-}"
json_cmd="${__norm[1]:-}"

[[ -n "$target" ]]   || abort "Malformed stream: empty URL after normalization."
[[ -n "$json_cmd" ]] || abort "Malformed stream: empty JSON after normalization."

ok "Stream parsed."

log_line INFO  "URL(final)=<$(shorten "$target")>"
log_debug "URL(final-full)=<$target>"

# ------------------------------------------------------------
# Step 3 — Remote playback
# ------------------------------------------------------------
step "Checking remote VLC server availability…"

# Fast failure: if remote is down, immediately fallback to local playback.
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

# Treat typical error strings as failure signals
shopt -s nocasematch
if [[ "$resp" == *"INVALID REQUEST"* || "$resp" == *"error"* || "$resp" == *"failed"* ]]; then
  shopt -u nocasematch
  fallback "WebSocket response indicates an error."
fi
shopt -u nocasematch

ok "Command successfully sent to remote VLC."

finish_block
exit 0
