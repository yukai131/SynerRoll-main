const DATE_ONLY_PATTERN = /^\d{4}-\d{2}-\d{2}$/
const DAY_MINUTES = 24 * 60

export const DEFAULT_BOUNDARY_START_DATE = '2026-01-01'

const parseDateParts = (value: string): [number, number, number] | null => {
  if (!DATE_ONLY_PATTERN.test(value)) return null
  const [year, month, day] = value.split('-').map(Number)
  if (!year || !month || !day) return null
  const date = new Date(Date.UTC(year, month - 1, day))
  if (
    date.getUTCFullYear() !== year
    || date.getUTCMonth() !== month - 1
    || date.getUTCDate() !== day
  ) return null
  return [year, month, day]
}

export const isDateOnly = (value: string | null | undefined): value is string =>
  Boolean(value && parseDateParts(value))

export const dateOnlyToUtcMilliseconds = (value: string): number | null => {
  const parts = parseDateParts(value)
  return parts ? Date.UTC(parts[0], parts[1] - 1, parts[2]) : null
}

export const addCalendarDays = (value: string, days: number): string => {
  const milliseconds = dateOnlyToUtcMilliseconds(value)
  if (milliseconds === null) return ''
  return new Date(milliseconds + Math.trunc(days) * DAY_MINUTES * 60_000)
    .toISOString()
    .slice(0, 10)
}

export const inclusiveCalendarDayCount = (startDate: string, endDate: string): number | null => {
  const start = dateOnlyToUtcMilliseconds(startDate)
  const end = dateOnlyToUtcMilliseconds(endDate)
  if (start === null || end === null || end < start) return null
  return Math.floor((end - start) / (DAY_MINUTES * 60_000)) + 1
}

export const deriveCalendarEndDate = (startDate: string, dayCount: number): string =>
  dayCount > 0 ? addCalendarDays(startDate, dayCount - 1) : ''

export const calendarDateToMinuteOffset = (startDate: string, value: string): number | null => {
  const start = dateOnlyToUtcMilliseconds(startDate)
  const date = dateOnlyToUtcMilliseconds(value)
  if (start === null || date === null) return null
  return Math.floor((date - start) / 60_000)
}

export const calendarMinuteToDateOnly = (startDate: string, minute: number): string =>
  addCalendarDays(startDate, Math.floor(Math.max(0, minute) / DAY_MINUTES))

export const formatCalendarMinute = (startDate: string | null | undefined, minute: number): string => {
  if (!startDate || !isDateOnly(startDate)) {
    const safeMinute = Math.max(0, Math.round(minute))
    return `${Math.floor(safeMinute / 60)}:${String(safeMinute % 60).padStart(2, '0')}`
  }
  const start = dateOnlyToUtcMilliseconds(startDate)!
  const date = new Date(start + Math.max(0, minute) * 60_000)
  const month = date.getUTCMonth() + 1
  const day = date.getUTCDate()
  const hour = String(date.getUTCHours()).padStart(2, '0')
  const minutePart = String(date.getUTCMinutes()).padStart(2, '0')
  return `${month}月${day}日 ${hour}:${minutePart}`
}

export const CALENDAR_DAY_MINUTES = DAY_MINUTES
