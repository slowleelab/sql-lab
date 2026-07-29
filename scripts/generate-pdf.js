/**
 * generate-pdf.js — 将 VitePress 文档站渲染为单个 PDF
 *
 * 用法:
 *   npm run docs:build   # 先构建
 *   npm run docs:pdf     # 再生成 PDF
 *
 * 输出: docs/public/sql-lab-cases.pdf
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'
import { createServer } from 'http'
import { readFile } from 'fs/promises'
import puppeteer from 'puppeteer'
import { PDFDocument } from 'pdf-lib'

const __dirname = dirname(fileURLToPath(import.meta.url))
const PROJECT_ROOT = resolve(__dirname, '..')
const DIST_DIR = resolve(PROJECT_ROOT, 'docs/.vitepress/dist')
const OUTPUT_FILE = resolve(PROJECT_ROOT, 'docs/public/sql-lab-cases.pdf')
const BASE = '/sql-lab/'
const PORT = 4173

// ── 收集所有页面 URL ──
function collectUrls() {
  const guideUrls = [
    '/guide/introduction',
    '/guide/quick-start',
    '/guide/how-to-read',
  ]

  const cats = ['indexing', 'query-rewrite', 'join', 'ddl',
    'architecture', 'transaction', 'optimizer', 'tidb']

  const urls = [...guideUrls]
  for (const cat of cats) {
    const d = resolve(DIST_DIR, 'cases', cat)
    if (!existsSync(d)) continue
    for (const f of readdirSync(d)) {
      if (f.endsWith('.html')) {
        urls.push(`/cases/${cat}/${f.replace('.html', '')}`)
      }
    }
  }
  return urls
}

// ── VitePress 静态文件服务器 ──
function startServer() {
  return new Promise((resolvePromise, reject) => {
    const server = createServer(async (req, res) => {
      let url = new URL(req.url, `http://localhost:${PORT}`).pathname
      if (url.startsWith(BASE)) url = url.slice(BASE.length - 1)
      if (url === '' || url === '/') url = '/index.html'

      let filePath = resolve(DIST_DIR, `.${url}`)
      if (!existsSync(filePath)) filePath = `${filePath}.html`
      if (!existsSync(filePath)) filePath = resolve(DIST_DIR, `.${url}/index.html`)

      try {
        const content = await readFile(filePath)
        const ext = filePath.endsWith('.html') ? 'text/html'
          : filePath.endsWith('.js') ? 'application/javascript'
          : filePath.endsWith('.css') ? 'text/css'
          : filePath.endsWith('.svg') ? 'image/svg+xml'
          : filePath.endsWith('.json') ? 'application/json'
          : 'application/octet-stream'
        res.writeHead(200, { 'Content-Type': ext })
        res.end(content)
      } catch {
        res.writeHead(404)
        res.end('Not Found')
      }
    })

    server.listen(PORT, () => {
      console.log(`  📡 http://localhost:${PORT}${BASE}`)
      resolvePromise(server)
    })
    server.on('error', reject)
  })
}

// ── 渲染单页为 PDF Buffer ──
async function renderPage(browser, url, index, total) {
  const page = await browser.newPage()
  try {
    const fullUrl = `http://localhost:${PORT}${BASE}${url.replace(/^\//, '')}`
    process.stdout.write(`  [${String(index).padStart(3)}/${total}] ${fullUrl} `.padEnd(80) + '\r')

    await page.goto(fullUrl, { waitUntil: 'networkidle0', timeout: 30000 })

    // 移除导航栏、侧边栏、页脚
    await page.evaluate(() => {
      const remove = sel => document.querySelectorAll(sel).forEach(e => e.remove())
      remove('.VPNav')
      remove('.VPSidebar')
      remove('.VPLocalNav')
      remove('.VPFooter')
      remove('.DocFooter')
      remove('.edit-link')
      remove('.prev-next')
      remove('.VPDocAside')
      remove('.VPNavScreen')
    })

    await page.evaluate(() => document.fonts.ready)

    const pdfBuf = await page.pdf({
      format: 'A4',
      margin: { top: '20mm', bottom: '22mm', left: '18mm', right: '18mm' },
      printBackground: true,
      displayHeaderFooter: true,
      headerTemplate: '<div style="font-size:8px;color:#999;text-align:center;width:100%;padding:4px 0;border-bottom:1px solid #e8e8e8">SQL Lab · MySQL + TiDB 优化实战案例集</div>',
      footerTemplate: '<div style="font-size:8px;color:#999;text-align:center;width:100%;padding:4px 0;border-top:1px solid #e8e8e8"><span class="pageNumber"></span> / <span class="totalPages"></span></div>',
    })

    process.stdout.write(`  [${String(index).padStart(3)}/${total}] ✅ ${url}\n`)
    return pdfBuf
  } finally {
    await page.close()
  }
}

// ── 合并 PDF ──
async function mergePdfs(pdfBuffers) {
  const merged = await PDFDocument.create()
  for (const buf of pdfBuffers) {
    const doc = await PDFDocument.load(buf)
    const pages = await merged.copyPages(doc, doc.getPageIndices())
    pages.forEach(p => merged.addPage(p))
  }
  return Buffer.from(await merged.save())
}

// ── 主流程 ──
async function main() {
  console.log('📄 SQL Lab PDF Generator\n')

  if (!existsSync(resolve(DIST_DIR, 'index.html'))) {
    console.error('❌ 未找到构建产物，请先运行: npm run docs:build')
    process.exit(1)
  }

  const urls = collectUrls()
  console.log(`  📚 ${urls.length} 个页面 (3 指南 + ${urls.length - 3} 案例)\n`)

  const server = await startServer()
  console.log('  🚀 Headless Chrome...')
  const browser = await puppeteer.launch({
    headless: true,
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  })

  try {
    console.log('  📖 渲染页面...\n')
    const pdfs = []
    for (let i = 0; i < urls.length; i++) {
      const buf = await renderPage(browser, urls[i], i + 1, urls.length)
      pdfs.push(buf)
    }

    console.log('\n  🔗 合并 PDF...')
    const merged = await mergePdfs(pdfs)
    const outDir = dirname(OUTPUT_FILE)
    if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true })
    writeFileSync(OUTPUT_FILE, merged)

    const sizeMB = (merged.length / 1024 / 1024).toFixed(2)
    console.log(`\n  ✅ docs/public/sql-lab-cases.pdf`)
    console.log(`  📦 ${sizeMB} MB | 📄 ${urls.length}+ 页`)
    console.log(`  🌐 https://slowleelab.github.io/sql-lab/sql-lab-cases.pdf`)
  } finally {
    await browser.close()
    server.close()
  }
}

main().catch(err => {
  console.error('❌', err.message)
  process.exit(1)
})
