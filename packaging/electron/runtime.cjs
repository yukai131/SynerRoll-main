const fs = require('node:fs')
const path = require('node:path')

function juliaConfiguration(resources, userRoot) {
  const directory = path.join(userRoot, 'julia-depot')
  fs.mkdirSync(directory, { recursive: true })
  const depot = directory
  const runtime = path.join(resources, 'runtime')
  const backend = path.join(resources, 'app/backend')
  const image = path.join(runtime, 'psfa-sysimage.dll')
  const cacheMode = 'yes'
  return {
    executable: path.join(runtime, 'julia/bin/julia.exe'), backend, cacheMode, depot,
    args: ['--startup-file=no', `--compiled-modules=${cacheMode}`, `--project=${backend}`, ...(fs.existsSync(image) ? [`--sysimage=${image}`] : [])],
    env: {
      SYNERROLL_DATA_DIR: path.join(userRoot, 'data'), SYNERROLL_HOST: '127.0.0.1',
      JULIA_DEPOT_PATH: [depot, path.join(runtime, 'julia-depot'), ''].join(path.delimiter),
      JULIA_PKG_OFFLINE: 'true', JULIA_CPU_TARGET: 'generic', JULIA_NUM_THREADS: '1', JULIA_PKG_PRECOMPILE_AUTO: '0', JULIA_NUM_PRECOMPILE_TASKS: '2'
    }
  }
}

async function migrateLegacyData(userRoot) {
  const legacy = path.join(process.env.APPDATA, 'SynerRoll')
  if (path.resolve(legacy).toLowerCase() === path.resolve(userRoot).toLowerCase()) return
  if (fs.existsSync(path.join(legacy, 'data')) && !fs.existsSync(path.join(userRoot, 'data'))) {
    fs.mkdirSync(userRoot, { recursive: true })
    const source = path.join(legacy, 'data')
    const staging = path.join(userRoot, `migration-${Date.now()}`)
    fs.cpSync(source, staging, { recursive: true, errorOnExist: true, force: false,
      filter: entry => !/\.db(?:-wal|-shm)?$/i.test(entry) })
    // 安装时旧版可能仍在运行；SQLite online backup 会包含已提交的 WAL。
    const { DatabaseSync, backup } = require('node:sqlite')
    async function backupDatabases(directory) {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const original = path.join(directory, entry.name)
        if (entry.isDirectory()) await backupDatabases(original)
        else if (/\.db$/i.test(entry.name)) {
          const destination = path.join(staging, path.relative(source, original))
          const database = new DatabaseSync(original, { readOnly: true })
          try { database.exec('PRAGMA busy_timeout=10000'); await backup(database, destination) }
          finally { database.close() }
        }
      }
    }
    await backupDatabases(source)
    fs.renameSync(staging, path.join(userRoot, 'data'))
    if (fs.existsSync(path.join(legacy, 'settings.json')) && !fs.existsSync(path.join(userRoot, 'settings.json'))) {
      fs.copyFileSync(path.join(legacy, 'settings.json'), path.join(userRoot, 'settings.json'))
    }
  }
}
module.exports = { juliaConfiguration, migrateLegacyData }
