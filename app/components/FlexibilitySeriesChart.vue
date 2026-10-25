<script setup lang="ts">
import * as echarts from 'echarts'
import type { FlexibilityPeriodResult } from '~~/types/api'
import type { FlexibilityDisplayWindow } from '~~/types/flexibility-display'
import {
  timeLabelToMinutes
} from '~~/utils/timeLabel'
import { formatCalendarMinute } from '~~/utils/calendarTime'
import { getDeviceColor } from '~~/config/device-colors'
import AppModal from '~/components/AppModal.vue'
import { useSharedDataZoom } from '~~/composables/useSharedDataZoom'

const SOLID_LINE_LEGEND_ICON = 'path://M0 4H30V6H0Z'
const DEFICIT_COLOR = '#F04438'

const props = defineProps<{
  rows: FlexibilityPeriodResult[]
  direction: 'up' | 'down'
  deviceLabels?: Record<string, string>
  simStartTime?: string
  simEndTime?: string | null
  simEndMinutes?: number
  simStartDate?: string | null
  displayWindow: FlexibilityDisplayWindow
}>()

const formatTimelineLabel = (value: number | string): string => {
  const minute = typeof value === 'number' ? value : timeLabelToMinutes(value)
  return formatCalendarMinute(props.simStartDate, minute)
}

const emit = defineEmits<{
  hoverTimestamp: [timestamp: string | null]
  'update:displayWindow': [value: FlexibilityDisplayWindow]
}>()

const chartRef = ref<HTMLDivElement | null>(null)
const contributionChartRef = ref<HTMLDivElement | null>(null)
const contributionDisplayMode = ref<'value' | 'percentage'>('value')
const marginVisible = ref(true)
const selectedDeficitTimestamp = ref<string | null>(null)
const deficitDetailOpen = ref(false)
let chart: echarts.ECharts | null = null
let contributionChart: echarts.ECharts | null = null
let resizeObserver: ResizeObserver | null = null

const DAY_MINUTES = 24 * 60
const dateRangeStartMinutes = computed(() => props.displayWindow.dateStart)
const dateRangeEndMinutes = computed(() => props.displayWindow.dateEnd)
const rangeStartMinutes = computed(() => props.displayWindow.start)
const rangeEndMinutes = computed(() => props.displayWindow.end)

const simStartMinutes = computed(() => timeLabelToMinutes(props.simStartTime ?? '0:00'))
const simEndMinutesComputed = computed(() =>
  props.simEndMinutes ?? (props.simEndTime ? timeLabelToMinutes(props.simEndTime) : null)
)

const DEVICE_TYPE_LABELS: Record<string, string> = {
  WT: '风机',
  PV: '光伏',
  CP: '燃煤机组',
  GP: '气电机组',
  CHP: '热电联产',
  ET: '电解槽',
  ELOAD: '电负荷',
  HLOAD: '氢负荷',
  QLOAD: '热负荷',
  ES: '电化学储能',
  HS: '储氢设备',
  FS: '飞轮储能',
  CS: '压缩空气储能',
  PS: '抽水蓄能',
  HYDRO: '常规水电',
  GRID: '电网',
  HGRID: '氢网'
}

const directionLabel = computed(() => props.direction === 'up' ? '上调' : '下调')
const directionalDisplayValue = (value: unknown): number | null => {
  const numericValue = Number(value)
  if (!Number.isFinite(numericValue)) return null
  return props.direction === 'down' ? -numericValue : numericValue
}

const directionRows = computed(() => props.rows
  .filter(row => row.direction === props.direction)
  .slice()
  .sort((a, b) => timeLabelToMinutes(a.timestamp) - timeLabelToMinutes(b.timestamp)))

/** 业务指标仍按共享细窗计算，与原 DualRangeSlider 口径一致 */
const visibleRows = computed(() => directionRows.value.filter(row => {
  const timestamp = timeLabelToMinutes(row.timestamp)
  return timestamp >= rangeStartMinutes.value && timestamp < rangeEndMinutes.value
}))

/** 图序列覆盖日期粗窗，细窗由 dataZoom 控制 */
const domainRows = computed(() => directionRows.value.filter(row => {
  const timestamp = timeLabelToMinutes(row.timestamp)
  return timestamp >= zoomDomain.value.start && timestamp < zoomDomain.value.end
}))

const selectedDeficitRow = computed(() => directionRows.value.find(row =>
  row.timestamp === selectedDeficitTimestamp.value && Number(row.margin) < 0
) ?? null)

const DEVICE_CONSTRAINT_LABELS: Record<string, string> = {
  unavailable: '不可用',
  offline: '停机',
  rigid_load: '刚性负荷不可调',
  startup_unavailable: '启动条件不足',
  minimum_power_on_startup: '启动最小功率',
  maximum_power: '最大功率',
  minimum_power: '最小功率',
  available_power: '可用功率',
  maximum_discharge_power: '最大放电功率',
  maximum_charge_power: '最大充电功率',
  minimum_energy: '最低储能量',
  maximum_energy: '最高储能量',
  ramp_up: '上爬坡能力',
  ramp_down: '下爬坡能力'
}

const selectedDevices = computed(() => (selectedDeficitRow.value?.device_results ?? [])
  .map(device => ({
    key: `${device.device_type}:${device.device_id}`,
    type: device.device_type,
    label: props.deviceLabels?.[device.device_id]
      ?? `${DEVICE_TYPE_LABELS[device.device_type] ?? device.device_type} ${device.device_id}`,
    flexibility: Number(device.device_flexibility) || 0,
    contribution: Number(device.device_contribution) || 0,
    constraint: device.binding_constraint
      ? DEVICE_CONSTRAINT_LABELS[device.binding_constraint] ?? device.binding_constraint
      : '—'
  }))
  .sort((left, right) => right.contribution - left.contribution || left.label.localeCompare(right.label)))

const selectedDeviceTypes = computed(() => {
  const groups = new Map<string, number>()
  for (const device of selectedDevices.value) {
    groups.set(device.type, (groups.get(device.type) ?? 0) + device.contribution)
  }
  return [...groups.entries()]
    .map(([type, contribution]) => ({
      type,
      label: DEVICE_TYPE_LABELS[type] ?? type,
      contribution,
      color: contributionColorByType.value.get(type) ?? getDeviceColor(type)
    }))
    .filter(item => item.contribution > 0)
    .sort((left, right) => right.contribution - left.contribution)
})

const selectedContributionTotal = computed(() => selectedDeviceTypes.value
  .reduce((total, item) => total + item.contribution, 0))

function formatPower(value: unknown): string {
  const numeric = Number(value)
  return Number.isFinite(numeric)
    ? numeric.toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    : '—'
}

function showDeficitDetail(index: number): void {
  const row = domainRows.value[index]
  if (!row || Number(row.margin) >= 0) return
  selectedDeficitTimestamp.value = row.timestamp
  deficitDetailOpen.value = true
  renderContributionChart()
}

async function viewSelectedContribution(): Promise<void> {
  deficitDetailOpen.value = false
  await nextTick()
  contributionChartRef.value?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  const dataIndex = domainRows.value.findIndex(row => row.timestamp === selectedDeficitTimestamp.value)
  if (dataIndex >= 0) contributionChart?.dispatchAction({ type: 'showTip', seriesIndex: 0, dataIndex })
}

const sliderStepMinutes = computed(() => {
  const steps = directionRows.value
    .map(row => {
      const start = timeLabelToMinutes(row.timestamp)
      let end = timeLabelToMinutes(row.next_timestamp)
      if (end <= start) end += DAY_MINUTES
      return end - start
    })
    .filter(step => Number.isFinite(step) && step > 0)
  return Math.min(...steps, 5)
})

/** 仿真结束时间存在时以任务配置为准，否则按已有结果数据推导时间轴末端。 */
const sliderMax = computed(() => {
  let maxMinute = 0
  for (const row of props.rows) {
    const ts = timeLabelToMinutes(row.timestamp)
    let next = timeLabelToMinutes(row.next_timestamp)
    if (next <= ts) next += DAY_MINUTES
    if (next > maxMinute) maxMinute = next
  }
  maxMinute = maxMinute > 0 ? Math.ceil(maxMinute / 15) * 15 : DAY_MINUTES
  const simEnd = simEndMinutesComputed.value
  return Math.max(
    simStartMinutes.value + sliderStepMinutes.value,
    simEnd === null ? maxMinute : simEnd
  )
})

const updateDateRangeStart = (value: number) => {
  emit('update:displayWindow', {
    ...props.displayWindow,
    dateStart: value,
    start: value,
    end: dateRangeEndMinutes.value
  })
}

const updateDateRangeEnd = (value: number) => {
  emit('update:displayWindow', {
    ...props.displayWindow,
    dateEnd: value,
    start: dateRangeStartMinutes.value,
    end: value
  })
}

const zoomDomain = computed(() => ({
  start: dateRangeStartMinutes.value,
  end: Math.max(dateRangeStartMinutes.value + 1, dateRangeEndMinutes.value)
}))

const sharedZoom = useSharedDataZoom({
  getChart: () => chart,
  getPeerCharts: () => [contributionChart],
  getWindow: () => ({ start: rangeStartMinutes.value, end: rangeEndMinutes.value }),
  getDomain: () => zoomDomain.value,
  onWindowChange: (win) => {
    emit('update:displayWindow', { ...props.displayWindow, start: win.start, end: win.end })
  }
})

const contributionColorByDevice = computed(() => {
  const keys = new Set<string>()
  for (const row of props.rows) {
    for (const device of row.device_results ?? []) {
      keys.add(`${device.device_type}:${device.device_id}`)
    }
  }

  return new Map(
    [...keys]
      .sort((left, right) => left.localeCompare(right))
      .map((key) => {
        const [deviceType] = key.split(':')
        return [key, getDeviceColor(deviceType, key)] as const
      })
  )
})

const contributionTypeKeys = computed(() => {
  const keys = new Set<string>()
  for (const row of props.rows) {
    for (const device of row.device_results ?? []) {
      if (device.device_contribution == null) continue
      const contribution = Number(device.device_contribution)
      if (Number.isFinite(contribution) && contribution > 0) keys.add(device.device_type)
    }
  }
  return [...keys].sort((left, right) => left.localeCompare(right))
})

const contributionColorByType = computed(() => new Map(
  contributionTypeKeys.value.map((key) => [
    key,
    getDeviceColor(key)
  ] as const)
))

interface ContributionStackSeries {
  key: string
  label: string
  color: string
  data: Array<number | null>
}

const contributionStackSeries = computed<ContributionStackSeries[]>(() => contributionTypeKeys.value
  .map((deviceType) => {
    const data = domainRows.value.map((row) => {
      let hasValue = false
      let total = 0
      for (const device of row.device_results ?? []) {
        if (device.device_type !== deviceType) continue
        if (device.device_contribution == null) continue
        const contribution = Number(device.device_contribution)
        if (!Number.isFinite(contribution) || contribution < 0) continue
        hasValue = true
        total += contribution
      }
      return hasValue ? directionalDisplayValue(total) : null
    })

    return {
      key: deviceType,
      label: DEVICE_TYPE_LABELS[deviceType] ?? deviceType,
      color: contributionColorByType.value.get(deviceType) ?? getDeviceColor(deviceType),
      data
    }
  })
  .filter(series => series.data.some(value => value !== null && value !== 0)))

interface ContributionItem {
  key: string
  label: string
  value: number
  percentage: number
  color: string
}

const contributionItems = computed<ContributionItem[]>(() => {
  const totals = new Map<string, { label: string; value: number }>()

  for (const row of visibleRows.value) {
    const start = timeLabelToMinutes(row.timestamp)
    let end = timeLabelToMinutes(row.next_timestamp)
    if (end <= start) end += DAY_MINUTES
    const durationHours = Math.max(0, end - start) / 60

    for (const device of row.device_results ?? []) {
      const contribution = Number(device.device_contribution ?? device.device_flexibility)
      if (!Number.isFinite(contribution) || contribution <= 0) continue

      const key = `${device.device_type}:${device.device_id}`
      const fallbackLabel = `${DEVICE_TYPE_LABELS[device.device_type] ?? device.device_type} ${device.device_id}`
      const current = totals.get(key)
      totals.set(key, {
        label: props.deviceLabels?.[device.device_id] ?? fallbackLabel,
        value: (current?.value ?? 0) + contribution * durationHours
      })
    }
  }

  const sorted = [...totals.entries()]
    .map(([key, item]) => ({ key, ...item }))
    .sort((left, right) => right.value - left.value || left.label.localeCompare(right.label))
  const total = sorted.reduce((sum, item) => sum + item.value, 0)

  return sorted.map(item => ({
    ...item,
    percentage: total > 0 ? item.value / total * 100 : 0,
    color: contributionColorByDevice.value.get(item.key) ?? getDeviceColor(item.key)
  }))
})

const totalContribution = computed(() => contributionItems.value.reduce((sum, item) => sum + item.value, 0))

const emitAxisTimestamp = (event: { axesInfo?: Array<{ value?: string | number }> }) => {
  const axisValue = event.axesInfo?.[0]?.value
  if (axisValue == null) {
    emit('hoverTimestamp', null)
    return
  }

  const timestamp = typeof axisValue === 'string'
    ? axisValue
    : domainRows.value[Math.round(Number(axisValue))]?.timestamp
  emit('hoverTimestamp', timestamp ?? null)
}

interface ContributionTooltipItem {
  axisValue?: string | number
  axisValueLabel?: string
  dataIndex?: number
  marker?: string
  seriesName?: string
  seriesIndex?: number
  value?: unknown
}

const formatContributionTooltip = (params: unknown): string => {
  const rawItems = Array.isArray(params) ? params : [params]
  const items = rawItems.filter((item): item is ContributionTooltipItem =>
    typeof item === 'object' && item !== null
  )
  const valuedItems = items
    .map(item => ({ item, value: Number(item.value) }))
    .filter(entry => entry.item.value != null && Number.isFinite(entry.value))
  const axisValue = items[0]?.axisValue
  const timelineIndex = items[0]?.dataIndex ?? (typeof axisValue === 'number'
    ? axisValue
    : domainRows.value.findIndex(row => row.timestamp === String(axisValue ?? items[0]?.axisValueLabel ?? '')))
  const fullTotal = timelineIndex >= 0
    ? contributionStackSeries.value.reduce((sum, series) => {
        const value = series.data[timelineIndex]
        return sum + (value == null ? 0 : Math.abs(value))
      }, 0)
    : 0
  const visibleTotal = contributionDisplayMode.value === 'value'
    ? valuedItems.reduce((sum, entry) => sum + Math.abs(entry.value), 0)
    : 0
  const total = fullTotal > 0 ? fullTotal : visibleTotal
  const lines = [items[0]?.axisValueLabel ?? '']

  for (const { item, value } of valuedItems) {
    if (contributionDisplayMode.value === 'percentage') {
      const originalValue = item.seriesIndex === undefined || timelineIndex < 0
        ? null
        : contributionStackSeries.value[item.seriesIndex]?.data[timelineIndex]
      const originalLabel = originalValue == null ? '—' : `${originalValue.toFixed(2)} kW`
      lines.push(`${item.marker ?? ''}${item.seriesName ?? ''}：${value.toFixed(1)}%（${originalLabel}）`)
    }
    else {
      const percentage = total > 0 ? Math.abs(value) / total * 100 : 0
      lines.push(`${item.marker ?? ''}${item.seriesName ?? ''}：${value.toFixed(2)} kW（${percentage.toFixed(1)}%）`)
    }
  }

  const signedTotal = props.direction === 'down' ? -total : total
  lines.push(`贡献合计：${signedTotal.toFixed(2)} kW`)
  return lines.join('<br/>')
}

const renderSystemChart = () => {
  if (!chartRef.value) return
  chart ??= echarts.init(chartRef.value)

  const rows = domainRows.value

  // 负裕度叠加层在相邻采样值跨越零线时插入交点，避免孤立缺额只剩一个红点。
  const positiveMargin: Array<[number, number] | null> = []
  const negativeMargin: Array<[number, number] | null> = []
  rows.forEach((row, index) => {
    const value = Number(row.margin)
    if (index > 0) {
      const previous = Number(rows[index - 1]!.margin)
      if ((previous < 0) !== (value < 0)) {
        const crossing = index - 1 + Math.abs(previous) / (Math.abs(previous) + Math.abs(value))
        positiveMargin.push([crossing, 0])
        negativeMargin.push([crossing, 0])
      }
    }
    positiveMargin.push(value >= 0 ? [index, value] : null)
    negativeMargin.push(value < 0 ? [index, value] : null)
  })

  chart.setOption({
    animation: true,
    animationDuration: 300,
    animationDurationUpdate: 220,
    animationEasing: 'cubicOut',
    animationEasingUpdate: 'linear',
    color: ['#165DFF', '#F79009', '#12B76A'],
    title: {
      text: '',
      subtext: '      kW',
      left: 6,
      top: 6,
      subtextStyle: { fontSize: 10, color: '#667085' }
    },
    legend: {
      data: [
        { name: '系统供给', icon: SOLID_LINE_LEGEND_ICON },
        { name: '系统需求', icon: SOLID_LINE_LEGEND_ICON },
        { name: '裕度', icon: SOLID_LINE_LEGEND_ICON }
      ],
      right: 12,
      top: 10,
      itemWidth: 20,
      itemHeight: 8,
      textStyle: { fontSize: 12 },
      formatter: (name: string) => name === '裕度' ? '裕度（负值标红）' : name
    },
    grid: { left: 52, right: 18, top: 38, bottom: 48 },
    dataZoom: sharedZoom.buildDataZoom(),
    xAxis: {
      type: 'value',
      min: 0,
      max: Math.max(1, rows.length - 1),
      splitNumber: 12,
      splitLine: { show: false },
      axisLabel: {
        fontSize: 8,
        rotate: 45,
        formatter: (value: number) => {
          const row = rows[Math.round(value)]
          return row ? formatTimelineLabel(row.timestamp) : ''
        }
      },
      axisLine: { lineStyle: { color: '#D0D5DD' } }
    },
    yAxis: {
      type: 'value',
      axisLabel: { fontSize: 10 },
      splitLine: { lineStyle: { type: 'dashed', color: '#EAECF0' } }
    },
    tooltip: {
      trigger: 'axis',
      formatter: (params: unknown) => {
        const first = Array.isArray(params) ? params[0] : params
        const item = first as { axisValue?: number; dataIndex?: number } | undefined
        const axisIndex = Number(item?.axisValue)
        const index = Number.isFinite(axisIndex) ? Math.round(axisIndex) : item?.dataIndex
        const row = index === undefined ? undefined : rows[index]
        if (!row) return ''
        return [
          formatTimelineLabel(row.timestamp),
          `系统供给：${formatPower(row.system_supply)} kW`,
          `系统需求：${formatPower(row.requirement)} kW`,
          ...(marginVisible.value ? [
            `裕度：${formatPower(row.margin)} kW`,
            ...(Number(row.margin) < 0 ? [`<span style="color: ${DEFICIT_COLOR}; font-weight: 600">缺额：${formatPower(row.deficit)} kW（点击红色标记查看详情）</span>`] : [])
          ] : [])
        ].join('<br/>')
      }
    },
    series: [
      { id: 'supply', name: '系统供给', type: 'line', showSymbol: false, data: rows.map((row, index) => [index, directionalDisplayValue(row.system_supply)]) },
      { id: 'requirement', name: '系统需求', type: 'line', showSymbol: false, data: rows.map((row, index) => [index, directionalDisplayValue(row.requirement)]) },
      { id: 'margin', name: '裕度', type: 'line', showSymbol: false, data: marginVisible.value ? positiveMargin : [] },
      {
        id: 'negative-margin',
        name: '负裕度',
        type: 'line',
        showSymbol: false,
        connectNulls: false,
        z: 5,
        lineStyle: { color: DEFICIT_COLOR, width: 2.5 },
        itemStyle: { color: DEFICIT_COLOR },
        data: marginVisible.value ? negativeMargin : []
      },
      {
        id: 'deficit-hit',
        name: '缺额时段',
        type: 'scatter',
        symbolSize: 7,
        z: 6,
        itemStyle: { color: DEFICIT_COLOR },
        emphasis: { scale: 1.6 },
        data: marginVisible.value
          ? rows.flatMap((row, index) => Number(row.margin) < 0 ? [[index, row.margin]] : [])
          : []
      }
    ]
  }, {
    notMerge: false,
    lazyUpdate: true,
    replaceMerge: ['series']
  })
}

const renderContributionChart = () => {
  if (!contributionChartRef.value) return
  contributionChart ??= echarts.init(contributionChartRef.value)

  const timeline = domainRows.value.map(row => row.timestamp)
  const percentageMode = contributionDisplayMode.value === 'percentage'
  const totalByTimestamp = timeline.map((_, index) => contributionStackSeries.value.reduce((sum, item) => {
    const value = item.data[index]
    return sum + (value == null ? 0 : Math.abs(value))
  }, 0))
  const series: echarts.SeriesOption[] = contributionStackSeries.value.map((item, index) => ({
    id: `device-type-${item.key}`,
    name: item.label,
    type: 'bar',
    stack: 'device-contribution',
    barMaxWidth: 32,
    data: percentageMode
      ? item.data.map((value, index) => {
          const total = totalByTimestamp[index] ?? 0
          return value == null || total <= 0 ? null : Math.abs(value) / total * 100
        })
      : item.data,
    itemStyle: { color: item.color },
    emphasis: { focus: 'series' },
    ...(index === 0 && selectedDeficitTimestamp.value && domainRows.value.some(row => row.timestamp === selectedDeficitTimestamp.value)
      ? {
          markLine: {
            silent: true,
            symbol: 'none',
            label: { show: false },
            lineStyle: { color: DEFICIT_COLOR, type: 'dashed', width: 1.5 },
            data: [{ xAxis: selectedDeficitTimestamp.value }]
          }
        }
      : {})
  }))

  contributionChart.setOption({
    animation: true,
    animationDuration: 300,
    animationDurationUpdate: 220,
    animationEasing: 'cubicOut',
    animationEasingUpdate: 'linear',
    legend: {
      type: 'scroll',
      data: contributionStackSeries.value.map(item => item.label),
      right: 12,
      top: 6,
      itemWidth: 14,
      itemHeight: 8,
      textStyle: { fontSize: 11 }
    },
    grid: { left: 52, right: 18, top: 38, bottom: 48 },
    dataZoom: sharedZoom.buildDataZoom(),
    xAxis: {
      type: 'category',
      data: timeline,
      boundaryGap: true,
      axisLabel: {
        fontSize: 8,
        rotate: 45,
        interval: Math.max(0, Math.floor(timeline.length / 12)),
        formatter: (value: string) => formatTimelineLabel(value)
      },
      axisLine: { lineStyle: { color: '#D0D5DD' } }
    },
    yAxis: {
      type: 'value',
      name: percentageMode ? '%' : 'kW',
      nameTextStyle: { fontSize: 10, color: '#667085' },
      ...(percentageMode ? { min: 0, max: 100 } : {}),
      axisLabel: {
        fontSize: 10,
        ...(percentageMode ? { formatter: (value: number) => `${value}%` } : {})
      },
      splitLine: { lineStyle: { type: 'dashed', color: '#EAECF0' } }
    },
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      formatter: formatContributionTooltip
    },
    series
  }, {
    notMerge: false,
    lazyUpdate: true,
    replaceMerge: ['series', 'yAxis']
  })
}

const render = () => {
  renderSystemChart()
  renderContributionChart()
  sharedZoom.attachDataZoomEvents()
}

watch(
  [() => props.rows, () => props.direction, rangeStartMinutes, rangeEndMinutes, dateRangeStartMinutes, dateRangeEndMinutes],
  () => {
    render()
    sharedZoom.syncDataZoomFromWindow()
  }
)

watch(contributionDisplayMode, renderContributionChart)

onMounted(() => {
  render()
  chart?.on('legendselectchanged', (params) => {
    const visible = params.selected['裕度'] !== false
    if (marginVisible.value === visible) return
    marginVisible.value = visible
    if (!visible) {
      deficitDetailOpen.value = false
      selectedDeficitTimestamp.value = null
      chart?.dispatchAction({ type: 'hideTip' })
      renderContributionChart()
    }
    renderSystemChart()
  })
  chart?.on('click', (params) => {
    if (marginVisible.value && (params.seriesId === 'deficit-hit' || params.seriesId === 'negative-margin' || params.seriesId === 'margin')) {
      const x = Array.isArray(params.value) ? Number(params.value[0]) : params.dataIndex
      const candidates = [Math.floor(x), Math.ceil(x)]
        .filter(index => Number(domainRows.value[index]?.margin) < 0)
        .sort((left, right) => Math.abs(left - x) - Math.abs(right - x))
      if (candidates[0] !== undefined) showDeficitDetail(candidates[0])
    }
  })
  chart?.on('updateAxisPointer', emitAxisTimestamp)
  chart?.on('globalout', () => emit('hoverTimestamp', null))
  contributionChart?.on('updateAxisPointer', emitAxisTimestamp)
  contributionChart?.on('globalout', () => emit('hoverTimestamp', null))
  resizeObserver = new ResizeObserver(() => {
    chart?.resize()
    contributionChart?.resize()
  })
  resizeObserver.observe(chartRef.value!)
  resizeObserver.observe(contributionChartRef.value!)
})

onBeforeUnmount(() => {
  resizeObserver?.disconnect()
  chart?.dispose()
  contributionChart?.dispose()
  chart = null
  contributionChart = null
})
</script>

<template>
  <section class="border border-app-border bg-white px-4 py-2">
    <div class="flex items-center gap-3">
      <span class="text-base text-app-text">{{ directionLabel }}灵活性时序</span>
    </div>
    <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_240px]">
      <div class="relative min-w-0 h-64">
        <div
          v-if="visibleRows.length === 0"
          class="absolute inset-0 z-10 flex items-center justify-center bg-white text-sm text-app-muted"
        >
          所选时段暂无{{ directionLabel }}逐时段结果
        </div>
        <div ref="chartRef" class="h-64 w-full" />
      </div>

      <aside class="self-start px-3">
        <div class="flex items-start justify-between gap-2">
          <div>
            <h3 class="text-sm text-app-text">灵活性贡献度分析</h3>
          </div>
        </div>

        <div v-if="contributionItems.length" class="mt-3 flex h-48 min-h-0 gap-3">
          <div class="flex h-full w-12 shrink-0 flex-col overflow-hidden rounded-[6px] border border-white bg-white shadow-sm">
            <div
              v-for="item in contributionItems"
              :key="item.key"
              class="min-h-px w-full border-b border-white/80 last:border-b-0"
              :style="{ height: `${item.percentage}%`, backgroundColor: item.color }"
              :title="`${item.label} ${item.percentage.toFixed(1)}%`"
            />
          </div>
          <div class="min-w-0 flex-1 overflow-y-auto pr-1">
            <div
              v-for="item in contributionItems"
              :key="item.key"
              class="mb-2 flex items-center gap-2 last:mb-0"
            >
              <span class="h-2.5 w-2.5 shrink-0 rounded-sm" :style="{ backgroundColor: item.color }" />
              <span class="min-w-0 flex-1 truncate text-xs text-app-text" :title="item.label">{{ item.label }}</span>
              <span class="shrink-0 text-xs text-app-text">{{ item.percentage.toFixed(2) }}%</span>
            </div>
          </div>
        </div>
        <div v-else class="mt-3 flex h-48 items-center justify-center rounded-lg border border-dashed border-app-border bg-white text-center text-[11px] leading-5 text-app-muted">
          所选时段暂无设备贡献数据
        </div>
      </aside>
    </div>

    <div class="mt-3 border-t border-app-border pt-3">
      <div class="flex flex-wrap items-center justify-between gap-2 px-1">
        <div class="text-sm text-app-text">{{ directionLabel }}设备灵活性贡献构成（分时）</div>
        <div class="flex gap-2" role="group" :aria-label="`${directionLabel}设备贡献构成显示模式`">
          <AppButton
            label="值模式"
            size="sm"
            :tone="contributionDisplayMode === 'value' ? 'primary' : 'neutral'"
            @click="contributionDisplayMode = 'value'"
          />
          <AppButton
            label="百分比模式"
            size="sm"
            :tone="contributionDisplayMode === 'percentage' ? 'primary' : 'neutral'"
            @click="contributionDisplayMode = 'percentage'"
          />
        </div>
      </div>
      <div class="relative h-56 min-w-0">
        <div
          v-if="contributionStackSeries.length === 0"
          class="absolute inset-0 z-10 flex items-center justify-center bg-white text-sm text-app-muted"
        >
          所选时段暂无{{ directionLabel }}设备贡献数据
        </div>
        <div ref="contributionChartRef" class="h-56 w-full" />
      </div>
    </div>

    <div class="px-4">
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

  <AppModal
    :open="deficitDetailOpen && !!selectedDeficitRow"
    :title="`${directionLabel}缺额详情`"
    size="lg"
    @close="deficitDetailOpen = false"
  >
    <div v-if="selectedDeficitRow" class="space-y-4 px-4 py-3 text-sm text-app-text">
      <div class="font-medium">
        {{ formatTimelineLabel(selectedDeficitRow.timestamp) }} — {{ formatTimelineLabel(selectedDeficitRow.next_timestamp) }}
      </div>
      <div class="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <div class="rounded-lg bg-app-panel-soft p-3">系统供给<div class="mt-1 font-semibold">{{ formatPower(selectedDeficitRow.system_supply) }} kW</div></div>
        <div class="rounded-lg bg-app-panel-soft p-3">系统需求<div class="mt-1 font-semibold">{{ formatPower(selectedDeficitRow.requirement) }} kW</div></div>
        <div class="rounded-lg bg-app-panel-soft p-3">裕度<div class="mt-1 font-semibold text-red-600">{{ formatPower(selectedDeficitRow.margin) }} kW</div></div>
        <div class="rounded-lg bg-red-50 p-3 text-red-700">缺额<div class="mt-1 font-semibold">{{ formatPower(selectedDeficitRow.deficit) }} kW</div></div>
      </div>

      <div>
        <div class="flex items-center justify-between gap-2">
          <div class="font-medium">该时段设备调节能力与供给贡献</div>
          <button type="button" class="text-xs text-primary hover:underline" @click="viewSelectedContribution">查看分时贡献图</button>
        </div>
        <div v-if="selectedContributionTotal > 0" class="mt-2 flex h-5 overflow-hidden rounded-md" role="img" :aria-label="`该时段设备贡献合计 ${formatPower(selectedContributionTotal)} kW`">
          <div
            v-for="item in selectedDeviceTypes"
            :key="item.type"
            :style="{ width: `${item.contribution / selectedContributionTotal * 100}%`, backgroundColor: item.color }"
            :title="`${item.label}：${formatPower(item.contribution)} kW`"
          />
        </div>
        <div v-if="selectedDeviceTypes.length" class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs">
          <span v-for="item in selectedDeviceTypes" :key="item.type" class="flex items-center gap-1">
            <span class="h-2.5 w-2.5 rounded-sm" :style="{ backgroundColor: item.color }" />
            {{ item.label }} {{ formatPower(item.contribution) }} kW
          </span>
        </div>
        <div v-if="selectedDevices.length" class="mt-3 max-h-48 overflow-auto rounded-lg border border-app-border">
          <table class="w-full border-collapse text-left text-xs">
            <thead class="sticky top-0 bg-app-panel-soft"><tr>
              <th class="px-3 py-2 font-medium">设备</th>
              <th class="px-3 py-2 font-medium">可调能力（kW）</th>
              <th class="px-3 py-2 font-medium">计入供给（kW）</th>
              <th class="px-3 py-2 font-medium">设备约束</th>
            </tr></thead>
            <tbody><tr v-for="device in selectedDevices" :key="device.key" class="border-t border-app-border">
              <td class="px-3 py-2">{{ device.label }}</td>
              <td class="px-3 py-2">{{ formatPower(device.flexibility) }}</td>
              <td class="px-3 py-2">{{ formatPower(device.contribution) }}</td>
              <td class="px-3 py-2">{{ device.constraint }}</td>
            </tr></tbody>
          </table>
        </div>
        <p v-else class="mt-2 text-xs text-app-muted">该时段没有可展示的设备结果。</p>
      </div>
    </div>
  </AppModal>
</template>
