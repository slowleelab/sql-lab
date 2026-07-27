#!/usr/bin/env bash
#
# run-case.sh — 一键运行某个案例：建表 → 造数据 → 跑 bad/good EXPLAIN 对比
#
# 用法:
#   ./scripts/run-case.sh <case-dir>              # 默认 MySQL 8.0
#   ./scripts/run-case.sh <case-dir> --ver 5.7    # 指定 MySQL 5.7
#   ./scripts/run-case.sh <case-dir> --ver tidb   # 指定 TiDB
#   ./scripts/run-case.sh <case-dir> --no-seed    # 跳过造数据（数据已存在）
#
# 示例:
#   ./scripts/run-case.sh 01-deep-pagination
#   ./scripts/run-case.sh 01-deep-pagination --ver 5.7
#
set -euo pipefail

# ────────────────────────────── 颜色 ──────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ────────────────────────────── 参数 ──────────────────────────────
CASE_DIR=""
MYSQL_VER="8.0"
SKIP_SEED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ver)
      MYSQL_VER="$2"; shift 2 ;;
    --no-seed)
      SKIP_SEED=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *)
      CASE_DIR="$1"; shift ;;
  esac
done

if [[ -z "$CASE_DIR" ]]; then
  echo -e "${RED}错误: 请指定案例目录名${NC}"
  echo "用法: $0 <case-dir> [--ver 5.7|8.0|tidb] [--no-seed]"
  echo "可用案例:"
  ls -1 "$(dirname "$0")/../sql/cases/" | sed 's/^/  - /'
  exit 1
fi

# ────────────────────────────── 路径 ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CASE_PATH="$PROJECT_ROOT/sql/cases/$CASE_DIR"

if [[ ! -d "$CASE_PATH" ]]; then
  echo -e "${RED}错误: 案例目录不存在: $CASE_PATH${NC}"
  echo "可用案例:"
  ls -1 "$PROJECT_ROOT/sql/cases/" | sed 's/^/  - /'
  exit 1
fi

# ────────────────────────────── 端口映射 ──────────────────────────────
case "$MYSQL_VER" in
  5.7) PORT=3307; CONTAINER="sql-treasure-mysql57" ;;
  8.0) PORT=3308; CONTAINER="sql-treasure-mysql80" ;;
  tidb) PORT=4000; CONTAINER="sql-treasure-tidb" ;;
  *) echo -e "${RED}错误: 不支持的版本 $MYSQL_VER，请用 5.7、8.0 或 tidb${NC}"; exit 1 ;;
esac

MYSQL_CMD="mysql -h 127.0.0.1 -P $PORT -uroot -proot sql_treasure"

# ────────────────────────────── 检查容器 ──────────────────────────────
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SQL Lab · 案例运行器${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "  案例:   ${BOLD}$CASE_DIR${NC}"
if [[ "$MYSQL_VER" == "tidb" ]]; then
  echo -e "  版本:   TiDB (端口 $PORT)"
else
  echo -e "  版本:   MySQL $MYSQL_VER  (端口 $PORT)"
fi
echo -e "  容器:   $CONTAINER"
echo ""

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo -e "${YELLOW}⚠ 容器 $CONTAINER 未运行，正在启动...${NC}"
  if [[ "$MYSQL_VER" == "tidb" ]]; then
    docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d pd tikv tidb
  else
    docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d "mysql${MYSQL_VER/./}"
  fi
  echo -e "${YELLOW}  等待 MySQL 就绪...${NC}"
  for i in $(seq 1 60); do
    if $MYSQL_CMD -e "SELECT 1" &>/dev/null; then
      echo -e "${GREEN}  ✓ MySQL 已就绪${NC}"
      break
    fi
    sleep 2
    [[ $i -eq 60 ]] && { echo -e "${RED}  ✗ MySQL 启动超时${NC}"; exit 1; }
  done
fi

# ────────────────────────────── 建表 ──────────────────────────────
SCHEMA_FILE="$CASE_PATH/schema.sql"
if [[ -f "$SCHEMA_FILE" ]]; then
  echo -e "${CYAN}▶ [1/4] 建表 (schema.sql)...${NC}"
  $MYSQL_CMD < "$SCHEMA_FILE"
  echo -e "${GREEN}  ✓ 建表完成${NC}"
else
  echo -e "${YELLOW}  ⚠ 未找到 schema.sql，跳过建表${NC}"
fi

# ────────────────────────────── 造数据 ──────────────────────────────
SEED_FILE="$CASE_PATH/seed.sql"
if [[ "$SKIP_SEED" == "true" ]]; then
  echo -e "${YELLOW}▶ [2/4] 跳过造数据 (--no-seed)${NC}"
elif [[ -f "$SEED_FILE" ]]; then
  echo -e "${CYAN}▶ [2/4] 造数据 (seed.sql)...${NC}"
  $MYSQL_CMD < "$SEED_FILE"
  echo -e "${GREEN}  ✓ 造数据完成${NC}"
else
  echo -e "${YELLOW}  ⚠ 未找到 seed.sql，跳过造数据${NC}"
fi

# ────────────────────────────── 确认数据量 ──────────────────────────────
echo -e "${CYAN}▶ [3/4] 数据概览:${NC}"
$MYSQL_CMD -e "SELECT TABLE_NAME, TABLE_ROWS AS approx_rows FROM information_schema.TABLES WHERE TABLE_SCHEMA='sql_treasure' AND TABLE_ROWS > 0 ORDER BY TABLE_ROWS DESC LIMIT 10;" 2>/dev/null | sed 's/^/  /'
echo ""

# ────────────────────────────── EXPLAIN 对比 ──────────────────────────────
echo -e "${CYAN}▶ [4/4] EXPLAIN 对比${NC}"
echo ""

run_explain() {
  local label="$1"
  local color="$2"
  local file="$3"
  local setup_file="${4:-}"   # 可选: EXPLAIN 前先执行的 DDL/setup 文件

  if [[ ! -f "$file" ]]; then
    echo -e "  ${YELLOW}⚠ 未找到 $label 文件: $(basename "$file")${NC}"
    return
  fi

  echo -e "${color}━━━ $label ━━━${NC}"
  echo -e "${color}SQL: $(grep -v '^--' "$file" | head -1)$NC"
  echo ""

  # 构建 EXPLAIN 命令：如果有 setup 文件，先执行 setup
  local setup_sql=""
  if [[ -n "$setup_file" && -f "$setup_file" ]]; then
    setup_sql="$(grep -v '^--' "$setup_file" | grep -v '^$') "
  fi

  # 如果 setup 包含 DDL（ALTER/CREATE/DROP），直接用文件执行（支持多语句）
  if echo "$setup_sql" | grep -qiE 'ALTER|CREATE|DROP|TRUNCATE'; then
    # DDL 语句用文件方式执行（支持多条 DDL），忽略已存在等错误
    $MYSQL_CMD --force < "$setup_file" 2>/dev/null
    # 再跑 EXPLAIN（DDL 跨连接生效）
    $MYSQL_CMD -e "EXPLAIN $(cat "$file");" 2>/dev/null \
      || $MYSQL_CMD -e "EXPLAIN $(cat "$file");"
  elif echo "$setup_sql" | grep -qiE 'SET SESSION|SET @'; then
    # SET SESSION 必须和 EXPLAIN 在同一连接
    local session_only=""
    session_only="$(echo "$setup_sql" | grep -iE 'SET SESSION|SET @')"
    $MYSQL_CMD -e "${session_only} EXPLAIN $(cat "$file");" 2>/dev/null \
      || $MYSQL_CMD -e "EXPLAIN $(cat "$file");"
  else
    $MYSQL_CMD -e "EXPLAIN $(cat "$file");" 2>/dev/null \
      || $MYSQL_CMD -e "EXPLAIN $(cat "$file");"
  fi

  echo ""

  # 跑实际查询统计耗时（同样需要 setup 的 SET SESSION 在同一连接）
  echo -e "${color}实际执行耗时:${NC}"
  if echo "$setup_sql" | grep -qiE 'SET SESSION|SET @'; then
    local session_only=""
    session_only="$(echo "$setup_sql" | grep -iE 'SET SESSION|SET @')"
    $MYSQL_CMD -e "${session_only} SET @start_ts := NOW(6); $(cat "$file"); SET @end_ts := NOW(6); SELECT CONCAT(ROUND(TIMESTAMPDIFF(MICROSECOND, @start_ts, @end_ts)/1000, 2), ' ms') AS elapsed;" 2>/dev/null | sed 's/^/  /'
  else
    $MYSQL_CMD -e "SET @start_ts := NOW(6); $(cat "$file"); SET @end_ts := NOW(6); SELECT CONCAT(ROUND(TIMESTAMPDIFF(MICROSECOND, @start_ts, @end_ts)/1000, 2), ' ms') AS elapsed;" 2>/dev/null | sed 's/^/  /'
  fi
  echo ""
}

# bad.sql 可选 setup-bad.sql; good.sql 可选 setup-good.sql
run_explain "bad.sql (优化前)" "$RED" "$CASE_PATH/bad.sql" "$CASE_PATH/setup-bad.sql"
run_explain "good.sql (优化后)" "$GREEN" "$CASE_PATH/good.sql" "$CASE_PATH/setup-good.sql"

# ────────────────────────────── 参考结果 ──────────────────────────────
EXPECTED_DIR="$CASE_PATH/expected"
if [[ -d "$EXPECTED_DIR" ]]; then
  echo -e "${CYAN}━━━ 参考结果 ━━━${NC}"
  echo -e "  参考的 EXPLAIN 结果在 sql/cases/$CASE_DIR/expected/ 目录下，可对照你本地的输出。"
  ls -1 "$EXPECTED_DIR" 2>/dev/null | sed 's/^/  - /'
  echo ""
fi

echo -e "${GREEN}✓ 案例运行完成！${NC}"
echo -e "${CYAN}提示: 加 --no-seed 可跳过造数据直接重跑 EXPLAIN${NC}"
