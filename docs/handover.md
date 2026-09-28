# Bàn giao: kiểm thử trên Ubuntu

Tài liệu này dành cho người (hoặc AI) tiếp tục công việc trên máy Ubuntu.
Ngày bàn giao: 2026-09-28.

## 1. Trạng thái hiện tại

Code được viết trên Windows và **chưa từng chạy trên Linux thật**.
Việc chính cần làm trên Ubuntu là kiểm thử với công cụ thật, sửa lỗi phát hiện được, rồi dựng bộ test Docker.

| Hạng mục | Trạng thái |
|---|---|
| `host/backup.sh`, `host/ssh-gate.sh`, `host/restore.sh` | Đã viết, mới kiểm thử bằng chương trình giả |
| `collector/collect.sh` | Đã viết, mới kiểm thử bằng chương trình giả |
| `host/restore.bat`, `host/restore.ps1` | Đã chạy trên Windows với `mysql` giả, chưa chạy với DB thật |
| `tests/run-tests.sh` | 77/78 mục đạt trên Git Bash (Windows) |
| Test Docker, GitHub Actions | Chưa làm |
| Bản Windows của host | Chưa làm, để sau |

Mục test không đạt trên Windows là `symbolic link is stored as link`. Nguyên nhân là Git Bash không có symlink thật
và không có `zip` (phải dùng chương trình thay thế). Trên Ubuntu mục này phải đạt.

## 2. Đọc trước

| Tài liệu | Nội dung |
|---|---|
| [spec.md](spec.md) | Thiết kế: luồng xử lý, quy ước tên file, config, các lệnh |
| [setup.md](setup.md) | Hướng dẫn cài đặt host, backup server, Healthchecks |
| [README.md](../README.md) | Giới thiệu |

## 3. Các quyết định đã chốt

| Quyết định | Lý do |
|---|---|
| Backup server kích hoạt backup qua SSH rồi kéo file về | Chỉ backup server truy cập được host, không có chiều ngược lại. Chạy tuần tự nên không có vấn đề bất đồng bộ |
| Host có cron dự phòng `backup.sh --if-missing` | Vẫn có backup khi backup server ngừng hoạt động |
| Backup source nguyên cả thư mục, không loại trừ | Mục đích là khôi phục nhanh khi hỏng ổ cứng, xóa nhầm file |
| File backup là zip, bên trong có thư mục cùng tên | Tải về là mở được, không cần công cụ riêng |
| Giám sát bằng Healthchecks tự host | Không tự viết phần theo dõi lịch và gửi mail, Slack |
| Kéo file bằng lệnh `get` qua SSH, không dùng `rsync` | Không cần cài thêm gì trên host, kiểm soát tên file chặt |
| Không xử lý riêng Docker, không mã hóa file backup | Ngoài phạm vi |
| Ưu tiên dùng công cụ có sẵn | Chỉ tự viết phần mà công cụ có sẵn không đáp ứng |

## 4. Việc cần làm, theo thứ tự

### Bước 1: Chạy test có sẵn

```bash
sudo apt install zip unzip
git clone https://github.com/umbalaconmeogia/webapp-backup.git
cd webapp-backup
bash tests/run-tests.sh
```

Kết quả mong đợi: `Passed: 78, failed: 0`. Khi một mục không đạt, test in kèm output của lệnh bị lỗi.

Bộ test này thay `mysqldump`, `mysql`, `ssh`, `curl` bằng chương trình giả,
nhưng dùng `zip`, `unzip`, `flock`, `sha256sum` thật của máy.

### Bước 2: Dựng bộ test Docker

Đặc tả ở mục 5.

### Bước 3: GitHub Actions

Tạo `.github/workflows/test.yml` chạy cả `tests/run-tests.sh` và bộ test Docker mỗi lần push và pull request.

### Bước 4: Chạy thử trên một server thật

Làm theo [setup.md](setup.md) với một dự án thật, kèm Healthchecks thật.
Kiểm tra cả 2 trường hợp: mail và Slack báo khi backup thất bại, và báo khi quá hạn không có backup.

## 5. Đặc tả bộ test Docker

### 5.1. Mục tiêu

Chạy trọn luồng thật, không dùng chương trình giả: backup, kéo file qua `sshd` thật, restore vào DB thật, so sánh dữ liệu.

### 5.2. Các container

| Container | Image gợi ý | Vai trò |
|---|---|---|
| `mysql` | `mysql:8.4` | DB nguồn và DB đích để restore |
| `mariadb` | `mariadb:11` | Kiểm tra dump của MariaDB restore được bằng client MySQL |
| `postgres` | `postgres:17` | DB PostgreSQL |
| `host` | Ubuntu 24.04 + `openssh-server`, `zip`, `unzip`, client MySQL và PostgreSQL | Chạy `host/`, có thư mục source mẫu |
| `collector` | Ubuntu 24.04 + `openssh-client`, `curl` | Chạy `collector/` |
| `healthchecks` | `healthchecks/healthchecks` hoặc một HTTP server ghi lại request | Nhận ping |

Nên chạy thêm host trên image `amazonlinux:2023`, vì đây là môi trường mục tiêu thứ hai.

Đặt file trong `tests/docker/`, chạy bằng một lệnh, ví dụ `bash tests/docker/run.sh`.

### 5.3. Dữ liệu mẫu

| Dữ liệu | Mục đích kiểm tra |
|---|---|
| Bảng có tiếng Việt, tiếng Nhật, emoji | Bảng mã `utf8mb4` |
| Bảng có cột `BLOB` chứa dữ liệu nhị phân | Dump và restore không làm hỏng byte |
| View, stored procedure, trigger có `DEFINER` là user không tồn tại ở DB đích | Xử lý `DEFINER` khi restore |
| Thư mục source có: file thường, thư mục rỗng, symlink tới file, symlink tới thư mục, symlink hỏng, file tên có dấu cách và tiếng Việt, file quyền `600` và `755` | Nén source nguyên trạng |
| Một file mà user chạy backup không đọc được | Backup vẫn tạo được, có cảnh báo |

### 5.4. Kịch bản

| # | Kịch bản | Tiêu chí đạt |
|---|---|---|
| 1 | `backup.sh db` với MySQL, MariaDB, PostgreSQL | Tạo zip, có `db.sql` và `manifest.txt` trong thư mục cùng tên |
| 2 | `backup.sh full` | Giải nén ra giống hệt thư mục source: `diff -r` không khác biệt, symlink vẫn là symlink, quyền file giữ nguyên |
| 3 | `backup.sh full` khi `SOURCE_DIR` nằm ngay dưới `/` (ví dụ `/app`) | Tạo zip đúng cấu trúc |
| 4 | `restore.sh` vào DB trống, cùng loại DB | Số dòng và nội dung các bảng giống DB nguồn, view và procedure chạy được |
| 5 | Restore dump của MariaDB bằng client MySQL | Thành công (dòng sandbox được bỏ) |
| 6 | `restore.sh` bằng user DB không có quyền tạo database | Thành công khi database đã tồn tại |
| 7 | `collect.sh example db` qua `sshd` thật, key có `command=` | File về đủ, đúng checksum, Healthchecks nhận `/start` và ping thành công |
| 8 | Dùng key đó chạy lệnh khác: `ssh host "cat /etc/passwd"`, mở shell, `scp`, chuyển tiếp cổng | Tất cả bị từ chối |
| 9 | `collect.sh` khi DB của host bị tắt | Thất bại, Healthchecks nhận `/fail` kèm log lỗi |
| 10 | Tạo backup trên host khi collector không chạy, sau đó chạy `collect.sh example sync` | Collector kéo đủ các file còn thiếu |
| 11 | `backup.sh db --if-missing` 2 lần liên tiếp | Lần đầu tạo backup, lần sau không làm gì |
| 12 | Chạy 2 `backup.sh` cùng lúc | Một bên báo lỗi đang có backup khác chạy |
| 13 | DB dung lượng lớn (khoảng 500 MB) | Hoàn tất, ghi lại thời gian chạy |

## 6. Các điểm rủi ro cần xác nhận

Đây là những chỗ có khả năng hỏng cao nhất khi chạy thật.

| # | Vị trí | Rủi ro | Hướng xử lý nếu hỏng |
|---|---|---|---|
| 1 | `create_zip` trong `host/backup.sh` | Source được nén qua một symlink trỏ tới thư mục cha của source, để không phải copy. Cách này chưa chạy với `zip` thật | Copy source vào thư mục tạm bằng `cp -al` (hardlink, không tốn dung lượng), không được thì `cp -a` |
| 2 | `create_zip` | Gọi `zip` 2 lần vào cùng một file có đuôi `.part`. Cần xác nhận `zip` thêm vào file cũ và không tự nối đuôi `.zip` | Đặt tên tạm có đuôi `.zip`, ví dụ `.<tên>.tmp.zip` |
| 3 | `dump_db` | `--routines`, `--events` cần quyền mà user DB giới hạn có thể không có (MySQL 8) | Ghi rõ quyền cần cấp trong `setup.md`, hoặc bỏ bớt tham số qua `DB_DUMP_OPTIONS` |
| 4 | `host/ssh-gate.sh` | `sshd` chạy lệnh ép buộc qua shell đăng nhập của user. Nếu user dùng shell `nologin` thì không chạy được | Ghi yêu cầu về shell trong `setup.md` |
| 5 | Quyền đọc source | User chạy backup không đọc được hết file của web server | `zip` trả mã 18, script ghi `WARNING` và vẫn tạo file. Cân nhắc có nên coi là thất bại |
| 6 | `pgsql_filter` trong `host/restore.sh` | Lọc `OWNER TO`, `GRANT`, `REVOKE` bằng biểu thức chính quy theo từng dòng, chưa chạy với dump thật | Dùng `pg_dump --no-owner --no-privileges` khi dump |
| 7 | `hc_ping` trong `collector/collect.sh` | Tham số `create=1` và `rid` chưa thử với Healthchecks thật | Xem tài liệu API của Healthchecks |
| 8 | Image `amazonlinux:2023` | Có thể thiếu `flock`, `numfmt`, hoặc tên gói client DB khác Ubuntu | Bổ sung danh sách gói vào `setup.md` |

## 7. Quy ước

| Hạng mục | Quy ước |
|---|---|
| Ngôn ngữ | README, `setup.md`, chú thích trong code, commit message: tiếng Anh. `spec.md`, `handover.md`: tiếng Việt |
| Tên ví dụ | Dùng `example`, `demo`. Không dùng tên dự án thật |
| Thông tin nhạy cảm | Repo là public. Không commit IP thật, mật khẩu, đường dẫn nội bộ. IP ví dụ dùng dải `203.0.113.0/24` |
| Config thật | `backup.conf`, `my.cnf`, `collector.conf`, `projects.d/*.conf` đã nằm trong `.gitignore` |
| Output của `backup.sh` | stdout chỉ có đúng 1 dòng là tên file. Mọi thông báo ghi ra stderr và file log. Collector dựa vào điều này |
| Khi sửa code | Chạy lại `bash tests/run-tests.sh`, bổ sung test cho lỗi vừa sửa |

## 8. Việc để sau

* Bản Windows của host (PowerShell), cho các hệ thống chạy trên Windows Server.
* Dịch `spec.md` sang tiếng Anh.
* Xóa tài liệu bàn giao này khi các bước ở mục 4 đã xong.
