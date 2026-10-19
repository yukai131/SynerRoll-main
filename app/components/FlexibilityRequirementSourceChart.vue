<script setup lang="ts">
import * as echarts from 'echarts'
import type { FlexibilityDisplayWindow } from '~~/types/flexibility-display'
import { formatCalendarMinute } from '~~/utils/calendarTime'
import { timeLabelToMinutes } from '~~/utils/timeLabel'

type RequirementSource = 'net_load_change' | 'agc_or_schedule' | 'user_defined'

interface RequirementPeriod {
  timestamp: string
  next_timestamp: string
  direction: 'up' | 'down'
  requirement: number
  reference_power?: number | null
  target_power?: number | null
}

const props = defineProps<{
  rows: RequirementPeriod[]
  source: RequirementSource
  displayWindow: FlexibilityDisplayWindow
  simStartTime?: string
  simEndMinutes: number
  simStartDate?: string | null
}>()

const emit = defineEmits<{
  'update:displayWindow': [window: FlexibilityDisplayWindow]
  openDemandComparison: []
}>()

const chartRef = ref<HTMLDivElement | null>(null)
const netLoadDisplayMode = ref<'level' | 'change'>('level')
let chart: echarts.ECharts | null = null
let resizeObserver: ResizeObserver | null = null

const title = computed(() => {
  if (props.source === 'net_load_change') return '灵活性需求来源 · 净负荷变化'
  if (props.source === 'agc_or_schedule') return '灵活性需求来源 · AGC/计划跟踪'
  return '灵活性需求来源 · 用户自定义'
})

const simStartMinutes = computed(() => timeLabelToMinutes(props.simStartTime ?? '0:00'))
const sliderMax = computed(() => Math.max(simStartMinutes.value + 5, props.simEndMinutes))
const displayWindow = computed(() => props.displayWindow)

const sliderStepMinutes = computed(() => {
  const steps = props.rows
    .filter(row => row.direction === 'up')
    .map(row => timeLabelToMinutes(row.next_timestamp) - timeLabelToMinutes(row.timestamp))
    .filter(step => Number.isFinite(step) && step > 0)
  return Math.min(...steps, 5)
})

function updateDateRangeStart(value: number): void {
  emit('update:displayWindow', {
    ...displayWindow.value,
    dateStart: value,
    start: value,
    end: displayWindow.value.dateEnd
  })
}

function updateDateRangeEnd(value: number): void {
  emit('update:displayWindow', {
    ...displayWindow.value,
    dateEnd: value,
    start: displayWindow.value.dateStart,
    end: value
  })
}

function updateRangeStart(value: number): void {
  emit('update:displayWindow', { ...displayWindow.value, start: value })
}

function updateRangeEnd(value: number): void {
  emit('update:displayWindow', { ...displayWindow.value, end: value })
}

function setNetLoadDisplayMode(mode: 'level' | 'change'): void {
  netLoadDisplayMode.value = mode
}

const visibleRows = computed(() => props.rows
  .filter(row => {
    const minute = timeLabelToMinutes(row.timestamp)
    return minute >= displayWindow.value.start && minute < displayWindow.value.end
  })
  .sort((left, right) => timeLabelToMinutes(left.timestamp) - timeLabelToMinutes(right.timestamp)))

const upwardRows = computed(() => visibleRows.value.filter(row => row.direction === 'up'))
const downwardRows = computed(() => visibleRows.value.filter(row => row.direction === 'down'))

function finitePower(value: number | null | undefined): number | null {
  if (value == null) return null
  const numeric = Number(value)
  return Number.isFinite(numeric) ? numeric : null
}

function formatPower(value: number): string {
  return value.toLocaleString('zh-CN', { maximumFractionDigits: 2 })
}

function formatTime(minute: number): string {
  return formatCalendarMinute(props.simStartDate, minute)
}

interface SourceLine {
  name: string
  color: string
  data: Array<[number, number]>
}

const sourceLines = computed<SourceLine[]>(() => {
  if (props.source === 'net_load_change') {
    if (netLoadDisplayMode.value === 'change') {
      return [{
        name: '净负荷变化量',
        color: '#F79009',
        data: upwardRows.value.flatMap(row => {
          const current = finitePower(row.reference_power)
          const next = finitePower(row.target_power)
          return current === null || next === null
            ? []
            : [[timeLabelToMinutes(row.timestamp), next - current] as [number, number]]
        })
      }]
    }

    const points = new Map<number, number>()
    for (const row of upwardRows.value) {
      const current = finitePower(row.reference_power)
      const next = finitePower(row.target_power)
      const start = timeLabelToMinutes(row.timestamp)
      const end = timeLabelToMinutes(row.next_timestamp)
      if (current !== null) points.set(start, current)
      if (next !== null && end <= displayWindow.value.end) points.set(end, next)
    }
    return [{
      name: '净负荷',
      color: '#165DFF',
      data: [...points.entries()].sort((left, right) => left[0] - right[0])
    }]
  }

  if (props.source === 'agc_or_schedule') {
    const makeLine = (name: string, field: 'reference_power' | 'target_power', color: string): SourceLine => ({
      name,
      color,
      data: upwardRows.value.flatMap(row => {
        const value = finitePower(row[field])
        // AGC/计划输入的基准与目标功率均对应区间终点。
        return value === null ? [] : [[timeLabelToMinutes(row.next_timestamp), value] as [number, number]]
      })
    })
    return [
      makeLine('基准并网功率', 'reference_power', '#165DFF'),
      makeLine('AGC/计划目标功率', 'target_power', '#F79009')
    ]
  }

  return [
    {
      name: '上调需求',
      color: '#165DFF',
      data: upwardRows.value.flatMap(row => {
        const value = finitePower(row.requirement)
        return value === null ? [] : [[timeLabelToMinutes(row.timestamp), value] as [number, number]]
      })
    },
    {
      name: '下调需求',
      color: '#F79009',
      data: downwardRows.value.flatMap(row => {
        const value = finitePower(row.requirement)
        return value === null ? [] : [[timeLabelToMinutes(row.timestamp), value] as [number, number]]
      })
    }
  ]
})

const hasSourceData = computed(() => sourceLines.value.some(line => line.data.some(
  ([minute]) => minute >= displayWindow.value.start && minute <= displayWindow.value.end
)))

interface SourceTooltipItem {
  axisValue?: number | string
  marker?: string
  seriesName?: string
  value?: number | [number, number]
}

function formatTooltip(params: unknown): string {
  const items = (Array.isArray(params) ? params : [params]) as SourceTooltipItem[]
  const minute = Number(items[0]?.axisValue ?? (Array.isArray(items[0]?.value) ? items[0].value[0] : NaN))
  if (!Number.isFinite(minute)) return ''
  if (props.source === 'net_load_change' && netLoadDisplayMode.value === 'level') {
    const point = items.find(item => item.seriesName === '净负荷')
    const value = Array.isArray(point?.value) ? Number(point.value[1]) : Number(point?.value)
    return Number.isFinite(value)
      ? `${formatTime(minute)}<br/>${point?.marker ?? ''}净负荷：${formatPower(value)} kW`
      : formatTime(minute)
  }
  const row = upwardRows.value.find(item => timeLabelToMinutes(
    props.source === 'agc_or_schedule' ? item.next_timestamp : item.timestamp
  ) === minute)
  const downRow = downwardRows.value.find(item => timeLabelToMinutes(
    props.source === 'agc_or_schedule' ? item.next_timestamp : item.timestamp
  ) === minute)
  const lines = [formatTime(minute)]
  if (row) lines.push(`需求区间：${formatTime(timeLabelToMinutes(row.timestamp))} → ${formatTime(timeLabelToMinutes(row.next_timestamp))}`)

  for (const item of items) {
    const value = Array.isArray(item.value) ? Number(item.value[1]) : Number(item.value)
    if (Number.isFinite(value)) lines.push(`${item.marker ?? ''}${item.seriesName ?? ''}：${formatPower(value)} kW`)
  }

  if (row && props.source !== 'user_defined'
    && !(props.source === 'net_load_change' && netLoadDisplayMode.value === 'change')) {
    const reference = finitePower(row.reference_power)
    const target = finitePower(row.target_power)
    if (reference !== null && target !== null) {
      lines.push(`变化量：${formatPower(target - reference)} kW`)
    }
  }
  if (row) lines.push(`上调需求：${formatPower(Number(row.requirement) || 0)} kW`)
  if (downRow) lines.push(`下调需求：${formatPower(Number(downRow.requirement) || 0)} kW`)
  return lines.join('<br/>')
}

function render(): void {
  if (!chartRef.value) return
  chart ??= echarts.init(chartRef.value)
  chart.setOption({
    animation: false,
    legend: {
      type: 'scroll',
      top: 4,
      right: 12,
      data: sourceLines.value.map(line => ({ name: line.name, icon: 'path://M0 4H30V6H0Z' })),
      itemWidth: 20,
      itemHeight: 8,
      textStyle: { fontSize: 11, color: '#475467' }
    },
    grid: { left: 70, right: 24, top: 38, bottom: 30 },
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
      name: 'kW',
      nameTextStyle: { fontSize: 10, color: '#667085' },
      axisLabel: { fontSize: 10 },
      splitLine: { lineStyle: { type: 'dashed', color: '#EAECF0' } }
    },
    tooltip: { trigger: 'axis', formatter: formatTooltip },
    series: sourceLines.value.map(line => ({
      id: line.name,
      name: line.name,
      type: 'line',
      showSymbol: line.data.length === 1,
      symbolSize: 6,
      connectNulls: false,
      data: line.data,
      lineStyle: { width: 2, color: line.color },
      itemStyle: { color: line.color },
      ...(props.source === 'net_load_change' && netLoadDisplayMode.value === 'change' ? {
        markLine: {
          silent: true,
          symbol: 'none',
          label: { show: false },
          lineStyle: { color: '#98A2B3', type: 'dashed', width: 1 },
          data: [{ yAxis: 0 }]
        }
      } : {})
    }))
  }, true)
}

watch(
  [() => props.rows, () => props.source, netLoadDisplayMode,
    () => displayWindow.value.start, () => displayWindow.value.end],
  render
)

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
  <section class="border border-app-border bg-white px-4 py-3">
    <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
      <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 class="text-base text-app-text">{{ title }}</h3>
        <span v-if="source === 'net_load_change'" class="text-xs text-app-muted">
          净负荷 = 刚性电负荷 + 柔性电负荷 − 风电可用功率 − 光伏可用功率
        </span>
      </div>
      <div v-if="source === 'net_load_change'" class="flex flex-wrap items-center gap-2" role="group" aria-label="净负荷显示模式">
        <AppButton
          label="净负荷"
          size="sm"
          :tone="netLoadDisplayMode === 'level' ? 'primary' : 'neutral'"
          @click="setNetLoadDisplayMode('level')"
        />
        <AppButton
          label="净负荷变化量"
          size="sm"
          :tone="netLoadDisplayMode === 'change' ? 'primary' : 'neutral'"
          @click="setNetLoadDisplayMode('change')"
        />
        <AppButton
          label="需求对照"
          size="sm"
          tone="neutral"
          @click="emit('openDemandComparison')"
        />
      </div>
    </div>
    <div class="relative mt-2 h-52 min-w-0">
      <div
        v-if="!hasSourceData"
        class="absolute inset-0 z-10 flex items-center justify-center bg-white text-sm text-app-muted"
      >当前时段暂无需求来源数据</div>
      <div ref="chartRef" class="h-52 w-full" />
    </div>
    <div class="px-4">
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
  </section>
</template>
