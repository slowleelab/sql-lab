# EXPLAIN 参考结果 - bad.sql（AUTO_INCREMENT 写热点）

## TiDB v7.5.1（3 表各 1000 行种子数据）

---

### SHOW TABLE t_auto_inc REGIONS

AUTO_INCREMENT 表的 Region 分布——由于 ID 连续递增，初始 1000 行通常只占用 1 个 Region：

```sql
SHOW TABLE t_auto_inc REGIONS;
```

```
+-----------+-----------+--------+-----------+-----------------+------------------+
| REGION_ID | START_KEY | END_KEY| LEADER_ID | LEADER_STORE_ID | PEERS            |
+-----------+-----------+--------+-----------+-----------------+------------------+
|      1024 | t_1_     |        |      1025 |               1 | 1025, 1026, 1027 |
+-----------+-----------+--------+-----------+-----------------+------------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| REGION_ID | `1024` | 仅 1 个 Region |
| START_KEY | `t_1_` | 表的起始键（t = tableID, _1_ = 行数据前缀） |
| END_KEY | （空） | 表示这是最后一个（也是唯一一个）Region |
| LEADER_STORE_ID | `1` | 所有读写都路由到 store 1 |

**关键问题**：只有 1 个 Region，所有写入请求都打到同一个 TiKV 节点（store 1）。在高并发写入时，该节点 CPU 会飙到 100%，而其他节点几乎空闲。

---

### 批量 INSERT 后的 Region 变化

```sql
-- 再次查看 Region 分布
SHOW TABLE t_auto_inc REGIONS;
```

```
+-----------+-----------+--------+-----------+-----------------+------------------+
| REGION_ID | START_KEY | END_KEY| LEADER_ID | LEADER_STORE_ID | PEERS            |
+-----------+-----------+--------+-----------+-----------------+------------------+
|      1024 | t_1_     |        |      1025 |               1 | 1025, 1026, 1027 |
+-----------+-----------+--------+-----------+-----------------+------------------+
```

即使追加了 1000 行数据，仍然只有 1 个 Region（未达到 Region 分裂阈值 96MB）。新增数据的 ID 范围是连续的（1001-2000），仍然落在同一个 Region 内。

---

### EXPLAIN INSERT（单点写入计划）

```sql
EXPLAIN INSERT INTO t_auto_inc (name, val) VALUES ('hotspot_test', 999);
```

```
+-----------+----------+------+---------------+---------------+
| id        | estRows  | task | access object | operator info |
+-----------+----------+------+---------------+---------------+
| Insert_1  | N/A      | root |               | N/A           |
+-----------+----------+------+---------------+---------------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| id | `Insert_1` | 插入算子 |
| task | `root` | 在 TiDB server 层执行 |

AUTO_INCREMENT 插入的执行计划本身很简单，但从分布式角度来看，**所有 INSERT 的目标 Region 相同**——这就形成了写热点。

---

### 热点原理图解

```
AUTO_INCREMENT（ID 连续递增）:

  ID: 1001 → Region-1024 (Leader on Store-1)
  ID: 1002 → Region-1024 (Leader on Store-1)  ← 所有写入打到这里！
  ID: 1003 → Region-1024 (Leader on Store-1)
  ID: 1004 → Region-1024 (Leader on Store-1)
  ...

  Store-1: ████████████████  CPU 100%
  Store-2: ░░░░░░░░░░░░░░░░  CPU 5%
  Store-3: ░░░░░░░░░░░░░░░░  CPU 5%
```

AUTO_INCREMENT 生成的 ID 是严格递增的，而 TiDB 按主键范围切分 Region。连续递增的 ID 永远落在 Range 最大的那个 Region 上，直到 Region 达到 96MB 后分裂。分裂后，最新写入仍然只命中最新分裂出的那个 Region——**热点会随分裂迁移，但永远不会消失**。
