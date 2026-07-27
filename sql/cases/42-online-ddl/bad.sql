-- 传统方式加索引：ALGORITHM=COPY 会创建临时表、逐行拷贝、全程锁表
-- 5.7 默认加索引可能走 COPY 或 INPLACE，显式指定 COPY 模拟最差情况
-- COPY 模式下：表级独占锁，DDL 期间不允许任何 DML（读写均阻塞）
ALTER TABLE t_big_table ADD KEY idx_user_id (user_id), ALGORITHM=COPY;
