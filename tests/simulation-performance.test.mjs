import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, resolve } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { readTaskSeriesData, readTaskFlexibility } from '../server/utils/sqlite-reader.ts'
import { createTaskRequestGate } from '../utils/task-refresh.ts'
import { pairTimeSeriesWindow, sliceTimeSeries } from '../utils/time-series-window.ts'
import { downsampleTimeSeries } from '../utils/chart-downsample.ts'

test('committed deltas, overlapping revisions, boundary ranges and old database compatibility', () => {
  const root = mkdtempSync(join(tmpdir(), 'synerroll-sql-test-'))
  const previous = process.env.SYNERROLL_DATA_DIR
  process.env.SYNERROLL_DATA_DIR = root
  mkdirSync(join(root, 'tasks', 'fixture'), { recursive: true })
  const tasks = new DatabaseSync(join(root, 'tasks.db'))
  tasks.exec('CREATE TABLE tasks (id TEXT PRIMARY KEY, layer_id TEXT, extra_json TEXT)')
  tasks.prepare('INSERT INTO tasks VALUES (?,?,?)').run('fixture', '1', JSON.stringify({ flexibility: { enabled: true, layerId: '1' } }))
  const db = new DatabaseSync(join(root, 'tasks', 'fixture', 'timeseries.db'))
  db.exec(`
    PRAGMA journal_mode=WAL;
    CREATE TABLE time_series_meta(id INTEGER PRIMARY KEY, source_id TEXT, var_name TEXT, remark TEXT, layer_id TEXT);
    CREATE TABLE time_series_data(id INTEGER PRIMARY KEY AUTOINCREMENT,series_id INTEGER,ts TEXT,value REAL,ts_min INTEGER);
    CREATE INDEX idx_data_series_tsmin ON time_series_data(series_id,ts_min);
    INSERT INTO time_series_meta VALUES(1,'b_boundary','P','planned','1'),(2,'BUS','E_SHORTAGE','power','1'),(3,'WT','P','power','1');
    INSERT INTO time_series_data(series_id,ts,value,ts_min) VALUES(1,'0:00',10,0),(1,'8760:00',20,525600),(2,'0:00',3,0),(3,'1:00',4,60);
    CREATE TABLE flexibility_period_results(layer_id TEXT,timestamp_minutes INTEGER,direction TEXT,result_json TEXT,revision INTEGER);
    CREATE TABLE flexibility_summary_results(layer_id TEXT,start_minutes INTEGER,result_json TEXT);
    CREATE TABLE task_result_versions(kind TEXT PRIMARY KEY,version INTEGER);
    INSERT INTO task_result_versions VALUES('flexibility',1);
  `)
  const insertFlex = db.prepare('INSERT INTO flexibility_period_results VALUES(?,?,?,?,?)')
  insertFlex.run('1', 0, 'up', JSON.stringify({ timestamp: '0:00', margin: 1 }), 1)
  try {
    const initial = readTaskSeriesData('fixture', { skipBoundary: true, afterId: 0, limit: 1 })
    assert.equal(initial.rows.length, 1)
    assert.equal(initial.rows[0].sourceId, 'BUS', 'SQL wildcard must not hide BUS')
    assert.equal(initial.has_more, true)
    const next = readTaskSeriesData('fixture', { skipBoundary: true, afterId: initial.cursor, limit: 1 })
    assert.equal(next.rows[0].sourceId, 'WT')
    assert.equal(next.has_more, false)
    const cursor = next.cursor
    db.exec('BEGIN IMMEDIATE')
    db.prepare('DELETE FROM time_series_data WHERE series_id=3 AND ts=?').run('1:00')
    db.prepare('INSERT INTO time_series_data(series_id,ts,value,ts_min) VALUES(?,?,?,?)').run(3, '1:00', 99, 60)
    assert.deepEqual(readTaskSeriesData('fixture', { skipBoundary: true, afterId: cursor }).rows, [], 'uncommitted writes must not advance cursor')
    db.exec('COMMIT')
    const delta = readTaskSeriesData('fixture', { skipBoundary: true, afterId: cursor })
    assert.equal(delta.rows.length, 1)
    assert.equal(delta.rows[0].value, 99, 'correction at an old timestamp must be delivered')
    assert.deepEqual(readTaskSeriesData('fixture', { afterId: delta.cursor }).rows, [])
    const boundary = readTaskSeriesData('fixture', { boundaryOnly: true, minMinutes: 0, maxMinutes: 60 })
    assert.deepEqual(boundary.rows.map(row => row.ts), ['0:00'])
    const allFlex = readTaskFlexibility('fixture')
    assert.equal(allFlex.revision, 1)
    assert.equal(allFlex.reset, true)
    assert.equal(allFlex.periods.length, 1)
    assert.deepEqual(readTaskFlexibility('fixture', { afterRevision: 1 }).periods, [])
    db.exec('BEGIN IMMEDIATE')
    db.prepare('UPDATE flexibility_period_results SET result_json=?,revision=2').run(JSON.stringify({ timestamp: '0:00', margin: 42 }))
    db.exec("UPDATE task_result_versions SET version=2 WHERE kind='flexibility'; COMMIT")
    const flexDelta = readTaskFlexibility('fixture', { afterRevision: 1 })
    assert.equal(flexDelta.periods[0].margin, 42)
    assert.equal(flexDelta.reset, false)
    assert.equal(readTaskFlexibility('fixture', { afterRevision: 100 }).reset, true)
    db.exec('DROP TABLE task_result_versions')
    const legacy = readTaskFlexibility('fixture', { afterRevision: 2 })
    assert.equal(legacy.versioned, false)
    assert.equal(legacy.periods.length, 1)
    db.exec('DROP INDEX idx_data_series_tsmin; ALTER TABLE time_series_data DROP COLUMN ts_min')
    assert.deepEqual(readTaskSeriesData('fixture', { boundaryOnly: true, maxMinutes: 60 }).rows.map(row => row.ts), ['0:00'])
  } finally {
    db.close()
    tasks.close()
    if (previous === undefined) delete process.env.SYNERROLL_DATA_DIR
    else process.env.SYNERROLL_DATA_DIR = previous
    assert.equal(dirname(root), resolve(tmpdir()))
    rmSync(root, { recursive: true, force: true })
  }
})

test('one in-flight request per session and retry after rejection', async () => {
  const gate = createTaskRequestGate()
  let resolve
  let calls = 0
  const first = gate.run('task|1', () => { calls++; return new Promise(done => { resolve = done }) })
  const duplicate = gate.run('task|1', async () => { calls++; return 2 })
  await Promise.resolve()
  assert.equal(calls, 1)
  assert.equal(first, duplicate)
  resolve(1)
  assert.equal(await duplicate, 1)
  await assert.rejects(gate.run('task|1', async () => { throw Error('temporary') }))
  assert.equal(await gate.run('task|1', async () => 3), 3)
  assert.equal(await gate.run('task|2', async () => 4), 4)
})

test('half-open chart windows and chronological extrema-preserving sampling', () => {
  const points = [{ ts: '0:00', value: 1 }, { ts: '1:00', value: 2 }, { ts: '8760:00', value: 3 }]
  assert.deepEqual(sliceTimeSeries(points, 60, 525600), [points[1]])
  assert.deepEqual(sliceTimeSeries(points, 0, 1), [points[0]])
  assert.deepEqual(sliceTimeSeries(points, 120, 180), [])
  const large = Array.from({ length: 10000 }, (_, i) => [i, i === 10 ? 1000 : i === 20 ? -1000 : Math.sin(i)])
  const sampled = downsampleTimeSeries(large, 0, 10000, 1200)
  assert(sampled.length <= 1200)
  assert(sampled.some(point => point[1] === 1000))
  assert(sampled.some(point => point[1] === -1000))
  assert(sampled.every((point, i) => i === 0 || point[0] > sampled[i - 1][0]))
  assert.equal(sampled[0][0], 0)
  assert.equal(sampled.at(-1)[0], 9999)
  assert.equal(downsampleTimeSeries(large, 0, 48 * 60), large, 'small windows keep original precision')
})

test('8760-hour chart sampling keeps the complete selected window instead of the yearly prefix', () => {
  const timestamps = Array.from({ length: 8760 }, (_, hour) => `${hour}:00`)
  const values = Array.from({ length: 8760 }, (_, hour) => Math.sin(hour))
  const start = 4380 * 60
  const end = 8760 * 60
  const windowed = pairTimeSeriesWindow(timestamps, values, start, end)
  const sampled = downsampleTimeSeries(windowed, start, end, 1200)

  assert.equal(windowed.length, 4380)
  assert.equal(sampled[0][0], start)
  assert.equal(sampled.at(-1)[0], (8760 - 1) * 60)
  assert(sampled.length <= 1200)
  assert(sampled.every(point => point[0] >= start && point[0] < end))
})
