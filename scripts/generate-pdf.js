/**
 * generate-pdf.js — SQL Lab 电子书 PDF
 * 封面 · 目录 · 作者(李强) · 元数据 · 页眉页脚
 */
import { writeFileSync, existsSync, mkdirSync, readdirSync, readFileSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'
import { createServer } from 'http'
import { readFile } from 'fs/promises'
import puppeteer from 'puppeteer'
import { PDFDocument } from 'pdf-lib'

const RD = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const DIST = resolve(RD, 'docs/.vitepress/dist')
const OUT = resolve(RD, 'docs/public/sql-lab-cases.pdf')
const AUTHOR = '李强'
const PORT = 4175

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
        // 跳过重定向页面
        const fp = resolve(dir, f)
        const content = readFileSync(fp, 'utf-8')
        if (content.includes('http-equiv="refresh"')) continue
        // 相同编号只保留第一个（实际案例优先于重定向）
        if (cases.find(x => x.num === num)) continue
        cases.push({ u: `/cases/${c.d}/${slug}`, num, cat: c.n, slug })
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
      let fp = resolve(DIST, `.${url}`)
      if (!existsSync(fp)) { fp += '.html'; if (!existsSync(fp)) fp = resolve(DIST, `.${url}/index.html`) }
      try {
        const ct = await readFile(fp)
        res.writeHead(200, { 'Content-Type': fp.endsWith('.html') ? 'text/html' : fp.endsWith('.js') ? 'text/javascript' : fp.endsWith('.css') ? 'text/css' : 'text/plain' })
        res.end(ct)
      } catch { res.writeHead(404); res.end('404') }
    })
    s.listen(PORT, () => ok(s))
    s.on('error', fail)
  })
}

async function htmlPdf(browser, html) {
  const p = await browser.newPage()
  try { await p.setContent(html, { waitUntil: 'load' }); await p.evaluate(() => document.fonts.ready); return await p.pdf({ format: 'A4', printBackground: true, margin: { top: 0, bottom: 0, left: 0, right: 0 } }) } finally { await p.close() }
}

async function pagePdf(browser, url, i, t) {
  const p = await browser.newPage()
  try {
    const full = `http://localhost:${PORT}/sql-lab/${url.replace(/^\//, '')}`
    process.stdout.write(`  [${String(i).padStart(3)}/${t}] ${url.slice(0, 60).padEnd(62)}\r`)
    await p.goto(full, { waitUntil: 'networkidle0', timeout: 30000 })
    await p.evaluate(() => {
      for (const s of '.VPNav,.VPSidebar,.VPLocalNav,.VPFooter,.DocFooter,.edit-link,.prev-next,.VPDocAside,.VPNavScreen,.VPSkipLink'.split(',')) document.querySelectorAll(s).forEach(e => e.remove())
      const d = document.querySelector('.VPDoc'); if (d) d.style.padding = '0 36px'
      const c = document.querySelector('.VPContent'); if (c) c.style.paddingLeft = '0'
    })
    await p.evaluate(() => document.fonts.ready)
    const buf = await p.pdf({ format: 'A4', margin: { top: '22mm', bottom: '24mm', left: '18mm', right: '18mm' }, printBackground: true, displayHeaderFooter: true, headerTemplate: '<div style="font-size:7px;color:#bbb;text-align:center;width:100%;padding:4px 0;border-bottom:1px solid #eee">SQL Lab · MySQL + TiDB  优化实战案例集</div>', footerTemplate: '<div style="font-size:7px;color:#bbb;text-align:center;width:100%;padding:4px 0;border-top:1px solid #eee">- <span class="pageNumber"></span> -</div>' })
    process.stdout.write(`  [${String(i).padStart(3)}/${t}] ✅\n`)
    return buf
  } finally { await p.close() }
}

function coverHtml() {
  return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;width:210mm;height:297mm;background:linear-gradient(160deg,#0f2b1d 0%,#1e4a30 35%,#2d6b44 65%,#3a8a54 100%);color:#fff}
.c{text-align:center;padding:56px 80px}
.c .ic{font-size:64px;margin-bottom:20px}
.c h1{font-size:54px;font-weight:800;letter-spacing:8px;margin-bottom:12px;text-shadow:0 3px 12px rgba(0,0,0,.25)}
.c .st{font-size:22px;font-weight:300;opacity:.92;margin-bottom:36px;line-height:1.6;letter-spacing:3px}
.c .dv{width:120px;height:2px;background:rgba(255,255,255,.4);margin:0 auto 36px}
.c .info{font-size:14px;opacity:.8;line-height:2;margin-bottom:48px}
.c .info span{margin:0 12px;padding:4px 16px;border:1px solid rgba(255,255,255,.3);border-radius:16px}
.c .au{font-size:26px;font-weight:600;letter-spacing:6px;margin-top:40px}
.c .ft{position:absolute;bottom:32px;left:0;right:0;text-align:center;font-size:11px;opacity:.4;letter-spacing:2px}
</style></head><body><div class="c"><div class="ic">🐳</div><h1>SQL Lab</h1><div class="st">MySQL + TiDB<br>优化实战案例集</div><div class="dv"></div><div class="info"><span>102 个案例</span><span>8 大场景</span><span>Docker 复现</span><br><span>MySQL 5.7 &amp; 8.0</span><span>TiDB v7.5</span></div><div class="au">${AUTHOR}</div><div class="ft">2026 · https://slowleelab.github.io/sql-lab/</div></div></body></html>`
}

function tocHtml(guides, cases) {
  let rows = ''
  for (const g of guides) rows += `<tr class="gd"><td></td><td>${g.t}</td></tr>`
  let lc = ''
  for (const c of cases) {
    if (c.cat !== lc) { rows += `<tr class="ct"><td colspan="2">${c.cat}</td></tr>`; lc = c.cat }
    rows += `<tr><td class="nm">${String(c.num).padStart(2, '0')}</td><td>${c.slug.replace(/^\d+-/, '').replace(/-/g, ' ')}</td></tr>`
  }
  return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;padding:50px 60px;color:#333}
h1{font-size:30px;text-align:center;margin-bottom:36px;padding-bottom:18px;border-bottom:2px solid #3a8a54;letter-spacing:4px}
table{width:100%;border-collapse:collapse;font-size:13px}
tr.gd td{font-weight:600;color:#3a8a54;padding:8px 8px 4px;font-size:15px}
tr.ct td{color:#3a8a54;font-weight:700;padding:14px 8px 4px;font-size:14px;border-top:1px solid #e0e0e0}
td{padding:4px 8px;line-height:1.6;border-bottom:1px dotted #e8e8e8}
td.nm{width:36px;text-align:right;color:#999;padding-right:12px;font-size:11px}
</style></head><body><h1>目 录</h1><table>${rows}</table></body></html>`
}

async function main() {
  console.log('📖 SQL Lab PDF 电子书\n')
  if (!existsSync(resolve(DIST, 'index.html'))) { console.error('❌ 请先 npm run docs:build'); process.exit(1) }
  const { guides, cases } = collect()
  console.log(`  📚 ${guides.length} 前言 + ${cases.length} 案例\n`)
  const server = await startServer()
  console.log(`  📡 :${PORT}`)
  const browser = await puppeteer.launch({ headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', args: ['--no-sandbox'] })
  try {
    console.log('\n  📄 封面 + 📋 目录...')
    const pdfs = [await htmlPdf(browser, coverHtml()), await htmlPdf(browser, tocHtml(guides, cases))]
    const total = guides.length + cases.length
    console.log(`\n  📖 渲染 ${total} 页...\n`)
    for (const g of guides) pdfs.push(await pagePdf(browser, g.u, pdfs.length - 1, total))
    for (let i = 0; i < cases.length; i++) pdfs.push(await pagePdf(browser, cases[i].u, i + 1, cases.length))
    console.log('\n  🔗 合并 + 元数据...')
    const doc = await PDFDocument.create()
    doc.setTitle('SQL Lab · MySQL + TiDB 优化实战案例集')
    doc.setAuthor(AUTHOR)
    doc.setSubject('102 个 MySQL + TiDB 优化实战案例 — Docker 一键复现，EXPLAIN 量化对比')
    doc.setKeywords(['MySQL', 'TiDB', 'SQL优化', 'EXPLAIN', '索引', '事务', '分布式'])
    doc.setCreator(`SQL Lab (${AUTHOR})`)
    doc.setProducer('SQL Lab PDF Generator')
    for (const buf of pdfs) { const s = await PDFDocument.load(buf); const pp = await doc.copyPages(s, s.getPageIndices()); for (const pg of pp) doc.addPage(pg) }
    const outData = Buffer.from(await doc.save())
    const d = dirname(OUT); if (!existsSync(d)) mkdirSync(d, { recursive: true })
    writeFileSync(OUT, outData)
    console.log(`\n  ✅ ${OUT}`)
    console.log(`  📦 ${(outData.length / 1024 / 1024).toFixed(1)} MB  |  👤 ${AUTHOR}`)
    console.log(`  🌐 https://slowleelab.github.io/sql-lab/sql-lab-cases.pdf`)
  } finally { await browser.close(); server.close() }
}
main().catch(e => { console.error('❌', e.message); process.exit(1) })
