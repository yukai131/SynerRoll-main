export type TaskIndicatorTone = 'blue' | 'red' | 'green'

export interface TaskIndicator {
  tone: TaskIndicatorTone
  blink: boolean
}

export interface TaskStatusLike {
  status: string
  /** ISO 时间串；计算任务为 created_at，容量规划为 createdAt */
  createdAt: string
}

export interface TaskIndicatorVocab {
  /** 求解中（含排队/解析/构建）→ 蓝闪 */
  running: readonly string[]
  /** 报错 → 红 */
  failed: readonly string[]
  /** 已完成 → 绿 */
  completed: readonly string[]
  /** 已取消 → 永不显示 */
  cancelled: readonly string[]
}

export const COMPUTE_TASK_VOCAB: TaskIndicatorVocab = {
  running: ['pending', 'parsing', 'building', 'solving'],
  failed: ['failed'],
  completed: ['completed'],
  cancelled: ['cancelled']
}

export const CAPACITY_TASK_VOCAB: TaskIndicatorVocab = {
  running: ['queued', 'validating', 'clustering', 'optimizing'],
  failed: ['failed'],
  completed: ['completed'],
  cancelled: ['cancelled']
}

const FIVE_MIN_MS = 5 * 60 * 1000

/**
 * 任务状态指示器：
 * 1. 有 running（不限时间）→ 蓝闪（优先级最高）
 * 2. 五分钟内创建且 failed → 红
 * 3. 五分钟内创建且 completed → 绿
 * 4. 取消不显示；五分钟外非 running 不显示
 */
export function resolveTaskIndicator(
  tasks: TaskStatusLike[],
  vocab: TaskIndicatorVocab,
  nowMs: number = Date.now()
): TaskIndicator | null {
  const runningSet = new Set(vocab.running)
  const failedSet = new Set(vocab.failed)
  const completedSet = new Set(vocab.completed)
  const cancelledSet = new Set(vocab.cancelled)

  let hasRunning = false
  let hasRecentFailed = false
  let hasRecentCompleted = false

  for (const task of tasks) {
    const status = task.status
    if (cancelledSet.has(status)) continue

    if (runningSet.has(status)) {
      hasRunning = true
      continue
    }

    const createdMs = Date.parse(task.createdAt)
    const isRecent = Number.isFinite(createdMs) && nowMs - createdMs <= FIVE_MIN_MS
    if (!isRecent) continue

    if (failedSet.has(status)) hasRecentFailed = true
    else if (completedSet.has(status)) hasRecentCompleted = true
  }

  if (hasRunning) return { tone: 'blue', blink: true }
  if (hasRecentFailed) return { tone: 'red', blink: false }
  if (hasRecentCompleted) return { tone: 'green', blink: false }
  return null
}
