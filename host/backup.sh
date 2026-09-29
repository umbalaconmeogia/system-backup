#!/usr/bin/env bash
#
# Create a backup of database and/or source code into a zip file.
# When ENCRYPT_PUBLIC_KEY_FILE is set, the zip file is encrypted with gpg (.zip.gpg).
#
# Usage: backup.sh [--config FILE] [--label TEXT] [--if-missing] <db|source|full>
#
# On success, the name of the created backup file is printed to stdout (nothing else is).
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
if [ -n "$ENCRYPT_PUBLIC_KEY_FILE" ]; then
    require_cmd gpg
    [ -r "$ENCRYPT_PUBLIC_KEY_FILE" ] \
        || die "ENCRYPT_PUBLIC_KEY_FILE not found, or user $(id -un) has no permission to read it: $ENCRYPT_PUBLIC_KEY_FILE"
fi
if [ "$NEED_DB" = 1 ]; then
    check_db_config
fi
if [ "$NEED_SOURCE" = 1 ]; then
    [ -n "$SOURCE_DIR" ] || die "SOURCE_DIR is not set"
    [ -d "$SOURCE_DIR" ] || die "SOURCE_DIR not found, or user $(id -un) has no permission to access it: $SOURCE_DIR"
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
BACKUP_FILE=$ZIP_FILE
if [ -n "$ENCRYPT_PUBLIC_KEY_FILE" ]; then
    BACKUP_FILE="$ZIP_FILE.gpg"
fi
WARNINGS=0

cleanup() {
    local rc=$?
    set +e
    # $LINK_DIR contains a symbolic link to the parent of SOURCE_DIR. Remove the link itself first.
    if [ -L "$LINK_DIR/$NAME" ]; then
        rm -f "$LINK_DIR/$NAME"
    fi
    rm -rf "$WORK" "$LINK_DIR" "$WORK_ROOT/$NAME.err"
    rm -f "$ZIP_FILE.part" "$BACKUP_FILE.part" "$BACKUP_FILE.sha256.part"
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

# Encrypt $1 into $2 with the public key. Only the owner of the private key can decrypt it.
# The zip file is already compressed, so gpg does not compress it again.
# The key is given as a file, it is not imported into the keyring of the user.
gpg_encrypt() {
    local err="$WORK_ROOT/$NAME.err" line
    if ! gpg --batch --yes --quiet --trust-model always --compress-algo none \
        --recipient-file "$ENCRYPT_PUBLIC_KEY_FILE" --output "$2" --encrypt "$1" 2> "$err"; then
        while IFS= read -r line; do log "gpg: $line"; done < "$err"
        die "Encryption with ENCRYPT_PUBLIC_KEY_FILE failed: $ENCRYPT_PUBLIC_KEY_FILE"
    fi
}

# Fail before the dump, which may take long, when the key cannot be used.
if [ -n "$ENCRYPT_PUBLIC_KEY_FILE" ]; then
    echo test > "$WORK/encrypt-test"
    gpg_encrypt "$WORK/encrypt-test" "$WORK/encrypt-test.gpg"
    rm -f "$WORK/encrypt-test" "$WORK/encrypt-test.gpg"
fi

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

# zip does not tell which files it could not read. List them (at most 20) in the log.
report_unreadable() {
    local list count
    list=$(find "$SOURCE_DIR" ! -type l \( ! -readable -o -type d ! -executable \) -print 2> /dev/null || true)
    count=$(grep -c . <<< "$list" || true)
    if [ "$count" -eq 0 ]; then
        log "No unreadable file found now. Some files may have been removed while zipping."
        return 0
    fi
    log "Cannot read $count file(s) or directory(ies) as user $(id -un):"
    head -n 20 <<< "$list" | while IFS= read -r f; do log "  $f"; done
    [ "$count" -le 20 ] || log "  ..."
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
            report_unreadable
            if [ "$FAIL_ON_UNREADABLE" = 1 ]; then
                die "zip could not read some files. Give the user $(id -un) permission to read them, or set FAIL_ON_UNREADABLE=0."
            fi
            WARNINGS=1
            log "WARNING: zip could not read some files, the backup is incomplete."
        elif [ $rc -ne 0 ]; then
            die "zip failed (exit code $rc)"
        fi
    fi
    unzip -tq "$ZIP_FILE.part" > /dev/null || die "Created zip file is broken"
    if [ "$BACKUP_FILE" = "$ZIP_FILE" ]; then
        mv "$ZIP_FILE.part" "$BACKUP_FILE"
    else
        gpg_encrypt "$ZIP_FILE.part" "$BACKUP_FILE.part"
        rm -f "$ZIP_FILE.part"
        mv "$BACKUP_FILE.part" "$BACKUP_FILE"
    fi
    # .sha256 is written last, it marks the backup as finished.
    (cd "$BACKUP_DIR" && sha256sum "${BACKUP_FILE##*/}") > "$BACKUP_FILE.sha256.part"
    mv "$BACKUP_FILE.sha256.part" "$BACKUP_FILE.sha256"
    log "Created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
}

# Delete automatic (not labeled) backups older than KEEP_DAYS, keep at least KEEP_MIN of each type.
prune() {
    local cutoff t f stamp count
    cutoff=$(date -d "-$KEEP_DAYS days" '+%Y%m%d')
    for t in db source full; do
        local -a files=()
        while IFS= read -r f; do
            [[ "$f" =~ ^${PROJECT}_${ENV}_${t}_([0-9]{8})_[0-9]{6}\.zip(\.gpg)?$ ]] && files+=("$f")
        done < <(list_finished "$t")
        count=${#files[@]}
        for f in ${files[@]+"${files[@]}"}; do
            [ "$count" -gt "$KEEP_MIN" ] || break
            [[ "$f" =~ _([0-9]{8})_[0-9]{6}\.zip(\.gpg)?$ ]]
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
        "Backup server did not trigger the backup today. Created ${BACKUP_FILE##*/} locally."
fi
if [ "$WARNINGS" = 1 ]; then
    log "Backup finished with WARNINGS: $NAME"
else
    log "Backup finished: $NAME"
fi
echo "${BACKUP_FILE##*/}"
