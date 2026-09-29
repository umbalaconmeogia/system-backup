[English](setup.md) | [Tiếng Việt](setup.vi.md) | [日本語](setup.ja.md)

# Setup guide

In this guide, the scripts are installed in `/opt/webapp-backup`, the project is named `example`.

## 1. Host

### 1.1. Install

```bash
sudo apt install zip unzip          # Ubuntu
sudo dnf install zip unzip          # Amazon Linux
```

Copy the directory `host/` to `/opt/webapp-backup/host`. The scripts must be owned by root,
so that the user of the backup cannot modify them, in particular `ssh-gate.sh`, which limits what the backup server can do.

```bash
sudo chown -R root:root /opt/webapp-backup
sudo chmod 755 /opt/webapp-backup/host/*.sh
```

### 1.2. User

All scripts on the host (triggered by the backup server, or by cron) must run as the same user.
This user needs permission to read all files of the source directory.
If some files cannot be read, the backup fails and the files are listed in the log (see `FAIL_ON_UNREADABLE` in `backup.conf`).

Create a dedicated user with a login shell. The backup server connects as this user, and SSH runs `ssh-gate.sh` through its shell.
Do not use the user `backup`: it already exists on Ubuntu and Debian, with the shell `/usr/sbin/nologin`.

```bash
sudo useradd -m -s /bin/bash webapp-backup
sudo install -d -m 700 -o webapp-backup -g webapp-backup /var/webapp-backup
```

#### Source directory owned by another user

When the source directory belongs to another user, for example `/home/deploy/example.com`,
give `webapp-backup` the permission to read it with ACL (Access Control List).
ACL adds a permission for one more user to files and directories, without changing the permissions of the owner and of other users.

```bash
sudo apt install acl                                                   # Amazon Linux: sudo dnf install acl
sudo setfacl -m u:webapp-backup:x /home/deploy
sudo setfacl -R -m u:webapp-backup:rX /home/deploy/example.com
sudo setfacl -R -d -m u:webapp-backup:rX /home/deploy/example.com
```

| Command | Effect |
|---|---|
| `setfacl -m u:webapp-backup:x /home/deploy` | `webapp-backup` can pass through the home directory, but cannot list its files. Needed for each directory on the path that does not allow it (on Ubuntu, home directories have the permission `750`) |
| `setfacl -R -m u:webapp-backup:rX ...` | `webapp-backup` can read all existing files. `X` (upper case) allows entering directories, not executing files |
| `setfacl -R -d -m u:webapp-backup:rX ...` | Default ACL: files and directories created later can also be read |

The default ACL does not apply in a few cases: a file whose permission is changed later (for example `chmod 600`),
and a private file moved (`mv`) or copied with `cp -p` into the source directory.
Then the backup fails, and the files are listed in the log. Run `sudo setfacl -R -m u:webapp-backup:rX /home/deploy/example.com` again to fix it.

### 1.3. Config

```bash
cd /opt/webapp-backup/host
sudo cp backup.conf.example backup.conf
sudo cp my.cnf.example my.cnf
sudo chown root:webapp-backup backup.conf my.cnf
sudo chmod 640 backup.conf my.cnf
```

The user `webapp-backup` can read the config files, but cannot modify them. Other users cannot read them.

For PostgreSQL, create `pgpass` instead of `my.cnf`. It must be owned by `webapp-backup` with the permission `600`:
the client of PostgreSQL ignores the file if its group can read it.

```bash
sudo install -o webapp-backup -g webapp-backup -m 600 pgpass.example pgpass
```

Edit `backup.conf` and `my.cnf` (or `pgpass`) with `sudo`. `BACKUP_DIR` must be outside of `SOURCE_DIR`.

The database user needs permission to dump the database.

MySQL 8.0.20 or later:

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON example_db.* TO 'backup_user'@'localhost';
GRANT SHOW_ROUTINE ON *.* TO 'backup_user'@'localhost';
```

MariaDB 11.3 or later:

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, SHOW CREATE ROUTINE ON example_db.* TO 'backup_user'@'localhost';
```

Older MariaDB: replace `SHOW CREATE ROUTINE ON example_db.*` by `GRANT SELECT ON mysql.proc`.

**Without the privilege to read routines, stored procedures and functions are silently missing from the backup**:
the dump succeeds, without any error or warning. Check it once after setup, before enabling the encryption (1.7):

```bash
unzip -p /var/webapp-backup/example/<backup file>.zip '*/db.sql' | grep -E 'CREATE .*(PROCEDURE|FUNCTION)'
```

`PROCESS` is also needed if `--no-tablespaces` is removed from the dump options.

PostgreSQL 14 or later:

```sql
GRANT pg_read_all_data TO backup_user;
```

The version of `pg_dump` on the host must not be older than the PostgreSQL server
(for example, `pg_dump` 16 of Ubuntu 24.04 cannot dump a PostgreSQL 17 server).

### 1.4. Try

```bash
./backup.sh db
./backup.sh full
ls -l /var/webapp-backup/example
```

### 1.5. Allow the backup server to connect

Add the public key of the backup server (created in 2.2) into `~/.ssh/authorized_keys` of the user, in one line:

```
command="/opt/webapp-backup/host/ssh-gate.sh /opt/webapp-backup/host/backup.conf",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... backup-server
```

With this key, the backup server can only create backups, list and read the backup files of this project.

If there are several projects on one host, use one config file and one key for each project.

### 1.6. Fallback

If the backup server does not trigger the backup (for example, it is down), the host creates the backup by itself.
Add into crontab of the user (see [crontab.example](../host/crontab.example)), the time must be later than the schedule of the backup server:

```
0 5 * * * /opt/webapp-backup/host/backup.sh --if-missing db > /dev/null 2>&1
```

When a fallback backup is created, a notification is sent to `NOTIFY_SLACK_WEBHOOK` and `NOTIFY_MAIL` of `backup.conf`.
The file is pulled by the backup server at its next run.

### 1.7. Encryption (optional)

Encrypt the backup files, so that a file that leaks out (copied to a PC, sent by mistake...) cannot be read.
The host encrypts with a public key of gpg. The private key, needed to decrypt, is kept by the administrator:
it is neither on the host nor on the backup server.

1. On the PC of the administrator (not on the host), create a key pair. Set a strong passphrase when asked.
   The expiration must be `never`: when the key expires, backups fail.

   ```bash
   gpg --quick-generate-key "example backup <backup@example.com>" default default never
   gpg --armor --export backup@example.com > example-backup.pub.asc
   gpg --armor --export-secret-keys backup@example.com > example-backup.secret.asc
   ```

2. Keep `example-backup.secret.asc` and its passphrase in at least two safe places
   (for example, a password manager and an offline USB drive), then delete the file from the PC.
   **If the private key or its passphrase is lost, all encrypted backups are lost.**
3. Copy the public key to the host, next to `backup.conf`:

   ```bash
   sudo install -o root -g webapp-backup -m 640 example-backup.pub.asc /opt/webapp-backup/host/
   ```

   Then set in `backup.conf`: `ENCRYPT_PUBLIC_KEY_FILE=example-backup.pub.asc`.
   `gpg` is usually installed already (check with `gpg --version`). Otherwise, on Ubuntu: `sudo apt install gnupg`.
4. Run `./backup.sh db`: it creates `<name>.zip.gpg`. Download the file to the PC of the administrator and decrypt it:

   ```bash
   gpg --output example.zip --decrypt example_prod_db_20260928_010000.zip.gpg
   unzip -l example.zip
   ```

Try the decryption regularly, for example when restoring a backup into a local PC (4.1).

* File names inside the zip are encrypted too. Only the name of the backup file (project, env, type, date) can be seen.
* While encrypting, both the zip file and the encrypted file exist in `BACKUP_DIR`: free space for twice the size of a backup is needed.
* To make sure that the backups of a project are always encrypted, set `REQUIRE_ENCRYPTION` on the backup server (2.3).

## 2. Backup server

### 2.1. Install

Copy the directory `collector/` to `/opt/webapp-backup/collector`.

```bash
chmod +x /opt/webapp-backup/collector/*.sh
```

### 2.2. SSH key

Create one key for each project, without passphrase:

```bash
ssh-keygen -t ed25519 -N "" -C backup-server -f ~/.ssh/example_ed25519
```

Register the content of `~/.ssh/example_ed25519.pub` on the host (see 1.5), then connect once to accept the host key:

```bash
ssh -i ~/.ssh/example_ed25519 -p 22 webapp-backup@203.0.113.10 list
```

### 2.3. Config

```bash
cd /opt/webapp-backup/collector
cp collector.conf.example collector.conf
cp projects.d/example.conf.example projects.d/example.conf
chmod 600 collector.conf projects.d/example.conf
```

Edit both files. `PROJECT` and `ENV` must be same as in `backup.conf` on the host.

If the host encrypts the backups (1.7), set `REQUIRE_ENCRYPTION=1`, in `collector.conf` for all projects or in `projects.d/example.conf`.
Then a backup that is not encrypted, for example after `ENCRYPT_PUBLIC_KEY_FILE` is removed by mistake, is not pulled, and the run fails.
The backup server does not need `gpg` nor the key.

### 2.4. Try

```bash
./collect.sh example db
ls -l /backup/example
```

### 2.5. Schedule

Add into crontab (see [crontab.example](../collector/crontab.example)):

```
0 1 * * 1-6 /opt/webapp-backup/collector/collect.sh example db > /dev/null 2>&1
0 1 * * 0   /opt/webapp-backup/collector/collect.sh example full > /dev/null 2>&1
```

## 3. Healthchecks

### 3.1. Install

Healthchecks provides Docker images and a sample configuration.
See [Running with Docker](https://healthchecks.io/docs/self_hosted_docker/) for details.

```bash
git clone https://github.com/healthchecks/healthchecks.git
cd healthchecks/docker
cp .env.example .env
# Edit .env: ALLOWED_HOSTS, SITE_ROOT, SECRET_KEY, DEFAULT_FROM_EMAIL, EMAIL_HOST, EMAIL_HOST_USER, EMAIL_HOST_PASSWORD
docker compose up -d
docker compose run web /opt/healthchecks/manage.py createsuperuser
```

Healthchecks listens on port 8000. Put it behind a reverse proxy that handles HTTPS.

### 3.2. Config

1. Create a project. In Settings of the project, create the **Ping key**.
   Set `HC_PING_BASE` of `collector.conf` to `<SITE_ROOT>/ping/<ping key>`.
2. In Integrations, add **Email** and **Slack**.
3. Run `collect.sh` once for each project and type. The checks are created automatically,
   with the name `<project>-<env>-<type>` (for example `example-prod-db`).
4. Set the schedule of each check same as the crontab. For example, with `0 1 * * 1-6`:
   schedule `0 1 * * 1-6`, time zone of the backup server, grace time 2 hours.

Healthchecks sends alerts when a run fails, or when no result arrives in time.
It does not send a message for every successful run. To get one, set `REPORT_SLACK_WEBHOOK` of `collector.conf`.

### 3.3. Note

If Healthchecks runs on the backup server and the backup server is down, nobody sends alerts.
In this case, only the notification of the fallback backup (1.6) tells that something is wrong.
To avoid this, run Healthchecks on another server.

## 4. Restore

### 4.1. Database, on a local PC (Windows)

1. Copy `host/restore.bat`, `host/restore.ps1` to a directory, create `backup.conf` and `my.cnf` of the local database there.
   Only `DB_TYPE`, `DB_NAME`, `DB_CREDENTIAL_FILE` are needed (and `DB_USER`, `DB_HOST`, `DB_PORT` for PostgreSQL).
2. Download the backup file, then run:

```bat
restore.bat C:\path\to\example_prod_db_20260928_010000.zip
```

For an encrypted backup (`.zip.gpg`), install [Gpg4win](https://www.gpg4win.org/) and import the private key once:
`gpg --import example-backup.secret.asc`. Then run `restore.bat` with the `.zip.gpg` file, it asks for the passphrase.

The dump is adjusted for the local environment (the backup file itself is not modified):

* `DEFINER` of views, routines, triggers and events is replaced by `CURRENT_USER`.
  The user of production usually does not exist on the local PC.
* The first line written by `mariadb-dump` (`enable the sandbox mode`) is removed. The client of MySQL cannot read it.
* `NO_AUTO_CREATE_USER` is removed from `sql_mode` of routines and triggers. MariaDB keeps it, MySQL 8 rejects it.
* Collations `utf8mb4_uca1400_*`, the default of MariaDB 11.4 and later, are replaced by `utf8mb4_0900_*`
  (or `utf8mb4_unicode_ci`) when the local server does not have them, for example MySQL.
* PostgreSQL: `OWNER TO`, `GRANT` and `REVOKE` statements are skipped. Objects are owned by the user of the restore.

### 4.2. Restore by a user who is not an administrator (MySQL)

MySQL 8 enables binary logging by default. Then only an administrator can create triggers and routines,
and the restore fails with `ERROR 1419`. Either restore as an administrator (for example `root`),
or run this on the target server once:

```sql
SET PERSIST log_bin_trust_function_creators = 1;
```

The user also needs all privileges on the target database. If it cannot create databases, create the database before the restore.

### 4.3. Rebuild the server

For an encrypted backup, import the private key first (`gpg --import example-backup.secret.asc`),
and delete it after the restore (`gpg --delete-secret-keys backup@example.com`).

```bash
cd /var/webapp-backup/example
gpg --output example_prod_full_20260928_010000.zip --decrypt example_prod_full_20260928_010000.zip.gpg   # Encrypted backup only
unzip example_prod_full_20260928_010000.zip
/opt/webapp-backup/host/restore.sh --as-is example_prod_full_20260928_010000
cp -a example_prod_full_20260928_010000/example /var/www/
chown -R www-data:www-data /var/www/example      # Owner of files is not stored in the zip file
```
