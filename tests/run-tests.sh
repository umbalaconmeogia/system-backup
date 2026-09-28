#!/usr/bin/env bash
#
# Test host and collector scripts on one machine.
# Database commands, ssh and curl are replaced by stubs, so no database, no network is needed.
# Requires: bash, zip, unzip, sha256sum, flock.
#
# Usage: tests/run-tests.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
chmod +x "$ROOT"/host/*.sh "$ROOT"/collector/*.sh

PASSED=0
FAILED=0

ok() {
    PASSED=$((PASSED + 1))
    echo "  ok   $1"
}

# Output of the checked command is shown when the check fails.
ng() {
    FAILED=$((FAILED + 1))
    echo "  FAIL $1"
    if [ -s "$T/output" ]; then
        tail -n 20 "$T/output" | sed 's/^/       | /'
    fi
}

# check <description> <command...>: passes when the command succeeds.
check() {
    local desc=$1
    shift
    if "$@" > "$T/output" 2>&1; then ok "$desc"; else ng "$desc"; fi
}

# check_not <description> <command...>: passes when the command fails.
check_not() {
    local desc=$1
    shift
    if "$@" > "$T/output" 2>&1; then ng "$desc"; else ok "$desc"; fi
}

count_files() {
    find "$1" -maxdepth 1 -name "$2" | wc -l | tr -d ' '
}

# --- Stubs --------------------------------------------------------------------

mkdir -p "$T/bin" "$T/src/app/sub" "$T/collector/projects.d"
export TEST_DIR=$T
export TEST_ROOT=$ROOT

cat > "$T/bin/mysqldump" <<'EOF'
#!/usr/bin/env bash
if [ -f "$TEST_DIR/dump_fail" ]; then
    echo "mysqldump: Got error: 1045: Access denied" >&2
    exit 2
fi
echo '/*!999999\- enable the sandbox mode */'
echo 'CREATE TABLE `t` (`id` int);'
echo '/*!50013 DEFINER=`admin`@`10.0.0.%` SQL SECURITY DEFINER */'
if [ -f "$TEST_DIR/dump_small" ]; then
    exit 0
fi
for i in $(seq 1 2000); do
    echo "INSERT INTO \`t\` VALUES ($i, '$RANDOM$RANDOM$RANDOM$RANDOM');"
done
EOF

cat > "$T/bin/mysql" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/mysql.args"
case "$*" in
    *" -e "*) ;;
    *) cat > "$TEST_DIR/mysql.stdin" ;;
esac
EOF

# ssh: run the forced command locally, as sshd does with command="..." in authorized_keys.
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [ -f "$TEST_DIR/ssh_fail" ]; then
    echo "ssh: connect to host: Connection timed out" >&2
    exit 255
fi
SSH_ORIGINAL_COMMAND="${*: -1}" exec "$TEST_ROOT/host/ssh-gate.sh" "$TEST_DIR/backup.conf"
EOF

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "${*: -1}" >> "$TEST_DIR/curl.log"
EOF

chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

echo "hello" > "$T/src/app/index.php"
echo "sub" > "$T/src/app/sub/file.txt"
ln -s index.php "$T/src/app/link.php"

cat > "$T/backup.conf" <<EOF
PROJECT=demo
ENV=prod
BACKUP_DIR=$T/backup
DB_TYPE=mysql
DB_NAME=demo_db
DB_CREDENTIAL_FILE=my.cnf
SOURCE_DIR=$T/src/app
KEEP_DAYS=30
KEEP_MIN=2
NOTIFY_SLACK_WEBHOOK=https://slack.example.com/host-webhook
EOF
echo "[client]" > "$T/my.cnf"

cat > "$T/collector/collector.conf" <<EOF
HC_PING_BASE=https://hc.example.com/ping/key
MIN_FREE_MB=1
SIZE_DROP_LIMIT=50
EOF
cat > "$T/collector/projects.d/demo.conf" <<EOF
PROJECT=demo
ENV=prod
SSH_HOST=host.example.com
SSH_USER=backup
SSH_KEY=$T/key
LOCAL_DIR=$T/collected
KEEP_DAYS=365
KEEP_MIN=2
EOF
touch "$T/key"
export COLLECTOR_CONF="$T/collector/collector.conf"
export PROJECTS_DIR="$T/collector/projects.d"

BACKUP="$ROOT/host/backup.sh --config $T/backup.conf"
GATE="$ROOT/host/ssh-gate.sh $T/backup.conf"
COLLECT="$ROOT/collector/collect.sh"
B=$T/backup

# Wait until the next second, so that names of backups are different.
next_second() {
    sleep 1
}

# --- backup.sh ----------------------------------------------------------------

echo "backup.sh db"
OUT=$($BACKUP db 2> "$T/err")
NAME=${OUT%.zip}
check "stdout is the file name only" test "$(echo "$OUT" | wc -l | tr -d ' ')" = 1
check "name follows the convention" grep -Eq '^demo_prod_db_[0-9]{8}_[0-9]{6}\.zip$' <<< "$OUT"
check "zip file exists" test -f "$B/$OUT"
check "checksum is correct" bash -c "cd '$B' && sha256sum -c '$OUT.sha256'"
unzip -Z1 "$B/$OUT" > "$T/list"
check "zip has <name>/db.sql" grep -qx "$NAME/db.sql" "$T/list"
check "zip has <name>/manifest.txt" grep -qx "$NAME/manifest.txt" "$T/list"
check "zip has nothing outside <name>/" test -z "$(grep -v "^$NAME/" "$T/list")"
check "work directory is removed" test -z "$(ls -A "$B/.work")"
check "no .part file remains" test "$(count_files "$B" '*.part')" = 0

echo "backup.sh full"
next_second
OUT=$($BACKUP full 2> "$T/err")
NAME=${OUT%.zip}
unzip -Z1 "$B/$OUT" > "$T/list"
check "zip has database" grep -qx "$NAME/db.sql" "$T/list"
check "zip has source files" grep -qx "$NAME/app/sub/file.txt" "$T/list"
check "zip has the symbolic link" grep -qx "$NAME/app/link.php" "$T/list"
if unzip -Z "$B/$OUT" "$NAME/app/link.php" 2> /dev/null | grep -q '^l'; then
    ok "symbolic link is stored as link"
else
    : > "$T/output"; ng "symbolic link is stored as link"
fi
mkdir -p "$T/extract"
(cd "$T/extract" && unzip -q "$B/$OUT")
check "extracted file is same as source" cmp "$T/src/app/sub/file.txt" "$T/extract/$NAME/app/sub/file.txt"
check "source directory is untouched" test -f "$T/src/app/index.php"
check "manifest has type" grep -qx "type=full" "$T/extract/$NAME/manifest.txt"

echo "backup.sh source, label"
next_second
OUT=$($BACKUP source --label before_release 2> "$T/err")
check "label is in the name" grep -Eq '^demo_prod_source_[0-9]{8}_[0-9]{6}_before_release\.zip$' <<< "$OUT"
check_not "zip has no database" bash -c "unzip -Z1 '$B/$OUT' | grep -q 'db.sql'"
check_not "invalid label is refused" $BACKUP db --label "a/b"

echo "backup.sh errors"
touch "$T/dump_fail"
BEFORE=$(count_files "$B" '*.zip')
check_not "fails when dump fails" $BACKUP db
check "no zip is created" test "$(count_files "$B" '*.zip')" = "$BEFORE"
check "no .part file remains" test "$(count_files "$B" '*.part')" = 0
check "error of dump is logged" grep -q "Access denied" "$B/backup.log"
rm "$T/dump_fail"
sed "s|^BACKUP_DIR=.*|BACKUP_DIR=$T/src/app/backup|" "$T/backup.conf" > "$T/bad.conf"
cp "$T/my.cnf" "$T/src/app/" 2> /dev/null
check_not "BACKUP_DIR inside SOURCE_DIR is refused" "$ROOT/host/backup.sh" --config "$T/bad.conf" full
rm -rf "$T/src/app/backup" "$T/src/app/my.cnf"

echo "backup.sh prune"
fake() {
    echo "fake" > "$B/$1"
    (cd "$B" && sha256sum "$1" > "$1.sha256")
}
fake demo_prod_db_20200101_010000.zip
fake demo_prod_db_20200102_010000.zip
fake demo_prod_db_20200103_010000_keep_me.zip
fake demo_prod_full_20200101_010000.zip
fake other_prod_db_20200101_010000.zip
touch "$B/demo_prod_db_20200104_010000.zip"
next_second
$BACKUP db > /dev/null 2>&1
check_not "old backup is deleted" test -f "$B/demo_prod_db_20200101_010000.zip"
check_not "checksum of old backup is deleted" test -f "$B/demo_prod_db_20200101_010000.zip.sha256"
check_not "old backup is deleted (2)" test -f "$B/demo_prod_db_20200102_010000.zip"
check "labeled backup is kept" test -f "$B/demo_prod_db_20200103_010000_keep_me.zip"
check "KEEP_MIN of other type is respected" test -f "$B/demo_prod_full_20200101_010000.zip"
check "file of other project is kept" test -f "$B/other_prod_db_20200101_010000.zip"
check "unfinished file is not touched" test -f "$B/demo_prod_db_20200104_010000.zip"
check "new backups are kept" test "$(count_files "$B" "demo_prod_db_$(date +%Y)*.zip")" = 2
rm -f "$B"/other_prod_* "$B/demo_prod_db_20200104_010000.zip"

echo "backup.sh --if-missing"
BEFORE=$(count_files "$B" '*.zip')
: > "$T/curl.log"
next_second
OUT=$($BACKUP db --if-missing 2> /dev/null)
check "nothing is created when backup of today exists" test "$(count_files "$B" '*.zip')" = "$BEFORE"
check "nothing is printed" test -z "$OUT"
check "no notification" test ! -s "$T/curl.log"
mkdir "$T/saved"
mv "$B"/demo_prod_*_"$(date +%Y%m%d)"_* "$T/saved/"
OUT=$($BACKUP db --if-missing 2> /dev/null)
check "backup is created when there is no backup of today" test -f "$B/$OUT"
check "notification is sent" grep -q "slack.example.com/host-webhook" "$T/curl.log"
mv "$T/saved"/* "$B/"

# --- ssh-gate.sh --------------------------------------------------------------

echo "ssh-gate.sh"
gate() {
    SSH_ORIGINAL_COMMAND="$1" $GATE
}
FIRST=$(gate list 2> /dev/null | head -n 1)
check "list returns finished files" test -n "$FIRST"
check "get returns the file" bash -c "SSH_ORIGINAL_COMMAND='get $FIRST' $GATE | cmp - '$B/$FIRST'"
check "get returns the checksum file" gate "get $FIRST.sha256"
check_not "empty command is denied" gate ""
check_not "shell command is denied" gate "cat /etc/passwd"
check_not "command after backup is denied" gate "backup db; id"
check_not "unknown type is denied" gate "backup all"
check_not "path is denied" gate "get ../backup.conf"
check_not "absolute path is denied" gate "get /etc/passwd"
check_not "other file is denied" gate "get backup.log"
echo "x" > "$B/other_prod_db_20200101_010000.zip"
echo "x" > "$B/other_prod_db_20200101_010000.zip.sha256"
check_not "file of other project is denied" gate "get other_prod_db_20200101_010000.zip"
rm -f "$B"/other_prod_*
touch "$B/demo_prod_db_20200105_010000.zip"
check_not "unfinished file is denied" gate "get demo_prod_db_20200105_010000.zip"
rm -f "$B/demo_prod_db_20200105_010000.zip"

# --- collect.sh ---------------------------------------------------------------

echo "collect.sh db"
C=$T/collected
: > "$T/curl.log"
next_second
check "succeeds" $COLLECT demo db
check "all finished files are pulled" test "$(count_files "$C" '*.zip')" = "$(gate list 2> /dev/null | wc -l | tr -d ' ')"
check "labeled file is pulled" test "$(count_files "$C" '*_before_release.zip')" = 1
check "checksums are correct" bash -c "cd '$C' && cat *.sha256 | sha256sum -c -"
check "start is pinged" grep -q "^https://hc.example.com/ping/key/demo-prod-db/start?" "$T/curl.log"
check "success is pinged" grep -q "^https://hc.example.com/ping/key/demo-prod-db?" "$T/curl.log"
check_not "failure is not pinged" grep -q "/fail" "$T/curl.log"
check "no .part file remains" test "$(count_files "$C" '*.part')" = 0

echo "collect.sh errors"
: > "$T/curl.log"
touch "$T/dump_fail"
next_second
check_not "fails when backup on host fails" $COLLECT demo db
check "failure is pinged" grep -q "^https://hc.example.com/ping/key/demo-prod-db/fail?" "$T/curl.log"
check "error of host is logged" grep -q "Access denied" "$C/collect.log"
rm "$T/dump_fail"

: > "$T/curl.log"
touch "$T/ssh_fail"
check_not "fails when host is not reachable" $COLLECT demo db
check "failure is pinged" grep -q "/demo-prod-db/fail?" "$T/curl.log"
rm "$T/ssh_fail"

: > "$T/curl.log"
touch "$T/dump_small"
next_second
check_not "fails when size drops" $COLLECT demo db
check "failure is pinged" grep -q "/demo-prod-db/fail?" "$T/curl.log"
check "reason is logged" grep -q "dropped" "$C/collect.log"
rm "$T/dump_small"

echo "collect.sh sync, broken file"
next_second
NEW=$($BACKUP db --label manual 2> /dev/null)
echo "0000000000000000000000000000000000000000000000000000000000000000  $NEW" > "$B/$NEW.sha256"
: > "$T/curl.log"
check_not "fails when checksum does not match" $COLLECT demo sync
check_not "broken file is not stored" test -f "$C/$NEW"
check "failure is pinged" grep -q "/demo-prod-sync/fail?" "$T/curl.log"
(cd "$B" && sha256sum "$NEW" > "$NEW.sha256")
check "sync succeeds" $COLLECT demo sync
check "file is pulled" test -f "$C/$NEW"

# --- restore.sh ---------------------------------------------------------------

echo "restore.sh"
RESTORE="$ROOT/host/restore.sh --config $T/backup.conf --yes"
ZIP=$(ls "$B"/demo_prod_full_"$(date +%Y)"*.zip | head -n 1)
rm -f "$T/mysql.stdin"
check "restore from zip file" $RESTORE "$ZIP"
check "sandbox line is removed" bash -c "! grep -q 'sandbox' '$T/mysql.stdin'"
check "DEFINER is replaced" grep -q 'DEFINER=CURRENT_USER SQL SECURITY' "$T/mysql.stdin"
check "data is kept" grep -q 'INSERT INTO `t` VALUES (2000,' "$T/mysql.stdin"
check "zip file is not modified" bash -c "cd '$B' && sha256sum -c '${ZIP##*/}.sha256'"
NAME=$(basename "$ZIP" .zip)
rm -f "$T/mysql.stdin"
check "restore from directory, as is" $RESTORE --as-is "$T/extract/$NAME"
check "DEFINER is kept" grep -q 'DEFINER=`admin`@`10.0.0.%`' "$T/mysql.stdin"
check_not "canceled without confirmation" bash -c "echo n | '$ROOT/host/restore.sh' --config '$T/backup.conf' '$ZIP'"

echo
echo "Passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
