/**
 * 结果分析各图共用的显示视窗（日期粗窗 + 精确时刻细窗）。
 * 分钟均为相对仿真起始日的偏移；date* 含结束自然日，内部细窗为半开区间 [start, end)。
 */
export interface ChartDisplayWindow {
  dateStart: number
  dateEnd: number
  start: number
  end: number
}

export type FlexibilityDisplayWindow = ChartDisplayWindow

export function createDisplayWindow(dateStart: number, dateEnd: number): ChartDisplayWindow {
  const start = Math.min(dateStart, dateEnd)
  const end = Math.max(dateStart, dateEnd)
  return { dateStart: start, dateEnd: end, start, end }
}

/** 日期粗窗变更后，细窗重置为该日期窗口全宽（与 BUG-011 交互约定一致）。 */
export function withDateRange(window: ChartDisplayWindow, dateStart: number, dateEnd: number): ChartDisplayWindow {
  const start = Math.min(dateStart, dateEnd)
  const end = Math.max(dateStart, dateEnd)
  return { dateStart: start, dateEnd: end, start, end }
}

/** 细窗微调；不改日期粗窗。 */
export function withRange(window: ChartDisplayWindow, start: number, end: number): ChartDisplayWindow {
  return {
    ...window,
    start: Math.min(start, end),
    end: Math.max(start, end)
  }
}

/**
 * 数据末端前进时同步拉伸视窗：用户原先跟到旧末端则继续跟上，否则只扩日期上界。
 */
export function followDataEnd(window: ChartDisplayWindow, dataEnd: number): ChartDisplayWindow {
  if (!(dataEnd > window.dateEnd)) return window
  const dateEnd = dataEnd
  const end = window.end >= window.dateEnd || window.end < dataEnd ? dataEnd : window.end
  return {
    ...window,
    dateEnd,
    end: Math.max(window.start + 1, end)
  }
}

export function clampDisplayWindow(
  window: ChartDisplayWindow,
  min: number,
  max: number
): ChartDisplayWindow {
  const lo = Math.min(min, max)
  const hi = Math.max(min, max)
  const dateStart = clamp(window.dateStart, lo, hi)
  const dateEnd = clamp(window.dateEnd, dateStart, hi)
  const start = clamp(window.start, dateStart, dateEnd)
  const end = clamp(window.end, start + Number.EPSILON, dateEnd)
  return { dateStart, dateEnd, start, end }
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value))
}
