# EXPLAIN 参考结果 - good.sql（GC 优化与长事务治理）

GC 不产生 EXPLAIN 输出。本文说明 GC 参数调优、事务超时设置、分批删除 vs 批量删除的 GC 回收速度对比，以及合理的 GC 治理方案。

---

## GC 参数调优表

| 参数 | 默认值 | 推荐值 | 说明 |
|------|--------|--------|------|
| `tikv_gc_life_time` | `10m` | `24h`（生产环境推荐） | 历史版本保留时长。太短会导致快照读失败，太长会导致版本堆积 |
| `tikv_gc_run_interval` | `10m` | `10m`（保持默认） | GC 运行间隔。过短增加 GC 开销，过长导致版本回收不及时 |
| `tikv_gc_concurrency` | `2` | `2-4`（根据集群规模调整） | GC 并发度。增加可加快 GC 速度，但会消耗更多 CPU |
| `tikv_gc_scan_lock_mode` | `LEGACY` | `PHYSICAL`（v5.0+ 推荐） | GC 锁扫描模式。PHYSICAL 模式效率更高 |
| `tikv_gc_auto_concurrency` | `true` | `true`（保持默认） | 是否自动调整 GC 并发度 |
| `tikv_gc_enable_compaction_filter` | `false` | `true`（v5.0+ 推荐） | 启用 compaction filter 辅助 GC 回收 |

### 修改 GC 生命周期

```sql
-- 将 GC 生命周期调整为 24 小时（生产环境推荐值）
UPDATE mysql.tidb SET variable_value = '24h' WHERE variable_name = 'tikv_gc_life_time';

-- 查看当前配置
SELECT * FROM mysql.tidb WHERE variable_name IN (
    'tikv_gc_safe_point', 
    'tikv_gc_run_interval', 
    'tikv_gc_life_time'
);
```

---

## 事务超时设置表

| 参数 | 默认值 | 推荐值 | 说明 |
|------|--------|--------|------|
| `tidb_idle_transaction_timeout` | `0`（不限制） | `300`（5 分钟） | 事务空闲超时。连接在事务中空闲超过此时间，自动回滚并断开 |
| `max_execution_time` | `0`（不限制） | `10000`（10 秒） | SQL 最大执行时间（毫秒）。超时自动终止 |
| `tidb_txn_mode` | `pessimistic` | 保持不变 | 悲观事务默认有锁等待超时保护 |

### 设置事务超时

```sql
-- 会话级别：空闲事务 5 分钟超时
SET SESSION tidb_idle_transaction_timeout = 300;

-- 会话级别：单条 SQL 最长执行 10 秒
SET SESSION max_execution_time = 10000;

-- 全局级别（需要 SUPER 权限）
SET GLOBAL tidb_idle_transaction_timeout = 300;
SET GLOBAL max_execution_time = 10000;
```

---

## 分批删除 vs 批量删除的 GC 回收速度对比

### 场景对比

```
批量 DELETE（bad）:
  DELETE FROM t_gc_test WHERE status = 0;
  → 单个大事务，可能持续数分钟
  → 事务期间 GC Safe Point 无法推进
  → 删除完成后 GC 才可逐步回收
  → 事务越大，GC 回收延迟越严重

分批 DELETE（good）:
  DELETE FROM t_gc_test WHERE status = 1 LIMIT 1000;
  → 每批 1000 行，事务短小（毫秒级）
  → 每批提交后 GC Safe Point 立即可推进
  → GC 渐进式回收，无版本堆积
  → 批量间可插入短暂休眠，减少系统压力
```

| 对比维度 | 批量 DELETE（一次性） | 分批 DELETE（LIMIT 1000） |
|---------|---------------------|-------------------------|
| 事务时长 | 长（数分钟甚至数小时） | 短（毫秒级） |
| 事务期间 GC | **阻塞** | 不影响 |
| 主键锁持有 | 长时间持有 | 短暂持有 |
| 版本堆积量 | 大量旧版本集中堆积 | 分散回收，不堆积 |
| 磁盘空间释放 | 延迟（等 GC 追上 Safe Point） | 渐进释放 |
| 可中断 | 中断代价大（回滚时间长） | 随时可暂停/恢复 |
| 适用场景 | 离线维护窗口 | 在线业务持续清理 |

### 分批删除脚本示例

```sql
-- 分批删除 status=1 的数据（每批 1000 行）
-- 可在应用层或脚本中循环执行

DELIMITER $$

CREATE PROCEDURE IF NOT EXISTS batch_delete_gc()
BEGIN
    DECLARE affected_rows INT DEFAULT 1;
    WHILE affected_rows > 0 DO
        DELETE FROM t_gc_test WHERE status = 1 LIMIT 1000;
        SET affected_rows = ROW_COUNT();
        COMMIT;
        -- 可选：每批之间休眠一小段时间
        DO SLEEP(0.1);
    END WHILE;
END$$

DELIMITER ;

CALL batch_delete_gc();

DROP PROCEDURE IF EXISTS batch_delete_gc;
```

---

## GC 状态监控

```sql
-- 查看 GC 相关配置
SELECT * FROM mysql.tidb WHERE variable_name LIKE 'tikv_gc%';
-- +-----------------------------------+-------------------+
-- | variable_name                     | variable_value    |
-- +-----------------------------------+-------------------+
-- | tikv_gc_leader_uuid               | 5b7e8...          |
-- | tikv_gc_leader_desc               | host:tidb-0, pid: |
-- | tikv_gc_safe_point                | 20260728-16:00:00|
-- | tikv_gc_life_time                 | 24h               |
-- | tikv_gc_run_interval              | 10m               |
-- | tikv_gc_concurrency               | 2                 |
-- | tikv_gc_last_run_time             | 20260728-16:10:00|
-- | tikv_gc_scan_lock_mode            | PHYSICAL          |
-- | tikv_gc_enable_compaction_filter  | true              |
-- +-----------------------------------+-------------------+

-- 查看是否有 GC leader
SELECT * FROM mysql.tidb WHERE variable_name = 'tikv_gc_leader_desc';
```

---

## GC 治理最佳实践

1. **不要随意调大 `tikv_gc_life_time`**：过大的值会导致历史版本大量堆积，磁盘膨胀。生产环境建议 24h。
2. **不要随意调小 `tikv_gc_life_time`**：过小的值会导致快照读（如 `AS OF TIMESTAMP`）失败，报表类查询报错。
3. **长事务及时 kill**：发现长时间未提交的事务，通过 `CLUSTER_PROCESSLIST` 定位并 `KILL TIDB <connection_id>`。
4. **设置事务超时**：`tidb_idle_transaction_timeout` 和 `max_execution_time` 双保险。
5. **大批量写入/删除拆分**：分批执行，每批提交后给 GC 留出回收窗口。
6. **监控 GC Safe Point**：定期检查 Safe Point 是否正常推进，若长时间停滞则排查是否有长事务。
7. **启用 Compaction Filter**（v5.0+）：`tikv_gc_enable_compaction_filter = true` 可在 RocksDB compaction 时直接丢弃过期版本，减少 GC 扫描开销。
