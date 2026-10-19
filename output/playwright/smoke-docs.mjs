import { createRequire } from 'module'
import { pathToFileURL } from 'url'
import path from 'path'

const require = createRequire(import.meta.url)
const pwRoot = 'C:/Users/Administrator/AppData/Local/npm-cache/_npx/31e32ef8478fbf80/node_modules/playwright-core'
const { chromium } = require(pwRoot)

const base = process.env.BASE_URL || 'http://127.0.0.1:3000'

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
  })
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })

  // 1) open project list
  await page.goto(`${base}/project`, { waitUntil: 'networkidle', timeout: 60000 })
  await page.screenshot({ path: 'output/playwright/01-project.png', fullPage: true })

  // try open first project card / open button
  const openBtn = page.locator('button:has-text("打开"), a:has-text("打开"), [title="打开"]').first()
  const card = page.locator('.cursor-pointer, [class*="project"]').first()
  if (await openBtn.count()) {
    await openBtn.click()
  } else if (await card.count()) {
    await card.click()
  } else {
    // try navigate via any project name link
    const any = page.locator('text=项目').first()
    if (await any.count()) await any.click()
  }
  await page.waitForTimeout(2000)
  await page.screenshot({ path: 'output/playwright/02-after-open.png', fullPage: true })

  // If we landed in editor, click 产品文档
  const docsBtn = page.locator('button[title="产品文档"]').first()
  if (await docsBtn.count()) {
    await docsBtn.click()
    await page.waitForTimeout(800)
    await page.screenshot({ path: 'output/playwright/03-docs-panel.png', fullPage: true })

    // switch chapter tabs
    const ch2 = page.locator('button:has-text("第二章")').first()
    if (await ch2.count()) {
      await ch2.click()
      await page.waitForTimeout(400)
      await page.screenshot({ path: 'output/playwright/04-docs-ch2.png', fullPage: true })
    }
    const ch3 = page.locator('button:has-text("第三章")').first()
    if (await ch3.count()) {
      await ch3.click()
      await page.waitForTimeout(400)
      await page.screenshot({ path: 'output/playwright/05-docs-ch3.png', fullPage: true })
    }
    // click a section
    const sec = page.locator('aside button:has-text("3.3")').first()
    if (await sec.count()) {
      await sec.click()
      await page.waitForTimeout(400)
      await page.screenshot({ path: 'output/playwright/06-docs-section.png', fullPage: true })
    }
    console.log('DOCS_OK')
  } else {
    console.log('DOCS_BTN_NOT_FOUND url=' + page.url())
    // dump some text
    console.log(await page.locator('body').innerText().then(t => t.slice(0, 500)))
  }

  await browser.close()
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
