import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, mkdtempSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { EventEmitter } from 'node:events'
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { pathToFileURL } from 'node:url'
import vm from 'node:vm'

const root = resolve(import.meta.dirname, '..')
const shellRoot = join(root, 'packaging/electron')
const require = createRequire(import.meta.url)
const brand = JSON.parse(readFileSync(join(root, 'config/brand.json')))
const digest = value => createHash('md5').update(value).digest('hex')
test('Legacy offline license algorithm preserves ordinary and special keys without persisting input', () => {
  const sandbox = { module: { exports: {} }, require: name => name === './license-keys.json'
    ? { normal: [digest('ordinary-fixture')], special: [digest('special-fixture')] } : require(name) }
  vm.runInNewContext(readFileSync(join(shellRoot, 'license.cjs'), 'utf8'), sandbox)
  const { verifyLicenseKey } = sandbox.module.exports
  assert(verifyLicenseKey('ordinary-fixture').valid)
  assert.equal(verifyLicenseKey('ordinary-fixture').isSpecial, false)
  assert(verifyLicenseKey('special-fixture').isSpecial)
  for (const key of ['invalid', '', null, {}, 'ordinary-fixture ']) assert.equal(verifyLicenseKey(key).valid, false)
  const legacy = JSON.parse(readFileSync(join(shellRoot, 'license-keys.json')))
  assert.equal(legacy.normal.length, 11)
  assert.equal(legacy.special.length, 2)
  assert([...legacy.normal, ...legacy.special].every(value => /^[a-f0-9]{32}$/.test(value)))
})

async function desktopFixture() {
  const windows = [], handlers = new Map(), listeners = new Map(), launches = [], opened = [], menus = []
  const userRoot = mkdtempSync(join(tmpdir(), 'psfa-shell-'))
  const app = Object.assign(new EventEmitter(), {
    isPackaged: false, setName: value => { app.name = value },
    getPath: () => userRoot, setPath: () => {}, requestSingleInstanceLock: () => true,
    whenReady: () => Promise.resolve(), quit: () => { app.quits = (app.quits || 0) + 1 }
  })
  class Window extends EventEmitter {
    constructor(options) {
      super(); this.options = options; windows.push(this)
      this.webContents = Object.assign(new EventEmitter(), { mainFrame: { url: '' },
        setWindowOpenHandler: handler => { this.openHandler = handler } })
    }
    setMenu(value) { this.menu = value }
    setMenuBarVisibility(value) { this.menuVisible = value }
    isDestroyed() { return Boolean(this.destroyed) }
    isMinimized() { return false }
    isFullScreen() { return Boolean(this.fullscreen) }
    setFullScreen(value) { this.fullscreen = value }
    async loadFile(file) { this.file = file; this.webContents.mainFrame.url = pathToFileURL(file).href }
    async loadURL(url) { this.webContents.mainFrame.url = url }
    setTitle(title) { this.title = title }
    show() { this.shown = true }
    maximize() { this.maximized = true }
    focus() {}
    close() { this.destroyed = true }
    destroy() { this.destroyed = true }
  }
  let port = 51000
  const electron = { app, BrowserWindow: Window, Menu: { setApplicationMenu: value => menus.push(value) },
    ipcMain: { handle: (name, fn) => handlers.set(name, fn), on: (name, fn) => listeners.set(name, fn) },
    dialog: { showErrorBox: (...args) => { throw Error(args.join(': ')) } },
    shell: { openPath: async file => { opened.push(file); return '' } } }
  const localRequire = name => {
    if (name === 'electron') return electron
    if (name === './license.cjs') return { verifyLicenseKey: key => ({ valid: key === 'valid-fixture' }) }
    if (name === './runtime.cjs') return { juliaConfiguration: () => ({ env: {}, args: [], backend: shellRoot, executable: 'julia.exe', cacheMode: 'test', depot: 'test' }) }
    if (name === 'node:fs') return { ...require(name), readFileSync: (file, ...args) => require(name).readFileSync(String(file).endsWith('brand.json') ? join(root, 'config/brand.json') : file, ...args) }
    if (name === 'node:child_process') return { spawn: (file, args) => {
      launches.push({ file, args })
      const child = Object.assign(new EventEmitter(), { pid: 90000 + launches.length, exitCode: null,
        signalCode: null, stdout: new EventEmitter(), stderr: new EventEmitter() })
      if (file.endsWith('taskkill.exe')) setImmediate(() => child.emit('exit', 0))
      return child
    } }
    if (name === 'node:net') return { createServer: () => ({ on() {}, listen(_port, _host, fn) { fn() }, address: () => ({ port: ++port }), close: fn => fn() }) }
    if (name === 'node:http') return { get: (_url, _options, fn) => {
      const request = Object.assign(new EventEmitter(), { destroy() {} })
      queueMicrotask(() => { const response = Object.assign(new EventEmitter(), { statusCode: 200 }); fn(response)
        response.emit('data', JSON.stringify({ status: 'ok', solvers: { HiGHS: true }, data: { ready: true } })); response.emit('end') })
      return request
    } }
    return require(name)
  }
  vm.runInNewContext(readFileSync(join(shellRoot, 'main.js'), 'utf8'), {
    require: localRequire, __dirname: shellRoot, process: { ...process, env: {} },
    URL, setTimeout, setImmediate, console
  })
  await new Promise(resolve => setImmediate(resolve))
  const event = window => ({ sender: window.webContents, senderFrame: window.webContents.mainFrame })
  return { windows, handlers, listeners, launches, opened, menus, app, event, userRoot }
}

test('Desktop license gate starts no services until valid input; branded windows have no menu or devtools', async () => {
  const fixture = await desktopFixture()
  const { windows, handlers, launches, event, menus } = fixture
  const license = windows[0]
  assert(license.file.endsWith('license.html'))
  assert.equal(launches.length, 0)
  assert.equal(menus[0], null)
  assert.equal(license.options.webPreferences.nodeIntegration, false)
  assert.equal(license.options.webPreferences.devTools, false)
  assert.equal(handlers.get('desktop:brand')(event(license)).displayName, brand.displayName)
  assert.throws(() => handlers.get('license:submit')({ sender: {}, senderFrame: {} }, 'valid-fixture'))
  assert.equal(handlers.get('license:submit')(event(license), 'invalid').valid, false)
  assert.equal(launches.length, 0)
  assert.equal(handlers.get('license:submit')(event(license), 'valid-fixture').valid, true)
  await new Promise(resolve => setImmediate(resolve))
  await new Promise(resolve => setImmediate(resolve))
  const main = windows.find(window => window.options.webPreferences.preload.endsWith('preload.js') && !window.options.webPreferences.preload.endsWith('shell-preload.js'))
  assert(main?.shown && main.maximized)
  assert.equal(main.options.title, brand.displayName)
  assert.equal(launches.length, 2)
  assert(windows.every(window => window.menu === null && window.menuVisible === false && window.options.webPreferences.devTools === false))
  let blocked = false
  main.webContents.emit('before-input-event', { preventDefault() { blocked = true } }, { type: 'keyDown', key: 'F11' })
  assert(main.fullscreen && blocked)
  main.webContents.emit('before-input-event', { preventDefault() {} }, { type: 'keyDown', key: 'Escape' })
  assert.equal(main.fullscreen, false)
  await handlers.get('desktop:open-location')(event(main), 'logs')
  assert.equal(fixture.opened[0], join(fixture.userRoot, 'logs'))
  await assert.rejects(handlers.get('desktop:open-location')(event(main), '../../other'))
  await assert.rejects(handlers.get('desktop:open-location')({ sender: {}, senderFrame: {} }, 'logs'))
})

test('Cancel exits before launch; each application start requires a new license entry', async () => {
  const fixture = await desktopFixture()
  fixture.listeners.get('license:cancel')(fixture.event(fixture.windows[0]))
  assert.equal(fixture.app.quits, 1)
  assert.equal(fixture.launches.length, 0)
  const next = await desktopFixture()
  assert(next.windows[0].file.endsWith('license.html'))
  assert.equal(next.launches.length, 0)
  next.app.emit('window-all-closed')
  assert.equal(next.app.quits, 1)
})
