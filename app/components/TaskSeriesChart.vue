<script setup lang="ts">
import * as echarts from 'echarts'
import type { ChartDisplayWindow } from '~~/utils/display-window'
import {
  timeLabelToMinutes
} from '~~/utils/timeLabel'
import { formatCalendarMinute } from '~~/utils/calendarTime'
import { getDeviceColor, getLayerColor } from '~~/config/device-colors'

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
const DAY_MINUTES = 24 * 60

const dateRangeStartMinutes = computed(() => props.displayWindow.dateStart)
const dateRangeEndMinutes = computed(() => props.displayWindow.dateEnd)
const rangeStartMinutes = computed(() => props.displayWindow.start)
const rangeEndMinutes = computed(() => props.displayWindow.end)

const simStartMinutes = computed(() => timeLabelToMinutes(props.simStartTime ?? '0:00'))
const simEndMinutes = computed(() => props.simEndTime ? timeLabelToMinutes(props.simEndTime) : null)

const timelineMinutes = computed(() => [...new Set(
  Object.values(props.layers)
    .flat()
    .map(point => timeLabelToMinutes(point.ts))
    .filter(Number.isFinite)
)].sort((left, right) => left - right))

const sliderStepMinutes = computed(() => {
  const timeline = timelineMinutes.value
  const steps = timeline
    .slice(1)
    .map((minute, index) => minute - timeline[index]!)
    .filter(step => step > 0)
  return Math.min(...steps, 60)
})

const sliderMax = computed(() => {
  const timeline = timelineMinutes.value
  const dataEnd = timeline.length
    ? timeline[timeline.length - 1]! + sliderStepMinutes.value
    : DAY_MINUTES
  // 跟随本图已有数据末端，而不是被 simEnd 锁死在全年；
  // 否则仿真头往前走时，曲线只在左侧加长，看起来像卡住不滚动
  return Math.max(simStartMinutes.value + sliderStepMinutes.value, dataEnd)
})

const formatTimelineLabel = (minute: number): string => formatCalendarMinute(props.simStartDate, minute)

function emitWindow(next: ChartDisplayWindow): void {
  emit('update:displayWindow', next)
}

const updateRangeStart = (value: number): void => {
  emitWindow({ ...props.displayWindow, start: value })
}
const updateRangeEnd = (value: number): void => {
  emitWindow({ ...props.displayWindow, end: value })
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


/**
 * 显示用抽稀：仅缩点给 ECharts，不修改原始数据。
 * 视窗 <= 48h 或点数不多时返回全精度（缩放后仍精细）。
 */
function downsampleForDisplay(
  data: Array<[number, number]>,
  startMin: number,
  endMin: number,
  maxPoints = 1200
): Array<[number, number]> {
  const span = Math.max(1, endMin - startMin)
  if (span <= 48 * 60 || data.length <= maxPoints) return data
  const bucketCount = Math.max(2, Math.floor(maxPoints / 4))
  const bucketSize = span / bucketCount
  const out: Array<[number, number]> = []
  let i = 0
  while (i < data.length && out.length < maxPoints) {
    let j = i
    let minP = data[i]!
    let maxP = data[i]!
    const bucketEnd = data[i]![0] + bucketSize
    while (j < data.length && data[j]![0] < bucketEnd) {
      const p = data[j]!
      if (p[1] < minP[1]) minP = p
      if (p[1] > maxP[1]) maxP = p
      j++
    }
    const last = data[j - 1]!
    for (const p of [data[i]!, minP, maxP, last]) {
      if (!out.length || out[out.length - 1]![0] !== p[0]) out.push(p)
    }
    i = j
  }
  return out
}

const render = () => {
  if (!chartRef.value) return
  if (!chartInstance) {
    chartInstance = echarts.init(chartRef.value)
  }

  const layerIds = Object.keys(props.layers).sort((a, b) => Number(a) - Number(b))
  const startMin = rangeStartMinutes.value
  const endMin = rangeEndMinutes.value

  const series: echarts.SeriesOption[] = layerIds.map((lid, i) => {
    const points = props.layers[lid] ?? []
    const filtered = points
      .filter(p => { const m = timeLabelToMinutes(p.ts); return m >= startMin && m < endMin })
      .map(p => [timeLabelToMinutes(p.ts), truncateSeriesValue(p.value)] as [number, number])
    // 大视窗才抽稀；缩小视窗后自动回到全精度点
    const data: [number, number][] = downsampleForDisplay(filtered, startMin, endMin)
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
    grid: { left: 42, right: 12, top: layerIds.length > 1 ? 20 : 24, bottom: 20, containLabel: false },
    xAxis: {
      type: 'value',
      min: startMin,
      max: endMin,
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
    animation: true,
    animationDuration: 300,
    animationDurationUpdate: 220,
    animationEasing: 'cubicOut',
    animationEasingUpdate: 'linear'
  }, {
    notMerge: false,
    lazyUpdate: true,
    replaceMerge: ['series']
  })
}

// 数据、单位或共享视窗变化时重绘。
watch([
  () => props.layers,
  () => props.dataVersion,
  () => props.deviceColorKey,
  () => props.unit,
  () => props.simStartDate,
  () => props.displayWindow
], () => render())

onMounted(() => {
  render()
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
      <DualRangeSlider
        :start="rangeStartMinutes"
        :end="rangeEndMinutes"
        :min="dateRangeStartMinutes"
        :max="dateRangeEndMinutes"
        :step="sliderStepMinutes"
        :format-label="formatTimelineLabel"
        @update:start="updateRangeStart"
        @update:end="updateRangeEnd"
      />
    </div>
  </section>
</template>
