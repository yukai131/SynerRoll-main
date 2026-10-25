<script setup lang="ts">
import * as echarts from 'echarts'
import type { TaskTraceStep } from '~~/types/api'
import { downloadText } from '~~/utils/download'
import {
  convertDeviceOutputValue,
  defaultDisplayUnit,
  minutesToTimestamp,
  timestampToMinutes,
  type DeviceOutputLiveData,
  type DeviceOutputVariable
} from '~~/utils/deviceOutputData'
import { formatCalendarMinute } from '~~/utils/calendarTime'
import { downsampleTimeSeries } from '~~/utils/chart-downsample'
import { getDeviceColor, getLayerColor } from '~~/config/device-colors'

interface AxisGroup {
  dimension: string
  label: string
  unit: string
  variables: DeviceOutputVariable[]
}

interface DisplayedSeries {
  variable: DeviceOutputVariable
  layerId: string
  name: string
}

type VariableLineType = 'solid' | 'dashed' | 'dotted' | number[]

const VARIABLE_LINE_TYPES: readonly VariableLineType[] = [
  'solid',
  'dashed',
  'dotted',
  [10, 4, 2, 4],
  [12, 4, 2, 4, 2, 4],
  [4, 3, 12, 3]
]

const props = defineProps<{
  chartId: string
  title: string
  selectedKeys: string[]
  variables: DeviceOutputVariable[]
  liveData: DeviceOutputLiveData
  layerIds: string[]
  layerLabels: Record<string, string>
  unitSelections: Record<string, string>
  zoomStart: number
  zoomEnd: number
  /** 同标签页共享的日期粗窗（分钟） */
  dateRangeStart: number
  dateRangeEnd: number
  analysisMode: 'range' | 'point'
  traceStep: number | null
  traceOptions: TaskTraceStep[]
  traceLoading: boolean
  traceError?: string
  minimumMinute?: number
  maximumMinute?: number
  simStartDate?: string | null
}>()

const formatTimelineLabel = (minute: number): string =>
  formatCalendarMinute(props.simStartDate, minute)

const emit = defineEmits<{
  delete: []
  editVariables: []
  'update:title': [value: string]
  'update:unit': [payload: { dimension: string; unit: string }]
  'update:zoom': [payload: { start: number; end: number }]
  'update:dateRange': [payload: { start: number; end: number }]
  'update:mode': [value: 'range' | 'point']
  'update:traceStep': [value: number]
}>()

const chartRef = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null
let resizeObserver: ResizeObserver | null = null

const selectedVariables = computed(() => {
  const byKey = new Map(props.variables.map(variable => [variable.key, variable]))
  return props.selectedKeys.map(key => byKey.get(key)).filter((item): item is DeviceOutputVariable => Boolean(item))
})

function preferredVariableLineIndex(variable: DeviceOutputVariable): number {
  const name = variable.baseVarName.toUpperCase()
  if (name.includes('_CUT') || name.includes('SHORTAGE') || name.includes('EXCESS')) return 2
  if (name.startsWith('AVAILABLE_')) return 1
  if (name.startsWith('MINIMUM_') || name.startsWith('MAXIMUM_')) return 3
  if (/(?:^|_)IN(?:_|$)/.test(name)) return 1
  if (/(?:^|_)OUT(?:_|$)/.test(name)) return 0
  if (['ES', 'HS', 'PS', 'FS', 'CS'].includes(variable.componentType.toUpperCase())) return 2
  if (variable.medium === 'thermal') return 1
  if (variable.medium === 'fuel') return 2
  if (variable.medium === 'hydrogen') return 3
  return 0
}

/** 同一设备内按完整变量目录稳定分配线型，避免随当前勾选顺序变化。 */
const variableLineTypeByKey = computed(() => {
  const variablesByDevice = new Map<string, DeviceOutputVariable[]>()
  for (const variable of props.variables) {
    const variables = variablesByDevice.get(variable.deviceId) ?? []
    variables.push(variable)
    variablesByDevice.set(variable.deviceId, variables)
  }

  const result = new Map<string, VariableLineType>()
  for (const variables of variablesByDevice.values()) {
    const used = new Set<number>()
    const sorted = [...variables].sort((left, right) => left.key.localeCompare(right.key))
    for (const variable of sorted) {
      const preferred = preferredVariableLineIndex(variable)
      let selected = preferred
      for (let offset = 0; offset < VARIABLE_LINE_TYPES.length; offset += 1) {
        const candidate = (preferred + offset) % VARIABLE_LINE_TYPES.length
        if (!used.has(candidate)) {
          selected = candidate
          break
        }
      }
      used.add(selected)
      result.set(variable.key, VARIABLE_LINE_TYPES[selected]!)
    }
  }
  return result
})

/** 用纯线段路径替代默认“线段＋圆点”图例，使短图例中也能辨认划线节奏。 */
function legendIconForLineType(lineType: VariableLineType): string {
  const signature = Array.isArray(lineType) ? lineType.join(',') : lineType
  const paths: Record<string, string> = {
    solid: 'path://M0 4H36V6H0Z',
    dashed: 'path://M0 4H8V6H0Z M12 4H20V6H12Z M24 4H32V6H24Z',
    dotted: 'path://M0 4H2V6H0Z M6 4H8V6H6Z M12 4H14V6H12Z M18 4H20V6H18Z M24 4H26V6H24Z M30 4H32V6H30Z',
    '10,4,2,4': 'path://M0 4H10V6H0Z M14 4H16V6H14Z M20 4H30V6H20Z M34 4H36V6H34Z',
    '12,4,2,4,2,4': 'path://M0 4H12V6H0Z M16 4H18V6H16Z M22 4H24V6H22Z M28 4H36V6H28Z',
    '4,3,12,3': 'path://M0 4H4V6H0Z M7 4H19V6H7Z M22 4H26V6H22Z M29 4H36V6H29Z'
  }
  return paths[signature] ?? paths.solid!
}

const axisGroups = computed<AxisGroup[]>(() => {
  const groups = new Map<string, AxisGroup>()
  for (const variable of selectedVariables.value) {
    const existing = groups.get(variable.dimension)
    if (existing) {
      existing.variables.push(variable)
      continue
    }
    groups.set(variable.dimension, {
      dimension: variable.dimension,
      label: variable.dimensionLabel,
      unit: props.unitSelections[variable.dimension]
        ?? defaultDisplayUnit(variable.dimension, variable.originalUnit),
      variables: [variable]
    })
  }
  return [...groups.values()]
})

const orderedLayerIds = computed(() => [...props.layerIds]
  .sort((left, right) => Number(left) - Number(right)))

const displayedSeries = computed<DisplayedSeries[]>(() => selectedVariables.value.flatMap((variable) => (
  orderedLayerIds.value
    .filter(layerId => variable.layerIds.includes(layerId))
    .map(layerId => ({
      variable,
      layerId,
      name: props.layerIds.length > 1
        ? `${variable.displayName} - ${props.layerLabels[layerId] ?? `时层${layerId}`}`
        : variable.displayName
    }))
)))

const dataMinutes = computed(() => displayedSeries.value.flatMap((item) => {
  const points = props.liveData[item.variable.key]?.[item.layerId] ?? []
  return points.map(point => timestampToMinutes(point.ts))
}).filter(Number.isFinite))

const minimumMinute = computed(() => {
  if (props.minimumMinute !== undefined) return props.minimumMinute
  if (props.analysisMode !== 'point' || !dataMinutes.value.length) return 0
  return Math.min(...dataMinutes.value)
})

const maximumMinute = computed(() => {
  const dataMaximum = Math.max(0, ...dataMinutes.value)
  if (props.analysisMode === 'point') {
    if (props.layerIds.includes('1')) return props.maximumMinute || 1440
    return dataMaximum || props.maximumMinute || 1440
  }
  if (props.maximumMinute && props.maximumMinute > 0) {
    return props.maximumMinute
  }
  return dataMaximum || 1440
})

const xAxisInterval = computed(() => {
  // 时间段窗口按可见跨度自动分配刻度，避免全年范围逐小时堆叠标签。
  if (props.analysisMode === 'range') return undefined
  return props.layerIds.includes('3') ? 15 : 60
})

const dateRangeStartMinute = computed(() => props.dateRangeStart)
const dateRangeEndMinute = computed(() => props.dateRangeEnd)
const timelineSpanMinutes = computed(() => Math.max(1, maximumMinute.value - minimumMinute.value))
const rangeStartMinute = computed(() => minimumMinute.value + timelineSpanMinutes.value * props.zoomStart / 100)
const rangeEndMinute = computed(() => minimumMinute.value + timelineSpanMinutes.value * props.zoomEnd / 100)
const hourlyTicks = computed(() => {
  const ticks = Array.from(
    { length: Math.floor(maximumMinute.value / 60) + 1 },
    (_, hour) => minutesToTimestamp(hour * 60)
  )
  if (maximumMinute.value % 60 !== 0) ticks.push(minutesToTimestamp(maximumMinute.value))
  return ticks
})
const selectedTrace = computed(() => props.traceOptions.find(option => option.step === props.traceStep))
const selectedLayerLabel = computed(() => props.layerIds
  .map(layerId => props.layerLabels[layerId] ?? `时层${layerId}`)
  .join('、'))
const hasDisplayedPoints = computed(() => displayedSeries.value.some(item => convertedPoints(item.variable, item.layerId).length > 0))

function selectedUnit(variable: DeviceOutputVariable): string {
  return axisGroups.value.find(group => group.dimension === variable.dimension)?.unit ?? variable.originalUnit
}

function convertedPoints(variable: DeviceOutputVariable, layerId: string): [number, number][] {
  const unit = selectedUnit(variable)
  const pts = (props.liveData[variable.key]?.[layerId] ?? [])
    .map(point => [
      timestampToMinutes(point.ts),
      convertDeviceOutputValue(Number(point.value), variable.originalUnit, unit, variable.dimension)
    ] as [number, number])
    .filter(([minute, value]) => minute >= 0 && minute <= maximumMinute.value && Number.isFinite(value))
  // 显示抽稀：缩放后回到全精度（只影响图，不影响原始 liveData）
  return downsampleTimeSeries(pts, rangeStartMinute.value, rangeEndMinute.value)
}

function formatNumber(value: number): string {
  const absolute = Math.abs(value)
  const digits = absolute >= 1000 ? 0 : absolute >= 100 ? 1 : absolute >= 1 ? 2 : 3
  return value.toLocaleString('zh-CN', { maximumFractionDigits: digits })
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}

function axisSide(index: number): { position: 'left' | 'right'; offset: number } {
  const position = index % 2 === 0 ? 'left' : 'right'
  return { position, offset: Math.floor(index / 2) * 54 }
}

function render(): void {
  if (!chartRef.value || selectedVariables.value.length === 0) return
  if (!chart) {
    chart = echarts.init(chartRef.value)
  }
  if (!resizeObserver) {
    resizeObserver = new ResizeObserver(() => chart?.resize())
    resizeObserver.observe(chartRef.value)
  }

  const axisIndex = new Map(axisGroups.value.map((group, index) => [group.dimension, index]))
  const leftAxisCount = Math.ceil(axisGroups.value.length / 2)
  const rightAxisCount = Math.floor(axisGroups.value.length / 2)
  const series: echarts.SeriesOption[] = displayedSeries.value.map((item) => {
    const variable = item.variable
    const layerIndex = orderedLayerIds.value.indexOf(item.layerId)
    const color = getLayerColor(
      getDeviceColor(variable.componentType, variable.deviceId),
      Math.max(0, layerIndex),
      orderedLayerIds.value.length
    )
    const lineType = variableLineTypeByKey.value.get(variable.key) ?? 'solid'
    return {
      id: `${variable.key}|${item.layerId}`,
      name: item.name,
      type: 'line',
      yAxisIndex: axisIndex.get(variable.dimension) ?? 0,
      data: convertedPoints(variable, item.layerId),
      showSymbol: false,
      symbolSize: 5,
      smooth: false,
      sampling: 'lttb',
      connectNulls: false,
      lineStyle: { width: 2, color, type: lineType },
      itemStyle: { color },
      emphasis: { focus: 'none', lineStyle: { width: 3 } }
    } satisfies echarts.LineSeriesOption
  })

  chart.setOption({
    animation: false,
    animationDuration: 260,
    color: displayedSeries.value.map((item) => {
      const layerIndex = orderedLayerIds.value.indexOf(item.layerId)
      return getLayerColor(
        getDeviceColor(item.variable.componentType, item.variable.deviceId),
        Math.max(0, layerIndex),
        orderedLayerIds.value.length
      )
    }),
    legend: {
      type: 'scroll',
      orient: 'horizontal',
      top: 8,
      left: 24,
      right: 24,
      height: 24,
      data: displayedSeries.value.map(item => ({
        name: item.name,
        icon: legendIconForLineType(variableLineTypeByKey.value.get(item.variable.key) ?? 'solid')
      })),
      itemWidth: 20,
      itemHeight: 10,
      pageIconSize: 10,
      pageTextStyle: { fontSize: 10, color: '#667085' },
      textStyle: { fontSize: 10, color: '#4E5969' }
    },
    grid: {
      left: 96 + Math.max(0, leftAxisCount - 1) * 54,
      right: 64 + Math.max(0, rightAxisCount - 1) * 54,
      top: 64,
      bottom: 48,
      containLabel: false
    },
    xAxis: {
      type: 'value',
      min: minimumMinute.value,
      max: maximumMinute.value,
      interval: xAxisInterval.value,
      splitNumber: 5,
      axisLine: { lineStyle: { color: '#C9CDD4' } },
      axisTick: { show: false },
      axisLabel: {
        color: '#86909C',
        fontSize: 10,
        hideOverlap: true,
        formatter: (value: number) => formatTimelineLabel(value)
      },
      splitLine: { show: false }
    },
    yAxis: axisGroups.value.map((group, index) => {
      const side = axisSide(index)
      return {
        type: 'value',
        name: `${group.label} / ${group.unit}`,
        nameLocation: 'end',
        nameGap: 10,
        position: side.position,
        offset: side.offset,
        scale: true,
        nameTextStyle: {
          color: '#667085',
          fontSize: 10,
          align: side.position === 'left' ? 'right' : 'left'
        },
        axisLine: { show: true, lineStyle: { color: '#98A2B3' } },
        axisTick: { show: false },
        axisLabel: {
          color: '#86909C',
          fontSize: 10,
          formatter: (value: number) => formatNumber(value)
        },
        splitLine: index === 0
          ? { lineStyle: { color: '#E5E6EB', type: 'dashed' } }
          : { show: false }
      }
    }),
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'cross', lineStyle: { color: '#86909C' } },
      confine: true,
      formatter: (params: unknown) => {
        const items = Array.isArray(params)
          ? params as Array<{ data?: [number, number]; seriesIndex?: number; marker?: string; seriesName?: string }>
          : []
        if (!items.length) return ''
        const minute = Number(items[0]?.data?.[0] ?? 0)
        let html = `<div style="font-weight:600;margin-bottom:6px">${formatTimelineLabel(minute)}</div>`
        for (const item of items) {
          const displayed = displayedSeries.value[item.seriesIndex ?? -1]
          const variable = displayed?.variable
          const value = Number(item.data?.[1])
          if (!variable || !Number.isFinite(value)) continue
          html += `<div style="display:flex;gap:12px;justify-content:space-between;min-width:220px">`
          html += `<span>${item.marker ?? ''}${escapeHtml(item.seriesName ?? variable.displayName)}</span>`
          html += `<b>${formatNumber(value)} ${escapeHtml(selectedUnit(variable))}</b></div>`
        }
        return html
      }
    },
    dataZoom: [
      {
        type: 'inside',
        start: props.analysisMode === 'range' ? props.zoomStart : 0,
        end: props.analysisMode === 'range' ? props.zoomEnd : 100,
        filterMode: 'none',
        zoomOnMouseWheel: true,
        moveOnMouseWheel: true,
        moveOnMouseMove: true
      },
      {
        type: 'slider',
        start: props.analysisMode === 'range' ? props.zoomStart : 0,
        end: props.analysisMode === 'range' ? props.zoomEnd : 100,
        filterMode: 'none',
        height: 18,
        bottom: 4
      }
    ],
    series
  }, {
    notMerge: true,
    lazyUpdate: true
  })

  chart.off('datazoom')
  chart.on('datazoom', handleDataZoomEvent)
}



const traceCommittedIndex = computed(() => {
  const index = props.traceOptions.findIndex(option => option.step === props.traceStep)
  return Math.max(0, index)
})

const traceDraftIndex = ref(0)

watch([
  () => props.traceStep,
  () => props.traceOptions.map(option => option.step).join('|')
], () => {
  traceDraftIndex.value = traceCommittedIndex.value
}, { immediate: true })

const tracePreview = computed(() => {
  const maximumIndex = Math.max(0, props.traceOptions.length - 1)
  const index = Math.min(maximumIndex, Math.max(0, traceDraftIndex.value))
  return props.traceOptions[index] ?? selectedTrace.value
})

const traceTicks = computed(() => {
  const maximumIndex = Math.max(1, props.traceOptions.length - 1)
  return props.traceOptions.flatMap((option, index, options) => {
    const minute = timestampToMinutes(option.simTime)
    if (index !== 0 && index !== options.length - 1 && minute % 60 !== 0) return []
    const percentage = index / maximumIndex * 100
    const transform = index === 0
      ? 'translateX(0)'
      : index === options.length - 1
        ? 'translateX(-100%)'
        : 'translateX(-50%)'
    return [{ ...option, style: { left: `${percentage}%`, transform } }]
  })
})

const traceSelectionStyle = computed(() => {
  const maximumIndex = Math.max(1, props.traceOptions.length - 1)
  return { width: `${traceDraftIndex.value / maximumIndex * 100}%` }
})

const traceLabelStyle = computed(() => {
  const maximumIndex = Math.max(1, props.traceOptions.length - 1)
  const percentage = traceDraftIndex.value / maximumIndex * 100
  const transform = percentage <= 1
    ? 'translateX(0)'
    : percentage >= 99
      ? 'translateX(-100%)'
      : 'translateX(-50%)'
  return { left: `${percentage}%`, transform }
})

function updateTracePreview(event: Event): void {
  const maximumIndex = Math.max(0, props.traceOptions.length - 1)
  traceDraftIndex.value = Math.min(maximumIndex, Math.max(0, Math.round(Number((event.target as HTMLInputElement).value))))
}

function commitTraceStep(event: Event): void {
  updateTracePreview(event)
  const index = traceDraftIndex.value
  const option = props.traceOptions[index]
  if (option && option.step !== props.traceStep) emit('update:traceStep', option.step)
}

const visibleRangeLabel = computed(() => {
  return `${formatTimelineLabel(rangeStartMinute.value)} - ${formatTimelineLabel(rangeEndMinute.value)}`
})

function onDateRangeStartUpdate(startMinute: number): void {
  emit('update:dateRange', { start: startMinute, end: props.dateRangeEnd })
  emit('update:zoom', {
    start: (startMinute - minimumMinute.value) / timelineSpanMinutes.value * 100,
    end: (props.dateRangeEnd - minimumMinute.value) / timelineSpanMinutes.value * 100
  })
}

function onDateRangeEndUpdate(endMinute: number): void {
  emit('update:dateRange', { start: props.dateRangeStart, end: endMinute })
  emit('update:zoom', {
    start: (props.dateRangeStart - minimumMinute.value) / timelineSpanMinutes.value * 100,
    end: (endMinute - minimumMinute.value) / timelineSpanMinutes.value * 100
  })
}

/** 图内 dataZoom（替代 PrimaryDualRangeSlider）→ 回写共享 zoom 百分比 */
function handleDataZoomEvent(params: unknown): void {
  const raw = params as { batch?: Array<{ start?: number; end?: number }> } | { start?: number; end?: number } | null
  const item = Array.isArray((raw as { batch?: unknown })?.batch)
    ? (raw as { batch: Array<{ start?: number; end?: number }> }).batch[0]
    : (raw as { start?: number; end?: number } | null)
  if (!item || item.start === undefined || item.end === undefined) return
  const start = Math.min(100, Math.max(0, Number(item.start)))
  const end = Math.min(100, Math.max(0, Number(item.end)))
  if (Math.abs(start - props.zoomStart) < 0.05 && Math.abs(end - props.zoomEnd) < 0.05) return
  emit('update:zoom', { start: Math.min(start, end), end: Math.max(start, end) })
}

function csvCell(value: string): string {
  return `"${value.replaceAll('"', '""')}"`
}

function exportCsv(): void {
  if (!displayedSeries.value.length) return
  const rangeStart = props.analysisMode === 'point' ? minimumMinute.value : rangeStartMinute.value
  const rangeEnd = props.analysisMode === 'point' ? maximumMinute.value : rangeEndMinute.value
  const timestamps = [...new Set(displayedSeries.value.flatMap(item => convertedPoints(item.variable, item.layerId).map(point => point[0])))]
    .filter(minute => minute >= rangeStart && minute <= rangeEnd)
    .sort((a, b) => a - b)
  const valueMaps = displayedSeries.value.map(item => new Map(convertedPoints(item.variable, item.layerId)))
  const header = ['时间', ...displayedSeries.value.map(item => `${item.name} (${selectedUnit(item.variable)})`)]
  const rows = [header.map(csvCell).join(',')]
  for (const minute of timestamps) {
    const values = valueMaps.map(map => map.has(minute) ? String(map.get(minute)) : '')
    rows.push([formatTimelineLabel(minute), ...values].map(csvCell).join(','))
  }
  const safeTitle = props.title.trim().replace(/[\\/:*?"<>|]/g, '_') || '设备出力分析'
  downloadText(`${safeTitle}.csv`, `﻿${rows.join('\r\n')}`, 'text/csv;charset=utf-8')
}

function destroyChart(): void {
  resizeObserver?.disconnect()
  resizeObserver = null
  chart?.dispose()
  chart = null
}

watch(
  [minimumMinute, maximumMinute],
  ([minimum, maximum]) => {
    if (props.dateRangeStart !== minimum || props.dateRangeEnd !== maximum) {
      emit('update:dateRange', { start: minimum, end: maximum })
    }
  },
  { immediate: true }
)

watch([
  () => props.selectedKeys,
  () => props.variables,
  () => props.liveData,
  () => props.layerIds,
  () => props.layerLabels,
  axisGroups,
  () => props.analysisMode,
  () => props.traceStep,
  () => props.maximumMinute,
  () => props.minimumMinute,
  () => props.simStartDate,
  () => props.zoomStart,
  () => props.zoomEnd
], () => {
  if (!selectedVariables.value.length) {
    destroyChart()
    return
  }
  void nextTick(render)
})

onMounted(() => {
  render()
})

onBeforeUnmount(() => {
  destroyChart()
})
</script>

<template>
  <section
    class="flex flex-col border border-app-border bg-white"
  >
    <div class="flex flex-wrap items-center gap-2 border-b border-app-border px-3 py-2.5">
      <input
        :value="title"
        type="text"
        class="min-w-[220px] flex-1 border border-transparent bg-transparent px-2 transition hover:border-app-border focus:border-primary"
        aria-label="图表标题"
        @input="emit('update:title', ($event.target as HTMLInputElement).value)"
      >
      <AppButton :label="`变量选择（${selectedVariables.length}）`" size="sm" tone="primary" @click="emit('editVariables')" />
      <AppButton label="导出数据" size="sm" tone="neutral" :disabled="!selectedVariables.length" @click="exportCsv" />
      <AppButton label="删除视图" size="sm" tone="danger" @click="emit('delete')" />
    </div>

    <div v-if="selectedVariables.length" class="flex flex-1 flex-col">
      <div class="relative min-h-[360px] flex-1">
        <div ref="chartRef" class="h-full min-h-[360px] w-full" />
        <div
          v-if="analysisMode === 'point' && traceLoading"
          class="absolute inset-0 flex items-center justify-center bg-white/75 text-sm text-app-muted"
        >
          正在读取历史滚动求解快照...
        </div>
        <div
          v-else-if="analysisMode === 'point' && traceStep !== null && !hasDisplayedPoints && !traceError"
          class="absolute inset-0 flex items-center justify-center bg-white/75 text-sm text-app-muted"
        >
          该历史求解版本中没有所选变量的结果数据
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-3 border-t border-app-border px-4 py-2.5 text-xs">
        <span class="ml-auto text-app-muted">当前范围 {{ visibleRangeLabel }}</span>
      </div>

      <div class="px-5">
        <CalendarRangeInputs
          v-if="simStartDate"
          :base-date="simStartDate"
          :start="dateRangeStartMinute"
          :end="dateRangeEndMinute"
          :min="minimumMinute"
          :max="maximumMinute"
          @update:start="onDateRangeStartUpdate"
          @update:end="onDateRangeEndUpdate"
        />
      </div>
    </div>

    <div v-else class="flex h-[360px] flex-col items-center justify-center gap-3 text-center">
      <div class="flex h-12 w-12 items-center justify-center rounded-full bg-primary-soft text-xl text-primary">＋</div>
      <div>
        <p class="text-sm font-medium text-app-text">尚未选择设备变量</p>
        <p class="mt-1 text-xs text-app-muted">选择同一设备的多个变量，或对比多个设备的出力</p>
      </div>
      <AppButton label="选择设备变量" size="sm" tone="primary" @click="emit('editVariables')" />
    </div>
  </section>
</template>

<style scoped>
.device-output-trace-input {
  height: 20px;
  margin: 0;
  background: transparent;
  cursor: pointer;
  appearance: none;
  pointer-events: none;
}

.device-output-trace-input::-webkit-slider-runnable-track {
  height: 4px;
  background: transparent;
}

.device-output-trace-input::-webkit-slider-thumb {
  width: 14px;
  height: 14px;
  margin-top: -5px;
  border: 2px solid #0A4DA2;
  border-radius: 50%;
  background: #fff;
  cursor: grab;
  appearance: none;
  pointer-events: auto;
}

.device-output-trace-input::-moz-range-track {
  height: 4px;
  background: transparent;
}

.device-output-trace-input::-moz-range-thumb {
  width: 14px;
  height: 14px;
  border: 2px solid #0A4DA2;
  border-radius: 50%;
  background: #fff;
  cursor: grab;
  pointer-events: auto;
}

.device-output-trace-input:disabled {
  cursor: default;
  opacity: 0.6;
}

.device-output-trace-input:disabled::-webkit-slider-thumb {
  cursor: default;
}

.device-output-trace-input:disabled::-moz-range-thumb {
  cursor: default;
}

.device-output-trace-input:focus-visible::-webkit-slider-thumb {
  outline: 2px solid rgba(10, 77, 162, 0.35);
  outline-offset: 3px;
}
</style>
