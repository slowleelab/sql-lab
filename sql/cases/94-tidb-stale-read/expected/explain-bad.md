# EXPLAIN 参考结果 - bad.sql（强一致读行为分析）

## TiDB v7.5.1（10 万 t_stale 行）

---

### 场景1: 普通 SELECT 聚合查询

```sql
SELECT COUNT(*) AS total_items, SUM(qty) AS total_qty, SUM(qty * price) AS total_value
FROM t_stale;
```

```
+------------------+----------+-----------+---------------+---------------------------------------+
| id               | estRows  | task      | access object | operator info                         |
+------------------+----------+-----------+---------------+---------------------------------------+
| HashAgg_9        | 1.00     | root      |               | funcs:count(1)->Column#7, ...         |
| └─TableFullScan_8| 100000.00| cop[tikv] | table:t_stale | keep order:false, stats:pseudo        |
+------------------+----------+-----------+---------------+---------------------------------------+
```

#### 分析

| 字段 | 值 | 分析 |
|------|-----|------|
| 最外层算子 | `HashAgg_9` | 在 TiDB 层聚合 `COUNT/SUM` |
| 数据来源 | `TableFullScan_8` | 全表扫 10 万行 |
| task | `cop[tikv]` | 扫描下推到 TiKV Coprocessor 执行 |
| operator info | `stats:pseudo` | 使用伪统计信息（表未 ANALYZE） |

#### 强一致读的机制

普通 `SELECT` 在 TiDB 中默认是**强一致读**，流程如下：

1. **获取 TSO**：TiDB 向 PD（Placement Driver）请求一个全局唯一的时间戳（TSO — Timestamp Oracle），该 TSO 代表查询开始那一瞬间的"逻辑时间点"
2. **从 Leader 读取**：每个 Region 的 Leader 副本负责处理读请求。TiDB 将带有 TSO 的读取请求发送到各 Region 的 Leader TiKV 节点
3. **Leader 确认**：Leader 需要确认自己仍然是 Leader（通过 lease 机制），确保返回的数据是最新且一致的
4. **MVCC 快照读**：TiKV 使用 Multi-Version Concurrency Control（MVCC），根据 TSO 找到 <= TSO 的最新提交版本并返回

```
┌──────────┐     ① Get TSO      ┌──────┐
│  TiDB    │ ──────────────────► │  PD  │
│  SQL层   │ ◄────────────────   │      │
└────┬─────┘   TSO: 4567890123  └──────┘
     │
     │ ② 发送读请求 (TSO + key ranges)
     ▼
┌──────────┐  ┌──────────┐  ┌──────────┐
│  TiKV-1  │  │  TiKV-2  │  │  TiKV-3  │
│ (Leader) │  │ (Leader) │  │ (Leader) │
│          │  │          │  │          │
│ Region-A │  │ Region-B │  │ Region-C │
└──────────┘  └──────────┘  └──────────┘
```

---

### 场景2: 与写入操作的锁交互

```sql
-- 会话 A: 开启显式事务，更新一行
BEGIN;
UPDATE t_stale SET qty = qty + 1 WHERE id = 1;
-- 此时会话 A 持有 id=1 行的锁（悲观模式）

-- 会话 B: 尝试读取同一行（强一致读）
SELECT * FROM t_stale WHERE id = 1;
-- 悲观事务模式下：
--   TiDB 会尝试对 id=1 加读锁，但该行已被写事务锁定
--   → 读请求等待写事务提交或回滚（锁等待）
--   → 如果锁等待超时（tidb_lock_wait_timeout），返回锁超时错误
```

#### 锁交互分析

| 维度 | 强一致读 | Stale Read |
|------|---------|-----------|
| TSO 获取 | 每次查询向 PD 获取最新 TSO | 使用历史 TSO（无需 PD 交互） |
| 读取目标 | Leader 副本 | Leader 或 Follower（取决于配置） |
| 读锁机制 | 悲观模式下可能需要读锁 | **不加锁**，直接读历史 MVCC 版本 |
| 与写事务关系 | 可能被阻塞（等锁或等提交） | **不被阻塞**：读写不同 MVCC 版本 |
| 延迟 | 等待 Leader 确认 + 可能锁等待 | 最多等待 Follower 同步到指定 TSO |

---

### 场景3: 强一致读的延迟来源

```
强一致读总延迟 = TSO获取延迟 + Leader确认延迟 + 扫描延迟 + 锁等待延迟
                  (~0.5ms)     (~0-2ms)         (可变)      (0~∞)
```

1. **TSO 获取延迟**：每次查询需向 PD 发送 RPC 请求获取 TSO（约 0.5ms），高频查询时 PD 可能成为瓶颈
2. **Leader 确认延迟**：Leader 需通过 Raft lease 确认自己的 Leader 身份
3. **锁等待延迟**：如果目标行有未提交的写事务，读操作需等待（tidb_lock_wait_timeout 默认值内）

---

### 核心问题总结

强一致读的三个痛点：

1. **PD TSO 瓶颈**：高并发读场景下，所有查询都向 PD 请求 TSO，PD 负载高
2. **Leader 压力集中**：所有读都打到 Leader 副本，Follower 副本闲置
3. **读写干扰**：写事务的锁可能阻塞读操作，尤其是悲观事务模式下的长事务
