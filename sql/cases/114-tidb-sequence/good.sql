-- good.sql: Sequence 创建和使用（全局递增，CACHE 预分配减少 TSO 开销）

-- 1. 创建 Sequence（订单号场景：从 1000000 起步）
CREATE SEQUENCE seq_order_id
    START WITH 1000000
    INCREMENT BY 1
    CACHE 500;

-- 2. 获取单个 NEXTVAL（每次调用消耗一次 TSO）
SELECT NEXTVAL(seq_order_id) AS next_order_id;

-- 3. 多次获取观察递增特征
SELECT NEXTVAL(seq_order_id) AS order_id_1;
SELECT NEXTVAL(seq_order_id) AS order_id_2;
SELECT NEXTVAL(seq_order_id) AS order_id_3;

-- 4. 查看 Sequence 定义信息
SHOW CREATE SEQUENCE seq_order_id;

-- 5. 在 INSERT 中使用 NEXTVAL
INSERT INTO t_seq (name, val) VALUES (CONCAT('order_', NEXTVAL(seq_order_id)), 100);
SELECT * FROM t_seq ORDER BY id DESC LIMIT 5;

-- 6. NO CACHE vs CACHE 差异说明
-- NO CACHE: 每次 NEXTVAL 都申请一次 TSO（全局时间戳），性能最低
-- CACHE N: 一次 TSO 预分配 N 个值到本地缓存，后续 N-1 次调用不消耗 TSO

-- 创建 NO CACHE 版本做对比
CREATE SEQUENCE seq_no_cache START WITH 1 INCREMENT BY 1 NO CACHE;

-- 查看缓存设置
SELECT 'seq_order_id CACHE=500' AS seq_name;
SHOW CREATE SEQUENCE seq_order_id;

SELECT 'seq_no_cache NO CACHE' AS seq_name;
SHOW CREATE SEQUENCE seq_no_cache;

-- 7. 三种分布式 ID 方案对比
SELECT 'AUTO_INCREMENT' AS scheme,
       'TiDB Server 本地分配' AS allocation,
       '不保证全局单调递增' AS monotonicity,
       '连续递增导致写热点' AS hotspot,
       '不需要 TSO' AS tso_cost,
       'MySQL 兼容，简单场景首选' AS best_for

UNION ALL

SELECT 'AUTO_RANDOM',
       'Shard bits 随机 + 自增低位',
       '不保证顺序',
       '写入打散到多 Region',
       '不需要 TSO',
       '高并发写入，不要求 ID 有序'

UNION ALL

SELECT 'Sequence',
       '全局 TSO 分配',
       '全局严格单调递增',
       '按主键递增（同 AUTO_INCREMENT）',
       '每次 NEXTVAL（或 CACHE 批量）消耗 TSO',
       '需要全局递增序列（订单号/流水号）';
