# Setup guide

In this guide, the scripts are installed in `/opt/webapp-backup`, the project is named `example`.

## 1. Host

### 1.1. Install

```bash
sudo apt install zip unzip          # Ubuntu
sudo dnf install zip unzip          # Amazon Linux
```

Copy the directory `host/` to `/opt/webapp-backup/host`.

```bash
chmod +x /opt/webapp-backup/host/*.sh
```

### 1.2. User

All scripts on the host (triggered by the backup server, or by cron) must run as the same user.
This user needs permission to read all files of the source directory.

### 1.3. Config

```bash
cd /opt/webapp-backup/host
cp backup.conf.example backup.conf
cp my.cnf.example my.cnf            # PostgreSQL: cp pgpass.example pgpass
chmod 600 backup.conf my.cnf
```

Edit `backup.conf` and `my.cnf`. `BACKUP_DIR` must be outside of `SOURCE_DIR`.

The database user needs permission to dump the database.
For MySQL: `SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES` (and `PROCESS` if `--no-tablespaces` is removed from the dump options).

### 1.4. Try

```bash
./backup.sh db
./backup.sh full
ls -l /var/backup/example
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
ssh -i ~/.ssh/example_ed25519 -p 22 backup@203.0.113.10 list
```

### 2.3. Config

```bash
cd /opt/webapp-backup/collector
cp collector.conf.example collector.conf
cp projects.d/example.conf.example projects.d/example.conf
chmod 600 collector.conf projects.d/example.conf
```

Edit both files. `PROJECT` and `ENV` must be same as in `backup.conf` on the host.

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

### 4.2. Rebuild the server

```bash
cd /var/backup/example
unzip example_prod_full_20260928_010000.zip
/opt/webapp-backup/host/restore.sh --as-is example_prod_full_20260928_010000
cp -a example_prod_full_20260928_010000/example /var/www/
chown -R www-data:www-data /var/www/example      # Owner of files is not stored in the zip file
```
