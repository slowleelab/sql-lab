# EXPLAIN 参考结果 - bad.sql (优化前)

## MySQL 8.0（AUTO_INCREMENT 接近 INT UNSIGNED 上限）

```
-- INSERT 报错，无 EXPLAIN
ERROR 1467 (HY000): Failed to read auto-increment value from storage engine
```

或

```
ERROR 1062 (23000): Duplicate entry '4294967295' for key 'PRIMARY'
```

## 关键问题

| 指标 | 值 | 分析 |
|------|-----|------|
| AUTO_INCREMENT | 4,294,967,295 | INT UNSIGNED 上限 |
| 剩余可用 ID | 0 | 无法继续插入 |
| 错误类型 | 1467 / 1062 | 自增耗尽或主键冲突 |
| 业务影响 | 全部写入中断 | 非慢查询，是致命故障 |

## 为什么危险

`INT UNSIGNED` 上限为 **4,294,967,295**（约 42.9 亿），`INT` 有符号上限仅 **2,147,483,647**（约 21.5 亿）。

当 AUTO_INCREMENT 达到上限后：
1. 新 INSERT 直接报错，所有写入中断
2. 业务全面瘫痪，不是变慢而是**完全不可用**
3. 紧急扩容 BIGINT 需要 ALTER TABLE，大表可能锁表数小时
4. 如果使用了 `INT`（有符号），21 亿就会触发，很多系统 3-5 年就会遇到

## 查询自增水位

```sql
SELECT AUTO_INCREMENT,
       4294967295 - AUTO_INCREMENT AS remaining_slots
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 't_order_bad';
```

结果：

```
+------------+------------------+
| AUTO_INCREMENT | remaining_slots |
+------------+------------------+
| 4294967296 |               -1 |  -- 已溢出！
+------------+------------------+
```
