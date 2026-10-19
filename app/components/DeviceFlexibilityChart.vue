<script setup lang="ts">
import * as echarts from 'echarts'
import type { ChartDisplayWindow } from '~~/utils/display-window'
import type { DeviceFlexibilityResult } from '~~/types/api'
import {
  timeLabelToMinutes
} from '~~/utils/timeLabel'
import { formatCalendarMinute } from '~~/utils/calendarTime'

const SOLID_LINE_LEGEND_ICON = 'path://M0 4H30V6H0Z'
const DASHED_LINE_LEGEND_ICON = 'path://M0 4H7V6H0Z M11 4H18V6H11Z M23 4H30V6H23Z'

const props = defineProps<{
  title: string
  deviceType: string
  rows: DeviceFlexibilityResult[]
  boundary?: boolean
  simStartTime?: string
  simEndTime?: string | null
  simStartDate?: string | null
  displayWindow: ChartDisplayWindow
}>()

const emit = defineEmits<{
  'update:displayWindow': [value: ChartDisplayWindow]
}>()

const chartRef = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null
let resizeObserver: ResizeObserver | null = null
const DAY_MINUTES = 24 * 60
const dateRangeStartMinutes = computed(() => props.displayWindow.dateStart)
const dateRangeEndMinutes = computed(() => props.displayWindow.dateEnd)
const rangeStartMinutes = computed(() => props.displayWindow.start)
const rangeEndMinutes = computed(() => props.displayWindow.end)

const simStartMinutes = computed(() => timeLabelToMinutes(props.simStartTime ?? '0:00'))
const simEndMinutes = computed(() => props.simEndTime ? timeLabelToMinutes(props.simEndTime) : null)

function timeStepToMinutes(value: unknown): number {
  const match = /^(\d+(?:\.\d+)?)\s*(h|m|s)$/i.exec(String(value ?? '').trim())
  if (!match) return 60
  const amount = Number(match[1])
  const unit = match[2]!.toLowerCase()
  if (unit === 'h') return amount * 60
  if (unit === 's') return amount / 60
  return amount
}

const sliderStepMinutes = computed(() => {
  const steps = props.rows
    .map(row => timeStepToMinutes(row.time_step))
    .filter(step => Number.isFinite(step) && step > 0)
  return Math.min(...steps, 60)
})

const sliderMax = computed(() => {
  let dataEnd = 0
  for (const row of props.rows) {
    const start = timeLabelToMinutes(row.timestamp)
    dataEnd = Math.max(dataEnd, start + timeStepToMinutes(row.time_step))
  }
  if (dataEnd <= 0) dataEnd = DAY_MINUTES
  const configuredEnd = simEndMinutes.value
  return Math.max(
    simStartMinutes.value + sliderStepMinutes.value,
    configuredEnd === null ? dataEnd : configuredEnd
  )
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

const visibleRows = computed(() =>
  props.rows.filter((row) => {
    const minute = timeLabelToMinutes(row.timestamp)
    return minute >= rangeStartMinutes.value && minute < rangeEndMinutes.value
  })
)

const timeline = computed(() => [...new Set(visibleRows.value.map(row => row.timestamp))]
  .sort((a, b) => timeLabelToMinutes(a) - timeLabelToMinutes(b)))

const valueByDirection = (direction: 'up' | 'down', field: 'device_flexibility' | 'device_contribution') => {
  const values = new Map(
    visibleRows.value
      .filter(row => row.direction === direction)
      .map(row => {
        const rawValue = Number(row[field] ?? row.device_flexibility)
        const displayValue = direction === 'down' ? -rawValue : rawValue
        return [row.timestamp, displayValue] as const
      })
  )
  return timeline.value.map(timestamp => values.get(timestamp) ?? null)
}

const peak = (direction: 'up' | 'down'): number => Math.max(
  0,
  ...visibleRows.value
    .filter(row => row.direction === direction)
    .map(row => Number(row.device_flexibility) || 0)
)

const render = () => {
  if (!chartRef.value) return
  chart ??= echarts.init(chartRef.value)

  const hasContribution = !props.boundary && props.rows.some(row => row.device_contribution != null)
  const series: echarts.SeriesOption[] = [
    {
      id: 'up-capacity',
      name: props.boundary ? '上调边界空间' : '上调灵活性',
      type: 'line',
      data: valueByDirection('up', 'device_flexibility'),
      showSymbol: false,
      lineStyle: { width: 2, color: '#165DFF' },
      itemStyle: { color: '#165DFF' },
      areaStyle: { color: 'rgba(22,93,255,0.08)' }
    },
    {
      id: 'down-capacity',
      name: props.boundary ? '下调边界空间' : '下调灵活性',
      type: 'line',
      data: valueByDirection('down', 'device_flexibility'),
      showSymbol: false,
      lineStyle: { width: 2, color: '#12B76A' },
      itemStyle: { color: '#12B76A' },
      areaStyle: { color: 'rgba(18,183,106,0.06)' }
    }
  ]

  if (hasContribution) {
    series.push(
      {
        id: 'up-contribution',
        name: '上调系统供给分摊',
        type: 'line',
        data: valueByDirection('up', 'device_contribution'),
        showSymbol: false,
        lineStyle: { width: 1.5, type: 'dashed', color: '#F79009' },
        itemStyle: { color: '#F79009' }
      },
      {
        id: 'down-contribution',
        name: '下调系统供给分摊',
        type: 'line',
        data: valueByDirection('down', 'device_contribution'),
        showSymbol: false,
        lineStyle: { width: 1.5, type: 'dashed', color: '#F04438' },
        itemStyle: { color: '#F04438' }
      }
    )
  }

  chart.setOption({
    animation: true,
    animationDuration: 300,
    color: ['#165DFF', '#12B76A', '#F79009', '#F04438'],
    legend: {
      right: 12,
      top: 5,
      data: series.map(item => ({
        name: String(item.name ?? ''),
        icon: String(item.id ?? '').endsWith('contribution')
          ? DASHED_LINE_LEGEND_ICON
          : SOLID_LINE_LEGEND_ICON
      })),
      itemWidth: 20,
      itemHeight: 8,
      textStyle: { fontSize: 10 }
    },
    grid: { left: 55, right: 18, top: 38, bottom: 30 },
    xAxis: {
      type: 'category',
      data: timeline.value,
      boundaryGap: false,
      axisLabel: {
        fontSize: 10,
        hideOverlap: true,
        formatter: (value: string) => formatCalendarMinute(props.simStartDate, timeLabelToMinutes(value))
      },
      axisLine: { lineStyle: { color: '#D0D5DD' } }
    },
    yAxis: {
      type: 'value',
      name: 'kW',
      nameTextStyle: { fontSize: 10, color: '#667085' },
      axisLabel: { fontSize: 10 },
      splitLine: { lineStyle: { type: 'dashed', color: '#EAECF0' } }
    },
    tooltip: {
      trigger: 'axis',
      valueFormatter: (value: unknown) => `${Number(value).toFixed(2)} kW`
    },
    series
  }, {
    notMerge: false,
    lazyUpdate: true,
    replaceMerge: ['series']
  })
}

watch([
  () => props.rows,
  () => props.simStartDate,
  () => props.displayWindow
], render)

onMounted(() => {
  render()
  resizeObserver = new ResizeObserver(() => chart?.resize())
  resizeObserver.observe(chartRef.value!)
})

onBeforeUnmount(() => {
  resizeObserver?.disconnect()
  chart?.dispose()
  chart = null
})
</script>

<template>
  <section class="border border-app-border bg-white p-3">
    <div class="flex flex-wrap items-start justify-between gap-3 px-1">
      <div>
        <div class="flex items-center gap-2">
          <h3 class="">{{ title }}</h3>
          <span v-if="boundary" class="rounded-full bg-blue-50 px-2 py-0.5 text-[10px] text-primary">并网边界</span>
        </div>
      </div>
      <div class="flex gap-4 text-right text-xs text-app-muted">
        <div>峰值上调 <span class="ml-1 text-xs text-primary font-semibold">{{ peak('up').toFixed(2) }} kW</span></div>
        <div>峰值下调 <span class="ml-1 text-xs text-green-700 font-semibold">{{ peak('down').toFixed(2) }} kW</span></div>
      </div>
    </div>
    <div ref="chartRef" class="mt-2 h-44 w-full" />
    <div class="px-4 pt-1">
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
