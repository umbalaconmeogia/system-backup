#!/usr/bin/env bash
#
# Restore database from a backup.
#
# Usage: restore.sh [--config FILE] [--as-is] [--yes] <backup directory | zip file | sql file>
#
# The target database is defined by the config file of the environment that runs this script,
# not by the backup. The backup file itself is never modified.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [--config FILE] [--as-is] [--yes] <backup directory | zip file | sql file>

  --config FILE   Config file (default: backup.conf next to this script).
  --as-is         Restore the dump as it is (to rebuild the original server).
                  By default, the dump is adjusted to be restored into another environment:
                    MySQL: DEFINER is replaced by CURRENT_USER.
                    PostgreSQL: OWNER TO, GRANT, REVOKE statements are skipped.
  --yes           Do not ask for confirmation.
EOF
    exit 2
}

CONFIG="$SCRIPT_DIR/backup.conf"
AS_IS=0
YES=0
INPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
        --as-is) AS_IS=1; shift ;;
        --yes) YES=1; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown argument: $1" >&2; usage ;;
        *) [ -z "$INPUT" ] || usage; INPUT=$1; shift ;;
    esac
done
[ -n "$INPUT" ] || usage

load_config "$CONFIG"
check_db_config

TMP_DIR=""
cleanup() {
    if [ -n "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

SQL_FILE=""
MANIFEST=""
if [ -d "$INPUT" ]; then
    SQL_FILE="$INPUT/db.sql"
    MANIFEST="$INPUT/manifest.txt"
elif [[ "$INPUT" == *.zip ]]; then
    require_cmd unzip
    [ -f "$INPUT" ] || die "File not found: $INPUT"
    TMP_DIR=$(mktemp -d)
    TOP=$(unzip -Z1 "$INPUT" | head -n 1 | cut -d/ -f1)
    unzip -q "$INPUT" "$TOP/db.sql" "$TOP/manifest.txt" -d "$TMP_DIR" || die "Cannot extract db.sql from $INPUT"
    SQL_FILE="$TMP_DIR/$TOP/db.sql"
    MANIFEST="$TMP_DIR/$TOP/manifest.txt"
else
    SQL_FILE=$INPUT
fi
[ -f "$SQL_FILE" ] || die "SQL file not found: $SQL_FILE"

if [ -f "$MANIFEST" ]; then
    SRC_DB_TYPE=$(sed -n 's/^db_type=//p' "$MANIFEST")
    if [ -n "$SRC_DB_TYPE" ] && [ "$SRC_DB_TYPE" != "$DB_TYPE" ]; then
        die "Backup is of $SRC_DB_TYPE, but DB_TYPE in config is $DB_TYPE"
    fi
    log "Backup: $(sed -n 's/^name=//p' "$MANIFEST") (created at $(sed -n 's/^created_at=//p' "$MANIFEST"))"
fi

log "Target: $DB_TYPE database \"$DB_NAME\" (credential: $DB_CREDENTIAL_FILE)"
if [ "$YES" != 1 ]; then
    read -r -p "All data of database \"$DB_NAME\" will be replaced. Continue? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) log "Canceled."; exit 1 ;;
    esac
fi

# Output the dump, adjusted for restoring.
mysql_filter() {
    # The first line of dumps created by mariadb-dump is not understood by mysql client.
    local -a script=(-e '1{/enable the sandbox mode/d}')
    if [ "$AS_IS" != 1 ]; then
        script+=(-e 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g')
    fi
    LC_ALL=C sed -E "${script[@]}" "$SQL_FILE"
}

pgsql_filter() {
    if [ "$AS_IS" = 1 ]; then
        cat "$SQL_FILE"
    else
        LC_ALL=C sed -E -e '/^ALTER [^;]* OWNER TO [^;]*;$/d' -e '/^(GRANT|REVOKE) [^;]*;$/d' "$SQL_FILE"
    fi
}

case "$DB_TYPE" in
    mysql)
        CMD=$(first_cmd mysql mariadb)
        "$CMD" --defaults-extra-file="$DB_CREDENTIAL_FILE" \
            -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4"
        mysql_filter | "$CMD" --defaults-extra-file="$DB_CREDENTIAL_FILE" --default-character-set=utf8mb4 "$DB_NAME"
        ;;
    pgsql)
        require_cmd psql
        pg_conn_args
        pgsql_filter | PGPASSFILE="$DB_CREDENTIAL_FILE" psql "${PG_ARGS[@]}" -d "$DB_NAME" -q -v ON_ERROR_STOP=1 > /dev/null
        ;;
esac

log "Restore finished: $DB_NAME"
