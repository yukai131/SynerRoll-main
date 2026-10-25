/**
 * 多图共享时间窗 + ECharts dataZoom。
 * 保留原 displayWindow 状态机与 downsampleTimeSeries 抽稀；
 * 仅把 DualRangeSlider/PrimaryDualRangeSlider 换成图内 dataZoom。
 */
import type { ECharts } from 'echarts'
import {
  createTimeSeriesDataZoom,
  minutesToZoomPercent,
  nearlyEqualMinutes,
  nearlyEqualZoom,
  readZoomPercentFromEvent,
  readZoomPercentFromOption,
  zoomPercentToMinutes
} from '~~/utils/chart-datazoom'

export interface DataZoomDomain {
  start: number
  end: number
}

export function useSharedDataZoom(options: {
  /** 图表实例（可为 ref/getter） */
  getChart: () => ECharts | null
  /** 同组其他需要联动的图（如同组件内贡献图） */
  getPeerCharts?: () => Array<ECharts | null>
  /** 当前共享细窗（分钟） */
  getWindow: () => { start: number; end: number }
  /** 细窗所属粗窗定义域（分钟） */
  getDomain: () => DataZoomDomain
  /** 用户缩放后回写共享细窗 */
  onWindowChange: (win: { start: number; end: number }) => void
}) {
  let syncingFromProps = false
  let lastEmitted: { start: number; end: number } | null = null

  function allCharts(): ECharts[] {
    const primary = options.getChart()
    const peers = options.getPeerCharts?.() ?? []
    return [primary, ...peers].filter((chart): chart is ECharts => Boolean(chart))
  }

  /** 构造 dataZoom 配置（含当前细窗百分比） */
  function buildDataZoom() {
    const domain = options.getDomain()
    const zoom = minutesToZoomPercent(options.getWindow(), domain.start, domain.end)
    return createTimeSeriesDataZoom(zoom)
  }

  /** 图内 dataZoom 事件 → 分钟细窗 → 回写共享状态 */
  function handleDataZoomEvent(params: unknown): void {
    if (syncingFromProps) return
    const percent = readZoomPercentFromEvent(params) ?? readZoomPercentFromOption(options.getChart()?.getOption())
    if (!percent) return
    const domain = options.getDomain()
    const next = zoomPercentToMinutes(percent, domain.start, domain.end)
    if (lastEmitted && nearlyEqualMinutes(lastEmitted, next, 0.5)) return
    if (nearlyEqualMinutes(options.getWindow(), next, 0.5)) return
    lastEmitted = next
    // 同组件内多图先对齐，再回写父级共享窗
    const target = minutesToZoomPercent(next, domain.start, domain.end)
    syncingFromProps = true
    for (const chart of allCharts()) {
      if (chart === options.getChart()) continue
      chart.dispatchAction({ type: 'dataZoom', start: target.start, end: target.end })
    }
    requestAnimationFrame(() => {
      syncingFromProps = false
    })
    options.onWindowChange(next)
  }

  /** 外部共享细窗变化 → 同步本图 dataZoom（避免回环 emit） */
  function syncDataZoomFromWindow(): void {
    const domain = options.getDomain()
    if (!(domain.end > domain.start)) return
    const target = minutesToZoomPercent(options.getWindow(), domain.start, domain.end)
    syncingFromProps = true
    try {
      for (const chart of allCharts()) {
        const current = readZoomPercentFromOption(chart.getOption())
        if (current && nearlyEqualZoom(current, target, 0.2)) continue
        chart.dispatchAction({
          type: 'dataZoom',
          start: target.start,
          end: target.end
        })
      }
    }
    finally {
      // 等 ECharts 把 datazoom 事件派发完再允许回写
      requestAnimationFrame(() => {
        syncingFromProps = false
      })
    }
  }

  /** setOption 后挂事件（每次 render 调用一次） */
  function attachDataZoomEvents(): void {
    for (const chart of allCharts()) {
      chart.off('datazoom')
      chart.on('datazoom', handleDataZoomEvent)
    }
  }

  return {
    buildDataZoom,
    attachDataZoomEvents,
    syncDataZoomFromWindow,
    handleDataZoomEvent
  }
}
