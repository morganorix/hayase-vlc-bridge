#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIG (modifiable uniquement ici)
# ============================================================

# 0 = pas de logs fichier
# 1 = logs simples
# 2 = logs détaillés
LOG_VERBOSITY=0

LOG_DIR="${HOME}/.local/logs"
LOG_FILE="${LOG_DIR}/hayase-vlc-appletv.log"

REMOTE_HOST="ssalon.local"
WS_URL="ws://${REMOTE_HOST}"

# IP joignable depuis l'Apple TV
STREAM_HOST="192.168.2.68"

# VLC local (Flatpak)
VLC_LOCAL=(flatpak run org.videolan.VLC --one-instance)

# ============================================================
# Ignore override environnement
# ============================================================
unset HAYASE_LOG_LEVEL HAYASE_LOG_ENABLED HAYASE_LOG_VERBOSITY

mkdir -p "$LOG_DIR"

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
  # stop total (pas de fallback)
  err "$1"
  finish_block
  exit 1
}

fallback() {
  # fallback local (uniquement quand le flux est valide)
  warn "$1"
  warn "Fallback: lancement VLC local (flatpak)"
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

# ============================================================
# START
# ============================================================
blank
sep
log_line INFO "===== START ====="
log_line INFO "Args: $#"
log_debug "CONFIG: LOG_VERBOSITY=$LOG_VERBOSITY STREAM_HOST=$STREAM_HOST REMOTE_HOST=$REMOTE_HOST"

# ------------------------------------------------------------
# Étape 1 : récupérer la source du flux
# -> si ça échoue : STOP TOTAL
# ------------------------------------------------------------
step "Récupération de la source du flux (URL Hayase)…"
[[ $# -ge 1 ]] || abort "Récupération du flux impossible : aucune URL reçue."
RAW_TARGET="$*"
log_debug "URL(raw)=<${RAW_TARGET}>"

# Petit garde-fou : on veut une URL (Hayase envoie en général http(s)://...)
[[ "$RAW_TARGET" == *"://"* ]] || abort "Récupération du flux invalide : argument non-URL."

ok "Flux torrent trouvé."

# ------------------------------------------------------------
# Étape 2 : parsing / préparation
# -> si parsing KO : STOP TOTAL
# ------------------------------------------------------------
step "Réécriture de l'URL pour qu'elle soit joignable depuis l'Apple TV…"
target="$RAW_TARGET"
target="${target/http:\/\/localhost:/http:\/\/$STREAM_HOST:}"
target="${target/http:\/\/127.0.0.1:/http:\/\/$STREAM_HOST:}"
log_debug "URL(rewrite-host)=<$target>"
ok "Hôte réécrit."

step "Normalisation de l'encodage de l'URL…"
target="$(normalize_url "$target")" || abort "Flux mal parsé : normalisation URL impossible (python3/urllib)."
[[ -n "$target" ]] || abort "Flux mal parsé : URL vide après normalisation."
ok "Flux parsé."

log_line INFO  "URL(final)=<$(shorten "$target")>"
log_debug "URL(final-full)=<$target>"

# ------------------------------------------------------------
# Étape 3 : remote (si remote KO -> fallback local)
# ------------------------------------------------------------
step "Vérification du serveur VLC distant…"
curl -fsS --max-time 2 "http://${REMOTE_HOST}/" >/dev/null 2>&1 \
  || fallback "Serveur VLC distant injoignable (http://${REMOTE_HOST}/)."
ok "Serveur VLC distant joignable."

step "Vérification de websocat…"
require_cmd_or_fallback websocat "websocat manquant (impossible d'envoyer au VLC distant)."
ok "websocat OK."

step "Envoi de l'URL au VLC distant (WebSocket)…"
json_cmd="$(python3 -c 'import json,sys; print(json.dumps({"type":"openURL","url":sys.argv[1]}))' "$target")"
log_debug "WS url=<$WS_URL>"
log_debug "WS json=<$json_cmd>"

resp="$(printf '%s\n' "$json_cmd" | websocat -n1 "$WS_URL" 2>&1)" \
  || fallback "WebSocket a échoué (envoi impossible)."

log_line INFO "Réponse VLC=<$resp>"

echo "$resp" | grep -qiE "INVALID REQUEST|error|failed" \
  && fallback "Réponse WebSocket indique une erreur."

ok "Commande envoyée au VLC distant (pas d’erreur détectée)."

finish_block
exit 0
