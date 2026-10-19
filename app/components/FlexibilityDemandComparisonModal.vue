<script setup lang="ts">
import * as echarts from 'echarts'
import type { FlexibilityDisplayWindow } from '~~/types/flexibility-display'
import { formatCalendarMinute } from '~~/utils/calendarTime'
import { timeLabelToMinutes } from '~~/utils/timeLabel'

interface RequirementPeriod {
  timestamp: string
  next_timestamp: string
  direction: 'up' | 'down'
  requirement: number
  reference_power?: number | null
  target_power?: number | null
}

interface ComparisonLine {
  title: string
  color: string
  data: Array<[number, number]>
}

const props = defineProps<{
  rows: RequirementPeriod[]
  initialWindow: FlexibilityDisplayWindow
  simStartTime?: string
  simEndMinutes: number
  simStartDate?: string | null
}>()

const emit = defineEmits<{ close: [] }>()

// 弹窗内的时间窗口独立于页面图表，三个对照图共用这一份状态。
const displayWindow = ref<FlexibilityDisplayWindow>({ ...props.initialWindow })
const simStartMinutes = computed(() => timeLabelToMinutes(props.simStartTime ?? '0:00'))
const sliderMax = computed(() => Math.max(simStartMinutes.value + 5, props.simEndMinutes))

const sliderStepMinutes = computed(() => {
  const steps = props.rows
    .filter(row => row.direction === 'up')
    .map(row => timeLabelToMinutes(row.next_timestamp) - timeLabelToMinutes(row.timestamp))
    .filter(step => Number.isFinite(step) && step > 0)
  return Math.min(...steps, 5)
})

function updateDateRangeStart(value: number): void {
  displayWindow.value = {
    ...displayWindow.value,
    dateStart: value,
    start: value,
    end: displayWindow.value.dateEnd
  }
}

function updateDateRangeEnd(value: number): void {
  displayWindow.value = {
    ...displayWindow.value,
    dateEnd: value,
    start: displayWindow.value.dateStart,
    end: value
  }
}

function updateRangeStart(value: number): void {
  displayWindow.value = { ...displayWindow.value, start: value }
}

function updateRangeEnd(value: number): void {
  displayWindow.value = { ...displayWindow.value, end: value }
}

function formatTime(minute: number): string {
  return formatCalendarMinute(props.simStartDate, minute)
}

function finitePower(value: number | null | undefined): number | null {
  if (value == null) return null
  const numeric = Number(value)
  return Number.isFinite(numeric) ? numeric : null
}

const visibleRows = computed(() => props.rows
  .filter(row => {
    const minute = timeLabelToMinutes(row.timestamp)
    return minute >= displayWindow.value.start && minute < displayWindow.value.end
  })
  .sort((left, right) => timeLabelToMinutes(left.timestamp) - timeLabelToMinutes(right.timestamp)))

const comparisonLines = computed<ComparisonLine[]>(() => {
  const upward = visibleRows.value.filter(row => row.direction === 'up')
  const downward = visibleRows.value.filter(row => row.direction === 'down')
  return [
    {
      title: '净负荷变化量',
      color: '#F79009',
      data: upward.flatMap(row => {
        const current = finitePower(row.reference_power)
        const next = finitePower(row.target_power)
        return current === null || next === null
          ? []
          : [[timeLabelToMinutes(row.timestamp), next - current] as [number, number]]
      })
    },
    {
      title: '上调系统需求',
      color: '#F79009',
      data: upward.flatMap(row => {
        const value = finitePower(row.requirement)
        return value === null ? [] : [[timeLabelToMinutes(row.timestamp), value] as [number, number]]
      })
    },
    {
      title: '下调系统需求（负值）',
      color: '#F79009',
      data: downward.flatMap(row => {
        const value = finitePower(row.requirement)
        return value === null ? [] : [[timeLabelToMinutes(row.timestamp), -value] as [number, number]]
      })
    }
  ]
})

const axisMax = computed(() => {
  const peak = comparisonLines.value.reduce((maximum, line) =>
    line.data.reduce((lineMaximum, [, value]) => Math.max(lineMaximum, Math.abs(value)), maximum), 0)
  if (peak <= 0) return 1
  const unit = 10 ** (Math.floor(Math.log10(peak)) - 1)
  return Math.ceil(peak * 1.05 / unit) * unit
})

const chartElements: Array<HTMLDivElement | null> = [null, null, null]
const charts: Array<echarts.ECharts | null> = [null, null, null]
let resizeObserver: ResizeObserver | null = null

function setChartElement(element: unknown, index: number): void {
  chartElements[index] = element instanceof HTMLDivElement ? element : null
}

function render(): void {
  comparisonLines.value.forEach((line, index) => {
    const element = chartElements[index]
    if (!element) return
    charts[index] ??= echarts.init(element)
    charts[index]!.setOption({
      animation: false,
      grid: { left: 76, right: 24, top: 12, bottom: 30 },
      xAxis: {
        type: 'value',
        min: displayWindow.value.start,
        max: displayWindow.value.end,
        axisLabel: { fontSize: 10, formatter: (minute: number) => formatTime(minute) },
        splitLine: { show: false },
        axisLine: { lineStyle: { color: '#D0D5DD' } }
      },
      yAxis: {
        type: 'value',
        min: -axisMax.value,
        max: axisMax.value,
        splitNumber: 4,
        name: 'kW',
        nameTextStyle: { fontSize: 10, color: '#667085' },
        axisLabel: { fontSize: 10 },
        splitLine: { lineStyle: { type: 'dashed', color: '#EAECF0' } }
      },
      tooltip: {
        trigger: 'axis',
        formatter: (params: unknown) => {
          const item = (Array.isArray(params) ? params[0] : params) as {
            axisValue?: number | string
            marker?: string
            value?: number | [number, number]
          } | undefined
          const minute = Number(item?.axisValue ?? (Array.isArray(item?.value) ? item.value[0] : NaN))
          const value = Array.isArray(item?.value) ? Number(item.value[1]) : Number(item?.value)
          if (!Number.isFinite(minute) || !Number.isFinite(value)) return ''
          return `${formatTime(minute)}<br/>${item?.marker ?? ''}${line.title}：${value.toLocaleString('zh-CN', { maximumFractionDigits: 2 })} kW`
        }
      },
      series: [{
        name: line.title,
        type: 'line',
        showSymbol: line.data.length === 1,
        symbolSize: 6,
        data: line.data,
        lineStyle: { width: 2, color: line.color },
        itemStyle: { color: line.color },
        markLine: {
          silent: true,
          symbol: 'none',
          label: { show: false },
          lineStyle: { color: '#98A2B3', type: 'dashed', width: 1 },
          data: [{ yAxis: 0 }]
        }
      }]
    }, true)
  })
}

watch([() => JSON.stringify(props.rows), () => displayWindow.value.start,
  () => displayWindow.value.end, axisMax], render)

onMounted(async () => {
  await nextTick()
  render()
  resizeObserver = new ResizeObserver(() => charts.forEach(chart => chart?.resize()))
  chartElements.forEach(element => { if (element) resizeObserver?.observe(element) })
})

onBeforeUnmount(() => {
  resizeObserver?.disconnect()
  charts.forEach(chart => chart?.dispose())
})
</script>

<template>
  <AppModal :open="true" title="需求对照" size="xl" @close="emit('close')">
    <div class="px-4 py-2">
      <div v-for="(line, index) in comparisonLines" :key="line.title" class="border-b border-app-border py-2 last:border-b-0">
        <div class="text-sm font-medium text-app-text">{{ line.title }}</div>
        <div class="relative h-40 min-w-0">
          <div v-if="line.data.length === 0" class="absolute inset-0 z-10 flex items-center justify-center bg-white text-sm text-app-muted">
            所选时段暂无数据
          </div>
          <div :ref="element => setChartElement(element, index)" class="h-40 w-full" />
        </div>
      </div>
      <div class="px-4 pt-3">
        <CalendarRangeInputs
          v-if="simStartDate"
          :base-date="simStartDate"
          :start="displayWindow.dateStart"
          :end="displayWindow.dateEnd"
          :min="simStartMinutes"
          :max="sliderMax"
          @update:start="updateDateRangeStart"
          @update:end="updateDateRangeEnd"
        />
        <PrimaryDualRangeSlider
          :start="displayWindow.start"
          :end="displayWindow.end"
          :min="displayWindow.dateStart"
          :max="displayWindow.dateEnd"
          :step="sliderStepMinutes"
          :format-label="formatTime"
          @update:start="updateRangeStart"
          @update:end="updateRangeEnd"
        />
      </div>
    </div>
  </AppModal>
</template>
