<script setup lang="ts">
import type {
  ComputeTask,
  ComputeTaskListResponse,
  DeviceFlexibilityResult,
  EconomyEvaluationResult,
  FlexibilityRequirementSource,
  FlexibilitySummaryResult,
  FlexibilityTaskConfig,
  FlexibilityValueSpec,
  TaskFlexibilityResponse
} from '~~/types/api'
import type { Project } from '~~/types/project'
import type { BoundaryItem } from '~~/types/boundary'
import type { FlexibilityDisplayWindow } from '~~/types/flexibility-display'
import type { ChartDisplayWindow } from '~~/utils/display-window'
import {
  createDisplayWindow,
  followDataEnd
} from '~~/utils/display-window'
import { useTaskApi } from '~~/composables/api/useTaskApi'
import { useTaskWebSocket } from '~~/composables/api/useTaskWebSocket'
import { useProjectApi } from '~~/composables/api/useProjectApi'
import { useToastCenter } from '~~/state/ui'
import { parseVariableKey, getVariableDisplayName } from '~~/config/component-meta'
import { getResultDisplayUnit } from '~~/utils/result-units'
import {
  FLEXIBILITY_REQUIREMENT_LABELS,
  FLEXIBILITY_REQUIREMENT_OPTIONS
} from '~~/config/flexibility'
import {
  timeLabelToMinutes,
  minutesToTimeLabel
} from '~~/utils/timeLabel'
import {
  DEFAULT_BOUNDARY_START_DATE,
  deriveCalendarEndDate,
  inclusiveCalendarDayCount,
  isDateOnly
} from '~~/utils/calendarTime'
import PropertyText from '../../components/PropertyText.vue'
import PropertySelect from '../../components/PropertySelect.vue'
import DeviceOutputAnalysis from '~/components/DeviceOutputAnalysis.vue'
import FlexibilityDemandComparisonModal from '~/components/FlexibilityDemandComparisonModal.vue'
import PieChart from '~/components/PieChart.vue'
import ResultChartsSkeleton from '~/components/ResultChartsSkeleton.vue'
import { getDeviceColor, getLayerColor } from '~~/config/device-colors'

definePageMeta({ title: '结果分析 - SynerRoll' })

function durationToMinutes(duration: string): number | null {
  const match = /^(\d+)(h|m|s)$/.exec(duration.trim())
  if (!match) return null
  const value = Number(match[1])
  if (match[2] === 'h') return value * 60
  if (match[2] === 'm') return value
  return value % 60 === 0 ? value / 60 : null
}

const taskApi = useTaskApi()
const projectApi = useProjectApi()
const { connect } = useTaskWebSocket()
const { push } = useToastCenter()

// ───── 分析栏目 ─────
interface AnalysisSection {
  key: string
  label: string
  icon: string
}

const sections: AnalysisSection[] = [
  { key: 'overview', label: '运行总览', icon: '' },
  { key: 'energy-flow', label: '能流平衡分析', icon: '' },
  { key: 'device-output', label: '设备出力分析', icon: '' },
  { key: 'economy', label: '经济性分析', icon: '' },
  { key: 'flexibility', label: '系统灵活性量化评估', icon: '' },
  { key: 'device-flexibility', label: '设备灵活性量化评估', icon: '' },
]

const activeSection = ref<string>('overview')

// ───── 当前选中的任务 ─────
const selectedTaskId = ref<string | null>(null)
const selectedTask = ref<ComputeTask | null>(null)
/** 创建后立刻出壳，后台补齐项目/灵活性 */
const resultShellLoading = ref(false)
const currentProject = ref<Project | null>(null)

/** 当前任务的仿真范围；end 为 null 时回退到时层 1 的 length */
const taskSimRange = computed(() => {
  const start = selectedTask.value?.sim_start_time ?? '0:00'
  const end = selectedTask.value?.sim_end_time ?? null

  let endMinutes = end ? timeLabelToMinutes(end) : null
  if (endMinutes === null) {
    const layer1 = currentProject.value?.layerConfig?.layers.find(l => l.id === '1')
    const length = layer1?.length
    if (length) {
      const match = /^(\d+)(h|m|s)$/.exec(String(length).trim())
      if (match) {
        const value = parseInt(match[1], 10)
        const unit = match[2]
        if (unit === 'h') endMinutes = value * 60
        else if (unit === 'm') endMinutes = value
        else if (unit === 's') endMinutes = value / 60
      }
    }
    if (endMinutes === null) endMinutes = 24 * 60
  }

  return { start, end, endMinutes }
})

// ───── 任务列表弹窗 ─────
const showTaskListDialog = ref(false)

// ───── 新建任务弹窗 ─────
const showCreateDialog = ref(false)
const creatingTask = ref(false)

// ───── 层名称映射 ─────
const layerNames = computed<Record<string, string>>(() => {
  if (!currentProject.value?.layerConfig?.layers) return {}
  const result: Record<string, string> = {}
  for (const layer of currentProject.value.layerConfig.layers) {
    result[layer.id] = layer.name
  }
  return result
})

// ───── 能流平衡分析 ─────
interface BusConnection {
  busLabel: string
  busCode: string
  variables: string[]
}

type EnergyFlowDisplayMode = 'balance' | 'loadTracking'

const connectionData = ref<BusConnection[]>([])
const energyFlowDisplayMode = ref<EnergyFlowDisplayMode>('balance')

const loadConnectionData = async (taskId: string) => {
  try {
    const res = await taskApi.getConnection(taskId)
    connectionData.value = Array.isArray(res) ? res : []
  }
  catch (e) {
    console.warn('[EnergyFlow] loadConnectionData error:', e)
    connectionData.value = []
  }
}

// 时层选项（从 layerConfig 获取）
const layerOptions = computed(() => {
  if (!currentProject.value?.layerConfig?.layers) return []
  return currentProject.value.layerConfig.layers.map(l => ({
    value: l.id,
    label: l.name,
    stepMinutes: durationToMinutes(l.step) ?? 60
  }))
})

// ───── 画布名称 ─────
const canvasName = computed(() => {
  if (!currentProject.value?.workspace?.canvases || !selectedTask.value) return ''
  const canvas = currentProject.value.workspace.canvases.find(c => c.id === selectedTask.value!.canvas_id)
  return canvas?.name ?? ''
})

// ───── code → 节点名称映射 ─────
// sourceId 格式: "WT_7e8a"，其中 7e8a 是节点 UUID 的前4位十六进制
const codeToLabel = computed<Record<string, string>>(() => {
  if (!currentProject.value?.workspace?.canvases) return {}
  const result: Record<string, string> = {}
  for (const canvas of currentProject.value.workspace.canvases) {
    for (const node of canvas.nodes) {
      if (node.data?.label && node.id) {
        // node.id = "node-7e8a9baa-..." → code = "7e8a"
        const code = node.id.replace('node-', '').slice(0, 4)
        result[code] = node.data.label
      }
    }
  }
  return result
})

// ───── 图表显示名称 ─────
const knownCodes = computed(() => Object.keys(codeToLabel.value))

function getChartDisplayUnit(sourceId: string, varName: string, remark?: string): string {
  const { baseVarName } = parseVariableKey(`${sourceId}|${varName}`, knownCodes.value)
  return getResultDisplayUnit(baseVarName, remark)
}

function getChartDisplayName(key: string): string {
  const { componentType, baseVarName } = parseVariableKey(key, knownCodes.value)
  const varDisplayName = getVariableDisplayName(componentType, baseVarName)

  // 从 varName 中匹配 codeToLabel 里已知的 code，获取节点名称
  const varName = key.split('|')[1] ?? ''
  let nodeName = ''
  for (const code of knownCodes.value) {
    if (varName.includes(code)) {
      nodeName = codeToLabel.value[code]!
      break
    }
  }

  if (nodeName && varDisplayName !== baseVarName) {
    return `${nodeName} - ${varDisplayName}`
  }
  if (varDisplayName !== baseVarName) {
    return varDisplayName
  }
  return key
}

function getChartDeviceColorKey(key: string): string {
  const { componentType, baseVarName } = parseVariableKey(key, knownCodes.value)
  return `${componentType}_${baseVarName}`
}

// ───── 数据轮询 ─────
let wsHandle: { close: () => void; send: (m: object) => void } | null = null
const liveData = ref<Record<string, Record<string, { ts: string; value: number }[]>>>({})
const liveDataUnits = ref<Record<string, string>>({})
/** 全局版本：liveData 整体替换时的信号（能流/设备出力等） */
const liveDataVersion = ref(0)
/** 按图版本：仅脏图递增，避免无关图表重绘 */
const liveDataVersions = ref<Record<string, number>>({})
const liveDataMaxMinutes = ref(0)
const liveStatus = ref<string>('')
const flexibilityData = ref<TaskFlexibilityResponse | null>(null)
const flexibilityLoading = ref(false)
const flexibilityError = ref('')

// ───── 经济性评价 ─────
const economyData = ref<EconomyEvaluationResult | null>(null)
const economyLoading = ref(false)
const economyError = ref('')
const economySelectedLayer = ref<string>('')

let refreshTimer: ReturnType<typeof setTimeout> | null = null
let pollingGeneration = 0

const flexibilityConfig = computed<FlexibilityTaskConfig | null>(() => {
  const config = flexibilityData.value?.config
  return config?.enabled ? config as FlexibilityTaskConfig : null
})

const FLEXIBILITY_DIRECTIONS = ['up', 'down'] as const
const FLEXIBILITY_DIRECTION_LABELS: Record<typeof FLEXIBILITY_DIRECTIONS[number], string> = {
  up: '上调',
  down: '下调'
}
const FLEXIBILITY_DIRECTION_ORDER: Record<typeof FLEXIBILITY_DIRECTIONS[number], number> = {
  up: 0,
  down: 1
}

const flexibilityPeriods = computed(() =>
  (flexibilityData.value?.periods ?? [])
    .slice()
    .sort((a, b) => {
      const timeDiff = timeLabelToMinutes(a.timestamp) - timeLabelToMinutes(b.timestamp)
      return timeDiff || FLEXIBILITY_DIRECTION_ORDER[a.direction] - FLEXIBILITY_DIRECTION_ORDER[b.direction]
    })
)

const flexibilityDisplayWindow = ref<FlexibilityDisplayWindow>({
  dateStart: 0,
  dateEnd: 24 * 60,
  start: 0,
  end: 24 * 60
})
/** 系统灵活性三图共用同一视窗（需求来源 + 上调 + 下调） */
const flexibilitySourceDisplayWindow = computed({
  get: () => flexibilityDisplayWindow.value,
  set: (value: FlexibilityDisplayWindow) => { flexibilityDisplayWindow.value = value }
})
const showFlexibilityDemandComparison = ref(false)

/** 运行总览 / 能流 / 设备灵活性：同标签页内多图共享视窗 */
const overviewDisplayWindow = ref<ChartDisplayWindow>(createDisplayWindow(0, 24 * 60))
const energyFlowDisplayWindow = ref<ChartDisplayWindow>(createDisplayWindow(0, 24 * 60))
const deviceFlexDisplayWindow = ref<ChartDisplayWindow>(createDisplayWindow(0, 24 * 60))

function resetSharedDisplayWindows(): void {
  const start = timeLabelToMinutes(taskSimRange.value.start)
  const simEnd = Math.max(start + 5, taskSimRange.value.endMinutes)
  // 各标签页独立副本：只在同标签页内联动
  // 灵活性 / 能流 / 设备灵活性：按仿真范围
  flexibilityDisplayWindow.value = createDisplayWindow(start, simEnd)
  energyFlowDisplayWindow.value = createDisplayWindow(start, simEnd)
  deviceFlexDisplayWindow.value = createDisplayWindow(start, simEnd)
  // 运行总览：跟数据末端滚动（与原单图一致）
  overviewDisplayWindow.value = createDisplayWindow(
    start,
    liveDataMaxMinutes.value > 0
      ? Math.max(start + 5, liveDataMaxMinutes.value)
      : Math.min(simEnd, start + 24 * 60)
  )
  showFlexibilityDemandComparison.value = false
}

watch(
  [selectedTaskId, () => taskSimRange.value.start, () => taskSimRange.value.endMinutes],
  () => { resetSharedDisplayWindows() },
  { immediate: true }
)

/** 运行总览视窗：首帧贴合数据末端，之后数据前进时滚动跟上 */
watch(liveDataMaxMinutes, (maxMinutes, previous) => {
  if (!(maxMinutes > 0)) return
  const start = timeLabelToMinutes(taskSimRange.value.start)
  const dataEnd = Math.max(start + 5, maxMinutes)
  if (!previous) {
    overviewDisplayWindow.value = createDisplayWindow(start, dataEnd)
    return
  }
  overviewDisplayWindow.value = followDataEnd(overviewDisplayWindow.value, dataEnd)
})

watch(activeSection, () => { showFlexibilityDemandComparison.value = false })

function sameDisplayWindow(a: ChartDisplayWindow, b: ChartDisplayWindow): boolean {
  return a.dateStart === b.dateStart && a.dateEnd === b.dateEnd
    && a.start === b.start && a.end === b.end
}

const updateFlexibilityDisplayWindow = (window: FlexibilityDisplayWindow): void => {
  if (sameDisplayWindow(flexibilityDisplayWindow.value, window)) return
  flexibilityDisplayWindow.value = window
}

const updateFlexibilitySourceDisplayWindow = (window: FlexibilityDisplayWindow): void => {
  updateFlexibilityDisplayWindow(window)
}

const updateOverviewDisplayWindow = (window: ChartDisplayWindow): void => {
  if (sameDisplayWindow(overviewDisplayWindow.value, window)) return
  overviewDisplayWindow.value = window
}

const updateEnergyFlowDisplayWindow = (window: ChartDisplayWindow): void => {
  if (sameDisplayWindow(energyFlowDisplayWindow.value, window)) return
  energyFlowDisplayWindow.value = window
}

const updateDeviceFlexDisplayWindow = (window: ChartDisplayWindow): void => {
  if (sameDisplayWindow(deviceFlexDisplayWindow.value, window)) return
  deviceFlexDisplayWindow.value = window
}

interface DeviceFlexibilityGroup {
  key: string
  deviceId: string
  deviceType: string
  label: string
  boundary: boolean
  rows: DeviceFlexibilityResult[]
}

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

const deviceFlexibilityGroups = computed<DeviceFlexibilityGroup[]>(() => {
  const groups = new Map<string, DeviceFlexibilityGroup>()

  const addRow = (row: DeviceFlexibilityResult, boundary = false) => {
    const key = `${row.device_type}:${row.device_id}`
    let group = groups.get(key)
    if (!group) {
      const nodeLabel = codeToLabel.value[row.device_id]
      group = {
        key,
        deviceId: row.device_id,
        deviceType: row.device_type,
        label: nodeLabel || DEVICE_TYPE_LABELS[row.device_type] || `${row.device_type} ${row.device_id}`,
        boundary,
        rows: []
      }
      groups.set(key, group)
    }
    group.rows.push(row)
  }

  for (const period of flexibilityPeriods.value) {
    for (const row of period.device_results ?? []) addRow(row)
    if (period.boundary_result) addRow(period.boundary_result, true)
  }

  const canvas = currentProject.value?.workspace.canvases.find(
    item => item.id === selectedTask.value?.canvas_id
  )
  const order = new Map<string, number>()
  for (const [index, node] of (canvas?.nodes ?? []).entries()) {
    const code = node.id.replace('node-', '').slice(0, 4)
    order.set(`${node.data.componentKey}:${code}`, index)
  }

  return [...groups.values()]
    .map(group => ({
      ...group,
      rows: group.rows.slice().sort((a, b) => {
        const timeDiff = timeLabelToMinutes(a.timestamp) - timeLabelToMinutes(b.timestamp)
        return timeDiff || a.direction.localeCompare(b.direction)
      })
    }))
    .sort((a, b) => (order.get(a.key) ?? Number.MAX_SAFE_INTEGER) - (order.get(b.key) ?? Number.MAX_SAFE_INTEGER)
      || a.key.localeCompare(b.key))
})

const flexibilityPoiLimits = computed(() => {
  const upward = flexibilityPeriods.value.find(row => row.direction === 'up')
  const downward = flexibilityPeriods.value.find(row => row.direction === 'down')
  const maximum = upward?.poi_power_limit == null ? Number.NaN : Number(upward.poi_power_limit)
  const minimum = downward?.poi_power_limit == null ? Number.NaN : Number(downward.poi_power_limit)
  return {
    maximum: Number.isFinite(maximum) ? maximum : null,
    minimum: Number.isFinite(minimum) ? minimum : null
  }
})

const directionSummary = (direction: 'up' | 'down'): FlexibilitySummaryResult | undefined =>
  flexibilityData.value?.summaries.find(row => row.direction === direction)

const formatFlexValue = (value: unknown, digits = 2): string => {
  const numeric = Number(value)
  return Number.isFinite(numeric) ? numeric.toFixed(digits) : '--'
}

const formatFlexPercent = (value: unknown): string => {
  const numeric = Number(value)
  return Number.isFinite(numeric) ? `${(numeric * 100).toFixed(1)}%` : '--'
}

/** 灵活性 period 历史累积：首次全量，之后增量 merge（与 liveData 策略一致） */
let flexHistoryLoaded = false
let flexMaxMinutes = 0

function flexPeriodKey(row: Record<string, unknown>): string {
  return [
    row.layer_id ?? row.layerId ?? '',
    row.timestamp ?? row.ts ?? '',
    row.direction ?? '',
    row.requirement_source ?? row.requirementSource ?? '',
    row.case_id ?? row.caseId ?? '',
    row.poi_id ?? row.poiId ?? '',
    row.application_type ?? '',
    row.operation_mode ?? '',
    row.boundary_condition ?? '',
  ].join('|')
}

function mergeFlexibilityPeriods(
  existing: Array<Record<string, unknown>> | undefined,
  incoming: Array<Record<string, unknown>> | undefined
): Array<Record<string, unknown>> {
  const map = new Map<string, Record<string, unknown>>()
  for (const row of existing ?? []) {
    map.set(flexPeriodKey(row), row)
  }
  for (const row of incoming ?? []) {
    map.set(flexPeriodKey(row), row)
    const tsMin = Number(row.timestamp_minutes)
    const tsLabel = String(row.timestamp ?? '')
    const m = Number.isFinite(tsMin) && tsMin > 0 ? tsMin : timeLabelToMinutes(tsLabel)
    if (Number.isFinite(m) && m > flexMaxMinutes) flexMaxMinutes = m
  }
  return [...map.values()]
}

const reloadFlexibility = async (taskId: string, options: { silent?: boolean } = {}) => {
  if (!options.silent) {
    flexibilityLoading.value = true
    flexibilityError.value = ''
  }
  const t0 = performance.now()
  try {
    // 首次拉全量 periods；之后按 flexMaxMinutes 增量，前端 merge 保留历史
    const minMinutes = flexHistoryLoaded && flexMaxMinutes > 0
      ? Math.max(0, flexMaxMinutes - 24 * 60)
      : undefined
    const data = await taskApi.getFlexibility(taskId, undefined, minMinutes)
    if (selectedTaskId.value !== taskId) return
    const mergedPeriods = mergeFlexibilityPeriods(
      flexibilityData.value?.periods as Array<Record<string, unknown>> | undefined,
      (data as { periods?: Array<Record<string, unknown>> }).periods
    )
    flexibilityData.value = {
      ...(data as Record<string, unknown>),
      periods: mergedPeriods,
      summaries: (data as { summaries?: unknown[] }).summaries
        ?? flexibilityData.value?.summaries
        ?? [],
    } as typeof flexibilityData.value
    flexHistoryLoaded = true
    flexibilityError.value = ''
    const fp = (data as { probe?: Record<string, number | string> })?.probe
    if (fp) probeAcc.lastFlexProbe = fp
  }
  catch (error) {
    if (selectedTaskId.value !== taskId) return
    if (!options.silent || !flexibilityData.value) {
      flexibilityData.value = null
      flexibilityError.value = error instanceof Error ? error.message : String(error)
    }
    else {
      console.warn('[Poll] reloadFlexibility error:', error)
    }
  }
  finally {
    probeAcc.flexMs += performance.now() - t0
    if (!options.silent && selectedTaskId.value === taskId) {
      flexibilityLoading.value = false
    }
  }
}

const COST_TYPE_COLORS: Record<string, string> = {
  om_cost: '#3b82f6',
  fuel_cost: '#0ea5e9',
  on_off_cost: '#f59e0b',
  adjust_cost: '#8b5cf6',
  cut_cost: '#ef4444',
  purchase_cost: '#06b6d4',
  sell_revenue: '#10b981',
  hydrogen_purchase_cost: '#0d9488',
  hydrogen_sell_revenue: '#14b8a6',
  shortage_penalty: '#f97316',
  excess_penalty: '#ec4899',
}

const COST_TYPE_LABELS: Record<string, string> = {
  om_cost: '运维成本',
  fuel_cost: '燃料成本',
  on_off_cost: '启停成本',
  adjust_cost: '调整成本',
  cut_cost: '弃风/弃光成本',
  purchase_cost: '购电成本',
  sell_revenue: '售电收益',
  hydrogen_purchase_cost: '购氢成本',
  hydrogen_sell_revenue: '售氢收益',
  shortage_penalty: '短缺惩罚',
  excess_penalty: '过剩惩罚',
}

const economySelectedLayerSummary = computed(() => {
  if (!economyData.value?.layers?.length) return null
  const layerId = economySelectedLayer.value || economyData.value.layers[0]?.layerId
  return economyData.value.layers.find(l => l.layerId === layerId) ?? economyData.value.layers[0] ?? null
})

const economyMetrics = computed(() => economyData.value?.metrics ?? null)

/** 金额：千分位，¥ 与逗号后加细空格提升可读性 */
const formatMoney = (v: unknown, digits = 2): string => {
  const n = Number(v)
  if (!Number.isFinite(n)) return '--'
  const s = n.toLocaleString('zh-CN', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits
  })
  return '¥\u2009' + s.replace(/,/g, ',\u2009')
}

const formatDays = (v: unknown): string => {
  const n = Number(v)
  if (!Number.isFinite(n) || n <= 0) return '--'
  if (n >= 10) return `${n.toFixed(1)} 天`
  if (n >= 1) return `${n.toFixed(2)} 天`
  return `${(n * 24).toFixed(1)} 小时`
}

/** 设备展示名：优先后端 componentName，其次画布节点名，最后回退 compKey */
const economyCompDisplayNames = computed(() => {
  const map: Record<string, string> = {}
  for (const item of economyData.value?.allCostItems ?? []) {
    const key = `${item.componentType}_${item.componentId}`
    if (!map[key] && item.componentName) map[key] = item.componentName
    else if (!map[key] && item.componentId && codeToLabel.value[item.componentId]) {
      map[key] = codeToLabel.value[item.componentId]!
    }
  }
  return map
})

const economyCompDisplayName = (compKey: string): string => {
  return economyCompDisplayNames.value[compKey] || compKey
}

const economyLayerPieItems = computed(() => {
  if (!economyData.value?.allCostItems?.length) return {}
  const result: Record<string, Array<{ label: string; value: number; color: string }>> = {}
  const visible = economyData.value.allCostItems.filter(item => !item.isSlack && Math.abs(item.value) >= 0.01)
  const countByComp: Record<string, number> = {}
  for (const item of visible) {
    const key = `${item.componentType}_${item.componentId}`
    countByComp[key] = (countByComp[key] ?? 0) + 1
  }
  const indexByComp: Record<string, number> = {}
  for (const item of visible) {
    if (!result[item.layerId]) result[item.layerId] = []
    const compKey = `${item.componentType}_${item.componentId}`
    const idx = indexByComp[compKey] ?? 0
    indexByComp[compKey] = idx + 1
    const baseColor = getDeviceColor(item.componentType, item.componentId)
    const color = (countByComp[compKey] ?? 1) > 1
      ? getLayerColor(baseColor, idx, countByComp[compKey]!)
      : baseColor
    const label = item.componentName
      ? `${item.componentName} - ${item.costLabel}`
      : `${item.componentType} - ${item.costLabel}`
    result[item.layerId]!.push({
      label,
      value: Math.abs(item.value),
      color,
    })
  }
  return result
})

const reloadEconomy = async (taskId: string, options: { silent?: boolean } = {}) => {
  if (!options.silent) {
    economyLoading.value = true
    economyError.value = ''
  }
  try {
    const data = await taskApi.getEconomy(taskId)
    if (selectedTaskId.value !== taskId) return
    economyData.value = data
    economyError.value = ''
    if (!economySelectedLayer.value && data.layers?.length) {
      economySelectedLayer.value = data.layers[0]!.layerId
    }
  }
  catch (error) {
    if (selectedTaskId.value !== taskId) return
    if (!options.silent || !economyData.value) {
      economyData.value = null
      economyError.value = error instanceof Error ? error.message : String(error)
    }
    else {
      console.warn('[Poll] reloadEconomy error:', error)
    }
  }
  finally {
    if (!options.silent && selectedTaskId.value === taskId) {
      economyLoading.value = false
    }
  }
}

// ───── 轮询性能探测 ─────
// 每 2s 汇总打印一次，定位卡顿在拉数/锁/序列化/前端合并/图表
const probeAcc = {
  cycles: 0,
  getDataMs: 0,
  mergeMs: 0,
  flexMs: 0,
  econMs: 0,
  cycleMs: 0,
  rows: 0,
  sentMinMinutes: -1,
  taskHead: -1,
  stalePolls: 0,
  stateMs: 0,
  lastProbe: null as null | Record<string, number | string>,
  lastFlexProbe: null as null | Record<string, number | string>,
  lastLogAt: 0,
}
const probeLog = (force = false) => {
  const now = performance.now()
  if (!force && now - probeAcc.lastLogAt < 2000) return
  const n = Math.max(1, probeAcc.cycles)
  const p = probeAcc.lastProbe ?? {}
  const fp = probeAcc.lastFlexProbe ?? {}
  console.info(
    `[Probe] cycles=${probeAcc.cycles}` +
    ` | getData_avg=${(probeAcc.getDataMs / n).toFixed(0)}ms` +
    ` | merge_avg=${(probeAcc.mergeMs / n).toFixed(0)}ms` +
    ` | flex_avg=${(probeAcc.flexMs / n).toFixed(0)}ms` +
    ` | econ_avg=${(probeAcc.econMs / n).toFixed(0)}ms` +
    ` | cycle_avg=${(probeAcc.cycleMs / n).toFixed(0)}ms` +
    ` | rows_last=${probeAcc.rows}` +
    ` | julia_lock=${p.lock_wait_ms ?? '-'}ms` +
    ` | julia_query=${p.query_ms ?? '-'}ms` +
    ` | julia_build=${p.build_ms ?? '-'}ms` +
    ` | julia_ser=${p.serialize_est_ms ?? '-'}ms` +
    ` | julia_total=${p.total_ms ?? '-'}ms` +
    ` | bff=${p.bff_total_ms ?? '-'}ms` +
    ` | series=${p.series_count ?? '-'}` +
    ` | raw_pts=${p.raw_point_count ?? '-'}` +
    ` | flex_parse=${fp.period_parse_ms ?? '-'}ms` +
    ` | flex_n=${fp.period_count ?? '-'}` +
    ` | minMin_sent=${probeAcc.sentMinMinutes}` +
    ` | minMin_srv=${p.min_minutes ?? '-'}` +
    ` | taskHead=${probeAcc.taskHead}` +
    ` | stale=${probeAcc.stalePolls}` +
    ` | cur_time=${selectedTask.value?.cur_time ?? 'null'}` +
    ` | maxDevTs=${p.max_device_ts ?? '-'}` +
    ` | state_avg=${(probeAcc.stateMs / n).toFixed(0)}ms`
  )
  probeAcc.cycles = 0
  probeAcc.getDataMs = 0
  probeAcc.mergeMs = 0
  probeAcc.flexMs = 0
  probeAcc.econMs = 0
  probeAcc.cycleMs = 0
  probeAcc.stateMs = 0
  probeAcc.lastLogAt = now
}

// 每条序列的 ts→index 查找表，避免 findIndex O(n^2)
const liveDataIndex = new Map<string, Map<string, number>>()
// 仿真头（已求解到的分钟数）；不能用全局 max(ts)——边界会铺到年末
let simHeadMinutes = 0

/** 判断是否为边界序列（sourceId 形如 b_xxx，不参与仿真头水位） */
function isBoundaryRowKey(sourceId: string): boolean {
  return sourceId.startsWith('b_')
}

function simHeadFromTask(): number {
  const raw = selectedTask.value?.cur_time
  if (raw === null || raw === undefined || raw === '') return 0
  const s = String(raw).trim()
  // 支持 "H:MM" 与纯分钟数
  if (/^\d+$/.test(s)) {
    const n = Number(s)
    return Number.isFinite(n) ? n : 0
  }
  const m = timeLabelToMinutes(s)
  return Number.isFinite(m) ? m : 0
}

/** stale 只看任务 cur_time；maxDevTs 会超前，不能当水位 */
let staleHeadPolls = 0
let lastTaskHead = 0
let lastHeadChangeAt = 0
let loadedBoundaryOnce = false


/** 合并 rows 到 liveData（WS 推送与 getData 共用） */
function applyLiveRows(rows: Array<{
  sourceId: string
  varName: string
  remark?: string
  layerId?: string
  ts: string | number
  value: number
}>) {
  if (!rows.length) return
  const merged = liveData.value
  const units = liveDataUnits.value
  let newMax = simHeadMinutes
  const dirtySlots = new Set<string>()
  const dirtyKeys = new Set<string>()
  const needsSort = new Set<string>()
  let unitsChanged = false
  let changed = false
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]!
    const key = row.sourceId + '|' + row.varName
    const unit = getChartDisplayUnit(row.sourceId, row.varName, row.remark)
    if (units[key] !== unit) {
      units[key] = unit
      unitsChanged = true
    }
    const lid = row.layerId ?? '1'
    const slot = key + '\u0001' + lid
    if (!merged[key]) merged[key] = {}
    if (!merged[key]![lid]) merged[key]![lid] = []
    const arr = merged[key]![lid]!
    const ts = String(row.ts)
    const m = timeLabelToMinutes(ts)
    if (Number.isFinite(m) && !isBoundaryRowKey(row.sourceId) && m > newMax) newMax = m
    let idxMap = liveDataIndex.get(slot)
    if (!idxMap) {
      idxMap = new Map()
      for (let j = 0; j < arr.length; j++) idxMap.set(arr[j]!.ts, j)
      liveDataIndex.set(slot, idxMap)
    }
    const point = { ts, value: Math.abs(Number(row.value)) }
    const exist = idxMap.get(ts)
    if (exist !== undefined) {
      const prev = arr[exist]!
      if (prev.value !== point.value) {
        arr[exist] = point
        changed = true
        dirtySlots.add(slot)
        dirtyKeys.add(key)
      }
    } else {
      changed = true
      dirtySlots.add(slot)
      dirtyKeys.add(key)
      // 通常增量点落在末尾；只有乱序插入才标记需要排序
      const lastM = arr.length ? timeLabelToMinutes(arr[arr.length - 1]!.ts) : -1
      if (arr.length === 0 || m >= lastM) {
        idxMap.set(ts, arr.length)
        arr.push(point)
      } else {
        let lo = 0
        let hi = arr.length
        while (lo < hi) {
          const mid = (lo + hi) >> 1
          if (timeLabelToMinutes(arr[mid]!.ts) < m) lo = mid + 1
          else hi = mid
        }
        arr.splice(lo, 0, point)
        idxMap.set(ts, lo)
        needsSort.add(slot)
      }
    }
  }
  // 仅对乱序插入过的序列做全量 sort，避免每轮 O(n log n)
  for (const slot of needsSort) {
    const sepPos = slot.indexOf('\u0001')
    if (sepPos < 0) continue
    const key = slot.slice(0, sepPos)
    const lid = slot.slice(sepPos + 1)
    const arr = merged[key]?.[lid]
    if (!arr) continue
    arr.sort((a, b) => timeLabelToMinutes(a.ts) - timeLabelToMinutes(b.ts))
    const idxMap = new Map<string, number>()
    for (let j = 0; j < arr.length; j++) idxMap.set(arr[j]!.ts, j)
    liveDataIndex.set(slot, idxMap)
  }
  // 视窗末端跟仿真进度（cur_time），避免被超前 max(ts) 拉飞导致不滚动
  const progressMin = simHeadFromTask()
  const mergedMax = newMax
  simHeadMinutes = Math.max(simHeadMinutes, mergedMax)
  liveDataMaxMinutes.value = progressMin > 0 ? progressMin : Math.max(simHeadMinutes, mergedMax)

  // 无增量：不替换 liveData、不触发图表重绘
  if (!changed) {
    if (unitsChanged) liveDataUnits.value = { ...units }
    return
  }

  const next: typeof merged = { ...merged }
  for (const slot of dirtySlots) {
    const sepPos = slot.indexOf('\u0001')
    if (sepPos < 0) continue
    const key = slot.slice(0, sepPos)
    const lid = slot.slice(sepPos + 1)
    const arr = merged[key]?.[lid]
    if (!arr) continue
    next[key] = { ...next[key], [lid]: [...arr] }
  }
  liveData.value = next
  if (unitsChanged) liveDataUnits.value = { ...units }
  const nextVersions = { ...liveDataVersions.value }
  for (const key of dirtyKeys) {
    nextVersions[key] = (nextVersions[key] ?? 0) + 1
  }
  liveDataVersions.value = nextVersions
  liveDataVersion.value++
}

const reloadLiveData = async (taskId: string) => {
  const t0 = performance.now()
  try {
    const statusNow = liveStatus.value || selectedTask.value?.status || ''
    const running = ['pending', 'parsing', 'building', 'solving'].includes(statusNow)
    const taskHead = simHeadFromTask()

    // 仅当 taskHead 在较长时间内不动才算 stale（不能每 200ms 轮询就 +1）
    const nowMs = performance.now()
    if (taskHead > lastTaskHead) {
      staleHeadPolls = 0
      lastTaskHead = taskHead
      lastHeadChangeAt = nowMs
    }
    else if (running && nowMs - lastHeadChangeAt > 3000) {
      staleHeadPolls = Math.min(staleHeadPolls + 1, 2)
    }

    // 拉取窗口跟仿真进度 cur_time，而不是 max(ts)。
    // 时层1会超前写出很长视野，若用 max(ts) 当水位会切掉细层进度点，前端就不刷新。
    const head = taskHead
    // 首次拉全量含边界；之后始终 skipBoundary
    // stale 时只放宽到 48h，避免 7 天窗导致 rows 暴涨
    const wideWindow = running && staleHeadPolls >= 2
    const lookbackMin = wideWindow ? 48 * 60 : 24 * 60
    const minMinutes = head > 0 ? Math.max(0, head - lookbackMin) : undefined
    const skipBoundary = loadedBoundaryOnce
    probeAcc.sentMinMinutes = minMinutes ?? -1
    probeAcc.taskHead = taskHead
    probeAcc.stalePolls = staleHeadPolls
    const data = await taskApi.getData(taskId, {
      ...(minMinutes !== undefined ? { minMinutes } : {}),
      ...(skipBoundary ? { skipBoundary: true } : {}),
    })
    loadedBoundaryOnce = true
    const t1 = performance.now()
    probeAcc.getDataMs += t1 - t0
    const rows = data?.rows ?? []
    probeAcc.rows = rows.length
    probeAcc.lastProbe = (data as { probe?: Record<string, number | string> })?.probe ?? null
    if (rows.length) {
      applyLiveRows(rows as any)
    }
    probeAcc.mergeMs += performance.now() - t1
  }
  catch (e) {
    probeAcc.getDataMs += performance.now() - t0
    console.warn('[Poll] reloadLiveData error:', e)
  }
}

const startPolling = (taskId: string) => {
  stopPolling()
  liveDataMaxMinutes.value = 0
  simHeadMinutes = 0
  staleHeadPolls = 0
  lastTaskHead = 0
  lastHeadChangeAt = 0
  loadedBoundaryOnce = false
  liveDataIndex.clear()
  liveData.value = {}
  liveDataUnits.value = {}
  liveDataVersions.value = {}
  liveDataVersion.value++
  flexHistoryLoaded = false
  flexMaxMinutes = 0
  const generation = pollingGeneration
  let pending = false
  let lastFlexAt = 0
  let lastStateAt = 0
  let lastEconAt = 0
  const reloadResults = async () => {
    const t0 = performance.now()
    // 状态最多 2s 同步一次，避免 getState 被求解阻塞时拖慢曲线周期
    const nowState = performance.now()
    const needState = nowState - lastStateAt >= 2000
    const tState = performance.now()
    const stateP = needState
      ? taskApi.getState(taskId).then((st) => {
          probeAcc.stateMs += performance.now() - tState
          lastStateAt = performance.now()
          if (st && selectedTaskId.value === taskId) {
            selectedTask.value = st
            liveStatus.value = st.status
          }
          return st
        }).catch(() => {
          probeAcc.stateMs += performance.now() - tState
          lastStateAt = performance.now()
          return selectedTask.value
        })
      : Promise.resolve(selectedTask.value)
    const liveP = reloadLiveData(taskId)
    const now = performance.now()
    const flexInterval = ['flexibility', 'device-flexibility'].includes(activeSection.value) ? 2000 : 5000
    if (now - lastFlexAt >= flexInterval) {
      lastFlexAt = now
      void reloadFlexibility(taskId, { silent: true })
    }
    // 经济性评价支持运行中动态刷新；节流约 2s，避免每次 200ms 轮询都扫库
    const nowEcon = performance.now()
    const econInterval = 2000
    const econP = (nowEcon - lastEconAt >= econInterval)
      ? (async () => {
          lastEconAt = nowEcon
          const t = performance.now()
          await reloadEconomy(taskId, { silent: true })
          probeAcc.econMs += performance.now() - t
        })()
      : Promise.resolve()
    const st = await stateP
    await Promise.all([liveP, econP])
    probeAcc.cycleMs += performance.now() - t0
    probeAcc.cycles += 1
    probeLog()
    return st
  }
  const poll = async () => {
    if (pending) return
    pending = true
    const t0 = performance.now()
    let shouldStop = false
    try {
      const task = await reloadResults()
      if (task && ['completed', 'failed', 'cancelled'].includes(task.status)) {
        await reloadResults()
        probeLog(true)
        shouldStop = true
        return
      }
    }
    catch { /* 静默 */ }
    finally {
      pending = false
      if (!shouldStop && generation === pollingGeneration && selectedTaskId.value === taskId) {
        // 固定 1s 节拍：本拍内攒齐增量再画；后端慢则自然变成 2~3s 一跳
        const delay = Math.max(0, 1000 - (performance.now() - t0))
        refreshTimer = setTimeout(poll, delay)
      }
    }
  }
  void poll()
}

const stopPolling = () => {
  pollingGeneration += 1
  if (refreshTimer) {
    clearTimeout(refreshTimer)
    refreshTimer = null
  }
}

const unsubscribeTask = () => {
  stopPolling()
  if (wsHandle) {
    wsHandle.close()
    wsHandle = null
  }
}

const subscribeTask = (taskId: string) => {
  unsubscribeTask()
  liveData.value = {}
  liveDataUnits.value = {}
  liveDataVersions.value = {}
  liveDataVersion.value++
  liveStatus.value = ''
  flexibilityData.value = null
  flexibilityError.value = ''

  wsHandle = connect(taskId, (evt) => {
    if (evt.type === 'status') {
      liveStatus.value = evt.status
      if (selectedTask.value?.id === taskId) {
        selectedTask.value = { ...selectedTask.value, status: evt.status as ComputeTask['status'] }
      }
    }
    else if (evt.type === 'flexibility' || evt.type === 'flexibility_summary') {
      void reloadFlexibility(taskId, { silent: true })
    }
    else if (evt.type === 'completed' || evt.type === 'failed' || evt.type === 'cancelled') {
      if (selectedTask.value?.id === taskId) {
        selectedTask.value = {
          ...selectedTask.value,
          status: evt.type,
          error_message: evt.type === 'failed' ? (evt.error ?? selectedTask.value.error_message) : null
        }
      }
      void reloadLiveData(taskId)
      void reloadFlexibility(taskId, { silent: true })
      stopPolling()
    }
  })
}

// ───── 加载项目详情 ─────
const loadProject = async (projectId: string) => {
  try {
    const res = await projectApi.getProject(projectId)
    currentProject.value = res.project
  }
  catch (e) {
    console.warn('[Result] loadProject error:', e)
    currentProject.value = null
  }
}

// ───── 选中任务 ─────
const selectTask = async (taskId: string, options: { instantShell?: boolean } = {}) => {
  selectedTaskId.value = taskId
  showTaskListDialog.value = false
  resultShellLoading.value = options.instantShell ?? false

  // 秒开：先塞占位任务，模板立刻出壳；真实状态稍后覆盖
  if (options.instantShell || !selectedTask.value || selectedTask.value.id !== taskId) {
    selectedTask.value = {
      id: taskId,
      project_id: '',
      canvas_id: '',
      layer_id: '',
      mode: 'offline',
      name: null,
      status: 'pending',
      params_hash: '',
      sim_start_time: '0:00',
      sim_end_time: null,
      sim_start_date: null,
      sim_end_date: null,
      cur_time: null,
      created_at: '',
      updated_at: '',
      started_at: null,
      finished_at: null,
      error_message: null,
      extra_json: null,
    }
  }

  // 详情/项目/连接并行拉，不阻塞骨架屏
  const detailP = taskApi.getState(taskId).then((task) => {
    selectedTask.value = task
    return task
  }).catch((e) => {
    console.warn('[Result] get task state error:', e)
    return null
  })

  void detailP.then((task) => {
    if (task?.project_id) void loadProject(task.project_id)
    void reloadEconomy(taskId, { silent: true })
  })
  void loadConnectionData(taskId)
  subscribeTask(taskId)
  startPolling(taskId)
  // 灵活性结果较重，后台拉；完成后再撤掉创建后的骨架遮罩
  void reloadFlexibility(taskId, { silent: true }).finally(() => {
    resultShellLoading.value = false
  })
}

watch(activeSection, (section) => {
  if ((section === 'flexibility' || section === 'device-flexibility') && selectedTaskId.value) {
    void reloadFlexibility(selectedTaskId.value)
  }
  if (section === 'economy' && selectedTaskId.value) {
    void reloadEconomy(selectedTaskId.value)
  }
})

onBeforeUnmount(() => unsubscribeTask())

// ───── 任务列表数据（仅当前项目） ─────
const route = useRoute()
const initialProjectId = (route.query.projectId as string) || ''
const initialCanvasId = (route.query.canvasId as string) || ''

/** 本项目 id：URL 预填优先，其次已加载项目 / 选中任务 */
const scopedProjectId = computed(() =>
  initialProjectId || currentProject.value?.id || selectedTask.value?.project_id || ''
)

const { data: taskListData, refresh: refreshTaskList } = await useAsyncData<ComputeTaskListResponse>(
  () => `task-list-${scopedProjectId.value || 'all'}`,
  () => taskApi.listTasks(scopedProjectId.value ? { projectId: scopedProjectId.value } : undefined)
)
const taskList = computed(() => {
  const tasks = taskListData.value?.tasks ?? []
  const pid = scopedProjectId.value
  return pid ? tasks.filter(t => t.project_id === pid) : tasks
})

const refreshList = async () => { await refreshTaskList() }

const openTaskList = async () => {
  await refreshList()
  showTaskListDialog.value = true
}

// ───── 状态展示辅助 ─────
const STATUS_LABEL: Record<string, string> = {
  pending: '待启动',
  parsing: '解析中',
  building: '构建中',
  solving: '求解中',
  completed: '已完成',
  failed: '失败',
  cancelled: '已取消'
}

const STATUS_TONE: Record<string, string> = {
  pending: 'neutral',
  parsing: 'primary',
  building: 'primary',
  solving: 'primary',
  completed: 'success',
  failed: 'danger',
  cancelled: 'warning'
}

const showActions = (t: ComputeTask) => ({
  cancel: ['pending', 'parsing', 'building', 'solving'].includes(t.status),
  cleanup: ['completed', 'failed', 'cancelled'].includes(t.status)
})

const doAction = async (action: 'cancel' | 'cleanup', taskId: string) => {
  try {
    if (action === 'cleanup') {
      if (!confirm('确认清理该任务？数据将被永久删除。')) return
      await taskApi.cleanup(taskId)
      push({ tone: 'success', title: '任务已清理' })
      if (selectedTaskId.value === taskId) {
        unsubscribeTask()
        selectedTaskId.value = null
        selectedTask.value = null
      }
    }
    else if (action === 'cancel') {
      if (!confirm('确认取消该任务？')) return
      await taskApi.cancel(taskId)
      push({ tone: 'success', title: '已发送取消信号' })
    }
    await refreshList()
  }
  catch (err) {
    push({ tone: 'danger', title: `${action} 失败`, description: String(err) })
  }
}

// ───── 新建任务 ─────

type FlexibilityValueMode = 'constant' | 'manual' | 'file' | 'boundary'

interface CreationBoundarySeriesOption {
  value: string
  label: string
  timestamps: string[]
  values: number[]
  source: 'database' | 'project'
}

// 仿真模式类型
type SimulationMode = 'multi_layer' | 'single_layer'

const newTask = reactive({
  projectId: initialProjectId,
  canvasId: initialCanvasId,
  layerId: '1',
  mode: 'offline' as 'offline',
  simMode: 'multi_layer' as SimulationMode,
  targetLayerId: '1',
  name: '',
  poiId: '',
  requirementSource: 'net_load_change' as FlexibilityRequirementSource,
  flexibilityValueMode: 'constant' as FlexibilityValueMode,
  targetPoiPowerKw: 0,
  upwardRequirementKw: 0,
  downwardRequirementKw: 0,
  targetPoiPowerSeries: { default: 0 } as Record<string, number>,
  upwardRequirementSeries: { default: 0 } as Record<string, number>,
  downwardRequirementSeries: { default: 0 } as Record<string, number>
})

const creationProject = ref<Project | null>(null)
const creationProjectLoading = ref(false)
const creationProjectError = ref('')
const boundarySeriesOptions = ref<CreationBoundarySeriesOption[]>([])
const boundarySeriesLoading = ref(false)
const boundarySeriesWarning = ref('')
const seriesValidationErrors = reactive({ target: '', upward: '', downward: '' })

const creationCanvasOptions = computed(() => creationProject.value?.workspace.canvases ?? [])
const creationLayerOptions = computed(() => creationProject.value?.layerConfig.layers ?? [])
const creationCanvas = computed(() =>
  creationCanvasOptions.value.find(canvas => canvas.id === newTask.canvasId) ?? creationCanvasOptions.value[0]
)

// 项目名称
const creationProjectName = computed(() => creationProject.value?.name ?? '')

// 画布名称
const creationCanvasName = computed(() => creationCanvas.value?.name ?? '')

// 默认任务名称：项目名称-画布名称（任务ID由后端生成，不参与placeholder）
const defaultTaskName = computed(() => {
  const parts = [creationProjectName.value, creationCanvasName.value].filter(Boolean)
  return parts.join('-') || '未命名任务'
})

// Layer1的小时数（从layer1.length解析，如"24h" -> 24）
const layer1Hours = computed(() => {
  const layer1 = creationLayerOptions.value.find(l => l.id === '1')
  if (!layer1?.length) return 24
  const match = /^(\d+)h?$/.exec(layer1.length.trim())
  return match ? parseInt(match[1], 10) : 24
})

// 时间范围字符串（格式："0:00-24:00"）
const timeRange = ref('0:00-24:00')

// 时间范围校验错误
const timeRangeError = ref('')
const simStartDate = ref('')
const simEndDate = ref('')
const dateRangeError = ref('')

type CreationTimeMode = 'relative' | 'calendar' | 'invalid'

const creationBoundaryIds = computed(() => new Set(
  (creationCanvas.value?.nodes ?? [])
    .flatMap(node => node.data?.business?.boundaryIds ?? [])
    .map(String)
))

const creationBoundaries = computed<BoundaryItem[]>(() => {
  const boundaries = creationProject.value?.boundaries ?? []
  const ids = creationBoundaryIds.value
  if (ids.size > 0) return boundaries.filter(boundary => ids.has(boundary.id))

  const nodeIds = new Set((creationCanvas.value?.nodes ?? []).map(node => node.id))
  return boundaries.filter(boundary => boundary.relatedComponents.some(componentId => nodeIds.has(componentId)))
})

const creationCalendarRanges = computed(() => creationBoundaries.value
  .map((boundary) => {
    const metadata = boundary.boundaryMeta
    if (!metadata || metadata.dayCount <= 0) return null
    const start = isDateOnly(metadata.calendarStartDate)
      ? metadata.calendarStartDate
      : DEFAULT_BOUNDARY_START_DATE
    const end = isDateOnly(metadata.calendarEndDate)
      ? metadata.calendarEndDate
      : deriveCalendarEndDate(start, metadata.dayCount)
    return isDateOnly(end) ? { start, end } : null
  })
  .filter((range): range is { start: string; end: string } => Boolean(range)))

const creationTimeMode = computed<CreationTimeMode>(() => {
  if (creationBoundaries.value.length === 0) return 'relative'
  return creationCalendarRanges.value.length === creationBoundaries.value.length
    ? 'calendar'
    : 'invalid'
})

const commonCalendarCoverage = computed(() => {
  if (creationTimeMode.value !== 'calendar') return null
  const starts = creationCalendarRanges.value.map(range => range.start)
  const ends = creationCalendarRanges.value.map(range => range.end)
  const start = starts.sort().at(-1) ?? ''
  const end = ends.sort().at(0) ?? ''
  return start && end && start <= end ? { start, end } : null
})

const calendarDurationDays = computed(() =>
  inclusiveCalendarDayCount(simStartDate.value, simEndDate.value)
)

const validateCalendarRange = (): boolean => {
  if (creationTimeMode.value === 'invalid') {
    dateRangeError.value = '当前画布关联边界缺少有效的日期覆盖信息，请先重新导入并提交边界数据。'
    return false
  }
  if (creationTimeMode.value !== 'calendar') {
    dateRangeError.value = ''
    return true
  }
  const coverage = commonCalendarCoverage.value
  if (!coverage) {
    dateRangeError.value = '相关边界的日期覆盖范围没有交集。'
    return false
  }
  if (!isDateOnly(simStartDate.value) || !isDateOnly(simEndDate.value)) {
    dateRangeError.value = '请选择仿真起始日期和终止日期。'
    return false
  }
  if (simStartDate.value < coverage.start || simEndDate.value > coverage.end) {
    dateRangeError.value = `仿真日期必须位于共同覆盖范围 ${coverage.start} 至 ${coverage.end} 内。`
    return false
  }
  if (simEndDate.value < simStartDate.value) {
    dateRangeError.value = '终止日期不能早于起始日期。'
    return false
  }
  dateRangeError.value = ''
  return true
}

watch(commonCalendarCoverage, (coverage) => {
  if (!coverage) {
    simStartDate.value = ''
    simEndDate.value = ''
    return
  }
  simStartDate.value = coverage.start
  simEndDate.value = coverage.end
  dateRangeError.value = ''
}, { immediate: true })

// 当项目加载后，用layer1的小时数初始化
watch(layer1Hours, (val) => {
  timeRange.value = `0:00-${val}:00`
}, { immediate: true })

// 校验时间范围格式
const validateTimeRange = (value: string) => {
  const trimmed = value.trim()
  if (!trimmed) {
    timeRangeError.value = '时间范围不能为空'
    return false
  }

  const match = /^(\d+):(\d{2})\s*[-~]\s*(\d+):(\d{2})$/.exec(trimmed)
  if (!match) {
    timeRangeError.value = '格式错误，请使用 0:00-24:00 格式'
    return false
  }

  const startHour = parseInt(match[1], 10)
  const startMin = parseInt(match[2], 10)
  const endHour = parseInt(match[3], 10)
  const endMin = parseInt(match[4], 10)

  if (startMin !== 0 || endMin !== 0) {
    timeRangeError.value = '分钟必须为 00'
    return false
  }

  if (startHour < 0 || endHour < 0) {
    timeRangeError.value = '小时不能为负数'
    return false
  }

  if (endHour <= startHour) {
    timeRangeError.value = '结束时间必须大于开始时间'
    return false
  }

  if ((endHour - startHour) % 24 !== 0) {
    timeRangeError.value = '时间范围必须是24小时的整数倍'
    return false
  }

  timeRangeError.value = ''
  return true
}

// 解析结束时间的小时数
const parsedEndHour = computed(() => {
  if (creationTimeMode.value === 'calendar' && calendarDurationDays.value) {
    return calendarDurationDays.value * 24
  }
  const match = /^(\d+):(\d{2})\s*[-~]\s*(\d+):(\d{2})$/.exec(timeRange.value.trim())
  if (!match) return 24
  return parseInt(match[3], 10)
})

// 发送给后端的结束时间（格式："X:00"）
const simEndTime = computed(() => `${parsedEndHour.value}:00`)

// 时间范围变更处理
const onTimeRangeChange = (value: string) => {
  timeRange.value = value
  validateTimeRange(value)
}

// 画布选项（PropertySelect格式）
const canvasSelectOptions = computed(() =>
  creationCanvasOptions.value.map(c => ({ label: c.name, value: c.id }))
)

// 时层选项（PropertySelect格式）
const layerSelectOptions = computed(() =>
  creationLayerOptions.value.map(l => ({ label: `${l.name}（${l.step}）`, value: l.id }))
)

const finiteGridNumber = (value: unknown, fallback: number): number => {
  const numeric = Number(value)
  return Number.isFinite(numeric) ? numeric : fallback
}

const creationGridOptions = computed(() =>
  (creationCanvas.value?.nodes ?? [])
    .filter(node => node.data?.componentKey === 'GRID')
    .map(node => {
      const params = node.data?.business?.commonTechParams ?? {}
      const capacityKw = Math.max(0, finiteGridNumber(params.capacity, 0))
      const sellRatio = Math.max(0, finiteGridNumber(params.sell_ratio, 1))
      const buyRatio = Math.max(0, finiteGridNumber(params.buy_ratio, 1))
      const code = node.id.replace(/^node-/, '').slice(0, 4)
      return {
        value: code,
        label: `${node.data?.label ?? '电网接口'} (${code})`,
        capacityKw,
        sellRatio,
        buyRatio,
        maximumPoiPowerKw: capacityKw * sellRatio,
        minimumPoiPowerKw: -capacityKw * buyRatio
      }
    })
)

const selectedGridOption = computed(() =>
  creationGridOptions.value.find(option => option.value === newTask.poiId) ?? creationGridOptions.value[0] ?? null
)

const isIslandedFlexibility = computed(() => creationGridOptions.value.length === 0)

// 灵活性评价固定采用项目配置中的最底层时层。
const flexibilityEvaluationLayer = computed(() =>
  creationLayerOptions.value[creationLayerOptions.value.length - 1]
)
const flexibilityEvaluationLayerId = computed(() =>
  flexibilityEvaluationLayer.value?.id ?? newTask.layerId
)

// 与 simulation_runner._flexibility_evaluation_timestamps 保持一致：周前层按 length，
// 其他层按 forward 形成评价窗口，并受任务结束时间截断。
const expectedFlexibilityTimestamps = computed<string[]>(() => {
  const layer = flexibilityEvaluationLayer.value
  if (!layer) return []
  const startMinutes = 0 // 开始时间固定为 0:00
  const stepMinutes = durationToMinutes(layer.step)
  const durationMinutes = durationToMinutes(String(layer.id) === '1' ? layer.length : layer.forward)
  if (!stepMinutes || !durationMinutes || durationMinutes % stepMinutes !== 0) return []

  const endMinutes = parsedEndHour.value * 60 // 结束时间由 parsedEndHour 控制
  const timestamps: string[] = []
  for (let offset = 0; offset < durationMinutes; offset += stepMinutes) {
    const timestampMinutes = startMinutes + offset
    if (timestampMinutes + stepMinutes > endMinutes) break
    timestamps.push(minutesToTimeLabel(timestampMinutes))
  }
  return timestamps
})

const expectedRequirementTimestamps = computed(() => {
  if (newTask.requirementSource !== 'agc_or_schedule') return expectedFlexibilityTimestamps.value
  const stepMinutes = durationToMinutes(flexibilityEvaluationLayer.value?.step ?? '')
  if (!stepMinutes) return []
  return expectedFlexibilityTimestamps.value.map(timestamp =>
    minutesToTimeLabel(timeLabelToMinutes(timestamp) + stepMinutes)
  )
})

const availableRequirementOptions = computed(() =>
  isIslandedFlexibility.value
    ? FLEXIBILITY_REQUIREMENT_OPTIONS.filter(option => option.value !== 'agc_or_schedule')
    : FLEXIBILITY_REQUIREMENT_OPTIONS
)

const formatBoundaryPower = (value: number): string =>
  `${new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 2 }).format(value)} kW`

const openGridConfiguration = () => {
  if (!newTask.projectId) return
  showCreateDialog.value = false
  void navigateTo(`/editor/${newTask.projectId}`)
}

const syncCreationSelections = () => {
  if (creationCanvasOptions.value.length && !creationCanvasOptions.value.some(canvas => canvas.id === newTask.canvasId)) {
    newTask.canvasId = creationCanvasOptions.value[0]!.id
  }
  if (creationLayerOptions.value.length && !creationLayerOptions.value.some(layer => layer.id === newTask.layerId)) {
    newTask.layerId = creationLayerOptions.value[0]!.id
  }
  if (!creationGridOptions.value.some(option => option.value === newTask.poiId)) {
    newTask.poiId = creationGridOptions.value[0]?.value ?? ''
  }
}

const loadCreationProject = async (projectId: string) => {
  creationProject.value = null
  creationProjectError.value = ''
  if (!projectId.trim()) return
  creationProjectLoading.value = true
  try {
    const response = await projectApi.getProject(projectId.trim())
    creationProject.value = response.project
    syncCreationSelections()
  }
  catch (error) {
    creationProjectError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    creationProjectLoading.value = false
  }
}

const boundarySeriesCandidates = computed(() =>
  (creationProject.value?.boundaries ?? []).filter(boundary =>
    boundary.meaning === 'power' || /计划|AGC|目标|调度/i.test(boundary.name)
  )
)

const cachedBoundarySeriesOptions = (): CreationBoundarySeriesOption[] => {
  const layerId = flexibilityEvaluationLayerId.value
  const options: CreationBoundarySeriesOption[] = []
  for (const boundary of boundarySeriesCandidates.value) {
    const layer = boundary.transformedData?.layers.find(item => String(item.layerId) === String(layerId))
    if (!layer?.timestamps.length || layer.timestamps.length !== layer.values.length) continue
    options.push({
      value: `${boundary.id}:${layerId}`,
      label: `${boundary.name} · ${layer.layerName}（项目缓存）`,
      timestamps: layer.timestamps.map(String),
      values: layer.values.map(Number),
      source: 'project'
    })
  }
  return options
}

const refreshBoundarySeriesOptions = async () => {
  const projectId = newTask.projectId.trim()
  const layerId = flexibilityEvaluationLayerId.value
  const candidates = boundarySeriesCandidates.value
  boundarySeriesOptions.value = cachedBoundarySeriesOptions()
  boundarySeriesWarning.value = ''
  if (!projectId || !layerId || !candidates.length) return

  boundarySeriesLoading.value = true
  try {
    const response = await $fetch<{
      success: boolean
      data?: {
        boundaries: Array<{
          boundaryId?: string
          layerId: string
          found: boolean
          values?: number[]
          timestamps?: string[]
        }>
      }
    }>('/api/v1/boundary/load', {
      method: 'POST',
      body: {
        projectId,
        boundaries: candidates.map(boundary => ({
          layerId,
          meaning: boundary.meaning,
          boundaryId: boundary.id
        }))
      }
    })
    const databaseOptions: CreationBoundarySeriesOption[] = []
    for (let index = 0; index < (response.data?.boundaries ?? []).length; index++) {
      const item = response.data!.boundaries[index]!
      if (!item.found || !item.timestamps?.length || item.timestamps.length !== item.values?.length) continue
      const boundaryId = item.boundaryId || candidates[index]?.id
      const boundary = candidates.find(candidate => candidate.id === boundaryId)
      if (!boundary || !boundaryId) continue
      databaseOptions.push({
        value: `${boundaryId}:${layerId}`,
        label: `${boundary.name} · ${creationLayerOptions.value.find(layer => String(layer.id) === String(layerId))?.name ?? `时层${layerId}`}（边界数据库）`,
        timestamps: item.timestamps.map(String),
        values: item.values!.map(Number),
        source: 'database'
      })
    }
    const databaseIds = new Set(databaseOptions.map(option => option.value))
    boundarySeriesOptions.value = [
      ...databaseOptions,
      ...boundarySeriesOptions.value.filter(option => !databaseIds.has(option.value))
    ]
  }
  catch {
    if (boundarySeriesOptions.value.length) {
      boundarySeriesWarning.value = '边界数据库暂不可用，当前使用项目中保存的同层缓存。'
    }
    else {
      boundarySeriesWarning.value = '边界数据库暂不可用，且项目中没有该时层的缓存曲线。'
    }
  }
  finally {
    boundarySeriesLoading.value = false
  }
}

watch(() => newTask.canvasId, () => {
  if (!creationGridOptions.value.some(option => option.value === newTask.poiId)) {
    newTask.poiId = creationGridOptions.value[0]?.value ?? ''
  }
})

watch(isIslandedFlexibility, (isIslanded) => {
  if (!isIslanded) return
  newTask.poiId = ''
  if (newTask.requirementSource === 'agc_or_schedule') newTask.requirementSource = 'net_load_change'
})

watch(
  [() => newTask.flexibilityValueMode, () => flexibilityEvaluationLayerId.value],
  ([mode]) => {
    if (mode === 'boundary') void refreshBoundarySeriesOptions()
  }
)

watch(showCreateDialog, async (open) => {
  if (open) {
    newTask.projectId = initialProjectId || selectedTask.value?.project_id || newTask.projectId
    newTask.canvasId = initialCanvasId || selectedTask.value?.canvas_id || newTask.canvasId
    newTask.simMode = 'multi_layer'
    newTask.targetLayerId = '1'
    await loadCreationProject(newTask.projectId)
    // 设置默认值
    newTask.name = defaultTaskName.value
  }
})

// 当项目或画布变化时更新默认任务名称
watch([creationProjectName, creationCanvasName], () => {
  if (showCreateDialog.value) {
    newTask.name = defaultTaskName.value
  }
})

onMounted(async () => {
  // 如果有 initialProjectId，预加载项目信息（用于返回按钮）
  if (initialProjectId && !currentProject.value) {
    await loadProject(initialProjectId)
  }
})

const parseFlexibilityValueSpec = (
  constantValue: number,
  seriesValue: Record<string, number>,
  fieldLabel: string,
  nonnegative: boolean
): FlexibilityValueSpec => {
  if (newTask.flexibilityValueMode === 'constant') {
    const value = Number(constantValue)
    if (!Number.isFinite(value) || (nonnegative && value < 0)) {
      throw new Error(`${fieldLabel}必须是${nonnegative ? '非负' : ''}有限数值`)
    }
    return value
  }

  if (!seriesValue || Object.keys(seriesValue).length === 0) {
    throw new Error(`${fieldLabel}的分时数据必须是非空的时间戳对象`)
  }

  const result: Record<string, number> = {}
  for (const [timestamp, rawValue] of Object.entries(seriesValue)) {
    const value = Number(rawValue)
    if (!Number.isFinite(value) || (nonnegative && value < 0)) {
      throw new Error(`${fieldLabel}在 ${timestamp} 的值必须是${nonnegative ? '非负' : ''}有限数值`)
    }
    result[timestamp] = value
  }
  return result
}

const buildFlexibilityTaskConfig = (): FlexibilityTaskConfig => {
  const islanded = isIslandedFlexibility.value
  if (!islanded && creationGridOptions.value.length > 1 && !newTask.poiId) {
    throw new Error('当前画布存在多个电网接口，请选择本次评价使用的并网点')
  }
  if (islanded && newTask.requirementSource === 'agc_or_schedule') {
    throw new Error('离网系统没有并网点，不能使用AGC目标计划作为需求来源')
  }

  const config: FlexibilityTaskConfig = {
    enabled: true,
    layerId: flexibilityEvaluationLayerId.value,
    // 后端兼容字段；当前优化模型始终采用经济运行基准，不再向用户暴露无效选项。
    operationMode: 'economic_operation',
    networkMode: islanded ? 'islanded' : 'grid_connected',
    boundaryCondition: islanded ? 'islanded_local_balance' : 'grid_component_limits',
    poiId: islanded ? null : (newTask.poiId || null),
    requirementSource: newTask.requirementSource
  }

  if (newTask.requirementSource === 'agc_or_schedule') {
    if (newTask.flexibilityValueMode !== 'constant' && seriesValidationErrors.target) {
      throw new Error(seriesValidationErrors.target)
    }
    config.targetPoiPowerKw = parseFlexibilityValueSpec(
      newTask.targetPoiPowerKw,
      newTask.targetPoiPowerSeries,
      '目标并网功率',
      false
    )
  }
  else if (newTask.requirementSource === 'user_defined') {
    if (newTask.flexibilityValueMode !== 'constant') {
      if (seriesValidationErrors.upward) throw new Error(seriesValidationErrors.upward)
      if (seriesValidationErrors.downward) throw new Error(seriesValidationErrors.downward)
    }
    config.upwardRequirementKw = parseFlexibilityValueSpec(
      newTask.upwardRequirementKw,
      newTask.upwardRequirementSeries,
      '上调需求',
      true
    )
    config.downwardRequirementKw = parseFlexibilityValueSpec(
      newTask.downwardRequirementKw,
      newTask.downwardRequirementSeries,
      '下调需求',
      true
    )
  }
  return config
}

const createTask = async () => {
  if (creatingTask.value) return
  if (!newTask.projectId) {
    push({ tone: 'warning', title: '请填写 projectId' })
    return
  }
  if (!validateCalendarRange()) {
    push({ tone: 'warning', title: '仿真日期范围不可用', description: dateRangeError.value })
    return
  }
  if (creationTimeMode.value === 'relative' && !validateTimeRange(timeRange.value)) {
    push({ tone: 'warning', title: '时间范围格式错误', description: timeRangeError.value })
    return
  }
  creatingTask.value = true
  try {
    const flexibility = buildFlexibilityTaskConfig()
    // 单层仿真时使用 targetLayerId，多层仿真时使用 layerId（默认 '1'）
    const effectiveLayerId = newTask.simMode === 'single_layer' ? newTask.targetLayerId : newTask.layerId
    const res = await taskApi.createTask({
      projectId: newTask.projectId,
      canvasId: newTask.canvasId,
      layerId: effectiveLayerId,
      mode: newTask.mode,
      simMode: newTask.simMode,
      targetLayerId: newTask.simMode === 'single_layer' ? newTask.targetLayerId : undefined,
      simStartTime: '0:00',
      simEndTime: simEndTime.value,
      simStartDate: creationTimeMode.value === 'calendar' ? simStartDate.value : null,
      simEndDate: creationTimeMode.value === 'calendar' ? simEndDate.value : null,
      name: newTask.name || null,
      flexibility
    })
    showCreateDialog.value = false
    // 秒开：先立结果壳，列表/项目/灵活性后台补齐
    activeSection.value = 'overview'
    push({ tone: 'success', title: '任务已创建' })
    await selectTask(res.id, { instantShell: true })
    void refreshList()
  }
  catch (err) {
    push({ tone: 'danger', title: '创建任务失败', description: String(err) })
  }
  finally {
    creatingTask.value = false
  }
}
</script>

<template>
  <div class="h-screen flex flex-col bg-app-bg">
    <!-- 头部 -->
    <header class="flex items-center h-14 px-4 bg-primary text-white">
      <button
        class="inline-flex items-center gap-1 px-3 h-8 rounded text-sm hover:bg-white/10"
        @click="() => {
          const pid = currentProject?.id || selectedTask?.project_id || initialProjectId
          navigateTo(pid ? `/editor/${pid}` : '/project')
        }"
      >← 返回</button>
      <h1 class="ml-4 text-base font-medium">结果分析</h1>
      <div class="ml-auto flex items-center gap-2">
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md px-3 text-sm font-medium text-white transition hover:bg-white/10"
          type="button"
          @click="openTaskList"
        >
          📋 任务列表
        </button>
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md bg-white/20 px-3 text-sm font-medium text-white transition hover:bg-white/30"
          type="button"
          @click="showCreateDialog = true"
        >
          ➕ 新建任务
        </button>
      </div>
    </header>

    <div class="flex-1 min-h-0 flex gap-2 p-2">
      <!-- 左：分析栏目导航 -->
      <aside class="panel-card w-56 flex flex-col">
        <div class="flex items-center px-3 h-12 border-b border-app-border">
          <span class="text-sm font-medium">仿真结果分析</span>
        </div>

        <div class="flex-1 overflow-y-auto">
          <div
            v-for="section in sections"
            :key="section.key"
            class="flex items-center px-3 h-11 cursor-pointer transition-colors"
            :class="activeSection === section.key ? 'bg-primary-soft' : 'hover:bg-app-panel-soft'"
            @click="activeSection = section.key"
          >
            <span class="mr-2 text-sm">{{ section.icon }}</span>
            <span class="flex-1 text-sm truncate">{{ section.label }}</span>
          </div>
        </div>
      </aside>

      <!-- 右：内容区 -->
      <main class="flex-1 panel-card flex flex-col min-h-0 p-3">
        <!-- 未选中任务 -->
        <div v-if="!selectedTask" class="flex-1 flex flex-col items-center justify-center text-app-muted text-sm gap-4">
          <div>请先选择一个计算任务</div>
          <AppButton label="选择任务" tone="primary" @click="openTaskList" />
        </div>

        <!-- 已选中任务 -->
        <div v-else class="flex-1 flex flex-col min-h-0">
          <!-- 任务信息栏 -->
          <div class="flex items-center justify-between mb-3 pb-3 border-b border-app-border">
            <div>
              <div class="text-sm font-medium">
                任务: {{ selectedTask.name ?? selectedTask.id.slice(0, 8) }}
              </div>
              <div v-if="selectedTask.sim_start_date && selectedTask.sim_end_date" class="mt-1 text-xs text-app-muted">
                仿真日期：{{ selectedTask.sim_start_date }} 至 {{ selectedTask.sim_end_date }}
              </div>
              <div v-if="resultShellLoading" class="mt-1 text-xs text-primary">
                正在加载项目与评价结果，图表将随求解进度逐步填充…
              </div>
            </div>
            <div class="flex items-center gap-2">
              <span
                class="px-2 py-0.5 rounded text-xs"
                :class="`bg-${STATUS_TONE[selectedTask.status]}-soft text-${STATUS_TONE[selectedTask.status]}`"
              >{{ STATUS_LABEL[selectedTask.status] }}</span>
              <AppButton
                v-if="showActions(selectedTask).cancel"
                label="取消"
                size="sm"
                tone="danger"
                @click="doAction('cancel', selectedTask!.id)"
              />
              <AppButton
                v-if="showActions(selectedTask).cleanup"
                label="清理"
                size="sm"
                tone="ghost"
                @click="doAction('cleanup', selectedTask!.id)"
              />
            </div>
          </div>

          <!-- 运行总览 -->
          <div v-if="activeSection === 'overview'" class="flex-1 min-h-0 overflow-y-auto">
            <ResultChartsSkeleton
              v-if="Object.keys(liveData).length === 0"
              :status="selectedTask.status"
              :error-message="selectedTask.error_message"
            />
            <div v-else class="grid grid-cols-2 gap-3">
              <div
                v-for="(layers, key) in liveData"
                :key="key"
                class="border border-app-border rounded p-2"
              >
                <TaskSeriesChart
                  :layers="layers"
                  :data-version="liveDataVersions[String(key)] ?? 0"
                  :title="getChartDisplayName(String(key))"
                  :device-color-key="getChartDeviceColorKey(String(key))"
                  :unit="liveDataUnits[String(key)] ?? 'kW'"
                  :layer-names="layerNames"
                  :sim-start-time="taskSimRange.start"
                  :sim-end-time="taskSimRange.end"
                  :sim-start-date="selectedTask.sim_start_date"
                  :display-window="overviewDisplayWindow"
                  @update:display-window="updateOverviewDisplayWindow"
                />
              </div>
            </div>
          </div>

          <!-- 系统灵活性量化评估 -->
          <div v-else-if="activeSection === 'flexibility'" class="flex-1 min-h-0 overflow-y-auto">
            <div v-if="flexibilityLoading" class="flex h-full items-center justify-center text-sm text-app-muted">
              正在加载灵活性评价结果...
            </div>

            <div v-else-if="flexibilityError" class="flex h-full flex-col items-center justify-center gap-3 text-sm">
              <div class="max-w-xl rounded-[12px] border border-app-danger/30 bg-red-50 px-5 py-4 text-app-danger">
                {{ flexibilityError }}
              </div>
              <AppButton label="重新加载" tone="primary" size="sm" @click="reloadFlexibility(selectedTask!.id)" />
            </div>

            <div v-else-if="!flexibilityConfig" class="flex h-full flex-col items-center justify-center gap-2 text-center">
              <div class="inline-flex h-12 w-12 items-center justify-center rounded-full bg-app-panel-soft text-2xl">↕️</div>
              <p class="text-sm font-medium text-app-text">该历史任务未包含灵活性量化评估</p>
              <p class="max-w-md text-xs leading-5 text-app-muted">
                请新建计算任务；新任务将默认执行灵活性量化评估。
              </p>
            </div>

            <div v-else class="space-y-3">
              <section class="flex items-center gap-6 bg-app-panel-soft/60 px-4 py-2 text-sm">
                <span class="text-app-muted">需求来源：<span class="font-medium text-app-text">{{ FLEXIBILITY_REQUIREMENT_LABELS[flexibilityConfig.requirementSource] ?? flexibilityConfig.requirementSource }}</span></span>
                <span class="text-app-muted">网络口径：<span class="font-medium text-app-text">{{ flexibilityConfig.networkMode === 'islanded' ? '离网本地平衡' : '并网POI' }}</span></span>
                <template v-if="flexibilityConfig.networkMode !== 'islanded'">
                  <span class="text-app-muted">GRID功率边界：<span class="font-medium text-app-text">{{ flexibilityPoiLimits.minimum == null ? '--' : formatBoundaryPower(flexibilityPoiLimits.minimum) }} ～ {{ flexibilityPoiLimits.maximum == null ? '--' : formatBoundaryPower(flexibilityPoiLimits.maximum) }}</span></span>
                </template>
                <template v-else>
                  <span class="text-app-muted">系统边界：<span class="font-medium text-app-text">无外部交换，内部资源承担平衡</span></span>
                </template>
              </section>

              <section v-if="flexibilityData?.summaries.length" class="grid gap-3 xl:grid-cols-2">
                <div
                  v-for="direction in FLEXIBILITY_DIRECTIONS"
                  :key="direction"
                  class="bg-white border border-app-border p-4"
                >
                  <div class="mb-3 flex items-center justify-between">
                    <h3 class="text-base">{{ FLEXIBILITY_DIRECTION_LABELS[direction] }}全时域指标</h3>
                  </div>
                  <div class="grid grid-cols-2 gap-2 lg:grid-cols-4">
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">全时域最小裕度</div>
                      <div class="mt-1 text-base font-semibold text-app-text">{{ formatFlexValue(directionSummary(direction)?.minimum_margin) }} <span class="text-xs font-normal text-app-muted">kW</span></div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">最大缺额</div>
                      <div class="mt-1 text-base font-semibold text-app-text">{{ formatFlexValue(directionSummary(direction)?.maximum_deficit) }} <span class="text-xs font-normal text-app-muted">kW</span></div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">缺额电量</div>
                      <div class="mt-1 text-base font-semibold text-app-text">{{ formatFlexValue(directionSummary(direction)?.deficit_energy) }} <span class="text-xs font-normal text-app-muted">kWh</span></div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">达标时段比例</div>
                      <div
                        class="mt-1 text-base font-semibold"
                        :class="Number(directionSummary(direction)?.adequate_period_ratio) > 0.9 ? 'text-green-600' : 'text-orange-700'"
                      >
                        {{ formatFlexPercent(directionSummary(direction)?.adequate_period_ratio) }}
                      </div>
                    </div>
                  </div>
                </div>
              </section>

              <div v-if="flexibilityPeriods.length" class="grid gap-3">
                <FlexibilityRequirementSourceChart
                  :key="selectedTask.id"
                  :rows="flexibilityPeriods"
                  :source="flexibilityConfig.requirementSource"
                  :display-window="flexibilitySourceDisplayWindow"
                  @update:display-window="updateFlexibilitySourceDisplayWindow"
                  @open-demand-comparison="showFlexibilityDemandComparison = true"
                  :sim-start-time="taskSimRange.start"
                  :sim-end-minutes="taskSimRange.endMinutes"
                  :sim-start-date="selectedTask.sim_start_date"
                />
                <FlexibilitySeriesChart
                  :rows="flexibilityPeriods"
                  :device-labels="codeToLabel"
                  direction="up"
                  :display-window="flexibilityDisplayWindow"
                  @update:display-window="updateFlexibilityDisplayWindow"
                  :sim-start-time="taskSimRange.start"
                  :sim-end-time="taskSimRange.end"
                  :sim-end-minutes="taskSimRange.endMinutes"
                  :sim-start-date="selectedTask.sim_start_date"
                />
                <FlexibilitySeriesChart
                  :rows="flexibilityPeriods"
                  :device-labels="codeToLabel"
                  direction="down"
                  :display-window="flexibilityDisplayWindow"
                  @update:display-window="updateFlexibilityDisplayWindow"
                  :sim-start-time="taskSimRange.start"
                  :sim-end-time="taskSimRange.end"
                  :sim-end-minutes="taskSimRange.endMinutes"
                  :sim-start-date="selectedTask.sim_start_date"
                />
              </div>

              <FlexibilityDemandComparisonModal
                v-if="showFlexibilityDemandComparison && flexibilityConfig.requirementSource === 'net_load_change'"
                :rows="flexibilityPeriods"
                :initial-window="flexibilitySourceDisplayWindow"
                :sim-start-time="taskSimRange.start"
                :sim-end-minutes="taskSimRange.endMinutes"
                :sim-start-date="selectedTask.sim_start_date"
                @close="showFlexibilityDemandComparison = false"
              />

              <div v-if="!flexibilityPeriods.length" class="flex min-h-52 items-center justify-center rounded-[12px] border border-dashed border-app-border text-sm text-app-muted">
                {{ selectedTask.status === 'completed' ? '任务已完成，但暂无灵活性评价结果。' : '任务运行中，正在等待灵活性逐时段结果...' }}
              </div>
            </div>
          </div>

          <!-- 设备灵活性量化评估 -->
          <div v-else-if="activeSection === 'device-flexibility'" class="flex-1 min-h-0 overflow-y-auto">
            <div v-if="flexibilityLoading" class="flex h-full items-center justify-center text-sm text-app-muted">
              正在加载设备灵活性评价结果...
            </div>

            <div v-else-if="flexibilityError" class="flex h-full flex-col items-center justify-center gap-3 text-sm">
              <div class="max-w-xl rounded-[12px] border border-app-danger/30 bg-red-50 px-5 py-4 text-app-danger">
                {{ flexibilityError }}
              </div>
              <AppButton label="重新加载" tone="primary" size="sm" @click="reloadFlexibility(selectedTask!.id)" />
            </div>

            <div v-else-if="!flexibilityConfig" class="flex h-full flex-col items-center justify-center gap-2 text-center">
              <div class="inline-flex h-12 w-12 items-center justify-center rounded-full bg-app-panel-soft text-2xl">⚙️</div>
              <p class="text-sm font-medium text-app-text">该历史任务未包含灵活性量化评估</p>
              <p class="max-w-md text-xs leading-5 text-app-muted">
                新任务会默认生成系统汇总和各设备灵活性明细。
              </p>
            </div>

            <div v-else-if="deviceFlexibilityGroups.length" class="space-y-2">
              <DeviceFlexibilityChart
                v-for="device in deviceFlexibilityGroups"
                :key="device.key"
                :title="device.label"
                :device-type="device.deviceType"
                :rows="device.rows"
                :boundary="device.boundary"
                :sim-start-time="taskSimRange.start"
                :sim-end-time="taskSimRange.end"
                :sim-start-date="selectedTask.sim_start_date"
                :display-window="deviceFlexDisplayWindow"
                @update:display-window="updateDeviceFlexDisplayWindow"
              />
            </div>

            <div v-else class="flex min-h-52 items-center justify-center rounded-[12px] border border-dashed border-app-border text-sm text-app-muted">
              {{ selectedTask.status === 'completed' ? '任务已完成，但暂无设备灵活性评价结果。' : '任务运行中，正在等待设备灵活性结果...' }}
            </div>
          </div>

          <!-- 能流平衡分析 -->
          <div v-else-if="activeSection === 'energy-flow'" class="flex-1 min-h-0 flex flex-col">
            <div
              v-if="connectionData.length === 0"
              class="flex-1 flex items-center justify-center text-app-muted text-sm"
            >
              等待任务数据...
            </div>
            <div v-else class="flex-1 min-h-0 flex flex-col gap-3">
              <div class="flex flex-shrink-0 items-center justify-end gap-2">
                <AppButton
                  label="能流平衡模式"
                  size="md"
                  :tone="energyFlowDisplayMode === 'balance' ? 'primary' : 'neutral'"
                  @click="energyFlowDisplayMode = 'balance'"
                />
                <AppButton
                  label="负荷跟踪模式"
                  size="md"
                  :tone="energyFlowDisplayMode === 'loadTracking' ? 'primary' : 'neutral'"
                  @click="energyFlowDisplayMode = 'loadTracking'"
                />
              </div>

              <div class="flex-1 min-h-0 overflow-y-auto space-y-6">
                <div
                  v-for="bus in connectionData"
                  :key="bus.busCode"
                  class="space-y-3"
                >
                  <div
                    v-for="layer in layerOptions"
                    :key="layer.value"
                    class="border border-app-border rounded p-3"
                  >
                    <EnergyFlowChart
                      :bus-label="`${bus.busLabel} · ${layer.label}`"
                      :variables="bus.variables"
                      :live-data="liveData"
                      :layer-id="layer.value"
                      :code-to-label="codeToLabel"
                      :display-mode="energyFlowDisplayMode"
                      :time-step-minutes="layer.stepMinutes"
                      :sim-start-time="taskSimRange.start"
                      :sim-end-time="taskSimRange.end"
                      :sim-start-date="selectedTask.sim_start_date"
                      :display-window="energyFlowDisplayWindow"
                      @update:display-window="updateEnergyFlowDisplayWindow"
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>

          <!-- 设备出力分析 -->
          <div v-else-if="activeSection === 'device-output'" class="flex-1 min-h-0">
            <DeviceOutputAnalysis
              :task-id="selectedTask.id"
              :canvas-id="selectedTask.canvas_id"
              :project="currentProject"
              :live-data="liveData"
              :live-data-units="liveDataUnits"
              :layer-options="layerOptions"
              :sim-start-time="taskSimRange.start"
              :sim-end-time="taskSimRange.end"
              :sim-start-date="selectedTask.sim_start_date"
            />
          </div>

          <!-- 经济性分析 -->
          <div v-else-if="activeSection === 'economy'" class="flex-1 min-h-0 overflow-auto p-4 space-y-4">
            <!-- 加载中 -->
            <div v-if="economyLoading" class="flex items-center justify-center h-64 text-app-muted">
              <div class="text-sm">正在计算经济性指标...</div>
            </div>

            <!-- 错误 -->
            <div v-else-if="economyError" class="flex items-center justify-center h-64">
              <div class="text-sm text-red-500">{{ economyError }}</div>
            </div>

            <!-- 无数据 -->
            <div v-else-if="!economyData || !economyData.layers?.length" class="flex items-center justify-center h-64 text-app-muted">
              <div class="text-sm">
                {{ economyData?.message || (economyData?.isPartial !== false
                  ? '暂无经济性数据（等待仿真产生结果后自动刷新）'
                  : '暂无经济性数据') }}
              </div>
            </div>

            <!-- 经济性数据展示 -->
            <template v-else>
              <!-- 总览：累计 + 日均/月均/年化 -->
              <div class="border border-app-border bg-white p-4 space-y-3">
                <div class="flex items-center justify-between">
                  <h3 class="text-sm font-semibold text-app-text">运行经济性总览</h3>
                  <div class="flex items-center gap-2">
                    <span
                      v-if="economyData.isPartial"
                      class="inline-flex items-center rounded-full bg-amber-50 border border-amber-200 px-2 py-0.5 text-xs text-amber-700"
                    >
                      运行中 · 截至 {{ economyData.coveredEnd || economyMetrics?.coveredEnd || '--' }}
                    </span>
                    <span
                      v-else
                      class="inline-flex items-center rounded-full bg-emerald-50 border border-emerald-200 px-2 py-0.5 text-xs text-emerald-700"
                    >
                      已完成
                    </span>
                  </div>
                </div>

                <div v-if="economyMetrics" class="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-3">
                  <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                    <div class="text-sm text-app-muted">平均净成本</div>
                    <div class="mt-1 text-base font-semibold text-app-text">{{ formatMoney(economyMetrics.netCost) }}</div>
                    <div class="text-xs text-app-muted mt-0.5">含售电收益抵扣</div>
                  </div>
                  <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                    <div class="text-sm text-app-muted">日均成本</div>
                    <div class="mt-1 text-base font-semibold text-app-text">{{ formatMoney(economyMetrics.dailyAvgCost) }}</div>
                    <div class="text-xs text-app-muted mt-0.5">已覆盖 {{ formatDays(economyMetrics.elapsedDays) }}</div>
                  </div>
                  <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                    <div class="text-sm text-app-muted">月均估算</div>
                    <div class="mt-1 text-base font-semibold text-primary">{{ formatMoney(economyMetrics.monthlyEstimateCost) }}</div>
                    <div class="text-xs text-app-muted mt-0.5">日均 × 30</div>
                  </div>
                  <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                    <div class="text-sm text-app-muted">年化估算</div>
                    <div class="mt-1 text-base font-semibold text-primary">{{ formatMoney(economyMetrics.annualEstimateCost) }}</div>
                    <div class="text-xs text-app-muted mt-0.5">日均 × 365 · 粗估</div>
                  </div>
                  <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                    <div class="text-sm text-app-muted">目标函数值</div>
                    <div class="mt-1 text-base font-semibold text-app-text">{{ formatMoney(economyMetrics.objectiveValue) }}</div>
                    <div class="text-xs text-app-muted mt-0.5">不含松弛惩罚</div>
                  </div>
                  <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                    <div class="text-sm text-app-muted">仿真覆盖进度</div>
                    <div class="mt-1 text-base font-semibold text-app-text">{{ ((economyMetrics.progressRatio || 0) * 100).toFixed(1) }}%</div>
                    <div class="text-xs text-app-muted mt-0.5">
                      {{ economyMetrics.coveredStart }} → {{ economyMetrics.coveredEnd }}
                    </div>
                  </div>
                </div>

                <!-- 分项日均/年化 -->
                <div v-if="economyMetrics?.byCostType && Object.keys(economyMetrics.byCostType).length" class="overflow-x-auto">
                  <table class="w-full text-sm">
                    <thead>
                      <tr class="border-t border-app-border bg-app-panel-soft">
                        <th class="px-4 py-3 text-left font-medium text-app-muted">成本项</th>
                        <th class="px-4 py-3 text-right font-medium text-app-muted">累计</th>
                        <th class="px-4 py-3 text-right font-medium text-app-muted">日均</th>
                        <th class="px-4 py-3 text-right font-medium text-app-muted">月均估算</th>
                        <th class="px-4 py-3 text-right font-medium text-app-muted">年化估算</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr v-for="(m, key) in economyMetrics.byCostType" :key="key" class="border-t border-app-border">
                        <td class="px-4 py-3">{{ COST_TYPE_LABELS[key as string] ?? key }}</td>
                        <td class="px-4 py-3 text-right" :class="{ 'text-green-600': Number(m.total) < 0 }">{{ formatMoney(m.total) }}</td>
                        <td class="px-4 py-3 text-right">{{ formatMoney(m.daily) }}</td>
                        <td class="px-4 py-3 text-right">{{ formatMoney(m.monthly) }}</td>
                        <td class="px-4 py-3 text-right text-primary">{{ formatMoney(m.annual) }}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
                <div v-if="economyMetrics?.note" class="text-xs text-app-muted">{{ economyMetrics.note }}</div>
              </div>

              <!-- 各时层经济性概览（纵向排列） -->
              <div
                v-for="layer in economyData.layers"
                :key="layer.layerId"
                class="border border-app-border bg-white p-4 space-y-4"
              >
                <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                  <!-- 左半区：扇形图 + 不平衡提醒 -->
                  <div class="space-y-3">
                    <div v-if="economyLayerPieItems[layer.layerId]?.length > 0">
                      <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
                        <h3 class="text-sm font-semibold text-app-text">{{ layer.layerName }} · 目标函数组成</h3>
                        <div class="text-sm text-app-muted">
                          目标函数值（不含松弛惩罚）：
                          <span class="font-semibold text-app-text">{{ formatMoney(layer.objectiveValue) }}</span>
                        </div>
                      </div>
                      <PieChart
                        :items="economyLayerPieItems[layer.layerId]"
                        unit="元"
                      />
                    </div>
                    <div v-else class="text-sm text-app-muted">
                      {{ layer.layerName }} · 目标函数组成暂无数据
                    </div>

                    <!-- 松弛变量警告：放在扇形图下方 -->
                    <div v-if="layer.hasSlack" class="border border-orange-300 bg-orange-50 p-3">
                      <div class="flex items-center gap-2 text-orange-700 font-semibold text-sm mb-1">
                        ⚠️ 存在能量不平衡
                      </div>
                      <div class="text-xs text-orange-600 space-y-1">
                        <div v-if="(layer.slackPenalty ?? 0) > 0">
                          松弛惩罚：{{ formatMoney(layer.slackPenalty ?? 0) }}
                        </div>
                        <div>说明：松弛变量大于0表示系统能量供应不平衡</div>
                      </div>
                    </div>
                  </div>

                  <!-- 右半区：目标函数组成明细表 + 总成本/售电收益 -->
                  <div class="overflow-x-auto">
                    <table class="w-full text-sm">
                      <thead>
                        <tr class="border-t border-app-border bg-app-panel-soft">
                          <th class="px-4 py-3 text-left font-medium text-app-muted">项目</th>
                          <th class="px-4 py-3 text-right font-medium text-app-muted">金额</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          v-for="(value, key) in layer.costBreakdown"
                          :key="key"
                          class="border-t border-app-border"
                        >
                          <td class="px-4 py-3">{{ COST_TYPE_LABELS[key as string] ?? key }}</td>
                          <td class="px-4 py-3 text-right" :class="Number(value) < 0 ? 'text-green-600' : ''">
                            {{ formatMoney(value) }}
                          </td>
                        </tr>
                        <tr
                          v-for="(value, key) in (layer.revenueItems ?? {})"
                          v-show="!(layer.costBreakdown && key in layer.costBreakdown)"
                          :key="`rev-${key}`"
                          class="border-t border-app-border"
                        >
                          <td class="px-4 py-3 text-green-600">{{ COST_TYPE_LABELS[key as string] ?? key }}</td>
                          <td class="px-4 py-3 text-right text-green-600">
                            {{ formatMoney(value) }}
                          </td>
                        </tr>
                        <tr class="border-t border-app-border bg-app-panel-soft/50">
                          <td class="px-4 py-3 font-medium text-app-text">总成本</td>
                          <td class="px-4 py-3 text-right font-semibold text-app-text">
                            {{ formatMoney(layer.totalCost ?? 0) }}
                          </td>
                        </tr>
                        <tr class="border-t border-app-border bg-app-panel-soft/50">
                          <td class="px-4 py-3 font-medium text-app-text">目标函数值（不含松弛惩罚）</td>
                          <td class="px-4 py-3 text-right font-semibold text-app-text">
                            {{ formatMoney(layer.objectiveValue ?? 0) }}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>

              <!-- 各时层经济性对比 + 设备经济性明细（关联展示） -->
              <div class="border border-app-border bg-white overflow-hidden">
                <h3 class="text-sm font-semibold text-app-text px-4 pt-3 pb-2">各时层经济性对比</h3>
                <div class="overflow-x-auto">
                  <table class="w-full min-w-[920px] table-fixed text-sm">
                    <colgroup>
                      <col class="w-[6.5rem]" />
                      <col />
                      <col />
                      <col class="w-[6.5rem]" />
                      <col class="w-[6.5rem]" />
                      <col class="w-[6.5rem]" />
                      <col />
                      <col class="w-[4.5rem]" />
                    </colgroup>
                    <thead>
                      <tr class="border-t border-app-border bg-app-panel-soft">
                        <th class="px-3 py-3 text-left font-medium text-app-muted">时层</th>
                        <th class="px-3 py-3 text-right font-medium text-app-muted">目标函数值</th>
                        <th class="px-3 py-3 text-right font-medium text-app-muted">运维成本</th>
                        <th class="px-3 py-3 text-right font-medium text-app-muted">启停</th>
                        <th class="px-3 py-3 text-right font-medium text-app-muted">调整</th>
                        <th class="px-3 py-3 text-right font-medium text-app-muted">购电</th>
                        <th class="px-3 py-3 text-right font-medium text-app-muted">售电</th>
                        <th class="px-3 py-3 text-center font-medium text-app-muted">状态</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        v-for="layer in economyData.layers"
                        :key="layer.layerId"
                        class="border-t border-app-border hover:bg-blue-50 cursor-pointer"
                        :class="{ 'bg-blue-50': layer.layerId === economySelectedLayer }"
                        @click="economySelectedLayer = layer.layerId"
                      >
                        <td class="px-3 py-3 font-medium whitespace-nowrap">{{ layer.layerName }}</td>
                        <td class="px-3 py-3 text-right">{{ formatMoney(layer.objectiveValue) }}</td>
                        <td class="px-3 py-3 text-right">{{ formatMoney(layer.costBreakdown['om_cost'] ?? 0) }}</td>
                        <td class="px-3 py-3 text-right">{{ formatMoney(layer.costBreakdown['on_off_cost'] ?? 0) }}</td>
                        <td class="px-3 py-3 text-right">{{ formatMoney(layer.costBreakdown['adjust_cost'] ?? 0) }}</td>
                        <td class="px-3 py-3 text-right">{{ formatMoney(layer.costBreakdown['purchase_cost'] ?? 0) }}</td>
                        <td class="px-3 py-3 text-right text-green-600">{{ formatMoney(layer.costBreakdown['sell_revenue'] ?? 0) }}</td>
                        <td class="px-3 py-3 text-center">
                          <span v-if="layer.hasSlack" class="text-orange-500" title="存在松弛变量">⚠️</span>
                          <span v-else class="text-green-500" title="能量平衡">✓</span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <!-- 设备经济性明细 -->
                <div class="border-t border-app-border p-4">
                  <div class="flex items-center justify-between mb-3">
                    <h3 class="text-sm font-semibold text-app-text">设备经济性明细</h3>
                    <div class="text-xs text-app-muted">
                      <span class="inline-block w-2 h-2 rounded-full bg-app-text align-middle mr-1" />进入目标函数
                      <span class="inline-block w-2 h-2 rounded-full bg-gray-300 align-middle mr-1 ml-3" />未选入目标（仅统计）
                    </div>
                  </div>
                  <div
                    v-if="economySelectedLayerSummary"
                    class="grid grid-cols-[repeat(auto-fill,minmax(300px,1fr))] gap-3"
                  >
                    <div
                      v-for="(value, compKey) in economySelectedLayerSummary.componentBreakdown"
                      :key="compKey"
                      class="rounded-lg border border-app-border bg-white p-3 shadow-sm min-w-0"
                    >
                      <div class="text-sm font-semibold text-app-text mb-1 truncate" :title="economyCompDisplayName(String(compKey))">
                        {{ economyCompDisplayName(String(compKey)) }}
                      </div>
                      <div class="text-sm font-medium">{{ formatMoney(value) }}</div>
                      <div class="mt-2 space-y-1">
                        <div
                          v-for="item in economyData.allCostItems.filter(i => i.layerId === economySelectedLayerSummary!.layerId && `${i.componentType}_${i.componentId}` === compKey)"
                          :key="item.costType"
                          class="text-xs"
                          :class="{ 'text-gray-400': !item.inObjective && !item.isSlack, 'text-app-muted': item.inObjective, 'text-orange-600': item.isSlack }"
                        >
                          <div class="flex justify-between gap-2">
                            <span class="truncate">
                              {{ item.costLabel }}
                              <span v-if="item.isSlack" class="text-orange-500">[松弛]</span>
                              <span v-else-if="!item.inObjective" class="text-gray-400">[未选入目标]</span>
                              <span v-else class="text-emerald-600">[目标]</span>
                            </span>
                            <span class="shrink-0" :class="{ 'text-green-600': item.isRevenue }">
                              {{ formatMoney(item.value) }}
                            </span>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </template>
          </div>

          <!-- 其他栏目占位 -->
          <div v-else class="flex-1 flex items-center justify-center text-app-muted text-sm">
            {{ sections.find(s => s.key === activeSection)?.label ?? '' }} - 开发中...
          </div>
        </div>
      </main>
    </div>

    <!-- 任务列表弹窗 -->
    <AppModal
      :open="showTaskListDialog"
      title="计算任务列表"
      size="lg"
      @close="showTaskListDialog = false"
    >
      <div class="px-2 py-1">
        <div class="max-h-96 overflow-y-auto">
          <div v-if="taskList.length === 0" class="p-4 text-center text-sm text-app-muted">
            暂无任务
          </div>
          <table v-else class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs text-app-muted border-b border-app-border">
                <th class="pb-2 pr-4">任务名称</th>
                <th class="pb-2 pr-4">项目ID</th>
                <th class="pb-2 pr-4">模式</th>
                <th class="pb-2 pr-4">状态</th>
                <th class="pb-2">操作</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="t in taskList"
                :key="t.id"
                class="border-b border-app-border cursor-pointer hover:bg-app-panel-soft"
                @click="selectTask(t.id)"
              >
                <td class="py-2 pr-4 truncate max-w-[10rem]">{{ t.name ?? t.id.slice(0, 8) }}</td>
                <td class="py-2 pr-4 font-mono text-xs text-app-muted truncate max-w-[8rem]">{{ t.project_id }}</td>
                <td class="py-2 pr-4">{{ t.mode === 'offline' ? '离线' : '在线' }}</td>
                <td class="py-2 pr-4">
                  <span
                    class="px-1.5 py-0.5 rounded text-[10px]"
                    :class="`bg-${STATUS_TONE[t.status]}-soft text-${STATUS_TONE[t.status]}`"
                  >{{ STATUS_LABEL[t.status] }}</span>
                </td>
                <td class="py-2">
                  <div class="flex gap-1">
                    <AppButton
                      v-if="showActions(t).cancel"
                      label="取消"
                      size="sm"
                      tone="danger"
                      @click.stop="doAction('cancel', t.id)"
                    />
                    <AppButton
                      v-if="showActions(t).cleanup"
                      label="清理"
                      size="sm"
                      tone="ghost"
                      @click.stop="doAction('cleanup', t.id)"
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <template #footer>
        <AppButton label="刷新" tone="ghost" size="sm" @click="refreshList" />
        <AppButton label="关闭" tone="neutral" size="sm" @click="showTaskListDialog = false" />
      </template>
    </AppModal>

    <!-- 新建任务弹窗 -->
    <AppModal
      :open="showCreateDialog"
      title="新建仿真计算任务"
      size="lg"
      @close="showCreateDialog = false"
    >
      <div class="space-y-4 px-2 py-1">
        <section class="p-2">
          <div class="mb-3">
            <h3 class="text-base text-app-text">仿真任务设置</h3>
          </div>

          <div class="space-y-4 border-t border-app-border pt-4">
            <!-- 项目名称和建模画布在同一行 -->
            <div class="property-row-double">
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">项目名称</label>
                <PropertyText
                  :model-value="creationProjectName"
                  placeholder=""
                  :disabled="true"
                />
              </div>
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">建模画布</label>
                <PropertySelect
                  v-model="newTask.canvasId"
                  :options="canvasSelectOptions"
                />
              </div>
            </div>
            <!-- 任务名称 -->
            <div class="property-row-double">
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">任务名称</label>
                <PropertyText
                  v-model="newTask.name"
                  :placeholder="defaultTaskName"
                />
              </div>
            </div>
            <!-- 无关联边界的任务仍使用相对时间范围 -->
            <div class="property-row-double">
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">运行方式</label>
                <PropertyText
                  model-value="离线计算"
                  placeholder=""
                  :disabled="true"
                />
              </div>
              <div v-if="creationTimeMode !== 'calendar'" class="flex items-center gap-2 flex-1">
                <label class="property-label">时间范围</label>
                <div class="flex-1">
                  <PropertyText
                    :model-value="timeRange"
                    placeholder="0:00-24:00"
                    :disabled="creationTimeMode === 'invalid'"
                    @update:model-value="onTimeRangeChange"
                  />
                  <p v-if="timeRangeError" class="text-xs text-red-500 mt-1">{{ timeRangeError }}</p>
                  <p v-if="creationTimeMode === 'invalid'" class="mt-1 text-xs text-app-danger">
                    当前画布关联边界缺少有效的日期覆盖信息，请先重新导入并提交边界数据。
                  </p>
                </div>
              </div>
            </div>
            <!-- 日历模式使用独立区域，避免起止日期并排时内容被截断 -->
            <div v-if="creationTimeMode === 'calendar'" class="property-row-double calendar-date-row">
              <label class="property-label">仿真日期</label>
              <div class="min-w-0 flex-1 space-y-2">
                <div class="flex items-center gap-2">
                  <span class="w-[70px] flex-shrink-0 text-sm text-app-muted">起始日期</span>
                  <AppDateInput
                    v-model="simStartDate"
                    class="min-w-0 flex-1"
                    :min="commonCalendarCoverage?.start"
                    :max="simEndDate || commonCalendarCoverage?.end"
                    @change="validateCalendarRange"
                  />
                </div>
                <div class="flex items-center gap-2">
                  <span class="w-[70px] flex-shrink-0 text-sm text-app-muted">终止日期</span>
                  <AppDateInput
                    v-model="simEndDate"
                    class="min-w-0 flex-1"
                    :min="simStartDate || commonCalendarCoverage?.start"
                    :max="commonCalendarCoverage?.end"
                    @change="validateCalendarRange"
                  />
                </div>
                <div class="flex items-center gap-6 whitespace-nowrap pl-[78px] text-xs text-app-muted">
                  <p>当前仿真时长：{{ calendarDurationDays ?? 0 }} 天</p>
                  <p>可选日期范围：{{ commonCalendarCoverage?.start }} 至 {{ commonCalendarCoverage?.end }}</p>
                </div>
                <div class="pl-[78px] text-xs">
                  <p v-if="dateRangeError" class="mt-1 text-app-danger">{{ dateRangeError }}</p>
                </div>
              </div>
            </div>
            <!-- 仿真时层 -->
            <div class="property-row-double">
              <label class="property-label">仿真时层</label>
              <div class="sim-mode-toggle">
                <button
                  type="button"
                  class="sim-mode-toggle__btn"
                  :class="newTask.simMode === 'multi_layer' ? 'sim-mode-toggle__btn--active' : ''"
                  @click="newTask.simMode = 'multi_layer'"
                >
                  多层联合
                </button>
                <button
                  type="button"
                  class="sim-mode-toggle__btn"
                  :class="newTask.simMode === 'single_layer' ? 'sim-mode-toggle__btn--active' : ''"
                  @click="newTask.simMode = 'single_layer'"
                >
                  单层仿真
                </button>
              </div>
              <PropertySelect
                v-model="newTask.targetLayerId"
                :options="layerSelectOptions"
                :disabled="newTask.simMode === 'multi_layer'"
              />
            </div>
          </div>

          <p v-if="creationProjectLoading" class="mt-2 text-xs text-app-muted">正在读取项目配置...</p>
          <p v-else-if="creationProjectError" class="mt-2 text-xs text-app-danger">{{ creationProjectError }}</p>
        </section>

        <section class="p-4">
          <div>
            <h3 class="text-base text-app-text">灵活性评价设置</h3>
          </div>

          <div class="mt-4 space-y-3 border-t border-primary/15 pt-4">
            <div class="property-row-double">
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">需求来源</label>
                <PropertySelect
                  v-model="newTask.requirementSource"
                  :options="availableRequirementOptions.map(o => ({ value: o.value, label: o.label }))"
                />
              </div>
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">并网点</label>
                <PropertySelect
                  v-model="newTask.poiId"
                  :options="isIslandedFlexibility ? [{ value: '', label: '无并网点' }] : creationGridOptions.map(o => ({ value: o.value, label: o.label }))"
                  :disabled="isIslandedFlexibility"
                />
              </div>
            </div>
            
            <div class="bg-white text-xs text-app-muted px-3">
              {{ availableRequirementOptions.find(option => option.value === newTask.requirementSource)?.label }}：
              {{ availableRequirementOptions.find(option => option.value === newTask.requirementSource)?.description }}
            </div>

            <div
              v-if="selectedGridOption"
              data-testid="poi-boundary-summary"
              class="border border-app-border bg-white p-3"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div class="text-xs text-app-text">并网点功率边界</div>
                </div>
                <button type="button" class="text-xs font-medium text-primary hover:underline" @click="openGridConfiguration">
                  返回建模页
                </button>
              </div>
              <div class="mt-3 grid gap-2 text-xs sm:grid-cols-2 xl:grid-cols-4">
                <div class="rounded-lg bg-app-panel-soft px-3 py-2">
                  <div class="text-app-muted">接口容量</div>
                  <div class="mt-1 font-medium text-app-text">{{ formatBoundaryPower(selectedGridOption.capacityKw) }}</div>
                </div>
                <div class="rounded-lg bg-app-panel-soft px-3 py-2">
                  <div class="text-app-muted">上送上限</div>
                  <div class="mt-1 font-medium text-app-text">{{ formatBoundaryPower(selectedGridOption.maximumPoiPowerKw) }}</div>
                </div>
                <div class="rounded-lg bg-app-panel-soft px-3 py-2">
                  <div class="text-app-muted">购入下限</div>
                  <div class="mt-1 font-medium text-app-text">{{ formatBoundaryPower(selectedGridOption.minimumPoiPowerKw) }}</div>
                </div>
                <div class="rounded-lg bg-app-panel-soft px-3 py-2">
                  <div class="text-app-muted">上送 / 购入比例</div>
                  <div class="mt-1 font-medium text-app-text">{{ (selectedGridOption.sellRatio * 100).toFixed(0) }}% / {{ (selectedGridOption.buyRatio * 100).toFixed(0) }}%</div>
                </div>
              </div>
            </div>
            <div
              v-else
              data-testid="islanded-boundary-summary"
              class="bg-white text-xs text-app-muted px-3"
            >
              <div>离网模式不支持设置AGC目标计划</div>
            </div>


            <template v-if="newTask.requirementSource !== 'net_load_change'">
              <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs">
                <span class="text-app-muted">数值输入方式</span>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="constant" class="accent-primary">
                  全时域常数
                </label>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="file" class="accent-primary">
                  导入文件
                </label>
                <label class="inline-flex items-center gap-1.5">
                  <input v-model="newTask.flexibilityValueMode" type="radio" value="boundary" class="accent-primary">
                  项目边界数据库
                </label>
              </div>

              <div v-if="newTask.requirementSource === 'agc_or_schedule'">
                <label class="space-y-1 text-xs text-app-muted">
                  <span>目标并网功率/kW（正值表示上送）</span>
                  <input v-if="newTask.flexibilityValueMode === 'constant'" v-model.number="newTask.targetPoiPowerKw" type="number" step="100" class="field-input h-8 text-xs">
                </label>
                <FlexibilityTimeSeriesEditor
                  v-if="newTask.flexibilityValueMode !== 'constant'"
                  v-model="newTask.targetPoiPowerSeries"
                  :mode="newTask.flexibilityValueMode"
                  label="目标并网功率"
                  :boundary-options="boundarySeriesOptions"
                  :expected-timestamps="expectedRequirementTimestamps"
                  @validation="seriesValidationErrors.target = $event"
                />
              </div>

              <div v-else class="grid gap-3 sm:grid-cols-2">
                <div class="space-y-1 text-xs text-app-muted">
                  <span>上调需求（kW）</span>
                  <input v-if="newTask.flexibilityValueMode === 'constant'" v-model.number="newTask.upwardRequirementKw" type="number" min="0" step="100" class="field-input h-8 text-xs">
                  <FlexibilityTimeSeriesEditor
                    v-else
                    v-model="newTask.upwardRequirementSeries"
                    :mode="newTask.flexibilityValueMode"
                    label="上调需求"
                    :nonnegative="true"
                    :boundary-options="boundarySeriesOptions"
                    :expected-timestamps="expectedRequirementTimestamps"
                    @validation="seriesValidationErrors.upward = $event"
                  />
                </div>
                <div class="space-y-1 text-xs text-app-muted">
                  <span>下调需求（kW）</span>
                  <input v-if="newTask.flexibilityValueMode === 'constant'" v-model.number="newTask.downwardRequirementKw" type="number" min="0" step="100" class="field-input h-8 text-xs">
                  <FlexibilityTimeSeriesEditor
                    v-else
                    v-model="newTask.downwardRequirementSeries"
                    :mode="newTask.flexibilityValueMode"
                    label="下调需求"
                    :nonnegative="true"
                    :boundary-options="boundarySeriesOptions"
                    :expected-timestamps="expectedRequirementTimestamps"
                    @validation="seriesValidationErrors.downward = $event"
                  />
                </div>
              </div>

              <p v-if="newTask.flexibilityValueMode === 'boundary' && boundarySeriesLoading" class="text-xs text-app-muted">正在读取项目边界数据库...</p>
              <p v-else-if="newTask.flexibilityValueMode === 'boundary' && boundarySeriesWarning" class="rounded-lg bg-orange-50 px-3 py-2 text-xs text-orange-700">{{ boundarySeriesWarning }}</p>
            </template>
          </div>
        </section>
      </div>
      <template #footer>
        <AppButton
          label="取消"
          tone="neutral"
          :disabled="creatingTask"
          @click="showCreateDialog = false"
        />
        <AppButton
          label="创建"
          tone="primary"
          :loading="creatingTask"
          loading-label="创建中..."
          @click="createTask"
        />
      </template>
    </AppModal>
  </div>
</template>

<style scoped>
.property-row-double {
  display: flex;
  gap: 16px;
  align-items: center;
  padding-inline: 10px;
}

.property-row-double .property-label {
  width: 70px;
  flex-shrink: 0;
}

.calendar-date-row {
  align-items: flex-start;
}

.calendar-date-row > .property-label {
  padding-top: 30px;
}

.property-label {
  font-size: 14px;
  font-weight: 500;
  color: #1d2129;
}

.sim-mode-toggle {
  display: flex;
  border: 1px solid #dde1e6;
  border-radius: 6px;
  overflow: hidden;
  flex-shrink: 0;
}

.sim-mode-toggle__btn {
  padding: 6px 16px;
  font-size: 13px;
  font-weight: 500;
  color: #1d2129;
  background: #ffffff;
  border: none;
  cursor: pointer;
  transition: all 0.15s ease;
  white-space: nowrap;
}

.sim-mode-toggle__btn:first-child {
  border-right: 1px solid #dde1e6;
}

.sim-mode-toggle__btn:hover {
  background: #f5f7fa;
}

.sim-mode-toggle__btn--active {
  background: #0a4da2;
  color: #ffffff;
}

.sim-mode-toggle__btn--active:hover {
  background: #084a9a;
}
</style>
