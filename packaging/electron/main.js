/**
 * SynerRoll Electron 主进程
 * 职责：读配置 → 拉起 Julia + Nuxt BFF → 健康检查 → 开窗 → 托盘 → 优雅退出
 */
const { app, BrowserWindow, Tray, Menu, dialog, shell } = require('electron')
const { spawn } = require('child_process')
const path = require('path')
const fs = require('fs')
const http = require('http')
const net = require('net')

// ── 路径 ──────────────────────────────────────────────
const ROOT = path.resolve(__dirname)
const CONFIG_PATH = path.join(ROOT, 'config', 'synerroll.json')
const RUNTIME_DIR = path.join(ROOT, 'runtime')
const APP_DIR = path.join(ROOT, 'app')

// ── 配置 ──────────────────────────────────────────────
function loadConfig() {
  const defaults = {
    version: 1,
    juliaPort: 8080,
    bffPort: 3000,
    host: '127.0.0.1',
    solver: 'HiGHS',
    dataDir: 'data',
    logDir: 'logs',
    julia: { heapSizeHintMB: 0, startupTimeoutSec: 120 },
    bff: { startupTimeoutSec: 60 },
    ui: { openDevTools: false, windowWidth: 1440, windowHeight: 900 }
  }
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'))
    return {
      ...defaults,
      ...raw,
      julia: { ...defaults.julia, ...(raw.julia || {}) },
      bff: { ...defaults.bff, ...(raw.bff || {}) },
      ui: { ...defaults.ui, ...(raw.ui || {}) }
    }
  } catch {
    return defaults
  }
}

const config = loadConfig()
const dataDir = path.isAbsolute(config.dataDir) ? config.dataDir : path.join(ROOT, config.dataDir)
const logDir = path.isAbsolute(config.logDir) ? config.logDir : path.join(ROOT, config.logDir)

// ── 日志 ──────────────────────────────────────────────
function ensureDirs() {
  for (const d of [
    dataDir,
    logDir,
    path.join(dataDir, 'projects'),
    path.join(dataDir, 'tasks'),
    path.join(dataDir, 'licenses')
  ]) {
    try { fs.mkdirSync(d, { recursive: true }) } catch { /* ignore */ }
  }
}

function appendLog(name, line) {
  try {
    fs.appendFileSync(
      path.join(logDir, name),
      `[${new Date().toISOString()}] ${line}\n`
    )
  } catch (e) {
    console.error('[LOGFAIL]', name, e.message)
  }
}

// ── 端口 ──────────────────────────────────────────────
function isPortFree(port, host = '127.0.0.1') {
  return new Promise((resolve) => {
    const srv = net.createServer()
    srv.once('error', () => resolve(false))
    srv.once('listening', () => { srv.close(); resolve(true) })
    srv.listen(port, host)
  })
}

async function pickPort(preferred, host) {
  for (let p = preferred; p < preferred + 20; p++) {
    if (await isPortFree(p, host)) return p
  }
  throw new Error(`端口 ${preferred}–${preferred + 19} 均被占用`)
}

// ── 健康检查 ──────────────────────────────────────────
function httpGet(url, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      let body = ''
      res.on('data', (c) => (body += c))
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(body) }) }
        catch { resolve({ status: res.statusCode, body }) }
      })
    })
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')) })
    req.on('error', reject)
  })
}

async function waitForHealth(url, timeoutSec, label, onTick) {
  const deadline = Date.now() + timeoutSec * 1000
  let attempt = 0
  while (Date.now() < deadline) {
    attempt++
    try {
      const r = await httpGet(url, 3000)
      if (r.status === 200 && (r.body?.status === 'ok' || r.body?.data?.ready === true || r.body?.success === true)) {
        return r.body
      }
    } catch { /* not ready */ }
    if (onTick) onTick(attempt, Math.ceil((deadline - Date.now()) / 1000))
    await new Promise((r) => setTimeout(r, 1500))
  }
  throw new Error(`${label} 在 ${timeoutSec}s 内未就绪: ${url}`)
}

// ── 子进程 ────────────────────────────────────────────
let juliaProc = null
let bffProc = null

function startJulia(port) {
  const juliaExe = path.join(RUNTIME_DIR, 'julia', 'bin', 'julia.exe')
  const backendDir = path.join(APP_DIR, 'backend')
  const depot = path.join(RUNTIME_DIR, 'julia-depot')
  const serverScript = path.join(backendDir, 'server.jl')

  const env = {
    ...process.env,
    PORT: String(port),
    JULIA_DEPOT_PATH: depot,
    JULIA_PROJECT: backendDir,
    SYNERROLL_DATA_DIR: dataDir,
    SYNERROLL_DEFAULT_SOLVER: config.solver
  }
  if (config.julia.heapSizeHintMB > 0) {
    env.JULIA_HEAP_SIZE_HINT = `${config.julia.heapSizeHintMB}M`
  }

  appendLog('launcher.log', `starting Julia: ${juliaExe} --project=${backendDir}`)
  juliaProc = spawn(juliaExe, [`--project=${backendDir}`, serverScript], {
    env,
    cwd: backendDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true
  })
  juliaProc.stdout.on('data', (d) => appendLog('julia.log', d.toString().trimEnd()))
  juliaProc.stderr.on('data', (d) => appendLog('julia.log', d.toString().trimEnd()))
  juliaProc.on('exit', (code, signal) => {
    appendLog('launcher.log', `Julia exited code=${code} signal=${signal}`)
    juliaProc = null
  })
  return juliaProc
}

function startBff(juliaPort, bffPort) {
  const entry = path.join(APP_DIR, '.output', 'server', 'index.mjs')
  const env = {
    ...process.env,
    PORT: String(bffPort),
    NITRO_PORT: String(bffPort),
    HOST: config.host,
    NITRO_HOST: config.host,
    JULIA_BACKEND_URL: `http://${config.host}:${juliaPort}`,
    NUXT_PUBLIC_JULIA_WS_BASE: `ws://${config.host}:${juliaPort}`,
    NUXT_PUBLIC_API_BASE: '/api/v1'
  }

  appendLog('launcher.log', `starting BFF: node ${entry} (port ${bffPort})`)
  bffProc = spawn(process.execPath, [entry], {
    env,
    cwd: APP_DIR,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true
  })
  bffProc.stdout.on('data', (d) => appendLog('bff.log', d.toString().trimEnd()))
  bffProc.stderr.on('data', (d) => appendLog('bff.log', d.toString().trimEnd()))
  bffProc.on('exit', (code, signal) => {
    appendLog('launcher.log', `BFF exited code=${code} signal=${signal}`)
    bffProc = null
  })
  return bffProc
}

function stopChildren() {
  for (const p of [juliaProc, bffProc]) {
    if (p && !p.killed) {
      try { p.kill('SIGTERM') } catch { /* ignore */ }
    }
  }
  juliaProc = null
  bffProc = null
}

// ── 窗口 / 托盘 ───────────────────────────────────────
let mainWindow = null
let tray = null
let splash = null

function createSplash() {
  splash = new BrowserWindow({
    width: 480,
    height: 280,
    frame: false,
    resizable: false,
    alwaysOnTop: true,
    webPreferences: { nodeIntegration: false }
  })
  const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
    body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:#0f172a;color:#e2e8f0;
         display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh}
    h1{font-size:20px;font-weight:600;margin:0 0 8px}
    p{font-size:13px;color:#94a3b8;margin:0}
    .bar{width:220px;height:4px;background:#1e293b;border-radius:2px;margin-top:20px;overflow:hidden}
    .fill{height:100%;width:30%;background:#38bdf8;border-radius:2px;animation:slide 1.2s ease-in-out infinite}
    @keyframes slide{0%{margin-left:-30%}100%{margin-left:100%}}
  </style></head><body>
    <h1>SynerRoll</h1>
    <p id="msg">正在启动计算服务…</p>
    <div class="bar"><div class="fill"></div></div>
  </body></html>`
  splash.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html))
}

function updateSplash(msg) {
  if (splash && !splash.isDestroyed()) {
    splash.webContents
      .executeJavaScript(`document.getElementById('msg').textContent=${JSON.stringify(msg)}`)
      .catch(() => {})
  }
}

function closeSplash() {
  if (splash && !splash.isDestroyed()) splash.close()
  splash = null
}

function createMainWindow(bffPort) {
  mainWindow = new BrowserWindow({
    width: config.ui.windowWidth,
    height: config.ui.windowHeight,
    minWidth: 1024,
    minHeight: 700,
    show: false,
    title: 'SynerRoll',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  })

  mainWindow.once('ready-to-show', () => {
    closeSplash()
    mainWindow.show()
    if (config.ui.openDevTools) mainWindow.webContents.openDevTools({ mode: 'detach' })
  })

  mainWindow.on('close', (e) => {
    if (!app.isQuitting) {
      e.preventDefault()
      mainWindow.hide()
    }
  })

  mainWindow.loadURL(`http://${config.host}:${bffPort}/`)
}

function createTray() {
  // 图标可选：缺失时用空 Tray（不阻断启动）
  try {
    const iconPath = path.join(ROOT, 'resources', 'icon.ico')
    if (fs.existsSync(iconPath)) {
      tray = new Tray(iconPath)
    }
  } catch (e) {
    appendLog('launcher.log', `tray icon skip: ${e.message}`)
  }

  const menu = Menu.buildFromTemplate([
    { label: '打开 SynerRoll', click: () => { if (mainWindow) { mainWindow.show(); mainWindow.focus() } } },
    { type: 'separator' },
    { label: '查看日志', click: () => shell.openPath(logDir) },
    {
      label: '导出诊断包',
      click: () => {
        try {
          const { execSync } = require('child_process')
          const stamp = new Date().toISOString().replace(/[:.]/g, '-')
          const zipPath = path.join(logDir, `diagnostics-${stamp}.zip`)
          execSync(`powershell -Command "Compress-Archive -Path '${logDir}\\*' -DestinationPath '${zipPath}' -Force"`, { timeout: 15000 })
          dialog.showMessageBox({ type: 'info', title: '诊断包', message: `已生成：\n${zipPath}` })
        } catch (e) {
          dialog.showErrorBox('导出失败', e.message)
        }
      }
    },
    {
      label: '重启计算引擎',
      click: async () => {
        stopChildren()
        try {
          await bootServices()
          if (mainWindow) mainWindow.loadURL(`http://${config.host}:${config.bffPort}/`)
        } catch (err) {
          dialog.showErrorBox('重启失败', String(err.message || err))
        }
      }
    },
    { type: 'separator' },
    { label: '退出', click: () => { app.isQuitting = true; stopChildren(); app.quit() } }
  ])

  if (tray) {
    tray.setToolTip('SynerRoll')
    tray.setContextMenu(menu)
    tray.on('double-click', () => { if (mainWindow) { mainWindow.show(); mainWindow.focus() } })
  }
}

// ── 启动流程 ──────────────────────────────────────────
async function bootServices() {
  ensureDirs()

  const juliaPort = await pickPort(config.juliaPort, config.host)
  const bffPort = await pickPort(config.bffPort, config.host)
  config.juliaPort = juliaPort
  config.bffPort = bffPort
  appendLog('launcher.log', `ports: julia=${juliaPort} bff=${bffPort} host=${config.host}`)

  updateSplash('正在启动 Julia 计算引擎…')
  startJulia(juliaPort)
  await waitForHealth(
    `http://${config.host}:${juliaPort}/health`,
    config.julia.startupTimeoutSec,
    'Julia 后端',
    (a, left) => updateSplash(`等待计算引擎… (${left}s)`)
  )
  appendLog('launcher.log', 'Julia healthy')

  updateSplash('正在启动应用服务…')
  startBff(juliaPort, bffPort)
  await waitForHealth(
    `http://${config.host}:${bffPort}/api/v1/health`,
    config.bff.startupTimeoutSec,
    'BFF',
    (a, left) => updateSplash(`等待应用服务… (${left}s)`)
  )
  appendLog('launcher.log', 'BFF healthy')

  return bffPort
}

// ── App 生命周期 ──────────────────────────────────────
const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.show()
      mainWindow.focus()
    }
  })

  app.whenReady().then(async () => {
    appendLog('launcher.log', 'app ready')
    try { createSplash() } catch (e) { appendLog('launcher.log', `splash err: ${e.message}`) }
    try { createTray() } catch (e) { appendLog('launcher.log', `tray err: ${e.message}`) }
    try {
      const bffPort = await bootServices()
      createMainWindow(bffPort)
    } catch (err) {
      closeSplash()
      appendLog('launcher.log', `boot failed: ${err.message || err}`)
      dialog.showErrorBox(
        'SynerRoll 启动失败',
        `${err.message || err}\n\n请查看日志目录：\n${logDir}`
      )
      stopChildren()
      app.quit()
    }
  })

  app.on('before-quit', () => { app.isQuitting = true; stopChildren() })
  app.on('window-all-closed', () => { /* keep tray alive */ })

  process.on('uncaughtException', (err) => {
    appendLog('launcher.log', `uncaught: ${err.stack || err}`)
  })
}
