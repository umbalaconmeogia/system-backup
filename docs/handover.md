# Bàn giao

Tài liệu này dành cho người (hoặc AI) tiếp tục phát triển.
Cập nhật lần cuối: 2026-09-28.

## 1. Trạng thái hiện tại

| Hạng mục | Trạng thái |
|---|---|
| `host/backup.sh`, `host/ssh-gate.sh`, `host/restore.sh` | Đã kiểm thử với MySQL 8.4, MariaDB 11.4, PostgreSQL 16 và sshd thật (Docker) |
| `collector/collect.sh` | Đã kiểm thử qua sshd thật, báo cáo tới Healthchecks thật |
| `host/restore.bat`, `host/restore.ps1` | Đã kiểm thử trên Windows với client `mysql` 9.3 và MySQL 8.4 thật: restore dump của MariaDB 11.4 |
| `tests/run-tests.sh` (test stub) | 78/78 đạt trên Ubuntu 24.04 |
| `tests/docker/run.sh` (test Docker) | 95/95 đạt |
| GitHub Actions | Chưa làm |
| Chạy thử trên server thật | Chưa làm |
| Host trên Amazon Linux 2023 | Chưa kiểm thử |
| Bản Windows của host | Chưa làm, để sau |

Các vấn đề phát sinh trong quá trình kiểm thử và bài học rút ra: xem [dev-note.md](dev-note.md).

## 2. Đọc trước

| Tài liệu | Nội dung |
|---|---|
| [spec.md](spec.md) | Thiết kế: luồng xử lý, quy ước tên file, config, các lệnh |
| [setup.md](setup.md) | Hướng dẫn cài đặt host, backup server, Healthchecks |
| [dev-note.md](dev-note.md) | Các lỗi đã gặp và bài học về kiểm thử |
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
| File backup giữ nguyên bản, mọi điều chỉnh làm lúc restore | Luôn dựng lại được đúng server gốc (`--as-is`) |
| Không xử lý riêng Docker, không mã hóa file backup | Ngoài phạm vi |
| Ưu tiên dùng công cụ có sẵn | Chỉ tự viết phần mà công cụ có sẵn không đáp ứng |

## 4. Kiểm thử

| Bộ test | Lệnh | Cần gì | Thời gian |
|---|---|---|---|
| Test stub | `bash tests/run-tests.sh` | bash, `zip`, `unzip`, `flock` | Vài chục giây |
| Test Docker | `bash tests/docker/run.sh` | Docker | Khoảng 2 phút (lần đầu thêm vài phút để build image) |

Test Docker dựng các container: MySQL 8.4, MariaDB 11.4, PostgreSQL 16, Healthchecks, 2 host Ubuntu 24.04
(một host dùng client MySQL, một host dùng client MariaDB), và collector. Các kịch bản:

| # | Kịch bản |
|---|---|
| 1 | `backup.sh db` với MySQL, MariaDB, PostgreSQL. Dump có đủ bảng, view, procedure, trigger, event |
| 2 | `backup.sh full`: giải nén ra giống hệt thư mục source (loại file, quyền, symlink, symlink hỏng, thư mục rỗng) |
| 3 | `SOURCE_DIR` nằm ngay dưới `/` |
| 4 | Restore bằng user chỉ có quyền trên database đích, definer không tồn tại. So sánh dữ liệu, gọi procedure, view, trigger |
| 5 | Dump của MariaDB 11.4 restore vào MySQL 8.4 |
| 6 | `collect.sh` qua sshd thật, kiểm tra checksum, Healthchecks nhận `/start` và ping thành công cùng `rid` |
| 7 | SSH key của backup server không chạy được lệnh khác, shell, `scp`, `sftp`, chuyển tiếp cổng |
| 8 | Database của host bị tắt: Healthchecks nhận `/fail` kèm log |
| 9 | Backup tạo trên host được kéo về sau bằng `sync` |
| 10 | `--if-missing` chạy 2 lần |
| 11 | 2 backup chạy cùng lúc |
| 12 | Có file không đọc được trong source: backup vẫn tạo, có cảnh báo |
| 13 | Database lớn: chỉ chạy khi đặt `LARGE_MB`, ví dụ `LARGE_MB=500 bash tests/docker/run.sh`. **Chưa chạy lần nào** |

Tùy chọn `KEEP=1` giữ lại các container sau khi chạy để điều tra.

## 5. Các rủi ro trong lần bàn giao trước

| # | Rủi ro | Kết quả |
|---|---|---|
| 1 | Nén source qua symlink tới thư mục cha, chưa chạy với `zip` thật | Hoạt động đúng |
| 2 | Gọi `zip` 2 lần vào cùng một file `.part` | Hoạt động đúng |
| 3 | User DB thiếu quyền để dump routine | **Xảy ra**: procedure bị thiếu mà không báo lỗi. Đã ghi quyền cần cấp vào `setup.md` |
| 4 | User dùng shell `nologin` | **Xảy ra**: Ubuntu có sẵn user `backup` với shell `nologin`. Tài liệu đổi sang user `webapp-backup` |
| 5 | File source không đọc được | Hoạt động như thiết kế: cảnh báo, vẫn tạo file |
| 6 | Lọc `OWNER TO`, `GRANT`, `REVOKE` của PostgreSQL | Hoạt động đúng |
| 7 | `create=1` và `rid` của Healthchecks | Hoạt động đúng |
| 8 | Amazon Linux 2023 | Chưa kiểm thử |

Kiểm thử còn phát hiện thêm các lỗi chưa được dự đoán, xem [dev-note.md](dev-note.md).

## 6. Việc cần làm tiếp

1. **GitHub Actions**: tạo `.github/workflows/test.yml` chạy cả 2 bộ test mỗi lần push và pull request.
2. **Chạy thử trên một server thật**: làm theo [setup.md](setup.md) với một dự án thật, kèm Healthchecks thật.
   Kiểm tra cả 2 trường hợp: mail và Slack báo khi backup thất bại, và báo khi quá hạn không có backup.
3. **Amazon Linux 2023**: thêm một host dùng image `amazonlinux:2023` vào test Docker, bổ sung tên gói vào `setup.md`.
4. **Database lớn**: chạy kịch bản 13, ghi lại thời gian và dung lượng.

## 7. Quy ước

| Hạng mục | Quy ước |
|---|---|
| Ngôn ngữ | README, `setup.md`, chú thích trong code, commit message: tiếng Anh. `spec.md`, `handover.md`, `dev-note.md`: tiếng Việt |
| Tên ví dụ | Dùng `example`, `demo`. Không dùng tên dự án thật |
| Thông tin nhạy cảm | Repo là public. Không commit IP thật, mật khẩu, đường dẫn nội bộ. IP ví dụ dùng dải `203.0.113.0/24` |
| Config thật | `backup.conf`, `my.cnf`, `collector.conf`, `projects.d/*.conf` đã nằm trong `.gitignore` |
| Output của `backup.sh` | stdout chỉ có đúng 1 dòng là tên file. Mọi thông báo ghi ra stderr và file log. Collector dựa vào điều này |
| Khi sửa code | Chạy lại cả 2 bộ test. Với mỗi lỗi đã sửa, thêm test bắt được lỗi đó và xác nhận test hỏng khi gỡ bản sửa |

## 8. Việc để sau

* Bản Windows của host (PowerShell), cho các hệ thống chạy trên Windows Server.
* Dịch `spec.md` sang tiếng Anh.
