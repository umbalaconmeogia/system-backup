-- Test data for PostgreSQL. Run by postgres.

-- Owner of the objects. It exists on the production server, but not on the environment of the restore.
CREATE ROLE app_owner LOGIN PASSWORD 'app_pw';
CREATE ROLE app_reader;

-- User for backup, with the privileges written in docs/setup.md.
CREATE ROLE backup_user LOGIN PASSWORD 'backup_pw';
GRANT pg_read_all_data TO backup_user;

-- User for restore. It is not a member of app_owner.
CREATE ROLE restore_user LOGIN PASSWORD 'restore_pw';

CREATE DATABASE demo OWNER app_owner;
CREATE DATABASE demo_restore OWNER restore_user;

\connect demo
SET ROLE app_owner;

CREATE TABLE item (
    id int PRIMARY KEY,
    name text NOT NULL,
    data bytea
);

INSERT INTO item (id, name) VALUES
    (1, 'Tiếng Việt: Đà Nẵng, Huế'),
    (2, '日本語のテキスト'),
    (3, 'Emoji 🎉🗄️'),
    (4, E'Quote '' backslash \\ newline\nend');
INSERT INTO item (id, name, data) VALUES (5, 'binary',
    (SELECT string_agg(set_byte('\x00'::bytea, 0, n), ''::bytea ORDER BY n) FROM generate_series(0, 255) AS n));

CREATE VIEW item_names AS SELECT id, name FROM item;

CREATE FUNCTION count_items() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM item $$;

GRANT SELECT ON item TO app_reader;
