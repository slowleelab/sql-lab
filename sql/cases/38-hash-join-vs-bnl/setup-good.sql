-- setup-good.sql: 给 t_b.a_id 加索引，使 JOIN 走 Index Nested Loop
ALTER TABLE t_b ADD KEY idx_a_id (a_id);
