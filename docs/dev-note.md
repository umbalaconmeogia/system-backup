# Ghi chú phát triển: bài học về kiểm thử

Tài liệu này ghi lại các vấn đề phát sinh khi phát triển webapp-backup (tháng 9/2026),
để rút kinh nghiệm cho các lần phát triển sau.

## 1. Tóm tắt

Code được viết trên Windows. Bộ test dùng chương trình giả (stub) chạy gần như hoàn hảo,
và ở thời điểm đó mọi thứ **trông như đã xong**. Khi đưa vào môi trường thật hơn (Docker, với MySQL, MariaDB,
PostgreSQL, sshd và Healthchecks thật), lượt chạy đầu tiên hỏng 25 trên 89 mục, do 6 lỗi thật.
Trong đó có những lỗi làm **mất dữ liệu mà không báo lỗi gì**, là loại lỗi tệ nhất mà một công cụ backup có thể có.

| Giai đoạn | Kết quả | Cảm nhận lúc đó |
|---|---|---|
| Test stub trên Git Bash (Windows) | 77/78 đạt | "Chỉ còn 1 mục, do Windows không có symlink" |
| Test stub trên Ubuntu 24.04 thật | 78/78 đạt | "Xong rồi" |
| Test Docker, lần 1 | Không build được | User `backup` đã có sẵn trên Ubuntu |
| Test Docker, lần 2 | 64 đạt, **25 hỏng** | 6 lỗi thật của sản phẩm, 4 lỗi của chính bộ test |
| Test Docker, lần cuối | 95/95 đạt | Sau khi sửa code, tài liệu và bộ test |

## 2. Các lỗi của sản phẩm mà test stub không bắt được

| # | Lỗi | Vì sao test stub không thấy | Nếu đưa lên production |
|---|---|---|---|
| 1 | `collect.sh` chỉ kéo được 1 file mỗi lượt: `ssh` đọc mất stdin, là danh sách file đang được duyệt trong vòng lặp | `ssh` giả không đọc stdin | Lệnh `sync` **báo thành công** nhưng chỉ kéo 1 file, các bản backup chạy tay và bản dự phòng bị bỏ lại trên host |
| 2 | Dump **thiếu stored procedure mà không báo lỗi**: user backup thiếu quyền `SHOW_ROUTINE` (MySQL) hoặc `SHOW CREATE ROUTINE` (MariaDB) | `mysqldump` giả luôn in ra đủ nội dung | Backup mỗi ngày đều "thành công". Chỉ phát hiện thiếu procedure vào đúng lúc cần restore khi có sự cố |
| 3 | Hướng dẫn dùng user `backup`, nhưng Ubuntu đã có sẵn user này với shell `nologin`, nên lệnh ép buộc của SSH không chạy được | Không có hệ điều hành thật, không có user thật | Làm đúng theo hướng dẫn cài đặt mà không chạy được |
| 4 | Restore trigger vào MySQL 8 bằng user thường hỏng với `ERROR 1419`, vì MySQL 8 bật binary log mặc định | Không có MySQL thật | Restore về máy local thất bại, người dùng không hiểu vì sao |
| 5 | Dump của MariaDB 11.4 không restore được vào MySQL: collation mặc định `utf8mb4_uca1400_ai_ci` không tồn tại trên MySQL | Không có MariaDB thật | Luồng "lấy DB production về máy local để điều tra bug" không dùng được |
| 6 | Sau khi sửa lỗi 5, lỗi tiếp theo lộ ra: trigger và procedure của MariaDB mang `sql_mode` có `NO_AUTO_CREATE_USER`, MySQL 8 không chấp nhận | Như trên | Như trên |

Lỗi đã biết từ các dự án cũ (dòng đầu `enable the sandbox mode` của `mariadb-dump`) đã được xử lý từ đầu,
và test Docker xác nhận cách xử lý đó hoạt động. Nhưng như lỗi 5 và 6 cho thấy, **đó chỉ là lỗi đầu tiên trong một chuỗi**.

## 3. Các lỗi của chính bộ test

Không chỉ code có lỗi, bộ test cũng có lỗi. Test sai nguy hiểm vì nó tạo cảm giác an toàn giả.

| # | Lỗi | Hậu quả |
|---|---|---|
| 1 | Hàm `check` ghi đè file output **trước khi** lệnh `grep` bên trong kịp đọc nó | Các mục kiểu "không có cảnh báo" **luôn đạt**, bất kể kết quả thật |
| 2 | Giả định sai về quyền của MySQL: tưởng user chỉ có quyền trên một database thì không chạy được `CREATE DATABASE` cho chính database đó | Test hỏng dù code đúng. Mục test bị bỏ |
| 3 | Tìm tên trigger có dấu `` ` ``, nhưng `mariadb-dump` không đặt tên trigger trong dấu `` ` `` | Test báo thiếu trigger dù dump có đủ |
| 4 | Sửa `run.sh` trong lúc nó đang chạy. Bash đọc script theo từng đoạn nên chạy lệch dòng | Lượt test dừng giữa chừng với lỗi khó hiểu |

Ngoài ra, dữ liệu test ban đầu cố định collation `utf8mb4_unicode_ci` cho database.
Lỗi 5 vẫn lộ ra chỉ vì trigger và procedure ghi lại collation của phiên kết nối.
Nếu database mẫu không có trigger, lỗi này đã bị che mất.

## 4. Bài học

### 4.1. "Test đạt" chỉ có nghĩa là code đúng với những gì người viết test giả định

Stub là giả định của người viết về thế giới thật: `ssh` giả không đọc stdin, `mysqldump` giả luôn có quyền đọc mọi thứ.
Cả 6 lỗi đều nằm đúng ở những chỗ giả định đó khác với thực tế.
Khi viết stub, cần tự hỏi: chương trình thật khác stub ở điểm nào, và điểm đó có ảnh hưởng đến code không?

### 4.2. Mỗi tầng kiểm thử bắt một loại lỗi khác nhau, không tầng nào thay được tầng nào

| Tầng | Bắt được | Không bắt được |
|---|---|---|
| Test stub | Logic, các nhánh lỗi hiếm (sai checksum, mất kết nối, dung lượng giảm bất thường) | Hành vi thật của phần mềm bên ngoài |
| Test Docker | Hành vi thật của `ssh`, `mysqldump`, `mariadb-dump`, quyền, collation, user hệ thống | Mạng thật, dữ liệu lớn, cấu hình riêng của từng server |
| Chạy thử trên server thật | Cấu hình thật, dung lượng thật, thời gian chạy thật | |

Bộ test stub vẫn có giá trị: nó chạy trong vài giây và dễ tạo tình huống lỗi. Nhưng nó không đủ.

### 4.3. Lỗi nguy hiểm nhất là lỗi im lặng

Lỗi 1 và 2 không làm gì hỏng cả, script vẫn báo thành công. Với công cụ backup, **một bản backup chưa từng được restore thử
thì coi như chưa có backup**. Vì vậy bộ test Docker không dừng ở việc kiểm tra file zip tồn tại, mà restore vào database thật
rồi so sánh từng dòng dữ liệu, gọi thử procedure, view, trigger.

### 4.4. Phải kiểm tra chính bộ test

Một test không bao giờ hỏng thì không chứng minh được gì. Sau khi sửa lỗi 1, `ssh` giả được sửa để đọc stdin giống `ssh` thật,
rồi tạm gỡ bản sửa khỏi `collect.sh` để xác nhận bộ test stub báo lỗi (9 mục hỏng). Chỉ khi thấy test đỏ
mới tin được rằng test xanh có ý nghĩa.

### 4.5. Khi test hỏng, xác định lỗi nằm ở đâu trước khi sửa

Trong 25 mục hỏng có lỗi của code, lỗi của tài liệu (quyền, tên user), giới hạn của MySQL (lỗi 1419),
và lỗi của chính bộ test. Mỗi loại cần cách sửa khác nhau. Sửa code cho qua một test sai là làm hỏng sản phẩm.

### 4.6. Sửa một lỗi có thể mở ra lỗi tiếp theo

Bỏ dòng sandbox thì lộ lỗi collation, sửa collation thì lộ lỗi `sql_mode`. Sau mỗi lần sửa phải chạy lại toàn bộ,
không chỉ mục vừa hỏng.

### 4.7. Dữ liệu test phải giống dữ liệu thật

Dữ liệu mẫu cần có những thứ mà dự án thật có: collation mặc định của server, trigger, procedure, event, view,
definer không tồn tại ở môi trường đích, user với quyền tối thiểu, dữ liệu nhị phân, tên file tiếng Việt,
symlink hỏng, file không có quyền đọc. Dữ liệu mẫu "sạch" che mất lỗi.

### 4.8. Tài liệu cũng cần được kiểm thử

Lỗi 2 và 3 nằm trong `setup.md`, không nằm trong code. Bộ test Docker dựng môi trường **đúng theo tài liệu**
(đúng quyền đã ghi, đúng cách tạo user), nhờ vậy mới phát hiện tài liệu sai.

### 4.9. Không quen với việc bỏ qua test hỏng

Trên Windows, 1 mục test hỏng được giải thích là "do môi trường". Lần này giải thích đó đúng.
Nhưng nếu thành thói quen, sẽ có ngày một lỗi thật bị bỏ qua với cùng lý do. Cách đúng là chạy lại trên môi trường
nơi mục đó phải đạt, như đã làm với Ubuntu.

## 5. Checklist cho lần sau

* [ ] Mỗi stub: liệt kê các điểm khác với chương trình thật.
* [ ] Có test với phần mềm thật (Docker) trước khi coi là xong, không chỉ test stub.
* [ ] Với backup: test phải restore và so sánh dữ liệu, không chỉ kiểm tra file tồn tại.
* [ ] Môi trường test dựng đúng theo tài liệu cài đặt.
* [ ] Dữ liệu test có đủ các trường hợp khó của dự án thật.
* [ ] Với mỗi lỗi đã sửa: có test bắt được lỗi đó, và đã thấy test đó hỏng khi gỡ bản sửa.
* [ ] Sau mỗi lần sửa: chạy lại toàn bộ test.
* [ ] Không sửa script test trong lúc nó đang chạy.
