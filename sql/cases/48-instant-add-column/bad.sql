-- bad.sql: MySQL 5.7 传统方式加列（重建整张表）
-- 5.7 中 ADD COLUMN 默认走 INPLACE 但需要重建表数据（rebuild）
-- 过程: 创建新表结构 -> 逐行拷贝数据 -> 重命名替换 -> 释放旧表
-- 50 万行需完整拷贝，期间持有 MDL 排他锁，阻塞所有 DML
-- 生产 500 万行表锁表可达 10 分钟以上
ALTER TABLE t_order ADD COLUMN source VARCHAR(20) NOT NULL DEFAULT 'web' COMMENT '订单来源';
