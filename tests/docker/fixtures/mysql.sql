-- Test data for MySQL and MariaDB. Run by root.

-- Default collation of the server is used, as in most projects
-- (MySQL 8: utf8mb4_0900_ai_ci, MariaDB 11.4: utf8mb4_uca1400_ai_ci).
CREATE DATABASE demo CHARACTER SET utf8mb4;
CREATE DATABASE demo_restore CHARACTER SET utf8mb4;
CREATE DATABASE demo_other CHARACTER SET utf8mb4;

-- Owner (definer) of views, routines, triggers, events.
-- It exists on the production server, but not on the environment of the restore.
CREATE USER 'app_admin'@'%' IDENTIFIED BY 'app_pw';
GRANT ALL ON demo.* TO 'app_admin'@'%';

-- User for backup, with the privileges written in docs/setup.md.
-- The privilege to read routines differs between MySQL and MariaDB, it is granted by run.sh.
CREATE USER 'backup_user'@'%' IDENTIFIED BY 'backup_pw';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON demo.* TO 'backup_user'@'%';

-- User for restore. It cannot create database, and cannot use other users as definer.
CREATE USER 'restore_user'@'%' IDENTIFIED BY 'restore_pw';
GRANT ALL ON demo_restore.* TO 'restore_user'@'%';
GRANT ALL ON demo_other.* TO 'restore_user'@'%';

USE demo;

CREATE TABLE item (
    id INT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    data BLOB
) ENGINE=InnoDB;

CREATE TABLE audit (
    id INT AUTO_INCREMENT PRIMARY KEY,
    item_id INT NOT NULL,
    note VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE DEFINER=`app_admin`@`%` SQL SECURITY DEFINER VIEW item_names AS SELECT id, name FROM item;

DELIMITER ;;
CREATE DEFINER=`app_admin`@`%` PROCEDURE count_items(OUT n INT)
BEGIN
    SELECT COUNT(*) INTO n FROM item;
END;;
CREATE DEFINER=`app_admin`@`%` TRIGGER item_after_insert AFTER INSERT ON item FOR EACH ROW
    INSERT INTO audit (item_id, note) VALUES (NEW.id, 'inserted');;
DELIMITER ;

CREATE DEFINER=`app_admin`@`%` EVENT purge_audit ON SCHEDULE EVERY 1 DAY DISABLE
    DO DELETE FROM audit WHERE id < 0;

INSERT INTO item (id, name) VALUES
    (1, 'Tiếng Việt: Đà Nẵng, Huế'),
    (2, '日本語のテキスト'),
    (3, 'Emoji 🎉🗄️'),
    (4, 'Quote '' backslash \\ newline\nend');
-- Row 5 (all 256 byte values in BLOB) is inserted by run.sh.
