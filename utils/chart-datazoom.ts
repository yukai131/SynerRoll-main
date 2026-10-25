/**
 * ECharts dataZoom 时间窗工具。
 * 只替换 DualRangeSlider / PrimaryDualRangeSlider 的 UI，
 * 分钟制 displayWindow 状态机与 downsampleTimeSeries 抽稀逻辑保持不变。
 */

export interface ZoomPercentWindow {
  start: number
  end: number
}

export interface MinutesWindow {
  start: number
  end: number
}

/** 分钟窗 → dataZoom 百分比（相对 domain） */
export function minutesToZoomPercent(
  win: MinutesWindow,
  domainStart: number,
  domainEnd: number
): ZoomPercentWindow {
  const span = Math.max(1e-6, domainEnd - domainStart)
  const start = ((win.start - domainStart) / span) * 100
  const end = ((win.end - domainStart) / span) * 100
  return {
    start: clampPercent(Math.min(start, end)),
    end: clampPercent(Math.max(start, end))
  }
}

/** dataZoom 百分比 → 分钟窗 */
export function zoomPercentToMinutes(
  zoom: ZoomPercentWindow,
  domainStart: number,
  domainEnd: number
): MinutesWindow {
  const span = Math.max(1e-6, domainEnd - domainStart)
  const start = domainStart + (clampPercent(zoom.start) / 100) * span
  const end = domainStart + (clampPercent(zoom.end) / 100) * span
  return {
    start: Math.min(start, end),
    end: Math.max(start, end)
  }
}

function clampPercent(value: number): number {
  if (!Number.isFinite(value)) return 0
  return Math.min(100, Math.max(0, value))
}

/** 与容量规划 Step2 一致的 dataZoom（滚轮 + 底部滑条） */
export function createTimeSeriesDataZoom(zoom: ZoomPercentWindow) {
  return [
    {
      type: 'inside' as const,
      start: zoom.start,
      end: zoom.end,
      filterMode: 'none' as const,
      zoomOnMouseWheel: true,
      moveOnMouseWheel: true,
      moveOnMouseMove: true
    },
    {
      type: 'slider' as const,
      start: zoom.start,
      end: zoom.end,
      filterMode: 'none' as const,
      height: 18,
      bottom: 12,
      showDetail: true,
      showDataShadow: true
    }
  ]
}

/**
 * 从 ECharts dataZoom 事件/配置里读出百分比窗。
 * 兼容 `batch` 与单条 dataZoom。
 */
export function readZoomPercentFromEvent(params: unknown): ZoomPercentWindow | null {
  const raw = params as { batch?: Array<{ start?: number; end?: number }> } | { start?: number; end?: number } | null
  if (!raw) return null
  if (Array.isArray((raw as { batch?: unknown }).batch)) {
    const item = (raw as { batch: Array<{ start?: number; end?: number }> }).batch[0]
    if (!item || item.start === undefined || item.end === undefined) return null
    return { start: clampPercent(item.start), end: clampPercent(item.end) }
  }
  const single = raw as { start?: number; end?: number }
  if (single.start === undefined || single.end === undefined) return null
  return { start: clampPercent(single.start), end: clampPercent(single.end) }
}

export function readZoomPercentFromOption(option: unknown): ZoomPercentWindow | null {
  const raw = option as { dataZoom?: Array<{ start?: number; end?: number }> } | null
  const dz = raw?.dataZoom?.[0]
  if (!dz || dz.start === undefined || dz.end === undefined) return null
  return { start: clampPercent(dz.start), end: clampPercent(dz.end) }
}

/** 数值近似相等，避免多图同步时来回 emit */
export function nearlyEqualZoom(a: ZoomPercentWindow, b: ZoomPercentWindow, eps = 0.05): boolean {
  return Math.abs(a.start - b.start) < eps && Math.abs(a.end - b.end) < eps
}

export function nearlyEqualMinutes(a: MinutesWindow, b: MinutesWindow, eps = 1): boolean {
  return Math.abs(a.start - b.start) < eps && Math.abs(a.end - b.end) < eps
}
