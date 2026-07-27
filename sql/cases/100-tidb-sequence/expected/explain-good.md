# 预期结果 - good.sql（Sequence 创建和使用）

## TiDB v7.5.1

---

### NEXTVAL 获取 Sequence 值

```
SELECT NEXTVAL(seq_order_id) AS next_order_id;
+----------------+
| next_order_id  |
+----------------+
|        1000000 |
+----------------+

SELECT NEXTVAL(seq_order_id) AS order_id_1;
SELECT NEXTVAL(seq_order_id) AS order_id_2;
SELECT NEXTVAL(seq_order_id) AS order_id_3;

+------------+
| order_id_1 |
+------------+
|    1000001 |
+------------+

+------------+
| order_id_2 |
+------------+
|    1000002 |
+------------+

+------------+
| order_id_3 |
+------------+
|    1000003 |
+------------+
```

说明：CACHE=500 表示一次 TSO 请求预分配 500 个值。前 500 次 NEXTVAL 在本地缓存命中，不额外消耗 TSO。第 501 次重新向 PD 申请下一批 500 个值。

---

### SHOW CREATE SEQUENCE

```
SHOW CREATE SEQUENCE seq_order_id\G
******************** 1. row ********************
       Sequence: seq_order_id
Create Sequence: CREATE SEQUENCE `seq_order_id` start with 1000000 minvalue 1 maxvalue 9223372036854775807
                 increment by 1 cache 500 nocycle ENGINE=InnoDB
```

关键参数解读：

| 参数 | 值 | 含义 |
|------|-----|------|
| `START WITH` | 1000000 | 起始值 |
| `INCREMENT BY` | 1 | 步长（正数为递增，负数为递减） |
| `CACHE` | 500 | 每次预分配 500 个值到本地缓存 |
| `NOCYCLE` | - | 达到最大值后不循环（默认行为） |
| `MINVALUE` | 1 | 最小值 |
| `MAXVALUE` | 9223372036854775807 | BIGINT 最大值 |

---

### Sequence 在 INSERT 中的应用

```
INSERT INTO t_seq (name, val) VALUES (CONCAT('order_', NEXTVAL(seq_order_id)), 100);
SELECT * FROM t_seq ORDER BY id DESC LIMIT 5;

+----+-----------------+-----+
| id | name            | val |
+----+-----------------+-----+
|  6 | order_1000004   | 100 |  ← Sequence 提供的全局递增 ID
|  5 | seq_e           | 500 |
|  4 | seq_d           | 400 |
|  3 | seq_c           | 300 |
|  2 | seq_b           | 200 |
+----+-----------------+-----+
```

---

### NO CACHE vs CACHE 性能差异

```
SHOW CREATE SEQUENCE seq_no_cache\G
******************** 1. row ********************
       Sequence: seq_no_cache
Create Sequence: CREATE SEQUENCE `seq_no_cache` start with 1 minvalue 1 maxvalue 9223372036854775807
                 increment by 1 nocache nocycle ENGINE=InnoDB
```

| 模式 | TSO 消耗 | 性能 | 使用场景 |
|------|----------|------|----------|
| `NO CACHE` | 每次 NEXTVAL 消耗 1 次 TSO | 最低 | 低频调用或对连续性要求极高 |
| `CACHE 100` | 每 100 次消耗 1 次 TSO | 提升 ~100x | 一般业务场景 |
| `CACHE 1000` | 每 1000 次消耗 1 次 TSO | 提升 ~1000x | 高并发高频调用 |

**CACHE 代价**：TiDB 实例重启后，缓存中尚未使用的值会丢失（产生空洞）。CACHE 越大，重启丢失的可能范围越大。

---

### 三种分布式 ID 方案对比分析

| 维度 | AUTO_INCREMENT | AUTO_RANDOM | Sequence |
|------|----------------|-------------|----------|
| **ID 分配方式** | TiDB Server 本地步长分配 | shard bits(高位随机) + 自增低位 | PD TSO 全局分配 |
| **全局单调递增** | 不保证（跨 TiDB 实例乱序） | 不保证 | 严格保证 |
| **ID 连续性** | 不连续（回滚/多实例导致空洞） | 不连续（随机高位） | CACHE 下不连续，NO CACHE 下接近连续 |
| **写入热点** | 严重（递增主键） | 无（shard bits 打散） | 严重（递增主键） |
| **TSO 依赖** | 不需要 | 不需要 | 每次 NEXTVAL 需要（CACHE 可减少） |
| **分布式扩展性** | 差（单热点瓶颈） | 好（写入打散到多 Region） | 差（同 AUTO_INCREMENT） |
| **排序友好性** | 友好（近似递增） | 不友好（乱序） | 友好（严格递增） |
| **兼容性** | MySQL 标准 | TiDB 特有 | Oracle/PostgreSQL 风格 |

---

### 三方案选型决策树

```
需要严格全局递增的序列号？
├── 是 → 需要排序友好？
│       ├── 是 → Sequence（订单号、流水号、发票号）
│       └── 否 → 极高频写入？
│               ├── 是 → AUTO_RANDOM（日志表、埋点表）
│               └── 否 → Sequence（批量获取，CACHE 减少 TSO）
│
└── 否 → 高并发写入是否导致热点？
        ├── 是 → AUTO_RANDOM（高吞吐写入场景）
        │      └── 需要有序？→ AUTO_INCREMENT + SHARD_ROW_ID_BITS
        └── 否 → AUTO_INCREMENT（低 QPS / 简单场景）
               └── 需要跨实例连续？→ Sequence
```
