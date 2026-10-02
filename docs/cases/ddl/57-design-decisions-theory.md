# 设计决策背后的理论依据：状态机、幂等、乐观锁到底解决什么问题

<CaseMeta difficulty="⭐⭐⭐" category="DDL 与大表" versions="5.7 & 8.0" :tags="['状态机', '幂等性', '乐观锁', '版本号', '去重键', '软删除', '设计原理']" />

## 每个字段背后都该有答案：从状态机讲清"是什么、解决什么、怎么实现"
建表评审时经常听到这样的对话："这里为什么要加 `version` 字段？""订单状态为什么不用几个布尔列？""支付回调凭什么重复推送也不会扣两次钱？"——如果答不上来，这些字段就是凭直觉抄来的。

本篇讲清数据模型中**每个关键设计节点背后的理论依据**。每个节点都用三个问题回答：**是什么（概念）→ 解决什么问题（动机）→ 具体怎么实现（落地）**。重点讲透状态机，再依次讲幂等性、乐观锁与版本号、去重唯一键、审计日志、软删除、枚举编码、时间戳和树形结构。

```
本文各节点的关系：

 状态机  ──┬── 迁移的原子性靠 ──→ 乐观锁/条件 UPDATE（防并发覆盖）
          ├── 事件重复触发靠 ──→ 幂等性 ──→ 去重唯一键（最终防线）
          └── 迁移要可追溯 ──→ 审计日志（状态事件表）
 软删除    ── 本质是给"删除"这个动作建一个状态
 枚举/时间戳 ── 状态机的状态编码与事件时间载体
```

## 一、状态机（核心）

### 1.1 是什么

**有限状态机（Finite State Machine, FSM）** 是一个数学模型，用四要素描述一个对象的生命周期：

| 要素 | 含义 | 订单例子 |
|------|------|---------|
| 状态 State | 对象在某一时刻所处的**唯一**状况 | 待支付、已支付、已发货、已完成、已取消 |
| 事件 Event | 触发状态变化的外部动作 | 用户支付、商家发货、用户确认、超时取消 |
| 迁移 Transition | 从某状态经某事件到另一状态的**合法规则** | 待支付 --支付--> 已支付 |
| 动作 Action | 迁移时执行的副作用 | 扣库存、发通知、记流水 |

关键性质：**一个对象同一时刻只有一个状态；不是任意两个状态之间都能迁移**。合法迁移画成图就是状态流转图：

```
                 支付成功                发货              确认收货
   ┌────────┐ ──────────► ┌────────┐ ──────────► ┌────────┐ ──────────► ┌────────┐
   │ 待支付 │             │ 已支付 │             │ 已发货 │             │ 已完成 │
   └────────┘             └────────┘             └────────┘             └────────┘
       │ 支付成功              │
       │ 超时/主动取消          │ 退款
       ▼                       ▼
   ┌────────┐             ┌────────┐
   │ 已取消 │             │ 已退款 │
   └────────┘             └────────┘

   非法迁移举例：待支付 ──发货──✗（没付钱不能发货）
               已完成 ──支付──✗（不能重复支付）
               已取消 ──发货──✗
```

### 1.2 解决什么问题

不用状态机、只用一堆布尔标志或允许任意改 status 的系统，会出现四类问题：

| 问题 | 具体表现 |
|------|---------|
| **非法状态组合** | 用 `is_paid=1, is_shipped=0, is_cancelled=1` 多列描述，出现"已支付且已取消且未发货"这种现实中不存在的组合，且无法穷举校验 |
| **非法迁移** | 代码各处直接 `SET status=X`，没有"从什么状态才能改"的校验；重复回调把已发货订单又改回已支付 |
| **并发覆盖** | 支付成功回调和超时取消任务同时执行，两个 UPDATE 后状态取决于谁后到，订单可能"取消了但钱扣了" |
| **不可追溯** | 只存当前状态，不知道何时、被谁、因什么事件改的，客诉和对账无法复盘 |

状态机把"状态"收敛成**单列单值**，把"能不能改"收敛成**显式迁移规则**，把"并发竞争"交给条件更新，把"历史"交给事件表——四个问题逐一对应解决。

### 1.3 怎么实现

**第一步：单个状态列，不用布尔组合。**

```sql
CREATE TABLE t_order (
    id          BIGINT   NOT NULL AUTO_INCREMENT,
    order_no    VARCHAR(32) NOT NULL,
    status      TINYINT  NOT NULL DEFAULT 0
                COMMENT '状态：0待支付 1已支付 2已发货 3已完成 4已取消 5已退款',
    -- 关键：不要用 is_paid/is_shipped/is_cancelled 多列
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单主表';
```

**第二步：迁移规则下沉到"条件 UPDATE"——这是状态机最核心的实现。**

```sql
-- 事件"用户支付成功"：只允许从 待支付(0) 迁移到 已支付(1)
UPDATE t_order
SET status = 1, updated_at = NOW()
WHERE id = 1001
  AND status = 0;            -- ★ 迁移前置条件：当前必须是待支付
-- affected_rows = 1：迁移成功
-- affected_rows = 0：当前状态不是待支付（已取消/已支付），迁移被拒绝
```

把"合法源状态集合"写进 WHERE，就是把状态流转图变成了代码。各事件对应写法：

```sql
-- 事件"商家发货"：已支付(1) → 已发货(2)
UPDATE t_order SET status = 2 WHERE id = 1001 AND status = 1;

-- 事件"确认收货"：已发货(2) → 已完成(3)
UPDATE t_order SET status = 3 WHERE id = 1001 AND status = 2;

-- 事件"超时取消"：待支付(0) → 已取消(4)
UPDATE t_order SET status = 4 WHERE id = 1001 AND status = 0;

-- 一笔订单需要经过多个前置状态时，用 IN 列出所有合法源状态
UPDATE t_order SET status = 5 /*已退款*/
WHERE id = 1001 AND status IN (1, 2);   -- 已支付或已发货才可退款
```

**第三步：应用层按 affected_rows 判定结果并处理副作用。**

```
执行条件 UPDATE
├── affected_rows = 1 → 迁移成功 → 执行动作（扣库存/发 MQ/写事件表）
└── affected_rows = 0 → 迁移被拒 → 查询当前 status，区分原因：
                          · 已在目标状态（重复事件）→ 幂等返回成功，见第二节
                          · 在其他状态（非法操作）  → 返回业务错误
```

::: tip 条件 UPDATE 为什么能防并发
支付回调和超时取消并发时，两条语句都带 `AND status=0`。InnoDB 行锁让它们串行执行：第一个提交后 status 变为 1（或 4），第二个的 `status=0` 不再成立，affected_rows=0 自动失败。**不需要额外加版本字段、不需要 `SELECT ... FOR UPDATE`，状态本身就是乐观锁标记。** 这也是状态机与第三节乐观锁的衔接点。
:::

**第四步：状态迁移事件表，解决可追溯。**

```sql
CREATE TABLE t_order_event (
    id          BIGINT   NOT NULL AUTO_INCREMENT,
    order_id    BIGINT   NOT NULL COMMENT '订单 ID',
    event       VARCHAR(30) NOT NULL COMMENT '事件：PAID/SHIPPED/CONFIRMED/CANCELLED/REFUNDED',
    from_status TINYINT  NOT NULL COMMENT '迁移前状态',
    to_status   TINYINT  NOT NULL COMMENT '迁移后状态',
    operator    VARCHAR(64) COMMENT '触发者：用户ID/系统任务/第三方回调',
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '事件发生时间',
    PRIMARY KEY (id),
    KEY idx_order (order_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单状态迁移事件流';
```

事件表只追加不修改，订单完整生命周期可按时间重放。迁移主表与写事件表应放在**同一个事务**里，保证"状态变了但没留痕"不会发生。

### 1.4 常见实现陷阱

| 陷阱 | 后果 | 正确做法 |
|------|------|---------|
| 迁移规则只写在应用代码，SQL 不带前置状态 | 绕过服务的脚本/老版本服务可制造非法状态 | 条件 UPDATE 作为数据库层最终防线 |
| 用 `UPDATE ... WHERE id=?` 然后代码里 if 判断 | "读-判断-写"三步在并发下有窗口期，两个事务都能通过判断 | 条件 UPDATE 一步原子完成 |
| 多个布尔列表示状态 | 组合爆炸，无法表达"状态只能向前" | 单列状态机 |
| 状态编码增改不更新注释和文档 | 后人不知 5 是什么 | 编码映射写进列注释 + 维护字典/枚举类 |
| 终态之后还允许任意事件 | 已完成订单被重复退款 | 流转图明确终态，WHERE 限定源状态 |

## 二、幂等性

### 2.1 是什么

**幂等（Idempotence）**：同一个操作执行一次和执行多次，产生的结果相同。数学表达是 `f(f(x)) = f(x)`。

| 操作 | 是否天然幂等 | 原因 |
|------|-------------|------|
| `UPDATE t SET status=1 WHERE id=10` | ✅ | 重复执行结果仍是 status=1 |
| `DELETE FROM t WHERE id=10` | ✅ | 第二次删除 0 行，结果相同 |
| `INSERT INTO t ...`（无唯一约束） | ❌ | 每次新增一条 |
| `UPDATE t SET balance=balance-100 WHERE id=1` | ❌ | 每执行一次扣一次钱 |

### 2.2 解决什么问题

分布式系统中"重复执行"是常态而非异常：网络超时后客户端重试、消息队列至少投递一次（at-least-once）导致消息重复消费、第三方支付回调可能推送 N 次。没有幂等保护，重复支付回调会**重复扣款 / 重复发货 / 重复加积分**。

### 2.3 怎么实现

**方案 1：业务唯一键（最简单、最强）** —— 给每个操作一个唯一编号，靠唯一索引兜底。

```sql
CREATE TABLE t_pay_record (
    id           BIGINT NOT NULL AUTO_INCREMENT,
    order_id     BIGINT NOT NULL,
    callback_no  VARCHAR(64) NOT NULL COMMENT '支付平台回调流水号（同一回调重复推送时相同）',
    amount       DECIMAL(10,2) NOT NULL,
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_callback (callback_no)   -- ★ 重复回调第二次插入直接冲突
);

-- 处理回调：先落流水，冲突即说明已处理
INSERT INTO t_pay_record(order_id, callback_no, amount)
VALUES (1001, 'WX20260924001', 99.00);
-- ERROR 1062 Duplicate entry → 捕获后直接返回"已处理成功"，不再执行后续状态迁移
```

**方案 2：幂等令牌表（通用去重，适合无法用业务键的场景）**

```sql
CREATE TABLE t_idempotent (
    request_id  VARCHAR(64) NOT NULL COMMENT '客户端为每次业务请求生成的唯一令牌',
    response    TEXT COMMENT '首次处理结果，可选',
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (request_id)
);
-- 处理流程：INSERT(request_id) → 1062 说明处理过，直接返回首次结果；插入成功才执行业务
```

**方案 3：状态机天然幂等** —— 重复"支付成功"事件执行 `SET status=1 WHERE id=? AND status=0`：第一次迁移成功，第二次 affected_rows=0。再查一次发现已经是目标状态，按"重复事件"返回成功即可（见 1.3 第三步）。状态机 + 去重键是生产上的标准组合：**唯一键挡住重复落账，条件更新挡住重复迁移**。

## 三、乐观锁与版本号

### 3.1 是什么

- **悲观锁**：假设冲突一定会发生，操作前先加锁（`SELECT ... FOR UPDATE`），其他人阻塞等待。
- **乐观锁**：假设冲突很少发生，不加锁，更新时检查"我读到的数据有没有被别人改过"，被改过就失败重试。版本号是乐观锁最常见的实现载体。

### 3.2 解决什么问题

两个请求同时读到同一条记录、各自修改后写回，后写的会**覆盖**先写的结果（丢失更新 Lost Update）。悲观锁用阻塞换取正确，高并发下锁等待严重、容易死锁；乐观锁在冲突少时几乎零阻塞。

### 3.3 怎么实现

```sql
CREATE TABLE t_account (
    id        BIGINT NOT NULL,
    balance   DECIMAL(12,2) NOT NULL,
    version   INT    NOT NULL DEFAULT 0 COMMENT '乐观锁版本号',
    PRIMARY KEY (id)
);

-- 1) 读出数据和版本号
SELECT balance, version FROM t_account WHERE id = 1;
-- balance=1000, version=5

-- 2) 更新时带上读到的版本号，同时把版本号 +1
UPDATE t_account
SET balance = balance - 100,
    version = version + 1
WHERE id = 1
  AND version = 5;          -- ★ 版本没变才更新
-- affected_rows = 1：成功；= 0：已被别人改过，重新读最新值重试
```

**CAS（Compare-And-Swap）语义**：更新成功的充要条件是"版本号仍是我读到的那个"。应用层重试模式：

```
最多重试 3 次：
  读(balance, version) → 条件 UPDATE
    ├── 成功 → 返回
    └── 0 行 → 说明有并发修改，回到第一步重读（必要时提示"数据已变更"）
```

**与状态机的关系**：`SET status=? WHERE id=? AND status=?` 本质就是**以状态本身当版本号的乐观锁**，不必再额外加 version。只有当"迁移后的状态可能与源状态相同"或需要对任意字段做并发保护时，才需要独立 version 字段。

| 选择 | 适用场景 |
|------|---------|
| 悲观锁 FOR UPDATE | 冲突频繁、持锁期间要做多步操作且必须强一致（如跨行转账） |
| 乐观锁 version | 冲突少、读多写少、要求高吞吐（如后台编辑、库存扣减的多数场景） |
| 状态条件更新 | 状态迁移类操作（首选，零额外字段） |

## 四、去重唯一键

### 4.1 是什么 / 解决什么问题

**唯一约束（UNIQUE）** 是数据库对"某列（或列组合）不许重复"的强制保证。它解决的是应用层"先查有没有、没有再插入"在并发下失效的问题：两个事务都查到"没有"，于是都插入，产生重复数据。唯一索引是**数据库层不可绕过的最终防线**。

### 4.2 怎么实现

```sql
-- 业务自然键：对外订单号
UNIQUE KEY uk_order_no (order_no)

-- 操作键：外部回调流水（幂等用，见第二节）
UNIQUE KEY uk_callback_no (callback_no)

-- 组合键：同一用户不能重复参加某活动
UNIQUE KEY uk_user_activity (user_id, activity_id)

-- 插入并发冲突时捕获 1062，而不是先 SELECT 再 INSERT
INSERT INTO t_activity_user(user_id, activity_id) VALUES (88, 5);
-- ERROR 1062 → 已参加，返回友好提示
```

经验：**凡是业务上"唯一"的东西，都要在库里落唯一索引**，哪怕服务层已经做了校验——应用校验挡不住并发，唯一索引可以。

## 五、版本号与审计日志

### 5.1 是什么 / 解决什么问题

**审计（Audit）** 回答"这条数据什么时候、被谁、改成了什么"。它解决三类问题：安全合规要求留痕、客诉/对账时需要还原现场、误操作后要追溯和恢复。审计和第三节的 version 是一体两面：version 解决并发，审计解决追溯。

### 5.2 怎么实现

**轻量：行内审计四件套**

```sql
created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
created_by  BIGINT   COMMENT '创建人',
updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
updated_by  BIGINT   COMMENT '最后修改人'
```

**完整：事件溯源式日志（只追加）** —— 状态机的 `t_order_event` 就是一种领域审计；通用做法再记变更前后快照：

```sql
CREATE TABLE t_audit_log (
    id         BIGINT NOT NULL AUTO_INCREMENT,
    table_name VARCHAR(50) NOT NULL,
    row_id     BIGINT NOT NULL,
    action     VARCHAR(20) NOT NULL COMMENT 'INSERT/UPDATE/DELETE',
    old_value  JSON COMMENT '变更前',
    new_value  JSON COMMENT '变更后',
    operator   VARCHAR(64),
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_row (table_name, row_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

只追加、不修改、不删除；重要业务用数据库触发器或应用切面统一写入，避免靠开发者自觉而漏记。

## 六、软删除

### 6.1 是什么 / 解决什么问题

**软删除（Soft Delete）** ：不执行物理 `DELETE`，而是用一个标记把行置为"已删除"。它解决：误删可恢复、需要保留历史留痕、物理删除大字段/索引代价高。可以把它理解为**给"删除"这个动作专门建的一个状态**——它同样是状态机思想的延伸。

### 6.2 怎么实现

```sql
-- 推荐：deleted_at 时间戳（NULL=未删除，非 NULL=删除于何时）
ALTER TABLE t_order ADD COLUMN deleted_at DATETIME DEFAULT NULL;

UPDATE t_order SET deleted_at = NOW() WHERE id = 1001;   -- "删除"
SELECT * FROM t_order WHERE deleted_at IS NULL;          -- 所有正常查询都要带这个条件
```

| 方案 | 取舍 |
|------|------|
| `is_deleted TINYINT` | 只知删没删，不知何时 |
| `deleted_at DATETIME`（推荐） | 同时记录删除时间，便于按时间归档 |

**两个必须处理的坑：**

1. **所有查询都要带 `deleted_at IS NULL`**，漏带就会把已删数据查出来；通常由 ORM 全局作用域统一注入。
2. **唯一索引与软删除冲突**：用户软删一条 `user_name='Tom'` 后无法再新建 Tom（唯一索引仍把旧行算进去）。解法：删除时把唯一列改为带删除标记的值（如 `Tom#deleted_<id>`），或用生成列组合唯一索引：
   ```sql
   active_key VARCHAR(64) GENERATED ALWAYS AS
       (IF(deleted_at IS NULL, user_name, NULL)) STORED,
   UNIQUE KEY uk_active_name (active_key)   -- 软删行 active_key 为 NULL，不参与唯一限制
   ```

软删数据长期堆积会拖慢查询、占用空间，要配合定期归档（软删超过 N 天的行移到归档表后物理删除）。是否软删的取舍详见案例65。

## 七、枚举编码与查找表

**是什么**：把有限的离散取值（状态、类型、渠道）用整数编码存储，含义由应用枚举类或字典查找表维护。
**解决什么问题**：相比 VARCHAR 存中文，整数比较快、索引小（TINYINT 的 key_len=1，VARCHAR(20) 为 82）、避免写错同音字/错别字；相比 ENUM，改取值不需要 `ALTER TABLE`。
**怎么实现**：

```sql
channel TINYINT NOT NULL DEFAULT 0
  COMMENT '渠道：0未知 1web 2App 3小程序 4H5'

-- 需要在库内关联可读时用查找表
CREATE TABLE t_dict_channel(code TINYINT PRIMARY KEY, name VARCHAR(20));
INSERT INTO t_dict_channel VALUES (0,'未知'),(1,'web'),(2,'App'),(3,'小程序'),(4,'H5');
```

落地三件事：列注释写全编码映射、代码侧用枚举类集中定义、新增编码走评审并同步文档。完整类型对比见案例55。

## 八、时间戳字段

**是什么 / 解决什么问题**：时间戳记录"何时发生"，是排序、有效期判断、统计聚合、分区裁剪、归档分片的共同依据。
**怎么实现（每个时间承载不同语义，不要混用）**：

| 字段 | 语义 |
|------|------|
| `created_at` | 记录创建时间，永不修改 |
| `updated_at` | 最后修改时间，`ON UPDATE` 自动维护 |
| `paid_at / shipped_at / closed_at` | **业务事件时间**，由状态机迁移时写入，是状态机事件的物理载体 |

```
DATETIME：存"字面值"、不随时区转换，范围大（到 9999 年）——业务时间首选
TIMESTAMP：存 UTC、随时区转换，受 2038 限制——只用于需要绝对时刻的场景
```

业务事件时间建议在迁移条件 UPDATE 中一并写入，保证状态与时间一致：

```sql
UPDATE t_order SET status = 1, paid_at = NOW()
WHERE id = 1001 AND status = 0;
```

时区与格式的完整坑见案例32、31。

## 九、树形结构节点

**是什么**：表达层级归属（组织架构、商品分类、评论盖楼）。三种经典模型：

| 模型 | 结构 | 优点 | 缺点 |
|------|------|------|------|
| 邻接表 | `parent_id` 指向父节点 | 增删改简单 | 查整棵子树要递归 |
| 路径枚举 | `path='/1/5/12/'` | 查前缀方便 | 节点移动代价大 |
| 闭包表 | 单独关系表存所有祖先-后代对 | 任意层级查询快 | 维护成本、冗余多 |

**解决什么问题 / 怎么实现**：MySQL 8.0 用邻接表 + 递归 CTE 即可兼顾简单与查询：

```sql
CREATE TABLE t_org (id BIGINT PRIMARY KEY, parent_id BIGINT, name VARCHAR(50));

WITH RECURSIVE org_tree AS (
    SELECT id, parent_id, name, 1 AS lvl FROM t_org WHERE id = 1   -- 根
    UNION ALL
    SELECT c.id, c.parent_id, c.name, p.lvl + 1
    FROM t_org c JOIN org_tree p ON c.parent_id = p.id
)
SELECT * FROM org_tree;       -- 一次查出所有下属及层级
```

递归 CTE 实战见案例88、101；路径枚举适合需要快速判断"是否在某路径下"的场景（如权限范围）。

## 十、决策—理论—实现总表

| 设计节点 | 理论依据 | 解决的核心问题 | 关键实现 |
|---------|---------|--------------|---------|
| 状态机 | 有限状态机 FSM | 非法状态/非法迁移/并发覆盖/不可追溯 | 单列状态 + 条件 UPDATE + 事件表 |
| 幂等性 | `f(f(x))=f(x)` | 重试、重复消息、重复回调 | 唯一键 / 令牌表 / 状态机 |
| 乐观锁 | CAS 比较并交换 | 丢失更新，避免锁阻塞 | `version` 条件更新并重试 |
| 去重唯一键 | 实体完整性 | 并发"先查后插"失效 | UNIQUE 索引 + 捕获 1062 |
| 审计日志 | 只追加事件流 | 留痕、复盘、恢复 | 审计四件套 / 事件表 |
| 软删除 | 删除即状态 | 可恢复、保留历史 | `deleted_at` + 唯一键处理 |
| 枚举编码 | 编码与表示分离 | 索引膨胀、取值非法 | TINYINT + 查找表 |
| 时间戳 | 事件时间建模 | 排序/统计/分区依据 | created/updated/事件时间 |
| 树形节点 | 图/层级模型 | 归属与子树查询 | 邻接表 + 递归 CTE |

<ExplainCompare
  :bad="{ 状态表示: '多布尔列,组合非法', 迁移控制: '读-判断-写,并发有窗口', 重复事件: '重复扣款发货', 历史: '只存当前值,无法复盘' }"
  :good="{ 状态表示: '单列状态机', 迁移控制: '条件 UPDATE 原子 CAS', 重复事件: '唯一键+幂等返回', 历史: '事件表只追加可重放' }"
  improvement="把四个隐性故障（非法组合、丢失更新、重复执行、无追溯）分别交给四个有理论依据的节点解决"
/>

## 落地清单

::: tip 设计一个"有生命周期"的对象时逐项确认
- [ ] 画出状态流转图：列出全部状态、事件、合法迁移、终态
- [ ] 状态用单列 TINYINT，编码映射写进注释；不用布尔组合
- [ ] 每个事件写成带源状态条件的 UPDATE，按 affected_rows 分支
- [ ] 副作用（扣款/发货）在确认迁移成功后执行，并与状态更新同事务
- [ ] 外部回调/消息消费接唯一去重键，重复时幂等返回
- [ ] 并发字段修改用 version 乐观锁；状态迁移直接用条件更新
- [ ] 迁移历史写只追加事件表，含操作人、前后状态、时间
- [ ] 软删除用 deleted_at，并处理唯一索引冲突与定期归档
:::

## 本地复现

```bash
docker exec -it sql-treasure-mysql80 mysql -uroot -proot sql_treasure

# 1) 建订单表（见 1.3），插入一条待支付订单
INSERT INTO t_order(order_no) VALUES ('RE-DEMO-001');

# 2) 模拟"支付成功"与"超时取消"并发（开两个终端同时执行），验证只有一个成功
UPDATE t_order SET status=1, paid_at=NOW() WHERE order_no='RE-DEMO-001' AND status=0;
UPDATE t_order SET status=4 WHERE order_no='RE-DEMO-001' AND status=0;

# 3) 模拟重复支付回调：再执行一次第 2 步的支付语句
#    → affected_rows=0，查询发现已是 status=1，幂等返回成功

# 4) 非法迁移验证：已支付订单尝试直接"确认收货"（跳过发货）
UPDATE t_order SET status=3 WHERE order_no='RE-DEMO-001' AND status=2;  -- 0 行，被状态机拒绝

# 5) 对照阅读：115 建模方法论、58 软删除、51 类型、66 悲观 vs 乐观、67 幻读
```

::: tip 一句话总结
好的设计节点不是"别人这么写我也这么写"，而是能回答三个问题：**它在理论上是什么、现实中替你挡住了哪类故障、在数据库里靠什么机制保证**。状态机、幂等、乐观锁、唯一键、审计，各自对应一类确定的故障模式，这正是它们不可替代的原因。
:::
