#!/usr/bin/env bash
#
# Integration test in Docker: real MySQL, MariaDB, PostgreSQL, sshd and Healthchecks.
# Scenarios are those of docs/handover.md, section 5.
#
# Usage: bash tests/docker/run.sh
#
#   KEEP=1         Keep the containers after the test.
#                  Remove them later with: docker compose -p webapp-backup-test down -v
#   LARGE_MB=500   Also back up a MySQL database of about this size (MB). Skipped by default.

set -uo pipefail
# Git Bash on Windows: do not convert /paths in arguments of docker.
export MSYS_NO_PATHCONV=1

cd "$(dirname "${BASH_SOURCE[0]}")"
KEEP=${KEEP:-0}
LARGE_MB=${LARGE_MB:-0}
OUT=$(mktemp)
PASSED=0
FAILED=0

HC_KEY=webapp-backup-test-key
BIN=/opt/webapp-backup/host
COLLECT=/opt/webapp-backup/collector/collect.sh
CONF=/etc/webapp-backup

dc() {
    docker compose -p webapp-backup-test -f docker-compose.yml "$@"
}

finish() {
    rm -f "$OUT" "$OUT.new"
    if [ "$KEEP" = 1 ]; then
        echo "Containers are kept. Remove them with: docker compose -p webapp-backup-test down -v"
    else
        dc down -v --remove-orphans > /dev/null 2>&1
    fi
}
trap finish EXIT

# --- Test helpers -------------------------------------------------------------

ok() {
    PASSED=$((PASSED + 1))
    echo "  ok   $1"
}

# Output of the checked command is shown when the check fails.
ng() {
    FAILED=$((FAILED + 1))
    echo "  FAIL $1"
    if [ -s "$OUT" ]; then
        tail -n 20 "$OUT" | sed 's/^/       | /'
    fi
}

# Run a command, save its output in $OUT.
# The output goes to a new file first, so that the command itself can read the previous $OUT.
run_saved() {
    local rc=0
    "$@" > "$OUT.new" 2>&1 || rc=$?
    mv "$OUT.new" "$OUT"
    return $rc
}

# check <description> <command...>: passes when the command succeeds.
check() {
    local desc=$1
    shift
    if run_saved "$@"; then ok "$desc"; else ng "$desc"; fi
}

# check_not <description> <command...>: passes when the command fails.
check_not() {
    local desc=$1
    shift
    if run_saved "$@"; then ng "$desc"; else ok "$desc"; fi
}

# check_eq <description> <expected> <actual>
check_eq() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        printf 'expected: %s\nactual:   %s\n' "$2" "$3" > "$OUT"
        ng "$1"
    fi
}

# --- Container helpers --------------------------------------------------------

# Run a bash script in a container as root.
on() {
    dc exec -T "$1" bash -c "$2"
}

# Run a bash script in a container as the user "webapp-backup".
as_backup() {
    dc exec -T -u webapp-backup "$1" bash -c "$2"
}

# put <service> <path> <mode> [owner]: write stdin to a file.
# The owner (default root:webapp-backup) is applied only when the user webapp-backup exists, as described in docs/setup.md.
put() {
    dc exec -T "$1" bash -c "cat > '$2' && chmod $3 '$2' && { ! id webapp-backup > /dev/null 2>&1 || chown ${4:-root:webapp-backup} '$2'; }"
}

mysql_on() {
    local svc=$1
    shift
    local client=mysql
    [ "$svc" = mariadb ] && client=mariadb
    dc exec -T "$svc" "$client" -uroot -proot --default-character-set=utf8mb4 "$@" 2> /dev/null
}

psql_on() {
    dc exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -q "$@"
}

hc_shell() {
    dc exec -T hc ./manage.py shell -v 0 -c "$1" 2> /dev/null
}

# Print status of a check and its pings: "<kind> <rid> <body has ERROR>".
hc_pings() {
    hc_shell "
from hc.api.models import Check, Ping
c = Check.objects.filter(slug='$1').first()
if c:
    print('status', c.status)
    for p in Ping.objects.filter(owner=c).order_by('id'):
        body = bytes(p.body_raw or b'').decode(errors='replace')
        print(p.kind or 'success', p.rid, 'ERROR' in body)
"
}

# Content of the tables, to compare source and restored databases.
mysql_dump_data() {
    mysql_on "$1" -N -B "$2" -e "SELECT id, name, HEX(data) FROM item WHERE id <= 5 ORDER BY id; SELECT item_id, note FROM audit WHERE item_id <= 5 ORDER BY id;"
}

pgsql_dump_data() {
    psql_on -d "$1" -At -c "SELECT id, name, encode(data, 'hex') FROM item ORDER BY id"
}

# --- Start --------------------------------------------------------------------

echo "Starting containers..."
dc down -v --remove-orphans > /dev/null 2>&1
if ! dc up -d --build --wait > "$OUT" 2>&1; then
    tail -n 40 "$OUT"
    echo "Cannot start containers."
    exit 1
fi

echo "Preparing data..."
mysql_on mysql < fixtures/mysql.sql || { echo "Cannot load fixtures/mysql.sql into MySQL"; exit 1; }
mysql_on mariadb < fixtures/mysql.sql || { echo "Cannot load fixtures/mysql.sql into MariaDB"; exit 1; }
psql_on -d postgres < fixtures/pgsql.sql > /dev/null || { echo "Cannot load fixtures/pgsql.sql"; exit 1; }
BYTES=$(printf '%02X' $(seq 0 255))
for svc in mysql mariadb; do
    mysql_on "$svc" demo -e "INSERT INTO item (id, name, data) VALUES (5, 'binary', 0x$BYTES)"
done
# Privilege to read routines, as written in docs/setup.md.
mysql_on mysql -e "GRANT SHOW_ROUTINE ON *.* TO 'backup_user'@'%'"
mysql_on mariadb -e "GRANT SHOW CREATE ROUTINE ON demo.* TO 'backup_user'@'%'"

hc_shell "
from django.contrib.auth.models import User
from hc.accounts.models import Profile, Project
u = User.objects.create_user('test', 'test@example.com', 'test-password')
Profile.objects.for_user(u)
Project.objects.create(owner=u, name='test', ping_key='$HC_KEY')
" || { echo "Cannot create Healthchecks project"; exit 1; }

# Source directory: various kinds of files.
on host "
set -e
mkdir -p /var/www/demo/sub /var/www/demo/bin /var/www/demo/empty-dir /var/www/demo/storage
cd /var/www/demo
echo '<?php echo 1;' > index.php
echo 'space' > 'file with space.txt'
echo 'việt' > 'tiếng việt.txt'
echo 'secret' > sub/private.txt && chmod 600 sub/private.txt
printf '#!/bin/sh\necho run\n' > bin/run.sh && chmod 755 bin/run.sh
echo 'hidden' > storage/.hidden
head -c 100000 /dev/urandom > storage/random.bin
ln -s index.php link-file
ln -s sub link-dir
ln -s missing broken-link
chown -R webapp-backup:webapp-backup /var/www/demo
mkdir -p /app/public && echo 'root source' > /app/public/index.html && chown -R webapp-backup:webapp-backup /app
"

# Config files of the hosts.
put host $CONF/shop.conf 640 <<'EOF'
PROJECT=shop
ENV=prod
BACKUP_DIR=/var/webapp-backup/shop
DB_TYPE=mysql
DB_NAME=demo
DB_CREDENTIAL_FILE=shop.cnf
SOURCE_DIR=/var/www/demo
EOF
put host $CONF/shop-lenient.conf 640 <<'EOF'
PROJECT=shop
ENV=prod
BACKUP_DIR=/var/webapp-backup/shop
DB_TYPE=mysql
DB_NAME=demo
DB_CREDENTIAL_FILE=shop.cnf
SOURCE_DIR=/var/www/demo
FAIL_ON_UNREADABLE=0
EOF
put host $CONF/shop.cnf 640 <<'EOF'
[client]
host=mysql
user=backup_user
password=backup_pw
EOF
put host $CONF/shop-restore.conf 640 <<'EOF'
PROJECT=shop
ENV=local
BACKUP_DIR=/var/webapp-backup/shop-local
DB_TYPE=mysql
DB_NAME=demo_restore
DB_CREDENTIAL_FILE=restore.cnf
EOF
put host $CONF/other-restore.conf 640 <<'EOF'
PROJECT=shop
ENV=local
BACKUP_DIR=/var/webapp-backup/shop-local
DB_TYPE=mysql
DB_NAME=demo_other
DB_CREDENTIAL_FILE=restore.cnf
EOF
put host $CONF/restore.cnf 640 <<'EOF'
[client]
host=mysql
user=restore_user
password=restore_pw
EOF
put host $CONF/fallback.conf 640 <<'EOF'
PROJECT=shop
ENV=fallback
BACKUP_DIR=/var/webapp-backup/fallback
DB_TYPE=mysql
DB_NAME=demo
DB_CREDENTIAL_FILE=shop.cnf
EOF
put host $CONF/crm.conf 640 <<'EOF'
PROJECT=crm
ENV=prod
BACKUP_DIR=/var/webapp-backup/crm
DB_TYPE=pgsql
DB_NAME=demo
DB_HOST=postgres
DB_USER=backup_user
DB_CREDENTIAL_FILE=crm.pgpass
SOURCE_DIR=/var/www/demo
EOF
put host $CONF/crm.pgpass 600 webapp-backup:webapp-backup <<'EOF'
postgres:5432:demo:backup_user:backup_pw
EOF
put host $CONF/crm-restore.conf 640 <<'EOF'
PROJECT=crm
ENV=local
BACKUP_DIR=/var/webapp-backup/crm-local
DB_TYPE=pgsql
DB_NAME=demo_restore
DB_HOST=postgres
DB_USER=restore_user
DB_CREDENTIAL_FILE=crm-restore.pgpass
EOF
put host $CONF/crm-restore.pgpass 600 webapp-backup:webapp-backup <<'EOF'
postgres:5432:demo_restore:restore_user:restore_pw
EOF
put host $CONF/rootsrc.conf 640 <<'EOF'
PROJECT=rootsrc
ENV=prod
BACKUP_DIR=/var/webapp-backup/rootsrc
DB_TYPE=none
SOURCE_DIR=/app
EOF
put host-mariadb $CONF/blog.conf 640 <<'EOF'
PROJECT=blog
ENV=prod
BACKUP_DIR=/var/webapp-backup/blog
DB_TYPE=mysql
DB_NAME=demo
DB_CREDENTIAL_FILE=blog.cnf
EOF
put host-mariadb $CONF/blog.cnf 640 <<'EOF'
[client]
host=mariadb
user=backup_user
password=backup_pw
EOF
put host-mariadb $CONF/blog-restore.conf 640 <<'EOF'
PROJECT=blog
ENV=local
BACKUP_DIR=/var/webapp-backup/blog-local
DB_TYPE=mysql
DB_NAME=demo_restore
DB_CREDENTIAL_FILE=restore.cnf
EOF
put host-mariadb $CONF/restore.cnf 640 <<'EOF'
[client]
host=mariadb
user=restore_user
password=restore_pw
EOF

# Collector: one SSH key per project, registered on the host with the forced command.
put collector /opt/webapp-backup/collector/collector.conf 600 <<EOF
HC_PING_BASE=http://hc:8000/ping/$HC_KEY
HC_AUTO_CREATE=1
MIN_FREE_MB=10
SIZE_DROP_LIMIT=50
EOF
for spec in shop:host crm:host blog:host-mariadb safe:host; do
    project=${spec%%:*}
    svc=${spec#*:}
    on collector "ssh-keygen -q -t ed25519 -N '' -C collector -f /root/.ssh/${project}_key"
    pub=$(on collector "cat /root/.ssh/${project}_key.pub")
    echo "command=\"$BIN/ssh-gate.sh $CONF/$project.conf\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $pub" \
        | dc exec -T "$svc" bash -c "cat >> /home/webapp-backup/.ssh/authorized_keys && chown webapp-backup:webapp-backup /home/webapp-backup/.ssh/authorized_keys && chmod 600 /home/webapp-backup/.ssh/authorized_keys"
    put collector /opt/webapp-backup/collector/projects.d/$project.conf 600 <<EOF
PROJECT=$project
ENV=prod
SSH_HOST=$svc
SSH_USER=webapp-backup
SSH_KEY=/root/.ssh/${project}_key
SSH_OPTIONS="-o StrictHostKeyChecking=accept-new"
LOCAL_DIR=/backup/$project
EOF
done

# --- 1. Backup database -------------------------------------------------------

echo "1. backup.sh db (MySQL, MariaDB, PostgreSQL)"
SHOP_DB=$(as_backup host "$BIN/backup.sh --config $CONF/shop.conf db" 2> "$OUT") && ok "MySQL: backup succeeds" || ng "MySQL: backup succeeds"
BLOG_DB=$(as_backup host-mariadb "$BIN/backup.sh --config $CONF/blog.conf db" 2> "$OUT") && ok "MariaDB: backup succeeds" || ng "MariaDB: backup succeeds"
CRM_DB=$(as_backup host "$BIN/backup.sh --config $CONF/crm.conf db" 2> "$OUT") && ok "PostgreSQL: backup succeeds" || ng "PostgreSQL: backup succeeds"

for spec in "MySQL:host:shop:$SHOP_DB" "MariaDB:host-mariadb:blog:$BLOG_DB"; do
    IFS=: read -r label svc project file <<< "$spec"
    dump="unzip -p /var/webapp-backup/$project/$file '${file%.zip}/db.sql'"
    check "$label: zip has manifest.txt" on "$svc" "unzip -l /var/webapp-backup/$project/$file | grep -q '${file%.zip}/manifest.txt'"
    check "$label: dump has the table" on "$svc" "$dump | grep -q 'CREATE TABLE \`item\`'"
    # mariadb-dump does not quote the name of triggers.
    check "$label: dump has the view" on "$svc" "$dump | grep -Eq 'VIEW \`?item_names'"
    check "$label: dump has the procedure" on "$svc" "$dump | grep -Eq 'PROCEDURE \`?count_items'"
    check "$label: dump has the trigger" on "$svc" "$dump | grep -Eq 'TRIGGER \`?item_after_insert'"
    check "$label: dump has the event" on "$svc" "$dump | grep -Eq 'EVENT \`?purge_audit'"
done
dump="unzip -p /var/webapp-backup/crm/$CRM_DB '${CRM_DB%.zip}/db.sql'"
check "PostgreSQL: dump has the table" on host "$dump | grep -q 'CREATE TABLE public.item'"
check "PostgreSQL: dump has the function" on host "$dump | grep -q 'CREATE FUNCTION public.count_items'"

# --- 2. Backup database and source --------------------------------------------

echo "2. backup.sh full"
SHOP_FULL=$(as_backup host "$BIN/backup.sh --config $CONF/shop.conf full" 2> "$OUT") && ok "backup succeeds" || ng "backup succeeds"
check_not "no warning" grep WARNING "$OUT"
NAME=${SHOP_FULL%.zip}
on host "rm -rf /tmp/extract && mkdir /tmp/extract && cd /tmp/extract && unzip -q /var/webapp-backup/shop/$SHOP_FULL"
check "zip has db.sql" on host "test -s /tmp/extract/$NAME/db.sql"
check "extracted source is same as original" on host "diff -r --no-dereference /var/www/demo /tmp/extract/$NAME/demo"
LIST_SRC=$(on host "cd /var/www/demo && find . -printf '%p %y %m %l\n' | sort")
LIST_ZIP=$(on host "cd /tmp/extract/$NAME/demo && find . -printf '%p %y %m %l\n' | sort")
check_eq "types, permissions and link targets are kept" "$LIST_SRC" "$LIST_ZIP"
check "empty directory is kept" on host "test -d /tmp/extract/$NAME/demo/empty-dir"
check "broken link is kept as link" on host "test -L /tmp/extract/$NAME/demo/broken-link"
check "zip has nothing outside <name>/" on host "! unzip -Z1 /var/webapp-backup/shop/$SHOP_FULL | grep -v '^$NAME/'"

# --- 3. Source directory directly under / -------------------------------------

echo "3. backup.sh source, SOURCE_DIR=/app"
ROOT_SRC=$(as_backup host "$BIN/backup.sh --config $CONF/rootsrc.conf source" 2> "$OUT") && ok "backup succeeds" || ng "backup succeeds"
check "zip has <name>/app/public/index.html" on host "unzip -Z1 /var/webapp-backup/rootsrc/$ROOT_SRC | grep -qx '${ROOT_SRC%.zip}/app/public/index.html'"
check "zip has nothing outside <name>/app" on host "! unzip -Z1 /var/webapp-backup/rootsrc/$ROOT_SRC | grep -v '^${ROOT_SRC%.zip}/\(manifest.txt\|app/.*\)$'"

# --- 4. Restore into an empty database ----------------------------------------

echo "4. restore.sh (user with privileges on the target database only, other definer)"
# MySQL 8 enables binary logging by default. Then only an administrator can create triggers.
check_not "MySQL: restore by a normal user fails when binary logging is enabled" \
    as_backup host "$BIN/restore.sh --config $CONF/shop-restore.conf --yes /var/webapp-backup/shop/$SHOP_DB"
check "MySQL: hint is shown" grep -q "log_bin_trust_function_creators" "$OUT"
mysql_on mysql -e "DROP DATABASE demo_restore; CREATE DATABASE demo_restore CHARACTER SET utf8mb4; SET GLOBAL log_bin_trust_function_creators = 1"
check "MySQL: restore succeeds" as_backup host "$BIN/restore.sh --config $CONF/shop-restore.conf --yes /var/webapp-backup/shop/$SHOP_DB"
check_eq "MySQL: data is same as source" "$(mysql_dump_data mysql demo)" "$(mysql_dump_data mysql demo_restore)"
check_eq "MySQL: binary data is kept" "$BYTES" "$(mysql_on mysql -N -B demo_restore -e 'SELECT HEX(data) FROM item WHERE id = 5')"
check_eq "MySQL: procedure works" "5" "$(mysql_on mysql -N -B demo_restore -e 'CALL count_items(@n); SELECT @n')"
check_eq "MySQL: view works (as restore user)" "5" \
    "$(dc exec -T mysql mysql -urestore_user -prestore_pw -N -B demo_restore -e 'SELECT COUNT(*) FROM item_names' 2> /dev/null)"
mysql_on mysql demo_restore -e "INSERT INTO item (id, name) VALUES (100, 'new')"
check_eq "MySQL: trigger works" "1" "$(mysql_on mysql -N -B demo_restore -e 'SELECT COUNT(*) FROM audit WHERE item_id = 100')"
check_eq "MySQL: event exists" "1" "$(mysql_on mysql -N -B demo_restore -e "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'demo_restore'")"
check_not "MySQL: --as-is fails when the definer cannot be used" \
    as_backup host "$BIN/restore.sh --config $CONF/shop-restore.conf --yes --as-is /var/webapp-backup/shop/$SHOP_DB"

check "MariaDB: restore succeeds" as_backup host-mariadb "$BIN/restore.sh --config $CONF/blog-restore.conf --yes /var/webapp-backup/blog/$BLOG_DB"
check_eq "MariaDB: data is same as source" "$(mysql_dump_data mariadb demo)" "$(mysql_dump_data mariadb demo_restore)"
check_eq "MariaDB: procedure works" "5" "$(mysql_on mariadb -N -B demo_restore -e 'CALL count_items(@n); SELECT @n')"

check "PostgreSQL: restore succeeds" as_backup host "$BIN/restore.sh --config $CONF/crm-restore.conf --yes /var/webapp-backup/crm/$CRM_DB"
check_eq "PostgreSQL: data is same as source" "$(pgsql_dump_data demo)" "$(pgsql_dump_data demo_restore)"
check_eq "PostgreSQL: function works" "5" "$(psql_on -d demo_restore -At -c 'SELECT count_items()')"
check_eq "PostgreSQL: view works" "5" "$(psql_on -d demo_restore -At -c 'SELECT count(*) FROM item_names')"
check_eq "PostgreSQL: owner is the restore user" "restore_user" \
    "$(psql_on -d demo_restore -At -c "SELECT tableowner FROM pg_tables WHERE tablename = 'item'")"
check_not "PostgreSQL: --as-is fails when the owner cannot be used" \
    as_backup host "$BIN/restore.sh --config $CONF/crm-restore.conf --yes --as-is /var/webapp-backup/crm/$CRM_DB"

# --- 5. Dump of MariaDB, restored by the client of MySQL ----------------------

echo "5. MariaDB dump restored into MySQL"
on host-mariadb "cp /var/webapp-backup/blog/$BLOG_DB /exchange/ && chmod 644 /exchange/$BLOG_DB"
if on host "unzip -p /exchange/$BLOG_DB '${BLOG_DB%.zip}/db.sql' | head -n 1 | grep -q 'sandbox mode'"; then
    echo "  (info) the dump starts with the sandbox mode line"
fi
check "the dump uses collations utf8mb4_uca1400_*" on host "unzip -p /exchange/$BLOG_DB '${BLOG_DB%.zip}/db.sql' | grep -q utf8mb4_uca1400_"
check "restore succeeds" as_backup host "$BIN/restore.sh --config $CONF/other-restore.conf --yes /exchange/$BLOG_DB"
check "collations are replaced" grep -q "replaced by utf8mb4_0900_" "$OUT"
check_eq "data is same as source" "$(mysql_dump_data mariadb demo)" "$(mysql_dump_data mysql demo_other)"
check_eq "procedure works" "5" "$(mysql_on mysql -N -B demo_other -e 'CALL count_items(@n); SELECT @n')"
mysql_on mysql demo_other -e "INSERT INTO item (id, name) VALUES (100, 'new')"
check_eq "trigger works" "1" "$(mysql_on mysql -N -B demo_other -e 'SELECT COUNT(*) FROM audit WHERE item_id = 100')"
check_eq "view works" "5" "$(mysql_on mysql -N -B demo_other -e 'SELECT COUNT(*) FROM item_names WHERE id <= 5')"

# --- 6. Collector -------------------------------------------------------------

echo "6. collect.sh through real sshd, report to Healthchecks"
for spec in shop:db blog:db crm:full; do
    project=${spec%%:*}
    action=${spec#*:}
    check "$project $action: succeeds" on collector "$COLLECT $project $action"
    HOST_LIST=$(on collector "ssh -i /root/.ssh/${project}_key -o BatchMode=yes webapp-backup@$( [ "$project" = blog ] && echo host-mariadb || echo host ) list")
    LOCAL_LIST=$(on collector "cd /backup/$project && ls *.zip")
    check_eq "$project $action: all finished files are pulled" "$HOST_LIST" "$LOCAL_LIST"
    check "$project $action: checksums are correct" on collector "cd /backup/$project && cat *.sha256 | sha256sum -c --quiet -"
    PINGS=$(hc_pings "$project-prod-$action")
    check_eq "$project $action: Healthchecks check is created and up" "status up" "$(head -n 1 <<< "$PINGS")"
    START=$(tail -n 2 <<< "$PINGS" | head -n 1)
    END=$(tail -n 1 <<< "$PINGS")
    RID=$(cut -d' ' -f2 <<< "$START")
    check "$project $action: rid is sent" grep -Eq '^[0-9a-f-]{36}$' <<< "$RID"
    check_eq "$project $action: start and success are pinged with the same rid" \
        "start $RID / success $RID" "$(cut -d' ' -f1,2 <<< "$START") / $(cut -d' ' -f1,2 <<< "$END")"
done

# --- 7. What the key of the backup server cannot do ---------------------------

echo "7. Restrictions of the SSH key"
SSH="ssh -i /root/.ssh/shop_key -o BatchMode=yes webapp-backup@host"
check_not "run a shell command" on collector "$SSH 'cat /etc/passwd' | grep -q root"
check_not "open a login shell" on collector "$SSH < /dev/null | grep -q ."
check_not "run a command after an allowed one" on collector "$SSH 'list; id' | grep -q uid"
check_not "copy a file with scp" on collector "scp -i /root/.ssh/shop_key -o BatchMode=yes webapp-backup@host:/etc/passwd /tmp/stolen; test -s /tmp/stolen"
check_not "copy a file with sftp" on collector "echo 'get /etc/passwd /tmp/stolen2' | sftp -i /root/.ssh/shop_key -o BatchMode=yes -b - webapp-backup@host; test -s /tmp/stolen2"
check_not "read another file with get" on collector "$SSH 'get ../../../etc/passwd' | grep -q root"
check_not "forward a port to the database" on collector "
    ssh -i /root/.ssh/shop_key -o BatchMode=yes -N -L 13306:mysql:3306 webapp-backup@host &
    pid=\$!
    sleep 2
    greeting=\$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/13306 && head -c 20 <&3' | tr -dc '[:print:]')
    kill \$pid
    [ -n \"\$greeting\" ]"
check "allowed command still works" on collector "$SSH list | grep -q '^shop_prod_'"

# --- 8. Failure is reported ---------------------------------------------------

echo "8. Database is down"
dc stop mysql > /dev/null 2>&1
check_not "collect fails" on collector "$COLLECT shop db"
PINGS=$(hc_pings shop-prod-db)
check_eq "Healthchecks check is down" "status down" "$(head -n 1 <<< "$PINGS")"
check_eq "failure is pinged with the error log" "fail True" "$(tail -n 1 <<< "$PINGS" | cut -d' ' -f1,3)"
dc start mysql > /dev/null 2>&1
dc up -d --wait mysql > /dev/null 2>&1

# --- 9. Backups made on the host are pulled later ------------------------------

echo "9. collect.sh sync"
MANUAL=$(as_backup host "$BIN/backup.sh --config $CONF/shop.conf db --label before_release" 2> "$OUT") && ok "manual backup succeeds" || ng "manual backup succeeds"
check "sync succeeds" on collector "$COLLECT shop sync"
check "labeled backup is pulled" on collector "test -f /backup/shop/$MANUAL"

# --- 10. Fallback backup ------------------------------------------------------

echo "10. backup.sh --if-missing"
FIRST=$(as_backup host "$BIN/backup.sh --config $CONF/fallback.conf --if-missing db" 2> "$OUT")
check "first run creates a backup" on host "test -f /var/webapp-backup/fallback/$FIRST"
SECOND=$(as_backup host "$BIN/backup.sh --config $CONF/fallback.conf --if-missing db" 2> "$OUT")
check_eq "second run does nothing" "" "$SECOND"
check_eq "only one backup exists" "1" "$(on host 'ls /var/webapp-backup/fallback/*.zip | wc -l' | tr -d ' ')"

# --- 11. Two backups at the same time -----------------------------------------

echo "11. Lock"
check_not "second backup is refused while one is running" as_backup host "
    flock /var/webapp-backup/shop/.backup.lock sleep 4 &
    sleep 1
    $BIN/backup.sh --config $CONF/shop.conf db
    rc=\$?
    wait
    exit \$rc"
check "reason is reported" grep -q "Another backup is running" "$OUT"

# --- 12. File that cannot be read ---------------------------------------------

echo "12. Unreadable file in the source directory"
on host "echo secret > /var/www/demo/root-only.txt && chmod 600 /var/www/demo/root-only.txt"
ZIPS_BEFORE=$(on host "ls /var/webapp-backup/shop/*.zip | wc -l")
check_not "FAIL_ON_UNREADABLE=1 (default): backup fails" as_backup host "$BIN/backup.sh --config $CONF/shop.conf full"
check "FAIL_ON_UNREADABLE=1: the unreadable file is listed" grep -q "/var/www/demo/root-only.txt" "$OUT"
check_eq "FAIL_ON_UNREADABLE=1: no backup file is left" "$ZIPS_BEFORE" "$(on host "ls /var/webapp-backup/shop/*.zip | wc -l")"
check_not "FAIL_ON_UNREADABLE=1: collect fails" on collector "$COLLECT shop full"
check_eq "FAIL_ON_UNREADABLE=1: failure is pinged to Healthchecks" "fail True" "$(hc_pings shop-prod-full | tail -n 1 | cut -d' ' -f1,3)"
WARN_FULL=$(as_backup host "$BIN/backup.sh --config $CONF/shop-lenient.conf full" 2> "$OUT") && ok "FAIL_ON_UNREADABLE=0: backup succeeds" || ng "FAIL_ON_UNREADABLE=0: backup succeeds"
check "warning is reported" grep -q "WARNING" "$OUT"
check_not "unreadable file is not in the zip" on host "unzip -Z1 /var/webapp-backup/shop/$WARN_FULL | grep -q root-only.txt"
check "readable files are in the zip" on host "unzip -Z1 /var/webapp-backup/shop/$WARN_FULL | grep -q 'demo/index.php'"
on host "rm -f /var/www/demo/root-only.txt"

# --- 13. Source directory owned by another user, shared with ACL -------------

echo "13. Source directory owned by another user (ACL, docs/setup.md 1.2)"
SRC=/home/deploy/example.com
on host "useradd -m -s /bin/bash deploy && chmod 750 /home/deploy
    su deploy -c 'mkdir -p $SRC && echo code > $SRC/index.php && echo secret > $SRC/.env && chmod 600 $SRC/.env'"
put host $CONF/acl.conf 640 <<EOF
PROJECT=acl
ENV=prod
BACKUP_DIR=/var/webapp-backup/acl
DB_TYPE=none
SOURCE_DIR=$SRC
EOF
check_not "without ACL: backup fails" as_backup host "$BIN/backup.sh --config $CONF/acl.conf source"
check "without ACL: the reason is reported" grep -q "no permission to access" "$OUT"
# The commands written in docs/setup.md.
on host "setfacl -m u:webapp-backup:x /home/deploy
    setfacl -R -m u:webapp-backup:rX $SRC
    setfacl -R -d -m u:webapp-backup:rX $SRC"
ACL_ZIP=$(as_backup host "$BIN/backup.sh --config $CONF/acl.conf source" 2> "$OUT") && ok "with ACL: backup succeeds" || ng "with ACL: backup succeeds"
check "with ACL: private file (600) is backed up" on host "unzip -Z1 /var/webapp-backup/acl/$ACL_ZIP | grep -q 'example.com/.env'"
check_not "with ACL: home directory of the owner cannot be listed" as_backup host "ls /home/deploy"
on host "su deploy -c 'umask 077; mkdir $SRC/uploads && echo img > $SRC/uploads/a.jpg'"
ACL_ZIP=$(as_backup host "$BIN/backup.sh --config $CONF/acl.conf source" 2> "$OUT") && ok "file created later: backup succeeds" || ng "file created later: backup succeeds"
check "file created later is in the zip" on host "unzip -Z1 /var/webapp-backup/acl/$ACL_ZIP | grep -q 'uploads/a.jpg'"
on host "su deploy -c 'chmod 600 $SRC/index.php'"
check_not "file changed by chmod 600: backup fails" as_backup host "$BIN/backup.sh --config $CONF/acl.conf source"
check "file changed by chmod 600: the file is listed" grep -q "$SRC/index.php" "$OUT"
on host "setfacl -R -m u:webapp-backup:rX $SRC"
check "after running setfacl again: backup succeeds" as_backup host "$BIN/backup.sh --config $CONF/acl.conf source"

# --- 14. Encryption -----------------------------------------------------------

echo "14. Encryption (docs/setup.md 1.7)"
# The administrator creates the key pair outside of the host. Here: root of the host, with its own key ring.
ADMIN_GPG="GNUPGHOME=/root/admin-gnupg"
on host "mkdir -m 700 /root/admin-gnupg
    $ADMIN_GPG gpg --batch --quiet --passphrase '' --quick-generate-key 'example backup <backup@example.com>' default default never
    $ADMIN_GPG gpg --armor --export backup@example.com > /tmp/example-backup.pub.asc
    install -o root -g webapp-backup -m 640 /tmp/example-backup.pub.asc $CONF/safe.pub.asc"
put host $CONF/safe.conf 640 <<'EOF'
PROJECT=safe
ENV=prod
BACKUP_DIR=/var/webapp-backup/safe
DB_TYPE=mysql
DB_NAME=demo
DB_CREDENTIAL_FILE=shop.cnf
SOURCE_DIR=/var/www/demo
ENCRYPT_PUBLIC_KEY_FILE=safe.pub.asc
EOF
SAFE_FULL=$(as_backup host "$BIN/backup.sh --config $CONF/safe.conf full" 2> "$OUT") && ok "backup succeeds" || ng "backup succeeds"
check "name ends with .zip.gpg" grep -Eq '^safe_prod_full_[0-9]{8}_[0-9]{6}\.zip\.gpg$' <<< "$SAFE_FULL"
check_not "no zip file is left on the host" on host "ls /var/webapp-backup/safe/*.zip"
check_not "the user of the backup cannot decrypt" as_backup host "gpg --batch --decrypt /var/webapp-backup/safe/$SAFE_FULL > /dev/null"
NAME=${SAFE_FULL%.zip.gpg}
on host "rm -rf /tmp/safe && mkdir /tmp/safe && cd /tmp/safe
    $ADMIN_GPG gpg --batch --quiet --output backup.zip --decrypt /var/webapp-backup/safe/$SAFE_FULL && unzip -q backup.zip"
check "decrypted: source is same as original" on host "diff -r --no-dereference /var/www/demo /tmp/safe/$NAME/demo"
check "decrypted: dump has the procedure" on host "grep -Eq 'PROCEDURE \`?count_items' /tmp/safe/$NAME/db.sql"

# MySQL was restarted in 8, the global variable is reset.
mysql_on mysql -e "DROP DATABASE IF EXISTS demo_restore; CREATE DATABASE demo_restore CHARACTER SET utf8mb4; SET GLOBAL log_bin_trust_function_creators = 1"
check "restore.sh decrypts and restores" on host "$ADMIN_GPG $BIN/restore.sh --config $CONF/shop-restore.conf --yes /var/webapp-backup/safe/$SAFE_FULL"
check_eq "restored data is same as source" "$(mysql_dump_data mysql demo)" "$(mysql_dump_data mysql demo_restore)"
check_not "restore.sh without the private key fails" \
    as_backup host "$BIN/restore.sh --config $CONF/shop-restore.conf --yes /var/webapp-backup/safe/$SAFE_FULL"
check "hint is shown" grep -q "Import the private key" "$OUT"

check_not "the backup server has no gpg" on collector "command -v gpg"
check "collect succeeds" on collector "$COLLECT safe full"
check "encrypted file is pulled" on collector "cd /backup/safe && sha256sum -c --quiet $SAFE_FULL.sha256"
on collector "echo REQUIRE_ENCRYPTION=1 >> /opt/webapp-backup/collector/projects.d/safe.conf"
check "REQUIRE_ENCRYPTION=1: collect succeeds when the host encrypts" on collector "$COLLECT safe db"
on host "sed -i 's/^ENCRYPT_PUBLIC_KEY_FILE=.*/ENCRYPT_PUBLIC_KEY_FILE=/' $CONF/safe.conf"
check_not "REQUIRE_ENCRYPTION=1: collect fails when the host does not encrypt" on collector "$COLLECT safe db"
check_eq "REQUIRE_ENCRYPTION=1: failure is pinged to Healthchecks" "fail True" "$(hc_pings safe-prod-db | tail -n 1 | cut -d' ' -f1,3)"
check_not "REQUIRE_ENCRYPTION=1: file that is not encrypted is not pulled" on collector "ls /backup/safe/*.zip"

# --- 15. Large database (optional) --------------------------------------------

if [ "$LARGE_MB" -gt 0 ]; then
    echo "15. Large database (about ${LARGE_MB}MB)"
    mysql_on mysql demo -e "
        CREATE TABLE big (id INT AUTO_INCREMENT PRIMARY KEY, payload VARCHAR(1000));
        SET SESSION cte_max_recursion_depth = 10000000;
        INSERT INTO big (payload)
            WITH RECURSIVE s (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < $LARGE_MB * 1000)
            SELECT REPEAT(MD5(n), 30) FROM s;"
    START_TIME=$(date +%s)
    check "backup succeeds" as_backup host "$BIN/backup.sh --config $CONF/shop.conf db"
    echo "  (info) backup took $(( $(date +%s) - START_TIME ))s, size: $(on host 'ls -lh /var/webapp-backup/shop/*.zip | tail -n 1 | awk "{print \$5}"')"
    mysql_on mysql demo -e "DROP TABLE big"
fi

echo
echo "Passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
