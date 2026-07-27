# EXPLAIN 参考结果 - good.sql（Region Split 与 Scatter 效果分析）

## TiDB v7.5.1（35 万 t_region_test 行）

---

### 方案1: SPLIT TABLE — 手动预分裂

```sql
SPLIT TABLE t_region_test BETWEEN (0) AND (MAXVALUE) REGIONS 8;
```

#### 执行原理

```
SPLIT 前:
  Region 1: [t_152_ ...................... t_152_00]  (全表一个 Region, ~189MB)

SPLIT 命令执行:
  ① PD 计算主键范围，将 [0, MAXVALUE) 均分为 8 段
  ② 在每个分界点创建新的 Region 边界
  ③ 触发 Raft Split，数据在每个分段内重新分布

SPLIT 后:
  Region 1: [t_152_ ........... t_152_r_{N/8}]
  Region 2: [t_152_r_{N/8+1} .. t_152_r_{2N/8}]
  Region 3: [t_152_r_{2N/8+1} . t_152_r_{3N/8}]
  ...
  Region 8: [t_152_r_{7N/8+1} . t_152_00]
```

#### 查看 Split 后的 Region 分布

```sql
SHOW TABLE t_region_test REGIONS;
```

```
+-----------+-----------------------------+-----------------------------+-----------+---------------------+-----------+
| REGION_ID | START_KEY                   | END_KEY                     | LEADER_ID | APPROXIMATE_SIZE    | APPROXIMATE_KEYS |
+-----------+-----------------------------+-----------------------------+-----------+---------------------+-----------+
|      1021 | t_152_                      | t_152_r_43000               |      1022 |            23600000 |     43750 |
|      1025 | t_152_r_43001               | t_152_r_86000               |      1023 |            23550000 |     43750 |
|      1026 | t_152_r_86001               | t_152_r_129000              |      1022 |            23610000 |     43750 |
|      1027 | t_152_r_129001              | t_152_r_172000              |      1024 |            23580000 |     43750 |
|      1028 | t_152_r_172001              | t_152_r_215000              |      1025 |            23620000 |     43750 |
|      1029 | t_152_r_215001              | t_152_r_258000              |      1026 |            23590000 |     43750 |
|      1030 | t_152_r_258001              | t_152_r_301000              |      1027 |            23600000 |     43750 |
|      1031 | t_152_r_301001              | t_152_00                    |      1027 |            23570000 |     35000 |
+-----------+-----------------------------+-----------------------------+-----------+---------------------+-----------+
```

**观察要点**：

- 表被切分为 8 个 Region，每个约 23.6MB（总计 ~189MB）
- 每个 Region 约 4.3 万行（均匀分布）
- `APPROXIMATE_SIZE` 均衡，说明数据按主键范围均匀切分
- 注意：如果 `LEADER_ID` 集中在少数 TiKV 节点，说明 Leader 分布不均衡，需要 `SCATTER`

---

### 方案2: SCATTER — 打散 Leader / Peer 分布

```sql
ALTER TABLE t_region_test SCATTER;
```

#### 执行效果

```
SCATTER 前:
  Store 1: [Leader: Region 1, Region 3, Region 5]  ← 负载过高
  Store 2: [Leader: Region 2]
  Store 3: [Leader: Region 4, Region 6, Region 7, Region 8]  ← 负载过高

SCATTER 后（等待调度完成）:
  Store 1: [Leader: Region 1, Region 6]
  Store 2: [Leader: Region 2, Region 5, Region 8]
  Store 3: [Leader: Region 3, Region 7]
  Store 4: [Leader: Region 4]
```

SCATTER 操作为异步调度，实质是将表的每个 Region 的 Leader/Peer 随机分配到不同 TiKV 节点上。PD 的 `scatter-range` 调度器会持续将新产生的 Leader 分配到负载较低的节点。

#### 观察 SCATTER 效果

```sql
-- 等待 3-5 秒调度生效
SHOW TABLE t_region_test REGIONS;
```

```
+-----------+-----------------------------+-----------------------------+-----------+---------------------+-----------+
| REGION_ID | START_KEY                   | END_KEY                     | LEADER_ID | APPROXIMATE_SIZE    | APPROXIMATE_KEYS |
+-----------+-----------------------------+-----------------------------+-----------+---------------------+-----------+
|      1021 | t_152_                      | t_152_r_43000               |      1022 |            23600000 |     43750 |
|      1025 | t_152_r_43001               | t_152_r_86000               |      1024 |            23550000 |     43750 |
|      1026 | t_152_r_86001               | t_152_r_129000              |      1023 |            23610000 |     43750 |
|      1027 | t_152_r_129001              | t_152_r_172000              |      1025 |            23580000 |     43750 |
|      1028 | t_152_r_172001              | t_152_r_215000              |      1022 |            23620000 |     43750 |
|      1029 | t_152_r_215001              | t_152_r_258000              |      1026 |            23590000 |     43750 |
|      1030 | t_152_r_258001              | t_152_r_301000              |      1024 |            23600000 |     43750 |
|      1031 | t_152_r_301001              | t_152_00                    |      1025 |            23570000 |     35000 |
+-----------+-----------------------------+-----------------------------+-----------+---------------------+-----------+
```

**关键变化**：`LEADER_ID` 从集中在 1022、1027 两个节点，变为均匀分布在 1022-1026 五个节点上。

---

### 方案3: PD 热点调度参数速查

```sql
-- 查看 PD 热点调度配置
SHOW CONFIG WHERE type = 'pd' AND name LIKE '%hot-region%';
```

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|---------|
| `hot-region-schedule-limit` | 4 | 同时进行热点调度的 Region 数量上限 | 热点严重时可临时调高到 8-16 |
| `hot-region-cache-hits-threshold` | 3 | Region 被检测为热点的最小阈值次数 | 减小可更快识别热点，但可能误判 |
| `leader-schedule-limit` | 4 | 同时进行 Leader 迁移的数量上限 | 配合 scatter 调高可加速打散 |
| `region-schedule-limit` | 2048 | 同时进行 Region 迁移的数量上限 | 通常无需调整 |

**注意**：

- PD 热点调度是**反应式**的——它只有在热点已经形成后才介入
- 正确的做法是在建表阶段就**预分配 Region**（SPLIT TABLE），从源头避免热点
- `SCATTER` 是一次性操作；若后续有新的 Split，新 Region 的 Leader 可能再次集中在某节点，需要定期或按需 SCATTER

---

### 方案4: 热点调度效果对比

```
                                    SPLIT 前           SPLIT 后          SPLIT + SCATTER 后
┌────────────────────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Region 数量                 │  │     1        │  │      8       │  │      8       │
│ 每个 Region 大小            │  │   189 MB     │  │   ~23.6 MB   │  │   ~23.6 MB   │
│ 写入负载分布                │  │ 1 个 TiKV    │  │ 2-3 个 TiKV  │  │ 均匀分布      │
│ Leader 分布                 │  │ 集中         │  │ 部分集中      │  │ 均匀          │
│ 新增写入的路由              │  │ 同一 Region  │  │ 按主键范围    │  │ 按主键范围    │
│ 热点风险                    │  │       严重   │  │       中     │  │      低       │
└────────────────────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
```

---

### 方案5: 针对索引热点的额外策略

SPLIT TABLE 按主键切分可以缓解**主键写入**的热点，但如果热点来自**二级索引**（如本案例中 idx_ts 的写入倾斜），仅 SPLIT 主键 Region 仍然不够。

#### 索引热点追加策略

| 策略 | 命令 | 适用场景 |
|------|------|---------|
| 使用分区表 | `PARTITION BY RANGE (YEAR(ts))` | ts 按时间自然分区，每个分区独立 Region 集合 |
| 使用 AUTO_RANDOM | `PRIMARY KEY (id) AUTO_RANDOM` | 写入主键时打散到多 Region |
| 使用 SHARD_ROW_ID_BITS | `SHARD_ROW_ID_BITS = 4` | 非聚簇索引的隐藏 _tidb_rowid 打散 |
| 业务层打散 | 写入时随机化 ts 值（如增加毫秒级抖动） | 业务可接受微小的时间偏差 |

#### 分区表示例（概念说明）

```sql
CREATE TABLE t_region_test_partitioned (
    id    BIGINT   NOT NULL AUTO_INCREMENT,
    val   INT      NOT NULL DEFAULT 0,
    ts    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, ts),  -- 分区键必须在主键中
    INDEX idx_ts (ts)
) PARTITION BY RANGE (TO_DAYS(ts)) (
    PARTITION p20260701 VALUES LESS THAN (TO_DAYS('2026-07-02')),
    PARTITION p20260702 VALUES LESS THAN (TO_DAYS('2026-07-03')),
    -- ...
    PARTITION p20260728 VALUES LESS THAN (TO_DAYS('2026-07-29')),
    PARTITION p_max VALUES LESS THAN MAXVALUE
);
```

---

### 核心结论

1. **SPLIT TABLE 是预防热点的一线手段**：在初始化大表时就应预分裂 Region，而非等待自动分裂（96MB 阈值到达前热点可能已很严重）。

2. **SCATTER 解决 Leader 倾斜**：SPLIT 解决了 Region 大小均衡问题，但 Leader 可能仍然集中，需要 SCATTER 将 Leader 打散到不同 TiKV 节点。

3. **索引热点需要额外考虑**：主键 SPLIT 无法解决二级索引的热点。对于索引热点，分区表是最直接的解决方案。

4. **PD 热点调度是兜底机制**：PD 的 `hot-region-scheduler` 在热点形成后自动介入，但它是反应式的——新分裂的 Region 可能很快又形成热点。主动 SPLIT + SCATTER 优于被动依赖 PD 调度。
