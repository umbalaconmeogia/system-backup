#!/usr/bin/env bash
#
# Restore database from a backup.
#
# Usage: restore.sh [--config FILE] [--as-is] [--yes] <backup directory | zip file | zip.gpg file | sql file>
#
# The target database is defined by the config file of the environment that runs this script,
# not by the backup. The backup file itself is never modified.
# A .zip.gpg file is decrypted with gpg: the private key must be in the keyring of the user.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [--config FILE] [--as-is] [--yes] <backup directory | zip file | zip.gpg file | sql file>

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

TMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SQL_FILE=""
MANIFEST=""
ZIP=""
if [ -d "$INPUT" ]; then
    SQL_FILE="$INPUT/db.sql"
    MANIFEST="$INPUT/manifest.txt"
elif [[ "$INPUT" == *.zip.gpg ]]; then
    require_cmd gpg
    [ -f "$INPUT" ] || die "File not found: $INPUT"
    ZIP="$TMP_DIR/backup.zip"
    # Not in batch mode: gpg asks for the passphrase of the private key.
    gpg --quiet --output "$ZIP" --decrypt "$INPUT" \
        || die "Cannot decrypt $INPUT. Import the private key first: gpg --import <private key file>"
elif [[ "$INPUT" == *.zip ]]; then
    [ -f "$INPUT" ] || die "File not found: $INPUT"
    ZIP=$INPUT
else
    SQL_FILE=$INPUT
fi
if [ -n "$ZIP" ]; then
    require_cmd unzip
    # awk reads the whole list. With head, unzip is killed by SIGPIPE when the list is long,
    # and the script stops without any message (pipefail).
    TOP=$(unzip -Z1 "$ZIP" | awk -F/ 'NR == 1 {print $1}')
    unzip -q "$ZIP" "$TOP/db.sql" "$TOP/manifest.txt" -d "$TMP_DIR" || die "Cannot extract db.sql from $INPUT"
    SQL_FILE="$TMP_DIR/$TOP/db.sql"
    MANIFEST="$TMP_DIR/$TOP/manifest.txt"
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

ERR_FILE="$TMP_DIR/restore.err"
UCA1400_TO=""

# Output the dump, adjusted for restoring.
mysql_filter() {
    # The first line of dumps created by mariadb-dump is not understood by mysql client.
    local -a script=(-e '1{/enable the sandbox mode/d}')
    if [ "$AS_IS" != 1 ]; then
        script+=(-e 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g')
        # Routines and triggers of MariaDB keep this sql_mode, which was removed in MySQL 8.
        # It only affects GRANT statements, so it is safe to remove on any server.
        script+=(-e 's/(,NO_AUTO_CREATE_USER|NO_AUTO_CREATE_USER,?)//g')
    fi
    if [ "$UCA1400_TO" = 0900 ]; then
        script+=(-e 's/utf8mb4_uca1400_(nopad_)?(ai_ci|as_ci|as_cs)/utf8mb4_0900_\2/g')
    elif [ -n "$UCA1400_TO" ]; then
        script+=(-e "s/utf8mb4_uca1400_[a-z_]*_c[is]/$UCA1400_TO/g")
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

# Collations utf8mb4_uca1400_* (default of MariaDB 11.4 and later) do not exist on MySQL and older MariaDB.
# Choose the replacement when the target server does not have them.
choose_uca1400_replacement() {
    local found
    grep -q 'utf8mb4_uca1400_' "$SQL_FILE" || return 0
    found=$("$CMD" --defaults-extra-file="$DB_CREDENTIAL_FILE" -N -B -e \
        "SELECT COLLATION_NAME FROM information_schema.COLLATIONS WHERE COLLATION_NAME IN ('utf8mb4_uca1400_ai_ci', 'utf8mb4_0900_ai_ci')" \
        2> /dev/null) || return 0
    if grep -q uca1400 <<< "$found"; then
        return 0
    elif grep -q 0900 <<< "$found"; then
        UCA1400_TO=0900
        log "Collations utf8mb4_uca1400_* do not exist on the target server, they are replaced by utf8mb4_0900_*."
    else
        UCA1400_TO=utf8mb4_unicode_ci
        log "Collations utf8mb4_uca1400_* do not exist on the target server, they are replaced by utf8mb4_unicode_ci."
    fi
}

# Show errors of the client, with hints for the known ones.
report_mysql_error() {
    cat "$ERR_FILE" >&2
    if grep -q 'ERROR 1419' "$ERR_FILE"; then
        log "HINT: Binary logging is enabled on the target server, so only an administrator can create triggers and routines."
        log "HINT: Restore as an administrator (e.g. root), or run on the target server: SET GLOBAL log_bin_trust_function_creators = 1;"
    fi
    if grep -q 'ERROR 1227' "$ERR_FILE" && [ "$AS_IS" = 1 ]; then
        log "HINT: The definer in the dump cannot be used by this user. Restore without --as-is."
    fi
}

case "$DB_TYPE" in
    mysql)
        CMD=$(first_cmd mysql mariadb)
        # This fails when the user has no permission to create database, even if the database exists.
        "$CMD" --defaults-extra-file="$DB_CREDENTIAL_FILE" \
            -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4" 2> /dev/null \
            || log "Cannot create database \"$DB_NAME\", it is supposed to exist."
        if [ "$AS_IS" != 1 ]; then
            choose_uca1400_replacement
        fi
        if ! mysql_filter | "$CMD" --defaults-extra-file="$DB_CREDENTIAL_FILE" --default-character-set=utf8mb4 "$DB_NAME" 2> "$ERR_FILE"; then
            report_mysql_error
            die "Restore failed: $DB_NAME"
        fi
        cat "$ERR_FILE" >&2
        ;;
    pgsql)
        require_cmd psql
        pg_conn_args
        pgsql_filter | PGPASSFILE="$DB_CREDENTIAL_FILE" psql "${PG_ARGS[@]}" -d "$DB_NAME" -q -v ON_ERROR_STOP=1 > /dev/null \
            || die "Restore failed: $DB_NAME"
        ;;
esac

log "Restore finished: $DB_NAME"
