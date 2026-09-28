[English](setup.md) | [Tiếng Việt](setup.vi.md) | [日本語](setup.ja.md)

# セットアップガイド

このガイドでは、スクリプトを `/opt/webapp-backup` にインストールし、プロジェクト名を `example` とします。

## 1. ホスト

### 1.1. インストール

```bash
sudo apt install zip unzip          # Ubuntu
sudo dnf install zip unzip          # Amazon Linux
```

ディレクトリ `host/` を `/opt/webapp-backup/host` にコピーします。

```bash
chmod +x /opt/webapp-backup/host/*.sh
```

### 1.2. ユーザー

ホスト上のすべてのスクリプト（バックアップサーバーから起動されるもの、cron で実行されるもの）は、同じユーザーで実行する必要があります。
このユーザーには、ソースディレクトリのすべてのファイルを読む権限が必要です。

ログインシェルを持つ専用ユーザーを作成してください。バックアップサーバーはこのユーザーで接続し、SSH はそのシェルを通して `ssh-gate.sh` を実行します。
ユーザー `backup` は使わないでください。Ubuntu と Debian には既に存在し、シェルが `/usr/sbin/nologin` になっています。

```bash
sudo useradd -m -s /bin/bash webapp-backup
sudo install -d -o webapp-backup -g webapp-backup /var/backup
```

### 1.3. 設定

```bash
cd /opt/webapp-backup/host
cp backup.conf.example backup.conf
cp my.cnf.example my.cnf            # PostgreSQL: cp pgpass.example pgpass
chmod 600 backup.conf my.cnf
```

`backup.conf` と `my.cnf` を編集します。`BACKUP_DIR` は `SOURCE_DIR` の外に置く必要があります。

データベースのユーザーには、データベースをダンプする権限が必要です。

MySQL 8.0.20 以降：

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON example_db.* TO 'backup_user'@'localhost';
GRANT SHOW_ROUTINE ON *.* TO 'backup_user'@'localhost';
```

MariaDB 11.3 以降：

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, SHOW CREATE ROUTINE ON example_db.* TO 'backup_user'@'localhost';
```

それより古い MariaDB：`SHOW CREATE ROUTINE ON example_db.*` を `GRANT SELECT ON mysql.proc` に置き換えてください。

**ルーチンを読む権限がないと、ストアドプロシージャとファンクションは何の通知もなくバックアップから欠落します**。
ダンプはエラーも警告もなく成功します。セットアップ後に一度確認してください：

```bash
unzip -p /var/backup/example/<backup file>.zip '*/db.sql' | grep -E 'CREATE .*(PROCEDURE|FUNCTION)'
```

ダンプのオプションから `--no-tablespaces` を外す場合は、`PROCESS` 権限も必要です。

PostgreSQL 14 以降：

```sql
GRANT pg_read_all_data TO backup_user;
```

ホストの `pg_dump` のバージョンは、PostgreSQL サーバーより古くてはいけません
（例：Ubuntu 24.04 の `pg_dump` 16 では PostgreSQL 17 サーバーをダンプできません）。

### 1.4. 試す

```bash
./backup.sh db
./backup.sh full
ls -l /var/backup/example
```

### 1.5. バックアップサーバーからの接続を許可する

バックアップサーバーの公開鍵（2.2 で作成）を、ユーザーの `~/.ssh/authorized_keys` に 1 行で追加します：

```
command="/opt/webapp-backup/host/ssh-gate.sh /opt/webapp-backup/host/backup.conf",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... backup-server
```

この鍵では、バックアップサーバーはこのプロジェクトのバックアップの作成と、バックアップファイルの一覧表示と読み取りしかできません。

1 台のホストに複数のプロジェクトがある場合は、プロジェクトごとに設定ファイルと鍵を 1 つずつ用意してください。

### 1.6. フォールバック

バックアップサーバーがバックアップを起動しない場合（例えば、停止している場合）、ホストが自分でバックアップを作成します。
ユーザーの crontab に追加します（[crontab.example](../host/crontab.example) を参照）。実行時刻はバックアップサーバーのスケジュールより後にしてください：

```
0 5 * * * /opt/webapp-backup/host/backup.sh --if-missing db > /dev/null 2>&1
```

フォールバックのバックアップが作成されると、`backup.conf` の `NOTIFY_SLACK_WEBHOOK` と `NOTIFY_MAIL` に通知が送られます。
ファイルは、バックアップサーバーの次回の実行時に取得されます。

## 2. バックアップサーバー

### 2.1. インストール

ディレクトリ `collector/` を `/opt/webapp-backup/collector` にコピーします。

```bash
chmod +x /opt/webapp-backup/collector/*.sh
```

### 2.2. SSH 鍵

プロジェクトごとに、パスフレーズなしの鍵を 1 つ作成します：

```bash
ssh-keygen -t ed25519 -N "" -C backup-server -f ~/.ssh/example_ed25519
```

`~/.ssh/example_ed25519.pub` の内容をホストに登録し（1.5 を参照）、ホスト鍵を受け入れるために一度接続します：

```bash
ssh -i ~/.ssh/example_ed25519 -p 22 webapp-backup@203.0.113.10 list
```

### 2.3. 設定

```bash
cd /opt/webapp-backup/collector
cp collector.conf.example collector.conf
cp projects.d/example.conf.example projects.d/example.conf
chmod 600 collector.conf projects.d/example.conf
```

両方のファイルを編集します。`PROJECT` と `ENV` は、ホストの `backup.conf` と同じにする必要があります。

### 2.4. 試す

```bash
./collect.sh example db
ls -l /backup/example
```

### 2.5. スケジュール

crontab に追加します（[crontab.example](../collector/crontab.example) を参照）：

```
0 1 * * 1-6 /opt/webapp-backup/collector/collect.sh example db > /dev/null 2>&1
0 1 * * 0   /opt/webapp-backup/collector/collect.sh example full > /dev/null 2>&1
```

## 3. Healthchecks

### 3.1. インストール

Healthchecks は Docker イメージとサンプル構成を提供しています。
詳しくは [Running with Docker](https://healthchecks.io/docs/self_hosted_docker/) を参照してください。

```bash
git clone https://github.com/healthchecks/healthchecks.git
cd healthchecks/docker
cp .env.example .env
# Edit .env: ALLOWED_HOSTS, SITE_ROOT, SECRET_KEY, DEFAULT_FROM_EMAIL, EMAIL_HOST, EMAIL_HOST_USER, EMAIL_HOST_PASSWORD
docker compose up -d
docker compose run web /opt/healthchecks/manage.py createsuperuser
```

Healthchecks はポート 8000 で待ち受けます。HTTPS を処理するリバースプロキシの背後に置いてください。

### 3.2. 設定

1. プロジェクトを作成します。プロジェクトの Settings で **Ping key** を作成します。
   `collector.conf` の `HC_PING_BASE` を `<SITE_ROOT>/ping/<ping key>` に設定します。
2. Integrations で **Email** と **Slack** を追加します。
3. プロジェクトとバックアップの種類ごとに、`collect.sh` を一度実行します。チェックは
   `<project>-<env>-<type>`（例：`example-prod-db`）という名前で自動的に作成されます。
4. 各チェックのスケジュールを crontab と同じにします。例えば `0 1 * * 1-6` の場合：
   schedule `0 1 * * 1-6`、タイムゾーンはバックアップサーバーのもの、grace time 2 時間。

Healthchecks は、実行が失敗したとき、または期限までに結果が届かないときにアラートを送信します。
成功した実行ごとにはメッセージを送りません。成功時にも通知が必要な場合は、`collector.conf` の `REPORT_SLACK_WEBHOOK` を設定してください。

### 3.3. 注意

Healthchecks をバックアップサーバー上で動かしていて、そのバックアップサーバーが停止すると、誰もアラートを送りません。
その場合、問題を知らせるのはフォールバックのバックアップの通知（1.6）だけです。
これを避けるには、Healthchecks を別のサーバーで動かしてください。

## 4. リストア

### 4.1. データベース、ローカル PC（Windows）

1. `host/restore.bat` と `host/restore.ps1` をディレクトリにコピーし、そこにローカルのデータベース用の `backup.conf` と `my.cnf` を作成します。
   必要なのは `DB_TYPE`、`DB_NAME`、`DB_CREDENTIAL_FILE` だけです（PostgreSQL の場合は `DB_USER`、`DB_HOST`、`DB_PORT` も）。
2. バックアップファイルをダウンロードし、次を実行します：

```bat
restore.bat C:\path\to\example_prod_db_20260928_010000.zip
```

ダンプはローカル環境向けに調整されます（バックアップファイル自体は変更されません）：

* ビュー、ルーチン、トリガー、イベントの `DEFINER` は `CURRENT_USER` に置き換えられます。
  本番環境のユーザーは、通常ローカル PC には存在しません。
* `mariadb-dump` が書き出す 1 行目（`enable the sandbox mode`）は削除されます。MySQL のクライアントはこの行を読めません。
* ルーチンとトリガーの `sql_mode` から `NO_AUTO_CREATE_USER` が削除されます。MariaDB は保持しますが、MySQL 8 は受け付けません。
* MariaDB 11.4 以降のデフォルトである照合順序 `utf8mb4_uca1400_*` は、ローカルのサーバー（例えば MySQL）に存在しない場合、
  `utf8mb4_0900_*`（または `utf8mb4_unicode_ci`）に置き換えられます。
* PostgreSQL：`OWNER TO`、`GRANT`、`REVOKE` 文はスキップされます。オブジェクトの所有者はリストアを実行したユーザーになります。

### 4.2. 管理者ではないユーザーでのリストア（MySQL）

MySQL 8 はデフォルトでバイナリログが有効です。その場合、トリガーとルーチンを作成できるのは管理者だけで、
リストアは `ERROR 1419` で失敗します。管理者（例：`root`）でリストアするか、
対象のサーバーで次を一度実行してください：

```sql
SET PERSIST log_bin_trust_function_creators = 1;
```

ユーザーには、対象データベースに対するすべての権限も必要です。ユーザーがデータベースを作成できない場合は、リストアの前にデータベースを作成してください。

### 4.3. サーバーの再構築

```bash
cd /var/backup/example
unzip example_prod_full_20260928_010000.zip
/opt/webapp-backup/host/restore.sh --as-is example_prod_full_20260928_010000
cp -a example_prod_full_20260928_010000/example /var/www/
chown -R www-data:www-data /var/www/example      # Owner of files is not stored in the zip file
```
