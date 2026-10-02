-- ============================================================
-- 案例: TiDB 锁机制深度解析
-- 场景: 秒杀并发扣减——FOR UPDATE / NOWAIT / SKIP LOCKED 行为对比
-- ============================================================

DROP TABLE IF EXISTS t_lock_test;
CREATE TABLE t_lock_test (
    id        INT         NOT NULL,
    item_name VARCHAR(50) NOT NULL,
    qty       INT         NOT NULL DEFAULT 100,
    PRIMARY KEY (id)
);
