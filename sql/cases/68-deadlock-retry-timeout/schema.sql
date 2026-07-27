-- ============================================================
-- 案例三十一: 死锁重试与超时处理
-- 场景: innodb_lock_wait_timeout 设置，锁等待超时后应用层重试
-- ============================================================

DROP TABLE IF EXISTS t_concurrent_counter;
CREATE TABLE t_concurrent_counter (
    id             BIGINT   NOT NULL AUTO_INCREMENT,
    counter_value  INT      NOT NULL DEFAULT 0    COMMENT '计数值',
    thread_id      VARCHAR(32) DEFAULT NULL       COMMENT '最后更新线程标识',
    updated_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='并发计数器表（锁等待演示）';
