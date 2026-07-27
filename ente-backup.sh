#!/bin/sh
# Scheduled Ente export loop with Healthchecks.io dead-man's-switch pings.
#
# Baked into the image at /usr/local/bin/ente-backup.
#
# Environment:
#   HC_URL    required. Healthchecks ping URL, e.g. https://hc-ping.com/<uuid>
#   INTERVAL  optional. Seconds between the END of one run and the START of
#             the next. Defaults to 3600.

set -u

log() { echo "[wrapper] $(date -u +%FT%TZ) $*"; }

INTERVAL="${INTERVAL:-3600}"

# ---- startup checks --------------------------------------------------------

if [ -z "${HC_URL:-}" ]; then
    log "FATAL: HC_URL is not set. Refusing to run unmonitored."
    exit 1
fi
log "HC_URL is set (host: $(echo "$HC_URL" | cut -d/ -f3))"

# curl is installed at build time, so this should never fail. If it does,
# the image is broken and we want to know immediately rather than discover
# it the first time a backup fails silently.
if ! curl --version >/dev/null 2>&1; then
    log "FATAL: curl is missing or will not run. Image is broken."
    exit 1
fi
log "using $(curl --version 2>/dev/null | head -n1)"

if ! /usr/bin/ente account list >/dev/null 2>&1; then
    log "WARNING: 'ente account list' failed - no account configured yet?"
    log "Run: docker exec -it <container> /usr/bin/ente account add"
fi

# ---- pinging ---------------------------------------------------------------
# $1 = url suffix ("", "/start", "/fail")
# $2 = human label for the log
# $3 = optional body text, shown on the Healthchecks dashboard
hc_ping() {
    url="${HC_URL}$1"
    curl -fsS -m 10 --retry 2 --data-raw "${3:-}" "$url" -o /dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log "ping OK ($2)"
        return 0
    fi
    log "PING FAILED ($2) - curl rc=$rc"
    return 1
}

log "sending startup test ping"
hc_ping "/start" "startup test" "wrapper started" \
    || log "startup ping failed - fix this before trusting the monitoring"

# ---- main loop -------------------------------------------------------------

log "starting loop, interval=${INTERVAL}s"

while true; do
    hc_ping "/start" "run starting" ""
    log "export starting"

    /usr/bin/ente export
    rc=$?
    log "ente export exited rc=$rc"

    # How much is actually on disk? Logged every run so you can spot a
    # library that stops growing, or one that suddenly shrinks.
    files=$(find /cli-export -type f ! -name '*.json' 2>/dev/null | wc -l)
    bytes=$(du -sh /cli-export 2>/dev/null | cut -f1)
    log "export dir now holds ${files} media files (${bytes})"

    # Exit code 0 with nothing on disk means something is wrong even
    # though the CLI thinks it succeeded.
    if [ "$rc" -eq 0 ] && [ "$files" -eq 0 ]; then
        log "WARNING: export dir is empty, treating as failure"
        rc=90
    fi

    if [ "$rc" -eq 0 ]; then
        log "export OK"
        hc_ping "" "success" "ok - ${files} files, ${bytes}"
    else
        log "export FAILED rc=$rc"
        hc_ping "/fail" "failure" "rc=${rc} - ${files} files, ${bytes}"
    fi

    log "sleeping ${INTERVAL}s"
    sleep "$INTERVAL"
done
