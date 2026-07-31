# 大数据导出：SELECT INTO OUTFILE vs mysqldump

<CaseMeta difficulty="⭐⭐" category="DDL 与大表" versions="5.7 & 8.0" :tags="['SELECT INTO OUTFILE', 'mysqldump', '大数据导出', 'secure_file_priv', 'LOAD DATA INFILE']" />

## 场景痛点

需要把 5000 万行订单表导出给数据团队做离线分析。运维同学用 `mysqldump` 跑了 2 小时还没完成，磁盘 IO 跑满，业务查询变慢。改用 `SELECT INTO OUTFILE` 后 8 分钟完成，IO 平稳。

```sql
-- 5000 万行订单表 t_order_export
SELECT COUNT(*) FROM t_order_export;
-- 50000000
```

::: warning 真实场景
"把数据库里的数据导出来"看似简单，但工具选择不当可能导致：
- 业务长时间 IO 争用（mysqldump 一行行 INSERT）
- 导出文件巨大且含转义（dump 格式是 SQL）
- 跨机传输慢（dump 文件是文本+SQL）

**`SELECT INTO OUTFILE`** 是 MySQL 内置的高性能导出方案，**直接以原始格式**写入服务器本地文件，比 mysqldump 快 5-20 倍。
:::

## 问题分析

### bad.sql — mysqldump 方式

```bash
# bad 方式: mysqldump 默认一行行 INSERT
mysqldump -h127.0.0.1 -uroot -p --single-transaction \
  --tab=/tmp/exp sql_treasure t_order_export
# --tab 选项会生成 .sql (schema) + .txt (数据) 两个文件
# 但 .txt 默认是 TSV，且单线程导出，5000 万行 ~25 分钟
```

**mysqldump 缺点**：

1. **逐行 INSERT 或多行 INSERT**：5000 万条 INSERT 语句（即使合并也是几万行）
2. **含 schema DDL**：导出文件不能直接 `LOAD DATA`，需先执行 DDL
3. **网络往返**：客户端/服务端架构，每行都需交互
4. **无并发**：单线程导出，无法利用多核

### good.sql — SELECT INTO OUTFILE

```sql
-- good 方式: SELECT INTO OUTFILE 直接写文件
-- 注意: 1) 文件路径在 SERVER 端（不是客户端） 2) 需 secure_file_priv 授权
-- 3) 不会锁表，不影响业务

SELECT *
INTO OUTFILE '/var/lib/mysql-files/t_order_export.csv'
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
FROM t_order_export
WHERE created_at >= '2026-01-01';
-- 5000 万行 ~8 分钟，比 mysqldump 快 3 倍
```

### 为什么快

| 维度 | mysqldump | SELECT INTO OUTFILE |
|------|-----------|---------------------|
| 输出位置 | 客户端（网络传输） | **服务端**（直接写本地盘） |
| 格式 | SQL 语句 | 原始 CSV/TSV |
| 锁 | `--single-transaction` MVCC 无锁 | 默认无锁，事务隔离 |
| 并发 | 单线程 | 单线程（但内部流式） |
| 包含 schema | 是 | 否（纯数据） |
| 重新导入 | 直接 mysql < dump.sql | LOAD DATA INFILE |
| 索引维护 | 重建索引 | 不重建（纯数据） |

## 优化方案

### good.sql — 完整最佳实践

```sql
-- 1. 先查看 secure_file_priv 配置（决定能写到哪）
SHOW VARIABLES LIKE 'secure_file_priv';
-- NULL: 完全禁止
-- '' (空): 任意路径
-- /var/lib/mysql-files/: 仅此目录

-- 2. 启用 local_infile（如果需要从客户端 LOAD DATA）
SET GLOBAL local_infile = ON;

-- 3. 导出带表头的 CSV
SELECT 'id', 'order_no', 'user_id', 'amount', 'status', 'created_at'
UNION ALL
SELECT id, order_no, user_id, amount, status, created_at
FROM t_order_export
WHERE created_at >= '2026-01-01'
INTO OUTFILE '/var/lib/mysql-files/t_order_export.csv'
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';
-- 8 分钟导完 5000 万行
```

### 配套：导入（LOAD DATA INFILE）

```sql
-- 接收端（同一台 MySQL 或另一台）
-- 1. 先建表
CREATE TABLE t_order_import LIKE t_order_export;

-- 2. 加载（比 INSERT 快 10-100 倍）
LOAD DATA INFILE '/var/lib/mysql-files/t_order_export.csv'
INTO TABLE t_order_import
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
(id, order_no, user_id, amount, status, @created_at)
SET created_at = STR_TO_DATE(@created_at, '%Y-%m-%d %H:%i:%s');
-- 5000 万行导入 ~5 分钟
```

### 原理

**`SELECT INTO OUTFILE` 工作流**：

```
┌─────────────────┐
│ InnoDB Buffer   │
│ Pool            │
│ 扫描 5000 万行  │
└────────┬────────┘
         │ 流式（不缓存到内存）
         ▼
┌─────────────────┐
│ MySQL Server    │
│ 转换为 CSV/TSV  │
└────────┬────────┘
         │ 直接 write() 系统调用
         ▼
/var/lib/mysql-files/t_order_export.csv
（顺序写，无网络）
```

**关键优化点**：

1. **服务端直接写文件**：不经过网络，避免客户端/服务端架构的来回
2. **流式处理**：一行行处理，不缓存到内存（5000 万行不会 OOM）
3. **无锁（默认）**：与 SELECT 一样的 MVCC 读，对业务无影响
4. **格式简单**：CSV/TSV 比 SQL dump 小 30-50%（无 schema、无引号转义）

### 对比

| 维度 | mysqldump (`--tab`) | SELECT INTO OUTFILE |
|------|---------------------|---------------------|
| 5000 万行导出 | ~25 分钟 | ~8 分钟（**3 倍快**） |
| 输出文件大小 | ~3.5 GB (含 schema) | ~2.5 GB (纯数据) |
| 业务影响 | 中（IO 抖动） | 低（流式无锁） |
| 重新导入耗时 | ~30 分钟（执行 INSERT） | ~5 分钟（LOAD DATA） |
| 跨机器传输 | 中（dump 文件大） | 优（CSV 紧凑） |

<ExplainCompare
  :bad="{ type: 'mysqldump', key: '单线程 SQL', rows: '5000万行', Extra: '~25 分钟, IO 抖动' }"
  :good="{ type: 'SELECT INTO OUTFILE', key: '流式 CSV', rows: '5000万行', Extra: '~8 分钟, IO 平坦' }"
  improvement="导出速度 3 倍提升，业务影响降到 1/3"
/>

## 避坑指南

::: warning 注意事项

1. **`secure_file_priv` 必须配置**。MySQL 5.7+ 默认 `secure_file_priv=/var/lib/mysql-files-`，必须写到这个目录（即使是 root 用户）。要写其他目录需在 `my.cnf` 中修改并重启。

2. **文件是 SERVER 端，不是客户端**。`INTO OUTFILE '/tmp/x.csv'` 写在 MySQL 服务器的 `/tmp/x.csv`，不是发起查询的客户端机器。如需下载到本地，用 `SELECT ... INTO OUTFILE '/var/lib/mysql-files/x.csv'` + `scp`/`rsync` 到本地。

3. **文件已存在会报错**。`INTO OUTFILE` 不会覆盖已有文件（避免误覆盖），需先删除或用新文件名。

4. **不要用 `LOAD DATA LOCAL INFILE` 加载未验证来源的 CSV**。可能引入恶意 SQL 注入（CSV 解析漏洞）。`local_infile=ON` 是全局开关，建议仅在迁移期间开启。

5. **不写主键索引**。`SELECT INTO OUTFILE` 输出是纯数据，导入时需先建表（含主键和索引），再 `LOAD DATA`。索引会在 LOAD 时增量构建。

6. **CSV 字符集需匹配**。导出端和导入端的 `character_set_database` 需一致，否则中文/特殊字符乱码。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| `secure_file_priv` 默认 | `/var/lib/mysql-files/` | 同 5.7 |
| `LOAD DATA LOCAL` 默认 | OFF | OFF |
| 导出 UTF-8mb4 中文 | 支持（注意 BOM） | 支持 |
| 导出到压缩文件 | 需 `SELECT ... INTO OUTFILE` + 系统 `gzip` 管道 | 同 5.7 |
| `mysql --tab` 模式 | 支持 | 支持 |
| `mysqlpump`（并行导出） | 支持（5.7+）| 支持，但社区已不再推荐 |

::: tip 大数据导出推荐方案
1. **纯数据迁移**：`SELECT INTO OUTFILE` + `LOAD DATA INFILE`（3-5 倍 mysqldump 速度）
2. **需含 schema**：`mysqldump --tab` 或 `mysqlpump`（并行）
3. **跨数据库**（MySQL → ES/Hive）：先用 OUTFILE 导出 CSV，再用 DataX/Sqoop
4. **云数据库**：很多云数据库禁用 `INTO OUTFILE`，需用 `mysqldump` 或厂商工具
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 105-select-into-outfile

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 105-select-into-outfile --ver 5.7
```
