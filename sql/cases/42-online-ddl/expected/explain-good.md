# DDL 参考结果 - good.sql (ALGORITHM=INPLACE, LOCK=NONE)

## 场景说明

本案例对比的是 DDL 算法，不是普通查询优化。重点在于 Online DDL 的
**并发能力**和**执行效率**。

## ALGORITHM=INPLACE, LOCK=NONE 的行为

```
-- 执行 DDL
ALTER TABLE t_big_table ADD KEY idx_user_id (user_id), ALGORITHM=INPLACE, LOCK=NONE;

-- 过程:
-- 1. 短暂获取 MDL 排他锁（仅元数据变更瞬间，毫秒级）
-- 2. 降级为 MDL 共享锁，允许并发 DML
-- 3. 在存储引擎内部构建索引（row log 记录期间 DML 变更）
-- 4. 回放 row log，合并到新索引
-- 5. 短暂获取 MDL 排他锁，提交变更
```

## 关键改进

| 维度 | COPY 模式 (bad) | INPLACE+LOCK=NONE (good) | 提升 |
|------|-----------------|--------------------------|------|
| 锁级别 | 表级独占锁 | NONE（允许并发 DML） | DDL 期间业务不中断 |
| 数据拷贝 | 全表拷贝到临时表 | 存储引擎内部构建 | 减少额外 I/O |
| 磁盘空间 | 2 倍表空间 | 仅新索引空间 | 节省 ~50% 空间 |
| 执行时间 | 3-5 秒（20万行） | 1-2 秒（20万行） | 速度提升约 2 倍 |
| 业务影响 | 期间不可写 | 期间可正常读写 | 零停机 |

## 为什么快

`ALGORITHM=INPLACE, LOCK=NONE` 的核心原理：

1. **不创建临时表**：索引在 InnoDB 内部直接构建，无需拷贝全表数据
2. **row log 机制**：DDL 期间并发的 DML 操作记录到 row log，DDL 完成后回放合并
3. **LOCK=NONE**：DDL 期间允许 INSERT/UPDATE/DELETE 并发执行，业务不感知
4. **MDL 锁持有极短**：仅在开始和提交阶段持有排他 MDL 锁，中间降级为共享锁

## 三种算法对比

| 算法 | 数据拷贝 | 锁 | 并发 DML | 适用场景 |
|------|----------|-----|----------|----------|
| COPY | 全表拷贝到临时表 | 表级独占 | 不允许 | 兼容性兜底（最差） |
| INPLACE | 存储引擎内部构建 | NONE/SHARED | 允许 | 加索引、加列等（推荐） |
| INSTANT | 不拷贝 | 无 | 允许 | 加列、重命名列等（8.0 新增，最快） |

> 注意：**加索引**操作不支持 INSTANT（需要实际构建索引数据），但 INPLACE+LOCK=NONE 已是最佳方案。
> INSTANT 适用于 `ADD COLUMN`（末尾加列）等纯元数据变更。

## 量化对比

| 指标 | bad (COPY) | good (INPLACE+NONE) | 提升 |
|------|-----------|---------------------|------|
| 锁表时间 | 全程（3-5秒） | 毫秒级 | **业务零感知** |
| 执行耗时 | 3-5 秒 | 1-2 秒 | **约 2 倍** |
| 磁盘空间 | 2x 表空间 | 1x + 索引 | **节省 ~50%** |
| 并发 DML | 阻塞 | 不阻塞 | **在线无停机** |

## 5.7 vs 8.0 差异

- 两者都支持 INPLACE+LOCK=NONE 加索引，执行计划一致
- 8.0 额外支持 INSTANT 算法（加列等操作），5.7 无此能力
- 8.0 的 Online DDL 覆盖范围更广，退化到 COPY 的情况更少

## 避坑指南

1. **先评估再执行**：用 `ALTER TABLE ... ALGORITHM=INPLACE, LOCK=NONE` 语法让 MySQL 自行校验，
   如果不支持会直接报错而非静默退化到 COPY
2. **监控 row log 大小**：并发 DML 过多时 row log 可能膨胀，需关注 `innodb_online_alter_log_max_size`
3. **大表仍需谨慎**：INPLACE 虽然不锁表，但构建索引仍消耗 CPU 和 I/O，建议低峰期执行
4. **使用 pt-online-schema-change**：超大规模表（亿级）可考虑 pt-osc 或 gh-ost 工具做更细粒度控制
