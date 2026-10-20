-- 只在首次搭建环境时手动执行一次。Flyway 不会执行本文件（它只扫 db/migration）。
-- 建库语句不放进迁移脚本，是为了避免 CI/他人机器上重复执行时误建库。

CREATE DATABASE IF NOT EXISTS otaku
    DEFAULT CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

-- 可选：为应用创建独立账号，避免直接用 root
-- CREATE USER IF NOT EXISTS 'otaku'@'localhost' IDENTIFIED BY '<设置一个密码>';
-- GRANT ALL PRIVILEGES ON otaku.* TO 'otaku'@'localhost';
-- FLUSH PRIVILEGES;
