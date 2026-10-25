<script setup lang="ts">
import * as echarts from 'echarts'
import type { ChartDisplayWindow } from '~~/utils/display-window'
import {
  timeLabelToMinutes
} from '~~/utils/timeLabel'
import { formatCalendarMinute } from '~~/utils/calendarTime'
import { getDeviceColor, getLayerColor } from '~~/config/device-colors'
import { pointMinutes, sliceTimeSeries } from '~~/utils/time-series-window'
import { downsampleTimeSeries } from '~~/utils/chart-downsample'
import { useVisibleChart } from '~~/composables/useVisibleChart'
import { useSharedDataZoom } from '~~/composables/useSharedDataZoom'

const SOLID_LINE_LEGEND_ICON = 'path://M0 4H30V6H0Z'

interface Point {
  ts: string
  value: number
}

const props = defineProps<{
  layers: Record<string, Point[]>
  title: string
  deviceColorKey?: string
  /** 父级数据版本号，嵌套 layers 引用不变时也强制重绘 */
  dataVersion?: number
  resultCursor?: number
  unit: string
  /** 层ID→层名称映射，如 { "1": "日前", "2": "日内" } */
  layerNames?: Record<string, string>
  simStartTime?: string
  simEndTime?: string | null
  simStartDate?: string | null
  /** 同标签页共享视窗；父级持有状态，本图只读并回写 */
  displayWindow: ChartDisplayWindow
}>()

const emit = defineEmits<{
  'update:displayWindow': [value: ChartDisplayWindow]
}>()

const chartRef = ref<HTMLDivElement | null>(null)
let chartInstance: echarts.ECharts | null = null
const { schedule: scheduleRender } = useVisibleChart(chartRef, () => render(),
  () => chartInstance, () => props.title, () => props.resultCursor ?? 0)
const DAY_MINUTES = 24 * 60

const dateRangeStartMinutes = computed(() => props.displayWindow.dateStart)
const dateRangeEndMinutes = computed(() => props.displayWindow.dateEnd)
const rangeStartMinutes = computed(() => props.displayWindow.start)
const rangeEndMinutes = computed(() => props.displayWindow.end)

const simStartMinutes = computed(() => timeLabelToMinutes(props.simStartTime ?? '0:00'))
const simEndMinutes = computed(() => props.simEndTime ? timeLabelToMinutes(props.simEndTime) : null)

const sliderStepMinutes = computed(() => {
  let step = 60
  for (const points of Object.values(props.layers)) {
    if (points.length > 1) {
      const difference = pointMinutes(points[1]!) - pointMinutes(points[0]!)
      if (difference > 0) step = Math.min(step, difference)
    }
  }
  return step
})

const sliderMax = computed(() => {
  const ends = Object.values(props.layers).filter(points => points.length).map(points => pointMinutes(points[points.length - 1]!))
  const dataEnd = ends.length ? Math.max(...ends) + sliderStepMinutes.value : DAY_MINUTES
  // 跟随本图已有数据末端，而不是被 simEnd 锁死在全年；
  // 否则仿真头往前走时，曲线只在左侧加长，看起来像卡住不滚动
  return Math.max(simStartMinutes.value + sliderStepMinutes.value, dataEnd)
})

function emitWindow(next: ChartDisplayWindow): void {
  emit('update:displayWindow', next)
}

const updateDateRangeStart = (value: number): void => {
  // 日期粗窗变更后细窗重置为该窗口全宽
  emitWindow({
    dateStart: value,
    dateEnd: props.displayWindow.dateEnd,
    start: value,
    end: props.displayWindow.dateEnd
  })
}
const updateDateRangeEnd = (value: number): void => {
  emitWindow({
    dateStart: props.displayWindow.dateStart,
    dateEnd: value,
    start: props.displayWindow.dateStart,
    end: value
  })
}

/** dataZoom 定义域 = 日期粗窗；细窗由共享 displayWindow.start/end 驱动 */
const zoomDomain = computed(() => ({
  start: dateRangeStartMinutes.value,
  end: Math.max(dateRangeStartMinutes.value + 1, dateRangeEndMinutes.value)
}))

const sharedZoom = useSharedDataZoom({
  getChart: () => chartInstance,
  getWindow: () => ({ start: rangeStartMinutes.value, end: rangeEndMinutes.value }),
  getDomain: () => zoomDomain.value,
  onWindowChange: (win) => {
    emitWindow({ ...props.displayWindow, start: win.start, end: win.end })
  }
})

/** 运行总览只展示整数量级，小数及求解器产生的极小浮点残差直接截断。 */
function truncateSeriesValue(value: number): number {
  return Math.trunc(Math.abs(value))
}

function formatIntegerValue(value: number): string {
  return Math.trunc(value).toLocaleString('en-US')
}

// 同一设备的各时层保持同一色相，仅用透明度区分先后层次。
function layerColor(index: number, total: number): string {
  const baseColor = getDeviceColor(props.deviceColorKey ?? props.title, props.title)
  return getLayerColor(baseColor, index, total)
}


const render = () => {
  if (!chartRef.value) return
  if (!chartInstance) {
    chartInstance = echarts.init(chartRef.value)
  }

  const layerIds = Object.keys(props.layers).sort((a, b) => Number(a) - Number(b))
  const domain = zoomDomain.value
  const startMin = rangeStartMinutes.value
  const endMin = rangeEndMinutes.value

  const series: echarts.SeriesOption[] = layerIds.map((lid, i) => {
    const points = props.layers[lid] ?? []
    // 序列保留日期粗窗全量点，由 dataZoom 控制细窗；抽稀仍按细窗跨度计算
    const filtered = sliceTimeSeries(points, domain.start, domain.end)
      .map(p => [pointMinutes(p), truncateSeriesValue(p.value)] as [number, number])
    // 大视窗才抽稀；缩小视窗后自动回到全精度点
    const data: [number, number][] = downsampleTimeSeries(filtered, startMin, endMin)
    const color = layerColor(i, layerIds.length)
    return {
      id: `layer-${lid}`,
      type: 'line',
      name: props.layerNames?.[lid] ?? `层${lid}`,
      data,
      showSymbol: false,
      smooth: false,
      lineStyle: { width: 1.5, color },
      itemStyle: { color },
      areaStyle: { opacity: 0.05, color },
    }
  })

  chartInstance.setOption({
    title: {
      text: props.title,
      textStyle: { fontSize: 11, fontWeight: 'normal' },
      left: 'center',
      top: 2
    },
    legend: {
      show: layerIds.length > 1,
      top: 2,
      right: 8,
      data: series.map(item => ({
        name: String(item.name ?? ''),
        icon: SOLID_LINE_LEGEND_ICON
      })),
      itemWidth: 20,
      itemHeight: 8,
      textStyle: { fontSize: 9 }
    },
    grid: { left: 42, right: 12, top: layerIds.length > 1 ? 20 : 24, bottom: 36, containLabel: false },
    dataZoom: sharedZoom.buildDataZoom(),
    xAxis: {
      type: 'value',
      min: domain.start,
      max: domain.end,
      interval: 'auto',
      axisLabel: {
        fontSize: 9,
        formatter: (v: number) => formatCalendarMinute(props.simStartDate, v)
      },
      splitLine: { show: false }
    },
    yAxis: {
      type: 'value',
      name: props.unit,
      nameGap: 8,
      nameTextStyle: { fontSize: 9, color: '#667085' },
      minInterval: 1,
      axisLabel: {
        fontSize: 9,
        formatter: (value: number) => formatIntegerValue(value)
      },
      scale: true,
      splitLine: { lineStyle: { type: 'dashed', color: '#eee' } }
    },
    series,
    tooltip: {
      trigger: 'axis',
      formatter: (params: unknown) => {
        const arr = Array.isArray(params) ? params as { data?: number[]; seriesName?: string; color?: string }[] : []
        if (!arr.length) return ''
        const m = arr[0]?.data?.[0] ?? 0
        let html = `<b>${formatCalendarMinute(props.simStartDate, m as number)}</b>`
        for (const p of arr) {
          const d = p.data
          if (!d || d.length < 2) continue
          const val = typeof d[1] === 'number' ? d[1] : 0
          const unitSuffix = props.unit ? ` ${props.unit}` : ''
          html += `<br/><span style="color:${p.color ?? ''}">●</span> ${p.seriesName ?? ''}: ${formatIntegerValue(val)}${unitSuffix}`
        }
        return html
      }
    },
    animation: false,
    animationDuration: 300,
    animationDurationUpdate: 220,
    animationEasing: 'cubicOut',
    animationEasingUpdate: 'linear'
  }, {
    notMerge: false,
    lazyUpdate: true,
    replaceMerge: ['series']
  })

  sharedZoom.attachDataZoomEvents()
}

// 数据、单位或共享视窗变化时重绘。
watch([
  () => props.layers,
  () => props.dataVersion,
  () => props.deviceColorKey,
  () => props.unit,
  () => props.simStartDate,
  () => props.displayWindow
], () => {
  scheduleRender()
  // 其他图改了共享细窗时，同步本图 dataZoom（不回写）
  sharedZoom.syncDataZoomFromWindow()
})

onMounted(() => {
  scheduleRender()
  const ro = new ResizeObserver(() => chartInstance?.resize())
  if (chartRef.value) ro.observe(chartRef.value)
  onBeforeUnmount(() => ro.disconnect())
})

onBeforeUnmount(() => {
  chartInstance?.dispose()
  chartInstance = null
})
</script>

<template>
  <section>
    <div ref="chartRef" class="h-36 w-full" />
    <div class="px-2 pt-1">
      <CalendarRangeInputs
        v-if="simStartDate"
        :base-date="simStartDate"
        :start="dateRangeStartMinutes"
        :end="dateRangeEndMinutes"
        :min="simStartMinutes"
        :max="sliderMax"
        @update:start="updateDateRangeStart"
        @update:end="updateDateRangeEnd"
      />
    </div>
  </section>
</template>
