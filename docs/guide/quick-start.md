# 快速开始

本指南让你从零开始，**复制粘贴每一步命令**，在 5 分钟内跑通第一个案例。

---

## 第一步：安装 Docker（已有可跳过）

::: tip 检查 Docker 是否已安装
```bash
docker --version
```
如果输出类似 `Docker version 24.x.x` 说明已安装，跳到第二步。
:::

<details>
<summary>没有 Docker？点这里展开安装方法</summary>

**Mac / Windows**：下载 [Docker Desktop](https://www.docker.com/products/docker-desktop/) 并安装。

**Linux（Ubuntu）**：
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
# 重新登录让用户组生效
exit
# 重新 SSH 登录后继续
```

安装完成后验证：
```bash
docker --version
docker compose version
```

</details>

---

## 第二步：克隆项目

```bash
git clone https://github.com/slowleelab/sql-lab.git
cd sql-lab
```

验证文件完整：
```bash
ls sql/cases/ | head -5
```

预期输出：
```
01-deep-pagination
02-leftmost-prefix
03-implicit-type-conversion
04-function-on-index
05-like-leading-wildcard
```

---

## 第三步：启动 MySQL 容器

```bash
docker compose up -d
```

::: warning 首次运行说明
首次启动会拉取 MySQL 镜像（约 500MB），根据网络情况可能需要 1-5 分钟。后续启动只需几秒。
:::

等待 MySQL 就绪（约 15 秒），检查容器状态：

```bash
docker compose ps
```

预期输出（`STATUS` 列显示 `healthy` 或 `Up`）：

```
NAME                      IMAGE       STATUS         PORTS
sql-treasure-mysql57      mysql:5.7   Up (healthy)   0.0.0.0:3307->3306/tcp
sql-treasure-mysql80      mysql:8.0   Up (healthy)   0.0.0.0:3308->3306/tcp
```

::: tip 如果状态还是 starting
等几秒再跑一次 `docker compose ps`。如果超过 1 分钟还没 healthy，检查端口是否被占用：
```bash
lsof -i :3307 -i :3308
```
如果端口被占用，修改 `docker-compose.yml` 中的端口映射。
:::

| 容器 | MySQL 版本 | 端口 | 用户 | 密码 | 数据库 |
|------|-----------|------|------|------|--------|
| sql-treasure-mysql57 | 5.7 | 3307 | root | root | sql_treasure |
| sql-treasure-mysql80 | 8.0 | 3308 | root | root | sql_treasure |

---

## 第四步：运行第一个案例

以「深度分页」为例，默认在 MySQL 8.0 上运行：

```bash
./scripts/run-case.sh 01-deep-pagination
```

::: tip 如果提示 Permission denied
```bash
chmod +x scripts/run-case.sh
```
然后重新运行。
:::

脚本会自动完成以下步骤（约 30-60 秒）：

```
═══════════════════════════════════════════════════════════
  SQL Lab · 案例运行器
═══════════════════════════════════════════════════════════
  案例:   01-deep-pagination
  版本:   MySQL 8.0  (端口 3308)
  容器:   sql-treasure-mysql80

▶ [1/4] 建表 (schema.sql)...
  ✓ 建表完成

▶ [2/4] 造数据 (seed.sql)...
  ✓ 造数据完成

▶ [3/4] 数据概览:
  TABLE_NAME    approx_rows
  t_order       1000000

▶ [4/4] EXPLAIN 对比

━━━ bad.sql (优化前) ━━━
type: ALL    rows: 980,000    Extra: Using filesort
耗时: 1230 ms

━━━ good.sql (优化后) ━━━
type: ref    rows: 12    Extra: Using index
耗时: 2 ms

🚀 扫描行数下降 99.99%，耗时下降 99.84%
```

看到上面的对比输出，说明第一个案例已成功跑通！

---

## 第五步：运行更多案例

### 查看所有可用案例

```bash
./scripts/run-case.sh
```

输出：
```
可用案例:
  - 01-deep-pagination
  - 02-leftmost-prefix
  - 03-implicit-type-conversion
  - 04-function-on-index
  - 05-like-leading-wildcard
  - 06-or-condition
  - 07-range-after-index
  - 08-covering-index
  - 09-index-condition-pushdown
  - 15-subquery-to-join
  ...（共 86 个）
```

### 运行其他案例

```bash
# 运行第 3 个案例（隐式类型转换）
./scripts/run-case.sh 03-implicit-type-conversion

# 运行第 24 个案例（小表驱动大表）
./scripts/run-case.sh 24-small-drive-large
```

::: tip 案例名怎么找
案例名就是 `sql/cases/` 下的目录名。也可以在[案例总览](../cases/)页面找到对应名称。
:::

---

## 常用选项

### 指定 MySQL 版本

```bash
# 在 MySQL 5.7 上运行（端口 3307）
./scripts/run-case.sh 01-deep-pagination --ver 5.7

# 在 MySQL 8.0 上运行（默认，端口 3308）
./scripts/run-case.sh 01-deep-pagination --ver 8.0
```

### 跳过造数据（快速重跑）

数据已经造好后，跳过造数据步骤，秒出 EXPLAIN 对比：

```bash
./scripts/run-case.sh 01-deep-pagination --no-seed
```

### 对比 5.7 和 8.0 的差异

```bash
# 先跑 5.7
./scripts/run-case.sh 09-index-condition-pushdown --ver 5.7

# 再跑 8.0
./scripts/run-case.sh 09-index-condition-pushdown --ver 8.0
```

观察 EXPLAIN 输出中 `Extra` 列的差异（如 ICP 在 8.0 中默认开启）。

---

## 手动连接数据库探索

如果你想自己写 SQL 实验，直接连上去：

```bash
# 连接 MySQL 8.0
mysql -h 127.0.0.1 -P 3308 -uroot -proot sql_treasure

# 连接 MySQL 5.7
mysql -h 127.0.0.1 -P 3307 -uroot -proot sql_treasure
```

::: tip 没装 mysql 客户端？
用 Docker 内置的客户端：
```bash
# MySQL 8.0
docker exec -it sql-treasure-mysql80 mysql -uroot -proot sql_treasure

# MySQL 5.7
docker exec -it sql-treasure-mysql57 mysql -uroot -proot sql_treasure
```
:::

---

## 本地预览文档站

```bash
npm install
npm run docs:dev
```

浏览器访问 `http://localhost:5173` 即可预览文档站（与在线版内容一致）。

---

## 清理环境

```bash
# 停止容器（保留数据，下次启动不用重新造数据）
docker compose down

# 停止并删除所有数据（完全重来）
docker compose down -v
```

---

## 常见问题

<details>
<summary><b>docker compose 命令不存在</b></summary>

旧版 Docker 使用 `docker-compose`（带横杠）。建议升级到新版 Docker Desktop，或安装 compose 插件：
```bash
# Linux 安装 compose 插件
sudo apt-get install docker-compose-plugin
```
</details>

<details>
<summary><b>端口 3307/3308 被占用</b></summary>

修改 `docker-compose.yml` 中的端口映射，例如改为 3407/3408：
```yaml
ports:
  - "3407:3306"  # 原来是 3307:3306
```
同时修改 `scripts/run-case.sh` 中的端口映射（搜索 `3307` 和 `3308` 替换）。
</details>

<details>
<summary><b>造数据很慢</b></summary>

百万级数据插入需要 30-60 秒，属正常现象。如果超过 3 分钟：
1. 检查 `docker compose ps` 容器是否 healthy
2. 检查磁盘空间：`df -h`
3. 可以减少数据量：编辑对应案例的 `seed.sql`，把存储过程的参数调小（如 `100000` 改为 `50000`）
</details>

<details>
<summary><b>容器启动后立即运行案例报错连接失败</b></summary>

MySQL 初始化需要时间，等容器状态变为 `healthy` 后再运行：
```bash
# 等待就绪
docker compose ps   # 确认 STATUS 为 healthy
```
或者直接运行 `run-case.sh`，脚本内置了等待逻辑（最多等 2 分钟）。
</details>

---

## 下一步

- [如何阅读案例](./how-to-read) — 了解每个案例的标准结构
- [案例总览](../cases/) — 浏览全部 86 个案例
- [深度分页案例](../cases/indexing/01-deep-pagination) — 从第一个案例开始深入
