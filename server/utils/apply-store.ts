import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import type { CapacityApplyRecord } from '~~/types/capacity-planning'

// C-406 安全应用：应用记录（含撤销/恢复所需的画布前后快照与来源溯源）。
// 独立 JSON 存储（server/data/capacity-applies.json），与项目库同风格串行化写。
const dataDirectory = join(process.cwd(), 'server', 'data')
const dataFile = join(dataDirectory, 'capacity-applies.json')

let applyStoreQueue: Promise<void> = Promise.resolve()

const withApplyLock = async <T>(operation: () => Promise<T>): Promise<T> => {
  const nextOperation = applyStoreQueue.then(operation, operation)
  applyStoreQueue = nextOperation.then(() => undefined, () => undefined)
  return nextOperation
}

const writeAppliesUnlocked = async (records: CapacityApplyRecord[]): Promise<void> => {
  await mkdir(dataDirectory, { recursive: true })
  await writeFile(dataFile, JSON.stringify(records, null, 2), 'utf8')
}

const ensureAppliesUnlocked = async (): Promise<CapacityApplyRecord[]> => {
  await mkdir(dataDirectory, { recursive: true })
  let content: string
  try {
    content = await readFile(dataFile, 'utf8')
  }
  catch (error) {
    const isMissing = typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT'
    if (isMissing) return []
    throw error
  }
  const trimmed = content.trim()
  if (!trimmed) return []
  const parsed: unknown = JSON.parse(trimmed)
  return Array.isArray(parsed) ? (parsed as CapacityApplyRecord[]) : []
}

export const listApplies = async (planningId?: string): Promise<CapacityApplyRecord[]> =>
  withApplyLock(async () => {
    const records = await ensureAppliesUnlocked()
    return planningId ? records.filter(record => record.planningId === planningId) : records
  })

export const getApply = async (applyId: string): Promise<CapacityApplyRecord> =>
  withApplyLock(async () => {
    const records = await ensureAppliesUnlocked()
    const record = records.find(item => item.applyId === applyId)
    if (!record) {
      throw createError({ statusCode: 404, statusMessage: `应用记录不存在: ${applyId}` })
    }
    return record
  })

export const insertApply = async (record: CapacityApplyRecord): Promise<void> =>
  withApplyLock(async () => {
    const records = await ensureAppliesUnlocked()
    await writeAppliesUnlocked([...records, record])
  })

export const updateApply = async (
  applyId: string,
  updater: (record: CapacityApplyRecord) => CapacityApplyRecord
): Promise<CapacityApplyRecord> =>
  withApplyLock(async () => {
    const records = await ensureAppliesUnlocked()
    const index = records.findIndex(item => item.applyId === applyId)
    if (index === -1) {
      throw createError({ statusCode: 404, statusMessage: `应用记录不存在: ${applyId}` })
    }
    const next = updater(records[index]!)
    const nextRecords = [...records]
    nextRecords[index] = next
    await writeAppliesUnlocked(nextRecords)
    return next
  })
