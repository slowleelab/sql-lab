#!/usr/bin/env bash
# ============================================================
# new-case.sh - 快速创建新案例骨架
# 用法: ./scripts/new-case.sh <编号-英文短名> <分类目录>
# 示例: ./scripts/new-case.sh 56-my-case indexing
# 分类: indexing / query-rewrite / join / ddl / architecture / transaction / optimizer / tidb
# ============================================================
set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ $# -lt 2 ]]; then
  echo -e "${RED}用法: $0 <编号-英文短名> <分类目录>${NC}"
  echo -e "示例: $0 56-my-case indexing"
  echo -e "分类: indexing / query-rewrite / join / ddl / architecture / transaction / optimizer"
  exit 1
fi

CASE_NAME="$1"
CATEGORY="$2"
CASE_DIR="sql/cases/${CASE_NAME}"
DOC_DIR="docs/cases/${CATEGORY}"

# 验证分类
VALID_CATEGORIES="indexing query-rewrite join ddl architecture transaction optimizer tidb"
if ! echo "$VALID_CATEGORIES" | grep -qw "$CATEGORY"; then
  echo -e "${RED}错误: 无效分类 '$CATEGORY'${NC}"
  echo -e "有效分类: $VALID_CATEGORIES"
  exit 1
fi

# 检查是否已存在
if [[ -d "$CASE_DIR" ]]; then
  echo -e "${RED}错误: 案例目录已存在: $CASE_DIR${NC}"
  exit 1
fi

# 创建目录结构
mkdir -p "$CASE_DIR/expected"

# 创建 case.yml
cat > "$CASE_DIR/case.yml" << EOF
title: 案例标题（中文）
category: ${CATEGORY}
difficulty: 2
versions: ["5.7", "8.0"]
tags: ["标签1", "标签2"]
description: |
  场景描述，2-3 行。
  说明优化方案。
EOF

# 创建 schema.sql
cat > "$CASE_DIR/schema.sql" << 'SQLEOF'
-- ============================================================
-- 案例: 案例标题
-- 场景: 场景描述
-- ============================================================

DROP TABLE IF EXISTS t_xxx;
CREATE TABLE t_xxx (
    id          BIGINT        NOT NULL AUTO_INCREMENT,
    -- TODO: 添加字段
    PRIMARY KEY (id),
    -- TODO: 添加索引 idx_xxx / uk_xxx
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='表注释';
SQLEOF

# 创建 seed.sql
cat > "$CASE_DIR/seed.sql" << 'SQLEOF'
-- ============================================================
-- 造数据: XX 万行
-- ============================================================

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_xxx $$
CREATE PROCEDURE sp_seed_xxx()
BEGIN
    DECLARE i INT DEFAULT 0;
    SET autocommit = 0;

    WHILE i < 100000 DO
        INSERT INTO t_xxx (/* TODO: 字段列表 */)
        VALUES (/* TODO: 值列表 */);
        SET i = i + 1;

        IF i % 5000 = 0 THEN
            COMMIT;
        END IF;
    END WHILE;

    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_xxx();
DROP PROCEDURE IF EXISTS sp_seed_xxx;

SELECT COUNT(*) AS total_rows FROM t_xxx;
SQLEOF

# 创建 bad.sql
cat > "$CASE_DIR/bad.sql" << 'SQLEOF'
-- bad.sql: 问题 SQL
-- 原理: 说明为什么慢
-- TODO: 替换为实际问题 SQL
SELECT * FROM t_xxx WHERE 1=1;
SQLEOF

# 创建 good.sql
cat > "$CASE_DIR/good.sql" << 'SQLEOF'
-- good.sql: 优化后 SQL
-- 原理: 说明优化方案
-- TODO: 替换为优化后 SQL
SELECT * FROM t_xxx WHERE 1=1;
SQLEOF

# 创建 expected 占位文件
cat > "$CASE_DIR/expected/explain-bad.md" << 'MDEOF'
# EXPLAIN 参考结果 - bad.sql（优化前）

## MySQL 8.0（XX 万行数据）

TODO: 运行 `./scripts/run-case.sh 案例名` 后填写实际 EXPLAIN 结果。
MDEOF

cat > "$CASE_DIR/expected/explain-good.md" << 'MDEOF'
# EXPLAIN 参考结果 - good.sql（优化后）

## MySQL 8.0（XX 万行数据）

TODO: 运行 `./scripts/run-case.sh 案例名` 后填写实际 EXPLAIN 结果。
MDEOF

# 创建文档 .md 骨架
DOC_FILE="${DOC_DIR}/${CASE_NAME}.md"
cat > "$DOC_FILE" << MDEOF
# 案例标题（中文）

<CaseMeta difficulty="⭐⭐" category="分类中文名" versions="5.7 & 8.0" :tags="['标签1', '标签2']" />

## 场景痛点

TODO: 描述生产场景和痛点。

## 问题分析

### bad.sql

\`\`\`sql
-- TODO: 引用 bad.sql 内容
\`\`\`

### EXPLAIN 结果

TODO: 分析 bad.sql 的 EXPLAIN。

### 为什么慢

TODO: 分析慢的原因。

## 优化方案

### good.sql

\`\`\`sql
-- TODO: 引用 good.sql 内容
\`\`\`

### 原理

TODO: 说明优化原理。

### 对比

| | bad.sql | good.sql |
|---|---|---|
| TODO | ... | ... |

<ExplainCompare
  :bad="{ type: 'TODO', key: 'TODO', rows: 'TODO', Extra: 'TODO' }"
  :good="{ type: 'TODO', key: 'TODO', rows: 'TODO', Extra: 'TODO' }"
  improvement="TODO"
/>

## 避坑指南

::: warning 注意事项
TODO: 列出注意事项。
:::

## 5.7 vs 8.0 差异

| 特性 | 5.7 | 8.0 |
|------|-----|-----|
| TODO | ... | ... |

## 本地复现

\`\`\`bash
./scripts/run-case.sh ${CASE_NAME}
./scripts/run-case.sh ${CASE_NAME} --ver 5.7
./scripts/run-case.sh ${CASE_NAME} --no-seed
\`\`\`
MDEOF

echo -e "${GREEN}✅ 案例骨架已创建:${NC}"
echo -e "  ${CYAN}SQL 目录:${NC}  $CASE_DIR/"
echo -e "  ${CYAN}文档文件:${NC}  $DOC_FILE"
echo ""
echo -e "${YELLOW}下一步:${NC}"
echo "  1. 编辑 case.yml 填写标题和标签"
echo "  2. 编写 schema.sql 建表"
echo "  3. 编写 seed.sql 造数据"
echo "  4. 编写 bad.sql / good.sql"
echo "  5. 运行 ./scripts/run-case.sh ${CASE_NAME} 测试"
echo "  6. 填写 expected/ 和文档 .md"
