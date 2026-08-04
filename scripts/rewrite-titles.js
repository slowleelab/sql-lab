#!/usr/bin/env node
/**
 * 案例"场景痛点"标题批量改写工具 v3
 *
 * 思路:
 *   1. 从"场景痛点"段首段提取"主谓宾"结构
 *   2. 优先选 [数字] + [动词/现象] + [关键名词] 组合
 *   3. --apply: 把已确认的标题批量替换 ## 场景痛点 → ## <新标题>
 *
 * 用法:
 *   node scripts/rewrite-titles.js --scan     # 扫描+生成候选
 *   node scripts/rewrite-titles.js --apply    # 应用(scan 后编辑 markdown 中"确认"列)
 */

import { readFileSync, readdirSync, writeFileSync, statSync } from 'fs'
import { resolve, dirname, basename } from 'path'
import { fileURLToPath } from 'url'

const ROOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const CASES_DIR = resolve(ROOT_DIR, 'docs/cases')
const OUT_FILE = resolve(ROOT_DIR, 'scripts/titles-rewrite-suggestions.md')

// ---------------------------------------------------------------------------
// 解析:从首段中拿到"最具画面感的子句"
// ---------------------------------------------------------------------------

/** 拿掉 markdown 强调/反引号 */
function clean(s) {
  return s
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/——|--+/g, '，')
    .replace(/\s+/g, ' ')
    .trim()
}

/** 拿掉"某 X 系统/X 业务..."这种铺垫,保留核心现象 */
function trimLeadIn(s) {
  // 去掉以"X 业务 / X 系统 / X 项目 / X 页面 / X 场景"开头的铺垫
  s = s.replace(/^[^，。]{0,30}(系统|业务|项目|页面|场景|服务|模块|后台|应用|环境|公司|组|端)\S{0,5}[，。、]?/, '')
  // 去掉"X 中 / X 后 / X 时"无主语短句
  s = s.replace(/^[^，。]{0,15}[中后时里内上]的?/, '')
  // 去掉"X 启动后 X / X 上线时 X / X 跑得 X / X 跑起来 X" 这类状态铺垫
  s = s.replace(/^[^，。]{0,12}(启动后|上线时|跑起来|跑得|运行|上线)\S{0,8}[，。、]?/, '')
  return s.trim()
}

/** 评估一个子句的"画面感"分数 */
function scoreClause(clause, nums, verbs) {
  let score = 0
  const c = clause.trim()
  if (c.length < 4) return -1
  if (c.length > 30) return -1
  // 含数字 +2,含动词 +2,同时含 +3
  if (nums.length > 0 && nums.some(n => c.includes(n))) score += 2
  if (verbs.length > 0 && verbs.some(v => c.includes(v))) score += 2
  if (nums.length > 0 && verbs.length > 0 && score === 4) score += 1
  // 长度适中(8-22)+1
  if (c.length >= 8 && c.length <= 22) score += 1
  // 不含连接词性短语开头 -1
  if (/^(但|但是|然后|于是|因此|所以|并且|而且)/.test(c)) score -= 2
  // 状态铺垫 -3
  if (/^.{0,12}(启动后运行|跑得好好的|跑起来|运行正常|上线时)/.test(c)) score -= 3
  return score
}

/** 把段首段拆成"主谓宾/现象"子句,挑最像"画面"的那句 */
function pickPunchline(para) {
  const cleaned = clean(para)
  // 按句号/逗号/分号切
  const clauses = cleaned
    .split(/[。,，;；!?]/)
    .map(s => trimLeadIn(s.trim()))
    .filter(s => s.length >= 4)
  if (clauses.length === 0) return cleaned.slice(0, 22)

  const nums = extractNumbers(cleaned)
  const verbs = extractVerbs(cleaned)

  // 找分数最高的子句
  let best = clauses[0]
  let bestScore = -1
  for (const c of clauses) {
    const s = scoreClause(c, nums, verbs)
    if (s > bestScore) {
      bestScore = s
      best = c
    }
  }

  // 兜底: 如果分数都很低,取含数字或动词的子句
  if (bestScore < 0) {
    const withN = clauses.find(c => nums.some(n => c.includes(n)))
    const withV = clauses.find(c => verbs.some(v => c.includes(v)))
    best = withN || withV || clauses[0]
  }

  if (best.length > 22) best = best.slice(0, 22) + '…'
  // 清理末尾标点
  best = best.replace(/[：:,，.;；]+$/, '').replace(/[）)]+$/, '').trim()
  return best
}

/** 关键数字: [数量+单位] 或纯数字 (>= 10) */
function extractNumbers(para) {
  const found = []
  const re1 = /(\d+(?:\.\d+)?\s*(?:万|亿|千|百|秒|分钟|小时|天|ms|GB|MB|KB|%|条|行|页|单|次|倍|×|x|X|TPS|QPS|RPS))/gi
  let m
  while ((m = re1.exec(para)) !== null) {
    if (!found.includes(m[1].trim())) found.push(m[1].trim())
    if (found.length >= 3) break
  }
  if (found.length < 3) {
    const re2 = /(?<![a-zA-Z\d.])(\d{2,}(?:\.\d+)?)(?![a-zA-Z\d.])/g
    while ((m = re2.exec(para)) !== null) {
      const v = m[1]
      if (!found.includes(v) && Number(v) >= 10 && Number(v) <= 1e9) {
        found.push(v)
        if (found.length >= 3) break
      }
    }
  }
  return found.slice(0, 3)
}

/** 关键动词(现象) */
function extractVerbs(para) {
  const dict = [
    '飙升', '暴涨', '骤降', '腰斩', '失败', '告警', '卡顿', '阻塞', '超时',
    '超卖', '错乱', '丢失', '重复', '翻倍', '堆积', '膨胀', '崩溃', '挂起',
    '变慢', '退化', '中断', '跳号', '飘红', '耗尽', '抖动', '抖动', '空转',
    '慢', '死锁', '死循环', '降级', '熔断', '雪崩', '穿透', '击穿',
  ]
  return [...new Set(dict.filter(v => para.includes(v)))].slice(0, 3)
}

// ---------------------------------------------------------------------------
// 候选生成
// ---------------------------------------------------------------------------

function suggest(para) {
  const nums = extractNumbers(para)
  const verbs = extractVerbs(para)
  const punch = pickPunchline(para)
  const cands = []

  // 候选 1: 数字 + 现象 (数据钩子型)
  if (nums.length > 0) {
    const num = nums[0]
    const verb = verbs[0]
    const hook = punch && punch.length >= 4 && !punch.includes(num) ? punch : ''
    if (verb && hook) {
      cands.push(`${num}${verb}：${hook}`)
    } else if (verb) {
      cands.push(`${num}${verb}`)
    } else if (hook) {
      cands.push(`${num}：${hook}`)
    } else {
      cands.push(`${num} 触发的问题`)
    }
  }

  // 候选 2: 现象直陈型
  if (punch && punch.length >= 6 && !cands.includes(punch)) {
    if (verbs.length > 0 && !punch.includes(verbs[0])) cands.push(`${punch},${verbs[0]}`)
    else cands.push(punch)
  } else if (cands.length < 2) {
    // 兜底:用首段前 18 字
    const first = clean(para).slice(0, 18)
    cands.push(first || '性能问题诊断')
  }

  // 候选 3: 极简型 [数字][动词] 或两关键词
  if (nums.length > 0 && verbs.length > 0) {
    cands.push(`${nums[0]}${verbs[0]}`)
  } else {
    const keywords = [...verbs, ...nums].slice(0, 2).join(' + ')
    cands.push(keywords || (punch ? punch.slice(0, 10) : '性能瓶颈'))
  }

  return cands.slice(0, 3)
}

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

function extractPainPoint(file) {
  const text = readFileSync(file, 'utf-8')
  const m = text.match(/^## 场景痛点\s*\n+([\s\S]*?)(?=\n## |\n---)/m)
  if (!m) return null
  const lines = m[1].split('\n')
  const para = []
  for (const line of lines) {
    if (line.startsWith('```')) break
    if (line.trim() === '' && para.length > 0) break
    para.push(line)
  }
  return clean(para.join(' ').trim())
}

const CAT_CN = {
  indexing: '索引',
  'query-rewrite': '查询改写',
  join: 'JOIN',
  ddl: 'DDL',
  architecture: '架构',
  transaction: '事务',
  optimizer: '优化器',
  tidb: 'TiDB',
}

function scan() {
  const files = []
  for (const cat of readdirSync(CASES_DIR)) {
    const catPath = resolve(CASES_DIR, cat)
    if (!statSync(catPath).isDirectory()) continue
    for (const f of readdirSync(catPath)) {
      if (!f.endsWith('.md')) continue
      files.push({ path: resolve(catPath, f), category: cat })
    }
  }
  files.sort((a, b) => a.path.localeCompare(b.path))

  const lines = [
    '# 案例标题重写候选表 (v3)',
    '',
    '> 自动生成,共 **' + files.length + '** 个案例。',
    '>',
    '> **使用流程**:',
    '> 1. 浏览候选,挑一个最像人话的填到"确认标题"列(或直接改原 markdown 后再跑 --scan)',
    '> 2. 留空表示保持"场景痛点"',
    '> 3. 保存后运行 `node scripts/rewrite-titles.js --apply` 批量替换',
    '',
    '> **候选风格**:',
    '> - 候选 1: [数字]+[动词]+[画面] (推荐) ',
    '> - 候选 2: 现象直陈 (适合没有具体数字的)',
    '> - 候选 3: 极简二词',
    '',
    '| # | 章节 | 文件 | 候选 1 | 候选 2 | 候选 3 | 确认标题 | 关键数字 | 关键现象 |',
    '|---|------|------|--------|--------|--------|----------|----------|----------|',
  ]

  let idx = 1
  for (const { path, category } of files) {
    const para = extractPainPoint(path)
    if (!para) {
      console.warn(`  ⚠️  跳过(无场景痛点): ${path}`)
      continue
    }
    const cands = suggest(para)
    while (cands.length < 3) cands.push('—')
    const nums = extractNumbers(para).join('/') || '—'
    const verbs = extractVerbs(para).join('/') || '—'
    const relPath = path.replace(ROOT_DIR + '/', '').replace('docs/cases/', '')
    const cnCat = CAT_CN[category] || category
    lines.push(`| ${idx} | ${cnCat} | \`${relPath}\` | ${cands[0]} | ${cands[1]} | ${cands[2]} |  | ${nums} | ${verbs} |`)
    idx++
  }

  writeFileSync(OUT_FILE, lines.join('\n') + '\n')
  console.log(`✅ 已生成 ${idx - 1} 个案例的候选: ${OUT_FILE}`)
  console.log(`📝 编辑"确认标题"列,留空表示保持"场景痛点"`)
  console.log(`💡 完成后: node scripts/rewrite-titles.js --apply`)
}

/**
 * 把"确认标题"列批量填上候选 1 (数据钩子型)
 * 用于先看整体效果,再人工逐个微调
 */
function fillCand1() {
  const text = readFileSync(OUT_FILE, 'utf-8')
  const lines = text.split('\n')
  let filled = 0
  let skipped = 0
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (!line.startsWith('|') || line.startsWith('| #') || line.startsWith('|---')) continue
    // split 后形如 ['', 'idx', '章节', '文件', '候选1', '候选2', '候选3', '确认', '数字', '现象', '']
    const cols = line.split('|').map(s => s.trim())
    if (cols.length < 9) continue
    const cand1 = cols[4]   // 候选 1
    if (!cand1 || cand1 === '—' || cand1 === '-') {
      skipped++
      continue
    }
    cols[7] = cand1         // "确认标题"列
    lines[i] = cols.join('|')
    filled++
  }
  writeFileSync(OUT_FILE, lines.join('\n'))
  console.log(`✅ 已填充 ${filled} 行的"确认标题"列为候选 1`)
  if (skipped > 0) console.log(`  跳过 ${skipped} 行(候选 1 为空/占位)`)
  console.log(`💡 完成后: node scripts/rewrite-titles.js --apply`)
}

// ---------------------------------------------------------------------------
// 应用
// ---------------------------------------------------------------------------

function parseConfirmTable() {
  const text = readFileSync(OUT_FILE, 'utf-8')
  const map = new Map() // relPath -> newTitle
  for (const line of text.split('\n')) {
    // 匹配表格数据行(形如 "| 1 | ..." 或 "|1|...") 
    if (!line.startsWith('|')) continue
    if (line.startsWith('| #') || line.startsWith('|---') || line.startsWith('|---')) continue
    // split 后形如 ['', 'idx', '章节', '文件', '候选1', '候选2', '候选3', '确认', '数字', '现象', '']
    const cols = line.split('|').map(s => s.trim())
    if (cols.length < 9) continue
    const relPath = cols[3].replace(/`/g, '').trim()
    const confirm = cols[7] || ''
    if (!relPath.endsWith('.md')) continue
    if (confirm) map.set(relPath, confirm)
  }
  return map
}

function apply() {
  const confirm = parseConfirmTable()
  if (confirm.size === 0) {
    console.log('⚠️  "确认标题"列为空,无任何替换')
    return
  }
  console.log(`📋 准备替换 ${confirm.size} 个文件的标题`)

  let changed = 0
  for (const [relPath, rawTitle] of confirm) {
    // 去除用户可能误填的 markdown 加粗/反引号
    const newTitle = rawTitle
      .replace(/^\*\*|\*\*$/g, '')
      .replace(/^`|`$/g, '')
      .trim()
    const abs = resolve(ROOT_DIR, 'docs/cases', relPath)
    const text = readFileSync(abs, 'utf-8')
    const re = /^## 场景痛点\s*$/m
    if (!re.test(text)) {
      console.warn(`  ⚠️  无 ## 场景痛点: ${relPath}`)
      continue
    }
    const next = text.replace(re, `## ${newTitle}`)
    if (next === text) continue
    writeFileSync(abs, next)
    changed++
    console.log(`  ✅ ${relPath}: 场景痛点 → ${newTitle}`)
  }
  console.log(`\n🎉 已替换 ${changed} 个文件`)
  console.log(`💡 建议运行 node scripts/rewrite-titles.js --scan 重新扫描以刷新候选表`)
}

const mode = process.argv[2] || '--scan'
if (mode === '--scan') scan()
else if (mode === '--fill-cand1') fillCand1()
else if (mode === '--apply') apply()
else {
  console.error('用法: node scripts/rewrite-titles.js [--scan | --fill-cand1 | --apply]')
  process.exit(1)
}
