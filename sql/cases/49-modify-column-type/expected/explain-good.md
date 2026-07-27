# DDL 参考结果 - good.sql (ALGORITHM=INPLACE, LOCK=NONE)

## 场景说明

显式指定 `ALGORITHM=INPLACE, LOCK=NONE` 是修改列类型的最佳实践。
它不仅性能最优，更重要的是**行为可预测**：不支持就直接报错，不会静默退化。

## ALGORITHM=INPLACE, LOCK=NONE 的行为

```
-- 执行 DDL
ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20) NOT NULL DEFAULT '',
    ALGORITHM=INPLACE, LOCK=NONE;

-- 过程:
-- 1. 校验: INPLACE+LOCK=NONE 是否支持当前操作 -> 支持则继续，不支持则报错
-- 2. 短暂获取 MDL 排他锁（毫秒级）
-- 3. 降级为 MDL 共享锁，允许并发 DML
-- 4. 在 InnoDB 内部重建表数据（row log 记录期间 DML 变更）
-- 5. 回放 row log，合并并发变更
-- 6. 短暂获取 MDL 排他锁，提交变更
```

## 关键改进

| 维度 | 不指定策略 (bad) | INPLACE+LOCK=NONE (good) | 提升 |
|------|-----------------|--------------------------|------|
| 锁级别 | SHARED（阻塞写） | **NONE（读写均不阻塞）** | 业务零感知 |
| 行为可预测性 | MySQL 自行选择 | **显式指定，不支持则报错** | 消除静默退化 |
| 数据拷贝 | 全表 rebuild | 全表 rebuild（引擎内部） | 相当 |
| 执行时间 | 60-120 秒 | 60-120 秒 | 相当 |
| 并发 DML | 写阻塞 | **读写均不阻塞** | 在线无停机 |

## 为什么快

`ALGORITHM=INPLACE, LOCK=NONE` 的核心价值不在于"更快"，而在于**"不锁表"**：

1. **LOCK=NONE 允许并发 DML**：DDL 期间 INSERT/UPDATE/DELETE 正常执行，业务完全无感知
2. **row log 机制**：DDL 期间的并发 DML 变更记录到 row log，DDL 完成后回放合并，保证数据一致性
3. **显式指定防退化**：如果操作不支持 LOCK=NONE，MySQL 直接报错 `LOCK=NONE is not supported`，而非静默退化为 SHARED 或 EXCLUSIVE
4. **MDL 锁极短**：仅在开始和提交阶段持有排他 MDL 锁，中间降级为共享锁

### 为什么显式指定很重要

```
不指定（危险）:
  ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20);
  -> MySQL 自行选择，可能 LOCK=SHARED
  -> 写操作阻塞 60-120 秒
  -> 你以为没问题，实际业务写入停了 2 分钟

显式指定（安全）:
  ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20), ALGORITHM=INPLACE, LOCK=NONE;
  -> 如果支持: 读写均不阻塞，业务无感知
  -> 如果不支持: 直接报错，你知道需要换方案
  -> 不存在"以为不锁实际锁了"的情况
```

## 量化对比

| 指标 | bad (不指定) | good (INPLACE+NONE) | 提升 |
|------|-------------|---------------------|------|
| 写操作阻塞 | 60-120 秒 | **0 秒** | 业务零感知 |
| 执行耗时 | 60-120 秒 | 60-120 秒 | 相当 |
| 行为可预测性 | 低（依赖默认） | **高（显式指定）** | 消除事故隐患 |
| 静默退化风险 | 有 | **无（不支持则报错）** | 安全 |

## 常见列类型修改的算法支持

| 修改操作 | INPLACE | LOCK=NONE | 说明 |
|----------|---------|-----------|------|
| VARCHAR 变长（50->100） | 支持 | 支持 | 8.0 中扩大 VARCHAR 通常 INPLACE |
| VARCHAR 变短（50->20） | 支持 | 支持 | 需 rebuild 但可 LOCK=NONE |
| INT -> BIGINT | 支持 | 支持 | 需 rebuild 但可 LOCK=NONE |
| 改列字符集 | 支持 | 支持 | 需 rebuild 但可 LOCK=NONE |
| 改列类型为完全不同类型 | 可能不支持 | 可能不支持 | 如 VARCHAR -> INT，可能需 COPY |

## 5.7 vs 8.0 差异

- 两者都支持 INPLACE+LOCK=NONE 修改列类型
- 8.0 的 Online DDL 覆盖范围更广，更多操作支持 LOCK=NONE
- 8.0 的代价模型更精确，默认行为更友好
- 核心建议一致：**始终显式指定 ALGORITHM 和 LOCK**

## 避坑指南

1. **永远显式指定 ALGORITHM 和 LOCK**：不要依赖 MySQL 的默认行为，显式指定让行为可预测
2. **先在测试环境验证**：用相同数据量在测试环境执行，确认耗时和锁行为
3. **监控 row log 大小**：并发 DML 过多时 row log 可能膨胀，关注 `innodb_online_alter_log_max_size`
4. **低峰期执行**：虽然 LOCK=NONE 不阻塞业务，但 rebuild 仍消耗 CPU 和 I/O，建议低峰期执行
5. **超大表考虑 pt-osc**：亿级表可考虑 pt-online-schema-change 或 gh-ost，提供更细粒度的控制
