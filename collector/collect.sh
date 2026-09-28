#!/usr/bin/env bash
#
# Run on the backup server: trigger a backup on a host, pull backup files, verify them,
# and report the result to Healthchecks.
#
# Usage: collect.sh <project config name> <db|source|full|sync>
#
#   db|source|full  Trigger the backup on the host, then pull all files that are not here yet.
#   sync            Only pull all files that are not here yet.
#
# Config: collector.conf and projects.d/<project config name>.conf next to this script.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
    echo "Usage: $(basename "$0") <project config name> <db|source|full|sync>" >&2
    exit 2
}

[ $# -eq 2 ] || usage
CONF_NAME=$1
ACTION=$2
case "$ACTION" in
    db|source|full|sync) ;;
    *) usage ;;
esac

RUN_LOG=$(mktemp)
LOG_FILE=""
STARTED=0
NEW_FILE=""
WARNINGS=""
SUMMARY=""

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$line" >&2
    echo "$line" >> "$RUN_LOG"
    if [ -n "$LOG_FILE" ]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

die() {
    log "ERROR: $*"
    exit 1
}

warn() {
    log "WARNING: $*"
    WARNINGS="${WARNINGS}$*; "
}

# --- Config -------------------------------------------------------------------

COLLECTOR_CONF=${COLLECTOR_CONF:-$SCRIPT_DIR/collector.conf}
PROJECT_CONF=${PROJECTS_DIR:-$SCRIPT_DIR/projects.d}/$CONF_NAME.conf
[ -f "$PROJECT_CONF" ] || die "Config file not found: $PROJECT_CONF"
if [ -f "$COLLECTOR_CONF" ]; then
    # shellcheck disable=SC1090
    . "$COLLECTOR_CONF"
fi
# shellcheck disable=SC1090
. "$PROJECT_CONF"

: "${HC_PING_BASE:=}"
: "${HC_AUTO_CREATE:=1}"
: "${REPORT_SLACK_WEBHOOK:=}"
: "${MIN_FREE_MB:=1024}"
: "${SIZE_DROP_LIMIT:=50}"
: "${SSH_PORT:=22}"
: "${SSH_OPTIONS:=}"
: "${KEEP_DAYS:=365}"
: "${KEEP_MIN:=7}"

[[ "${PROJECT:-}" =~ ^[A-Za-z0-9_-]+$ ]] || die "PROJECT must contain only letters, digits, _ and -"
[[ "${ENV:-}" =~ ^[A-Za-z0-9_-]+$ ]] || die "ENV must contain only letters, digits, _ and -"
for key in SSH_HOST SSH_USER SSH_KEY LOCAL_DIR; do
    [ -n "${!key:-}" ] || die "$key is not set in $PROJECT_CONF"
done
[ -f "$SSH_KEY" ] || die "SSH_KEY not found: $SSH_KEY"
for c in ssh sha256sum flock curl; do
    command -v "$c" > /dev/null 2>&1 || die "Command not found: $c"
done

umask 077
mkdir -p "$LOCAL_DIR"
LOCAL_DIR=$(cd "$LOCAL_DIR" && pwd -P)
LOG_FILE="$LOCAL_DIR/collect.log"

PREFIX="${PROJECT}_${ENV}_"
NAME_PATTERN="^${PREFIX}(db|source|full)_[0-9]{8}_[0-9]{6}(_[A-Za-z0-9_-]+)?\.zip$"
SLUG="${PROJECT}-${ENV}-${ACTION}"
SLUG=${SLUG,,}
RID=$(cat /proc/sys/kernel/random/uuid 2> /dev/null || true)

# --- Reporting ----------------------------------------------------------------

hc_ping() {
    local suffix=$1 url
    [ -n "$HC_PING_BASE" ] || return 0
    url="${HC_PING_BASE%/}/$SLUG$suffix?create=$HC_AUTO_CREATE"
    if [ -n "$RID" ]; then
        url="$url&rid=$RID"
    fi
    tail -c 90000 "$RUN_LOG" | curl -fsS -m 30 --retry 3 -o /dev/null --data-binary @- "$url" \
        || log "WARNING: Cannot ping Healthchecks ($SLUG$suffix)"
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

slack_report() {
    [ -n "$REPORT_SLACK_WEBHOOK" ] || return 0
    curl -fsS -m 20 --retry 2 -o /dev/null -H 'Content-Type: application/json' \
        --data "{\"text\": \"$(json_escape "$1")\"}" "$REPORT_SLACK_WEBHOOK" \
        || log "WARNING: Cannot send report to Slack"
}

finish() {
    local rc=$?
    rm -f "$LOCAL_DIR"/*.part
    if [ "$STARTED" = 1 ]; then
        if [ $rc -eq 0 ]; then
            log "RESULT: OK. $SUMMARY${WARNINGS:+ WARNINGS: $WARNINGS}"
            hc_ping ""
            slack_report "[backup] $PROJECT $ENV $ACTION: OK. $SUMMARY${WARNINGS:+ WARNINGS: $WARNINGS}"
        else
            log "RESULT: FAILED. $SUMMARY"
            hc_ping "/fail"
            slack_report "[backup] $PROJECT $ENV $ACTION: FAILED. $(grep 'ERROR:' "$RUN_LOG" | tail -n 1)"
        fi
    fi
    rm -f "$RUN_LOG"
}
trap finish EXIT

# --- Functions ----------------------------------------------------------------

remote() {
    local -a opts=()
    if [ -n "$SSH_OPTIONS" ]; then
        read -r -a opts <<< "$SSH_OPTIONS"
    fi
    ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=20 \
        -o ServerAliveInterval=60 -o ServerAliveCountMax=5 ${opts[@]+"${opts[@]}"} \
        "$SSH_USER@$SSH_HOST" "$@"
}

file_size() {
    stat -c %s "$1"
}

human() {
    numfmt --to=iec --suffix=B "$1" 2> /dev/null || echo "$1 bytes"
}

check_free_space() {
    local free
    free=$(df -Pm "$LOCAL_DIR" | awk 'NR==2 {print $4}')
    [ "$free" -ge "$MIN_FREE_MB" ] || die "Free space of $LOCAL_DIR is ${free}MB, less than ${MIN_FREE_MB}MB"
}

fetch_error() {
    log "ERROR: $*"
    return 1
}

# Pull a file, verify its checksum. Return 1 when the file cannot be pulled.
fetch() {
    local name=$1 expected actual
    check_free_space
    remote "get $name.sha256" > "$LOCAL_DIR/$name.sha256.part" 2>> "$RUN_LOG" \
        || { fetch_error "Cannot get $name.sha256"; return 1; }
    expected=$(cut -d' ' -f1 "$LOCAL_DIR/$name.sha256.part")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { fetch_error "Invalid checksum file: $name.sha256"; return 1; }
    remote "get $name" > "$LOCAL_DIR/$name.part" 2>> "$RUN_LOG" \
        || { fetch_error "Cannot get $name"; return 1; }
    actual=$(sha256sum < "$LOCAL_DIR/$name.part" | cut -d' ' -f1)
    [ "$expected" = "$actual" ] || { fetch_error "Checksum of $name does not match"; return 1; }
    mv "$LOCAL_DIR/$name.part" "$LOCAL_DIR/$name"
    mv "$LOCAL_DIR/$name.sha256.part" "$LOCAL_DIR/$name.sha256"
    log "Pulled: $name ($(human "$(file_size "$LOCAL_DIR/$name")"))"
}

# Pull all finished files of the host that are not here yet.
# A file that cannot be pulled does not stop the others.
sync_files() {
    local name list count=0 errors=0
    list=$(remote list 2>> "$RUN_LOG") || die "Cannot list backup files of the host"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [[ "$name" =~ $NAME_PATTERN ]] || { warn "Ignored unexpected file name from host: $name"; continue; }
        if [ -f "$LOCAL_DIR/$name" ] && [ -f "$LOCAL_DIR/$name.sha256" ]; then
            continue
        fi
        if fetch "$name"; then
            count=$((count + 1))
        else
            errors=$((errors + 1))
            rm -f "$LOCAL_DIR/$name.part" "$LOCAL_DIR/$name.sha256.part"
        fi
    done <<< "$list"
    log "Pulled $count file(s)."
    PULL_ERRORS=$errors
}

# List files here, oldest first. $1: type, $2: "auto" to list not labeled files only.
list_local() {
    local type=$1 auto=${2:-} f
    for f in "$LOCAL_DIR/$PREFIX${type}_"*.zip; do
        [ -f "$f" ] && [ -f "$f.sha256" ] || continue
        f=${f##*/}
        if [ "$auto" = auto ]; then
            [[ "$f" =~ ^${PREFIX}${type}_[0-9]{8}_[0-9]{6}\.zip$ ]] || continue
        else
            [[ "$f" =~ $NAME_PATTERN ]] || continue
        fi
        echo "$f"
    done | sort
}

# Compare size of the new file with the previous one of the same type.
check_size() {
    local name=$1 prev="" f size prev_size percent
    while IFS= read -r f; do
        [ "$f" != "$name" ] || break
        prev=$f
    done < <(list_local "$ACTION" auto)
    size=$(file_size "$LOCAL_DIR/$name")
    SUMMARY="$name, $(human "$size")"
    [ -n "$prev" ] || return 0
    prev_size=$(file_size "$LOCAL_DIR/$prev")
    [ "$prev_size" -gt 0 ] || return 0
    percent=$(( (size - prev_size) * 100 / prev_size ))
    SUMMARY="$SUMMARY ($(printf '%+d' "$percent")% compared to $prev)"
    if [ "$SIZE_DROP_LIMIT" -gt 0 ] && [ "$percent" -lt "-$SIZE_DROP_LIMIT" ]; then
        die "Size of $name dropped ${percent#-}% compared to $prev ($(human "$size") / $(human "$prev_size"))"
    fi
}

# Delete automatic (not labeled) backups older than KEEP_DAYS, keep at least KEEP_MIN of each type.
prune() {
    local cutoff t f count
    cutoff=$(date -d "-$KEEP_DAYS days" '+%Y%m%d')
    for t in db source full; do
        local -a files=()
        while IFS= read -r f; do
            files+=("$f")
        done < <(list_local "$t" auto)
        count=${#files[@]}
        for f in ${files[@]+"${files[@]}"}; do
            [ "$count" -gt "$KEEP_MIN" ] || break
            [[ "$f" =~ _([0-9]{8})_[0-9]{6}\.zip$ ]]
            [ "${BASH_REMATCH[1]}" -lt "$cutoff" ] || break
            rm -f "$LOCAL_DIR/$f.sha256" "$LOCAL_DIR/$f"
            log "Deleted old backup: $f"
            count=$((count - 1))
        done
    done
}

# --- Main ---------------------------------------------------------------------

exec 9> "$LOCAL_DIR/.collect.lock"
flock -w 3600 9 || die "Another collect.sh of this project is running"

STARTED=1
log "Start: $PROJECT $ENV $ACTION (host: $SSH_HOST)"
hc_ping "/start"
check_free_space

if [ "$ACTION" != sync ]; then
    ERR_FILE=$(mktemp)
    RC=0
    OUTPUT=$(remote "backup $ACTION" 2> "$ERR_FILE") || RC=$?
    cat "$ERR_FILE" >> "$RUN_LOG"
    cat "$ERR_FILE" >> "$LOG_FILE"
    if grep -q 'WARNING:' "$ERR_FILE"; then
        WARNINGS="${WARNINGS}host reported warnings, see log; "
    fi
    rm -f "$ERR_FILE"
    [ $RC -eq 0 ] || die "Backup on host failed (exit code $RC)"
    NEW_FILE=$(printf '%s\n' "$OUTPUT" | tail -n 1)
    [[ "$NEW_FILE" =~ $NAME_PATTERN ]] || die "Unexpected answer from host: $NEW_FILE"
    log "Host created: $NEW_FILE"
fi

PULL_ERRORS=0
sync_files

if [ -n "$NEW_FILE" ]; then
    [ -f "$LOCAL_DIR/$NEW_FILE" ] || die "$NEW_FILE was not pulled"
    check_size "$NEW_FILE"
fi
[ "$PULL_ERRORS" -eq 0 ] || die "$PULL_ERRORS file(s) could not be pulled"

prune
