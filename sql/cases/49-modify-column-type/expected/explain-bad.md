# DDL 参考结果 - bad.sql (不指定 ALGORITHM/LOCK)

## 场景说明

本案例对比的是修改列类型时不同 DDL 策略的**锁行为**差异。
不指定 `ALGORITHM` 和 `LOCK` 时，MySQL 自行选择的方式可能不是最优的。

## 不指定 ALGORITHM/LOCK 的行为

```
-- 执行 DDL
ALTER TABLE t_user MODIFY COLUMN phone VARCHAR(20) NOT NULL DEFAULT '';

-- MySQL 自行决策过程:
-- 1. 判断 MODIFY COLUMN 是否支持 INPLACE -> 支持（但需 rebuild）
-- 2. 选择 LOCK 级别 -> 默认 LOCK=DEFAULT（可能退化为 SHARED）
-- 3. LOCK=SHARED 意味着: 允许 SELECT，阻塞 INSERT/UPDATE/DELETE
-- 4. 开始重建表数据（100 万行逐行转换）
-- 5. 重建期间所有写操作排队等待
```

## 关键问题

| 维度 | 不指定策略 (bad) | 影响 |
|------|-----------------|------|
| 锁级别 | LOCK=SHARED（默认） | **阻塞所有写操作**，读不受影响 |
| 数据拷贝 | 全表 rebuild | 100 万行逐行转换列类型 |
| 执行时间 | 与表行数成正比 | 100 万行约 60-120 秒 |
| 写操作 | 完全阻塞 | 期间 INSERT/UPDATE/DELETE 排队 |
| 不可控性 | MySQL 自行选择 | 不同版本/配置行为可能不同 |

## 为什么慢

不指定 `ALGORITHM` 和 `LOCK` 的风险在于**行为不可控**：

1. **LOCK=SHARED 阻塞写入**：MySQL 默认可能选择 SHARED 锁，期间所有 INSERT/UPDATE/DELETE 排队等待，业务写入完全停滞
2. **全表 rebuild**：修改列类型需要重建每一行的记录格式，100 万行逐行转换
3. **行为不可预测**：不同 MySQL 版本、不同参数配置下，默认行为可能不同。5.7 和 8.0 的默认策略有差异
4. **静默退化风险**：如果 INPLACE 不支持当前操作，MySQL 可能静默退化到 COPY 模式（全程锁表），而你毫不知情
5. **生产事故隐患**："以为很快结果锁了 10 分钟"是常见的生产事故原因

### 不同 LOCK 级别对比

```
LOCK=NONE:     读写均不阻塞（最优）
LOCK=SHARED:   读不阻塞，写阻塞（默认可能选这个）
LOCK=EXCLUSIVE: 读写均阻塞（最差，COPY 模式）
```

## 实际表现

100 万行数据下，不指定策略修改列类型耗时约 **60-120 秒**。
期间所有写操作阻塞，如果业务有持续写入，连接池可能被打满。

## MySQL 5.7 vs 8.0 差异

- 5.7 中 MODIFY COLUMN 的默认 LOCK 级别更容易退化为 SHARED
- 8.0 的 Online DDL 覆盖范围更广，默认行为更友好
- 两个版本都建议显式指定 ALGORITHM 和 LOCK，避免依赖默认行为
