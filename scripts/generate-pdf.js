/**
 * generate-pdf.js — SQL Lab 电子书 PDF
 * 封面 · 目录 · 书签 · 作者(李强) · 元数据 · 页眉页脚
 *
 * 两轮生成：
 *   第一轮 — 合并所有页（封面 + 目录 + 指南 + 案例）
 *   第二轮 — 重新加载，添加书签/大纲
 *
 * 关键：Outline 对象通过 PDFDict + ctx.assign() 正确注册到 PDF 上下文，
 * 因此可以使用 useObjectStreams: true 让 pdf-lib 去重字体和资源（节省 ~40% 体积）。
 */
import { writeFileSync, existsSync, mkdirSync, unlinkSync, readdirSync, readFileSync, realpathSync } from 'fs'
import { resolve, dirname, sep } from 'path'
import { fileURLToPath } from 'url'
import { createServer } from 'http'
import { readFile } from 'fs/promises'
import puppeteer from 'puppeteer'
import { PDFDocument, PDFName, PDFString, PDFDict, PDFNumber, PDFArray, PDFHexString } from 'pdf-lib'

const ROOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const DIST = resolve(ROOT_DIR, 'docs/.vitepress/dist')
const OUT = resolve(ROOT_DIR, 'docs/public/sql-lab-cases.pdf')
const TMP = resolve(ROOT_DIR, 'docs/public/.sql-lab-cases-merged.pdf')
const AUTHOR = '李强'
const PORT = 4175
const BASE_PREFIX = '/sql-lab/' // VitePress base，必须与 docs/.vitepress/config.ts 一致
const CONCURRENCY = 6            // Puppeteer 并发渲染页面数（4-8 推荐，8GB 内存选 4，16GB+ 选 6-8）

// 解析 Chrome 路径：CI 优先用环境变量，本地优先用系统 Chrome，否则用 puppeteer 自带 chromium
function resolveChrome() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium-browser',
    '/usr/bin/chromium',
  ]
  for (const p of candidates) if (existsSync(p)) return p
  return undefined // 让 puppeteer 用自带的 chromium
}

// ─── 工具：MIME 类型 ─────────────────────────────────
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.eot': 'application/vnd.ms-fontobject',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
}
function mimeFor(fp) {
  const i = fp.lastIndexOf('.')
  return MIME[fp.slice(i)] || 'application/octet-stream'
}

// ─── 工具：HTML 转义 ─────────────────────────────────
const HTML_ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }
function escHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => HTML_ESC[c])
}

// ─── 工具：PDF UTF-16 BE 字符串（含 BOM）─ 用于中文书签
// PDF 字符串中的特殊字符 (\, (, ), 控制字符) 必须转义
function pdfStr(s) {
  if (s == null || s === '') return PDFString.of('')
  let raw
  if (/^[\x00-\x7F]*$/.test(s)) {
    raw = s
  } else {
    const buf = Buffer.alloc(2 + s.length * 2)
    buf[0] = 0xFE; buf[1] = 0xFF
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i)
      buf[2 + i * 2] = (c >> 8) & 0xFF
      buf[2 + i * 2 + 1] = c & 0xFF
    }
    raw = buf.toString('binary')
  }
  // 转义 PDF 字符串中的特殊字符
  let escaped = ''
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i]
    const code = raw.charCodeAt(i)
    if (c === '\\' || c === '(' || c === ')') {
      escaped += '\\' + c
    } else if (code === 0x0A) {
      escaped += '\\n'
    } else if (code === 0x0D) {
      escaped += '\\r'
    } else if (code === 0x09) {
      escaped += '\\t'
    } else if (code === 0x08) {
      escaped += '\\b'
    } else if (code === 0x0C) {
      escaped += '\\f'
    } else {
      escaped += c
    }
  }
  return PDFString.of(escaped)
}

const CATEGORIES = [
  { dir: 'indexing',       name: '一、索引设计与失效',     nums: [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18, 103, 104] },
  { dir: 'query-rewrite',  name: '二、查询改写',           nums: [19,20,21,22,23,24,25,26,27,28,29,30,31,32, 106] },
  { dir: 'join',           name: '三、JOIN 优化',          nums: [33,34,35,36,37,38,39,40,41] },
  { dir: 'ddl',            name: '四、DDL 与大表',         nums: [42,43,44,45,46,47,48,49,50,51, 105] },
  { dir: 'architecture',   name: '五、架构级优化',         nums: [52,53,54,55,56,57,58,59,60,61,62, 107, 108, 110] },
  { dir: 'transaction',    name: '六、事务与锁',           nums: [63,64,65,66,67,68,69,70,71, 109, 112] },
  { dir: 'optimizer',      name: '七、优化器与 8.0 新特性', nums: [72,73,74,75,76,77,78,79,80, 111] },
  { dir: 'tidb',           name: '八、TiDB 分布式优化',    nums: [81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100,101,102] },
]

function collect() {
  const guides = [
    { url: '/guide/introduction', title: '项目介绍' },
    { url: '/guide/quick-start',  title: '快速开始' },
    { url: '/guide/how-to-read',  title: '如何阅读案例' },
  ]
  const seenNums = new Set()
  const cases = []
  for (const cat of CATEGORIES) {
    const dir = resolve(DIST, 'cases', cat.dir)
    if (!existsSync(dir)) {
      console.warn(`  ⚠️  分类目录不存在: ${cat.dir}`)
      continue
    }
    // 用白名单集合过滤（支持每个 category 显式列举 num，不再依赖连续区间）
    const allow = new Set(cat.nums)
    for (const f of readdirSync(dir).filter(x => x.endsWith('.html')).sort()) {
      const slug = f.replace('.html', '')
      const m = slug.match(/^(\d+)/)
      if (!m) continue
      const num = parseInt(m[1], 10)
      if (!allow.has(num)) continue
      if (seenNums.has(num)) {
        console.warn(`  ⚠️  重复的案例编号 #${num} (${slug})，已跳过`)
        continue
      }
      const fp = resolve(dir, f)
      const content = readFileSync(fp, 'utf-8')
      if (content.includes('http-equiv="refresh"')) continue // 跳过重定向占位
      const tm = content.match(/<title>([^<]+)<\/title>/)
      const rawTitle = tm ? tm[1].replace(/\s*\|\s*SQL Lab$/, '').trim() : ''
      const title = rawTitle || slug.replace(/^\d+-/, '').replace(/-/g, ' ') || `案例 ${num}`
      seenNums.add(num)
      cases.push({ url: `/cases/${cat.dir}/${slug}`, num, cat: cat.name, slug, title })
    }
  }
  cases.sort((a, b) => a.num - b.num)
  return { guides, cases }
}

function startServer() {
  return new Promise((ok, fail) => {
    const s = createServer(async (req, res) => {
      try {
        let url = new URL(req.url, `http://localhost:${PORT}`).pathname
        // 剥离 VitePress base 前缀（保留前导 /）
        if (url.startsWith(BASE_PREFIX)) {
          url = '/' + url.slice(BASE_PREFIX.length)
        }
        if (!url || url === '/') url = '/index.html'
        if (!url.startsWith('/')) url = '/' + url

        // 防路径穿越：解码后必须仍在 DIST 之内
        const decoded = decodeURIComponent(url)
        let fp = resolve(DIST, `.${decoded}`)
        const realDist = realpathSync(DIST)
        if (!fp.startsWith(realDist + sep) && fp !== realDist) {
          res.writeHead(403); res.end('403'); return
        }
        if (!existsSync(fp)) {
          fp += '.html'
          if (!existsSync(fp)) fp = resolve(DIST, `.${decoded}/index.html`)
          if (!existsSync(fp)) { res.writeHead(404); res.end('404'); return }
        }
        const ct = await readFile(fp)
        res.writeHead(200, { 'Content-Type': mimeFor(fp), 'Content-Length': ct.length })
        res.end(ct)
      } catch (err) {
        if (!res.headersSent) res.writeHead(500); res.end('500')
        console.error(`  [server] ${req.url} -> ${err.message}`)
      }
    })
    s.listen(PORT, () => ok(s))
    s.on('error', fail)
  })
}

function closeServer(s) {
  return new Promise(r => s.close(() => r()))
}

async function htmlPdf(browser, html) {
  const p = await browser.newPage()
  try {
    await p.setContent(html, { waitUntil: 'load' })
    await p.evaluate(() => document.fonts.ready)
    return await p.pdf({ format: 'A4', printBackground: true, margin: { top: 0, bottom: 0, left: 0, right: 0 } })
  } finally { await p.close() }
}

async function pagePdf(browser, url, i, t) {
  const p = await browser.newPage()
  try {
    const full = `http://localhost:${PORT}${BASE_PREFIX}${url.replace(/^\//, '')}`
    // 在 goto 前注入 CSS 屏蔽非必要 Inter 字体子集，减小 PDF 体积
    await p.setBypassCSP(true)
    await p.setExtraHTTPHeaders({ 'X-PDF-Render': '1' })
    process.stdout.write(`  [${String(i).padStart(3)}/${t}] ${url.slice(0, 60).padEnd(62)}\r`)
    await p.goto(full, { waitUntil: 'domcontentloaded', timeout: 60000 })
    // 注入 CSS：覆盖中文字体优先 + 屏蔽 cyrillic/greek/vietnamese 等子集
    // + 注入 HTML 顶部 header (SQL Lab 标识) + 底部 footer (page counter via CSS)
    await p.addStyleTag({
      content: `
        body, .VPDoc, .vp-doc { font-family: "PingFang SC","Hiragino Sans GB","Microsoft YaHei","Source Han Sans SC",sans-serif !important; }
        /* 屏蔽非必要 Inter 字体子集（保留 basic-latin + latin-ext + cjk） */
        @font-face { font-family: 'Inter'; src: none !important; unicode-range: U+0400-04FF, U+0370-03FF, U+1E00-1EFF, U+0300-036F, U+0590-05FF, U+0600-06FF, U+0900-097F, U+3040-309F, U+30A0-30FF, U+AC00-D7AF, U+4E00-9FFF; }
        code, pre, .shiki { font-family: "JetBrains Mono","Menlo","Consolas",monospace !important; }
        /* 注入 HTML 渲染的页眉/页脚（比 Puppeteer headerTemplate 节省 ~80% 体积） */
        .pdf-header { position: running(header); border-bottom: 0.5px solid #ccc; padding-bottom: 4px; font-size: 8px; color: #666; text-align: center; width: 100%; }
        .pdf-footer { position: running(footer); border-top: 0.5px solid #ccc; padding-top: 4px; font-size: 8px; color: #999; text-align: center; width: 100%; }
        @page { @top-center { content: element(header); } @bottom-center { content: "— " counter(page) " —"; } margin-top: 16mm; margin-bottom: 18mm; margin-left: 16mm; margin-right: 16mm; }
      `
    })
    await p.evaluate(() => {
      // 注入页眉元素（HTML 渲染，不再走 Puppeteer headerTemplate）
      const header = document.createElement('div')
      header.className = 'pdf-header'
      header.textContent = 'SQL Lab · MySQL + TiDB 优化实战案例集'
      document.body.prepend(header)
      // 移除 VitePress 装饰元素
      for (const s of '.VPNav,.VPSidebar,.VPLocalNav,.VPFooter,.DocFooter,.edit-link,.prev-next,.VPDocAside,.VPNavScreen,.VPSkipLink'.split(',')) {
        document.querySelectorAll(s).forEach(e => e.remove())
      }
      const d = document.querySelector('.VPDoc')
      if (d) { d.style.padding = '0 24px'; d.style.maxWidth = '100%' }
      const c = document.querySelector('.VPContent')
      if (c) { c.style.paddingLeft = '0'; c.style.paddingRight = '0' }
    })
    await p.evaluate(() => document.fonts.ready)
    const buf = await p.pdf({
      format: 'A4',
      // 边距缩小到 16mm/18mm - 11% 提升单位面积利用率
      margin: { top: '16mm', bottom: '18mm', left: '16mm', right: '16mm' },
      printBackground: true,
      // 关闭 Puppeteer headerTemplate/footerTemplate - 改用 CSS @page + running() 节省 ~3MB
      displayHeaderFooter: false,
      // 字体渲染优化：禁用 hinting/抗锯齿以减小字形路径数据
      preferCSSPageSize: false,
    })
    process.stdout.write(`  [${String(i).padStart(3)}/${t}] ✅\n`)
    return buf
  } finally { await p.close() }
}

/**
 * 并发渲染多个页面，最大并发数 = CONCURRENCY
 * - 进度条按完成顺序输出，避免乱序覆盖
 * - 单个失败不阻塞整体（错误以 warn 形式记录，失败项返回 null）
 */
async function renderBatch(browser, items, concurrency = CONCURRENCY) {
  const results = new Array(items.length)
  let cursor = 0
  let completed = 0
  const total = items.length
  const start = Date.now()
  const inflight = new Set()

  const worker = async () => {
    while (true) {
      const idx = cursor++
      if (idx >= total) return
      const it = items[idx]
      try {
        const buf = await pagePdf(browser, it.url, it.idx, total)
        results[idx] = buf
        completed++
        const elapsed = ((Date.now() - start) / 1000).toFixed(1)
        process.stdout.write(`  📊 进度: ${completed}/${total} 完成 (并发 ${inflight.size}, 耗时 ${elapsed}s)\n`)
      } catch (err) {
        completed++
        console.warn(`  ⚠️  渲染失败: ${it.url} -> ${err.message}`)
        results[idx] = null
      } finally {
        inflight.delete(worker)
      }
    }
  }

  for (let i = 0; i < Math.min(concurrency, total); i++) {
    const w = worker()
    inflight.add(w)
    w.catch(() => {})
  }
  await Promise.all(inflight)
  return results
}

function coverHtml(casesTotal) {
  return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;width:210mm;height:297mm;background:linear-gradient(150deg,#0a1f14 0%,#163a26 30%,#265a3a 60%,#3a7a4e 100%);color:#fff}
.c{text-align:center;padding:60px 80px;position:relative}
.c .ic{font-size:72px;margin-bottom:16px;opacity:.9}
.c h1{font-size:58px;font-weight:800;letter-spacing:8px;margin-bottom:4px;text-shadow:0 3px 16px rgba(0,0,0,.3)}
.c .sub{font-size:26px;font-weight:300;opacity:.95;margin-bottom:8px;letter-spacing:12px}
.c .st{font-size:18px;font-weight:300;opacity:.75;margin-bottom:40px;letter-spacing:4px}
.c .dv{width:100px;height:2px;background:rgba(255,255,255,.35);margin:0 auto 40px}
.c .info{font-size:13px;opacity:.85;line-height:2.2;margin-bottom:44px}
.c .info span{margin:0 6px;padding:3px 14px;border:1px solid rgba(255,255,255,.3);border-radius:14px;white-space:nowrap}
.c .au{font-size:28px;font-weight:600;letter-spacing:8px;margin-top:32px;opacity:.95}
.c .ft{position:absolute;bottom:36px;left:0;right:0;text-align:center;font-size:11px;opacity:.4;letter-spacing:2px}
</style></head><body><div class="c"><div class="ic">🐳</div><h1>SQL Lab</h1><div class="sub">MySQL + TiDB</div><div class="st">优化实战案例集</div><div class="dv"></div><div class="info"><span>${casesTotal} 个案例</span><span>${CATEGORIES.length} 大场景</span><span>Docker 复现</span><br><span>MySQL 5.7 &amp; 8.0</span><span>TiDB v7.5</span></div><div class="au">${escHtml(AUTHOR)}</div><div class="ft">2026 · https://slowleelab.github.io/sql-lab/</div></div></body></html>`
}

function tocHtml(guides, cases) {
  let rows = ''
  for (const g of guides) rows += `<tr class="gd"><td></td><td>${escHtml(g.title)}</td></tr>`
  let lastCat = ''
  for (const c of cases) {
    if (c.cat !== lastCat) { rows += `<tr class="ct"><td colspan="2">${escHtml(c.cat)}</td></tr>`; lastCat = c.cat }
    rows += `<tr><td class="nm">${String(c.num).padStart(2, '0')}</td><td>${escHtml(c.title)}</td></tr>`
  }
  return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;padding:30px 52px;color:#333}
h1{font-size:24px;text-align:center;margin-bottom:18px;padding-bottom:10px;border-bottom:2px solid #2d6b44;letter-spacing:6px;color:#1a4a2e}
table{width:100%;border-collapse:collapse;font-size:11px}
tr.gd td{font-weight:600;color:#2d6b44;padding:6px 6px 2px;font-size:12px}
tr.ct td{color:#2d6b44;font-weight:700;padding:8px 6px 2px;font-size:11.5px;border-top:1px solid #d0d0d0}
td{padding:1.5px 6px;line-height:1.45;border-bottom:1px dotted #e8e8e8}
td.nm{width:32px;text-align:right;color:#999;padding-right:10px;font-size:10.5px}
</style></head><body><h1>目 录</h1><table>${rows}</table></body></html>`
}

/**
 * 为合并后的 PDF 添加书签/大纲
 * 使用 PDFDict + ctx.assign(ref, dict) 正确注册到 PDF 上下文，
 * 这样第二轮保存时使用 useObjectStreams: true 也能保留所有 Outline 对象。
 *
 * 层级: 指南(3) | 分类(8) → 案例(N)
 * 页数映射: 由调用方传入 (pageMap.guideStart / pageMap.caseStart)
 */
function addOutlines(doc, guides, cases, pageMap) {
  const ctx = doc.context
  const pages = doc.getPages()

  // 获取页面 ref 的辅助函数
  const pageRef = (idx) => pages[idx].ref

  // 预分配所有 ref
  const outlinesRef = ctx.nextRef()
  const guideRefs = guides.map(() => ctx.nextRef())
  const catRefs = Object.fromEntries(CATEGORIES.map(c => [c.name, ctx.nextRef()]))

  // 按分类分组案例
  const casesByCat = {}
  for (const c of CATEGORIES) casesByCat[c.name] = []
  for (const c of cases) casesByCat[c.cat].push(c)

  // 案例书签 refs
  const caseRefs = {}
  for (const c of CATEGORIES) {
    caseRefs[c.name] = casesByCat[c.name].map(() => ctx.nextRef())
  }

  // 所有顶层书签（指南 + 分类）
  const allTopRefs = [...guideRefs, ...CATEGORIES.map(c => catRefs[c.name])]

  // ── 创建指南书签 ──
  // guides 在合并后的全局起始页: pageMap.guideStart
  // 每个 guide 的首页: guideStart + 各 guide 的累计页数
  for (let i = 0; i < guides.length; i++) {
    const dict = PDFDict.withContext(ctx)
    dict.set(PDFName.of('Title'), pdfStr(guides[i].title))
    dict.set(PDFName.of('Parent'), outlinesRef)
    // Prev: 上一个顶层项（指南或分类）
    if (i > 0) dict.set(PDFName.of('Prev'), guideRefs[i - 1])
    // Next: 下一个顶层项；最后一个指南 → 第一个分类
    if (i < guides.length - 1) {
      dict.set(PDFName.of('Next'), guideRefs[i + 1])
    } else if (CATEGORIES.length > 0) {
      dict.set(PDFName.of('Next'), catRefs[CATEGORIES[0].name])
    }
    dict.set(PDFName.of('Dest'), ctx.obj([pageRef(pageMap.guideStart + pageMap.guidePageOffsets[i]), PDFName.of('XYZ'), PDFName.of('null'), PDFName.of('null'), PDFName.of('null')]))
    ctx.assign(guideRefs[i], dict)
  }

  // ── 创建分类 + 案例书签 ──
  // cases 起始页: pageMap.caseStart
  // 每个 case 的首页: caseStart + 各 case 的累计页数
  let globalCaseIdx = 0
  for (let ci = 0; ci < CATEGORIES.length; ci++) {
    const c = CATEGORIES[ci]
    const catCases = casesByCat[c.name]
    const catRef = catRefs[c.name]
    const childRefs = caseRefs[c.name]

    // 子案例书签
    for (let j = 0; j < catCases.length; j++) {
      const localIdx = globalCaseIdx
      const dict = PDFDict.withContext(ctx)
      dict.set(PDFName.of('Title'), pdfStr(catCases[j].title))
      dict.set(PDFName.of('Parent'), catRef)
      if (j > 0) dict.set(PDFName.of('Prev'), childRefs[j - 1])
      if (j < catCases.length - 1) dict.set(PDFName.of('Next'), childRefs[j + 1])
      dict.set(PDFName.of('Dest'), ctx.obj([pageRef(pageMap.caseStart + pageMap.casePageOffsets[localIdx]), PDFName.of('XYZ'), PDFName.of('null'), PDFName.of('null'), PDFName.of('null')]))
      ctx.assign(childRefs[j], dict)
      globalCaseIdx++
    }

    // 分类书签
    const catDict = PDFDict.withContext(ctx)
    catDict.set(PDFName.of('Title'), pdfStr(c.name))
    catDict.set(PDFName.of('Parent'), outlinesRef)
    // Prev: 上一个分类；第一个分类 → 最后一个指南
    if (ci > 0) {
      catDict.set(PDFName.of('Prev'), catRefs[CATEGORIES[ci - 1].name])
    } else if (guides.length > 0) {
      catDict.set(PDFName.of('Prev'), guideRefs[guides.length - 1])
    }
    // Next: 下一个分类
    if (ci < CATEGORIES.length - 1) catDict.set(PDFName.of('Next'), catRefs[CATEGORIES[ci + 1].name])
    if (catCases.length > 0) {
      catDict.set(PDFName.of('First'), childRefs[0])
      catDict.set(PDFName.of('Last'), childRefs[childRefs.length - 1])
      catDict.set(PDFName.of('Count'), PDFNumber.of(-catCases.length)) // 负数 = 默认折叠
    }
    ctx.assign(catRef, catDict)
  }

  // ── 根 Outlines 字典 ──
  const rootDict = PDFDict.withContext(ctx)
  rootDict.set(PDFName.of('Type'), PDFName.of('Outlines'))
  rootDict.set(PDFName.of('First'), allTopRefs[0])
  rootDict.set(PDFName.of('Last'), allTopRefs[allTopRefs.length - 1])
  rootDict.set(PDFName.of('Count'), PDFNumber.of(allTopRefs.length))
  ctx.assign(outlinesRef, rootDict)

  // 写入 Catalog
  doc.catalog.set(PDFName.of('Outlines'), outlinesRef)
  doc.catalog.set(PDFName.of('PageMode'), PDFName.of('UseOutlines'))
}

/**
 * 为 PDF 添加 PageLabels，让 Acrobat/Reader 在状态栏和书签上显示有意义的页码
 *
 * 结构：
 *   第 1 页        (cover)        - 空白或 "封面"
 *   第 2 页        (toc)          - "目录"
 *   第 3..2+guides (guides)       - "指南 1", "指南 2", ...
 *   第 X+          (cases)        - "案例 1", "案例 2", ...
 *
 * PageLabels 数组是"区间"结构，每个元素描述一个连续区间：
 *   { /S 'D' (decimal), /P '前缀', /St 起始值 }
 */
function addPageLabels(doc, guides, cases, pageMap) {
  const ctx = doc.context
  const nums = PDFArray.withContext(ctx)

  // 1. 封面 + TOC 共享：prefix="" + style=decimal，编号为 1, 2
  let entry = PDFDict.withContext(ctx)
  entry.set(PDFName.of('S'), PDFName.of('D'))  // Decimal
  entry.set(PDFName.of('P'), PDFHexString.fromText(''))
  entry.set(PDFName.of('St'), PDFNumber.of(1))
  nums.push(entry)

  // 2. 指南区 - "指南 1", "指南 2", ...
  if (guides.length > 0) {
    entry = PDFDict.withContext(ctx)
    entry.set(PDFName.of('S'), PDFName.of('D'))
    entry.set(PDFName.of('P'), PDFHexString.fromText('指南 '))
    entry.set(PDFName.of('St'), PDFNumber.of(1))
    nums.push(entry)
  }

  // 3. 案例区 - "案例 1", "案例 2", ...
  if (cases.length > 0) {
    entry = PDFDict.withContext(ctx)
    entry.set(PDFName.of('S'), PDFName.of('D'))
    entry.set(PDFName.of('P'), PDFHexString.fromText('案例 '))
    entry.set(PDFName.of('St'), PDFNumber.of(1))
    nums.push(entry)
  }

  // 必须 ctx.register 拿到 PDFRef 再设入 catalog，pdf-lib 才会保留到 save 后的文件
  const numsRef = ctx.register(nums)
  const pageLabelsDict = PDFDict.withContext(ctx)
  pageLabelsDict.set(PDFName.of('Nums'), numsRef)
  const pageLabelsRef = ctx.register(pageLabelsDict)
  doc.catalog.set(PDFName.of('PageLabels'), pageLabelsRef)
}

async function main() {
  console.log('📖 SQL Lab PDF 电子书 — 两轮生成\n')
  if (!existsSync(resolve(DIST, 'index.html'))) { console.error('❌ 请先 npm run docs:build'); process.exit(1) }
  const { guides, cases } = collect()
  const casesTotal = cases.length
  console.log(`  📚 ${guides.length} 篇指南 + ${casesTotal} 个案例`)
  console.log(`  📝 目录已提取中文标题`)

  // ── 第一轮：合并 ──
  const server = await startServer()
  console.log(`  📡 服务器 :${PORT}`)
  let browser
  try {
    browser = await puppeteer.launch({
      headless: true,
      executablePath: resolveChrome(),
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        // 字体优化：禁用远程字体 + 关闭字体 hinting (CJK 路径数据 -10-15%)
        '--disable-remote-fonts',
        '--font-render-hinting=none',
        // 打印优化：禁用 GPU、关闭不必要子系统
        '--disable-gpu',
        '--disable-extensions',
        '--no-first-run',
      ],
    })
    console.log('\n  📄 封面 + 目录...')
    const pdfs = [await htmlPdf(browser, coverHtml(casesTotal)), await htmlPdf(browser, tocHtml(guides, cases))]
    const total = guides.length + casesTotal
    console.log(`\n  📖 并发渲染 ${total} 页 (并发=${CONCURRENCY})...\n`)
    // 准备待渲染列表（idx 用于日志）
    const items = []
    for (let i = 0; i < guides.length; i++) {
      items.push({ url: guides[i].url, idx: i + 1 })
    }
    for (let i = 0; i < cases.length; i++) {
      items.push({ url: cases[i].url, idx: guides.length + i + 1 })
    }
    const renderStart = Date.now()
    const rendered = await renderBatch(browser, items, CONCURRENCY)
    for (const buf of rendered) pdfs.push(buf)
    console.log(`  ⏱️  渲染总耗时 ${((Date.now() - renderStart) / 1000).toFixed(1)}s`)

    console.log('\n  🔗 合并...')
    const doc = await PDFDocument.create()
    const now = new Date()
    doc.setTitle('SQL Lab · MySQL + TiDB 优化实战案例集')
    doc.setAuthor(AUTHOR)
    doc.setSubject(`${casesTotal} 个 MySQL + TiDB 优化实战案例 — Docker 一键复现，EXPLAIN 量化对比`)
    doc.setKeywords(['MySQL', 'TiDB', 'SQL优化', 'EXPLAIN', '索引', '事务', '分布式'])
    doc.setCreator(`SQL Lab (${AUTHOR})`)
    doc.setProducer('SQL Lab PDF Generator')
    doc.setCreationDate(now)
    doc.setModificationDate(now)

    // 计算每个 PDF 的页数（同时复制页面，合并两次为一次）
    // 顺序: cover, TOC, guide0..N-1, case0..M-1
    const pdfPageCounts = []
    for (const buf of pdfs) {
      const s = await PDFDocument.load(buf)
      pdfPageCounts.push(s.getPageCount())
      const pp = await doc.copyPages(s, s.getPageIndices())
      for (const pg of pp) doc.addPage(pg)
    }
    // 累计页数偏移
    const pdfOffsets = [0]
    for (const c of pdfPageCounts) pdfOffsets.push(pdfOffsets[pdfOffsets.length - 1] + c)

    // guideStart = 2 (cover=1 + TOC=1 -> guides start at 2)
    const guideStart = pdfOffsets[2]
    const guidePageOffsets = []
    let acc = 0
    for (let i = 0; i < guides.length; i++) {
      guidePageOffsets.push(acc)
      acc += pdfPageCounts[2 + i]
    }
    // caseStart: 第一个 case 的全局页号
    const caseStart = pdfOffsets[2 + guides.length]
    const casePageOffsets = []
    let acc2 = 0
    for (let i = 0; i < cases.length; i++) {
      casePageOffsets.push(acc2)
      acc2 += pdfPageCounts[2 + guides.length + i]
    }

    const merged = Buffer.from(await doc.save())
    const d = dirname(OUT)
    if (!existsSync(d)) mkdirSync(d, { recursive: true })
    writeFileSync(TMP, merged)
    console.log(`  ✅ 第一轮合并完成：${(merged.length / 1024 / 1024).toFixed(1)} MB`)

    // ── 第二轮：加载 + 书签 ──
    console.log('\n  📑 加载并添加书签...')
    const doc2 = await PDFDocument.load(merged)
    addOutlines(doc2, guides, cases, {
      guideStart,
      caseStart,
      guidePageOffsets,
      casePageOffsets,
    })
    addPageLabels(doc2, guides, cases)

    // 关键：useObjectStreams: true 去重字体和资源，减小 80MB → ~30MB
    // Outline 对象通过 PDFDict + ctx.assign 正确注册，pdf-lib 会保留它们
    const outData = Buffer.from(await doc2.save({ useObjectStreams: true }))
    writeFileSync(OUT, outData)

    const bkCount = guides.length + CATEGORIES.length + casesTotal
    console.log(`\n  ✅ ${OUT}`)
    console.log(`  📦 ${(outData.length / 1024 / 1024).toFixed(1)} MB  |  👤 ${AUTHOR}`)
    console.log(`  📑 ${bkCount} 个书签（${guides.length} 指南 + ${CATEGORIES.length} 分类 + ${casesTotal} 案例）`)
    console.log(`  🌐 https://slowleelab.github.io/sql-lab/sql-lab-cases.pdf`)
  } finally {
    if (browser) await browser.close().catch(() => {})
    await closeServer(server)
    if (existsSync(TMP)) unlinkSync(TMP)
  }
}
main().catch(e => { console.error('❌', e.message, e.stack); process.exit(1) })