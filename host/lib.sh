# Common functions for host scripts. Sourced, not executed.

LOG_FILE=""

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$line" >&2
    if [ -n "$LOG_FILE" ]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

die() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" > /dev/null 2>&1 || die "Command not found: $c"
    done
}

# Load config file and apply default values.
load_config() {
    local conf=$1
    [ -f "$conf" ] || die "Config file not found: $conf"
    CONFIG_DIR=$(cd "$(dirname "$conf")" && pwd)
    # shellcheck disable=SC1090
    . "$conf"

    : "${DB_TYPE:=none}"
    : "${DB_NAME:=}"
    : "${DB_CREDENTIAL_FILE:=}"
    : "${DB_HOST:=localhost}"
    : "${DB_PORT:=}"
    : "${DB_USER:=}"
    : "${DB_DUMP_OPTIONS:=}"
    : "${SOURCE_DIR:=}"
    : "${KEEP_DAYS:=30}"
    : "${KEEP_MIN:=7}"
    : "${FAIL_ON_UNREADABLE:=1}"
    : "${ENCRYPT_PUBLIC_KEY_FILE:=}"
    : "${NOTIFY_SLACK_WEBHOOK:=}"
    : "${NOTIFY_MAIL:=}"

    [[ "${PROJECT:-}" =~ ^[A-Za-z0-9_-]+$ ]] || die "PROJECT must contain only letters, digits, _ and -"
    [[ "${ENV:-}" =~ ^[A-Za-z0-9_-]+$ ]] || die "ENV must contain only letters, digits, _ and -"
    [ -n "${BACKUP_DIR:-}" ] || die "BACKUP_DIR is not set"
    [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "KEEP_DAYS must be a number"
    [[ "$KEEP_MIN" =~ ^[0-9]+$ ]] || die "KEEP_MIN must be a number"
    case "$DB_TYPE" in
        mysql|pgsql|none) ;;
        *) die "DB_TYPE must be mysql, pgsql or none" ;;
    esac

    # Relative file paths are relative to the config file.
    if [ -n "$DB_CREDENTIAL_FILE" ] && [ "${DB_CREDENTIAL_FILE#/}" = "$DB_CREDENTIAL_FILE" ]; then
        DB_CREDENTIAL_FILE="$CONFIG_DIR/$DB_CREDENTIAL_FILE"
    fi
    if [ -n "$ENCRYPT_PUBLIC_KEY_FILE" ] && [ "${ENCRYPT_PUBLIC_KEY_FILE#/}" = "$ENCRYPT_PUBLIC_KEY_FILE" ]; then
        ENCRYPT_PUBLIC_KEY_FILE="$CONFIG_DIR/$ENCRYPT_PUBLIC_KEY_FILE"
    fi
}

check_db_config() {
    [ "$DB_TYPE" != "none" ] || die "DB_TYPE is none, there is no database to process"
    [ -n "$DB_NAME" ] || die "DB_NAME is not set"
    [ -f "$DB_CREDENTIAL_FILE" ] || die "DB_CREDENTIAL_FILE not found: $DB_CREDENTIAL_FILE"
    if [ "$DB_TYPE" = "pgsql" ]; then
        [ -n "$DB_USER" ] || die "DB_USER is not set"
    fi
}

# Print the first command that exists.
first_cmd() {
    local c
    for c in "$@"; do
        if command -v "$c" > /dev/null 2>&1; then
            echo "$c"
            return 0
        fi
    done
    die "Command not found: $*"
}

pg_conn_args() {
    PG_ARGS=(-h "$DB_HOST" -U "$DB_USER" --no-password)
    if [ -n "$DB_PORT" ]; then
        PG_ARGS+=(-p "$DB_PORT")
    fi
}

# List finished backup files (the ones that have .sha256) of this project, oldest first.
# Backup files are .zip, or .zip.gpg when encrypted.
# $1: type (db, source, full) or empty for all types.
list_finished() {
    local type=${1:-} f prefix
    prefix="${PROJECT}_${ENV}_"
    for f in "$BACKUP_DIR/$prefix"*.zip "$BACKUP_DIR/$prefix"*.zip.gpg; do
        [ -f "$f" ] && [ -f "$f.sha256" ] || continue
        f=${f##*/}
        if [ -n "$type" ]; then
            [[ "${f#"$prefix"}" =~ ^${type}_[0-9]{8}_[0-9]{6}(_.+)?\.zip(\.gpg)?$ ]] || continue
        else
            [[ "${f#"$prefix"}" =~ ^(db|source|full)_[0-9]{8}_[0-9]{6}(_.+)?\.zip(\.gpg)?$ ]] || continue
        fi
        echo "$f"
    done | sort
}

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

# Send a message to Slack and mail, if configured. Never fails.
notify() {
    local subject=$1 body=${2:-}
    if [ -n "$NOTIFY_SLACK_WEBHOOK" ] && command -v curl > /dev/null 2>&1; then
        curl -fsS -m 20 --retry 2 -o /dev/null -H 'Content-Type: application/json' \
            --data "{\"text\": \"$(json_escape "$subject"$'\n'"$body")\"}" \
            "$NOTIFY_SLACK_WEBHOOK" || log "WARNING: Cannot send Slack notification"
    fi
    if [ -n "$NOTIFY_MAIL" ] && command -v mail > /dev/null 2>&1; then
        printf '%s\n' "$body" | mail -s "$subject" "$NOTIFY_MAIL" || log "WARNING: Cannot send mail notification"
    fi
}
