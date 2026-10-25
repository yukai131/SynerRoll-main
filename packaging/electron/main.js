const { app, BrowserWindow, Menu, dialog, shell, ipcMain } = require('electron')
const { spawn } = require('node:child_process')
const { pathToFileURL } = require('node:url')
const { verifyLicenseKey } = require('./license.cjs')
const path = require('node:path')
const fs = require('node:fs')
const http = require('node:http')
const net = require('node:net')
const resources = app.isPackaged ? process.resourcesPath : path.resolve(__dirname, '../release-stage')
const payload = path.join(resources, 'app')
const runtime = path.join(resources, 'runtime')
const brand = JSON.parse(fs.readFileSync(path.join(resources, 'config/brand.json'), 'utf8'))
app.setName(brand.productName)
const configuredUserRoot = process.env.SYNERROLL_USER_DATA
  ? path.resolve(process.env.SYNERROLL_USER_DATA)
  : path.join(app.getPath('appData'), brand.productName)
fs.mkdirSync(configuredUserRoot, { recursive: true })
app.setPath('userData', configuredUserRoot)
const userRoot = app.getPath('userData')
const dataDir = path.join(userRoot, 'data')
const logDir = path.join(userRoot, 'logs')
const configPath = path.join(userRoot, 'settings.json')
for (const dir of [dataDir, logDir, path.join(userRoot, 'julia-depot')]) fs.mkdirSync(dir, { recursive: true })
function log(name, message) {
  fs.appendFileSync(path.join(logDir, name), `[${new Date().toISOString()}] ${message}\n`)
}
function loadConfig() {
  const defaults = JSON.parse(fs.readFileSync(path.join(resources, 'config/synerroll.json'), 'utf8'))
  if (!fs.existsSync(configPath)) fs.writeFileSync(configPath, JSON.stringify(defaults, null, 2))
  const saved = JSON.parse(fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, ''))
  return { ...defaults, ...saved, julia: { ...defaults.julia, ...saved.julia }, bff: { ...defaults.bff, ...saved.bff }, ui: { ...defaults.ui, ...saved.ui } }
}
let mainWindow, splash, licenseWindow, config
let authenticated = false
let booting = false
let stopping = false
const children = new Set()
let startup = 0
const displayName = brand.displayName || brand.productName
const shellPage = name => path.join(__dirname, 'ui', name)
function trustedShell(event) {
  return [licenseWindow, splash].some(window => window && !window.isDestroyed()
    && event.sender === window.webContents && event.senderFrame === window.webContents.mainFrame
    && ['license.html', 'startup.html'].some(name => event.senderFrame.url === pathToFileURL(shellPage(name)).href))
}
function configureWindow(window, fullscreen = false) {
  window.setMenu(null)
  window.setMenuBarVisibility(false)
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  window.webContents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return
    if (input.key === 'F11') {
      event.preventDefault()
      if (fullscreen) window.setFullScreen(!window.isFullScreen())
    }
    if (input.key === 'Escape' && window.isFullScreen()) {
      event.preventDefault()
      window.setFullScreen(false)
    }
    if (input.key === 'F12' || ((input.control || input.meta) && input.shift && ['i', 'j', 'c'].includes(input.key.toLowerCase()))) event.preventDefault()
  })
}
const preferences = preload => ({ preload: path.join(__dirname, preload), contextIsolation: true, nodeIntegration: false, sandbox: true, devTools: false })
function launch(label, executable, args, env, cwd) {
  const child = spawn(executable, args, { env: { ...process.env, ...env }, cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
  children.add(child)
  log('launcher.log', `${label} pid=${child.pid} exe=${executable}`)
  child.stdout.on('data', bytes => log(`${label}.log`, bytes.toString().trimEnd()))
  child.stderr.on('data', bytes => log(`${label}.log`, bytes.toString().trimEnd()))
  child.on('error', error => { child.launchError = error; log('launcher.log', `${label}: ${error.message}`) })
  child.on('exit', (code, signal) => {
    log('launcher.log', `${label} exited code=${code} signal=${signal}`)
    children.delete(child)
    if (!stopping && mainWindow) {
      dialog.showErrorBox(`${displayName}服务已停止`, `${label} 意外退出。请重新打开软件。\n日志：${logDir}`)
      app.quit()
    }
  })
  return child
}
async function stopChildren() {
  stopping = true
  await Promise.all([...children].map(child => new Promise(resolve => {
    if (!child.pid) return resolve()
    // /T also terminates capacity-planning workers owned by the HTTP process.
    const killer = spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32/taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' })
    killer.once('exit', resolve)
    killer.once('error', () => { child.kill(); resolve() })
  })))
  children.clear()
}
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => { const port = server.address().port; server.close(() => resolve(port)) })
  })
}
function getJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: 5000 }, res => {
      let body = ''
      res.on('data', chunk => { body += chunk })
      res.on('end', () => {
        try { if (res.statusCode !== 200) throw Error(`HTTP ${res.statusCode}`); resolve(JSON.parse(body)) } catch (error) { reject(error) }
      })
      res.on('error', reject)
    })
    req.on('timeout', () => req.destroy(Error('timeout')))
    req.on('error', reject)
  })
}
async function waitHealthy(url, child, seconds, ready) {
  const deadline = Date.now() + seconds * 1000
  while (Date.now() < deadline) {
    if (stopping) throw Error('启动已取消')
    if (child.launchError) throw child.launchError
    if (child.exitCode !== null || child.signalCode !== null) throw Error(`服务提前退出，请查看 ${logDir}`)
    try { const info = await getJson(url); if (ready(info)) return info } catch {}
    await new Promise(resolve => setTimeout(resolve, 1000))
  }
  throw Error(`服务启动超过 ${seconds} 秒，请查看 ${logDir}`)
}
async function boot() {
  startup = Date.now()
  config = loadConfig()
  const juliaPort = await freePort()
  let bffPort = await freePort()
  while (bffPort === juliaPort) bffPort = await freePort()
  const juliaConfig = require('./runtime.cjs').juliaConfiguration(resources, userRoot)
  const env = juliaConfig.env
  try {
    const prepared = JSON.parse(fs.readFileSync(path.join(userRoot, 'runtime-ready.json'), 'utf8'))
    if (prepared.version === brand.version) env.PSFA_SKIP_STARTUP_WARMUP = '1'
  } catch {}
  const backend = juliaConfig.backend
  log('launcher.log', `Julia cache mode=${juliaConfig.cacheMode} depot=${juliaConfig.depot}`)
  const julia = launch('julia', juliaConfig.executable, [...juliaConfig.args, path.join(backend, 'server.jl')], { ...env, PORT: String(juliaPort) }, backend)
  await waitHealthy(`http://127.0.0.1:${juliaPort}/health`, julia, config.julia.startupTimeoutSec, info => info.status === 'ok' && info.solvers?.HiGHS === true)
  const bff = launch('bff', path.join(runtime, 'node/node.exe'), [path.join(payload, '.output/server/index.mjs')], {
    ...env, PORT: String(bffPort), NITRO_PORT: String(bffPort), HOST: '127.0.0.1', NITRO_HOST: '127.0.0.1',
    JULIA_BACKEND_URL: `http://127.0.0.1:${juliaPort}`, NUXT_PUBLIC_JULIA_WS_BASE: `ws://127.0.0.1:${juliaPort}`, NUXT_PUBLIC_API_BASE: '/api/v1'
  }, payload)
  await waitHealthy(`http://127.0.0.1:${bffPort}/api/v1/health`, bff, config.bff.startupTimeoutSec, info => info.data?.ready === true)
  const origin = `http://127.0.0.1:${bffPort}`
  mainWindow = new BrowserWindow({ width: config.ui.windowWidth, height: config.ui.windowHeight, minWidth: 1024, minHeight: 700, show: false, autoHideMenuBar: true, title: displayName, icon: path.join(resources, 'icon.ico'), webPreferences: preferences('preload.js') })
  configureWindow(mainWindow, true)
  mainWindow.webContents.on('will-navigate', (event, target) => { if (new URL(target).origin !== origin) event.preventDefault() })
  mainWindow.webContents.on('page-title-updated', event => { event.preventDefault(); mainWindow.setTitle(displayName) })
  mainWindow.webContents.on('render-process-gone', (_, details) => log('launcher.log', `renderer gone: ${JSON.stringify(details)}`))
  await mainWindow.loadURL(origin)
  splash?.destroy()
  splash = null
  mainWindow.maximize()
  mainWindow.show()
  fs.writeFileSync(path.join(userRoot, 'session.json'), JSON.stringify({ origin, juliaPort, bffPort, pid: process.pid, juliaPid: julia.pid, bffPid: bff.pid, startupSeconds: (Date.now() - startup) / 1000 }, null, 2))
  log('launcher.log', `ready ${origin} startup=${(Date.now() - startup) / 1000}s`)
}
async function startAuthorizedApplication() {
  try {
    splash = new BrowserWindow({ width: 540, height: 340, show: false, resizable: false, frame: false, title: displayName, icon: path.join(resources, 'icon.ico'), webPreferences: preferences('shell-preload.js') })
    configureWindow(splash)
    await splash.loadFile(shellPage('startup.html'))
    if (stopping) return
    splash.show()
    licenseWindow?.close()
    licenseWindow = null
    await boot()
  } catch (error) {
    if (!stopping) {
      log('launcher.log', error.stack || String(error))
      dialog.showErrorBox(`${displayName}启动失败`, `${error.message}\n\n日志目录：${logDir}`)
      app.quit()
    }
  }
}
async function showLicenseWindow() {
  licenseWindow = new BrowserWindow({ width: 520, height: 460, show: false, resizable: false, frame: true, titleBarStyle: 'hidden', autoHideMenuBar: true, title: `${displayName} - 许可证验证`, icon: path.join(resources, 'icon.ico'), webPreferences: preferences('shell-preload.js') })
  configureWindow(licenseWindow)
  licenseWindow.webContents.on('will-navigate', (event, target) => { if (target !== pathToFileURL(shellPage('license.html')).href) event.preventDefault() })
  await licenseWindow.loadFile(shellPage('license.html'))
  if (!stopping) licenseWindow.show()
}
if (!app.requestSingleInstanceLock()) app.quit()
else {
  ipcMain.handle('desktop:brand', event => {
    if (!trustedShell(event)) throw Error('页面不可访问品牌信息')
    return brand
  })
  ipcMain.handle('license:submit', (event, key) => {
    if (!trustedShell(event) || event.sender !== licenseWindow?.webContents) throw Error('许可证请求来源无效')
    if (booting) return { valid: true }
    const result = verifyLicenseKey(key)
    if (!result.valid) return { valid: false, message: '无效的许可证密钥。' }
    authenticated = true
    booting = true
    setImmediate(startAuthorizedApplication)
    return { valid: true }
  })
  ipcMain.on('license:cancel', event => { if (trustedShell(event)) app.quit() })
  ipcMain.handle('desktop:open-location', async (event, location) => {
    if (!authenticated || !mainWindow || event.sender !== mainWindow.webContents || event.senderFrame !== mainWindow.webContents.mainFrame) throw Error('请求来源无效')
    const locations = { data: dataDir, logs: logDir, settings: configPath }
    if (!Object.hasOwn(locations, location)) throw Error('无效的位置')
    const error = await shell.openPath(locations[location])
    if (error) throw Error(error)
  })
  app.on('second-instance', () => {
    const window = mainWindow || splash || licenseWindow
    if (window && !window.isDestroyed()) { if (window.isMinimized()) window.restore(); window.show(); window.focus() }
  })
  app.whenReady().then(async () => {
    try {
      Menu.setApplicationMenu(null)
      await showLicenseWindow()
    } catch (error) {
      if (!stopping) { log('launcher.log', error.stack || String(error)); dialog.showErrorBox(`${displayName}启动失败`, `${error.message}\n\n日志目录：${logDir}`); app.quit() }
    }
  })
  app.on('window-all-closed', () => app.quit())
  app.on('before-quit', event => {
    if (stopping) return
    event.preventDefault()
    stopChildren().finally(() => app.quit())
  })
}
