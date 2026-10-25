import { timeLabelToMinutes } from './timeLabel.ts'

const minutesCache = new WeakMap<object, number>()

/** 点对象在收到修正值时会替换，缓存不会把旧时间戳带到新点上。 */
export function pointMinutes(point: { ts: string }): number {
  let value = minutesCache.get(point)
  if (value === undefined) {
    const [hours, minutes] = point.ts.split(':').map(Number)
    value = (hours ?? 0) * 60 + (minutes ?? 0)
    minutesCache.set(point, value)
  }
  return value
}

export function lowerBound<T>(rows: readonly T[], minute: number, getMinute: (row: T) => number): number {
  let lo = 0
  let hi = rows.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (getMinute(rows[mid]!) < minute) lo = mid + 1
    else hi = mid
  }
  return lo
}

export function sliceTimeSeries<T extends { ts: string }>(rows: readonly T[], start: number, end: number): T[] {
  return rows.slice(lowerBound(rows, start, pointMinutes), lowerBound(rows, end, pointMinutes))
}

/** 将平行时间戳/数值数组截取为 [start, end) 内的 ECharts 点。 */
export function pairTimeSeriesWindow(
  timestamps: readonly string[],
  values: readonly number[],
  start: number,
  end: number
): Array<[number, number]> {
  const points: Array<[number, number]> = []
  for (let i = 0; i < timestamps.length; i++) {
    const minute = timeLabelToMinutes(timestamps[i]!)
    if (minute >= start && minute < end) points.push([minute, Number(values[i])])
  }
  return points
}
