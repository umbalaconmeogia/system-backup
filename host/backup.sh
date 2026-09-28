#!/usr/bin/env bash
#
# Create a backup of database and/or source code into a zip file.
#
# Usage: backup.sh [--config FILE] [--label TEXT] [--if-missing] <db|source|full>
#
# On success, the name of the created zip file is printed to stdout (nothing else is).
# All messages go to stderr and to BACKUP_DIR/backup.log.

set -euo pipefail

VERSION=1.0.0
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [--config FILE] [--label TEXT] [--if-missing] <db|source|full>

  db            Backup database only.
  source        Backup source directory only.
  full          Backup database and source directory.

  --config FILE Config file (default: backup.conf next to this script).
  --label TEXT  Text appended to the file name. Labeled backups are never deleted automatically.
  --if-missing  Do nothing if a backup of today already exists.
                Used by the fallback cron job, sends notification when a backup is created.
EOF
    exit 2
}

CONFIG="$SCRIPT_DIR/backup.conf"
LABEL=""
IF_MISSING=0
TYPE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
        --label) [ $# -ge 2 ] || usage; LABEL=$2; shift 2 ;;
        --if-missing) IF_MISSING=1; shift ;;
        -h|--help) usage ;;
        db|source|full) TYPE=$1; shift ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done
[ -n "$TYPE" ] || usage
if [ -n "$LABEL" ] && ! [[ "$LABEL" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Label must contain only letters, digits, _ and -" >&2
    exit 2
fi

umask 077
load_config "$CONFIG"

mkdir -p "$BACKUP_DIR"
BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd -P)
LOG_FILE="$BACKUP_DIR/backup.log"
WORK_ROOT="$BACKUP_DIR/.work"

NEED_DB=0
NEED_SOURCE=0
case "$TYPE" in
    db) NEED_DB=1 ;;
    source) NEED_SOURCE=1 ;;
    full) NEED_SOURCE=1; [ "$DB_TYPE" = "none" ] || NEED_DB=1 ;;
esac

require_cmd zip unzip sha256sum flock
if [ "$NEED_DB" = 1 ]; then
    check_db_config
fi
if [ "$NEED_SOURCE" = 1 ]; then
    [ -n "$SOURCE_DIR" ] || die "SOURCE_DIR is not set"
    [ -d "$SOURCE_DIR" ] || die "SOURCE_DIR not found: $SOURCE_DIR"
    SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd -P)
    case "$BACKUP_DIR/" in
        "$SOURCE_DIR/"*) die "BACKUP_DIR ($BACKUP_DIR) must be outside of SOURCE_DIR ($SOURCE_DIR)" ;;
    esac
    case "$SOURCE_DIR/" in
        "$BACKUP_DIR/"*) die "SOURCE_DIR ($SOURCE_DIR) must be outside of BACKUP_DIR ($BACKUP_DIR)" ;;
    esac
    SOURCE_NAME=${SOURCE_DIR##*/}
    [ -n "$SOURCE_NAME" ] || die "SOURCE_DIR must not be the root directory"
fi

# Only one backup of a project at a time.
exec 9> "$BACKUP_DIR/.backup.lock"
flock -n 9 || die "Another backup is running"

# With --if-missing, a "full" backup of today covers "db" and "source".
if [ "$IF_MISSING" = 1 ]; then
    today=$(date '+%Y%m%d')
    for t in "$TYPE" full; do
        if list_finished "$t" | grep -q "^${PROJECT}_${ENV}_${t}_${today}_"; then
            log "Backup ($t) of $today exists, nothing to do."
            exit 0
        fi
    done
    log "No backup of $today found, creating one (fallback)."
fi

NAME="${PROJECT}_${ENV}_${TYPE}_$(date '+%Y%m%d_%H%M%S')"
if [ -n "$LABEL" ]; then
    NAME="${NAME}_${LABEL}"
fi
WORK="$WORK_ROOT/$NAME"
LINK_DIR="$WORK_ROOT/$NAME.link"
ZIP_FILE="$BACKUP_DIR/$NAME.zip"
WARNINGS=0

cleanup() {
    local rc=$?
    set +e
    # $LINK_DIR contains a symbolic link to the parent of SOURCE_DIR. Remove the link itself first.
    if [ -L "$LINK_DIR/$NAME" ]; then
        rm -f "$LINK_DIR/$NAME"
    fi
    rm -rf "$WORK" "$LINK_DIR" "$WORK_ROOT/$NAME.err"
    rm -f "$ZIP_FILE.part" "$ZIP_FILE.sha256.part"
    if [ $rc -ne 0 ]; then
        log "Backup FAILED: $NAME"
        if [ "$IF_MISSING" = 1 ]; then
            notify "[backup] $PROJECT $ENV: fallback backup FAILED on $(hostname)" \
                "Backup server did not trigger the backup today, and the fallback backup failed. See $LOG_FILE"
        fi
    fi
}
trap cleanup EXIT

log "Start backup: $NAME"
mkdir -p "$WORK"

dump_db() {
    local out="$WORK/db.sql" err="$WORK_ROOT/$NAME.err" rc=0 cmd
    local -a opts
    case "$DB_TYPE" in
        mysql)
            cmd=$(first_cmd mysqldump mariadb-dump)
            opts=(--single-transaction --routines --triggers --events --no-tablespaces --default-character-set=utf8mb4)
            if [ -n "$DB_DUMP_OPTIONS" ]; then
                read -r -a opts <<< "$DB_DUMP_OPTIONS"
            fi
            "$cmd" --defaults-extra-file="$DB_CREDENTIAL_FILE" "${opts[@]}" "$DB_NAME" > "$out" 2> "$err" || rc=$?
            ;;
        pgsql)
            require_cmd pg_dump
            opts=(--format=plain --clean --if-exists)
            if [ -n "$DB_DUMP_OPTIONS" ]; then
                read -r -a opts <<< "$DB_DUMP_OPTIONS"
            fi
            pg_conn_args
            PGPASSFILE="$DB_CREDENTIAL_FILE" pg_dump "${PG_ARGS[@]}" "${opts[@]}" "$DB_NAME" > "$out" 2> "$err" || rc=$?
            ;;
    esac
    if [ -s "$err" ]; then
        while IFS= read -r line; do log "dump: $line"; done < "$err"
    fi
    [ $rc -eq 0 ] || die "Database dump failed (exit code $rc)"
    [ -s "$out" ] || die "Database dump is empty"
    log "Database dumped: $(du -h "$out" | cut -f1)"
}

write_manifest() {
    cat > "$WORK/manifest.txt" <<EOF
name=$NAME
project=$PROJECT
env=$ENV
type=$TYPE
label=$LABEL
created_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
hostname=$(hostname)
db_type=$( [ "$NEED_DB" = 1 ] && echo "$DB_TYPE" || echo none )
db_name=$( [ "$NEED_DB" = 1 ] && echo "$DB_NAME" || true )
source_dir=${SOURCE_DIR:-}
source_name=${SOURCE_NAME:-}
script_version=$VERSION
EOF
}

create_zip() {
    local rc=0 parent
    local -a items=("$NAME/manifest.txt")
    if [ "$NEED_DB" = 1 ]; then
        items+=("$NAME/db.sql")
    fi
    (cd "$WORK_ROOT" && zip -q "$ZIP_FILE.part" "${items[@]}") >&2 || die "zip failed (exit code $?)"
    if [ "$NEED_SOURCE" = 1 ]; then
        # The source directory is added to the zip file without being copied:
        # <LINK_DIR>/<NAME> is a symbolic link to the parent directory of SOURCE_DIR,
        # so <NAME>/<SOURCE_NAME> is the source directory itself.
        # Symbolic links inside the source directory are stored as links (-y).
        parent=${SOURCE_DIR%/*}
        mkdir -p "$LINK_DIR"
        ln -s "${parent:-/}" "$LINK_DIR/$NAME"
        (cd "$LINK_DIR" && zip -r -y -q "$ZIP_FILE.part" "$NAME/$SOURCE_NAME") >&2 || rc=$?
        if [ $rc -eq 18 ]; then
            # Some files could not be read (no permission, or removed while zipping).
            WARNINGS=1
            log "WARNING: zip could not read some files, the backup may be incomplete."
        elif [ $rc -ne 0 ]; then
            die "zip failed (exit code $rc)"
        fi
    fi
    unzip -tq "$ZIP_FILE.part" > /dev/null || die "Created zip file is broken"
    mv "$ZIP_FILE.part" "$ZIP_FILE"
    # .sha256 is written last, it marks the backup as finished.
    (cd "$BACKUP_DIR" && sha256sum "$NAME.zip") > "$ZIP_FILE.sha256.part"
    mv "$ZIP_FILE.sha256.part" "$ZIP_FILE.sha256"
    log "Created: $ZIP_FILE ($(du -h "$ZIP_FILE" | cut -f1))"
}

# Delete automatic (not labeled) backups older than KEEP_DAYS, keep at least KEEP_MIN of each type.
prune() {
    local cutoff t f stamp count
    cutoff=$(date -d "-$KEEP_DAYS days" '+%Y%m%d')
    for t in db source full; do
        local -a files=()
        while IFS= read -r f; do
            [[ "$f" =~ ^${PROJECT}_${ENV}_${t}_([0-9]{8})_[0-9]{6}\.zip$ ]] && files+=("$f")
        done < <(list_finished "$t")
        count=${#files[@]}
        for f in ${files[@]+"${files[@]}"}; do
            [ "$count" -gt "$KEEP_MIN" ] || break
            [[ "$f" =~ _([0-9]{8})_[0-9]{6}\.zip$ ]]
            stamp=${BASH_REMATCH[1]}
            [ "$stamp" -lt "$cutoff" ] || break
            rm -f "$BACKUP_DIR/$f.sha256" "$BACKUP_DIR/$f"
            log "Deleted old backup: $f"
            count=$((count - 1))
        done
    done
}

if [ "$NEED_DB" = 1 ]; then
    dump_db
fi
write_manifest
create_zip
prune

if [ "$IF_MISSING" = 1 ]; then
    notify "[backup] $PROJECT $ENV: fallback backup created on $(hostname)" \
        "Backup server did not trigger the backup today. Created $NAME.zip locally."
fi
if [ "$WARNINGS" = 1 ]; then
    log "Backup finished with WARNINGS: $NAME"
else
    log "Backup finished: $NAME"
fi
echo "$NAME.zip"
