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
