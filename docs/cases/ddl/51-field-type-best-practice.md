# 字段类型与长度选择最佳实践

<CaseMeta difficulty="⭐⭐" category="DDL" versions="5.7 & 8.0" :tags="['字段类型', 'VARCHAR', 'CHAR', 'TINYINT', 'DECIMAL', '表设计']" />

## 场景痛点

某团队在设计订单表时，字段类型随手选：状态用 `VARCHAR(20)` 存中文、金额用 `FLOAT`、手机号用 `VARCHAR(50)`、性别用 `VARCHAR(10)`、逻辑删除标记用 `VARCHAR(5)`。上线初期数据量小，一切正常。半年后表涨到 100 万行，问题集中爆发：

- 金额对账时 `WHERE amount = 99.90` 查不到数据，但页面上明明显示 99.90
- 状态字段索引体积异常大，buffer pool 被挤占，慢查询频发
- 手机号索引比预期大 2 倍多，写入越来越慢

```sql
-- 看似没问题的查询，实际查不到数据
SELECT * FROM t_type_bad WHERE amount = 99.90;
-- 返回 0 行！FLOAT 存的 99.90 实际是 99.9000015258789
```

问题根源不是查询写得差，而是**表设计阶段字段类型选错了**。类型选错会导致存储浪费、索引膨胀、查询变慢，甚至精度失效，且后期修改代价大（参见案例 49 的 MODIFY COLUMN 锁表风险）。

::: warning 真实场景
"建表时随手选 VARCHAR(255)、FLOAT、BIGINT"是最常见的设计债。数据量小时毫无感知，数据量大了存储、索引、精度问题集中暴露。更糟的是，事后改类型要面对 ALTER TABLE 的锁表风险（案例 49）。在表设计阶段就选对类型，是最有效、成本最低的优化。
:::

## 问题分析

### bad.sql

```sql
-- bad 表：类型选择随意
CREATE TABLE t_type_bad (
    id         BIGINT       NOT NULL AUTO_INCREMENT,  -- 小表用 BIGINT 浪费 4 字节
    status     VARCHAR(20)  NOT NULL DEFAULT '待支付', -- 枚举用 VARCHAR，索引 key_len=82
    gender     VARCHAR(10)  NOT NULL DEFAULT '未知',   -- 性别用 VARCHAR，存中文字符串
    phone      VARCHAR(50)  NOT NULL DEFAULT '',       -- 手机号 11 位却用 VARCHAR(50)，key_len=202
    amount     FLOAT        NOT NULL DEFAULT 0,        -- 金额用 FLOAT，99.90 存为 99.9000015
    remark     VARCHAR(1000) DEFAULT NULL,             -- 大部分为空但定义过长
    is_deleted VARCHAR(5)   NOT NULL DEFAULT 'false',  -- 布尔值用字符串
    ...
);

-- 查询 1: status 用 VARCHAR，字符串比较比整数慢
SELECT * FROM t_type_bad WHERE status = '已支付';

-- 查询 2: amount 用 FLOAT，精度问题导致查不到
SELECT * FROM t_type_bad WHERE amount = 99.90;  -- 返回 0 行!

-- 查询 3: phone VARCHAR(50) 索引比 VARCHAR(20) 大很多
SELECT * FROM t_type_bad WHERE phone = '13800138000';
```

### EXPLAIN 结果（查询 1：status 索引）

```
+----+-------------+------------+------+---------------+------------+---------+-------+--------+----------+-------+
| id | select_type | table      | type | possible_keys | key        | key_len | ref   | rows   | filtered | Extra |
+----+-------------+------------+------+---------------+------------+---------+-------+--------+----------+-------+
|  1 | SIMPLE      | t_type_bad | ref  | idx_status    | idx_status | 82      | const |  20000 |   100.00 | NULL  |
+----+-------------+------------+------+---------------+------------+---------+-------+--------+----------+-------+
```

| 字段 | 值 | 分析 |
|------|-----|------|
| type | `ref` | 等值匹配索引 |
| key | `idx_status` | status 列索引 |
| key_len | **`82`** | **VARCHAR(20) utf8mb4 = 20×4+2 = 82 字节** |
| rows | ~20000 | 命中约 1/5 数据 |

### 三个核心问题逐一分析

**问题 1：VARCHAR status 的字符串比较代价**

`status VARCHAR(20)` 存中文状态值（'待支付'、'已支付'…），在 utf8mb4 下：

1. **索引 key_len = 82 字节**：是 TINYINT（1 字节）的 82 倍，索引体积大
2. **字符串比较慢**：需逐字节比对字符编码，整数比较是 CPU 单条指令
3. **存储浪费**：'已支付' 占 12 字节，而 TINYINT 只占 1 字节
4. **扩展不友好**：新增状态需改字符串，中文字符串易因编码问题出错

**问题 2：FLOAT amount 的精度问题**

`amount FLOAT` 是 IEEE 754 单精度浮点数（4 字节），只能保证约 7 位有效数字：

1. **99.90 存为 99.9000015258789**：二进制无法精确表示十进制小数
2. **等值查询失效**：`WHERE amount = 99.90` 返回 0 行
3. **财务风险**：金额累加误差，对账时金额对不上

```
FLOAT 存储机制:
  99.90 -> 二进制浮点近似 -> 99.90000152587890625
  读取时显示截断为 99.9，但内部值并非精确的 99.90

DECIMAL 存储机制:
  99.90 -> 每两位存一个字节（BCD 编码）-> 精确存储 99.90
  读取返回精确的 99.90，无任何偏差
```

**问题 3：VARCHAR(50) phone 的索引膨胀**

`phone VARCHAR(50)` 实际手机号仅 11 位，定义过长直接膨胀索引：

1. **索引 key_len = 202 字节**：是 VARCHAR(20)（82 字节）的 2.5 倍
2. **索引体积膨胀**：10 万行索引多占约 60% 空间
3. **buffer pool 浪费**：大索引挤占缓存，热数据易被驱逐

### 表大小对比（10 万行数据）

| 表 | data_mb | index_mb | total_mb |
|----|---------|----------|----------|
| t_type_bad（随意选择） | ~14.5 | ~14.2 | ~28.7 |
| t_type_good（精心选择） | ~10.8 | ~10.5 | ~21.3 |

::: tip 核心认知
VARCHAR(N) 的索引按 N 计算最大 key_len（utf8mb4 下 N×4+2），而非实际存储长度。即使手机号只有 11 位，VARCHAR(50) 的索引仍按 50×4+2=202 字节计算。**类型选错的影响是乘数级的：行越多，浪费越大；索引越多，膨胀越严重。**
:::

## 优化方案

### good.sql

```sql
-- good 表：类型精心选择
CREATE TABLE t_type_good (
    id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,  -- 小表 INT UNSIGNED 足够
    status     TINYINT UNSIGNED NOT NULL DEFAULT 0,    -- 枚举用 TINYINT，key_len=1
    gender     CHAR(1)       NOT NULL DEFAULT 'U',     -- 定长单字符，省去长度前缀
    phone      VARCHAR(20)   NOT NULL DEFAULT '',       -- 按需定长，key_len=82
    amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00,    -- 金额精确到分
    remark     VARCHAR(500)  DEFAULT NULL,             -- 合理长度，NULL 不占行内空间
    is_deleted TINYINT(1)    NOT NULL DEFAULT 0,       -- 布尔值用 TINYINT
    ...
);

SELECT * FROM t_type_good WHERE status = 1;        -- 整数比较，key_len=1
SELECT * FROM t_type_good WHERE amount = 99.90;    -- DECIMAL 精确匹配，返回 100 行
SELECT * FROM t_type_good WHERE phone = '13800138000'; -- key_len=82
```

### 原理

每个类型选择的背后原理：

```
1. status: VARCHAR(20) -> TINYINT UNSIGNED
   - 索引 key_len: 82 -> 1（缩减 99%）
   - 比较: 逐字节字符串比较 -> CPU 单条整数指令
   - 存储: 12 字节(中文) -> 1 字节

2. amount: FLOAT -> DECIMAL(10,2)
   - 存储: 4 字节近似浮点 -> 5 字节精确十进制
   - 精度: 99.9000015... -> 99.90（精确）
   - 等值查询: 失败 -> 成功

3. phone: VARCHAR(50) -> VARCHAR(20)
   - 索引 key_len: 202 -> 82（缩减 59%）
   - 实际需要: 11 位手机号，VARCHAR(20) 足够

4. gender: VARCHAR(10) -> CHAR(1)
   - 存储: 变长+长度前缀 -> 定长 1 字节
   - 比较: 字符串比较 -> 单字节比较

5. is_deleted: VARCHAR(5) -> TINYINT(1)
   - 存储: 'false' 5 字节 -> 1 字节（节省 80%）

6. remark: VARCHAR(1000) -> VARCHAR(500)
   - 合理长度，NULL 值在行内仅占 NULL 标志位 1 bit
```

### 类型选择决策表

| 业务场景 | bad 选择 | good 选择 | 理由 |
|----------|----------|-----------|------|
| 订单状态（5 种枚举） | VARCHAR(20) | **TINYINT UNSIGNED** | 枚举值少，整数比较快，索引小 |
| 性别（男/女/未知） | VARCHAR(10) | **CHAR(1)** | 固定单字符，定长省空间 |
| 手机号（11 位） | VARCHAR(50) | **VARCHAR(20)** | 按需定长，索引 key_len 减半 |
| 金额（精确到分） | FLOAT | **DECIMAL(10,2)** | 精确存储，等值查询可靠 |
| 逻辑删除标记 | VARCHAR(5) | **TINYINT(1)** | 布尔值用整数，1 字节 |
| 备注（大部分为空） | VARCHAR(1000) | **VARCHAR(500)** | 合理长度，NULL 不占行内空间 |
| 小表主键 | BIGINT | **INT UNSIGNED** | 数据量小，INT 足够省 4 字节 |

### 对比

| 指标 | bad.sql（随意选择） | good.sql（精心选择） | 提升 |
|------|---------------------|---------------------|------|
| status key_len | 82 字节 | 1 字节 | **缩减 99%** |
| phone key_len | 202 字节 | 82 字节 | **缩减 59%** |
| 数据空间 | ~14.5 MB | ~10.8 MB | **节省 26%** |
| 索引空间 | ~14.2 MB | ~10.5 MB | **节省 26%** |
| 总空间 | ~28.7 MB | ~21.3 MB | **节省 26%** |
| amount=99.90 查询 | 0 行（失败） | 100 行（成功） | **精度修复** |

<ExplainCompare
  :bad="{ type: 'ref/ALL', key: 'idx_status(VARCHAR) / 全表扫(FLOAT)', rows: '20000 / 99642', Extra: 'key_len=82; amount=99.90 返回0行(精度失效)' }"
  :good="{ type: 'ref/ALL', key: 'idx_status(TINYINT) / 全表扫(DECIMAL)', rows: '20000 / 99642', Extra: 'key_len=1; amount=99.90 返回100行(精确匹配)' }"
  improvement="status 索引 key_len 从 82 降到 1（缩减 99%），phone 索引从 202 降到 82（缩减 59%），总存储节省 26%，金额等值查询从失效到精确命中"
/>

## 避坑指南

::: warning 注意事项

### 1. VARCHAR vs CHAR 怎么选

- **CHAR(N)**：定长，不足 N 位用空格填充，适合**长度固定**的字段（如性别 `CHAR(1)`、国家码 `CHAR(2)`、MD5 `CHAR(32)`）
- **VARCHAR(N)**：变长，按实际长度存储 + 1~2 字节长度前缀，适合**长度不固定**的字段（如手机号、邮箱、备注）
- **关键区别**：CHAR 的索引 key_len = N×4+2，VARCHAR 也是 N×4+2，但 CHAR 省去长度前缀且定长比较更快
- **CHAR 尾部空格**：5.7 和 8.0 默认 PAD SPACE（填充），检索时尾部空格会被处理，注意与预期的差异

### 2. INT 系列怎么选

| 类型 | 字节 | 范围 | 适用场景 |
|------|------|------|----------|
| TINYINT UNSIGNED | 1 | 0 ~ 255 | 状态、布尔、小枚举 |
| SMALLINT UNSIGNED | 2 | 0 ~ 65535 | 较小范围计数 |
| INT UNSIGNED | 4 | 0 ~ 42.9 亿 | 中等表主键、用户 ID |
| BIGINT | 8 | ±9.2×10¹⁸ | 大表主键、雪花 ID |

- **小表主键用 INT UNSIGNED**：数据量明确不会超 42 亿，比 BIGINT 省 4 字节/行
- **大表主键用 BIGINT**：避免 INT 耗尽（详见案例 61）
- **状态/布尔用 TINYINT**：不要用 INT 存 0/1，浪费 3 字节

### 3. DECIMAL vs FLOAT

- **DECIMAL(M,D)**：精确十进制存储，M 总位数（最大 65），D 小数位。金额、利率、比例**必须用 DECIMAL**
- **FLOAT**：4 字节单精度，约 7 位有效数字，有精度误差。仅用于科学计算、统计近似值
- **DOUBLE**：8 字节双精度，约 15 位有效数字，仍有精度误差
- **金额场景**：`DECIMAL(10,2)` 精确到分，`DECIMAL(19,4)` 精确到万分之一分（金融场景）

### 4. ENUM vs TINYINT 查找表

- **ENUM**：MySQL 内部用整数存储，查询时映射为字符串。优点是节省空间，缺点是**修改枚举值需要 ALTER TABLE**（5.7 可能锁表，8.0 部分操作 INSTANT）
- **TINYINT + 应用层映射**：数据库存整数编码，值含义在应用层/数据字典维护。修改枚举不需 DDL，但需文档维护映射关系
- **推荐**：状态频繁变化的业务用 TINYINT + 应用层映射；状态极少变化的用 ENUM
- **避免**：不要用 VARCHAR 存中文枚举值，既不是 ENUM 也不是 TINYINT，最差的选择

:::

::: tip VARCHAR 空值不占行内空间的特性
InnoDB 行格式（COMPACT/DYNAMIC）中，VARCHAR 列的 NULL 值**不存储长度前缀和数据**，仅在行头的 NULL 标志位占 1 bit。所以 `remark VARCHAR(500) DEFAULT NULL` 当值为 NULL 时几乎不占行内空间。这也是 VARCHAR 相对 CHAR 的核心优势之一：按实际长度存储，NULL 不浪费空间。但注意：把列改成 `NOT NULL DEFAULT ''` 会强制存空字符串，反而占空间。
:::

## 与相关案例的区别

| | 案例 51：字段类型选择 | 案例 49：MODIFY COLUMN 锁表 | 案例 61：INT 自增耗尽 | 案例 11：前缀索引 |
|---|---|---|---|---|
| 关注点 | 表设计阶段选对类型 | 事后改类型的锁行为 | 主键类型上限耗尽 | 长字符串索引体积 |
| 阶段 | **设计阶段**（预防） | 运维阶段（修复） | 运行多年后（事故） | 索引优化阶段 |
| 核心问题 | 存储浪费+精度失效+索引膨胀 | ALTER TABLE 锁表 | ID 达上限写入中断 | 全列索引 key_len 过大 |
| 本案例定位 | **源头预防**：选对类型避免后续所有问题 | 本案例的反面：选错后改的代价 | 主键类型选错的极端后果 | 字符串字段索引的通用优化 |

::: warning 与案例 49 的关系
案例 49 讲的是"选错类型后怎么改"（MODIFY COLUMN 的锁行为），本案例讲的是"怎么避免选错"（设计阶段选对类型）。**本案例是案例 49 的预防方案**--如果设计阶段就选对类型，就不需要冒着锁表风险去 MODIFY COLUMN。两者形成"预防-修复"的完整闭环。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| TINYINT/VARCHAR 索引 key_len | 一致 | 一致 |
| FLOAT 精度问题 | 一致（IEEE 754） | 一致 |
| DECIMAL 精度行为 | 精确 | 精确 |
| DECIMAL 内部存储 | 每位 4 bit + 符号 | 更紧凑（部分场景） |
| VARCHAR NULL 行内存储 | 不占空间 | 一致 |
| CHAR 尾部空格 | PAD SPACE | PAD SPACE（默认） |
| ENUM 修改 | 可能锁表 | 部分操作 INSTANT |

::: tip 两版核心一致
类型选择的核心原则在 5.7 和 8.0 完全一致：枚举用 TINYINT、金额用 DECIMAL、VARCHAR 按需定长。8.0 对 DECIMAL 的内部存储做了一些优化，对 ENUM 的修改操作支持 INSTANT（部分场景），但类型选择的决策原则不变。
:::

## 本地复现

```bash
# 默认在 MySQL 8.0 上运行
./scripts/run-case.sh 51-field-type-best-practice

# 在 MySQL 5.7 上运行（对比）
./scripts/run-case.sh 51-field-type-best-practice --ver 5.7

# 跳过造数据重跑
./scripts/run-case.sh 51-field-type-best-practice --no-seed
```

::: tip 复现要点
本案例重点观察三处差异：
1. **status 索引 key_len**：bad 表 82 字节 vs good 表 1 字节（EXPLAIN 对比）
2. **amount = 99.90 查询结果**：bad 表返回 0 行（FLOAT 精度失效）vs good 表返回 100 行（DECIMAL 精确）
3. **表存储大小**：`good.sql` 末尾的 `information_schema.TABLES` 查询对比两表的 data_mb / index_mb
:::
