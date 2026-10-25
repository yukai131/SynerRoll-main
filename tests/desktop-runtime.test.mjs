import test from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
const { juliaConfiguration, migrateLegacyData } = createRequire(import.meta.url)('../packaging/electron/runtime.cjs')

test('PSFA migration snapshots committed WAL without changing legacy databases or replacing existing data', async () => {
  const root = mkdtempSync(join(tmpdir(), 'psfa-migration-'))
  const previous = process.env.APPDATA
  process.env.APPDATA = root
  const legacy = join(root, 'SynerRoll', 'data')
  const destination = join(root, 'PSFA')
  mkdirSync(join(legacy, 'projects', 'one'), { recursive: true })
  writeFileSync(join(legacy, 'projects.json'), '{"name":"旧项目"}')
  const db = new DatabaseSync(join(legacy, 'projects', 'one', 'boundary.db'))
  let migrated
  try {
    db.exec('PRAGMA journal_mode=WAL; CREATE TABLE readings(value INTEGER); INSERT INTO readings VALUES(42)')
    await migrateLegacyData(destination)
    migrated = new DatabaseSync(join(destination, 'data', 'projects', 'one', 'boundary.db'), { readOnly: true })
    assert.equal(migrated.prepare('SELECT value FROM readings').get().value, 42)
    assert.equal(JSON.parse(readFileSync(join(destination, 'data/projects.json'))).name, '旧项目')
    db.exec('INSERT INTO readings VALUES(99)')
    await migrateLegacyData(destination)
    assert.equal(migrated.prepare('SELECT count(*) AS n FROM readings').get().n, 1)
    assert.equal(db.prepare('SELECT count(*) AS n FROM readings').get().n, 2)
    assert(existsSync(join(legacy, 'projects.json')))
  } finally {
    migrated?.close()
    db.close()
    if (previous === undefined) delete process.env.APPDATA
    else process.env.APPDATA = previous
  }
})

test('Installer and launcher share offline Julia configuration and bundled image', () => {
  const root = mkdtempSync(join(tmpdir(), 'psfa-runtime-'))
  mkdirSync(join(root, 'resources/runtime'), { recursive: true })
  writeFileSync(join(root, 'resources/runtime/psfa-sysimage.dll'), '')
  const config = juliaConfiguration(join(root, 'resources'), join(root, 'user'))
  assert(config.args.some(value => value.startsWith('--sysimage=')))
  assert.equal(config.env.JULIA_PKG_OFFLINE, 'true')
  assert.equal(config.env.JULIA_CPU_TARGET, 'generic')
  assert.equal(config.env.SYNERROLL_DATA_DIR, join(root, 'user/data'))
})
