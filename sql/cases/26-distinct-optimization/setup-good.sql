-- setup-good.sql: 建立联合索引 (user_id, visit_time) 支持去重与范围过滤
ALTER TABLE t_visit_log ADD KEY idx_user_visit (user_id, visit_time);
