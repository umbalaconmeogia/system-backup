[English](setup.md) | [Tiếng Việt](setup.vi.md) | [日本語](setup.ja.md)

# Hướng dẫn cài đặt

Trong hướng dẫn này, các script được cài vào `/opt/webapp-backup`, dự án có tên `example`.

## 1. Host

### 1.1. Cài đặt

```bash
sudo apt install zip unzip          # Ubuntu
sudo dnf install zip unzip          # Amazon Linux
```

Copy thư mục `host/` vào `/opt/webapp-backup/host`. Các script phải thuộc về root,
để user chạy backup không sửa được chúng, nhất là `ssh-gate.sh`, script giới hạn những gì backup server được làm.

```bash
sudo chown -R root:root /opt/webapp-backup
sudo chmod 755 /opt/webapp-backup/host/*.sh
```

### 1.2. User

Mọi script trên host (do backup server kích hoạt, hoặc do cron chạy) phải chạy bằng cùng một user.
User này cần quyền đọc toàn bộ file trong thư mục source.
Nếu có file không đọc được, việc backup thất bại và danh sách các file đó được ghi vào log (xem `FAIL_ON_UNREADABLE` trong `backup.conf`).

Hãy tạo một user riêng có shell đăng nhập. Backup server kết nối bằng user này, và SSH chạy `ssh-gate.sh` thông qua shell của nó.
Không dùng user `backup`: user này đã có sẵn trên Ubuntu và Debian, với shell `/usr/sbin/nologin`.

```bash
sudo useradd -m -s /bin/bash webapp-backup
sudo install -d -m 700 -o webapp-backup -g webapp-backup /var/webapp-backup
```

#### Thư mục source thuộc về user khác

Khi thư mục source thuộc về một user khác, ví dụ `/home/deploy/example.com`,
hãy cấp cho `webapp-backup` quyền đọc bằng ACL (Access Control List).
ACL thêm quyền cho một user nữa trên file và thư mục, mà không thay đổi quyền của chủ sở hữu và của các user khác.

```bash
sudo apt install acl                                                   # Amazon Linux: sudo dnf install acl
sudo setfacl -m u:webapp-backup:x /home/deploy
sudo setfacl -R -m u:webapp-backup:rX /home/deploy/example.com
sudo setfacl -R -d -m u:webapp-backup:rX /home/deploy/example.com
```

| Lệnh | Tác dụng |
|---|---|
| `setfacl -m u:webapp-backup:x /home/deploy` | `webapp-backup` được đi qua thư mục home, nhưng không xem được danh sách file trong đó. Cần làm với mỗi thư mục trên đường dẫn chưa cho phép điều này (trên Ubuntu, thư mục home có quyền `750`) |
| `setfacl -R -m u:webapp-backup:rX ...` | `webapp-backup` đọc được mọi file hiện có. `X` (viết hoa) cho phép vào thư mục, không cho chạy file |
| `setfacl -R -d -m u:webapp-backup:rX ...` | ACL mặc định: file và thư mục tạo sau này cũng đọc được |

ACL mặc định không có tác dụng trong vài trường hợp: file bị đổi quyền sau khi tạo (ví dụ `chmod 600`),
và file riêng tư được chuyển (`mv`) hoặc copy bằng `cp -p` vào thư mục source.
Khi đó backup thất bại và các file đó được liệt kê trong log. Chạy lại `sudo setfacl -R -m u:webapp-backup:rX /home/deploy/example.com` để khắc phục.

### 1.3. Config

```bash
cd /opt/webapp-backup/host
sudo cp backup.conf.example backup.conf
sudo cp my.cnf.example my.cnf
sudo chown root:webapp-backup backup.conf my.cnf
sudo chmod 640 backup.conf my.cnf
```

User `webapp-backup` đọc được các file config nhưng không sửa được. User khác không đọc được.

Với PostgreSQL, tạo `pgpass` thay cho `my.cnf`. File này phải thuộc về `webapp-backup` với quyền `600`:
client của PostgreSQL bỏ qua file nếu group của nó có quyền đọc.

```bash
sudo install -o webapp-backup -g webapp-backup -m 600 pgpass.example pgpass
```

Sửa `backup.conf` và `my.cnf` (hoặc `pgpass`) bằng `sudo`. `BACKUP_DIR` phải nằm ngoài `SOURCE_DIR`.

User của database cần quyền để dump database.

MySQL 8.0.20 trở lên:

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON example_db.* TO 'backup_user'@'localhost';
GRANT SHOW_ROUTINE ON *.* TO 'backup_user'@'localhost';
```

MariaDB 11.3 trở lên:

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, SHOW CREATE ROUTINE ON example_db.* TO 'backup_user'@'localhost';
```

MariaDB cũ hơn: thay `SHOW CREATE ROUTINE ON example_db.*` bằng `GRANT SELECT ON mysql.proc`.

**Nếu thiếu quyền đọc routine, stored procedure và function sẽ bị thiếu trong file backup mà không có thông báo gì**:
việc dump vẫn thành công, không có lỗi hay cảnh báo. Hãy kiểm tra một lần sau khi cài đặt, trước khi bật mã hóa (mục 1.7):

```bash
unzip -p /var/webapp-backup/example/<backup file>.zip '*/db.sql' | grep -E 'CREATE .*(PROCEDURE|FUNCTION)'
```

Cần thêm quyền `PROCESS` nếu bỏ `--no-tablespaces` khỏi tham số dump.

PostgreSQL 14 trở lên:

```sql
GRANT pg_read_all_data TO backup_user;
```

Phiên bản `pg_dump` trên host không được cũ hơn PostgreSQL server
(ví dụ, `pg_dump` 16 của Ubuntu 24.04 không dump được PostgreSQL 17 server).

### 1.4. Chạy thử

```bash
./backup.sh db
./backup.sh full
ls -l /var/webapp-backup/example
```

### 1.5. Cho phép backup server kết nối

Thêm public key của backup server (tạo ở mục 2.2) vào `~/.ssh/authorized_keys` của user, trên một dòng:

```
command="/opt/webapp-backup/host/ssh-gate.sh /opt/webapp-backup/host/backup.conf",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... backup-server
```

Với key này, backup server chỉ có thể tạo backup, liệt kê và đọc các file backup của dự án này.

Nếu một host có nhiều dự án, dùng một file config và một key cho mỗi dự án.

### 1.6. Dự phòng

Nếu backup server không kích hoạt backup (ví dụ, server đó ngừng hoạt động), host sẽ tự tạo backup.
Thêm vào crontab của user (xem [crontab.example](../host/crontab.example)), giờ chạy phải muộn hơn lịch của backup server:

```
0 5 * * * /opt/webapp-backup/host/backup.sh --if-missing db > /dev/null 2>&1
```

Khi bản backup dự phòng được tạo, thông báo được gửi tới `NOTIFY_SLACK_WEBHOOK` và `NOTIFY_MAIL` trong `backup.conf`.
File sẽ được backup server kéo về ở lượt chạy kế tiếp.

### 1.7. Mã hóa (tùy chọn)

Mã hóa file backup để nếu file bị lọt ra ngoài (bị copy về máy cá nhân, gửi nhầm...) thì cũng không đọc được.
Host mã hóa bằng public key của gpg. Private key, dùng để giải mã, do người quản lý giữ:
không nằm trên host, cũng không nằm trên backup server.

1. Trên máy của người quản lý (không phải trên host), tạo cặp key. Đặt passphrase mạnh khi được hỏi.
   Thời hạn phải là `never`: khi key hết hạn, backup sẽ thất bại.

   ```bash
   gpg --quick-generate-key "example backup <backup@example.com>" default default never
   gpg --armor --export backup@example.com > example-backup.pub.asc
   gpg --armor --export-secret-keys backup@example.com > example-backup.secret.asc
   ```

2. Cất `example-backup.secret.asc` và passphrase của nó ở ít nhất hai nơi an toàn
   (ví dụ, trình quản lý mật khẩu và một USB không kết nối mạng), rồi xóa file khỏi máy.
   **Nếu mất private key hoặc passphrase, toàn bộ các bản backup đã mã hóa sẽ mất theo.**
3. Copy public key lên host, đặt cạnh `backup.conf`:

   ```bash
   sudo install -o root -g webapp-backup -m 640 example-backup.pub.asc /opt/webapp-backup/host/
   ```

   Rồi đặt trong `backup.conf`: `ENCRYPT_PUBLIC_KEY_FILE=example-backup.pub.asc`.
   `gpg` thường đã được cài sẵn (kiểm tra bằng `gpg --version`). Nếu chưa có, trên Ubuntu: `sudo apt install gnupg`.
4. Chạy `./backup.sh db`: lệnh này tạo `<tên>.zip.gpg`. Tải file về máy của người quản lý và giải mã:

   ```bash
   gpg --output example.zip --decrypt example_prod_db_20260928_010000.zip.gpg
   unzip -l example.zip
   ```

Hãy thử giải mã định kỳ, ví dụ mỗi khi restore một bản backup về máy local (mục 4.1).

* Tên các file bên trong zip cũng được mã hóa. Chỉ nhìn thấy tên của file backup (dự án, môi trường, loại, ngày giờ).
* Trong lúc mã hóa, file zip và file đã mã hóa cùng tồn tại trong `BACKUP_DIR`: cần dung lượng trống gấp đôi một bản backup.
* Để chắc chắn backup của một dự án luôn được mã hóa, đặt `REQUIRE_ENCRYPTION` trên backup server (mục 2.3).

## 2. Backup server

### 2.1. Cài đặt

Copy thư mục `collector/` vào `/opt/webapp-backup/collector`.

```bash
chmod +x /opt/webapp-backup/collector/*.sh
```

### 2.2. SSH key

Tạo một key cho mỗi dự án, không đặt passphrase:

```bash
ssh-keygen -t ed25519 -N "" -C backup-server -f ~/.ssh/example_ed25519
```

Đăng ký nội dung của `~/.ssh/example_ed25519.pub` trên host (xem mục 1.5), rồi kết nối một lần để chấp nhận host key:

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

Sửa cả hai file. `PROJECT` và `ENV` phải giống với `backup.conf` trên host.

Nếu host mã hóa file backup (mục 1.7), hãy đặt `REQUIRE_ENCRYPTION=1`, trong `collector.conf` cho mọi dự án hoặc trong `projects.d/example.conf`.
Khi đó, bản backup không được mã hóa, ví dụ do lỡ xóa `ENCRYPT_PUBLIC_KEY_FILE`, sẽ không được kéo về, và lượt chạy thất bại.
Backup server không cần `gpg` và không cần key.

### 2.4. Chạy thử

```bash
./collect.sh example db
ls -l /backup/example
```

### 2.5. Lịch chạy

Thêm vào crontab (xem [crontab.example](../collector/crontab.example)):

```
0 1 * * 1-6 /opt/webapp-backup/collector/collect.sh example db > /dev/null 2>&1
0 1 * * 0   /opt/webapp-backup/collector/collect.sh example full > /dev/null 2>&1
```

## 3. Healthchecks

### 3.1. Cài đặt

Healthchecks cung cấp Docker image và cấu hình mẫu.
Xem chi tiết ở [Running with Docker](https://healthchecks.io/docs/self_hosted_docker/).

```bash
git clone https://github.com/healthchecks/healthchecks.git
cd healthchecks/docker
cp .env.example .env
# Edit .env: ALLOWED_HOSTS, SITE_ROOT, SECRET_KEY, DEFAULT_FROM_EMAIL, EMAIL_HOST, EMAIL_HOST_USER, EMAIL_HOST_PASSWORD
docker compose up -d
docker compose run web /opt/healthchecks/manage.py createsuperuser
```

Healthchecks lắng nghe ở cổng 8000. Hãy đặt nó sau một reverse proxy xử lý HTTPS.

### 3.2. Config

1. Tạo một project. Trong Settings của project, tạo **Ping key**.
   Đặt `HC_PING_BASE` trong `collector.conf` thành `<SITE_ROOT>/ping/<ping key>`.
2. Trong Integrations, thêm **Email** và **Slack**.
3. Chạy `collect.sh` một lần cho mỗi dự án và mỗi loại backup. Các check được tạo tự động,
   với tên `<project>-<env>-<type>` (ví dụ `example-prod-db`).
4. Đặt lịch của mỗi check giống với crontab. Ví dụ, với `0 1 * * 1-6`:
   schedule `0 1 * * 1-6`, múi giờ của backup server, grace time 2 giờ.

Healthchecks gửi cảnh báo khi một lượt chạy thất bại, hoặc khi quá hạn mà không nhận được kết quả.
Nó không gửi tin nhắn cho mỗi lượt chạy thành công. Muốn nhận tin đó, hãy đặt `REPORT_SLACK_WEBHOOK` trong `collector.conf`.

### 3.3. Lưu ý

Nếu Healthchecks chạy trên backup server và backup server ngừng hoạt động, sẽ không ai gửi cảnh báo.
Khi đó, chỉ có thông báo của bản backup dự phòng (mục 1.6) cho biết có sự cố.
Để tránh điều này, hãy chạy Healthchecks trên một server khác.

## 4. Restore

### 4.1. Database, trên máy local (Windows)

1. Copy `host/restore.bat`, `host/restore.ps1` vào một thư mục, tạo `backup.conf` và `my.cnf` của database local ở đó.
   Chỉ cần `DB_TYPE`, `DB_NAME`, `DB_CREDENTIAL_FILE` (và `DB_USER`, `DB_HOST`, `DB_PORT` với PostgreSQL).
2. Tải file backup về, rồi chạy:

```bat
restore.bat C:\path\to\example_prod_db_20260928_010000.zip
```

Với bản backup đã mã hóa (`.zip.gpg`), cài [Gpg4win](https://www.gpg4win.org/) và import private key một lần:
`gpg --import example-backup.secret.asc`. Sau đó chạy `restore.bat` với file `.zip.gpg`, lệnh này sẽ hỏi passphrase.

Dump được điều chỉnh cho môi trường local (bản thân file backup không bị sửa):

* `DEFINER` của view, routine, trigger và event được thay bằng `CURRENT_USER`.
  User của production thường không tồn tại trên máy local.
* Dòng đầu tiên do `mariadb-dump` ghi (`enable the sandbox mode`) được bỏ đi. Client của MySQL không đọc được dòng này.
* `NO_AUTO_CREATE_USER` được bỏ khỏi `sql_mode` của routine và trigger. MariaDB giữ nó, MySQL 8 không chấp nhận.
* Các collation `utf8mb4_uca1400_*`, mặc định của MariaDB 11.4 trở lên, được thay bằng `utf8mb4_0900_*`
  (hoặc `utf8mb4_unicode_ci`) khi server local không có chúng, ví dụ MySQL.
* PostgreSQL: bỏ qua các lệnh `OWNER TO`, `GRANT` và `REVOKE`. Các object thuộc về user thực hiện restore.

### 4.2. Restore bằng user không phải quản trị viên (MySQL)

MySQL 8 bật binary logging mặc định. Khi đó chỉ quản trị viên mới tạo được trigger và routine,
và việc restore thất bại với `ERROR 1419`. Hãy restore bằng quản trị viên (ví dụ `root`),
hoặc chạy lệnh sau một lần trên server đích:

```sql
SET PERSIST log_bin_trust_function_creators = 1;
```

User cũng cần toàn quyền trên database đích. Nếu user không tạo được database, hãy tạo database trước khi restore.

### 4.3. Dựng lại server

Với bản backup đã mã hóa, import private key trước (`gpg --import example-backup.secret.asc`),
và xóa nó sau khi restore xong (`gpg --delete-secret-keys backup@example.com`).

```bash
cd /var/webapp-backup/example
gpg --output example_prod_full_20260928_010000.zip --decrypt example_prod_full_20260928_010000.zip.gpg   # Encrypted backup only
unzip example_prod_full_20260928_010000.zip
/opt/webapp-backup/host/restore.sh --as-is example_prod_full_20260928_010000
cp -a example_prod_full_20260928_010000/example /var/www/
chown -R www-data:www-data /var/www/example      # Owner of files is not stored in the zip file
```
