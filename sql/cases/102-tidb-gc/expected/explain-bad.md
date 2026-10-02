# EXPLAIN 参考结果 - bad.sql（长事务阻塞 GC 机制分析）

GC 不产生 EXPLAIN 输出。本文说明 TiDB GC（垃圾回收）的工作机制、MVCC 版本链、长事务如何阻塞 GC Safe Point 推进，以及 Lock View 排查方法。

---

## TiDB MVCC 版本链

TiDB 基于 MVCC（多版本并发控制）模型，对每一行的 DELETE/UPDATE 不会立即覆盖或删除数据，而是写入新版本并保留旧版本：

```
row(key=k1) → v3(当前, ts=300) → v2(旧版本, ts=200) → v1(更旧, ts=100)

DELETE 操作:
  执行前: row(k1) → v3(ts=300) → v2(ts=200) → v1(ts=100)
  DELETE WHERE id=100;
  执行后: row(k1) → v4(DELETE标记, ts=400) → v3(ts=300) → v2(ts=200) → v1(ts=100)
                              ↑ 新写入的"删除标记"版本
```

- **INSERT**：写入第一个版本
- **UPDATE**：写入新版本，旧版本保留
- **DELETE**：写入一个 DELETE 标记版本，旧版本保留
- **GC**：后台周期性清理"不再需要的旧版本"

---

## GC Safe Point 被长事务阻塞的时间线

GC Safe Point 是 TiDB 确定"哪些旧版本可以安全删除"的依据——Safe Point 之前的版本（且没有被任何活跃事务引用）可以被 GC 回收。

```
时间线: 长事务如何阻塞 GC

 T1 ─ 事务A (长事务) BEGIN
 │    start_ts = 100
 │    SELECT * FROM t_gc_test WHERE id = 1;  -- 开启长事务
 │
 T2 ─ DELETE FROM t_gc_test WHERE status = 0;
 │    删除约 1 万行（写入 DELETE 标记版本，start_ts=200）
 │    COMMIT;
 │
 T3 ─ GC 尝试推进 Safe Point
 │    当前活跃事务: 事务A (start_ts=100)
 │    GC Safe Point 只能推进到 start_ts - 1 之前
 │    → Safe Point 卡在 ts=99，无法跨越事务A
 │
 T4 ─ 事务A 仍在运行中（未 COMMIT/ROLLBACK）
 │    Safe Point 持续被阻塞
 │    DELETE 的 1 万行旧版本无法被 GC 清除
 │
 T5 ─ GC 下一轮尝试
 │    事务A 仍未结束
 │    Safe Point 依然卡在 ts=99
 │    磁盘空间持续增长，旧版本堆积
 │
 T6 ─ 事务A 最终 COMMIT/ROLLBACK
 │    Safe Point 可推进到最新已提交时间戳
 │    GC 开始回收堆积的旧版本
```

**关键点**：GC Safe Point 必须保证所有 `start_ts < safe_point` 的事务都已经完成。如果存在一个 `start_ts` 很小的长事务，Safe Point 就无法推进到该事务的 `start_ts` 之后。

---

## GC 配置与 Safe Point 查看

```sql
-- 查看 GC 生命周期（默认 10 分钟）
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_life_time';
-- +----------------------+----------------+
-- | variable_name        | variable_value |
-- +----------------------+----------------+
-- | tikv_gc_life_time    | 10m            |
-- +----------------------+----------------+

-- 查看当前 Safe Point
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_safe_point';
-- +-----------------------+--------------------------------+
-- | variable_name         | variable_value                 |
-- +-----------------------+--------------------------------+
-- | tikv_gc_safe_point    | 20260728-15:30:00             |
-- +-----------------------+--------------------------------+

-- GC Safe Point 仅能推进到（当前时间 - tikv_gc_life_time）且在所有活跃事务的 start_ts 之前
-- 即: safe_point = MIN(
--   NOW() - tikv_gc_life_time,
--   最小活跃事务 start_ts - 1
-- )
```

---

## 查看当前活跃事务（排查 Safe Point 阻塞）

```sql
-- 查看长时间运行的事务
SELECT * FROM information_schema.cluster_processlist 
WHERE command != 'Sleep' AND time > 10;

-- 查看事务信息（查看 start_ts）
SELECT 
    txn_id,
    start_time,
    TIMESTAMPDIFF(SECOND, start_time, NOW()) AS duration_sec,
    query
FROM information_schema.cluster_tidb_txn
WHERE state = 'active'
ORDER BY start_time;
```

---

## Lock View 排查方法

```sql
-- 查看数据锁等待（TIDB 的锁视图）
SELECT * FROM information_schema.data_lock_waits;

-- 查看当前持有的锁
SELECT * FROM information_schema.cluster_tidb_locks;
```

---

## 长事务对 GC 的影响总结

| 影响维度 | 正常情况 | 长事务阻塞 |
|---------|---------|-----------|
| GC Safe Point | 平滑推进 | **卡住不动** |
| 版本回收 | 生命期后自动回收 | **持续堆积** |
| 磁盘空间 | DELETE 后逐步释放 | **DELETE 后不降反增** |
| 查询性能 | 正常 | 版本链过长，扫描变慢 |
| 系统稳定性 | 正常 | 磁盘可能写满 |

---

## 常见导致长事务的场景

| 场景 | 问题 | 排查方法 |
|------|------|---------|
| 应用层未关闭事务 | BEGIN 后忘记 COMMIT | `cluster_processlist` 查长时间连接 |
| ORM 框架隐式事务 | 框架默认开启事务未提交 | 检查 ORM 事务配置 |
| 慢查询 | 大批量 DML 未拆分 | `cluster_processlist` 查执行中的 SQL |
| 锁等待 | 悲观事务等待锁超时 | `data_lock_waits` 查锁等待链 |
| 交互式 BEGIN | `mysql` CLI 中 BEGIN 后不操作 | 设置 `tidb_idle_transaction_timeout` |
