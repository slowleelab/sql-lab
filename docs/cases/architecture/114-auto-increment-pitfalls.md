# 自增序列的坑：AUTO_INCREMENT 全景避坑手册

<CaseMeta difficulty="⭐⭐⭐" category="架构" versions="5.7 & 8.0" :tags="['AUTO_INCREMENT', '跳号', '自增锁', '重启丢失', '分布式ID', '主键设计', 'Sequence']" />

## ID 跳号、重启复用旧 ID：自增序列 8 个坑一篇说清
`AUTO_INCREMENT` 几乎是每张表的默认配置，但围绕它的坑横跨表结构、事务、复制、架构四个层面。同一个团队在三年里接连踩中过这些问题：

- 财务发现订单 ID 不连续，以为数据丢了；
- MySQL 实例崩溃重启后，**一个已经删掉的 ID 被重新分配给了新订单**，而旧日志、第三方系统里还留着这个 ID 的引用；
- 订单号直接用自增 ID，竞品写个脚本从 1 开始遍历，把全站订单数据爬走；
- 分库分表后两个分片生成了相同的 ID；
- 最终 INT 主键耗尽，写入链路整体中断。

本篇把自增序列的 **8 个坑**一次讲清，并给出"主键 / 业务编号 / 分布式 ID"三层选型方案。案例 14 讲透了跳号与锁模式、案例 61 讲透了耗尽事故、案例 100 讲透了 TiDB 三方案，本文是串联它们的全景图。

::: warning 先记住三句话
1. 自增 ID 只保证**唯一**和**大致递增**，不保证连续、不保证重启不变、不保证分布式安全；
2. 计数器**只增不减**——回滚不回收、删除不回缩；
3. 自增 ID 是**内部主键**，不是给客户看的业务编号。
:::

## 坑 1：跳号——回滚和"伪插入"都在消耗 ID

```sql
CREATE TABLE t_inc (id BIGINT NOT NULL AUTO_INCREMENT, name VARCHAR(20), PRIMARY KEY(id));

-- 1) 事务回滚：ID 已分配，不回收
START TRANSACTION;
INSERT INTO t_inc(name) VALUES ('a'), ('b'), ('c');
ROLLBACK;

-- 2) INSERT IGNORE / ON DUPLICATE KEY UPDATE / REPLACE：冲突行没插进去，ID 照耗
INSERT IGNORE INTO t_inc(id, name) VALUES (100, 'dup');   -- 若 100 已存在，下一个值仍跳过 100 之后的预分配
INSERT INTO t_inc(name) VALUES ('d');                     -- id 不是 1，而是 4

SELECT * FROM t_inc;
-- +----+------+
-- | id | name |
-- +----+------+
-- |  4 | d    |   -- 1、2、3 永远消失
-- +----+------+
```

| 跳号场景 | 原因 |
|---------|------|
| INSERT 失败 / 事务回滚 | ID 在插入前已向引擎申请，回滚不归还 |
| `INSERT ... ON DUPLICATE KEY UPDATE` | 冲突行先分配了 ID，UPDATE 时不再退还 |
| `INSERT IGNORE` / `REPLACE` | 同上，被忽略或被替换的行照样占号 |
| 批量 INSERT | 默认锁模式下一次性**预分配整段** ID，语句失败整段丢弃 |

**影响判断**：跳号不影响正确性，主键本就不需要连续。真正需要连续的是发票号、流水号这类**业务序列号**——它们不能用 AUTO_INCREMENT，要用独立发号器（见坑 8）。

## 坑 2：5.7 重启后计数器重算——旧 ID 可能被"复活"复用

这是最隐蔽、最危险的一个坑。MySQL 5.7 中 AUTO_INCREMENT 计数器**只存在内存里**，实例重启后按 `MAX(id) + 1` 重新计算。

```sql
-- 重启前：插入 1~1000，然后删掉 id 最大的 100 行
DELETE FROM t_inc WHERE id > 900;
-- 当前计数器仍停在 1001（只增不减），新插入拿到 1001 —— 不复用，没问题

-- ↓↓↓ 此刻 MySQL 崩溃 / 正常重启 ↓↓↓

INSERT INTO t_inc(name) VALUES ('after-restart');
-- 5.7：拿到 id = 901！这个 ID 三天前属于一条已删除的订单
```

**危害链**：

```
旧订单 id=901 被删除
  → 风控日志、客服工单、第三方 ERP、数据仓库里仍引用 901
  → 重启后新订单拿到 901
  → 所有历史引用全部"指鹿为马"，对账错乱、审计无法追溯
```

| 版本 | 计数器存储 | 重启行为 |
|------|-----------|---------|
| MySQL 5.7 | 仅内存 | 重算为 `MAX(id)+1`，间隙消失，**曾删除的大 ID 会被复用** |
| MySQL 8.0 | 持久化到 redo log | 重启后计数器原样恢复，不复用 |

**对策**：这是升级 8.0 的硬理由之一；留在 5.7 则要约定"删除只做软删除 / 归档永不复用主键"，并避免依赖 ID 做跨系统引用。

## 坑 3：INT 耗尽——写入整条链路中断

```
ERROR 1467 (HY000): Failed to read auto-increment value from storage engine
```

| 主键类型 | 上限 | 按 1000 ID/秒 可用 |
|---------|------|-------------------|
| `INT` | 21.5 亿 | ~25 天（高并发），实际通常 2-3 年 |
| `INT UNSIGNED` | 42.9 亿 | 通常 4-5 年 |
| `BIGINT` | 9.2 × 10¹⁸ | 约 29 万年 |

注意：**跳号会加速耗尽**——实际行数可能只有 5000 万，计数器却已逼近 21 亿。耗尽后再 `ALTER INT → BIGINT`，亿级表锁表数小时。

**水位监控（所有自增表一次查清，建议配定时告警）**：

```sql
SELECT TABLE_SCHEMA, TABLE_NAME, AUTO_INCREMENT,
       CASE COLUMN_TYPE
         WHEN 'int'           THEN 2147483647
         WHEN 'int unsigned'  THEN 4294967295
         WHEN 'bigint'        THEN 9223372036854775807
         WHEN 'bigint unsigned' THEN 18446744073709551615
       END AS max_val,
       ROUND(AUTO_INCREMENT /
         CASE COLUMN_TYPE
           WHEN 'int'           THEN 2147483647
           WHEN 'int unsigned'  THEN 4294967295
           WHEN 'bigint'        THEN 9223372036854775807
           WHEN 'bigint unsigned' THEN 18446744073709551615
         END * 100, 2) AS used_pct
FROM information_schema.TABLES t
JOIN information_schema.COLUMNS c
  USING (TABLE_SCHEMA, TABLE_NAME)
WHERE EXTRA LIKE '%auto_increment%'
  AND AUTO_INCREMENT IS NOT NULL
ORDER BY used_pct DESC;
-- 水位 > 70% 报警，留足在线迁移（pt-osc / gh-ost）时间
```

## 坑 4：计数器只增不减——删数据不回缩，ALTER 也不能往小调

```sql
INSERT INTO t_inc(name) VALUES ('x'), ('y'), ('z');   -- 1,2,3
DELETE FROM t_inc WHERE id = 3;                        -- 删掉最大行

-- 1) 删除不回缩：下一个 ID 仍是 4，不是 3
INSERT INTO t_inc(name) VALUES ('new');                -- id=4

-- 2) 显式插入大 ID 会把计数器"顶"上去
INSERT INTO t_inc(id, name) VALUES (10000, 'big');
INSERT INTO t_inc(name) VALUES ('next');               -- id=10001

-- 3) 试图用 ALTER 往小调：指定值 <= MAX(id)+1 时不生效（不报错，静默忽略）
ALTER TABLE t_inc AUTO_INCREMENT = 10;                 -- 无效，计数器仍是 10002

-- 4) 清空全表：DELETE 与 TRUNCATE 行为不同
DELETE FROM t_inc;        -- 8.0：计数器保留（5.7：不重启保留，重启后重算为 1）
TRUNCATE TABLE t_inc;     -- 所有版本：计数器立即重置
```

| 操作 | AUTO_INCREMENT 表现 |
|------|--------------------|
| DELETE 部分行（含最大行） | 不回缩 |
| 显式插入指定 ID | 计数器至少前进到 `该 ID + 1` |
| `ALTER TABLE ... AUTO_INCREMENT=n` | n 必须大于当前 `MAX(id)`，否则不生效 |
| `DELETE` 全表 | 8.0 保留；5.7 重启后重算 |
| `TRUNCATE` | 立即归零重建 |

## 坑 5：自增锁——并发吞吐与 STATEMENT 复制的对撞

`innodb_autoinc_lock_mode` 决定批量插入如何取号：

| 模式 | 锁 | 批量插入 | 并发性 | 使用条件 |
|------|-----|---------|--------|---------|
| 0 traditional | 表级 AUTO-INC 锁持到语句结束 | 串行 | 最差 | — |
| 1 consecutive（**5.7 默认**） | 语句级表锁，预分配连续段 | 连续 | 中 | — |
| 2 interleaved（**8.0 默认**） | 无表锁，mutex 取单个值 | 可交错 | **最好** | 必须 **ROW 格式 binlog** |

**陷阱**：模式 2 下并发事务交错取号，同一条 `INSERT ... SELECT` 产生的 ID 在主库不连续；如果 binlog 是 STATEMENT 格式，从库重放时另起一套编号，**主从 ID 对不上**，复制数据直接错乱。

```sql
SHOW VARIABLES LIKE 'binlog_format';          -- 必须是 ROW，才能安全用模式 2
SHOW VARIABLES LIKE 'innodb_autoinc_lock_mode';
```

注意 8.0.13 之前该变量只读，需写 `my.cnf` 重启；8.0 默认 ROW + 模式 2，开箱即安全。

## 坑 6：自增列的建表约束（小坑，但会现场打脸）

```sql
-- 1) 自增列必须是整数类型，且必须是某个索引的第一列
CREATE TABLE t_bad (id BIGINT AUTO_INCREMENT, name VARCHAR(20));
-- ERROR 1075: Incorrect table definition; there can be only one auto column
--              and it must be defined as a key

-- 正确：主键 / 唯一键 / 普通索引均可
CREATE TABLE t_ok (id BIGINT NOT NULL AUTO_INCREMENT, name VARCHAR(20), PRIMARY KEY(id));

-- 2) 一张表只能有一个 AUTO_INCREMENT 列
-- 3) 自增列不建议加 UNSIGNED 以外的"省空间"组合：直接 BIGINT，一步到位
```

## 坑 7：自增 ID 当对外编号——信息泄露与遍历拖库

把自增 ID 直接暴露给用户（URL、订单号、客服报号），等于同时交出三张底牌：

| 风险 | 表现 |
|------|------|
| 暴露业务规模 | 竞品注册一个账号看 ID，就知道你日增多少订单、总用户量 |
| 可枚举爬取 | `?orderId=10001` 逐一遍历，越权漏洞一扫就是全库；ID 连续使攻击成本极低 |
| 客户信任问题 | 用户看到订单号跳号、从 4 开始，质疑"是不是删过我数据"；合并/迁移后编号断档更明显 |
| 跨系统不可说 | 自增值受重启、迁移影响，无法保证对外编号规则稳定 |

**做法：内部主键与对外编号分离。**

```
内部:  id BIGINT（自增或雪花），只用于表关联和外键
对外:  order_no VARCHAR(32)，独立唯一索引，由发号规则生成
       例: RE(日期) + 渠道码 + 随机/哈希位 → RE20260923W8K2X3Q
```

## 坑 8：分库分表 / 分布式——自增失去全局意义

**MySQL 分片：靠两个变量错开编号**（本为多主复制设计）：

```sql
-- 2 个分片，步长 2，奇偶分配
-- 分片 1
SET GLOBAL auto_increment_offset = 1;
SET GLOBAL auto_increment_increment = 2;    -- 1,3,5,7...
-- 分片 2
SET GLOBAL auto_increment_offset = 2;
SET GLOBAL auto_increment_increment = 2;    -- 2,4,6,8...
```

两个隐患：① 配置错误（步长没对上）立刻产生**重复 ID**；② 2 分片扩到 4 分片时旧数据奇偶分布无法重排，新增节点的步长规划极其别扭。

**TiDB：AUTO_INCREMENT 由 TiDB Server 缓存 ID 段（默认 30000）**：

- 多实例各持一段，**跨实例不保证顺序**，实例重启整段丢弃产生大洞；
- 递增主键使所有写入落在最后一个 Region，**热点随 Region 分裂迁移但不消失**；
- 对策：只要唯一不要序 → `AUTO_RANDOM` 打散；要严格递增 → `CREATE SEQUENCE`（基于 PD TSO，CACHE 段重启仍会空洞，NO CACHE 才严格连续）。详见案例 100。

## 选型决策：三层 ID 方案

```
第 1 层 · 内部主键（表关联用）
├── 单库单表：BIGINT AUTO_INCREMENT（8.0 默认配置即可，别用 INT）
└── 分库分表 / 多实例高并发：雪花算法 或 号段模式（Leaf / UidGenerator）
                             TiDB 可选 AUTO_RANDOM

第 2 层 · 对外业务编号（订单号/工单号）
└── 独立列 + 唯一索引，发号器生成（日期 + 业务码 + 随机位），不复用自增 ID

第 3 层 · 严格连续流水号（发票号、会计凭证号）
├── MySQL：独立序列表（一行一更新，配合重试；或号段模式分配连续区间）
└── TiDB：CREATE SEQUENCE ... NO CACHE
```

| 需求组合 | 推荐 |
|---------|------|
| 唯一 + 顺序插入 + 单机 | BIGINT AUTO_INCREMENT |
| 唯一 + 高并发分布式 + 不依赖排序 | 雪花 / 号段；TiDB AUTO_RANDOM |
| 全局严格递增 | TiDB Sequence；MySQL 用序列表 / 中心化发号器 |
| 对外展示、不可枚举 | 专用业务编号，与主键物理分离 |

<ExplainCompare
  :bad="{ 主键类型: 'INT', 重启行为: '5.7 可能复用旧 ID', 编号连续性: '回滚即空洞', 分布式: '分片易冲突', 对外暴露: '可枚举拖库' }"
  :good="{ 主键类型: 'BIGINT', 重启行为: '8.0 持久化不复用', 编号连续性: '只保证唯一(业务可接受)', 分布式: '雪花/号段/AUTO_RANDOM', 对外暴露: '专用业务编号隔离' }"
  improvement="从五处隐患（耗尽、复用、锁争用、冲突、泄露）到分层设计一次消除"
/>

## 避坑清单（可直接落地）

::: warning 建表与运维规范

1. **新表主键一律 `BIGINT NOT NULL AUTO_INCREMENT`**，不使用 INT，不为省 4 字节赌未来。

2. **对外编号与主键分离**：主键不出现在 URL、客服话术、对账单中；业务编号带日期和随机位，加唯一索引。

3. **要求严格连续的序列号不使用自增**，走独立发号器，并在应用层做重复重试。

4. **8.0 + ROW binlog 保持默认锁模式 2**；5.7 若坚持 STATEMENT binlog，锁模式只能用 0/1。

5. **监控自增水位**：坑 3 的 SQL 接入定时任务，70% 告警；同时关注计数器增速与实际行数的差值（跳号速率）。

6. **删除策略**：重要数据只软删除或归档，不物理删除大 ID 行，尤其是还在 5.7 上时。

7. **分库分表先定 ID 方案再切**：优先用雪花/号段，把 auto_increment_offset 方案当作退路；配置后立刻在两个分片各插一行验证奇偶。

8. **跨系统引用主键要评估重启语义**：5.7 升级或迁移前，排查日志、数仓、第三方系统中存量 ID 引用。
:::

## 5.7 vs 8.0 差异速查

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| 计数器持久化 | ❌ 内存，重启重算 | ✅ redo log |
| 重启后复用已删 ID | **可能** | 不会 |
| 默认锁模式 | 1 consecutive | 2 interleaved |
| 默认 binlog 格式 | STATEMENT/MIXED（随安装） | ROW |
| 锁模式会话级动态设置 | ❌（8.0.13 前整体只读） | ✅ |

## 本地复现

本篇为纯 SQL 行为验证，直接进入容器客户端执行：

```bash
# 进入 MySQL 8.0 客户端
docker exec -it sql-treasure-mysql80 mysql -uroot -proot sql_treasure

# 依次验证：
# 1) 回滚跳号（坑 1）
CREATE TABLE t_inc_demo (id BIGINT NOT NULL AUTO_INCREMENT, name VARCHAR(20), PRIMARY KEY(id));
START TRANSACTION;
INSERT INTO t_inc_demo(name) VALUES ('a'),('b'),('c');
ROLLBACK;
INSERT INTO t_inc_demo(name) VALUES ('d');
SELECT * FROM t_inc_demo;                       -- 观察 id=4

# 2) 删除不回缩 + ALTER 不能调小（坑 4）
DELETE FROM t_inc_demo WHERE id = 4;
ALTER TABLE t_inc_demo AUTO_INCREMENT = 1;
SHOW CREATE TABLE t_inc_demo\G                 -- AUTO_INCREMENT 未被改小

# 3) 5.7 对照（端口 3307）：删掉最大行后重启容器，观察旧 ID 是否被复用（坑 2）
docker exec -it sql-treasure-mysql57 mysql -uroot -proot sql_treasure
```

::: tip 延伸阅读
- 案例 14：跳号的预分配机制与三种锁模式的并发量化
- 案例 61：INT 耗尽事故现场与雪花算法 64-bit 结构
- 案例 100：TiDB AUTO_INCREMENT / AUTO_RANDOM / Sequence 选型决策树
:::
