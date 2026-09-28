[English](setup.md) | [Tiếng Việt](setup.vi.md) | [日本語](setup.ja.md)

# Hướng dẫn cài đặt

Trong hướng dẫn này, các script được cài vào `/opt/webapp-backup`, dự án có tên `example`.

## 1. Host

### 1.1. Cài đặt

```bash
sudo apt install zip unzip          # Ubuntu
sudo dnf install zip unzip          # Amazon Linux
```

Copy thư mục `host/` vào `/opt/webapp-backup/host`.

```bash
chmod +x /opt/webapp-backup/host/*.sh
```

### 1.2. User

Mọi script trên host (do backup server kích hoạt, hoặc do cron chạy) phải chạy bằng cùng một user.
User này cần quyền đọc toàn bộ file trong thư mục source.

Hãy tạo một user riêng có shell đăng nhập. Backup server kết nối bằng user này, và SSH chạy `ssh-gate.sh` thông qua shell của nó.
Không dùng user `backup`: user này đã có sẵn trên Ubuntu và Debian, với shell `/usr/sbin/nologin`.

```bash
sudo useradd -m -s /bin/bash webapp-backup
sudo install -d -o webapp-backup -g webapp-backup /var/backup
```

### 1.3. Config

```bash
cd /opt/webapp-backup/host
cp backup.conf.example backup.conf
cp my.cnf.example my.cnf            # PostgreSQL: cp pgpass.example pgpass
chmod 600 backup.conf my.cnf
```

Sửa `backup.conf` và `my.cnf`. `BACKUP_DIR` phải nằm ngoài `SOURCE_DIR`.

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
việc dump vẫn thành công, không có lỗi hay cảnh báo. Hãy kiểm tra một lần sau khi cài đặt:

```bash
unzip -p /var/backup/example/<backup file>.zip '*/db.sql' | grep -E 'CREATE .*(PROCEDURE|FUNCTION)'
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
ls -l /var/backup/example
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

```bash
cd /var/backup/example
unzip example_prod_full_20260928_010000.zip
/opt/webapp-backup/host/restore.sh --as-is example_prod_full_20260928_010000
cp -a example_prod_full_20260928_010000/example /var/www/
chown -R www-data:www-data /var/www/example      # Owner of files is not stored in the zip file
```
