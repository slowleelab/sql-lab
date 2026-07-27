-- ============================================================
-- 案例四十七: 缓存穿透与布隆过滤器
-- 场景: 恶意请求查询不存在的用户ID，缓存和数据库都miss
--        用 SQL 表模拟布隆过滤器的位数组检查
-- ============================================================

-- 用户表: 100 万用户
DROP TABLE IF EXISTS t_user;
CREATE TABLE t_user (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    nickname     VARCHAR(64)  NOT NULL              COMMENT '用户昵称',
    phone        VARCHAR(20)  NOT NULL DEFAULT ''   COMMENT '手机号',
    email        VARCHAR(100) NOT NULL DEFAULT ''   COMMENT '邮箱',
    status       TINYINT      NOT NULL DEFAULT 1    COMMENT '1正常/0禁用',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '注册时间',
    PRIMARY KEY (id),
    KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';

-- 模拟布隆过滤器: 记录所有存在的用户 ID 的哈希位
-- 实际布隆过滤器在内存中用位数组实现，这里用表模拟其"存在性检查"功能
DROP TABLE IF EXISTS t_bloom_filter;
CREATE TABLE t_bloom_filter (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    user_id_hash BIGINT       NOT NULL              COMMENT '用户ID的哈希值（模拟布隆位）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_hash (user_id_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='模拟布隆过滤器（实际在内存中）';
