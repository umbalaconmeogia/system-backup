# Webapp backup - Specification

Tài liệu này cụ thể hóa requirement thành spec để triển khai.

## 1. Phạm vi

| Hạng mục | Trong phạm vi | Ghi chú |
|---|---|---|
| Backup DB | MySQL/MariaDB, PostgreSQL | |
| Backup source | Nguyên cả thư mục source, **không loại trừ** | Mục đích: khôi phục nhanh khi hỏng ổ cứng, xóa nhầm file |
| Backup trọn gói | DB + source trong cùng 1 lượt | |
| Restore DB | Từ file backup, trên Linux và trên máy local Windows | Restore source làm bằng tay (giải nén, copy) |
| Thu thập về backup server | Backup server kích hoạt backup rồi kéo file về | |
| Giám sát, báo cáo | Healthchecks tự host (mail, Slack) | Không tự viết |
| Hệ điều hành của server hệ thống | Linux (Ubuntu, Amazon Linux) | Windows làm sau |
| Docker | Không xử lý riêng | Docker tạo gì trong thư mục source thì backup nguyên cái đó |
| Mã hóa file backup | Ngoài phạm vi | |

## 2. Thành phần

| Thành phần | Chạy ở đâu | Vai trò |
|---|---|---|
| `host/` | Server hệ thống | Tạo backup, restore, tự xóa backup cũ, cổng SSH giới hạn |
| `collector/` | Backup server | Kích hoạt backup, kéo file về, kiểm tra, báo kết quả cho Healthchecks |
| Healthchecks | Backup server (hoặc máy khác) | Theo dõi lịch, gửi mail và Slack khi có sự cố |

Nguyên tắc: script giống hệt nhau giữa các dự án, mọi khác biệt nằm trong file config.
File config thật (`backup.conf`, `my.cnf`, `collector.conf`, `projects.d/*.conf`) không commit vào git.

## 3. Luồng chính

```
Backup server (cron)                         Server hệ thống
--------------------                         ---------------
collect.sh example db
  ping Healthchecks /start
  ssh "backup db"            ------------->  ssh-gate.sh -> backup.sh db
                                               dump DB, nén zip, ghi .sha256
                             <-------------  in ra tên file
  ssh "list"                 ------------->  danh sách file đã hoàn tất
  ssh "get <file>"           ------------->  nội dung file
  kiểm tra sha256
  xóa backup cũ (trên backup server)
  ping Healthchecks (thành công / thất bại, kèm log)
```

* Chỉ backup server kết nối được vào server hệ thống, không có chiều ngược lại.
* Mọi bước chạy tuần tự trong 1 job nên không có vấn đề bất đồng bộ.
* Lịch chạy của tất cả dự án nằm tập trung trong crontab của backup server.

### Dự phòng khi backup server không gọi

Trên server hệ thống đặt thêm 1 cron chạy muộn hơn giờ backup thường lệ:

```
0 5 * * * /opt/webapp-backup/host/backup.sh db --if-missing
```

`--if-missing`: nếu hôm nay đã có bản backup thì không làm gì; nếu chưa có thì tự tạo backup vào thư mục local
và gửi thông báo (Slack, mail) trực tiếp từ server hệ thống, nếu có thiết lập.
Khi backup server hoạt động lại, lượt `collect.sh` kế tiếp sẽ kéo cả các bản này về.

## 4. Host

### 4.1. Config (`backup.conf`)

| Khóa | Bắt buộc | Ý nghĩa |
|---|---|---|
| `PROJECT` | Có | Tên dự án, dùng trong tên file |
| `ENV` | Có | `prod`, `stag`... |
| `BACKUP_DIR` | Có | Nơi lưu backup, **phải nằm ngoài** `SOURCE_DIR` |
| `DB_TYPE` | Có | `mysql`, `pgsql`, `none` |
| `DB_NAME` | Nếu có DB | Tên database |
| `DB_CREDENTIAL_FILE` | Nếu có DB | `my.cnf` (MySQL) hoặc `.pgpass` (PostgreSQL) |
| `DB_HOST`, `DB_PORT`, `DB_USER` | PostgreSQL | Với MySQL, các giá trị này nằm trong `my.cnf` |
| `DB_DUMP_OPTIONS` | Không | Ghi đè tham số dump mặc định |
| `SOURCE_DIR` | Nếu backup source | Thư mục source |
| `KEEP_DAYS` | Không (30) | Xóa backup tự động cũ hơn số ngày này |
| `KEEP_MIN` | Không (7) | Luôn giữ ít nhất số bản này, tính theo từng loại backup |
| `NOTIFY_SLACK_WEBHOOK`, `NOTIFY_MAIL` | Không | Nơi nhận thông báo khi chạy dự phòng |

### 4.2. Quy ước tên và cấu trúc

Tên file: `<PROJECT>_<ENV>_<type>_<yyyymmdd>_<HHMMSS>[_<label>].zip`

* `type`: `db`, `source`, `full`.
* `label`: tùy chọn, dùng khi chạy tay (ví dụ `before_fix_bug_25576`).

Ví dụ `example_prod_full_20260928_010000.zip` giải nén ra:

```
example_prod_full_20260928_010000/
  manifest.txt        # project, env, type, loại DB, tên DB, hostname, thời điểm
  db.sql              # tên cố định, không phụ thuộc tên DB
  example/                # thư mục source, giữ nguyên tên và cấu trúc
```

* Tên file DB cố định là `db.sql` nên restore không cần đổi tên file.
* Zip lưu symlink dưới dạng symlink và giữ quyền file. Chủ sở hữu (owner) không được giữ, cần `chown` lại khi khôi phục source.

### 4.3. Tạo file an toàn

1. Nén vào `<tên>.zip.part`.
2. Kiểm tra zip, xong mới đổi tên thành `<tên>.zip`.
3. Ghi `<tên>.zip.sha256` **sau cùng**.

Chỉ file đã có `.sha256` mới được coi là hoàn tất và mới xuất hiện trong lệnh `list`.

### 4.4. Dump DB

* Nguyên tắc: **file backup giữ nguyên bản, mọi chỉnh sửa thực hiện lúc restore**.
* MySQL mặc định: `--single-transaction --routines --triggers --events --no-tablespaces --default-character-set=utf8mb4`.
* PostgreSQL mặc định: `--format=plain --clean --if-exists`.
* Mật khẩu không truyền qua dòng lệnh, chỉ đọc từ `DB_CREDENTIAL_FILE`.
* Dump lỗi thì dừng, không tạo zip, exit code khác 0.

### 4.5. Xóa backup cũ

* Chạy cuối mỗi lần backup thành công.
* Tuổi của file tính theo ngày giờ trong tên file.
* Xóa file cũ hơn `KEEP_DAYS`, nhưng mỗi loại backup luôn giữ ít nhất `KEEP_MIN` bản mới nhất.
* File có `label` không bao giờ tự xóa.

### 4.6. Cổng SSH (`ssh-gate.sh`)

SSH key của backup server bị ép chạy `ssh-gate.sh` (khai báo `command=` trong `authorized_keys`). Chỉ 3 lệnh được phép:

| Lệnh | Tác dụng |
|---|---|
| `backup <db\|source\|full>` | Chạy `backup.sh`, in ra tên file vừa tạo |
| `list` | Liệt kê các file backup đã hoàn tất |
| `get <tên file>` | Trả về nội dung 1 file trong `BACKUP_DIR` |

Tên file trong lệnh `get` chỉ được chứa chữ, số, `.`, `_`, `-` và phải bắt đầu bằng `<PROJECT>_<ENV>_`.
Backup server không có quyền xóa hay sửa file trên server hệ thống.

### 4.7. Restore DB

```
restore.sh [--config FILE] [--as-is] [--yes] <thư mục backup | file zip | db.sql>
```

* DB đích lấy từ config của môi trường restore, không lấy từ file backup.
* Mặc định, dump được điều chỉnh để restore sang môi trường khác (ví dụ máy local):
  * MySQL: thay `DEFINER=...` bằng `DEFINER=CURRENT_USER`.
  * PostgreSQL: bỏ các lệnh `OWNER TO`, `GRANT`, `REVOKE`.
* `--as-is`: restore nguyên bản, dùng khi dựng lại chính server gốc.
* Luôn bỏ dòng đầu `/*!999999\- enable the sandbox mode */` do mariadb-dump sinh ra (MySQL).
* Trên Windows dùng `restore.bat` (gọi `restore.ps1`): `restore.bat [-Config FILE] [-AsIs] [-Yes] <đường dẫn>`.

## 5. Collector

### 5.1. Config

`collector.conf` (chung):

| Khóa | Ý nghĩa |
|---|---|
| `HC_PING_BASE` | `https://<healthchecks>/ping/<ping-key>`. Để trống thì không ping |
| `HC_AUTO_CREATE` | `1`: tự tạo check trên Healthchecks nếu chưa có |
| `REPORT_SLACK_WEBHOOK` | Tùy chọn. Gửi 1 dòng kết quả sau mỗi lượt chạy, kể cả khi thành công |
| `MIN_FREE_MB` | Dung lượng trống tối thiểu, thiếu thì báo lỗi |
| `SIZE_DROP_LIMIT` | Báo lỗi nếu file mới nhỏ hơn bản trước quá số phần trăm này (0: tắt) |

`projects.d/<tên>.conf` (mỗi dự án 1 file):

| Khóa | Ý nghĩa |
|---|---|
| `PROJECT`, `ENV` | Phải khớp với `backup.conf` trên server hệ thống |
| `SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_KEY` | Thông tin kết nối |
| `LOCAL_DIR` | Nơi lưu trên backup server |
| `KEEP_DAYS`, `KEEP_MIN` | Thời gian lưu trên backup server |

### 5.2. Lệnh

```
collect.sh <tên config> <db|source|full>    # kích hoạt backup rồi kéo về
collect.sh <tên config> sync                # chỉ kéo các file chưa có
```

Mỗi lượt chạy đều kéo **mọi** file đã hoàn tất mà backup server chưa có,
gồm cả bản chạy tay có label và bản tạo bởi cron dự phòng.

### 5.3. Healthchecks

* Mỗi cặp dự án + loại backup là 1 check, slug `<project>-<env>-<type>` (chữ thường).
* `collect.sh` ping `/start` khi bắt đầu, ping thành công hoặc `/fail` khi kết thúc, kèm log.
* Lịch và thời gian chờ của từng check thiết lập trên giao diện Healthchecks, khớp với crontab.
* Healthchecks báo khi: job báo lỗi, hoặc quá hạn mà không nhận được ping.

Healthchecks chỉ gửi thông báo khi trạng thái thay đổi (hỏng, hồi phục) và gửi mail tổng hợp định kỳ.
Muốn nhận tin sau mỗi lượt chạy thành công thì dùng `REPORT_SLACK_WEBHOOK`.

## 6. Thứ tự triển khai

1. host: backup, restore, xóa backup cũ, cổng SSH (Linux, MySQL và PostgreSQL).
2. collector: kích hoạt, kéo file, kiểm tra, ping Healthchecks.
3. Tài liệu cài đặt, gồm Healthchecks tự host.
4. Bản Windows của host (PowerShell).
