#!/usr/bin/env bash
# champ-health.sh — one health monitor for every deployed Champ tool.
#
# Runs on DeependHQ-Hermes every 2 minutes via champ-health.timer. Checks each
# product's public surface, the box it runs on, and the metered third parties
# that stop working silently when they run out (MaxMind credits, TLS certs).
# Pages you through /root/lib-alert.sh (ntfy -> phone), the same sink
# hermes-guard.sh uses, so there is exactly one place that knows how to reach you.
#
# Adding a tool is one line in /root/champ-health.targets — nothing else.
#
#   ./champ-health.sh            one pass, alerting
#   ./champ-health.sh --dry-run  one pass, print only, never alert or write state
#   ./champ-health.sh --test     send a test page so you can prove the sink works
#
# Design notes:
#   * A failure must be seen FAIL_STREAK passes in a row before it pages. A single
#     blip during a deploy is not an outage and must not cry wolf.
#   * fail pages as critical; warn nags once a day at warning severity. A monitor
#     that pages the same way for "disk is 86% full" and "the site is down" gets
#     muted, and then it protects nothing.
#   * While something stays down you get re-paged every REPEAT_HOURS, not every
#     2 minutes. Recovery always pages once, immediately.
#   * Every pass writes a JSON snapshot to $STATUS_JSON. Serve that file and an
#     EXTERNAL checker can verify both "the tools are up" and "this box is still
#     running the monitor" — a monitor on the box can never report its own death.

set -uo pipefail

TARGETS="${TARGETS:-/root/champ-health.targets}"
ENV_FILE="${ENV_FILE:-/root/champ-health.env}"
STATE_DIR="${STATE_DIR:-/var/lib/champ-health}"
STATUS_JSON="${STATUS_JSON:-/var/www/fleet/fleet-status.json}"
ALERT_LIB="${ALERT_LIB:-/root/lib-alert.sh}"

FAIL_STREAK="${FAIL_STREAK:-2}"      # consecutive bad passes before paging
REPEAT_HOURS="${REPEAT_HOURS:-6}"    # re-page cadence while a check is FAILING
WARN_REPEAT_HOURS="${WARN_REPEAT_HOURS:-24}"  # warnings are not outages: nag daily, never hourly
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
MEM_WARN_MB="${MEM_WARN_MB:-200}"    # available RAM, not free
SWAP_WARN_PCT="${SWAP_WARN_PCT:-80}"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --test) : ;;
esac

mkdir -p "$STATE_DIR" "$(dirname "$STATUS_JSON")" 2>/dev/null
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

# ---------------------------------------------------------------- alerting
if [ -r "$ALERT_LIB" ]; then
  # shellcheck disable=SC1090
  . "$ALERT_LIB"
else
  hermes_alert() { logger -t champ-health -p "user.$1" -- "$2 — $3"; }
fi

if [ "${1:-}" = "--test" ]; then
  hermes_alert info "champ-health test" "If you can read this on your phone, the alert path works."
  echo "test alert sent"; exit 0
fi

# name -> a filesystem-safe key
key_of() { echo "$1" | tr -cs '[:alnum:]' '_' | sed 's/_*$//'; }

RESULTS=()   # name|status|detail  (status: ok|fail|warn)

record() { RESULTS+=("$1|$2|$3"); }

# ---------------------------------------------------------------- checks
check_http() {
  local name="$1" url="$2" expect="$3" needle="$4" code body
  # One retry: a transient reset during a redeploy is not an outage.
  for _ in 1 2; do
    body=$(curl -sS -m "$HTTP_TIMEOUT" -w $'\n%{http_code}' -A 'champ-health/1.0' "$url" 2>/dev/null)
    code="${body##*$'\n'}"
    [ "$code" = "$expect" ] && break
    sleep 2
  done
  if [ "$code" != "$expect" ]; then
    record "$name" fail "HTTP $code (expected $expect) at $url"
    return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"${body%$'\n'*}"; then
    record "$name" fail "HTTP $expect but response is missing \"$needle\" — serving the wrong thing"
    return
  fi
  record "$name" ok "HTTP $code"
}

check_cert() {
  local name="$1" url="$2" host end left
  host=$(sed -E 's#^https://([^/]+).*#\1#' <<<"$url")
  [[ "$url" == https://* ]] || return 0
  end=$(echo | timeout 12 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  [ -n "$end" ] || return 0
  left=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  [ "$left" -le 0 ] && return 0
  if [ "$left" -lt "$CERT_WARN_DAYS" ]; then
    record "$name TLS" warn "certificate expires in ${left}d ($host)"
  fi
}

check_box() {
  local pct avail swap_total swap_used swap_pct
  pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  [ "${pct:-0}" -ge "$DISK_WARN_PCT" ] && record "Disk" warn "root filesystem ${pct}% full"

  avail=$(free -m | awk '/^Mem:/{print $7}')
  [ "${avail:-9999}" -lt "$MEM_WARN_MB" ] && record "Memory" warn "only ${avail}MB available RAM"

  swap_total=$(free -m | awk '/^Swap:/{print $2}')
  swap_used=$(free -m | awk '/^Swap:/{print $3}')
  if [ "${swap_total:-0}" -gt 0 ]; then
    swap_pct=$(( swap_used * 100 / swap_total ))
    [ "$swap_pct" -ge "$SWAP_WARN_PCT" ] && \
      record "Swap" warn "${swap_pct}% of swap in use (${swap_used}MB) — the box is short on RAM"
  fi
}

check_containers() {
  local unhealthy
  command -v docker >/dev/null || return 0
  unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | paste -sd, -)
  [ -n "$unhealthy" ] && record "Containers" fail "unhealthy: $unhealthy"
  local exited
  exited=$(docker ps -a --filter status=exited --filter label=coolify.managed=true \
           --format '{{.Names}}' 2>/dev/null | head -5 | paste -sd, -)
  [ -n "$exited" ] && record "Containers" warn "exited: $exited"
  return 0
}

# MaxMind credits (and anything else ChampBeam grades) in one authenticated call.
check_champbeam_system() {
  [ -n "${CHAMPBEAM_API:-}" ] && [ -n "${CHAMPBEAM_API_KEY:-}" ] || return 0
  local json
  json=$(curl -sS -m "$HTTP_TIMEOUT" "$CHAMPBEAM_API/api/v1/system/status" \
         -H "X-API-Key: $CHAMPBEAM_API_KEY" 2>/dev/null)
  [ -n "$json" ] || { record "ChampBeam system" warn "system status unreachable"; return 0; }

  local parsed
  parsed=$(python3 - "$json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("warn|could not parse system status"); raise SystemExit
mm = d.get("checks", {}).get("maxmind", {})
st, rem, days, when = mm.get("status"), mm.get("queries_remaining"), mm.get("days_left"), mm.get("projected_exhaustion")
tail = f"{rem:,} queries left" if isinstance(rem, int) else "balance unknown"
if isinstance(days, int):
    tail += f", ~{days}d at current burn"
    if when: tail += f" (runs out {when})"
if st == "off":
    print("ok|MaxMind not configured on this deployment (geo falls back to the free providers)")
else:
    print({"ok": "ok", "warning": "warn", "critical": "fail"}.get(st, "warn") + "|MaxMind credits: " + tail)
PY
)
  [ -n "$parsed" ] || parsed="warn|could not read MaxMind credits"
  record "MaxMind" "${parsed%%|*}" "${parsed#*|}"
}

# ---------------------------------------------------------------- run
if [ -r "$TARGETS" ]; then
  while IFS='|' read -r name url expect needle; do
    name=$(echo "${name:-}" | sed 's/^ *//;s/ *$//')
    url=$(echo "${url:-}" | sed 's/^ *//;s/ *$//')
    expect=$(echo "${expect:-200}" | tr -dc '0-9')
    needle=$(echo "${needle:-}" | sed 's/^ *//;s/ *$//')
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$url" ] || continue
    check_http "$name" "$url" "${expect:-200}" "$needle"
    check_cert "$name" "$url"
  done < "$TARGETS"
else
  record "Config" fail "no targets file at $TARGETS"
fi

check_box
check_containers
check_champbeam_system

# ---------------------------------------------------------------- report
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FAILING=0; WARNING=0
NEW_DOWN=(); RECOVERED=(); STILL_DOWN=(); WARNED=()

for r in "${RESULTS[@]}"; do
  name="${r%%|*}"; rest="${r#*|}"; status="${rest%%|*}"; detail="${rest#*|}"
  [ "$status" = "fail" ] && FAILING=$((FAILING+1))
  [ "$status" = "warn" ] && WARNING=$((WARNING+1))

  if [ "$DRY_RUN" = 1 ]; then
    printf '  %-4s %-34s %s\n' "$status" "$name" "$detail"
    continue
  fi

  k="$STATE_DIR/$(key_of "$name")"
  streak=$(cat "$k.streak" 2>/dev/null || echo 0)
  alerted=$(cat "$k.alerted" 2>/dev/null || echo 0)

  if [ "$status" = ok ]; then
    if [ "$alerted" != 0 ]; then RECOVERED+=("$name — $detail"); fi
    echo 0 > "$k.streak"; echo 0 > "$k.alerted"
  else
    streak=$((streak+1)); echo "$streak" > "$k.streak"
    if [ "$streak" -ge "$FAIL_STREAK" ]; then
      age=$(( $(date +%s) - alerted ))
      if [ "$status" = warn ]; then
        # A warning is "look at this today", not "wake up". Nag daily at most.
        if [ "$alerted" = 0 ] || [ "$age" -ge $((WARN_REPEAT_HOURS * 3600)) ]; then
          WARNED+=("$name — $detail")
          date +%s > "$k.alerted"
        fi
      elif [ "$alerted" = 0 ]; then
        NEW_DOWN+=("$name — $detail")
        date +%s > "$k.alerted"
      elif [ "$age" -ge $((REPEAT_HOURS * 3600)) ]; then
        STILL_DOWN+=("$name — $detail (down $(( age / 3600 ))h)")
        date +%s > "$k.alerted"
      fi
    fi
  fi
done

if [ "$DRY_RUN" != 1 ]; then
  {
    printf '{"checked_at":"%s","failing":%d,"warning":%d,"checks":[' "$NOW" "$FAILING" "$WARNING"
    sep=""
    for r in "${RESULTS[@]}"; do
      name="${r%%|*}"; rest="${r#*|}"; status="${rest%%|*}"; detail="${rest#*|}"
      printf '%s{"name":%s,"status":"%s","detail":%s}' "$sep" \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$name")" "$status" \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$detail")"
      sep=","
    done
    printf ']}\n'
  } > "$STATUS_JSON.tmp" && mv "$STATUS_JSON.tmp" "$STATUS_JSON"

  if [ ${#NEW_DOWN[@]} -gt 0 ]; then
    hermes_alert crit "${#NEW_DOWN[@]} check(s) failing" "$(printf '%s\n' "${NEW_DOWN[@]}")"
  fi
  if [ ${#STILL_DOWN[@]} -gt 0 ]; then
    hermes_alert crit "still failing" "$(printf '%s\n' "${STILL_DOWN[@]}")"
  fi
  if [ ${#RECOVERED[@]} -gt 0 ]; then
    hermes_alert info "recovered" "$(printf '%s\n' "${RECOVERED[@]}")"
  fi
  if [ ${#WARNED[@]} -gt 0 ]; then
    hermes_alert warning "${#WARNED[@]} warning(s)" "$(printf '%s\n' "${WARNED[@]}")"
  fi
fi

[ "$DRY_RUN" = 1 ] && echo "  ── $FAILING failing, $WARNING warning, ${#RESULTS[@]} checks"
exit 0
