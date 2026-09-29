[English](setup.md) | [Tiếng Việt](setup.vi.md) | [日本語](setup.ja.md)

# セットアップガイド

このガイドでは、スクリプトを `/opt/webapp-backup` にインストールし、プロジェクト名を `example` とします。

## 1. ホスト

### 1.1. インストール

```bash
sudo apt install zip unzip          # Ubuntu
sudo dnf install zip unzip          # Amazon Linux
```

ディレクトリ `host/` を `/opt/webapp-backup/host` にコピーします。スクリプトの所有者は root にしてください。
バックアップを実行するユーザーがスクリプトを変更できないようにするためです。特に `ssh-gate.sh` は、バックアップサーバーにできることを制限しています。

```bash
sudo chown -R root:root /opt/webapp-backup
sudo chmod 755 /opt/webapp-backup/host/*.sh
```

### 1.2. ユーザー

ホスト上のすべてのスクリプト（バックアップサーバーから起動されるもの、cron で実行されるもの）は、同じユーザーで実行する必要があります。
このユーザーには、ソースディレクトリのすべてのファイルを読む権限が必要です。
読めないファイルがあるとバックアップは失敗し、それらのファイルがログに出力されます（`backup.conf` の `FAIL_ON_UNREADABLE` を参照）。

ログインシェルを持つ専用ユーザーを作成してください。バックアップサーバーはこのユーザーで接続し、SSH はそのシェルを通して `ssh-gate.sh` を実行します。
ユーザー `backup` は使わないでください。Ubuntu と Debian には既に存在し、シェルが `/usr/sbin/nologin` になっています。

```bash
sudo useradd -m -s /bin/bash webapp-backup
sudo install -d -m 700 -o webapp-backup -g webapp-backup /var/webapp-backup
```

#### 他のユーザーが所有するソースディレクトリ

ソースディレクトリが他のユーザーのもの（例：`/home/deploy/example.com`）である場合は、
ACL（Access Control List）で `webapp-backup` に読み取り権限を与えます。
ACL は、所有者や他のユーザーのパーミッションを変えずに、ファイルとディレクトリに特定のユーザーの権限を追加します。

```bash
sudo apt install acl                                                   # Amazon Linux: sudo dnf install acl
sudo setfacl -m u:webapp-backup:x /home/deploy
sudo setfacl -R -m u:webapp-backup:rX /home/deploy/example.com
sudo setfacl -R -d -m u:webapp-backup:rX /home/deploy/example.com
```

| コマンド | 効果 |
|---|---|
| `setfacl -m u:webapp-backup:x /home/deploy` | `webapp-backup` はホームディレクトリを通過できますが、中のファイル一覧は見られません。パス上でこれを許可していない各ディレクトリに必要です（Ubuntu のホームディレクトリのパーミッションは `750`） |
| `setfacl -R -m u:webapp-backup:rX ...` | `webapp-backup` は既存のすべてのファイルを読めます。`X`（大文字）はディレクトリへの移動だけを許可し、ファイルの実行は許可しません |
| `setfacl -R -d -m u:webapp-backup:rX ...` | デフォルト ACL：後から作成されるファイルとディレクトリも読めます |

デフォルト ACL が効かない場合がいくつかあります：作成後にパーミッションが変更されたファイル（例：`chmod 600`）、
非公開のファイルを `mv` で移動した場合や `cp -p` でソースディレクトリにコピーした場合です。
そのときはバックアップが失敗し、該当ファイルがログに出力されます。`sudo setfacl -R -m u:webapp-backup:rX /home/deploy/example.com` を再実行して対処してください。

### 1.3. 設定

```bash
cd /opt/webapp-backup/host
sudo cp backup.conf.example backup.conf
sudo cp my.cnf.example my.cnf
sudo chown root:webapp-backup backup.conf my.cnf
sudo chmod 640 backup.conf my.cnf
```

ユーザー `webapp-backup` は設定ファイルを読めますが、変更はできません。他のユーザーは読めません。

PostgreSQL の場合は、`my.cnf` の代わりに `pgpass` を作成します。所有者は `webapp-backup`、パーミッションは `600` にしてください。
グループが読める状態だと、PostgreSQL のクライアントはこのファイルを無視します。

```bash
sudo install -o webapp-backup -g webapp-backup -m 600 pgpass.example pgpass
```

`backup.conf` と `my.cnf`（または `pgpass`）は `sudo` で編集します。`BACKUP_DIR` は `SOURCE_DIR` の外に置く必要があります。

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
ダンプはエラーも警告もなく成功します。セットアップ後、暗号化（1.7）を有効にする前に一度確認してください：

```bash
unzip -p /var/webapp-backup/example/<backup file>.zip '*/db.sql' | grep -E 'CREATE .*(PROCEDURE|FUNCTION)'
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
ls -l /var/webapp-backup/example
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

### 1.7. 暗号化（任意）

バックアップファイルを暗号化すると、ファイルが外部に漏れた場合（PC にコピーされた、誤って送信されたなど）でも読まれません。
ホストは gpg の公開鍵で暗号化します。復号に必要な秘密鍵は管理者が保管し、
ホストにもバックアップサーバーにも置きません。

1. 管理者の PC（ホストではなく）で鍵ペアを作成します。聞かれたら強いパスフレーズを設定してください。
   有効期限は `never` にする必要があります。鍵の有効期限が切れると、バックアップが失敗します。

   ```bash
   gpg --quick-generate-key "example backup <backup@example.com>" default default never
   gpg --armor --export backup@example.com > example-backup.pub.asc
   gpg --armor --export-secret-keys backup@example.com > example-backup.secret.asc
   ```

2. `example-backup.secret.asc` とそのパスフレーズを、少なくとも 2 か所の安全な場所
   （例えば、パスワードマネージャーとオフラインの USB メモリ）に保管し、PC からファイルを削除します。
   **秘密鍵またはパスフレーズを失うと、暗号化されたすべてのバックアップが失われます。**
3. 公開鍵をホストの `backup.conf` と同じ場所にコピーします：

   ```bash
   sudo install -o root -g webapp-backup -m 640 example-backup.pub.asc /opt/webapp-backup/host/
   ```

   そして `backup.conf` に設定します：`ENCRYPT_PUBLIC_KEY_FILE=example-backup.pub.asc`。
   `gpg` は通常インストール済みです（`gpg --version` で確認）。ない場合、Ubuntu では `sudo apt install gnupg`。
4. `./backup.sh db` を実行すると `<name>.zip.gpg` が作成されます。ファイルを管理者の PC にダウンロードし、復号します：

   ```bash
   gpg --output example.zip --decrypt example_prod_db_20260928_010000.zip.gpg
   unzip -l example.zip
   ```

定期的に復号を試してください。例えば、バックアップをローカル PC にリストアするとき（4.1）です。

* zip の中のファイル名も暗号化されます。見えるのはバックアップファイルの名前（プロジェクト、環境、種類、日時）だけです。
* 暗号化の間は、zip ファイルと暗号化されたファイルの両方が `BACKUP_DIR` に存在します。バックアップ 2 つ分の空き容量が必要です。
* プロジェクトのバックアップが必ず暗号化されるようにするには、バックアップサーバーで `REQUIRE_ENCRYPTION` を設定します（2.3）。

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

ホストがバックアップを暗号化する場合（1.7）は、`REQUIRE_ENCRYPTION=1` を設定します。すべてのプロジェクトには `collector.conf` に、
プロジェクトごとには `projects.d/example.conf` に設定します。すると、暗号化されていないバックアップ（例えば `ENCRYPT_PUBLIC_KEY_FILE` を誤って消した場合）は
取得されず、実行は失敗します。バックアップサーバーには `gpg` も鍵も不要です。

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

暗号化されたバックアップ（`.zip.gpg`）の場合は、[Gpg4win](https://www.gpg4win.org/) をインストールし、秘密鍵を一度インポートします：
`gpg --import example-backup.secret.asc`。その後 `.zip.gpg` ファイルを指定して `restore.bat` を実行すると、パスフレーズを聞かれます。

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

暗号化されたバックアップの場合は、先に秘密鍵をインポートし（`gpg --import example-backup.secret.asc`）、
リストアの後で削除します（`gpg --delete-secret-keys backup@example.com`）。

```bash
cd /var/webapp-backup/example
gpg --output example_prod_full_20260928_010000.zip --decrypt example_prod_full_20260928_010000.zip.gpg   # Encrypted backup only
unzip example_prod_full_20260928_010000.zip
/opt/webapp-backup/host/restore.sh --as-is example_prod_full_20260928_010000
cp -a example_prod_full_20260928_010000/example /var/www/
chown -R www-data:www-data /var/www/example      # Owner of files is not stored in the zip file
```
