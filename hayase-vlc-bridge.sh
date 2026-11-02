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

VERSION="1.2.0"

# ============================================================
# Ignore environment overrides
# ============================================================
unset HAYASE_LOG_LEVEL HAYASE_LOG_ENABLED HAYASE_LOG_VERBOSITY

# ============================================================
# .env loading (trusted file)
# ============================================================
# Default location: ".env" next to the script.
# Override path with:
#   HAYASE_ENV_FILE="/path/to/.env" ./hayase-vlc-bridge.sh <url>
ENV_FILE="${HAYASE_ENV_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.env}"

# load_env <file> — sources the .env file if present (executed as bash).
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

# LOG_VERBOSITY: 0 = none, 1 = info, 2 = debug (masked config dump)
: "${LOG_VERBOSITY:=0}"

# LOG_DIR / LOG_FILE: where logs are written when LOG_VERBOSITY >= 1.
: "${LOG_DIR:="${HOME}/.local/logs/"}"
LOG_DIR="${LOG_DIR%/}/"
: "${LOG_FILE:="${LOG_DIR%/}/hayase-vlc-bridge.log"}"

# Remote VLC endpoint.
: "${REMOTE_HOST:=}"
: "${WS_URL:="ws://${REMOTE_HOST}"}"

# STREAM_HOST: LAN IP reachable from the remote device. "localhost" / "127.0.0.1"
# / "::1" in the stream URL are rewritten to this host (any scheme, port kept).
: "${STREAM_HOST:=}"

# VLC_LOCAL_CMD: local fallback command (string). Parsed lazily with shlex only
# if a fallback is actually needed (saves a python spawn on the nominal path).
: "${VLC_LOCAL_CMD:="flatpak run org.videolan.VLC --one-instance"}"

# Remote reachability timeouts (fail-fast). Configurable via .env.
: "${CONNECT_TIMEOUT:=0.3}"
: "${MAX_TIME:=0.8}"

# ============================================================
# Logging helpers
# ============================================================
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

# ============================================================
# Config report (masked)
# ============================================================
mask() {
  local s="${1-}"
  [[ -z "$s" ]] && { printf '<empty>'; return 0; }
  local n=${#s}
  if   (( n <= 4 )); then printf '****'
  elif (( n <= 8 )); then printf '%s****' "${s:0:2}"
  else                    printf '%s****%s' "${s:0:4}" "${s: -2}"; fi
}

log_multiline_debug() {
  local line
  while IFS= read -r line; do log_line DEBUG "$line"; done
}

config_report() {
  if logs_debug; then
    local dump
    dump=$(
      cat <<EOF
===================================================
External variables:
  ENV_FILE        = $(mask "${ENV_FILE:-}")
  LOG_VERBOSITY   = ${LOG_VERBOSITY:-}
  LOG_DIR         = $(mask "${LOG_DIR:-}")
  LOG_FILE        = $(mask "${LOG_FILE:-}")
  REMOTE_HOST     = $(mask "${REMOTE_HOST:-}")
  WS_URL          = $(mask "${WS_URL:-}")
  STREAM_HOST     = $(mask "${STREAM_HOST:-}")
  VLC_LOCAL_CMD   = $(mask "${VLC_LOCAL_CMD:-}")
  CONNECT_TIMEOUT = ${CONNECT_TIMEOUT:-}
  MAX_TIME        = ${MAX_TIME:-}
===================================================
EOF
    )
    printf '%s\n' "$dump" | log_multiline_debug
    printf '%s\n' "$dump" >&2
    return 0
  fi
  logs_enabled && ok "External variables loaded: OK." || true
}

# ============================================================
# Core helpers
# ============================================================
RAW_TARGET=""

abort() {
  err "$1"
  finish_block
  exit 1
}

# fallback <reason>
# Lazily parses VLC_LOCAL_CMD (shlex) and execs local VLC with the ORIGINAL
# (un-rewritten) URL, which local VLC can reach directly.
fallback() {
  warn "$1"
  warn "Fallback: launching local VLC."
  log_debug "URL(local)=<${RAW_TARGET}>"

  local -a vlc=()
  mapfile -t vlc < <(VLC_LOCAL_CMD="${VLC_LOCAL_CMD:-}" python3 - <<'PY'
import os, shlex
for a in shlex.split(os.environ.get("VLC_LOCAL_CMD", "")):
    print(a)
PY
  )
  (( ${#vlc[@]} >= 1 )) || abort "VLC_LOCAL_CMD is empty or invalid: cannot launch local VLC."

  finish_block
  exec "${vlc[@]}" "${RAW_TARGET}"
}

# normalize_url <url> <stream_host>
# In a single python pass: rewrite a local host to <stream_host> (any scheme,
# keeping the port), normalize percent-encoding, and build the JSON command.
# Output: line 1 = normalized URL, line 2 = JSON payload.
normalize_url() {
  python3 - "$1" "$2" <<'PY'
import json, sys, urllib.parse as P
raw, host = sys.argv[1], sys.argv[2]
sp = P.urlsplit(raw)
if host and (sp.hostname or "").lower() in ("localhost", "127.0.0.1", "::1"):
    try:
        port = sp.port
    except ValueError:
        port = None
    sp = sp._replace(netloc=host + (f":{port}" if port else ""))
u = P.urlunsplit(sp)
u = P.unquote(u)
u = P.quote(u, safe=":/%?=&@[]~")
print(u)
print(json.dumps({"type": "openURL", "url": u}))
PY
}

require_cmd_or_fallback() { command -v "$1" >/dev/null 2>&1 || fallback "$2"; }
require_cmd_or_abort()    { command -v "$1" >/dev/null 2>&1 || abort "$2"; }

# ============================================================
# Logging directory bootstrap
# ============================================================
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
config_report

# ------------------------------------------------------------
# Configuration validation
# ------------------------------------------------------------
step "Checking configuration…"
[[ -n "${REMOTE_HOST:-}" ]] || abort "REMOTE_HOST is not configured (empty). Set it in .env."
[[ -n "${STREAM_HOST:-}" ]] || abort "STREAM_HOST is not configured (empty). Set it in .env."
[[ -n "${LOG_DIR:-}" ]]     || abort "LOG_DIR is not configured (empty). Set it in .env."
[[ -n "${WS_URL:-}" ]]      || abort "WS_URL is empty. Set it in .env."
ok "Configuration valid."

# ------------------------------------------------------------
# Dependencies (needed for any playback mode)
# ------------------------------------------------------------
step "Checking required dependencies…"
require_cmd_or_abort python3 "python3 is required for URL normalization."
require_cmd_or_abort curl "curl is required to check remote VLC."
ok "Core dependencies detected."

# ------------------------------------------------------------
# Step 1 — Stream URL
# ------------------------------------------------------------
step "Retrieving stream source from Hayase…"
(( $# >= 1 )) || abort "Stream retrieval failed: no URL provided."
RAW_TARGET="$*"
log_debug "URL(raw)=<${RAW_TARGET}>"
[[ "$RAW_TARGET" == *"://"* ]] || abort "Invalid stream source: argument is not a valid URL."
ok "Stream source detected."

# ------------------------------------------------------------
# Step 2 — Rewrite host + normalize (single python pass)
# ------------------------------------------------------------
step "Rewriting host for remote access and normalizing URL…"
if ! __norm_out="$(normalize_url "$RAW_TARGET" "$STREAM_HOST")"; then
  abort "Malformed stream: URL normalization failed."
fi
mapfile -t __norm <<< "$__norm_out"
target="${__norm[0]:-}"
json_cmd="${__norm[1]:-}"
[[ -n "$target"   ]] || abort "Malformed stream: empty URL after normalization."
[[ -n "$json_cmd" ]] || abort "Malformed stream: empty JSON after normalization."
ok "Stream parsed."
log_line INFO  "URL(final)=<$(shorten "$target")>"
log_debug "URL(final-full)=<$target>"

# ------------------------------------------------------------
# Step 3 — Remote playback (fail-fast, else local fallback)
# ------------------------------------------------------------
step "Checking remote VLC server availability…"
curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "http://${REMOTE_HOST}/" >/dev/null 2>&1 \
  || fallback "Remote VLC server unreachable (http://${REMOTE_HOST}/)."
ok "Remote VLC reachable."

require_cmd_or_fallback websocat "websocat missing (cannot send to remote VLC)."

step "Sending stream to remote VLC via WebSocket…"
log_debug "WS url=<$WS_URL>"
log_debug "WS json=<$json_cmd>"
resp="$(printf '%s\n' "$json_cmd" | websocat -n1 "$WS_URL" 2>&1)" \
  || fallback "WebSocket transmission failed."
log_line INFO "VLC response=<$resp>"

# Treat typical error strings as failure signals.
shopt -s nocasematch
if [[ "$resp" == *"invalid request"* || "$resp" == *"error"* || "$resp" == *"failed"* ]]; then
  shopt -u nocasematch
  fallback "WebSocket response indicates an error."
fi
shopt -u nocasematch

ok "Command successfully sent to remote VLC."
finish_block
exit 0
