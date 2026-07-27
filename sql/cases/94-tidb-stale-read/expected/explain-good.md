# EXPLAIN 参考结果 - good.sql（Stale Read 分析）

## TiDB v7.5.1（10 万 t_stale 行）

---

### 会话级 Stale Read（tidb_read_staleness）

```sql
SET SESSION tidb_read_staleness = -5;
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale;
SET SESSION tidb_read_staleness = '';
```

执行计划与普通查询相同（仍为 `TableFullScan → HashAgg`），但执行路径不同：

**关键差异**：

| 维度 | 普通强一致读 | Stale Read (staleness=-5) |
|------|------------|--------------------------|
| TSO 来源 | PD 实时分配 | PD 分配 + 向后偏移 5 秒 |
| 读取版本 | 最新已提交版本 | 5 秒前已提交版本 |
| Leader 确认 | 需要确认 Leader lease | **不需要**确认（历史版本不受 Leader 变更影响） |
| 锁交互 | 可能与写锁冲突 | **不冲突**（读历史版本，不存在锁竞争） |
| PD 依赖 | 每次查询需要一次 PD RPC | 与强一致读相同（仍需 PD 分配 TSO，但减少 Leader 确认） |

#### AS OF TIMESTAMP 内部实现

```sql
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale
AS OF TIMESTAMP TIMESTAMPADD(SECOND, -10, NOW());
```

**MVCC 版本查找流程**：

```
当前 TSO: 4567890500
AS OF TIMESTAMP 计算: T0 = NOW() - 10s → 物理时间转为 TSO: ~4567890000

TiKV 接收请求 (key_range, TSO=4567890000):
  1. 扫描 CF_WRITE（Write Column Family）
  2. 找到 commit_ts <= 4567890000 的最新 write record
  3. 通过 write record 定位 CF_DEFAULT 中的对应 MVCC 版本
  4. 返回该版本的数据值

如果 T0 对应时间点无数据（该 key 在 T0 之后才首次写入）:
  → 返回空（该 key 不存在于该快照）
```

---

### tidb_read_staleness 参数说明

| 参数值 | 含义 | 示例 |
|--------|------|------|
| `0` | 强一致读（默认） | `SET SESSION tidb_read_staleness = 0;` |
| 负整数 | 读取 N 秒前的快照 | `SET SESSION tidb_read_staleness = -5;`（读 5 秒前） |
| 正整数 | 读取未来 N 秒的快照（极少使用） | `SET SESSION tidb_read_staleness = 5;` |
| 绝对时间戳 | 读取指定时间点的快照 | `SET SESSION tidb_read_staleness = '2026-07-01 10:00:00';` |
| `''`（空字符串） | 恢复默认（强一致读） | `SET SESSION tidb_read_staleness = '';` |

**注意**：

- `tidb_read_staleness` 是**会话级**变量，作用于该会话的所有后续查询
- 与 `AS OF TIMESTAMP` 的区别：前者隐式生效（所有 SQL），后者显式指定（单条 SQL）
- **延迟时间不能超过 `tidb_gc_life_time`**（默认 10 分钟），否则历史版本已被 GC 回收

---

### Stale Read + Follower Read 组合

```sql
SET SESSION tidb_replica_read = 'follower';
SET SESSION tidb_read_staleness = -5;
SELECT COUNT(*), SUM(qty), SUM(qty * price) FROM t_stale;
```

**组合效果**：

```
                  ┌─────────────┬──────────────────┐
                  │ Follower Read │ Stale Read       │
┌─────────────────┼─────────────┼──────────────────┤
│ Leader 读取      │ 不适用       │ 不阻塞写但需Leader│
│ Follower 读取    │ 分担读压力   │ 完美组合         │
│ TSO 获取         │ 仍需 PD      │ 仍需 PD          │
│ 数据一致性       │ snapshot     │ snapshot         │
│ 与写操作关系     │ 不阻塞        │ 不阻塞           │
└─────────────────┴─────────────┴──────────────────┘
```

**使用场景**：

- **报表系统**：每天生成日报，容忍 5 秒延迟，读写不互相干扰
- **数据导出**：全量导出大表，不需要最新数据，避免与在线事务冲突
- **审计查询**：对账场景，需要某个时间点的快照数据
- **缓存刷新**：定期刷新预热缓存，无需实时最新数据

---

### 三类读取方式对比

| 对比维度 | Strong Read | Follower Read | Stale Read |
|---------|-------------|---------------|------------|
| 读取目标 | Leader | Follower | Leader / Follower |
| 数据实时性 | 最新已提交 | ~100ms 延迟（Raft apply） | 自定义（秒级） |
| 一致性保证 | 线性一致性 | 快照一致性 | 快照一致性 |
| 是否阻塞写入 | **可能阻塞**（锁等待） | 不阻塞 | **不阻塞** |
| 是否被写入阻塞 | **可能被阻塞** | 不阻塞 | **不阻塞** |
| TSO 来源 | PD 实时分配 | PD 实时分配 | PD TSO 偏移 |
| Leader 确认 | 需要 | Follower 应用进度确认 | 不需要（历史版本） |
| 适用场景 | 金融交易、实时订单 | 高并发查询 | 报表、导出、审计 |
| PD 压力 | 高（每次查询请求 TSO） | 高 | 中（仍需 TSO 但偏移后使用） |

#### 执行流程对比

```
Strong Read:
  TiDB → PD(GetTSO) → TiKV-Leader(需要确认Leader身份+最新版本) → 返回
  延迟: TSO_RPC + Leader_check + Scan

Follower Read:
  TiDB → PD(GetTSO) → TiKV-Follower(确认已应用到TSO) → 返回
  延迟: TSO_RPC + apply_wait + Scan

Stale Read:
  TiDB → PD(GetTSO) → TSO偏移 → TiKV-任意副本(直接读历史版本) → 返回
  延迟: TSO_RPC + Scan (无Leader确认, 无apply_wait)
```

---

### Stale Read 的限制

1. **GC 时间限制**：读取的历史时间点必须在 GC SafePoint 之后
   ```
   当前时间 - Stale Read 偏移 ≤ tidb_gc_life_time (默认 10min)
   ```
   `tidb_read_staleness = -600`（10分钟前）可能因 GC 回收而失败

2. **不适用于需要最新数据的场景**：如库存扣减、订单状态查询等对实时性敏感的操作

3. **与 Stale Read 不兼容的 DDL**：某些 DDL 操作可能影响历史 MVCC 版本的可用性

4. **统计信息滞后**：Stale Read 读到的是历史数据，如果统计信息已更新，实际返回行数与 EXPLAIN 预估可能有差异
