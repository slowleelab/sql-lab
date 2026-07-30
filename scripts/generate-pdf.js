/**
 * generate-pdf.js — SQL Lab 电子书 PDF
 * 封面 · 目录 · 书签 · 作者(李强) · 元数据 · 页眉页脚
 *
 * 两轮生成：
 *   第一轮 — 合并所有页（封面 + 目录 + 指南 + 案例）
 *   第二轮 — 重新加载，添加书签/大纲
 *
 * 关键：pdf-lib 在对象流压缩时丢弃自定义 Outline 对象，
 * 必须使用 useObjectStreams: false 保存。
 */
import { writeFileSync, existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'
import { createServer } from 'http'
import { readFile } from 'fs/promises'
import puppeteer from 'puppeteer'
import { PDFDocument, PDFName, PDFString, PDFDict, PDFNumber, PDFRef } from 'pdf-lib'

const RD = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const DIST = resolve(RD, 'docs/.vitepress/dist')
const OUT = resolve(RD, 'docs/public/sql-lab-cases.pdf')
const TMP = resolve(RD, 'docs/public/.sql-lab-cases-merged.pdf')
const AUTHOR = '李强'
const PORT = 4175

// 将 JS 字符串编码为 PDF UTF-16 BE 字符串（含 BOM 0xFEFF）以正确显示中文
// 关键：必须转义 PDF 字符串中的特殊字符 (\, (, ))
function pdfStr(s) {
  if (s == null) return PDFString.of('')
  // 直接 ASCII 字符可保持原样（但仍需转义 \ ( )）
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
    // 转为 binary string：每个字节 1 个 char (Latin-1)
    raw = buf.toString('binary')
  }
  // 转义 PDF 字符串特殊字符
  // 在 binary string 中，\ 是 0x5C, ( 是 0x28, ) 是 0x29
  // asBytes() 会将 \\ 解释为单个 \，所以需要双重转义
  let escaped = ''
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i]
    if (c === '\\' || c === '(' || c === ')') {
      escaped += '\\' + c
    } else {
      escaped += c
    }
  }
  return PDFString.of(escaped)
}

const CATEGORIES = [
  { d: 'indexing', n: '一、索引设计与失效', s: 1, e: 18 },
  { d: 'query-rewrite', n: '二、查询改写', s: 19, e: 32 },
  { d: 'join', n: '三、JOIN 优化', s: 33, e: 41 },
  { d: 'ddl', n: '四、DDL 与大表', s: 42, e: 51 },
  { d: 'architecture', n: '五、架构级优化', s: 52, e: 62 },
  { d: 'transaction', n: '六、事务与锁', s: 63, e: 71 },
  { d: 'optimizer', n: '七、优化器与 8.0 新特性', s: 72, e: 80 },
  { d: 'tidb', n: '八、TiDB 分布式优化', s: 81, e: 102 },
]

function collect() {
  const guides = [
    { u: '/guide/introduction', t: '项目介绍' },
    { u: '/guide/quick-start', t: '快速开始' },
    { u: '/guide/how-to-read', t: '如何阅读案例' },
  ]
  const cases = []
  for (const c of CATEGORIES) {
    const dir = resolve(DIST, 'cases', c.d)
    if (!existsSync(dir)) continue
    for (const f of readdirSync(dir).filter(x => x.endsWith('.html'))) {
      const slug = f.replace('.html', '')
      const m = slug.match(/^(\d+)/)
      if (!m) continue
      const num = parseInt(m[1], 10)
      if (num >= c.s && num <= c.e) {
        const fp = resolve(dir, f)
        const content = readFileSync(fp, 'utf-8')
        if (content.includes('http-equiv="refresh"')) continue
        if (cases.find(x => x.num === num)) continue
        const tm = content.match(/<title>([^<]+)<\/title>/)
        const title = tm ? tm[1].replace(/\s*\|\s*SQL Lab$/, '').trim() : slug.replace(/^\d+-/, '').replace(/-/g, ' ')
        cases.push({ u: `/cases/${c.d}/${slug}`, num, cat: c.n, slug, title })
      }
    }
  }
  cases.sort((a, b) => a.num - b.num)
  return { guides, cases }
}

function startServer() {
  return new Promise((ok, fail) => {
    const s = createServer(async (req, res) => {
      let url = new URL(req.url, `http://localhost:${PORT}`).pathname
      if (url.startsWith('/sql-lab/')) url = url.slice(9)
      if (!url || url === '/') url = '/index.html'
      if (!url.startsWith('/')) url = '/' + url
      let fp = resolve(DIST, `.${url}`)
      if (!existsSync(fp)) { fp += '.html'; if (!existsSync(fp)) fp = resolve(DIST, `.${url}/index.html`) }
      try {
        const ct = await readFile(fp)
        const ctType = fp.endsWith('.html') ? 'text/html' : fp.endsWith('.js') ? 'text/javascript' : fp.endsWith('.css') ? 'text/css' : 'text/plain'
        res.writeHead(200, { 'Content-Type': ctType })
        res.end(ct)
      } catch { res.writeHead(404); res.end('404') }
    })
    s.listen(PORT, () => ok(s))
    s.on('error', fail)
  })
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
    const full = `http://localhost:${PORT}/sql-lab/${url.replace(/^\//, '')}`
    process.stdout.write(`  [${String(i).padStart(3)}/${t}] ${url.slice(0, 60).padEnd(62)}\r`)
    await p.goto(full, { waitUntil: 'networkidle0', timeout: 30000 })
    await p.evaluate(() => {
      for (const s of '.VPNav,.VPSidebar,.VPLocalNav,.VPFooter,.DocFooter,.edit-link,.prev-next,.VPDocAside,.VPNavScreen,.VPSkipLink'.split(',')) {
        document.querySelectorAll(s).forEach(e => e.remove())
      }
      const d = document.querySelector('.VPDoc')
      if (d) { d.style.padding = '0 36px'; d.style.maxWidth = '100%' }
      const c = document.querySelector('.VPContent')
      if (c) { c.style.paddingLeft = '0'; c.style.paddingRight = '0' }
    })
    await p.evaluate(() => document.fonts.ready)
    const buf = await p.pdf({
      format: 'A4',
      margin: { top: '22mm', bottom: '24mm', left: '18mm', right: '18mm' },
      printBackground: true,
      displayHeaderFooter: true,
      headerTemplate: '<div style="font-size:8px;color:#666;text-align:center;width:100%;padding:6px 0;border-bottom:0.5px solid #ccc;font-family:sans-serif">SQL Lab · MySQL + TiDB 优化实战案例集</div>',
      footerTemplate: '<div style="font-size:8px;color:#999;text-align:center;width:100%;padding:4px 0;font-family:sans-serif">— <span class="pageNumber"></span> —</div>',
    })
    process.stdout.write(`  [${String(i).padStart(3)}/${t}] ✅\n`)
    return buf
  } finally { await p.close() }
}

function coverHtml() {
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
</style></head><body><div class="c"><div class="ic">🐳</div><h1>SQL Lab</h1><div class="sub">MySQL + TiDB</div><div class="st">优化实战案例集</div><div class="dv"></div><div class="info"><span>102 个案例</span><span>8 大场景</span><span>Docker 复现</span><br><span>MySQL 5.7 &amp; 8.0</span><span>TiDB v7.5</span></div><div class="au">${AUTHOR}</div><div class="ft">2026 · https://slowleelab.github.io/sql-lab/</div></div></body></html>`
}

function tocHtml(guides, cases) {
  let rows = ''
  for (const g of guides) rows += `<tr class="gd"><td></td><td>${g.t}</td></tr>`
  let lc = ''
  for (const c of cases) {
    if (c.cat !== lc) { rows += `<tr class="ct"><td colspan="2">${c.cat}</td></tr>`; lc = c.cat }
    rows += `<tr><td class="nm">${String(c.num).padStart(2, '0')}</td><td>${c.title}</td></tr>`
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
 * 使用 PDFDict 对象 + ctx.assign(ref, dict) + useObjectStreams: false
 *
 * 层级: 指南(3) | 分类(8) → 案例(102)
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
  const catRefs = Object.fromEntries(CATEGORIES.map(c => [c.n, ctx.nextRef()]))

  // 按分类分组案例
  const casesByCat = {}
  for (const c of CATEGORIES) casesByCat[c.n] = []
  for (const c of cases) casesByCat[c.cat].push(c)

  // 案例书签 refs
  const caseRefs = {}
  for (const c of CATEGORIES) {
    caseRefs[c.n] = casesByCat[c.n].map(() => ctx.nextRef())
  }

  // 所有顶层书签（指南 + 分类）
  const allTopRefs = [...guideRefs, ...CATEGORIES.map(c => catRefs[c.n])]

  // ── 创建指南书签 ──
  // guides 在合并后的全局起始页: pageMap.guideStart
  // 每个 guide 的首页: guideStart + 各 guide 的累计页数
  for (let i = 0; i < guides.length; i++) {
    const dict = PDFDict.withContext(ctx)
    dict.set(PDFName.of('Title'), pdfStr(guides[i].t))
    dict.set(PDFName.of('Parent'), outlinesRef)
    // Prev: 上一个顶层项（指南或分类）
    if (i > 0) dict.set(PDFName.of('Prev'), guideRefs[i - 1])
    // Next: 下一个顶层项；最后一个指南 → 第一个分类
    if (i < guides.length - 1) {
      dict.set(PDFName.of('Next'), guideRefs[i + 1])
    } else if (CATEGORIES.length > 0) {
      dict.set(PDFName.of('Next'), catRefs[CATEGORIES[0].n])
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
    const catCases = casesByCat[c.n]
    const catRef = catRefs[c.n]
    const childRefs = caseRefs[c.n]

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
    catDict.set(PDFName.of('Title'), pdfStr(c.n))
    catDict.set(PDFName.of('Parent'), outlinesRef)
    // Prev: 上一个分类；第一个分类 → 最后一个指南
    if (ci > 0) {
      catDict.set(PDFName.of('Prev'), catRefs[CATEGORIES[ci - 1].n])
    } else if (guides.length > 0) {
      catDict.set(PDFName.of('Prev'), guideRefs[guides.length - 1])
    }
    // Next: 下一个分类
    if (ci < CATEGORIES.length - 1) catDict.set(PDFName.of('Next'), catRefs[CATEGORIES[ci + 1].n])
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

async function main() {
  console.log('📖 SQL Lab PDF 电子书 — 两轮生成\n')
  if (!existsSync(resolve(DIST, 'index.html'))) { console.error('❌ 请先 npm run docs:build'); process.exit(1) }
  const { guides, cases } = collect()
  console.log(`  📚 ${guides.length} 篇指南 + ${cases.length} 个案例`)
  console.log(`  📝 目录已提取中文标题`)

  // ── 第一轮：合并 ──
  const server = await startServer()
  console.log(`  📡 服务器 :${PORT}`)
  const browser = await puppeteer.launch({ headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', args: ['--no-sandbox'] })
  try {
    console.log('\n  📄 封面 + 目录...')
    const pdfs = [await htmlPdf(browser, coverHtml()), await htmlPdf(browser, tocHtml(guides, cases))]
    const total = guides.length + cases.length
    console.log(`\n  📖 渲染 ${total} 页...\n`)
    for (const g of guides) pdfs.push(await pagePdf(browser, g.u, pdfs.length - 1, total))
    for (let i = 0; i < cases.length; i++) pdfs.push(await pagePdf(browser, cases[i].u, i + 1, cases.length))

    console.log('\n  🔗 合并...')
    const doc = await PDFDocument.create()
    doc.setTitle('SQL Lab · MySQL + TiDB 优化实战案例集')
    doc.setAuthor(AUTHOR)
    doc.setSubject('102 个 MySQL + TiDB 优化实战案例 — Docker 一键复现，EXPLAIN 量化对比')
    doc.setKeywords(['MySQL', 'TiDB', 'SQL优化', 'EXPLAIN', '索引', '事务', '分布式'])
    doc.setCreator(`SQL Lab (${AUTHOR})`)
    doc.setProducer('SQL Lab PDF Generator')

    // 计算每个 PDF 在合并后的页数和偏移（用于书签定位）
    const pdfPageCounts = []
    for (const buf of pdfs) {
      const s = await PDFDocument.load(buf)
      pdfPageCounts.push(s.getPageCount())
    }
    // 顺序: cover, TOC, guide0..N-1, case0..M-1
    // 累计页数偏移
    const pdfOffsets = [0]
    for (const c of pdfPageCounts) pdfOffsets.push(pdfOffsets[pdfOffsets.length - 1] + c)

    // guideStart = 2 (cover=1 + TOC=1 -> guides start at 2)
    const guideStart = pdfOffsets[2] // = 2
    // guidePageOffsets: 每个 guide 自身相对 guideStart 的偏移
    let acc = 0
    const guidePageOffsets = []
    for (let i = 0; i < guides.length; i++) {
      guidePageOffsets.push(acc)
      acc += pdfPageCounts[2 + i]
    }
    // caseStart: 第一个 case 的全局页号
    const caseStart = pdfOffsets[2 + guides.length]
    let acc2 = 0
    const casePageOffsets = []
    for (let i = 0; i < cases.length; i++) {
      casePageOffsets.push(acc2)
      acc2 += pdfPageCounts[2 + guides.length + i]
    }

    for (const buf of pdfs) {
      const s = await PDFDocument.load(buf)
      const pp = await doc.copyPages(s, s.getPageIndices())
      for (const pg of pp) doc.addPage(pg)
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

    // 关键：useObjectStreams: true 去重字体和资源，减小 80MB → ~30MB
    // Outline 对象通过 PDFDict + ctx.assign 正确注册，pdf-lib 会保留它们
    const outData = Buffer.from(await doc2.save({ useObjectStreams: true }))
    writeFileSync(OUT, outData)
    if (existsSync(TMP)) unlinkSync(TMP)

    const bkCount = guides.length + CATEGORIES.length + cases.length
    console.log(`\n  ✅ ${OUT}`)
    console.log(`  📦 ${(outData.length / 1024 / 1024).toFixed(1)} MB  |  👤 ${AUTHOR}`)
    console.log(`  📑 ${bkCount} 个书签（${guides.length} 指南 + ${CATEGORIES.length} 分类 + ${cases.length} 案例）`)
    console.log(`  🌐 https://slowleelab.github.io/sql-lab/sql-lab-cases.pdf`)
  } finally { await browser.close(); server.close() }
}
main().catch(e => { console.error('❌', e.message, e.stack); process.exit(1) })