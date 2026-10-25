<script setup lang="ts">
import type {
  ApplyCapacityPlanningResult,
  ApplyCapacityPlanningPreview,
  CapacityPlanningResult,
  CapacityPlanningStatus,
  CapacityPlanningTask,
  CapacityPlanningFormSchema,
  CapacityVariableDraft,
  CapacityEconomicsConfig,
  CapacityLifecycleParams,
  CapacityPlanningLifecycleBreakdown,
  CapacityVariableChangeKind,
  CapacityVariableValueKind,
  CapacityPlanObjective,
  CapacityPlanningComparison,
  CapacityComparisonCandidate,
  CapacityComparisonMetricKey,
  CapacityApplyRecord,
  ScenarioPreviewResult
} from '~~/types/capacity-planning'
import type { Project } from '~~/types/project'
import { boundaryAxisName, BOUNDARY_MEANING_LABELS, resolveBoundaryModuleKey, resolveBoundaryUnit } from '~~/types/boundary'

import { useCapacityPlanningApi } from '~~/composables/api/useCapacityPlanningApi'
import { useProjectApi } from '~~/composables/api/useProjectApi'
import { useToastCenter } from '~~/state/ui'
import PropertySwitch from '../../components/PropertySwitch.vue'
import PropertyNumber from '../../components/PropertyNumber.vue'
import PropertyMultiSelect from '../../components/PropertyMultiSelect.vue'
import IterationCandidatesPanel from '../../components/capacity-planning/IterationCandidatesPanel.vue'
import * as echarts from 'echarts'

definePageMeta({ title: '容量规划 - 新能源发电系统灵活性量化评估软件' })

const route = useRoute()
const projectId = computed(() => String(route.params.projectId ?? ''))
const canvasId = computed(() => String(route.query.canvasId ?? ''))
const planningApi = useCapacityPlanningApi()
const projectApi = useProjectApi()
const { push } = useToastCenter()

const schema = ref<CapacityPlanningFormSchema | null>(null)
const project = ref<Project | null>(null)
const loading = ref(true)
const validating = ref(false)
const errorMessage = ref('')
const validatedAt = ref('')
const datasetLoading = ref(false)
const datasetError = ref('')
const scenarioPreview = ref<ScenarioPreviewResult | null>(null)
const sortedScenarios = computed(() =>
  [...(scenarioPreview.value?.scenarios ?? [])].sort((a, b) => b.probability - a.probability)
)
const scenarioChartsNormalized = ref(false)
const planningTask = ref<CapacityPlanningTask | null>(null)
const planningResult = ref<CapacityPlanningResult | null>(null)
// C-403：最优方案的生命周期经济（全投资口径）展示
const lifecycleBreakdown = computed<CapacityPlanningLifecycleBreakdown>(
  () => (planningResult.value?.breakdown ?? {}) as CapacityPlanningLifecycleBreakdown
)
const lifecycleIndicators = computed(() => lifecycleBreakdown.value.indicators ?? null)
const lifecycleAvailable = computed(() => Boolean(lifecycleIndicators.value))
/** fitness 拆解：目标 + 约束惩罚（result.breakdown） */
const fitnessBreakdown = computed<Record<string, unknown>>(
  () => (planningResult.value?.breakdown ?? {}) as Record<string, unknown>
)
const technicalMetricsRows = computed(() => {
  const bd = fitnessBreakdown.value as Record<string, any>
  const tech = (bd.technicalMetrics ?? {}) as Record<string, number>
  const details = (bd.technicalConstraintDetails ?? []) as Array<Record<string, any>>
  const labels: Record<string, string> = {
    renewableConsumptionRate: '新能源消纳率',
    greenPowerShare: '绿电占比',
    purchasedPowerShare: '购电占比',
    stability: '稳定性'
  }
  return Object.entries(labels).map(([key, label]) => {
    const detail = details.find(item => item.key === key)
    return {
      key,
      label,
      value: tech[key] != null && Number.isFinite(Number(tech[key])) ? Number(tech[key]).toFixed(1) : '—',
      penalty: Number(detail?.penalty ?? 0),
      threshold: detail?.threshold ?? null,
      operator: detail?.operator ?? null
    }
  })
})

/** 仅展示真实失败类告警；口径说明/开发者备注不进 UI */
const resultErrorWarnings = computed(() => {
  const raw = (planningResult.value?.warnings ?? []) as string[]
  return raw.filter((item) => /错误|失败|异常|不可行|超时未完成|取消|failed|error/i.test(item))
})

/** 实时/完成后 fitness 拆解：优先 result.breakdown，求解中用 progress.bestBreakdown */
const liveBestBreakdown = computed(() => {
  const fromResult = planningResult.value?.breakdown as Record<string, any> | undefined
  if (fromResult && Object.keys(fromResult).length) return fromResult
  return (planningTask.value?.progress.bestBreakdown ?? null) as Record<string, any> | null
})
const liveBestFitness = computed(() => {
  if (planningResult.value?.fitness != null) return planningResult.value.fitness
  return planningTask.value?.progress.bestFitness ?? null
})
// C-405 方案比较：统一指标、基准差异、输入版本、可解释排名
const comparison = ref<CapacityPlanningComparison | null>(null)
const comparisonLoading = ref(false)
const comparisonError = ref('')
const comparisonExpandedId = ref<number | null>(null)
const loadComparison = async () => {
  if (!planningTask.value || planningTask.value.status !== 'completed') return
  if (comparison.value && comparison.value.planningId === planningTask.value.id) return
  comparisonLoading.value = true
  comparisonError.value = ''
  try {
    comparison.value = await planningApi.getPlanningComparison(planningTask.value.id)
  }
  catch (error) {
    comparisonError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    comparisonLoading.value = false
  }
}
const toggleComparisonExpand = (evaluationId: number) => {
  comparisonExpandedId.value = comparisonExpandedId.value === evaluationId ? null : evaluationId
}
/** 指标值格式化：与表格展示、CSV 导出共用，保证三处数字一致 */
const formatMetricValue = (key: CapacityComparisonMetricKey, value: number | null | undefined): string => {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—'
  if (key === 'lcoe') return value.toFixed(3)
  if (key === 'irr') return value.toFixed(2)
  if (key === 'paybackYears' || key === 'discountedPaybackYears') return value.toFixed(1)
  return value.toLocaleString('zh-CN', { maximumFractionDigits: 2 })
}
const comparisonDiff = (candidate: CapacityComparisonCandidate, key: CapacityComparisonMetricKey) =>
  candidate.metrics.diffBaseline[key]
/** 差异着色：按指标方向判断优劣（direction 来自后端 metricSources） */
const comparisonDiffTone = (candidate: CapacityComparisonCandidate, key: CapacityComparisonMetricKey) => {
  const diff = comparisonDiff(candidate, key)
  if (diff === undefined || !Number.isFinite(diff) || Math.abs(diff) < 1.0e-12) return ''
  const direction = comparison.value?.metricSources.find(item => item.key === key)?.direction ?? 'asc'
  const better = direction === 'asc' ? diff < 0 : diff > 0
  return better ? 'text-app-success' : 'text-app-danger'
}
const comparisonDiffLabel = (candidate: CapacityComparisonCandidate, key: CapacityComparisonMetricKey) => {
  const diff = comparisonDiff(candidate, key)
  if (diff === undefined || !Number.isFinite(diff) || Math.abs(diff) < 1.0e-12) return ''
  const abs = formatMetricValue(key, Math.abs(diff))
  return `${diff > 0 ? '+' : '−'}${abs}`
}
/** C-405 导出 CSV：数字与页面展示共用 formatMetricValue，来源同一 payload，保证一致 */
const exportComparisonCsv = () => {
  const data = comparison.value
  if (!data) return
  const csvEscape = (cell: string) => (/[",\n]/.test(cell) ? `"${cell.replace(/"/g, '""')}"` : cell)
  const keys = data.metricSources.map(item => item.key)
  const header = [
    '排名', '评价序号', '状态',
    ...data.metricSources.map(item => item.label),
    '失败原因'
  ]
  const lines = [header.join(',')]
  for (const candidate of data.candidates) {
    const row = [
      candidate.rank === null ? '' : String(candidate.rank),
      String(candidate.ordinal),
      candidate.feasible ? '可行' : '不可行',
      ...keys.map(key => formatMetricValue(key, candidate.metrics.values[key])),
      candidate.feasible ? '' : (candidate.failureReason ?? '')
    ]
    lines.push(row.map(csvEscape).join(','))
  }
  // 输入版本与排名规则一并写入，导出件可独立追溯
  lines.push('')
  lines.push(`目标,${data.objective}`)
  lines.push(`排名规则,${csvEscape(data.rankingRule)}`)
  lines.push(`项目快照hash,${data.inputVersion.projectSnapshotHash}`)
  lines.push(`场景集hash,${data.inputVersion.scenarioSetHash ?? ''}`)
  lines.push(`经济评价器,${data.inputVersion.economicEvaluatorVersion}`)
  lines.push(`仿真评价器,${data.inputVersion.simulationEvaluatorVersion}`)
  const blob = new Blob([`﻿${lines.join('\n')}`], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = `方案比较-${data.planningId.slice(0, 12)}.csv`
  anchor.click()
  URL.revokeObjectURL(url)
}
/** 敏感性矩阵列（与 metricSources 一致） */
const comparisonRankKeys = computed<CapacityComparisonMetricKey[]>(() =>
  (comparison.value?.metricSources ?? []).map(item => item.key)
)
/** 现金流条图最大绝对值（万元） */
const cashflowMaxAbs = (candidate: CapacityComparisonCandidate) => {
  const flows = candidate.metrics.detail.cashflowWan ?? []
  return Math.max(1, ...flows.map(value => Math.abs(value ?? 0)))
}
// C-401：变量形态徽标文案
const VALUE_KIND_LABELS: Record<CapacityVariableValueKind, string> = {
  continuous: '连续',
  integer: '整数台数',
  tier: '离散档位'
}
const valueKindLabel = (kind: CapacityVariableValueKind | undefined) =>
  kind ? (VALUE_KIND_LABELS[kind] ?? kind) : ''
// C-401 第二增量：变更方式徽标文案
const CHANGE_KIND_LABELS: Record<CapacityVariableChangeKind, string> = {
  new: '新增',
  replace: '替换',
  retire: '退役'
}
const changeKindLabel = (kind: CapacityVariableChangeKind | undefined) =>
  kind ? (CHANGE_KIND_LABELS[kind] ?? kind) : ''
const formatWanYi = (value: number | null | undefined) => {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—'
  return `${(value / 10000).toFixed(2)} 亿元`
}
/** indicators.npv 单位为元 → 亿元 */
const formatYuanYi = (value: number | null | undefined) => {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—'
  return `${(value / 100000000).toFixed(2)} 亿元`
}
const formatPercent = (value: number | null | undefined) => {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—'
  return `${(value * 100).toFixed(1)}%`
}
const formatYuanPerKwh = (value: number | null | undefined) => {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—'
  return `${value.toFixed(3)} 元/kWh`
}

const formatWanInteger = (value: number | null | undefined) => {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—'
  return `${value.toLocaleString('zh-CN', { maximumFractionDigits: 0 })} 万元`
}
const formatYears = (value: number | null | undefined) => {
  if (value === null || value === undefined || !Number.isFinite(value)) return '—'
  return `${value.toFixed(1)} 年`
}
const planningBusy = ref(false)
const planningError = ref('')
const applyResult = ref<ApplyCapacityPlanningResult | null>(null)
const applyingResult = ref(false)
// C-101：应用前预览与确认
const applyPreview = ref<ApplyCapacityPlanningPreview | null>(null)
const showApplyConfirmDialog = ref(false)
const applyPreviewLoading = ref(false)
const applyPreviewCanvasName = computed(() =>
  applyPreview.value
    ? project.value?.workspace?.canvases.find(canvas => canvas.id === applyPreview.value?.canvasId)?.name ?? applyPreview.value.canvasId
    : ''
)
// C-406：安全应用——目标画布选择、应用记录、撤销/恢复
const applyTarget = ref<'current-canvas' | 'new-canvas'>('current-canvas')
const newCanvasName = ref('')
const applyRecords = ref<CapacityApplyRecord[]>([])
const applyRecordsLoading = ref(false)
const applyActionPending = ref('')
const applyTargetCanvasName = computed(() => {
  if (!applyResult.value?.targetCanvasId) return ''
  return project.value?.workspace?.canvases.find(canvas => canvas.id === applyResult.value?.targetCanvasId)?.name
    ?? applyResult.value.targetCanvasId
})
const loadApplies = async () => {
  if (!planningTask.value) return
  applyRecordsLoading.value = true
  try {
    const result = await planningApi.listApplies(planningTask.value.id)
    applyRecords.value = result.applies ?? []
  }
  catch (error) {
    console.warn('[CapPlan] loadApplies error:', error)
    applyRecords.value = []
  }
  finally {
    applyRecordsLoading.value = false
  }
}
/** 已完成任务：从后端恢复最优结果（planning_results / result.json），并进入第 6 步 */
const restoreCompletedTaskView = async () => {
  if (!planningTask.value || planningTask.value.status !== 'completed') return
  try {
    planningResult.value = await planningApi.getPlanningResult(planningTask.value.id)
    await loadComparison()
    await loadApplies()
    currentStep.value = 6
  }
  catch (error) {
    console.warn('[CapPlan] restore completed result failed:', error)
    planningResult.value = null
  }
}
const undoApplyRecord = async (applyId: string) => {
  if (applyActionPending.value) return
  applyActionPending.value = applyId
  planningError.value = ''
  try {
    await planningApi.undoApply(applyId)
    push({ tone: 'success', title: '已撤销容量应用', description: '画布已恢复到应用前状态' })
    await loadApplies()
    project.value = (await projectApi.getProject(projectId.value)).project
  }
  catch (error) {
    planningError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    applyActionPending.value = ''
  }
}
const redoApplyRecord = async (applyId: string) => {
  if (applyActionPending.value) return
  applyActionPending.value = applyId
  planningError.value = ''
  try {
    await planningApi.redoApply(applyId)
    push({ tone: 'success', title: '已恢复容量应用', description: '画布已还原到应用后状态' })
    await loadApplies()
    project.value = (await projectApi.getProject(projectId.value)).project
  }
  catch (error) {
    planningError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    applyActionPending.value = ''
  }
}
const currentStep = ref(1)

// ───── 任务管理 ─────
const showTaskListDialog = ref(false)
const showCreateTaskDialog = ref(false)
const taskList = ref<CapacityPlanningTask[]>([])
const taskListLoading = ref(false)
const cleanupTaskId = ref<string | null>(null)
const selectedTaskId = ref<string | null>(null)

// 新建任务表单
const newTaskForm = reactive({
  name: '',
  canvasId: canvasId.value || ''
})
const creatingTask = ref(false)

// 画布选项
const canvasOptions = computed(() => {
  const canvases = project.value?.workspace?.canvases ?? []
  return canvases.map(c => ({ value: c.id, label: c.name }))
})

// 默认任务名称
const defaultTaskName = computed(() => {
  const projectName = schema.value?.projectName || project.value?.name || ''
  const canvasName = project.value?.workspace?.canvases.find(c => c.id === newTaskForm.canvasId)?.name || ''
  return [projectName, canvasName, '容量规划'].filter(Boolean).join('-')
})
const objectiveConfirmed = ref(false)
const contentScroller = ref<HTMLElement | null>(null)
const selectedBoundaryId = ref('')
const boundaryPreviewChartRef = ref<HTMLDivElement | null>(null)
// 边界时序数据缓存：projects.json 只保存边界元数据（rawData/transformedData 已被剥离），
// 实际时序数据需通过边界配置 API（/api/v1/boundary/load）从 boundary.db 按需加载
const boundarySeriesById = ref<Record<string, { values: number[]; timestamps: string[] }>>({})
const boundarySeriesLoading = ref(false)
let boundarySeriesRequested = false
const convergenceChartRef = ref<HTMLDivElement | null>(null)
const capacityChangeChartRef = ref<HTMLDivElement | null>(null)
const planningLogRef = ref<HTMLDivElement | null>(null)
let planningPollTimer: ReturnType<typeof setInterval> | null = null
let planningPollPending = false
let boundaryPreviewChart: echarts.ECharts | null = null
let convergenceChart: echarts.ECharts | null = null
let capacityChangeChart: echarts.ECharts | null = null
const scenarioChartElements = new Map<string, HTMLDivElement>()
const scenarioCharts = new Map<string, echarts.ECharts>()
type PlanningLogState = 'done' | 'active' | 'pending' | 'error'
interface PlanningLogItem {
  id: string
  title: string
  detail: string
  state: PlanningLogState
  time: string
}
const planningLogFeed = ref<PlanningLogItem[]>([])
const planningLogIds = new Set<string>()
let planningLogSequenceTimer: ReturnType<typeof setTimeout> | null = null
let lastLoggedEvaluation = 0

const clustering = reactive({
  featureIds: [] as string[],
  clusterCount: 4,
  algorithm: 'kmeans' as 'kmeans' | 'kmedoids',
  normalize: 'zscore' as 'zscore' | 'minmax' | 'none',
  missingDayThreshold: 0.05,
  seed: 20260828,
  preserveExtremes: true,
  // C-402：预览后回写场景集 hash，运行时校验边界数据是否变更
  scenarioPreviewHash: null as string | null,
  /** 生成场景时的 project.boundariesUpdatedAt */
  boundariesVersion: null as string | null
})

/** 恢复任务配置时抑制「参数变更 → 清空预览」 */
const suppressClusteringInvalidation = ref(false)

/**
 * 边界数据相对已保存场景是否已更新。
 * 只提示、不自动重聚类；引导用户到步骤三重新生成。
 */
const boundariesStale = computed(() => {
  if (!clustering.scenarioPreviewHash) return false
  const saved = clustering.boundariesVersion
  const current = project.value?.boundariesUpdatedAt
  if (!current) return false
  if (!saved) return true
  return saved !== current
})

/** 步骤三标题是否显示 ⚠ */
const showStep3Warning = computed(() =>
  Boolean(scenarioPreview.value && boundariesStale.value)
)

const optimizer = reactive({
  method: 'adaptive_de_rand_1_bin_radiuslimited' as string,
  maxFuncEvals: 100,
  populationSize: 10,
  maxTimeSeconds: 300
})

/**
 * 求解算法展示名 → BlackBoxOptim Method。
 * 后端只认 BBO 原生方法名；前端用业务向名称包装，提交时写回真实 method。
 */
const optimizerMethodOptions = [
  {
    value: 'adaptive_de_rand_1_bin_radiuslimited',
    label: '差分进化算法',
    tip: '自适应差分进化（半径受限），当前默认。适合连续容量变量的黑箱全局搜索。'
  },
  {
    value: 'dxnes',
    label: '贝叶斯优化算法',
    tip: '对应 BlackBoxOptim 的深度 xNES（无梯度自适应协方差搜索）。界面名称便于业务沟通；底层不是经典贝叶斯优化。'
  },
  {
    value: 'separable_nes',
    label: '粒子群算法',
    tip: '对应可分自然进化策略（种群式搜索）。界面名称便于业务沟通；底层不是经典 PSO。'
  },
  {
    value: 'generating_set_search',
    label: '遗传算法',
    tip: '对应生成集搜索（模式搜索）。界面名称便于业务沟通；底层不是经典 GA。'
  }
] as const

const objectiveOptions: Array<{ value: CapacityPlanObjective; label: string; tip: string }> = [
  {
    value: 'total-cost-min',
    label: '总成本最低',
    tip: '含义：把买设备、交税、运维、购电等全部花钱折到今天比总账。\n用法：希望全生命周期花得最少，不单独看收益时选它。'
  },
  {
    value: 'operating-cost-min',
    label: '运行成本最低',
    tip: '含义：只比日常开销——购电、燃料、运维、弃电惩罚，不含买设备的钱。\n用法：容量已大致定好，主要想压低每年电费/燃料费时选它。'
  },
  {
    value: 'initial-investment-min',
    label: '初始投资最低',
    tip: '含义：只比一开始要掏出的设备投资和建设税。\n用法：建设预算紧、想先少花钱上项目时选它（可能牺牲后期运行经济性）。'
  },
  {
    value: 'npv-max',
    label: '净现值最高',
    tip: '含义：项目赚不赚钱——把历年净现金流按折现率折回今天求和。\n用法：要论证项目是否创造价值、做投资决策排序时选它。'
  },
  {
    value: 'lcoe-min',
    label: 'LCOE 最低',
    tip: '含义：发一度电平均花多少钱（元/kWh），便于和电价对比。\n用法：比较不同技术路线的度电成本、或与售电电价对标时选它。'
  },
  {
    value: 'payback-period-min',
    label: '回收期最短',
    tip: '含义：多少年能把投进去的钱赚回来（折现口径）。\n用法：最关心回本速度、贷款/资金压力大时选它。'
  },
  {
    value: 'irr-max',
    label: '内部收益率最高',
    tip: '含义：项目自身收益率（使净现值为 0 的利率），越高越赚钱。\n用法：要满足股东/银行收益率要求、与融资成本对标时选它。'
  }
]
const objectiveSettings = reactive<CapacityEconomicsConfig>({
  evaluator: 'timeseries-operating-cost-v1',
  currency: 'CNY',
  schemaVersion: 'capacity-objective-config-v2',
  objective: 'operating-cost-min',
  technicalConstraints: {
    renewableConsumptionRate: { enabled: false, operator: 'gte', threshold: 90, unit: '%' },
    greenPowerShare: { enabled: false, operator: 'gte', threshold: 50, unit: '%' },
    purchasedPowerShare: { enabled: false, operator: 'lte', threshold: 30, unit: '%' },
    stability: { enabled: false, operator: 'gte', threshold: 95, unit: '%' }
  },
  // 经济性参数始终生效（无勾选）；targetIrrPercent 为默认最低收益率约束
  economicConstraints: {
    lifecycleYears: { enabled: true, operator: 'gte', threshold: 20, unit: '年' },
    interestRatePercent: { enabled: true, operator: 'lte', threshold: 8, unit: '%' },
    taxRatePercent: { enabled: true, operator: 'lte', threshold: 25, unit: '%' },
    targetIrrPercent: { enabled: true, operator: 'gte', threshold: 8, unit: '%' }
  },
  lifecycle: {
    tax_holiday_years: 3,
    tax_half_years: 3,
    income_tax_rate: 0.25,
    output_vat_rate: 13,
    input_vat_rate: 13,
    construction_vat_rate: 10,
    surcharge_rate: 12,
    working_capital_rate: 30,
    salvage_rate_default: 5,
    staff_salary_wan: 15,
    fixed_om_ratio: 0,
    fixed_om_wan: 0,
    subsidy_yuan_per_kwh: 0,
    capacity_compensation_yuan_per_kw_year: 0,
    replace_cycle_years: 0,
    irr_penalty_weight: 1
  },
  extensions: {}
})

const selectedObjectiveLabel = computed(() =>
  objectiveOptions.find(option => option.value === objectiveSettings.objective)?.label ?? '—'
)

/** Step5 当前最优摘要行：目标 + 四项技术指标惩罚 + 总适应度 */
const liveBestSummaryRows = computed(() => {
  const bd = liveBestBreakdown.value
  const fitness = liveBestFitness.value
  if (!bd || fitness == null) return null
  const objective = Number(bd.objectiveFitness ?? bd.weightedOperatingCost ?? 0)
  const tech = (bd.technicalMetrics ?? {}) as Record<string, number>
  const details = (bd.technicalConstraintDetails ?? []) as Array<Record<string, any>>
  const labels: Record<string, string> = {
    renewableConsumptionRate: '新能源消纳率',
    greenPowerShare: '绿电占比',
    purchasedPowerShare: '购电占比',
    stability: '稳定性'
  }
  const techRows = Object.entries(labels).map(([key, label]) => {
    const detail = details.find(item => item.key === key)
    const value = tech[key]
    return {
      key,
      label,
      valueText: value != null && Number.isFinite(Number(value)) ? `${Number(value).toFixed(1)}%` : '—',
      penalty: Number(detail?.penalty ?? 0)
    }
  })
  return {
    objectiveLabel: selectedObjectiveLabel.value,
    objective,
    techRows,
    constraintPenalty: Number(bd.constraintPenalty ?? 0),
    technicalConstraintPenalty: Number(bd.technicalConstraintPenalty ?? 0),
    fitness: Number(fitness)
  }
})

const technicalConstraintItems = computed(() => [
  {
    key: 'renewableConsumptionRate' as const,
    label: '新能源消纳率',
    hint: '不低于',
    tip: '已调度风光电量 / 可发风光电量 ×100%。无风光时记 100%。未达标按软惩罚计入 fitness。'
  },
  {
    key: 'greenPowerShare' as const,
    label: '绿电占比',
    hint: '不低于',
    tip: '(风光 + 水电) / 总供电量 ×100%；总供电 = 绿电 + 常规 + 购电。未达标按软惩罚计入 fitness。'
  },
  {
    key: 'purchasedPowerShare' as const,
    label: '购电占比',
    hint: '不高于',
    tip: '购电量 / 总供电量 ×100%（与绿电占比同分母）。未达标按软惩罚计入 fitness。'
  },
  {
    key: 'stability' as const,
    label: '稳定性',
    hint: '不低于',
    tip: '供需达标率 = (1 − 不稳定时段数/总时段数) ×100%。未达标按软惩罚计入 fitness。'
  }
])

/** 经济性参数：始终生效，仅录入数值（无启用勾选） */
const economicCoreItems = computed(() => [
  {
    key: 'lifecycleYears' as const,
    label: '运营期',
    suffix: '年',
    min: 1,
    max: 100,
    step: 1,
    hint: '生命周期评价年限',
    tip: '现金流评价年数 n。影响 NPV/IRR/LCOE/回收期的折现区间与设备重置次数。'
  },
  {
    key: 'interestRatePercent' as const,
    label: '折现率',
    suffix: '%',
    min: 0,
    max: 100,
    step: 0.1,
    hint: 'NPV/折现回收期/LCOE',
    tip: '基准收益率 r，用于 NPV=Σcfₜ/(1+r)ᵗ、折现回收期与 LCOE 分母折现电量。'
  },
  {
    key: 'taxRatePercent' as const,
    label: '所得税率',
    suffix: '%',
    min: 0,
    max: 100,
    step: 0.1,
    hint: '企业所得税',
    tip: '调整所得税 = max(0, EBIT)×有效税率；前免税年为 0，减半段×0.5，之后全额。'
  },
  {
    key: 'targetIrrPercent' as const,
    label: '最低内部收益率',
    suffix: '%',
    min: 0,
    max: 100,
    step: 0.1,
    hint: '默认约束：IRR 低于阈值计入惩罚',
    tip: '经济约束：税后 IRR 低于该阈值时，按 IRR惩罚权重×差额×CAPEX 计入 fitness 惩罚。'
  }
])

type LifecycleFieldKey = keyof CapacityLifecycleParams

const lifecycleParamGroups = computed(() => [
  {
    title: '税收参数',
    hint: '价税分离与三免三减半，影响 NPV/IRR',
    items: [
      { key: 'tax_holiday_years' as LifecycleFieldKey, label: '免税年数', suffix: '年', min: 0, max: 20, step: 1, tip: '运营前 N 年所得税税率为 0（三免）。' },
      { key: 'tax_half_years' as LifecycleFieldKey, label: '减半年数', suffix: '年', min: 0, max: 20, step: 1, tip: '免税期之后 M 年按所得税率减半征收（三减半）。' },
      { key: 'output_vat_rate' as LifecycleFieldKey, label: '销项增值税率', suffix: '%', min: 0, max: 30, step: 0.1, tip: '收入价税分离：不含税收入 = 含税收入/(1+销项税率)。' },
      { key: 'input_vat_rate' as LifecycleFieldKey, label: '进项增值税率', suffix: '%', min: 0, max: 30, step: 0.1, tip: '经营成本可抵扣进项税 = 成本×进项税率；影响应缴增值税。' },
      { key: 'construction_vat_rate' as LifecycleFieldKey, label: '建设增值税率', suffix: '%', min: 0, max: 30, step: 0.1, tip: '建设投资增值税 = CAPEX×税率；计入初始投资与留抵税额。' },
      { key: 'surcharge_rate' as LifecycleFieldKey, label: '附加税率', suffix: '%', min: 0, max: 30, step: 0.1, tip: '营业税金及附加 = 应缴增值税×附加税率（城建+教育费附加）。' }
    ]
  },
  {
    title: '投资与运维',
    hint: '流动资金、残值、固定运维与收益补贴',
    items: [
      { key: 'working_capital_rate' as LifecycleFieldKey, label: '流动资金率', suffix: '元/容量单位', min: 0, max: 1000, step: 1, tip: '流动资金 = Σ(容量×费率)；第 0 年投入，末年回收。' },
      { key: 'salvage_rate_default' as LifecycleFieldKey, label: '默认残值率', suffix: '%', min: 0, max: 50, step: 0.1, tip: '设备残值 = CAPEX×残值率；末年回收，替换/退役时作处置回收。' },
      { key: 'staff_salary_wan' as LifecycleFieldKey, label: '人员年薪', suffix: '万元', min: 0, max: 100, step: 0.5, tip: '按人员数量计年薪酬，并入年经营成本。' },
      { key: 'fixed_om_ratio' as LifecycleFieldKey, label: '固定运维比例', suffix: '%/年', min: 0, max: 20, step: 0.1, tip: '固定运维 = CAPEX×比例/年 + 定额，计入经营成本。' },
      { key: 'fixed_om_wan' as LifecycleFieldKey, label: '固定运维定额', suffix: '万元/年', min: 0, max: 100000, step: 1, tip: '与比例项相加的固定年运维费用（万元/年）。' },
      { key: 'subsidy_yuan_per_kwh' as LifecycleFieldKey, label: '电量补贴', suffix: '元/kWh', min: 0, max: 10, step: 0.001, tip: '年补贴 = 年上网电量×补贴单价，计入含税收益。' },
      { key: 'capacity_compensation_yuan_per_kw_year' as LifecycleFieldKey, label: '容量补偿', suffix: '元/kW·年', min: 0, max: 10000, step: 1, tip: '按 kW 口径装机容量计年补偿；kWh/kg 类设备不计入。' },
      { key: 'replace_cycle_years' as LifecycleFieldKey, label: '替换周期', suffix: '年', min: 0, max: 50, step: 1, hint: '0=按折旧年限', tip: '设备重置年份；0 表示按折旧年限整数倍重购（计入运营期流出）。' },
      { key: 'irr_penalty_weight' as LifecycleFieldKey, label: 'IRR 惩罚权重', suffix: '', min: 0, max: 100, step: 0.1, tip: 'IRR 低于阈值时惩罚系数：权重×(阈值−实际IRR)×CAPEX，换算进 fitness。' }
    ]
  }
])

/**
 * 税率/比例字段：表单按百分数展示（10 表示 10%），后端与配置存储用小数（0.10）。
 * 后端 lifecycle_params_from_config 也会做同样归一；此处保证写出的 config 口径一致。
 * working_capital_rate（元/容量单位）、staff_salary_wan、年限、权重等不在此列。
 */
const PERCENT_LIFECYCLE_KEYS = [
  'output_vat_rate',
  'input_vat_rate',
  'construction_vat_rate',
  'surcharge_rate',
  'salvage_rate_default',
  'fixed_om_ratio',
  'income_tax_rate',
  'discount_rate'
] as const

const isPercentLifecycleKey = (key: string): boolean =>
  (PERCENT_LIFECYCLE_KEYS as readonly string[]).includes(key)

/** 表单百分数 → 配置/后端小数（10 → 0.10；1 → 0.01；已是小数则原样） */
const lifecycleRateToDecimal = (key: string, value: number): number =>
  isPercentLifecycleKey(key) && value >= 1 ? value / 100 : value

/** 配置/后端小数 → 表单百分数（0.10 → 10；0.01 → 1；历史百分数写法则原样） */
const lifecycleRateToPercent = (key: string, value: number): number =>
  isPercentLifecycleKey(key) && value < 1 ? value * 100 : value

const capacityEconomicsPayload = (): CapacityEconomicsConfig => {
  const payload = JSON.parse(JSON.stringify(objectiveSettings)) as CapacityEconomicsConfig
  // 参数始终生效，避免旧任务里的 enabled:false 写回后端被当关闭
  for (const item of economicCoreItems.value) {
    payload.economicConstraints[item.key].enabled = true
  }
  // 税率/比例统一写成小数，避免建设增值税/残值率等被当成整数倍
  for (const [key, value] of Object.entries(payload.lifecycle ?? {})) {
    if (typeof value === 'number' && Number.isFinite(value)) {
      ;(payload.lifecycle as Record<string, number>)[key] = lifecycleRateToDecimal(key, value)
    }
  }
  return payload
}

const planningSteps = [
  { id: 1, title: '容量变量配置', description: '确定参与规划的设备与容量范围' },
  { id: 2, title: '历史边界数据', description: '核对边界配置并预览时序数据' },
  { id: 3, title: '典型场景聚类', description: '配置聚类参数并预览代表性场景' },
  { id: 4, title: '规划目标设置', description: '配置方案目标、技术性约束和经济性参数' },
  { id: 5, title: '求解过程设置', description: '设置算法参数并观察求解过程' },
  { id: 6, title: '容量配置方案', description: '比较优化前后容量并应用最优方案' }
] as const

const variables = computed(() => schema.value?.variables ?? [])
const optimizedCount = computed(() => variables.value.filter(item => item.mode === 'optimize').length)
const fixedCount = computed(() => variables.value.length - optimizedCount.value)
const allOptimized = computed(() => variables.value.length > 0 && variables.value.every(item => item.mode === 'optimize'))
const toggleAllParticipation = () => {
  const target = allOptimized.value ? 'fixed' : 'optimize'
  for (const item of variables.value) {
    item.mode = target
    if (target === 'fixed') item.fixedValue = item.currentValue
  }
  validatedAt.value = ''
}
const handleSuggestedValueChange = (item: CapacityVariableDraft, value: number) => {
  item.suggestedValue = value
  validatedAt.value = ''
}
const handleBoundChange = (item: CapacityVariableDraft, field: 'lowerBound' | 'upperBound', value: number) => {
  const input = { value: String(value) } as unknown as EventTarget & { value: string }
  updateCapacityBound(item, field, { target: input } as unknown as Event)
}
const configuredBoundaries = computed(() => project.value?.boundaries ?? [])
// 当前画布节点引用的 boundaryId 并集（C-101/BUG-003）：聚类特征候选只允许取该集合内的边界，
// 防止同项目其他画布的边界混入典型场景。
const canvasBoundaryIds = computed(() => new Set(
  (project.value?.workspace.canvases.find(canvas => canvas.id === canvasId.value)?.nodes ?? [])
    .flatMap(node => node.data?.business.boundaryIds ?? [])
))
const canvasBoundaries = computed(() =>
  configuredBoundaries.value.filter(item => canvasBoundaryIds.value.has(item.id))
)
// Step2 历史边界数据：仅展示与组件已关联的边界，并排除 AGC 等调度目标类曲线
const isAgcBoundary = (boundary: Project['boundaries'][number]) =>
  resolveBoundaryModuleKey(boundary) === 'agc'
const isLinkedToComponent = (boundary: Project['boundaries'][number]) =>
  (boundary.relatedComponents?.length ?? 0) > 0 || canvasBoundaryIds.value.has(boundary.id)
const planningBoundaries = computed(() =>
  configuredBoundaries.value.filter(item => !isAgcBoundary(item) && isLinkedToComponent(item))
)
const canvasNodeNameById = computed(() => new Map(
  (project.value?.workspace.canvases.find(canvas => canvas.id === canvasId.value)?.nodes ?? [])
    .map(node => [node.id, node.data?.label || node.id])
))
const selectedBoundary = computed(() =>
  planningBoundaries.value.find(boundary => boundary.id === selectedBoundaryId.value) ?? null
)
// 聚类特征：按已关联边界逐项多选（不再枚举 C(n,2)+n 组合）
const clusteringFeatureOptions = computed(() =>
  planningBoundaries.value.map((item) => ({
    value: item.id,
    label: item.name || boundaryMeaningLabel(item.meaning) || item.meaning
  }))
)

/** 图例/展示用中文名 */
const featureDisplayName = (featureId: string) => {
  const boundary = planningBoundaries.value.find(item => item.id === featureId)
  if (boundary) return boundary.name || boundaryMeaningLabel(boundary.meaning) || boundary.meaning
  return featureId
}

/** day-N → 日历日期 */
const formatScenarioDayLabel = (dayLabel: string | null | undefined) => {
  if (!dayLabel) return '—'
  const match = /^(day-)?(\d+)$/.exec(String(dayLabel).trim())
  if (!match) return String(dayLabel)
  // 支持 day-N 与纯序号
  const dayIndex = Number(match[2])
  if (!Number.isFinite(dayIndex) || dayIndex < 1) return String(dayLabel)
  const startRaw = (scenarioPreview.value?.dataset as { startAt?: string } | undefined)?.startAt
    || planningBoundaries.value.find(item => item.boundaryMeta?.calendarStartDate)?.boundaryMeta?.calendarStartDate
    || planningBoundaries.value.find(item => item.rawData?.timestamps?.length)?.rawData?.timestamps?.[0]
    || Object.values(boundarySeriesById.value).find(series => series.timestamps?.length)?.timestamps?.[0]
  if (!startRaw) return String(dayLabel)
  const base = new Date(startRaw)
  if (Number.isNaN(base.getTime())) return String(dayLabel)
  const target = new Date(base.getTime())
  target.setDate(target.getDate() + dayIndex - 1)
  const year = target.getFullYear()
  const month = String(target.getMonth() + 1).padStart(2, '0')
  const day = String(target.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}


/** 至少选一项，可全选 */
const clusteringFeatureIdsModel = computed({
  get: () => clustering.featureIds,
  set: (value: string[]) => {
    if (!value.length) {
      push({
        tone: 'warning',
        title: '至少选择一个聚类特征',
        description: '可全选，但不能清空'
      })
      return
    }
    clustering.featureIds = [...value]
  }
})

// 首次可用时默认全选特征；已选特征失效时裁剪并提示（不静默全选替换）
watch(clusteringFeatureOptions, (options) => {
  if (suppressClusteringInvalidation.value) return
  if (!options.length) return
  const validIds = new Set(options.map(item => item.value))
  const kept = clustering.featureIds.filter(id => validIds.has(id))
  if (kept.length === clustering.featureIds.length && kept.length > 0) return

  const droppedCount = clustering.featureIds.length - kept.length
  suppressClusteringInvalidation.value = true
  try {
    if (kept.length > 0) {
      clustering.featureIds = kept
    }
    else if (clustering.featureIds.length > 0) {
      // 全部失效：不静默改成全选，保留空列表让用户选
      clustering.featureIds = []
    }
    else {
      clustering.featureIds = options.map(item => item.value)
    }
  }
  finally {
    suppressClusteringInvalidation.value = false
  }

  if (droppedCount > 0) {
    push({
      tone: 'warning',
      title: `已移除 ${droppedCount} 个不可用聚类特征`,
      description: '特征对应边界已失效或不可用，请重新选择后生成典型场景（非边界数据变更）'
    })
  }
}, { immediate: true })
const selectedBoundaryPreviewData = computed(() => {
  const boundary = selectedBoundary.value
  if (!boundary) return null
  // 优先使用中文标签+单位，与边界配置页保持一致
  const yAxisLabel = boundaryAxisName(
    boundary.meaning || 'load',
    (boundary as { unit?: string }).unit
  ) || boundary.rawData?.yAxisLabel
    || ''
  if (boundary.rawData?.values.length) {
    return {
      values: boundary.rawData.values,
      timestamps: boundary.rawData.timestamps,
      xAxisLabel: boundary.rawData.xAxisLabel || '时间',
      yAxisLabel
    }
  }

  const firstLayer = boundary.transformedData?.layers[0]
  if (firstLayer?.values.length) {
    return {
      values: firstLayer.values,
      timestamps: firstLayer.timestamps,
      xAxisLabel: '时间',
      yAxisLabel
    }
  }

  // 最后回退到通过边界配置 API 加载的时序数据
  const loadedSeries = boundarySeriesById.value[boundary.id]
  if (loadedSeries?.values.length) {
    return {
      values: loadedSeries.values,
      timestamps: loadedSeries.timestamps,
      xAxisLabel: '时间',
      yAxisLabel
    }
  }
  return null
})

// 边界预览图表标题
const boundaryPreviewChartTitle = computed(() => {
  const boundary = selectedBoundary.value
  const data = selectedBoundaryPreviewData.value
  if (!boundary || !data) return ''
  const pointCount = data.values.length
  const days = boundaryDayCount(boundary)
  const stats = selectedBoundaryStats.value
  const unit = boundaryUnit(boundary)
  const statsText = stats
    ? `    点数 ${stats.count} ｜ 最小值 ${stats.min.toFixed(4)} ｜ 最大值 ${stats.max.toFixed(4)} ｜ 平均值 ${stats.mean.toFixed(4)} ${unit === '—' ? '' : unit}`
    : ''
  return `时间尺度 ${boundary.timeStep || '1h'} ｜ ${pointCount} 点（${days} 天）${statsText}`
})
const activeStep = computed(() => planningSteps.find(item => item.id === currentStep.value) ?? planningSteps[0])

const boundaryPointCount = (boundary: Project['boundaries'][number]) =>
  boundary.rawData?.values.length
  ?? boundary.transformedData?.layers[0]?.values.length
  ?? boundarySeriesById.value[boundary.id]?.values.length
  ?? 0

const parseTimeStepHours = (timeStep: string | undefined) => {
  const match = /^(\d+)(h|m)$/.exec((timeStep || '1h').trim())
  if (!match) return 1
  const value = Number(match[1])
  return match[2] === 'h' ? value : value / 60
}

/** 边界时长（天）：优先 boundaryMeta.dayCount，否则按点数×步长估算 */
const boundaryDayCount = (boundary: Project['boundaries'][number]) => {
  const metaDays = boundary.boundaryMeta?.dayCount
  if (typeof metaDays === 'number' && Number.isFinite(metaDays) && metaDays > 0) return metaDays
  const points = boundaryPointCount(boundary)
  if (!points) return 0
  return Math.max(1, Math.round((points * parseTimeStepHours(boundary.timeStep)) / 24))
}

const boundaryUnit = (boundary: Project['boundaries'][number]) =>
  resolveBoundaryUnit(boundary) || '—'

const formatBoundaryDay = (value: string | undefined) => {
  if (!value) return ''
  // 兼容 ISO 与 YYYY-MM-DD
  const day = value.slice(0, 10)
  return /^\d{4}-\d{2}-\d{2}$/.test(day) ? day : value
}

/** 起止日期：优先 meta 日历，其次时序首尾时间戳 */
const boundaryDateRange = (boundary: Project['boundaries'][number]) => {
  const meta = boundary.boundaryMeta
  const start = formatBoundaryDay(meta?.calendarStartDate)
    || formatBoundaryDay(boundary.rawData?.timestamps[0])
    || formatBoundaryDay(boundary.transformedData?.layers[0]?.timestamps[0])
    || formatBoundaryDay(boundarySeriesById.value[boundary.id]?.timestamps[0])
  const end = formatBoundaryDay(meta?.calendarEndDate)
    || formatBoundaryDay(boundary.rawData?.timestamps[boundary.rawData.timestamps.length - 1])
    || formatBoundaryDay(boundary.transformedData?.layers[0]?.timestamps.at(-1))
    || formatBoundaryDay(boundarySeriesById.value[boundary.id]?.timestamps.at(-1))
  if (start && end) return `${start} ~ ${end}`
  return start || end || '—'
}

const allPlanningBoundariesHaveData = computed(() =>
  planningBoundaries.value.length > 0
  && planningBoundaries.value.every(item => boundaryPointCount(item) > 0)
)
const missingBoundaryDataCount = computed(() =>
  planningBoundaries.value.filter(item => boundaryPointCount(item) === 0).length
)

/** 预览序列摘要，便于对数 */
const selectedBoundaryStats = computed(() => {
  const data = selectedBoundaryPreviewData.value
  if (!data?.values?.length) return null
  let min = Number.POSITIVE_INFINITY
  let max = Number.NEGATIVE_INFINITY
  let sum = 0
  let count = 0
  for (const raw of data.values) {
    const v = Number(raw)
    if (!Number.isFinite(v)) continue
    if (v < min) min = v
    if (v > max) max = v
    sum += v
    count += 1
  }
  if (!count) return null
  return {
    min,
    max,
    mean: sum / count,
    count
  }
})

const goBoundaryConfig = () => {
  const query = selectedBoundaryId.value
    ? `?boundaryId=${encodeURIComponent(selectedBoundaryId.value)}`
    : ''
  navigateTo(`/boundary/${projectId.value}${query}`)
}

/** 将 "H:MM" 仿真时刻或 ISO 日期折算成日历日标签 */
const formatAxisDateLabel = (raw: string | undefined, startDate?: string) => {
  if (!raw) return ''
  if (/^\d{4}-\d{2}-\d{2}/.test(raw)) return raw.slice(0, 10)
  const match = /^(\d+):(\d{1,2})(?::\d{1,2})?$/.exec(raw.trim())
  if (!match) return raw
  const hours = Number(match[1]) + Number(match[2]) / 60
  const base = new Date(`${(startDate || '2026-01-01').slice(0, 10)}T00:00:00`)
  const d = new Date(base.getTime() + hours * 3600_000)
  const mm = String(d.getMonth() + 1).padStart(2, '0')
  const dd = String(d.getDate()).padStart(2, '0')
  return `${d.getFullYear()}-${mm}-${dd}`
}

const boundaryAxisDates = computed(() => {
  const data = selectedBoundaryPreviewData.value
  if (!data?.timestamps?.length) return []
  const startDate = selectedBoundary.value?.boundaryMeta?.calendarStartDate
  return data.timestamps.map(ts => formatAxisDateLabel(ts, startDate))
})

function boundaryMeaningLabel(meaning: string) {
  return BOUNDARY_MEANING_LABELS[meaning as keyof typeof BOUNDARY_MEANING_LABELS] || meaning
}

const boundaryRelatedDeviceNames = (boundary: Project['boundaries'][number]) => {
  const names = boundary.relatedComponents
    .map(componentId => canvasNodeNameById.value.get(componentId))
    .filter((name): name is string => Boolean(name))
  return names.length ? names.join('、') : '—'
}

const renderBoundaryPreview = () => {
  if (!boundaryPreviewChartRef.value || !selectedBoundaryPreviewData.value || !selectedBoundary.value) return
  boundaryPreviewChart?.dispose()
  boundaryPreviewChart = echarts.init(boundaryPreviewChartRef.value)
  boundaryPreviewChart.setOption({
    title: {
      text: boundaryPreviewChartTitle.value,
      textStyle: { fontSize: 13, fontWeight: 'normal' },
      left: 'center',
      top: 5,
      textOverflow: 'break',
      width: '92%'
    },
    tooltip: {
      trigger: 'axis',
      valueFormatter: (value) => (typeof value === 'number' ? value.toFixed(4) : String(value ?? '')),
      formatter: (params: unknown) => {
        const list = Array.isArray(params) ? params : [params]
        const first = list[0] as { dataIndex?: number; value?: number | string; axisValue?: string } | undefined
        const idx = first?.dataIndex ?? 0
        const label = boundaryAxisDates.value[idx] || String(first?.axisValue ?? '')
        const rows = list.map((item) => {
          const p = item as { seriesName?: string; value?: number | string; marker?: string }
          const v = Number(p.value)
          return `${p.marker ?? ''}${p.seriesName ?? ''}: ${Number.isFinite(v) ? v.toFixed(4) : String(p.value ?? '')}`
        })
        return [label, ...rows].join('<br/>')
      }
    },
    grid: {
      left: '3%',
      right: '3%',
      top: 48,
      bottom: 56,
      containLabel: true
    },
    dataZoom: [
      { type: 'inside', start: 0, end: 100 },
      { type: 'slider', start: 0, end: 100, height: 18, bottom: 12 }
    ],
    xAxis: {
      type: 'category',
      data: boundaryAxisDates.value,
      name: '日期',
      nameLocation: 'middle',
      nameGap: 30,
      axisLabel: {
        hideOverlap: true,
        formatter: (value: string) => value
      },
      axisTick: { alignWithLabel: true }
    },
    yAxis: {
      type: 'value',
      name: selectedBoundaryPreviewData.value.yAxisLabel,
      nameLocation: 'middle',
      nameGap: 40
    },
    series: [{
      name: selectedBoundary.value.name,
      data: selectedBoundaryPreviewData.value.values,
      type: 'line',
      smooth: false,
      symbol: 'none',
      lineStyle: { width: 2 },
      itemStyle: { color: '#165DFF' }
    }]
  })
  boundaryPreviewChart.resize()
  // flex 布局落定后再校正一次高度，避免初始化时容器尚未拉伸
  requestAnimationFrame(() => boundaryPreviewChart?.resize())
}

const resetBoundaryZoom = () => {
  boundaryPreviewChart?.dispatchAction({ type: 'dataZoom', start: 0, end: 100 })
}

const previewBoundary = async (boundary: Project['boundaries'][number]) => {
  selectedBoundaryId.value = boundary.id
  await nextTick()
  renderBoundaryPreview()
}

/** 默认预览第一条可展示的边界（Step2 进入或数据就绪时） */
const ensureDefaultBoundaryPreview = async () => {
  const list = planningBoundaries.value
  if (!list.length) {
    selectedBoundaryId.value = ''
    return
  }
  const current = list.find(item => item.id === selectedBoundaryId.value)
  if (current && boundaryPointCount(current)) {
    await nextTick()
    renderBoundaryPreview()
    return
  }
  const firstWithData = list.find(item => boundaryPointCount(item) > 0) ?? list[0]
  if (!firstWithData) return
  selectedBoundaryId.value = firstWithData.id
  await nextTick()
  renderBoundaryPreview()
}

// 通过边界配置 API 从 TS 库（boundary.db）加载已保存的边界时序数据
const loadBoundarySeries = async () => {
  const boundaries = planningBoundaries.value
  if (!projectId.value || !boundaries.length || boundarySeriesRequested) return
  boundarySeriesRequested = true
  boundarySeriesLoading.value = true
  try {
    await Promise.all(boundaries.map(async (boundary) => {
      try {
        const response = await $fetch<{
          success: boolean
          data?: {
            allFound: boolean
            boundaries: { layerId: string; found: boolean; values?: number[]; timestamps?: string[] }[]
          }
        }>('/api/v1/boundary/load', {
          method: 'POST',
          body: {
            projectId: projectId.value,
            boundaries: [{ layerId: '1', meaning: boundary.meaning, boundaryId: boundary.id }]
          }
        })
        const stored = response.data?.boundaries?.find(item => item.found)
        if (stored?.values?.length) {
          boundarySeriesById.value = {
            ...boundarySeriesById.value,
            [boundary.id]: { values: stored.values, timestamps: stored.timestamps ?? [] }
          }
        }
      }
      catch (error) {
        console.warn(`[CapPlan] 边界「${boundary.name}」时序数据加载失败:`, error)
      }
    }))
  }
  finally {
    boundarySeriesLoading.value = false
    if (currentStep.value === 2) {
      await ensureDefaultBoundaryPreview()
    }
  }
}

// 让下拉选中项与 clustering.featureIds 保持同步：
// 优先保留当前选中项；否则按任务已保存的 featureIds 匹配；最后回退到第一个可用特征
const disposeScenarioCharts = () => {
  scenarioCharts.forEach(chart => chart.dispose())
  scenarioCharts.clear()
}

const setScenarioChartRef = (scenarioId: string, element: unknown) => {
  if (element instanceof HTMLDivElement) {
    scenarioChartElements.set(scenarioId, element)
    return
  }
  scenarioChartElements.delete(scenarioId)
  scenarioCharts.get(scenarioId)?.dispose()
  scenarioCharts.delete(scenarioId)
}

const normalizeScenarioValues = (values: number[]) => {
  const finiteValues = values.filter(Number.isFinite)
  if (!finiteValues.length) return values

  const min = Math.min(...finiteValues)
  const max = Math.max(...finiteValues)
  const range = max - min
  if (range === 0) return values.map(value => Number.isFinite(value) ? 0.5 : value)
  return values.map(value => Number.isFinite(value) ? (value - min) / range : value)
}

const toggleScenarioNormalization = async () => {
  scenarioChartsNormalized.value = !scenarioChartsNormalized.value
  await nextTick()
  renderScenarioCharts()
}

const renderScenarioCharts = () => {
  disposeScenarioCharts()
  const preview = scenarioPreview.value
  if (!preview || currentStep.value !== 3) return

  const metadata = new Map(preview.dataset.series.map(item => [item.boundaryId, item]))
  const resolutionMinutes = preview.config.resolutionMinutes
  sortedScenarios.value.forEach((scenario, scenarioIndex) => {
    const element = scenarioChartElements.get(scenario.scenarioId)
    if (!element) return

    const entries = Object.entries(scenario.series)
    const pointCount = Math.max(0, ...entries.map(([, values]) => values.length))
    const timeLabels = Array.from({ length: pointCount }, (_, index) => {
      const totalMinutes = index * resolutionMinutes
      const hour = Math.floor(totalMinutes / 60).toString().padStart(2, '0')
      const minute = (totalMinutes % 60).toString().padStart(2, '0')
      return `${hour}:${minute}`
    })
    const units = [...new Set(entries.map(([featureId]) => metadata.get(featureId)?.unit || '数值'))]
    const normalized = scenarioChartsNormalized.value
    const chart = echarts.init(element)
    chart.setOption({
      animation: false,
      color: ['#165DFF', '#F59E0B', '#14B8A6', '#8B5CF6', '#EF4444'],
      tooltip: {
        trigger: 'axis',
        valueFormatter: normalized
          ? (value: unknown) => Number.isFinite(Number(value)) ? Number(value).toFixed(3) : String(value)
          : undefined
      },
      legend: {
        type: 'scroll',
        top: 0,
        left: 'center'
      },
      grid: {
        left: 16,
        right: units.length > 1 ? 70 : 24,
        top: 46,
        bottom: 30,
        containLabel: true
      },
      xAxis: {
        type: 'category',
        boundaryGap: false,
        data: timeLabels,
        axisLabel: { hideOverlap: true }
      },
      yAxis: normalized
          ? [{
            type: 'value',
            min: 0,
            max: 1,
            axisLabel: { formatter: (value: number) => value.toFixed(1) },
            splitLine: { show: true }
          }]
        : units.map((unit, index) => ({
            type: 'value',
            name: unit,
            position: index === 0 ? 'left' : 'right',
            offset: index > 1 ? (index - 1) * 54 : 0,
            splitLine: { show: index === 0 }
          })),
      series: entries.map(([featureId, values]) => {
        const seriesMetadata = metadata.get(featureId)
        const unit = seriesMetadata?.unit || '数值'
        return {
          name: featureDisplayName(featureId),
          data: normalized ? normalizeScenarioValues(values) : values,
          type: 'line',
          smooth: false,
          showSymbol: false,
          yAxisIndex: normalized ? 0 : Math.max(0, units.indexOf(unit)),
          lineStyle: { width: 2 }
        }
      }),
      aria: {
        enabled: true,
        description: `典型场景 ${scenarioIndex + 1} 的边界数据折线图`
      }
    })
    scenarioCharts.set(scenario.scenarioId, chart)
  })
}

const selectStep = (stepId: number) => {
  currentStep.value = Math.min(6, Math.max(1, stepId))
}

const confirmBoundaryData = async () => {
  if (planningBoundaries.value.length === 0) {
    push({
      tone: 'warning',
      title: '尚无可用的边界数据',
      description: '请先在边界配置中完善并保存历史边界数据。'
    })
    return
  }
  if (!allPlanningBoundariesHaveData.value) {
    push({
      tone: 'warning',
      title: '边界时序数据不完整',
      description: `还有 ${missingBoundaryDataCount.value} 条边界缺少数据，请返回边界配置补齐`
    })
    return
  }

  // 如果有选中的任务，更新任务的聚类配置
  if (selectedTaskId.value) {
    try {
      await planningApi.updatePlanningConfig(selectedTaskId.value, {
        clustering: clusteringConfigPayload()
      })
    }
    catch (error) {
      console.warn('[CapPlan] Failed to update clustering config:', error)
    }
  }

  currentStep.value = 3
}

const confirmTypicalScenarios = () => {
  if (!scenarioPreview.value) {
    push({ tone: 'warning', title: '请先生成并预览典型场景' })
    return
  }
  if (boundariesStale.value) {
    push({
      tone: 'warning',
      title: '典型场景可能已过期',
      description: '边界数据已更新，建议先重新生成聚类结果'
    })
  }
  currentStep.value = 4
}

const objectiveSettingsValid = computed(() => {
  const technicalConstraints = Object.values(objectiveSettings.technicalConstraints)
  const economicConstraints = objectiveSettings.economicConstraints
  const lifecycle = objectiveSettings.lifecycle
  return technicalConstraints.every(item => item.threshold >= 0 && item.threshold <= 100)
    && economicConstraints.lifecycleYears.threshold >= 1
    && economicConstraints.lifecycleYears.threshold <= 100
    && [economicConstraints.interestRatePercent, economicConstraints.taxRatePercent, economicConstraints.targetIrrPercent]
      .every(item => item.threshold >= 0 && item.threshold <= 100)
    && Object.values(lifecycle).every(value => typeof value === 'number' && Number.isFinite(value) && value >= 0)
    && (lifecycle.replace_cycle_years ?? 0) <= 50
    && (lifecycle.irr_penalty_weight ?? 1) >= 0
})

const confirmObjective = async () => {
  if (!objectiveSettingsValid.value) {
    push({ tone: 'warning', title: '请检查规划目标参数', description: '比例参数须在 0–100% 之间，生命周期须在 1–100 年之间。' })
    return
  }
  if (selectedTaskId.value && planningTask.value?.status === 'draft') {
    try {
      planningTask.value = await planningApi.updatePlanningConfig(selectedTaskId.value, {
        economics: capacityEconomicsPayload()
      })
    }
    catch (error) {
      push({ tone: 'danger', title: '保存规划目标失败', description: error instanceof Error ? error.message : String(error) })
      return
    }
  }
  objectiveConfirmed.value = true
  currentStep.value = 5
}

const formatNumber = (value: number) => new Intl.NumberFormat('zh-CN', {
  maximumFractionDigits: 4
}).format(value)

type CapacityBoundField = 'lowerBound' | 'upperBound'

const capacitySchemaMin = (item: CapacityVariableDraft) => {
  if (item.schemaMin === null || item.schemaMin === undefined) return 0
  const minimum = Number(item.schemaMin)
  return Number.isFinite(minimum) ? minimum : 0
}

const capacitySchemaMax = (item: CapacityVariableDraft) => {
  if (item.schemaMax === null || item.schemaMax === undefined) return undefined
  const maximum = Number(item.schemaMax)
  return Number.isFinite(maximum) ? maximum : undefined
}

const capacitySliderStep = (item: CapacityVariableDraft) => {
  const configuredStep = Number(item.step)
  if (Number.isFinite(configuredStep) && configuredStep > 0) return configuredStep
  return Math.max((Number(item.upperBound) - Number(item.lowerBound)) / 100, 0.0001)
}

const updateCapacityBound = (item: CapacityVariableDraft, field: CapacityBoundField, event: Event) => {
  const input = event.target as HTMLInputElement
  const inputValue = Number(input.value)
  if (!input.value.trim() || !Number.isFinite(inputValue)) {
    input.value = String(item[field])
    return
  }

  const gap = capacitySliderStep(item)
  if (field === 'lowerBound') {
    item.lowerBound = Math.max(capacitySchemaMin(item), Math.min(inputValue, item.upperBound - gap))
    item.suggestedValue = Math.max(item.suggestedValue, item.lowerBound)
  }
  else {
    const schemaMaximum = capacitySchemaMax(item)
    item.upperBound = Math.max(inputValue, item.lowerBound + gap)
    if (schemaMaximum !== undefined) item.upperBound = Math.min(item.upperBound, schemaMaximum)
    item.suggestedValue = Math.min(item.suggestedValue, item.upperBound)
  }

  input.value = String(item[field])
  validatedAt.value = ''
}

const updateCapacitySuggestion = (item: CapacityVariableDraft, event: Event) => {
  item.suggestedValue = Number((event.target as HTMLInputElement).value)
  validatedAt.value = ''
}

const updateParticipation = (item: CapacityVariableDraft, participates: boolean) => {
  item.mode = participates ? 'optimize' : 'fixed'
  if (!participates) item.fixedValue = item.currentValue
  validatedAt.value = ''
}

const variableError = (item: CapacityVariableDraft): string => {
  if (item.mode === 'fixed') {
    return Number.isFinite(Number(item.fixedValue)) && Number(item.fixedValue) >= 0
      ? ''
      : '固定容量必须是非负有限数值'
  }

  const lower = Number(item.lowerBound)
  const upper = Number(item.upperBound)
  const suggested = Number(item.suggestedValue)
  if (![lower, upper, suggested].every(Number.isFinite)) return '上下界和建议值必须是有限数值'
  if (lower < 0 || upper < 0 || suggested < 0) return '容量不能为负数'
  if (lower >= upper) return '下界必须小于上界'
  if (suggested < lower || suggested > upper) return '建议值必须位于上下界之间'
  return ''
}

const formValid = computed(() =>
  variables.value.length > 0
  && optimizedCount.value > 0
  && variables.value.every(item => !variableError(item))
)

const canPreviewScenarios = computed(() =>
  planningBoundaries.value.length > 0
  && clustering.featureIds.length > 0
  && clustering.clusterCount >= 2
  && clustering.missingDayThreshold >= 0
  && clustering.missingDayThreshold <= 1
)

const activePlanningStatuses: CapacityPlanningStatus[] = [
  'queued',
  'validating',
  'clustering',
  'optimizing'
]
const planningActive = computed(() =>
  Boolean(planningTask.value && activePlanningStatuses.includes(planningTask.value.status))
)
const cancellationPending = ref(false)
const planningCancellationRequested = computed(() => planningActive.value &&
  (cancellationPending.value || planningTask.value?.progress.cancellationRequested === true))
const optimizerValid = computed(() =>
  Number.isInteger(Number(optimizer.maxFuncEvals))
  && optimizer.maxFuncEvals >= 2
  && optimizer.maxFuncEvals <= 10000
  && Number.isInteger(Number(optimizer.populationSize))
  && optimizer.populationSize >= 2
  && optimizer.populationSize <= 500
  && Number(optimizer.maxTimeSeconds) >= 1
)

/** 提交给后端的优化器参数：种子/惩罚不暴露给用户，由后端自动评估 */
const optimizerPayload = () => ({
  method: optimizer.method || 'adaptive_de_rand_1_bin_radiuslimited',
  maxFuncEvals: Number(optimizer.maxFuncEvals),
  populationSize: Number(optimizer.populationSize),
  maxTimeSeconds: Number(optimizer.maxTimeSeconds),
  // 0 = 后端自动生成随机种子
  seed: 0,
  // 0 = 后端按目标量纲自动估算失败惩罚
  failurePenalty: 0,
  // 技术约束软惩罚系数（元/百分点），后端缺省口径
  technicalPenalty: 1e7
})
const planningPrerequisitesReady = computed(() =>
  Boolean(project.value && schema.value && planningBoundaries.value.length > 0 && scenarioPreview.value && objectiveConfirmed.value)
  && formValid.value
)
const canStartPlanning = computed(() =>
  planningPrerequisitesReady.value
  && optimizerValid.value
  && !planningActive.value
  && !planningBusy.value
)
const progressPercent = computed(() => {
  const progress = planningTask.value?.progress
  if (!progress?.maxFuncEvals) return 0
  return Math.min(100, Math.round(progress.completedEvaluations / progress.maxFuncEvals * 100))
})

const selectedClusteringFeatureLabel = computed(() => {
  const labels = clusteringFeatureOptions.value
    .filter(option => clustering.featureIds.includes(option.value))
    .map(option => option.label)
  if (!labels.length) return '—'
  return labels.length <= 2 ? labels.join('、') : `${labels.slice(0, 2).join('、')} 等 ${labels.length} 项`
})

const liveConvergencePoints = computed(() => {
  if (planningResult.value?.convergence.length) return planningResult.value.convergence
  return planningTask.value?.progress.convergence ?? []
})

/** 带 metrics 的评价点序列（双轴图 / 指标卡共用） */
const liveMetricPoints = computed(() =>
  liveConvergencePoints.value
    .filter(point => point.metrics)
    .map(point => ({
      ordinal: point.ordinal,
      fitness: point.fitness,
      bestSoFar: point.bestSoFar,
      feasible: point.feasible,
      metrics: point.metrics!
    }))
)

/** 指标方向：true = 越大越好 */
const METRIC_HIGHER_BETTER: Record<string, boolean> = {
  fitness: false,
  objectiveFitness: false,
  lifecycleCapexWan: false,
  weightedOperatingCost: false,
  irr: true,
  lcoe: false,
  npv: true
}

/** Step5 实时指标卡：数值 + 相对上一次评价的变化方向/优劣 */
const liveMetricCards = computed(() => {
  const points = liveMetricPoints.value
  const source = points[points.length - 1]
  if (!source?.metrics) return null
  const m = source.metrics
  const prev = points.length >= 2 ? points[points.length - 2] : null
  const prevM = prev?.metrics

  const pick = (key: string, fallback?: number | null) => {
    const rawCurrent = (m as Record<string, unknown>)[key]
    const current = Number(rawCurrent ?? fallback)
    const rawPrevious = prevM ? (prevM as Record<string, unknown>)[key] : null
    const previous = rawPrevious == null ? null : Number(rawPrevious)
    const previousFallback = key === 'fitness' ? prev?.fitness : null
    const comparablePrevious = previous !== null && Number.isFinite(previous)
      ? previous
      : Number(previousFallback)
    if (!Number.isFinite(current)) {
      return { value: null as number | null, trend: '' as const, trendTone: '' }
    }
    if (!Number.isFinite(comparablePrevious) || Math.abs(current - comparablePrevious) < 1e-9) {
      return { value: current, trend: '' as const, trendTone: '' }
    }
    const higherBetter = METRIC_HIGHER_BETTER[key] ?? false
    const trend = current > comparablePrevious ? 'up' as const : 'down' as const
    const improved = higherBetter ? trend === 'up' : trend === 'down'
    return { value: current, trend, trendTone: improved ? 'text-app-success' : 'text-app-danger' }
  }

  return {
    fitness: pick('fitness', source.fitness),
    objectiveFitness: pick('objectiveFitness'),
    lifecycleCapexWan: pick('lifecycleCapexWan'),
    weightedOperatingCost: pick('weightedOperatingCost'),
    irr: pick('irr'),
    lcoe: pick('lcoe'),
    npv: pick('npv'),
    hasPenalty: Boolean(m.hasPenalty),
    ordinal: source.ordinal
  }
})

/** 右轴技术指标序列：消纳/绿电/购电/过剩稳定性/缺额稳定性 */
const liveTechSeries = computed(() => {
  const points = liveMetricPoints.value
  const seriesDef = [
    { key: 'renewableConsumptionRate', name: '新能源消纳率', color: '#16B8A6', invertShare: false },
    { key: 'greenPowerShare', name: '绿电占比', color: '#22C55E', invertShare: false },
    { key: 'purchasedPowerShare', name: '购电占比', color: '#F59E0B', invertShare: false },
    { key: 'stabilityExcessShare', name: '过剩稳定性', color: '#EC4899', invertShare: true },
    { key: 'stabilityShortageShare', name: '缺额稳定性', color: '#F97316', invertShare: true }
  ] as const
  return seriesDef.map((def, index) => {
    const data = points.map(p => {
      const raw = (p.metrics as Record<string, unknown>)[def.key]
      const numericValue = raw == null ? null : Number(raw)
      const value = Number.isFinite(numericValue as number)
        ? def.invertShare
          ? Math.max(0, Math.min(100, 100 - (numericValue as number)))
          : numericValue as number
        : null
      return [p.ordinal, value] as [number, number | null]
    })
    const values = data.map(item => item[1]).filter((value): value is number => value !== null)
    return {
      name: def.name,
      key: def.key,
      color: def.color,
      symbol: ['circle', 'rect', 'roundRect', 'diamond', 'triangle'][index],
      symbolSize: [5, 5, 9, 7, 5][index],
      state: values.length === 0 ? 'empty' as const : values.every(value => Math.abs(value) < 1e-9) ? 'zero' as const : 'normal' as const,
      data
    }
  })
})

const capacityChartItems = computed(() => {
  const resultById = new Map(
    (planningResult.value?.variables ?? []).map(item => [item.componentId, item])
  )
  const bestCandidate = planningTask.value?.progress.bestCandidate
  return variables.value
    .filter(item => item.mode === 'optimize')
    .map((item) => {
      const finalResult = resultById.get(item.componentId)
      const liveValue = bestCandidate?.[item.componentId]?.value
      return {
        componentId: item.componentId,
        name: item.componentName,
        unit: item.unit,
        currentValue: Number(item.currentValue),
        plannedValue: Number(finalResult?.optimalValue ?? liveValue ?? item.suggestedValue)
      }
    })
})

const solverIndicator = computed(() => {
  const status = planningTask.value?.status
  if (planningBusy.value || status === 'queued' || status === 'validating' || status === 'clustering') {
    return { label: '校验中', tone: 'checking' as const }
  }
  if (status === 'optimizing') return { label: '开始计算', tone: 'running' as const }
  if (status === 'completed') return { label: '计算完成', tone: 'completed' as const }
  if (status === 'failed') return { label: '计算失败', tone: 'failed' as const }
  if (status === 'cancelled') return { label: '已终止', tone: 'cancelled' as const }
  return { label: '等待启动', tone: 'ready' as const }
})

const planningPrerequisiteEntries = computed(() => {
  const algorithmLabel = clustering.algorithm === 'kmeans' ? 'K-means' : 'K-medoids'
  return [
    {
      title: '容量变量配置完毕',
      detail: `${optimizedCount.value} 个参与优化，${fixedCount.value} 个保持固定，变量配置已确认`,
      state: (formValid.value ? 'done' : 'pending') as PlanningLogState
    },
    {
      title: '历史边界数据配置完毕',
      detail: planningBoundaries.value.length > 0
        ? `${planningBoundaries.value.length} 条已关联边界已配置`
        : '尚未配置边界数据',
      state: (planningBoundaries.value.length > 0 ? 'done' : 'pending') as PlanningLogState
    },
    {
      title: '典型场景聚类完毕',
      detail: scenarioPreview.value
        ? `${scenarioPreview.value.scenarios.length} 个场景，${algorithmLabel}，特征：${selectedClusteringFeatureLabel.value}`
        : '尚未生成典型场景',
      state: (scenarioPreview.value ? 'done' : 'pending') as PlanningLogState
    },
    {
      title: '规划目标配置完毕',
      detail: selectedObjectiveLabel.value,
      state: (objectiveConfirmed.value ? 'done' : 'pending') as PlanningLogState
    }
  ]
})

const solverThinkingText = computed(() => {
  if (planningCancellationRequested.value) return '正在终止当前求解并释放计算资源…'
  const progress = planningTask.value?.progress
  if (planningActive.value && progress?.currentEvaluation != null) {
    const displayElapsedMs = progress.wallElapsedMs ?? progress.elapsedMs ?? 0
    return `第 ${progress.currentEvaluation} 次评价 · 已用时 ${Math.floor(displayElapsedMs / 1000)} 秒`
  }
  if (solverIndicator.value.tone === 'checking') return '正在理解配置并执行一致性校验'
  if (solverIndicator.value.tone === 'running') return '正在搜索容量组合并推演更优解'
  if (solverIndicator.value.tone === 'completed') return '推演完成，已生成最优容量方案'
  if (solverIndicator.value.tone === 'failed') return '推演中断，正在整理错误信息'
  if (solverIndicator.value.tone === 'cancelled') return '任务已终止，等待新的求解指令'
  return '配置已载入，等待启动求解'
})

const planningLogTime = () => new Date().toLocaleTimeString('zh-CN', {
  hour12: false,
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit'
})

const MAX_PLANNING_LOG_ENTRIES = 30

const appendPlanningLog = (item: Omit<PlanningLogItem, 'time'>) => {
  if (planningLogIds.has(item.id)) return
  planningLogIds.add(item.id)
  planningLogFeed.value.push({ ...item, time: planningLogTime() })
  if (planningLogFeed.value.length > MAX_PLANNING_LOG_ENTRIES) {
    planningLogFeed.value.splice(0, planningLogFeed.value.length - MAX_PLANNING_LOG_ENTRIES)
  }
  void nextTick(() => {
    if (planningLogRef.value) planningLogRef.value.scrollTop = planningLogRef.value.scrollHeight
  })
}

const resetPlanningLog = () => {
  if (planningLogSequenceTimer) clearTimeout(planningLogSequenceTimer)
  planningLogSequenceTimer = null
  planningLogFeed.value = []
  planningLogIds.clear()
  lastLoggedEvaluation = 0
}

const appendCurrentPlanningStatus = () => {
  const task = planningTask.value
  if (planningBusy.value && !task) {
    appendPlanningLog({
      id: 'creating-task',
      title: '正在创建容量规划任务',
      detail: '冻结项目、容量变量与典型场景快照',
      state: 'active'
    })
    return
  }
  if (!task) {
    appendPlanningLog(planningPrerequisitesReady.value
      ? {
          id: 'ready-to-solve',
          title: '全部前置条件完成',
          detail: 'AI 规划引擎已就绪，等待开始求解',
          state: 'done'
        }
      : {
          id: 'prerequisite-missing',
          title: '前置条件尚未完成',
          detail: '请返回对应步骤补充配置和确认',
          state: 'pending'
        })
    return
  }

  if (task.status === 'queued') {
    appendPlanningLog({ id: 'task-queued', title: '规划任务已进入计算队列', detail: `任务 ${task.id.slice(0, 12)}，等待分配求解资源`, state: 'active' })
  }
  else if (task.status === 'validating') {
    appendPlanningLog({ id: 'task-validating', title: '正在校验容量规划配置', detail: '检查项目快照、容量上下界和求解参数', state: 'active' })
  }
  else if (task.status === 'clustering') {
    appendPlanningLog({ id: 'task-clustering', title: '正在复核典型场景', detail: '冻结聚类结果并检查场景权重一致性', state: 'active' })
  }
  else if (task.status === 'optimizing') {
    appendPlanningLog({ id: 'task-optimizing', title: '全部前置条件完成，开始求解', detail: '黑箱优化器正在搜索可行容量组合', state: 'active' })
  }
  else if (task.status === 'completed') {
    appendPlanningLog({
      id: 'task-completed',
      title: '容量规划求解完成',
      detail: `完成 ${task.progress.completedEvaluations} 次评价，最优适应度 ${task.progress.bestFitness === null ? '—' : formatNumber(task.progress.bestFitness)}`,
      state: 'done'
    })
  }
  else if (task.status === 'failed') {
    appendPlanningLog({ id: 'task-failed', title: '容量规划求解失败', detail: planningError.value || task.errorMessage || '求解器返回异常', state: 'error' })
  }
  else if (task.status === 'cancelled') {
    appendPlanningLog({ id: 'task-cancelled', title: '容量规划已终止', detail: '已停止后续候选容量评价', state: 'error' })
  }

  const completedEvaluations = task.progress.completedEvaluations
  if (planningCancellationRequested.value) {
    appendPlanningLog({ id: 'task-cancelling', title: '正在终止容量规划', detail: '正在停止当前求解并释放计算资源', state: 'active' })
  }
  if (completedEvaluations > lastLoggedEvaluation) {
    lastLoggedEvaluation = completedEvaluations
    appendPlanningLog({
      id: `evaluation-${completedEvaluations}`,
      title: `求解中 · 第 ${completedEvaluations} 次评价完成`,
      detail: task.progress.bestFitness === null
        ? '当前候选方案不可行，继续搜索新的容量组合'
        : `当前最优适应度 ${formatNumber(task.progress.bestFitness)}`,
      state: task.status === 'completed' ? 'done' : 'active'
    })
  }
}

const startPlanningLogSequence = () => {
  resetPlanningLog()
  const entries = [...planningPrerequisiteEntries.value]
  let index = 0
  const revealNext = () => {
    if (currentStep.value !== 5) return
    const entry = entries[index]
    if (!entry) {
      appendCurrentPlanningStatus()
      planningLogSequenceTimer = null
      return
    }
    appendPlanningLog({ id: `prerequisite-${index}`, ...entry })
    index += 1
    planningLogSequenceTimer = setTimeout(revealNext, 520)
  }
  planningLogSequenceTimer = setTimeout(revealNext, 180)
}

const compactChartNumber = (value: number) => {
  const absolute = Math.abs(value)
  if (absolute >= 1e9) return `${(value / 1e9).toFixed(1)}G`
  if (absolute >= 1e6) return `${(value / 1e6).toFixed(1)}M`
  if (absolute >= 1e3) return `${(value / 1e3).toFixed(1)}k`
  return Number(value.toFixed(2)).toString()
}

const renderConvergenceChart = () => {
  if (!convergenceChartRef.value || currentStep.value !== 5) return
  if (!convergenceChart) convergenceChart = echarts.init(convergenceChartRef.value)
  const chartOption = convergenceChart.getOption() as
    { legend?: Array<{ selected?: Record<string, boolean> }> } | undefined
  const legendSelected = chartOption?.legend?.[0]?.selected
  const points = liveConvergencePoints.value

  // 左轴：本次目标 / 当前最优
  const currentFitness = points
    .filter(point => point.feasible && Number.isFinite(point.fitness))
    .map(point => [point.ordinal, point.fitness])
  const bestFitness = points
    .filter(point => point.bestSoFar !== null && Number.isFinite(point.bestSoFar))
    .map(point => [point.ordinal, point.bestSoFar as number])

  const techSeries = liveTechSeries.value

  convergenceChart.setOption({
    animationDuration: 250,
    animationDurationUpdate: 250,
    tooltip: {
      trigger: 'axis',
      confine: true,
      valueFormatter: (value: unknown) => {
        const n = Number(value)
        return Number.isFinite(n) ? n.toFixed(n >= 100 ? 1 : 2) : String(value ?? '')
      }
    },
    legend: {
      top: 0,
      left: 4,
      right: 4,
      type: 'scroll',
      itemWidth: 12,
      itemHeight: 7,
      textStyle: { fontSize: 10 },
      selected: legendSelected,
      formatter: (name: string) => {
        const series = techSeries.find(item => item.name === name)
        if (series?.state === 'zero') return `${name}（全 0%）`
        if (series?.state === 'empty') return `${name}（无数据）`
        return name
      }
    },
    grid: { left: 54, right: 52, top: 48, bottom: 44 },
    xAxis: {
      type: 'value',
      minInterval: 1,
      name: '评价次数',
      nameLocation: 'middle',
      nameGap: 28,
      axisLabel: { fontSize: 10 },
      splitLine: { show: false }
    },
    yAxis: [
      {
        type: 'value',
        scale: true,
        axisLabel: { fontSize: 10, formatter: compactChartNumber },
        splitLine: { lineStyle: { type: 'dashed', color: '#e8edf4' } }
      },
      {
        type: 'value',
        min: 0,
        max: 100,
        position: 'right',
        axisLabel: { fontSize: 10, formatter: '{value}%' },
        splitLine: { show: false }
      }
    ],
    dataZoom: points.length > 30
      ? [{ type: 'inside', startValue: Math.max(1, points.length - 29), endValue: points.length }]
      : [],
    graphic: points.length
      ? []
      : [{
          type: 'text',
          left: 'center',
          top: 'middle',
          style: { text: '等待黑箱评价数据…', fill: '#8a94a6', fontSize: 13 }
        }],
    series: [
      {
        name: '本次目标',
        type: 'line',
        yAxisIndex: 0,
        data: currentFitness,
        showSymbol: true,
        symbolSize: 5,
        lineStyle: { width: 1.5, color: '#93B4E8' },
        itemStyle: { color: '#93B4E8' }
      },
      {
        name: '当前最优',
        type: 'line',
        yAxisIndex: 0,
        data: bestFitness,
        showSymbol: false,
        step: 'end',
        lineStyle: { width: 2.5, color: '#165DFF' },
        itemStyle: { color: '#165DFF' },
        areaStyle: { color: 'rgba(22, 93, 255, 0.10)' }
      },
      ...techSeries.map(s => ({
        name: s.name,
        type: 'line' as const,
        yAxisIndex: 1,
        data: s.data.map(([ordinal, value]) => [ordinal, value]),
        showSymbol: true,
        symbol: s.symbol,
        symbolSize: s.symbolSize,
        connectNulls: true,
        lineStyle: { width: 1.2, color: s.color, type: 'dashed' as const },
        itemStyle: { color: s.color }
      }))
    ]
  }, true)
}

const renderCapacityChangeChart = () => {
  if (!capacityChangeChartRef.value || currentStep.value !== 5) return
  if (!capacityChangeChart) capacityChangeChart = echarts.init(capacityChangeChartRef.value)
  const items = capacityChartItems.value
  capacityChangeChart.setOption({
    animationDuration: 300,
    animationDurationUpdate: 300,
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      formatter: (params: unknown) => {
        const rows = Array.isArray(params) ? params as Array<{ dataIndex?: number; seriesName?: string; value?: number; color?: string }> : []
        const index = rows[0]?.dataIndex ?? 0
        const item = items[index]
        if (!item) return ''
        return [
          `<b>${item.name}</b>`,
          ...rows.map(row => `<span style="color:${row.color ?? ''}">●</span> ${row.seriesName ?? ''}：${formatNumber(Number(row.value ?? 0))} ${item.unit}`)
        ].join('<br/>')
      }
    },
    legend: {
      top: 2,
      right: 8,
      itemWidth: 14,
      itemHeight: 8,
      textStyle: { fontSize: 10 }
    },
    grid: { left: 54, right: 18, top: 38, bottom: items.length > 5 ? 66 : 44 },
    xAxis: {
      type: 'category',
      data: items.map(item => item.name),
      axisLabel: {
        fontSize: 10,
        interval: 0,
        rotate: items.length > 5 ? 28 : 0,
        formatter: (value: string) => value.length > 8 ? `${value.slice(0, 8)}…` : value
      }
    },
    yAxis: {
      type: 'value',
      scale: true,
      axisLabel: { fontSize: 10, formatter: compactChartNumber },
      splitLine: { lineStyle: { type: 'dashed', color: '#e8edf4' } }
    },
    graphic: items.length
      ? []
      : [{
          type: 'text',
          left: 'center',
          top: 'middle',
          style: { text: '暂无参与规划的容量参数', fill: '#8a94a6', fontSize: 13 }
        }],
    series: [
      {
        name: '当前容量',
        type: 'bar',
        data: items.map(item => item.currentValue),
        barMaxWidth: 30,
        itemStyle: { color: '#B8C4D6', borderRadius: [4, 4, 0, 0] }
      },
      {
        name: planningTask.value?.progress.bestCandidate ? '实时最优容量' : '推荐初值',
        type: 'bar',
        data: items.map(item => item.plannedValue),
        barMaxWidth: 30,
        itemStyle: { color: '#165DFF', borderRadius: [4, 4, 0, 0] }
      }
    ]
  }, true)
}

const renderSolverCharts = () => {
  renderConvergenceChart()
  renderCapacityChangeChart()
}

const disposeSolverCharts = () => {
  convergenceChart?.dispose()
  capacityChangeChart?.dispose()
  convergenceChart = null
  capacityChangeChart = null
}

const scrollPlanningLogToEnd = () => {
  if (planningLogRef.value) planningLogRef.value.scrollTop = planningLogRef.value.scrollHeight
}

const loadSchema = async () => {
  loading.value = true
  errorMessage.value = ''
  validatedAt.value = ''
  try {
    if (!projectId.value || !canvasId.value) {
      throw new Error('缺少项目或画布参数，请从编辑器的”容量规划”入口进入')
    }
    schema.value = await planningApi.getFormSchema(projectId.value, canvasId.value)
  }
  catch (error) {
    errorMessage.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    loading.value = false
  }
}

// ───── 任务管理函数 ─────
const loadTaskList = async () => {
  taskListLoading.value = true
  try {
    const result = await planningApi.listPlannings(projectId.value)
    taskList.value = result.tasks ?? []
  }
  catch (error) {
    console.warn('[CapPlan] loadTaskList error:', error)
    taskList.value = []
  }
  finally {
    taskListLoading.value = false
  }
}

const selectTask = async (taskId: string) => {
  clearPlanningPoll()
  cancellationPending.value = false
  planningError.value = ''
  selectedTaskId.value = taskId
  showTaskListDialog.value = false
  try {
    planningTask.value = await planningApi.getPlanning(taskId)

    // 如果任务已有变量配置，恢复到 schema
    if (planningTask.value?.config?.variables && schema.value) {
      const savedVariables = planningTask.value.config.variables
      // 将保存的变量配置合并到 schema 中
      for (const savedVar of savedVariables) {
        const existingVar = schema.value.variables.find(v => v.componentId === savedVar.componentId)
        if (existingVar) {
          // 更新现有变量的配置
          existingVar.mode = savedVar.mode
          existingVar.fixedValue = savedVar.fixedValue
          existingVar.lowerBound = savedVar.lowerBound
          existingVar.upperBound = savedVar.upperBound
          existingVar.suggestedValue = savedVar.suggestedValue
        }
      }
      validatedAt.value = '' // 标记需要重新校验
    }

    // 如果任务已有聚类配置，恢复聚类设置（抑制变更监听，避免清空已生成预览）
    suppressClusteringInvalidation.value = true
    try {
      // 切换任务时先清掉上一个任务的回显，避免无预览任务继承旧场景。
      scenarioPreview.value = null
      if (planningTask.value?.config?.clustering) {
        const c = planningTask.value.config.clustering
        clustering.featureIds = c.featureIds || []
        clustering.clusterCount = c.clusterCount || 4
        clustering.algorithm = c.algorithm || 'kmeans'
        clustering.normalize = c.normalize || 'zscore'
        clustering.missingDayThreshold = c.missingDayThreshold || 0.05
        clustering.seed = c.seed || 20260828
        clustering.preserveExtremes = c.preserveExtremes ?? true
        clustering.scenarioPreviewHash = c.scenarioPreviewHash ?? null
        clustering.boundariesVersion = (c as { boundariesVersion?: string | null }).boundariesVersion ?? null
      }
    }
    finally {
      suppressClusteringInvalidation.value = false
    }

    // 回显已保存场景；不自动重聚类（产品要求：边界更新只提示，用户手点生成）
    {
      const savedPreview = (planningTask.value?.config?.clustering as { savedScenarioPreview?: ScenarioPreviewResult | null } | undefined)?.savedScenarioPreview
      if (savedPreview && savedPreview.scenarios?.length) {
        scenarioPreview.value = savedPreview
      }
      else if (planningTask.value.status !== 'draft') {
        // 已启动任务读取求解阶段真正落库的场景，兼容旧任务未保存预览的情况。
        try {
          scenarioPreview.value = await planningApi.getPlanningScenarios(taskId)
          clustering.scenarioPreviewHash = scenarioPreview.value.scenarioSetHash
        }
        catch (error) {
          console.warn('[CapPlan] restore persisted scenarios failed:', error)
        }
      }
      else if (clustering.scenarioPreviewHash && clustering.featureIds.length > 0 && canPreviewScenarios.value) {
        // 旧草稿未存 preview：仅此一次静默补齐回显（不弹「边界已变化」）
        await previewTypicalDays({ silent: true, mode: 'restore' })
      }
    }

    // 如果任务已有优化器配置，恢复优化器设置
    if (planningTask.value?.config?.optimizer) {
      const o = planningTask.value.config.optimizer
      optimizer.maxFuncEvals = o.maxFuncEvals || 20
      optimizer.populationSize = o.populationSize || 10
      optimizer.maxTimeSeconds = o.maxTimeSeconds || 300
      if (o.method && optimizerMethodOptions.some(item => item.value === o.method)) {
        optimizer.method = o.method
      }
    }

    // 恢复方案目标、技术性约束与经济性参数；兼容旧任务配置
    if (planningTask.value?.config?.economics) {
      const economics = planningTask.value.config.economics
      if (objectiveOptions.some(option => option.value === economics.objective)) {
        objectiveSettings.objective = economics.objective
      }
      if (economics.technicalConstraints) {
        for (const item of technicalConstraintItems.value) {
          Object.assign(
            objectiveSettings.technicalConstraints[item.key],
            economics.technicalConstraints[item.key] ?? {}
          )
        }
      }
      if (economics.economicConstraints) {
        for (const item of economicCoreItems.value) {
          Object.assign(
            objectiveSettings.economicConstraints[item.key],
            economics.economicConstraints[item.key] ?? {}
          )
          // 参数始终生效；旧任务 enabled:false 仅作历史字段忽略
          objectiveSettings.economicConstraints[item.key].enabled = true
        }
      }
      if (economics.lifecycle && typeof economics.lifecycle === 'object') {
        const hydrated: Record<string, number> = {}
        for (const [key, value] of Object.entries(economics.lifecycle)) {
          if (typeof value === 'number' && Number.isFinite(value)) {
            hydrated[key] = lifecycleRateToPercent(key, value)
          } else {
            hydrated[key] = value as number
          }
        }
        Object.assign(objectiveSettings.lifecycle, hydrated)
      }
      objectiveSettings.extensions = economics.extensions ?? {}
    }

    // C-405/C-406：已完成任务恢复最优结果、方案比较与应用记录
    if (planningTask.value?.status === 'completed') {
      await restoreCompletedTaskView()
    }
    else {
      planningResult.value = null
      comparison.value = null
      comparisonExpandedId.value = null
      applyRecords.value = []

      if (activePlanningStatuses.includes(planningTask.value.status)) {
        currentStep.value = 5
        startPlanningPoll()
      }
      else if (planningTask.value.status === 'failed' || planningTask.value.status === 'cancelled') {
        currentStep.value = 5
        planningError.value = planningTask.value.errorMessage
          || (planningTask.value.status === 'cancelled' ? '容量规划已取消' : '容量规划失败')
      }
    }
  }
  catch (error) {
    console.warn('[CapPlan] selectTask error:', error)
    planningTask.value = null
  }
}

const openTaskList = async () => {
  await loadTaskList()
  showTaskListDialog.value = true
}

const openCreateTask = async () => {
  // 确保 project 已加载
  if (!project.value) {
    try {
      const result = await projectApi.getProject(projectId.value)
      project.value = result.project
    }
    catch (error) {
      console.warn('[CapPlan] Failed to load project:', error)
    }
  }
  newTaskForm.name = defaultTaskName.value
  newTaskForm.canvasId = canvasId.value || project.value?.workspace?.canvases[0]?.id || ''
  showCreateTaskDialog.value = true
}

const createTask = async () => {
  if (!schema.value) return
  creatingTask.value = true
  try {
    const clusteringConfig = clusteringConfigPayload()

    const task = await planningApi.createPlanning({
      projectId: projectId.value,
      canvasId: newTaskForm.canvasId || canvasId.value,
      name: newTaskForm.name || defaultTaskName.value,
      variables: schema.value.variables,
      planningLayerId: '1',
      clustering: clusteringConfig,
      optimizer: optimizerPayload(),
      economics: capacityEconomicsPayload()
    })
    push({ tone: 'success', title: '任务已创建', description: task.name || task.id })
    showCreateTaskDialog.value = false
    await selectTask(task.id)
    currentStep.value = 1
  }
  catch (error) {
    push({ tone: 'danger', title: '创建任务失败', description: error instanceof Error ? error.message : String(error) })
  }
  finally {
    creatingTask.value = false
  }
}

const deleteTask = async (taskId: string) => {
  if (cleanupTaskId.value) return
  if (!confirm('确认清理该容量规划任务？任务记录和全部计算数据将被永久删除，此操作不可撤销。')) return
  cleanupTaskId.value = taskId
  try {
    await planningApi.cleanupPlanning(taskId)
    push({ tone: 'success', title: '任务已清理', description: '任务记录和计算数据已删除' })
    await loadTaskList()
    if (selectedTaskId.value === taskId) {
      selectedTaskId.value = null
      planningTask.value = null
      planningResult.value = null
      comparison.value = null
      applyRecords.value = []
    }
  }
  catch (error) {
    push({ tone: 'danger', title: '清理失败', description: error instanceof Error ? error.message : String(error) })
  }
  finally {
    cleanupTaskId.value = null
  }
}

// ───── 步骤保存函数 ─────
const saveVariablesToTask = async () => {
  if (!selectedTaskId.value || !schema.value) return
  // 变量配置保存到任务（通过重新创建任务配置的方式）
  // 注意：后端目前不支持单独更新变量，需要通过其他方式实现
  // 这里暂时只在创建任务时保存
}

const saveClusteringToTask = async () => {
  if (!selectedTaskId.value) return
  planningTask.value = await planningApi.updatePlanningConfig(selectedTaskId.value, {
    clustering: clusteringConfigPayload()
  })
}

const STATUS_LABEL: Record<string, string> = {
  draft: '草稿',
  queued: '排队中',
  validating: '校验中',
  clustering: '聚类中',
  optimizing: '优化中',
  completed: '已完成',
  failed: '失败',
  cancelled: '已取消'
}

const STATUS_TONE: Record<string, string> = {
  draft: 'neutral',
  queued: 'primary',
  validating: 'primary',
  clustering: 'primary',
  optimizing: 'primary',
  completed: 'success',
  failed: 'danger',
  cancelled: 'warning'
}

const loadDatasetContext = async () => {
  datasetError.value = ''
  try {
    const projectResult = await projectApi.getProject(projectId.value)
    project.value = projectResult.project
    // 项目加载后立即通过边界配置 API 拉取边界时序数据
    await loadBoundarySeries()
    await ensureDefaultBoundaryPreview()
  }
  catch (error) {
    datasetError.value = error instanceof Error ? error.message : String(error)
  }
}

/** 保存回显用精简场景（memberDates 过长时截断） */
const slimScenarioPreviewForSave = (preview: ScenarioPreviewResult): ScenarioPreviewResult => ({
  ...preview,
  scenarios: preview.scenarios.map(s => ({
    ...s,
    memberDates: (s.memberDates ?? []).slice(0, 12),
    series: { ...s.series }
  }))
})

/** 聚类配置统一出口：含 hash / 边界版本 / 回显预览 */
const clusteringConfigPayload = () => ({
  featureIds: [...clustering.featureIds],
  clusterCount: Number(clustering.clusterCount),
  algorithm: clustering.algorithm,
  normalize: clustering.normalize,
  missingDayThreshold: Number(clustering.missingDayThreshold),
  seed: Number(clustering.seed),
  representative: 'nearest-observation' as const,
  preserveExtremes: clustering.preserveExtremes,
  scenarioPreviewHash: clustering.scenarioPreviewHash,
  boundariesVersion: clustering.boundariesVersion,
  savedScenarioPreview: scenarioPreview.value
    ? slimScenarioPreviewForSave(scenarioPreview.value)
    : null
})

const previewTypicalDays = async (options?: {
  silent?: boolean
  /** restore：回显旧任务补齐；user：用户手点生成 */
  mode?: 'user' | 'restore'
}) => {
  if (!canPreviewScenarios.value) return
  const mode = options?.mode ?? 'user'
  const wasStale = boundariesStale.value
  datasetLoading.value = true
  datasetError.value = ''
  scenarioPreview.value = null
  try {
    scenarioPreview.value = await planningApi.previewScenarios({
      projectId: projectId.value,
      canvasId: canvasId.value,
      featureIds: [...clustering.featureIds],
      clusterCount: Number(clustering.clusterCount),
      algorithm: clustering.algorithm,
      normalize: clustering.normalize,
      missingDayThreshold: Number(clustering.missingDayThreshold),
      seed: Number(clustering.seed),
      representative: 'nearest-observation',
      preserveExtremes: clustering.preserveExtremes
    })
    // C-402：回写场景集 hash，供运行时校验预览与实际输入同版本
    clustering.scenarioPreviewHash = scenarioPreview.value.scenarioSetHash
    clustering.boundariesVersion = project.value?.boundariesUpdatedAt ?? null

    if (mode === 'user' && !options?.silent) {
      if (wasStale) {
        push({
          tone: 'info',
          title: '场景已按当前边界重新计算',
          description: '请核对典型场景后再继续'
        })
      }
      else {
        push({
          tone: 'success',
          title: '典型场景聚类完成',
          description: `${scenarioPreview.value.scenarios.length} 个场景，覆盖 ${scenarioPreview.value.quality.validDayCount} 个有效日`
        })
      }
    }
    // restore 路径静默，不弹「边界已变化」
    if (selectedTaskId.value) {
      try {
        await saveClusteringToTask()
      }
      catch (error) {
        console.warn('[CapPlan] save clustering after preview failed:', error)
      }
    }
  }
  catch (error) {
    datasetError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    datasetLoading.value = false
  }
}

const validateForm = async () => {
  if (!schema.value || !formValid.value) {
    push({ tone: 'warning', title: '请先修正容量变量配置' })
    return false
  }

  validating.value = true
  errorMessage.value = ''
  try {
    const result = await planningApi.validateVariables({
      projectId: projectId.value,
      canvasId: canvasId.value,
      variables: schema.value.variables
    })
    schema.value.variables = result.variables
    validatedAt.value = new Date().toLocaleTimeString('zh-CN')
    push({
      tone: 'success',
      title: '容量变量配置已通过服务端校验',
      description: `共 ${optimizedCount.value} 个优化变量、${fixedCount.value} 个固定变量`
    })
    return true
  }
  catch (error) {
    errorMessage.value = error instanceof Error ? error.message : String(error)
    return false
  }
  finally {
    validating.value = false
  }
}

const validateAndContinue = async () => {
  if (await validateForm()) {
    // 保存变量配置到任务
    if (selectedTaskId.value && schema.value) {
      try {
        await planningApi.updatePlanningConfig(selectedTaskId.value, {
          variables: [...schema.value.variables]
        })
        push({ tone: 'success', title: '变量配置已保存到任务' })
      }
      catch (error) {
        console.warn('[CapPlan] Failed to save variables:', error)
      }
    }
    currentStep.value = 2
  }
}

const clearPlanningPoll = () => {
  if (planningPollTimer) clearInterval(planningPollTimer)
  planningPollTimer = null
}

const refreshPlanning = async () => {
  if (!planningTask.value || planningPollPending) return
  const planningId = planningTask.value.id
  planningPollPending = true
  try {
    const task = await planningApi.getPlanning(planningId)
    if (planningTask.value?.id !== planningId) return
    planningTask.value = task
    if (planningTask.value.status === 'completed') {
      cancellationPending.value = false
      await restoreCompletedTaskView()
      clearPlanningPoll()
      push({
        tone: 'success',
        title: '容量规划完成',
        description: `${planningResult.value?.evaluationCount ?? 0} 次评价，最优目标 ${formatNumber(planningResult.value?.fitness ?? 0)}`
      })
    }
    else if (planningTask.value.status === 'failed' || planningTask.value.status === 'cancelled') {
      cancellationPending.value = false
      clearPlanningPoll()
      planningError.value = planningTask.value.errorMessage
        || (planningTask.value.status === 'cancelled' ? '容量规划已取消' : '容量规划失败')
    }
  }
  catch (error) {
    planningError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    planningPollPending = false
  }
}

const startPlanningPoll = () => {
  clearPlanningPoll()
  planningPollTimer = setInterval(refreshPlanning, 500)
  void refreshPlanning()
}

const createAndStartPlanning = async () => {
  if (!canStartPlanning.value || !schema.value) return
  clearPlanningPoll()
  cancellationPending.value = false
  resetPlanningLog()
  planningTask.value = null
  planningBusy.value = true
  planningError.value = ''
  planningResult.value = null
  comparison.value = null
  comparisonExpandedId.value = null
  applyResult.value = null
  applyRecords.value = []
  applyTarget.value = 'current-canvas'
  newCanvasName.value = ''
  try {
    const validated = await planningApi.validateVariables({
      projectId: projectId.value,
      canvasId: canvasId.value,
      variables: schema.value.variables
    })
    schema.value.variables = validated.variables
    validatedAt.value = new Date().toLocaleTimeString('zh-CN')

    const created = await planningApi.createPlanning({
      projectId: projectId.value,
      canvasId: canvasId.value,
      name: `${schema.value.projectName}容量规划`,
      variables: schema.value.variables,
      planningLayerId: '1',
      clustering: clusteringConfigPayload(),
      optimizer: optimizerPayload(),
      economics: capacityEconomicsPayload()
    })
    planningTask.value = await planningApi.startPlanning(created.id)
    currentStep.value = 5
    push({
      tone: 'success',
      title: '容量规划任务已启动',
      description: `任务 ${created.id.slice(0, 12)}，建议容量将首先被评价`
    })
    startPlanningPoll()
  }
  catch (error) {
    planningError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    planningBusy.value = false
  }
}

const cancelPlanning = async () => {
  if (!planningTask.value || !planningActive.value || planningCancellationRequested.value) return
  cancellationPending.value = true
  planningBusy.value = true
  try {
    planningTask.value = await planningApi.cancelPlanning(planningTask.value.id)
    await refreshPlanning()
  }
  catch (error) {
    cancellationPending.value = false
    planningError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    planningBusy.value = false
  }
}

// C-101：应用前先取服务端差异预览，用户确认后才执行写入
const requestApply = async () => {
  if (!planningTask.value || !planningResult.value || applyingResult.value || applyPreviewLoading.value) return
  applyPreviewLoading.value = true
  planningError.value = ''
  try {
    applyPreview.value = await planningApi.getApplyPreview(planningTask.value.id)
    showApplyConfirmDialog.value = true
  }
  catch (error) {
    planningError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    applyPreviewLoading.value = false
  }
}

const confirmApply = () => {
  showApplyConfirmDialog.value = false
  applyPreview.value = null
  applyAndSimulate()
}

const cancelApply = () => {
  showApplyConfirmDialog.value = false
  applyPreview.value = null
}

const applyAndSimulate = async () => {
  if (!planningTask.value || !planningResult.value || applyingResult.value) return
  applyingResult.value = true
  planningError.value = ''
  try {
    applyResult.value = await planningApi.applyAndSimulate(planningTask.value.id, {
      expectedProjectUpdatedAt: planningResult.value.projectUpdatedAt,
      mode: 'offline',
      name: `${schema.value?.projectName ?? '容量规划'}最优解全历史仿真`,
      // C-406：目标画布方式（更新当前画布 or 保存为新画布）
      target: applyTarget.value,
      newCanvasName: applyTarget.value === 'new-canvas' ? newCanvasName.value : undefined
    })
    push({
      tone: applyResult.value.taskCreated ? 'success' : 'warning',
      title: applyResult.value.taskCreated ? '最优容量已应用，验证仿真已启动' : '最优容量已应用',
      description: applyResult.value.taskCreated
        ? `仿真任务 ${applyResult.value.taskId?.slice(0, 12) ?? ''}（结果需在任务页确认，不作为已验证结论）`
        : applyResult.value.message
    })
    // C-406：应用后刷新应用记录与项目（服务端已改写画布）
    await loadApplies()
    try {
      const refreshed = await projectApi.getProject(projectId.value)
      project.value = refreshed.project
    }
    catch (error) {
      console.warn('[CapPlan] refresh project after apply failed:', error)
    }
  }
  catch (error) {
    planningError.value = error instanceof Error ? error.message : String(error)
  }
  finally {
    applyingResult.value = false
  }
}

watch(
  () => [
    [...clustering.featureIds].sort().join(','),
    clustering.clusterCount,
    clustering.algorithm,
    clustering.normalize,
    clustering.missingDayThreshold,
    clustering.seed,
    clustering.preserveExtremes
  ],
  () => {
    if (suppressClusteringInvalidation.value) return
    scenarioPreview.value = null
    clustering.scenarioPreviewHash = null
  },
  // 回填任务配置时同步读取抑制标记，避免 watcher 延迟执行后清空刚恢复的预览。
  { flush: 'sync' }
)

watch(
  () => JSON.stringify(objectiveSettings),
  () => {
    objectiveConfirmed.value = false
  }
)

watch(scenarioPreview, async (preview) => {
  disposeScenarioCharts()
  if (!preview || currentStep.value !== 3) return
  await nextTick()
  renderScenarioCharts()
})

watch(
  () => JSON.stringify({
    convergence: liveConvergencePoints.value,
    metrics: liveMetricPoints.value.map(p => p.metrics),
    capacities: capacityChartItems.value,
    status: planningTask.value?.status,
    busy: planningBusy.value
  }),
  async () => {
    if (currentStep.value !== 5) return
    await nextTick()
    renderSolverCharts()
    scrollPlanningLogToEnd()
  }
)

watch(
  () => [
    planningBusy.value,
    planningTask.value?.status,
    planningTask.value?.progress.completedEvaluations,
    planningTask.value?.progress.bestFitness,
    planningCancellationRequested.value,
    planningTask.value?.progress.currentEvaluation,
    planningTask.value?.progress.currentScenario?.index,
    planningTask.value?.progress.currentScenario?.stage,
    planningError.value
  ],
  () => {
    if (currentStep.value === 5) appendCurrentPlanningStatus()
  }
)

// 边界时序数据异步加载完成后，若当前正在预览该边界则重绘图表
watch(boundarySeriesById, async () => {
  if (currentStep.value !== 2 || !selectedBoundaryId.value) return
  await nextTick()
  renderBoundaryPreview()
})

watch(currentStep, async (step) => {
  await nextTick()
  contentScroller.value?.scrollTo({ top: 0, behavior: 'smooth' })
  if (step === 2) {
    // 进入历史边界数据页时确保边界时序数据已加载（首次加载完成后会自动重绘预览）
    await loadBoundarySeries()
    await ensureDefaultBoundaryPreview()
  }
  else if (step !== 2) {
    boundaryPreviewChart?.dispose()
    boundaryPreviewChart = null
  }
  if (step === 3) {
    // 进入步骤三：有已存场景则重绘；无则等用户点「生成」（不自动重算）
    if (scenarioPreview.value) {
      await nextTick()
      renderScenarioCharts()
    }
  }
  else if (step !== 3) disposeScenarioCharts()
  if (step === 5) {
    renderSolverCharts()
    // 步骤五图表容器改为 flex 自适应高度，需在布局完成后再次 resize
    void nextTick().then(() => {
      convergenceChart?.resize()
      capacityChangeChart?.resize()
    })
    startPlanningLogSequence()
  }
  else {
    if (planningLogSequenceTimer) clearTimeout(planningLogSequenceTimer)
    planningLogSequenceTimer = null
    disposeSolverCharts()
  }
})

const resizePlanningCharts = () => {
  boundaryPreviewChart?.resize()
  scenarioCharts.forEach(chart => chart.resize())
  convergenceChart?.resize()
  capacityChangeChart?.resize()
}

onMounted(() => window.addEventListener('resize', resizePlanningCharts))
onBeforeUnmount(() => {
  clearPlanningPoll()
  if (planningLogSequenceTimer) clearTimeout(planningLogSequenceTimer)
  window.removeEventListener('resize', resizePlanningCharts)
  boundaryPreviewChart?.dispose()
  disposeScenarioCharts()
  disposeSolverCharts()
})

await Promise.all([loadSchema(), loadDatasetContext(), loadTaskList()])

// 列表由后端按 createdAt DESC 返回；始终恢复最近创建的任务。
if (taskList.value.length > 0) {
  const pick = taskList.value[0]
  if (pick?.id) {
    await selectTask(pick.id)
  }
}
else {
  showCreateTaskDialog.value = true
}

useHead(() => ({
  title: schema.value ? `${schema.value.projectName} - 容量规划` : '容量规划 - 新能源发电系统灵活性量化评估软件'
}))
</script>

<template>
  <div class="h-screen min-h-[720px] bg-app-bg">
    <header class="flex h-14 items-center border-b border-blue-900/40 bg-primary px-4 shadow-sm">
      <button
        class="inline-flex h-9 items-center gap-2 rounded-md px-3 text-sm font-medium text-white transition hover:bg-white/10"
        type="button"
        @click="navigateTo('/editor/' + projectId)"
      >
        <span class="text-lg leading-none">←</span>
        <span>返回</span>
      </button>
      <div class="ml-4 hidden h-5 w-px bg-white/25 sm:block" />
      <div class="ml-4 hidden min-w-0 truncate text-sm font-medium text-white sm:block">
        {{ schema?.projectName || project?.name || '项目模型' }} - 容量规划
      </div>
      <div class="ml-auto flex items-center gap-2">
        <div v-if="selectedTaskId" class="flex items-center gap-2">
          <span class="text-xs text-white/70">当前任务：</span>
          <span class="rounded bg-white/15 px-2 py-0.5 text-xs font-medium text-white">
            {{ planningTask?.name || selectedTaskId.slice(0, 8) }}
          </span>
          <span class="rounded px-1.5 py-0.5 text-[10px]" :class="`bg-${STATUS_TONE[planningTask?.status || 'draft']}-soft text-${STATUS_TONE[planningTask?.status || 'draft']}`">
            {{ STATUS_LABEL[planningTask?.status || 'draft'] }}
          </span>
        </div>
        <button
          class="inline-flex h-8 items-center rounded-md px-3 text-sm font-medium text-white transition hover:bg-white/10"
          type="button"
          @click="openTaskList"
        >
          任务列表
        </button>
        <button
          class="inline-flex h-8 items-center rounded-md bg-white/20 px-3 text-sm font-medium text-white transition hover:bg-white/30"
          type="button"
          @click="openCreateTask"
        >
          新建任务
        </button>
      </div>
    </header>

    <div class="flex h-[calc(100vh-56px)] min-h-0 gap-2 p-2">
      <div v-if="loading" class="panel-card flex flex-1 items-center justify-center text-sm text-app-muted">
        正在分析画布中的容量设备...
      </div>

      <div v-else-if="errorMessage && !schema" class="panel-card flex flex-1 flex-col items-center justify-center p-8 text-center">
        <div class="text-base font-semibold text-app-danger">容量规划表单加载失败</div>
        <p class="mt-2 max-w-3xl text-sm text-app-muted">{{ errorMessage }}</p>
        <AppButton class="mt-5" label="重试" tone="primary" @click="loadSchema" />
      </div>

      <template v-else-if="schema">
        <aside class="panel-card flex w-72 shrink-0 flex-col overflow-hidden">
          <div class="border-b border-app-border px-5 py-3">
            <h1 class="text-lg font-bold text-app-text">容量规划流程</h1>
          </div>

          <nav class="flex-1 overflow-y-auto px-3 py-3" aria-label="容量规划步骤">
            <template v-for="step in planningSteps" :key="step.id">
              <button
                type="button"
                class="h-[72px] w-full rounded-lg border px-4 py-2.5 text-left transition"
                :class="currentStep === step.id
                  ? 'border-primary bg-primary text-white shadow-md'
                  : 'border-app-border bg-white text-app-text hover:border-primary/40 hover:bg-blue-50/50'"
                :aria-current="currentStep === step.id ? 'step' : undefined"
                @click="selectStep(step.id)"
              >
                <div class="flex h-full items-center gap-3">
                  <span
                    class="flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-bold"
                    :class="currentStep === step.id
                      ? 'bg-white text-primary'
                      : 'bg-app-panel-soft text-app-muted'"
                  >
                    {{ step.id }}
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-base">
                      步骤{{ ['一', '二', '三', '四', '五', '六'][step.id - 1] }}：{{ step.title }}
                      <span
                        v-if="step.id === 3 && showStep3Warning"
                        class="ml-1 inline-flex items-center gap-0.5 text-xs font-semibold"
                        :class="currentStep === step.id ? 'text-amber-200' : 'text-app-warning'"
                        title="边界数据已更新，请重新生成典型场景"
                      >⚠</span>
                    </span>
                  </span>
                </div>
              </button>
              <div v-if="step.id < 6" class="flex h-12 items-center justify-center text-2xl font-black leading-none text-primary/45">
                ↓
              </div>
            </template>
          </nav>

          <div class="border-t border-app-border bg-app-panel-soft px-4 py-3">
            <div class="mt-1 text-sm text-app-muted">{{ activeStep.description }}</div>
          </div>
        </aside>

        <main class="panel-card flex min-w-0 flex-1 flex-col overflow-hidden">
          <!-- 未选中任务时的提示 -->
          <div v-if="!selectedTaskId" class="flex-1 flex flex-col items-center justify-center text-app-muted text-sm gap-4">
            <div class="flex h-16 w-16 items-center justify-center rounded-full bg-app-panel-soft text-3xl">📋</div>
            <div class="text-lg font-medium text-app-text">请先选择或创建一个容量规划任务</div>
            <p class="max-w-md text-center text-sm text-app-muted">容量规划需要基于一个任务进行，任务会保存所有的配置和计算结果。</p>
            <div class="flex gap-3 mt-2">
              <AppButton label="选择任务" tone="primary" @click="openTaskList" />
              <AppButton label="新建任务" tone="neutral" @click="openCreateTask" />
            </div>
          </div>

          <!-- 已选中任务时的内容 -->
          <template v-else>
            <div class="flex items-center justify-between gap-5 border-b border-app-border bg-white px-6 py-4">
              <div>
                <div class="text-xs font-semibold text-primary">步骤 {{ currentStep }} / 6</div>
                <h2 class="mt-0.5 flex items-center gap-2 text-xl font-bold text-app-text">
                  {{ activeStep.title }}
                  <span
                    v-if="currentStep === 3 && showStep3Warning"
                    class="inline-flex items-center rounded bg-app-warning/15 px-2 py-0.5 text-xs font-semibold text-app-warning"
                    title="边界数据已更新，请重新生成典型场景"
                  >⚠ 边界已更新</span>
                </h2>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-xs text-app-muted">任务：</span>
                <span class="rounded bg-primary-soft px-2 py-0.5 text-xs font-medium text-primary">
                  {{ planningTask?.name || selectedTaskId?.slice(0, 8) }}
                </span>
                <span class="rounded px-1.5 py-0.5 text-[10px]" :class="`bg-${STATUS_TONE[planningTask?.status || 'draft']}-soft text-${STATUS_TONE[planningTask?.status || 'draft']}`">
                  {{ STATUS_LABEL[planningTask?.status || 'draft'] }}
                </span>
              </div>
            </div>

            <div ref="contentScroller" class="min-h-0 flex-1 overflow-y-auto bg-app-surface p-5">

            <!-- 边界已更新：提示重新生成聚类（不自动重算） -->
            <div
              v-if="boundariesStale && scenarioPreview"
              class="mb-4 flex flex-wrap items-center gap-3 rounded-lg border border-app-warning/40 bg-orange-50 px-4 py-3"
            >
              <span class="text-sm font-semibold text-app-warning">边界数据已更新，当前典型场景可能已过期</span>
              <span class="text-xs text-app-muted">请重新生成聚类结果后再确认</span>
              <AppButton
                label="去步骤三重新生成"
                tone="primary"
                class="ml-auto"
                @click="selectStep(3)"
              />
            </div>

            <section v-if="currentStep === 1" class="space-y-4">
              <div v-for="warning in schema.warnings" :key="warning" class="rounded-lg border border-app-warning/30 bg-orange-50 px-4 py-3 text-sm text-app-warning">
                {{ warning }}
              </div>

              <div class="overflow-hidden rounded-lg border border-app-border bg-white">
                <div class="flex items-center justify-between border-b border-app-border px-5 py-4">
                  <div>
                    <h3 class="font-semibold text-app-text">容量变量配置</h3>
                  </div>
                  <span class="text-xs text-app-muted">参与容量优化/可规划设备：<span class="font-bold text-primary">{{ optimizedCount }}/{{ variables.length }}</span></span>
                </div>

                <div v-if="variables.length" class="overflow-x-auto">
                  <table class="w-full min-w-[760px] text-center text-sm">
                    <thead class="bg-app-panel-soft text-sm text-center">
                      <tr>
                        <th class="px-4 py-3 font-medium">设备名称</th>
                        <th class="px-4 py-3 font-medium">设备类型</th>
                        <th class="px-4 py-3 font-medium w-1/3">变量设置</th>
                        <th class="px-4 py-3 font-medium w-1/6">参考容量值</th>
                        <th class="px-4 py-3 text-center font-medium">
                          <label class="inline-flex cursor-pointer items-center gap-1.5">
                            <span>参与优化</span>
                            <input type="checkbox" class="h-3.5 w-3.5 cursor-pointer accent-primary" :checked="allOptimized" @change="toggleAllParticipation">
                          </label>
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        v-for="item in variables"
                        :key="item.componentId"
                        class="border-t border-app-border transition-colors"
                        :class="item.mode === 'optimize' ? 'bg-primary-soft/20' : 'text-app-muted'"
                      >
                        <td class="px-4 py-3">
                          <div class="truncate text-sm" :class="item.mode === 'optimize' ? 'text-app-text' : 'text-app-muted'">{{ item.componentName }}</div>
                          <div v-if="item.valueKind && item.valueKind !== 'continuous' || item.groupId || item.mutexGroup || (item.changeKind && item.changeKind !== 'new')" class="mt-1 flex flex-wrap gap-1">
                            <span v-if="item.valueKind && item.valueKind !== 'continuous'" class="rounded bg-app-panel-soft px-1.5 py-0.5 text-[10px] text-app-muted">{{ valueKindLabel(item.valueKind) }}</span>
                            <span v-if="item.changeKind && item.changeKind !== 'new'" class="rounded bg-app-panel-soft px-1.5 py-0.5 text-[10px] text-app-muted">{{ changeKindLabel(item.changeKind) }}</span>
                            <span v-if="item.groupId" class="rounded bg-app-panel-soft px-1.5 py-0.5 text-[10px] text-app-muted">成组 {{ item.groupId }} ×{{ item.groupRatio }}</span>
                            <span v-if="item.mutexGroup" class="rounded bg-app-panel-soft px-1.5 py-0.5 text-[10px] text-app-muted">互斥 {{ item.mutexGroup }}</span>
                          </div>
                        </td>
                        <td class="px-4 py-3 text-xs">{{ item.componentKey }}</td>
                        <td class="px-4 py-3">
                          <div v-if="item.mode === 'optimize'" class="flex items-center gap-2">
                            <div class="shrink-0 w-max">
                              <PropertyNumber
                                :model-value="item.lowerBound"
                                :min="capacitySchemaMin(item)"
                                :max="item.upperBound - capacitySliderStep(item)"
                                :step="item.step ?? undefined"
                                :unit="item.unit"
                                label="下界"
                                @update:model-value="handleBoundChange(item, 'lowerBound', $event)"
                              />
                            </div>
                            <div class="flex-1 min-w-[160px]">
                              <div class="variable-slider">
                                <div class="variable-slider__track">
                                  <div
                                    class="variable-slider__fill"
                                    :style="{ width: ((item.suggestedValue - item.lowerBound) / Math.max(item.upperBound - item.lowerBound, 0.0001) * 100) + '%' }"
                                  />
                                  <input
                                    class="variable-slider__range"
                                    type="range"
                                    :value="item.suggestedValue"
                                    :min="item.lowerBound"
                                    :max="item.upperBound"
                                    :step="capacitySliderStep(item)"
                                    aria-label="容量推荐值"
                                    @input="updateCapacitySuggestion(item, $event)"
                                  >
                                </div>
                                <span class="variable-slider__unit text-xs text-app-muted">{{ item.unit }}</span>
                              </div>
                            </div>
                            <div class="shrink-0 w-max">
                              <PropertyNumber
                                :model-value="item.upperBound"
                                :min="item.lowerBound + capacitySliderStep(item)"
                                :max="capacitySchemaMax(item)"
                                :step="item.step ?? undefined"
                                :unit="item.unit"
                                label="上界"
                                @update:model-value="handleBoundChange(item, 'upperBound', $event)"
                              />
                            </div>
                          </div>
                          <div v-else class="text-xs text-app-muted">固定为 {{ formatNumber(item.currentValue) }} {{ item.unit }}</div>
                        </td>
                        <td class="px-4 py-3">
                          <div v-if="item.mode === 'optimize'" class="w-max mx-auto">
                            <PropertyNumber
                              :model-value="item.suggestedValue"
                              :min="item.lowerBound"
                              :max="item.upperBound"
                              :step="capacitySliderStep(item)"
                              :unit="item.unit"
                              label="推荐值"
                              @update:model-value="handleSuggestedValueChange(item, $event)"
                            />
                          </div>
                          <div v-else class="text-center text-xs text-app-muted">—</div>
                        </td>
                        <td class="px-4 py-3 text-center">
                          <PropertySwitch
                            :model-value="item.mode === 'optimize'"
                            @update:model-value="updateParticipation(item, $event)"
                          />
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
                <div v-else class="px-6 py-12 text-center text-sm text-app-muted">当前画布没有可规划容量的设备。</div>
              </div>

              <div class="flex items-center justify-between rounded-lg border border-app-border bg-white px-4 py-3">
                <div class="text-xs text-app-muted">
                  <span v-if="validatedAt" class="font-semibold text-app-success">✓ 服务端校验通过（{{ validatedAt }}）</span>
                  <span v-else>容量按设备及物理单位分别优化，修改后需要重新校验。</span>
                </div>
                <div class="flex gap-2">
                  <AppButton label="重新识别设备" tone="neutral" :disabled="loading" @click="loadSchema" />
                  <AppButton label="校验并进入下一步" tone="primary" :disabled="validating || !formValid" @click="validateAndContinue" />
                </div>
              </div>
            </section>

            <section v-else-if="currentStep === 2" class="flex min-h-full flex-col gap-4">
              <div class="shrink-0 rounded-lg border border-app-border bg-white">
                <div class="flex items-center justify-between border-b border-app-border px-5 py-4">
                  <div>
                    <h3>边界配置数据</h3>
                  </div>
                  <span class="text-xs text-app-muted">共 {{ planningBoundaries.length }} 项</span>
                </div>
                <div class="overflow-x-auto">
                  <table class="w-full min-w-[760px] text-center text-sm">
                    <thead class="bg-app-panel-soft text-sm text-center">
                      <tr>
                        <th class="px-4 py-3 font-medium">边界名称</th>
                        <th class="px-4 py-3 font-medium">物理含义</th>
                        <th class="px-4 py-3 font-medium">单位</th>
                        <th class="px-4 py-3 font-medium">数据列</th>
                        <th class="px-4 py-3 font-medium">时间步长</th>
                        <th class="px-4 py-3 font-medium">时长（天）</th>
                        <th class="px-4 py-3 font-medium">起止日期</th>
                        <th class="px-4 py-3 font-medium">关联设备</th>
                        <th class="px-4 py-3 font-medium">状态</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        v-for="boundary in planningBoundaries"
                        :key="boundary.id"
                        class="cursor-pointer border-t transition-colors"
                        :class="selectedBoundaryId === boundary.id
                          ? 'border-primary/20 bg-primary-soft/80'
                          : 'border-app-border hover:bg-app-panel-soft/70'"
                        @click="previewBoundary(boundary)"
                      >
                        <td
                          class="relative px-4 py-3 font-medium"
                          :class="selectedBoundaryId === boundary.id ? 'text-primary' : 'text-app-text'"
                        >
                          <span
                            v-if="selectedBoundaryId === boundary.id"
                            class="absolute inset-y-0 left-0 w-1 rounded-r bg-primary"
                            aria-hidden="true"
                          />
                          {{ boundary.name }}
                        </td>
                        <td class="px-4 py-3 text-app-text">{{ BOUNDARY_MEANING_LABELS[boundary.meaning] }}</td>
                        <td class="px-4 py-3 text-app-muted">{{ boundaryUnit(boundary) }}</td>
                        <td class="px-4 py-3 text-app-muted">{{ boundary.columnName || '—' }}</td>
                        <td class="px-4 py-3 text-app-muted">{{ boundary.timeStep || '—' }}</td>
                        <td class="px-4 py-3 text-app-text">{{ boundaryDayCount(boundary) || '—' }}</td>
                        <td class="px-4 py-3 text-app-muted whitespace-nowrap">{{ boundaryDateRange(boundary) }}</td>
                        <td class="max-w-72 px-4 py-3 text-app-muted">
                          <span class="line-clamp-2" :title="boundaryRelatedDeviceNames(boundary)">{{ boundaryRelatedDeviceNames(boundary) }}</span>
                        </td>
                        <td class="px-4 py-3">
                          <span class="rounded-full px-2.5 py-1 text-xs" :class="boundaryPointCount(boundary) ? 'bg-green-50 text-app-success' : 'bg-app-panel-soft text-app-muted'">
                            {{ boundaryPointCount(boundary) ? '已配置' : '待完善' }}
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                  <div v-if="!planningBoundaries.length" class="px-6 py-10 text-center text-sm text-app-muted">当前画布没有已关联组件的边界数据（AGC 等调度目标曲线不参与容量规划）。</div>
                </div>
              </div>

              <div class="flex min-h-[320px] flex-1 flex-col rounded-lg border border-app-border bg-white">
                <div class="flex items-center justify-between border-b border-app-border px-5 py-4">
                  <div>
                    <h3 v-if="selectedBoundary">{{ selectedBoundary.name }}</h3>
                  </div>
                </div>

                <div v-if="selectedBoundary && selectedBoundaryPreviewData" class="min-h-0 flex-1 p-4">
                  <div ref="boundaryPreviewChartRef" class="h-full min-h-[280px] w-full" />
                </div>

                <div v-else class="flex min-h-[280px] flex-1 flex-col items-center justify-center px-6 text-center text-app-muted">
                  <svg class="mb-3 h-10 w-10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                    <path d="M3 3v18h18M7 16l4-4 4 4 5-6" stroke-linecap="round" stroke-linejoin="round" />
                  </svg>
                  <div class="text-sm font-medium">{{ boundarySeriesLoading ? '边界数据加载中…' : selectedBoundary ? '该边界暂无可预览数据' : '数据预览为空' }}</div>
                  <p class="mt-1 text-xs">{{ boundarySeriesLoading ? '正在从边界配置加载已保存的时序数据。' : selectedBoundary ? '请返回边界配置导入并保存数据。' : '点击上方任意边界行即可预览曲线。' }}</p>
                </div>
              </div>

              <div class="mt-auto flex shrink-0 items-center justify-end gap-3 pt-1">
                <span v-if="!allPlanningBoundariesHaveData && planningBoundaries.length" class="text-xs text-app-warning">
                  还有 {{ missingBoundaryDataCount }} 条边界缺少时序数据，补齐后才能确认
                </span>
                <AppButton label="返回边界配置" tone="neutral" @click="goBoundaryConfig" />
                <AppButton
                  label="确认数据，进入典型场景聚类"
                  tone="primary"
                  :disabled="!allPlanningBoundariesHaveData"
                  @click="confirmBoundaryData"
                />
              </div>
            </section>

            <section v-else-if="currentStep === 3" class="space-y-4">
              <div class="rounded-lg border border-app-border bg-white">
                <div class="border-b border-app-border px-5 py-4">
                  <h3 class="">聚类算法配置</h3>
                </div>
                <div class="p-5">
                  <div class="grid grid-cols-[220px_300px_minmax(0,1fr)_auto] items-center gap-5">
                    <label class="flex min-w-0 items-center gap-3">
                      <span class="!mb-0 shrink-0 whitespace-nowrap">典型场景</span>
                      <input v-model.number="clustering.clusterCount" class="field-input min-w-0" type="number" min="2" max="30">
                    </label>
                    <label class="flex min-w-0 items-center gap-3">
                      <span class="!mb-0 shrink-0 whitespace-nowrap">聚类算法</span>
                      <select v-model="clustering.algorithm" class="field-select">
                        <option value="kmeans">K-means</option>
                        <option value="kmedoids">K-medoids</option>
                      </select>
                    </label>
                    <label class="flex min-w-0 items-center gap-3">
                      <span class="!mb-0 shrink-0 whitespace-nowrap">聚类特征</span>
                      <div class="min-w-0 flex-1">
                        <PropertyMultiSelect
                          v-model="clusteringFeatureIdsModel"
                          :options="clusteringFeatureOptions"
                          placeholder="请选择聚类特征（至少一项）"
                        />
                      </div>
                    </label>
                    <AppButton label="生成典型场景" tone="primary" :disabled="datasetLoading || !canPreviewScenarios" @click="previewTypicalDays()" />
                  </div>
                  <label class="mt-4 flex items-start gap-2 text-sm text-app-text">
                    <input v-model="clustering.preserveExtremes" type="checkbox" class="mt-0.5">
                    <span>
                      保留峰荷日和低可再生日
                      <span class="mt-0.5 block text-xs text-app-muted">勾选后负荷特征的峰荷日、风光特征的低可再生日各自成为权重 1 天的场景</span>
                    </span>
                  </label>
                </div>
              </div>

              <div class="rounded-lg border border-app-border bg-white">
                <div class="flex items-center justify-between border-b border-app-border px-5 py-4">
                  <h3 class="flex items-center gap-2">
                    典型场景预览
                    <span
                      v-if="boundariesStale"
                      class="rounded bg-app-warning/15 px-2 py-0.5 text-xs font-semibold text-app-warning"
                    >已过期</span>
                  </h3>
                  <AppButton
                    :label="scenarioChartsNormalized ? '显示原始数据' : '归一化处理'"
                    :tone="scenarioChartsNormalized ? 'primary' : 'neutral'"
                    :disabled="!scenarioPreview"
                    @click="toggleScenarioNormalization"
                  />
                </div>

                <div v-if="scenarioPreview" class="p-5" :class="boundariesStale ? 'opacity-60' : ''">
                  <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-app-muted">
                    <span>有效自然日 <span class="font-medium text-app-text">{{ scenarioPreview.quality.validDayCount }}</span></span>
                    <span class="text-app-border">|</span>
                    <span>排除自然日 <span class="font-medium text-app-text">{{ scenarioPreview.quality.excludedDayCount }}</span></span>
                    <span class="text-app-border">|</span>
                    <span>聚类迭代 <span class="font-medium text-app-text">{{ scenarioPreview.quality.iterations }}</span></span>
                    <span class="text-app-border">|</span>
                    <span>收敛状态 <span class="font-medium" :class="scenarioPreview.quality.converged ? 'text-app-success' : 'text-app-warning'">{{ scenarioPreview.quality.converged ? '已收敛' : '未收敛' }}</span></span>
                  </div>
                  <div class="mt-4 grid grid-cols-2 gap-4">
                    <article v-for="(scenario, scenarioIndex) in sortedScenarios" :key="scenario.scenarioId" class="overflow-hidden rounded-lg border border-app-border bg-white">
                      <div class="flex items-center justify-between gap-4 border-b border-app-border bg-app-panel-soft px-4 py-3">
                        <div>
                          <div class="text-sm">
                            场景 {{ scenarioIndex + 1 }} · 代表日期 {{ formatScenarioDayLabel(scenario.representativeDate) }}
                          </div>
                        </div>
                        <div class="shrink-0 text-right">
                          <div class="rounded-[4px] bg-primary px-3 py-1 text-xs font-semibold text-white">场景加权 {{ (scenario.probability * 100).toFixed(1) }}% / {{ scenario.memberDates.length }} 日</div>
                        </div>
                      </div>
                      <div :ref="element => setScenarioChartRef(scenario.scenarioId, element)" class="h-64 w-full px-2 py-1" />
                    </article>
                  </div>
                </div>

                <div v-else class="flex min-h-56 flex-col items-center justify-center px-6 py-10 text-center">
                  <div class="flex h-12 w-12 items-center justify-center rounded-full bg-app-panel-soft text-2xl text-primary">◌</div>
                  <div class="mt-3 font-medium text-app-text">
                    {{ datasetLoading ? '正在恢复/生成典型场景…' : '等待生成典型场景' }}
                  </div>
                  <p class="mt-1 text-sm text-app-muted">
                    {{ datasetLoading
                      ? '若该任务已生成过聚类结果，会按原参数自动回显。'
                      : '完成上方配置后点击「生成典型场景」；结果会保存到当前任务，下次进入自动加载。' }}
                  </p>
                </div>
              </div>

              <div class="flex items-center justify-between rounded-lg border border-app-border bg-white px-5 py-4">
                <p class="text-xs text-app-muted">请先核对各场景曲线和加权，确认后再进入下一步。</p>
                <AppButton label="确认典型场景，进入规划目标设置" tone="primary" :disabled="!scenarioPreview" @click="confirmTypicalScenarios" />
              </div>
            </section>

            <section v-else-if="currentStep === 4" class="space-y-4">
              <div class="rounded-lg border border-app-border bg-white px-5 py-4">
                <div class="flex items-center gap-5">
                  <h3 class="shrink-0 font-semibold text-app-text">方案目标：</h3>
                  <div class="flex min-w-0 flex-wrap items-center gap-2">
                    <button
                      v-for="option in objectiveOptions"
                      :key="option.value"
                      type="button"
                      class="group relative h-8 rounded-[4px] border px-4 text-sm font-medium transition"
                      :class="objectiveSettings.objective === option.value
                        ? 'border-primary bg-blue-50 text-primary'
                        : 'border-app-border bg-white text-app-text hover:border-primary/50 hover:text-primary'"
                      @click="objectiveSettings.objective = option.value"
                    >
                      {{ option.label }}
                      <span
                        class="pointer-events-none absolute left-1/2 top-full z-40 mt-2 w-80 -translate-x-1/2 whitespace-pre-line rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100"
                      >
                        {{ option.tip }}
                      </span>
                    </button>
                  </div>
                </div>
              </div>

              <div class="rounded-none border border-app-border bg-white">
                <div class="border-b border-app-border px-5 py-4">
                  <h3
                    class="group relative font-semibold text-app-text"
                  >
                    技术性约束
                    <span class="pointer-events-none absolute left-0 top-full z-40 mt-2 w-80 rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100">未达标按「技术约束惩罚系数」计入 fitness（软约束），不直接判定不可行。</span>
                  </h3>
                </div>
                <div class="grid grid-cols-[repeat(auto-fit,minmax(min(21rem,100%),1fr))] gap-3 p-4">
                  <div
                    v-for="item in technicalConstraintItems"
                    :key="item.key"
                    class="grid min-w-0 grid-cols-[minmax(0,1fr)_auto_5rem_auto_auto] items-center gap-2 rounded-none border border-app-border px-3 py-2"
                    :class="objectiveSettings.technicalConstraints[item.key].enabled ? 'border-primary/40 bg-blue-100/50' : 'border-app-border bg-white'"
                  >
                    <span
                      class="group relative min-w-0 whitespace-nowrap text-sm font-medium text-app-text"
                    >
                      {{ item.label }}
                      <span
                        class="pointer-events-none absolute left-0 top-full z-40 mt-2 w-80 rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100"
                      >
                        {{ item.tip }}
                      </span>
                    </span>
                    <span class="shrink-0 whitespace-nowrap text-xs text-app-muted">{{ item.hint }}</span>
                    <div class="w-20 shrink-0">
                      <input
                        v-model.number="objectiveSettings.technicalConstraints[item.key].threshold"
                        class="field-input"
                        type="number"
                        min="0"
                        max="100"
                        step="0.1"
                        :disabled="!objectiveSettings.technicalConstraints[item.key].enabled"
                      >
                    </div>
                    <span class="w-6 shrink-0 whitespace-nowrap text-sm text-app-muted">%</span>
                    <label class="inline-flex shrink-0 cursor-pointer items-center gap-1.5 whitespace-nowrap text-xs text-app-muted">
                      <input v-model="objectiveSettings.technicalConstraints[item.key].enabled" class="field-checkbox" type="checkbox">
                      启用
                    </label>
                  </div>
                </div>
              </div>

              <div class="rounded-none border border-app-border bg-white">
                <div class="border-b border-app-border px-5 py-4">
                  <h3
                    class="group relative font-semibold text-app-text"
                  >
                    经济性参数
                    <span class="pointer-events-none absolute left-0 top-full z-40 mt-2 w-80 rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100">用于计算生命周期现金流与 NPV/IRR/LCOE；税率比例按小数写入后端。</span>
                  </h3>
                </div>

                <div class="border-b border-app-border px-5 py-4">
                  <div
                    class="group relative mb-3 text-sm font-medium text-app-text"
                  >
                    核心评价参数
                    <span class="pointer-events-none absolute left-0 top-full z-40 mt-2 w-80 rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100">运营期/折现率/所得税率直接影响 NPV·IRR·LCOE；最低 IRR 为经济约束惩罚。</span>
                  </div>
                  <div class="grid grid-cols-2 gap-3 xl:grid-cols-4">
                    <div
                      v-for="item in economicCoreItems"
                      :key="item.key"
                      class="flex items-center gap-2 rounded-none border border-app-border bg-white px-3 py-2"
                    >
                      <span
                        class="group relative w-[7.5rem] shrink-0 whitespace-nowrap text-sm font-medium text-app-text"
                      >
                        {{ item.label }}
                        <span
                          class="pointer-events-none absolute left-0 top-full z-40 mt-2 w-80 rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100"
                        >
                          {{ item.tip }}
                        </span>
                      </span>
                      <span class="min-w-0 flex-1 truncate text-xs text-app-muted">{{ item.hint }}</span>
                      <div class="w-20 shrink-0">
                        <input
                          v-model.number="objectiveSettings.economicConstraints[item.key].threshold"
                          class="field-input"
                          type="number"
                          :min="item.min"
                          :max="item.max"
                          :step="item.step"
                        >
                      </div>
                      <span class="w-8 shrink-0 whitespace-nowrap text-sm text-app-muted">{{ item.suffix }}</span>
                    </div>
                  </div>
                </div>

                <div
                  v-for="group in lifecycleParamGroups"
                  :key="group.title"
                  class="border-b border-app-border px-5 py-4 last:border-b-0"
                >
                  <div class="group relative mb-1 flex items-baseline gap-2">
                    <div
                      class="text-sm font-medium text-app-text"
                    >
                      {{ group.title }}
                      <span
                        class="pointer-events-none absolute left-0 top-full z-40 mt-1 w-80 rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100"
                      >
                        {{ group.hint }}
                      </span>
                    </div>
                    <div class="text-xs text-app-muted">{{ group.hint }}</div>
                  </div>
                  <div class="grid grid-cols-2 gap-3 xl:grid-cols-4">
                    <div
                      v-for="item in group.items"
                      :key="item.key"
                      class="flex items-center gap-2 rounded-none border border-app-border bg-white px-3 py-2"
                    >
                      <span
                        class="group relative w-[7.5rem] shrink-0 whitespace-nowrap text-sm font-medium text-app-text"
                      >
                        {{ item.label }}
                        <span
                          v-if="'tip' in item && item.tip"
                          class="pointer-events-none absolute left-0 top-full z-40 mt-2 w-80 rounded-md border border-primary bg-primary px-3 py-2 text-left text-xs font-normal leading-5 text-white opacity-0 shadow-lg transition-opacity duration-150 group-hover:opacity-100"
                        >
                          {{ item.tip }}
                        </span>
                      </span>
                      <span v-if="'hint' in item && item.hint" class="min-w-0 flex-1 truncate text-xs text-app-muted">{{ item.hint }}</span>
                      <span v-else class="min-w-0 flex-1" />
                      <div class="w-20 shrink-0">
                        <input
                          v-model.number="objectiveSettings.lifecycle[item.key]"
                          class="field-input"
                          type="number"
                          :min="item.min"
                          :max="item.max"
                          :step="item.step"
                        >
                      </div>
                      <span class="min-w-[3.25rem] shrink-0 whitespace-nowrap text-xs text-app-muted">{{ item.suffix }}</span>
                    </div>
                  </div>
                </div>
              </div>

              <div class="flex items-center justify-between rounded-lg border border-app-border bg-white px-5 py-4">
                <p class="text-sm text-app-muted">方案目标、技术性约束与经济性参数将随容量规划任务保存。</p>
                <AppButton label="确认当前目标，进入求解设置" tone="primary" :disabled="!objectiveSettingsValid" @click="confirmObjective" />
              </div>
            </section>

            <section v-else-if="currentStep === 5" class="flex h-full min-h-0 flex-col gap-4">
              <div class="flex-none rounded-lg border border-app-border bg-white p-5">
                <div class="grid grid-cols-[minmax(160px,1.2fr)_repeat(3,minmax(0,1fr))_auto_auto] items-center gap-4">
                  <label class="flex min-w-0 items-center gap-3">
                    <span class="!mb-0 shrink-0 whitespace-nowrap">求解算法</span>
                    <select v-model="optimizer.method" class="field-select min-w-0">
                      <option v-for="option in optimizerMethodOptions" :key="option.value" :value="option.value" :title="option.tip">
                        {{ option.label }}
                      </option>
                    </select>
                  </label>
                  <label class="flex min-w-0 items-center gap-3"><span class="!mb-0 shrink-0 whitespace-nowrap">最大评价次数</span><input v-model.number="optimizer.maxFuncEvals" class="field-input min-w-0" type="number" min="2" max="10000"></label>
                  <label class="flex min-w-0 items-center gap-3"><span class="!mb-0 shrink-0 whitespace-nowrap">种群规模</span><input v-model.number="optimizer.populationSize" class="field-input min-w-0" type="number" min="2" max="500"></label>
                  <label class="flex min-w-0 items-center gap-3"><span class="!mb-0 shrink-0 whitespace-nowrap" title="计算预算不含工作进程启动和 Julia 编译时间">最长计算时间（秒）</span><input v-model.number="optimizer.maxTimeSeconds" class="field-input min-w-0" type="number" min="1"></label>
                  <AppButton class="whitespace-nowrap" label="启动容量规划" tone="primary" :disabled="!canStartPlanning" @click="createAndStartPlanning" />
                  <AppButton class="whitespace-nowrap" :label="planningCancellationRequested ? '正在终止…' : '终止计算'" tone="danger" :disabled="!planningActive || planningBusy || planningCancellationRequested" @click="cancelPlanning" />
                </div>
              </div>

              <div class="grid min-h-0 flex-1 grid-cols-[330px_minmax(0,1fr)] items-stretch gap-4">
                <div class="flex min-h-0 flex-col">
                  <div class="flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg border border-app-border bg-white">
                    <div class="flex items-start justify-between gap-3 border-b border-app-border px-4 py-3">
                      <div class="min-w-0">
                        <h3 class="text-sm font-semibold text-app-text">容量规划运行日志</h3>
                      </div>
                      <div
                        class="inline-flex shrink-0 items-center gap-2 rounded-full px-2.5 py-1 text-xs font-semibold"
                        :class="{
                          'bg-orange-50 text-app-warning': solverIndicator.tone === 'checking',
                          'bg-blue-50 text-primary': solverIndicator.tone === 'running',
                          'bg-green-50 text-app-success': solverIndicator.tone === 'completed',
                          'bg-red-50 text-app-danger': solverIndicator.tone === 'failed',
                          'bg-app-panel-soft text-app-muted': solverIndicator.tone === 'ready' || solverIndicator.tone === 'cancelled'
                        }"
                      >
                        <span
                          class="h-2 w-2 rounded-full"
                          :class="{
                            'animate-pulse bg-app-warning': solverIndicator.tone === 'checking',
                            'animate-pulse bg-primary': solverIndicator.tone === 'running',
                            'bg-app-success': solverIndicator.tone === 'completed',
                            'bg-app-danger': solverIndicator.tone === 'failed',
                            'bg-app-muted': solverIndicator.tone === 'ready' || solverIndicator.tone === 'cancelled'
                          }"
                        />
                        {{ solverIndicator.label }}
                      </div>
                    </div>

                    <div ref="planningLogRef" class="min-h-0 flex-1 overflow-y-auto px-4 py-2 text-xs">
                      <div class="relative z-10">
                        <div v-for="(entry, index) in planningLogFeed" :key="entry.id" class="planning-log-line flex gap-3 border-b border-app-border/70 py-3 last:border-b-0">
                          <span
                            class="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[10px] font-bold shadow-sm"
                            :class="entry.state === 'done' ? 'bg-emerald-500 text-white' : entry.state === 'active' ? 'bg-blue-500 text-white' : entry.state === 'error' ? 'bg-red-500 text-white' : 'bg-gray-300 text-gray-600'"
                          >{{ entry.state === 'done' ? '✓' : entry.state === 'active' ? 'i' : entry.state === 'error' ? '!' : index + 1 }}</span>
                          <div class="min-w-0 flex-1">
                            <div class="flex items-start justify-between gap-2">
                              <div class="font-medium" :class="entry.state === 'error' ? 'text-app-danger' : entry.state === 'pending' ? 'text-app-muted' : 'text-app-text'">{{ entry.title }}</div>
                              <time class="shrink-0 text-[10px] text-app-muted/75">{{ entry.time }}</time>
                            </div>
                            <div class="mt-1 leading-5 text-app-muted">{{ entry.detail }}</div>
                          </div>
                        </div>
                      </div>
                      <div class="planning-thinking relative z-10 mt-2 flex items-center gap-2 rounded-md border border-primary/15 bg-white/70 px-3 py-2 text-primary shadow-sm backdrop-blur-sm">
                        <span class="planning-thinking-dot" />
                        <span class="planning-thinking-dot" />
                        <span class="planning-thinking-dot" />
                        <span class="ml-4 min-w-0 flex-1 truncate">{{ solverThinkingText }}</span>
                      </div>
                      <div v-if="planningError && planningTask?.status !== 'failed' && planningTask?.status !== 'cancelled'" class="relative z-10 mt-2 border-t border-app-danger/20 py-3 text-app-danger">[错误] {{ planningError }}</div>
                    </div>

                    <div class="flex-none border-t border-app-border px-4 py-3">
                      <div class="h-1.5 overflow-hidden rounded-full bg-app-panel-soft">
                        <div class="h-full rounded-full bg-primary transition-all duration-300" :style="{ width: progressPercent + '%' }" />
                      </div>
                      <div class="mt-2 text-right text-xs text-app-muted">{{ planningTask?.progress.completedEvaluations ?? 0 }} / {{ planningTask?.progress.maxFuncEvals ?? optimizer.maxFuncEvals }} 次评价 · {{ progressPercent }}%</div>
                    </div>
                  </div>
                </div>

                <div class="flex min-h-0 flex-col gap-4">
                <div class="flex min-h-0 flex-[2] flex-col overflow-hidden rounded-lg border border-app-border bg-white">
                  <div class="flex-none border-b border-app-border px-4 py-3">
                    <div class="flex items-center justify-between gap-3">
                      <h3 class="text-sm font-semibold text-app-text">
                        实时指标收敛曲线
                        <span v-if="liveMetricCards?.ordinal" class="ml-2 text-xs font-normal text-app-muted">第 {{ liveMetricCards.ordinal }} 次评价</span>
                      </h3>
                      <div class="flex flex-wrap items-center justify-end gap-1.5 text-[10px]">
                        <span v-if="liveMetricCards?.hasPenalty" class="rounded-full bg-red-50 px-2 py-0.5 text-app-danger">本次评价含约束惩罚</span>
                        <span v-else class="rounded-full bg-emerald-50 px-2 py-0.5 text-app-success">本次评价无惩罚</span>
                      </div>
                    </div>
                    <div v-if="liveMetricCards" class="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-xs sm:grid-cols-3 lg:grid-cols-6">
                      <div>
                        <div class="text-app-muted">适应度</div>
                        <div class="font-semibold text-primary">
                          {{ liveMetricCards.fitness.value == null ? '—' : formatNumber(liveMetricCards.fitness.value) }}
                          <span v-if="liveMetricCards.fitness.trend" class="ml-0.5" :class="liveMetricCards.fitness.trendTone" aria-hidden="true">{{ liveMetricCards.fitness.trend === 'up' ? '↑' : '↓' }}</span>
                        </div>
                      </div>
                      <div>
                        <div class="text-app-muted">目标函数</div>
                        <div class="font-semibold text-primary">
                          {{ liveMetricCards.objectiveFitness.value == null ? '—' : formatNumber(liveMetricCards.objectiveFitness.value) }}
                          <span v-if="liveMetricCards.objectiveFitness.trend" class="ml-0.5" :class="liveMetricCards.objectiveFitness.trendTone" aria-hidden="true">{{ liveMetricCards.objectiveFitness.trend === 'up' ? '↑' : '↓' }}</span>
                        </div>
                      </div>
                      <div>
                        <div class="text-app-muted">总投资成本</div>
                        <div class="font-semibold text-primary">
                          {{ formatWanInteger(liveMetricCards.lifecycleCapexWan.value) }}
                          <span v-if="liveMetricCards.lifecycleCapexWan.trend" class="ml-0.5" :class="liveMetricCards.lifecycleCapexWan.trendTone" aria-hidden="true">{{ liveMetricCards.lifecycleCapexWan.trend === 'up' ? '↑' : '↓' }}</span>
                        </div>
                      </div>
                      <div>
                        <div class="text-app-muted">总运行成本</div>
                        <div class="font-semibold text-primary">
                          {{ formatWanInteger(liveMetricCards.weightedOperatingCost.value == null ? null : liveMetricCards.weightedOperatingCost.value / 10000) }}
                          <span v-if="liveMetricCards.weightedOperatingCost.trend" class="ml-0.5" :class="liveMetricCards.weightedOperatingCost.trendTone" aria-hidden="true">{{ liveMetricCards.weightedOperatingCost.trend === 'up' ? '↑' : '↓' }}</span>
                        </div>
                      </div>
                      <div>
                        <div class="text-app-muted">内部收益率 IRR</div>
                        <div class="font-semibold text-primary">
                          {{ liveMetricCards.irr.value == null ? '—' : formatPercent(liveMetricCards.irr.value) }}
                          <span v-if="liveMetricCards.irr.trend" class="ml-0.5" :class="liveMetricCards.irr.trendTone" aria-hidden="true">{{ liveMetricCards.irr.trend === 'up' ? '↑' : '↓' }}</span>
                        </div>
                      </div>
                      <div>
                        <div class="text-app-muted">LCOE</div>
                        <div class="font-semibold text-primary">
                          {{ liveMetricCards.lcoe.value == null ? '—' : formatYuanPerKwh(liveMetricCards.lcoe.value) }}
                          <span v-if="liveMetricCards.lcoe.trend" class="ml-0.5" :class="liveMetricCards.lcoe.trendTone" aria-hidden="true">{{ liveMetricCards.lcoe.trend === 'up' ? '↑' : '↓' }}</span>
                        </div>
                      </div>
                    </div>
                  </div>
                  <div ref="convergenceChartRef" class="min-h-0 w-full flex-1 px-2 py-1" />
                </div>

                <div class="flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg border border-app-border bg-white">
                  <div class="flex flex-none items-center justify-between border-b border-app-border px-4 py-3">
                    <div>
                      <h3 class="text-sm font-semibold text-app-text">容量配置参数变化</h3>
                    </div>
                    <span class="rounded-[4px] bg-primary-soft px-3 py-1 text-xs font-medium text-primary">待优化变量：{{ capacityChartItems.length }}</span>
                  </div>
                  <div ref="capacityChangeChartRef" class="min-h-0 w-full flex-1 px-2 py-1" />
                </div>
                </div>
              </div>
            </section>

            <section v-else class="space-y-4">
              <template v-if="planningResult">
                <!-- 上区：最优容量配置结果（指标 + 前后对比） -->
                <div class="rounded-lg border border-app-border bg-white p-4 space-y-4">
                  <div class="flex items-center justify-between">
                    <h3 class="text-sm font-semibold text-app-text">最优容量配置结果</h3>
                    <span class="rounded-full bg-primary px-2.5 py-0.5 text-xs font-semibold text-white">最优方案</span>
                  </div>
                <!-- 指标卡片：与系统灵活性评价同风格 -->
                  <div class="grid grid-cols-2 gap-2 lg:grid-cols-4">
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">最优适应度</div>
                      <div class="mt-1 text-base font-semibold text-primary">{{ formatNumber(planningResult.fitness) }}</div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">候选评价 / 失败</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ planningResult.evaluationCount }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        <span :class="planningResult.failedEvaluationCount ? 'text-app-warning' : 'text-app-success'">{{ planningResult.failedEvaluationCount }}</span>
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">目标项 / 约束惩罚</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatNumber(Number(fitnessBreakdown.objectiveFitness ?? planningResult.fitness)) }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        <span :class="Number(fitnessBreakdown.constraintPenalty ?? 0) > 0 ? 'text-app-warning' : 'text-app-muted'">{{ formatNumber(Number(fitnessBreakdown.constraintPenalty ?? 0)) }}</span>
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">年加权运行成本</div>
                      <div class="mt-1 text-base font-semibold text-app-text">{{ formatNumber(Number(fitnessBreakdown.weightedOperatingCost ?? 0)) }} <span class="text-xs font-normal text-app-muted">元</span></div>
                    </div>
                  </div>

                  <div class="grid grid-cols-2 gap-2 lg:grid-cols-4">
                    <div v-for="item in technicalMetricsRows" :key="item.key" class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">{{ item.label }}</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ item.value }}%
                        <span class="text-xs font-normal text-app-muted">（罚</span>
                        <span class="text-xs font-semibold" :class="item.penalty > 0 ? 'text-app-warning' : 'text-app-muted'">{{ formatNumber(item.penalty) }}</span>
                        <span class="text-xs font-normal text-app-muted">）</span>
                      </div>
                    </div>
                  </div>

                  <div v-if="lifecycleAvailable" class="grid grid-cols-2 gap-2 lg:grid-cols-4">
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">NPV（税后）/ IRR</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatYuanYi(lifecycleIndicators?.npv) }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        {{ formatPercent(lifecycleIndicators?.irr) }}
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">LCOE / 回收期（折现）</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatYuanPerKwh(lifecycleIndicators?.lcoe) }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        {{ formatYears(lifecycleBreakdown.lifecycleDiscountedPaybackYears ?? lifecycleBreakdown.lifecyclePaybackYears) }}
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">建设投资（含增值税）</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatWanYi(lifecycleBreakdown.lifecycleCapexWan) }}
                        <span class="text-xs font-normal text-app-muted">（税 {{ formatWanYi(lifecycleBreakdown.lifecycleConstructionVatWan) }}）</span>
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">折现总成本 / 流动资金</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatWanYi(lifecycleBreakdown.lifecycleDiscountedCostWan) }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        {{ formatWanYi(lifecycleBreakdown.lifecycleWorkingCapitalWan) }}
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">年折旧 / 年调整所得税</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatWanYi(lifecycleBreakdown.lifecycleAnnualDepreciationWan) }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        {{ formatWanYi(lifecycleBreakdown.lifecycleAnnualAdjustedTaxWan) }}
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">重置投资 / 处置回收</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatWanYi(lifecycleBreakdown.lifecycleReplaceCapexTotalWan) }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        {{ formatWanYi(lifecycleBreakdown.lifecycleDisposalRecoveryWan) }}
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">年固定运维 / 年补贴</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatWanYi(lifecycleBreakdown.lifecycleAnnualFixedOmWan) }}
                        <span class="text-xs font-normal text-app-muted">/</span>
                        {{ formatWanYi(lifecycleBreakdown.lifecycleAnnualSubsidyWan) }}
                      </div>
                    </div>
                    <div class="rounded-lg bg-app-panel-soft px-3 py-3">
                      <div class="text-sm text-app-muted">税后 NPV（万元）</div>
                      <div class="mt-1 text-base font-semibold text-app-text">
                        {{ formatNumber(Number(lifecycleBreakdown.lifecycleNpvAfterTaxWan ?? 0)) }}
                      </div>
                    </div>
                  </div>

                  <div v-if="resultErrorWarnings.length" class="space-y-2">
                    <div v-for="warning in resultErrorWarnings" :key="warning" class="rounded-lg border border-app-danger/30 bg-red-50 px-4 py-3 text-xs text-app-danger">{{ warning }}</div>
                  </div>

                  <div class="overflow-x-auto rounded-lg border border-app-border bg-white">
                    <div class="flex items-center justify-between border-b border-app-border px-5 py-4"><div><h3 class="font-semibold text-app-text">优化前后容量对比</h3></div></div>
                    <table class="w-full min-w-[850px] text-left text-sm">
                      <thead class="bg-app-panel-soft text-xs text-app-muted">
                        <tr><th class="px-4 py-3 font-medium">设备</th><th class="px-4 py-3 font-medium">设备类型</th><th class="px-4 py-3 font-medium">优化前</th><th class="bg-blue-50 px-4 py-3 font-semibold text-primary">优化后</th><th class="px-4 py-3 font-medium">容量变化</th><th class="px-4 py-3 font-medium">变化率</th><th class="px-4 py-3 font-medium">规划方式</th></tr>
                      </thead>
                      <tbody>
                        <tr v-for="item in planningResult.variables" :key="item.componentId" class="border-t border-app-border">
                          <td class="px-4 py-4 font-semibold text-app-text">{{ item.componentName }}</td>
                          <td class="px-4 py-4 text-app-muted">{{ item.componentKey }}</td>
                          <td class="px-4 py-4 text-app-text">{{ formatNumber(item.currentValue) }} {{ item.unit }}</td>
                          <td class="bg-blue-50/60 px-4 py-4 text-base font-bold text-primary">{{ formatNumber(item.optimalValue) }} {{ item.unit }}</td>
                          <td class="px-4 py-4" :class="item.optimalValue > item.currentValue ? 'text-app-success' : item.optimalValue < item.currentValue ? 'text-app-warning' : 'text-app-muted'">{{ item.optimalValue >= item.currentValue ? '+' : '' }}{{ formatNumber(item.optimalValue - item.currentValue) }} {{ item.unit }}</td>
                          <td class="px-4 py-4" :class="(item.changeRate ?? 0) > 0 ? 'text-app-success' : (item.changeRate ?? 0) < 0 ? 'text-app-warning' : 'text-app-muted'">{{ item.changeRate === null ? '基准为 0' : ((item.changeRate >= 0 ? '+' : '') + (item.changeRate * 100).toFixed(2) + '%') }}</td>
                          <td class="px-4 py-4 text-app-muted">{{ item.mode === 'optimize' ? '参与优化' : '固定' }}</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>

                </div>

                <!-- 中下区：迭代回溯 + 方案明细（全量清单仅 CSV） -->
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <h3 class="text-sm font-semibold text-app-text">寻优过程与方案明细</h3>
                  </div>
                  <AppButton
                    v-if="comparison"
                    label="导出完整清单"
                    tone="neutral"
                    @click="exportComparisonCsv"
                  />
                </div>
                <IterationCandidatesPanel
                  v-if="comparison"
                  :comparison="comparison"
                />
                <div v-else-if="comparisonLoading" class="rounded-lg border border-dashed border-app-border bg-white px-5 py-6 text-center text-sm text-app-muted">正在生成方案比较…</div>
                <div v-else-if="comparisonError" class="rounded-lg border border-app-warning/30 bg-orange-50 px-5 py-4 text-xs text-app-warning">方案比较生成失败：{{ comparisonError }}</div>

                <!-- C-406 应用记录：来源溯源 + 撤销/恢复 -->
                <div v-if="applyRecords.length" class="overflow-hidden rounded-lg border border-app-border bg-white">
                  <div class="flex items-center justify-between border-b border-app-border px-5 py-4">
                    <div>
                      <h3 class="font-semibold text-app-text">应用记录</h3>
                    </div>
                  </div>
                  <div class="divide-y divide-app-border">
                    <div v-for="record in applyRecords" :key="record.applyId" class="px-5 py-3">
                      <div class="flex flex-wrap items-center justify-between gap-2">
                        <div class="text-sm">
                          <span class="font-semibold text-app-text">{{ record.createdAt.slice(0, 19).replace('T', ' ') }}</span>
                          <span class="ml-2 text-xs text-app-muted">
                            {{ record.target === 'new-canvas' ? `新画布（${record.newCanvasName ?? record.targetCanvasId.slice(0, 8)}）` : '更新当前画布' }}
                            · 候选 #{{ record.candidateId ?? '—' }} · {{ record.changes.length }} 项变更
                          </span>
                          <span
                            class="ml-2 rounded-full px-2 py-0.5 text-xs"
                            :class="record.status === 'applied' ? 'bg-emerald-100 text-emerald-700' : 'bg-app-panel-soft text-app-muted'"
                          >{{ record.status === 'applied' ? '已应用' : '已撤销' }}</span>
                        </div>
                        <div class="flex items-center gap-2">
                          <AppButton
                            v-if="record.status === 'applied'"
                            label="撤销"
                            tone="neutral"
                            :disabled="Boolean(applyActionPending)"
                            @click="undoApplyRecord(record.applyId)"
                          />
                          <AppButton
                            v-else
                            label="恢复"
                            tone="primary"
                            :disabled="Boolean(applyActionPending)"
                            @click="redoApplyRecord(record.applyId)"
                          />
                        </div>
                      </div>
                      <p class="mt-1 text-xs text-app-muted">
                        变更：<template v-for="(change, index) in record.changes" :key="change.componentId">{{ index > 0 ? '；' : '' }}{{ change.componentName }} {{ formatNumber(change.previousValue) }}→{{ formatNumber(change.appliedValue) }} {{ change.unit }}</template>
                      </p>
                      <p v-if="record.taskId" class="mt-1 text-xs text-app-muted">验证仿真任务 {{ record.taskId.slice(0, 12) }}…（结果需在任务页确认）</p>
                    </div>
                  </div>
                </div>

                <div class="rounded-lg border border-green-200 bg-green-50 p-5">
                  <div class="flex items-end justify-between gap-8">
                    <div>
                      <h3 class="font-semibold text-app-text">应用最优容量并启动滚动优化求解</h3>
                      <p class="mt-1 max-w-3xl text-xs leading-5 text-app-muted">系统会校验项目版本，一次性把上表最优容量写回模型，再使用完整历史边界数据启动多时间尺度滚动求解。</p>
                      <div v-if="applyResult" class="mt-3 rounded-md border border-green-200 bg-white px-4 py-3 text-sm">
                        <div class="font-semibold" :class="applyResult.taskCreated ? 'text-app-success' : 'text-app-warning'">
                          {{ applyResult.taskCreated
                            ? `最优容量已写入画布「${applyTargetCanvasName || applyResult.targetCanvasId}」，验证仿真任务已创建`
                            : '最优容量已写入画布，但验证任务创建失败' }}
                        </div>
                        <div class="mt-1 text-xs text-app-muted">
                          目标：{{ applyResult.target === 'new-canvas' ? '新画布' : '当前画布' }} · 应用记录 {{ applyResult.applyId?.slice(0, 12) }}… · {{ applyResult.simStartTime }} 至 {{ applyResult.simEndTime }}
                        </div>
                        <p class="mt-1 text-xs text-app-muted">验证仿真结果需在任务页确认，不作为已验证结论。</p>
                        <p v-if="applyResult.message" class="mt-1 text-xs text-app-warning">{{ applyResult.message }}</p>
                      </div>
                    </div>
                    <div class="flex shrink-0 flex-col items-end gap-2">
                      <AppButton label="配置最优容量并启动滚动求解" tone="green" :disabled="applyingResult || applyPreviewLoading || Boolean(applyResult?.projectApplied)" @click="requestApply" />
                      <button v-if="applyResult?.taskCreated" type="button" class="text-xs font-medium text-primary hover:underline" @click="navigateTo('/tasks')">查看滚动求解任务 →</button>
                    </div>
                  </div>
                </div>
              </template>

              <div v-else class="flex min-h-[480px] flex-col items-center justify-center rounded-lg border border-dashed border-app-border bg-white px-8 text-center">
                <div class="flex h-14 w-14 items-center justify-center rounded-full bg-app-panel-soft text-3xl text-primary">◇</div>
                <h3 class="mt-4 text-lg font-semibold text-app-text">尚未生成容量配置方案</h3>
                <p class="mt-2 max-w-xl text-sm leading-6 text-app-muted">完成求解后，这里会显示最优指标、优化前后容量对比，以及将方案应用到模型的操作。</p>
                <AppButton class="mt-5" label="前往求解设置" tone="primary" @click="selectStep(5)" />
              </div>
            </section>
          </div>
          </template>
        </main>
      </template>
    </div>

    <!-- 应用前确认弹窗（C-101：应用前展示节点容量差异） -->
    <AppModal
      :open="showApplyConfirmDialog"
      title="确认应用最优容量"
      size="lg"
      @close="cancelApply"
    >
      <div class="px-2 py-1">
        <p class="mb-3 text-sm leading-6 text-app-muted">
          将容量方案写入画布「<span class="font-semibold text-app-text">{{ applyPreviewCanvasName }}</span>」。自动创建一条全历史验证仿真任务，结果需在任务页确认。
        </p>
        <p v-if="applyPreview?.candidateId != null" class="mb-3 text-xs text-app-muted">
          来源：规划任务 {{ applyPreview?.planningId.slice(0, 12) }}… - 最优候选评价 #{{ applyPreview?.candidateId }}
        </p>
        <!-- C-406：目标画布方式 -->
        <div class="mb-3 flex gap-4 rounded-lg border border-app-border px-4 py-3 text-sm">
          <label class="flex cursor-pointer items-center gap-2">
            <input v-model="applyTarget" type="radio" value="current-canvas" class="accent-primary" />
            <span class="text-app-text">更新当前画布</span>
          </label>
          <label class="flex cursor-pointer items-center gap-2">
            <input v-model="applyTarget" type="radio" value="new-canvas" class="accent-primary" />
            <span class="text-app-text">保存为新画布</span>
          </label>
          <input
            v-if="applyTarget === 'new-canvas'"
            v-model="newCanvasName"
            type="text"
            :placeholder="`${applyPreviewCanvasName}-容量方案`"
            class="min-w-0 flex-1 rounded-md border border-app-border px-3 py-1 text-sm outline-none focus:border-primary"
          />
        </div>
        <div class="max-h-80 overflow-y-auto rounded-lg border border-app-border">
          <table class="w-full text-left text-sm">
            <thead class="bg-app-panel-soft text-xs text-app-muted">
              <tr>
                <th class="px-4 py-2 font-medium">设备</th>
                <th class="px-4 py-2 font-medium">当前容量</th>
                <th class="px-4 py-2 font-semibold text-primary">应用后</th>
                <th class="px-4 py-2 font-medium">变化</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="item in applyPreview?.variables ?? []" :key="item.componentId" class="border-t border-app-border">
                <td class="px-4 py-2 font-semibold text-app-text">{{ item.componentName }}</td>
                <td class="px-4 py-2 text-app-muted">{{ formatNumber(item.currentValue) }} {{ item.unit }}</td>
                <td class="px-4 py-2 font-bold text-primary">{{ formatNumber(item.optimalValue) }} {{ item.unit }}</td>
                <td class="px-4 py-2" :class="item.optimalValue > item.currentValue ? 'text-app-success' : item.optimalValue < item.currentValue ? 'text-app-warning' : 'text-app-muted'">{{ item.optimalValue >= item.currentValue ? '+' : '' }}{{ formatNumber(item.optimalValue - item.currentValue) }} {{ item.unit }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="mt-4 flex justify-end gap-2">
          <AppButton label="取消" tone="neutral" @click="cancelApply" />
          <AppButton label="确认应用并启动求解" tone="green" :disabled="applyingResult" @click="confirmApply" />
        </div>
      </div>
    </AppModal>

    <!-- 任务列表弹窗 -->
    <AppModal
      :open="showTaskListDialog"
      title="容量规划任务列表"
      size="lg"
      @close="showTaskListDialog = false"
    >
      <div class="px-2 py-1">
        <div class="max-h-96 overflow-y-auto">
          <div v-if="taskListLoading" class="p-4 text-center text-sm text-app-muted">
            加载中...
          </div>
          <div v-else-if="taskList.length === 0" class="p-4 text-center text-sm text-app-muted">
            暂无规划任务
          </div>
          <table v-else class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs text-app-muted border-b border-app-border">
                <th class="pb-2 pr-4">任务名称</th>
                <th class="pb-2 pr-4">状态</th>
                <th class="pb-2 pr-4">创建时间</th>
                <th class="pb-2">操作</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="task in taskList"
                :key="task.id"
                class="border-b border-app-border cursor-pointer hover:bg-app-panel-soft"
                :class="selectedTaskId === task.id ? 'bg-primary-soft' : ''"
                @click="selectTask(task.id)"
              >
                <td class="py-2 pr-4 truncate max-w-[12rem]">{{ task.name || task.id.slice(0, 8) }}</td>
                <td class="py-2 pr-4">
                  <span
                    class="px-1.5 py-0.5 rounded text-[10px]"
                    :class="`bg-${STATUS_TONE[task.status]}-soft text-${STATUS_TONE[task.status]}`"
                  >{{ STATUS_LABEL[task.status] }}</span>
                </td>
                <td class="py-2 pr-4 text-xs text-app-muted">{{ task.createdAt }}</td>
                <td class="py-2">
                  <div class="flex gap-1">
                    <AppButton
                      v-if="['draft', 'completed', 'failed', 'cancelled'].includes(task.status)"
                      :label="cleanupTaskId === task.id ? '清理中...' : '清理'"
                      size="sm"
                      tone="danger"
                      :disabled="cleanupTaskId !== null"
                      @click.stop="deleteTask(task.id)"
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      <template #footer>
        <AppButton label="刷新" tone="ghost" size="sm" @click="loadTaskList" />
        <AppButton label="关闭" tone="neutral" size="sm" @click="showTaskListDialog = false" />
      </template>
    </AppModal>

    <!-- 新建任务弹窗 -->
    <AppModal
      :open="showCreateTaskDialog"
      title="新建容量规划任务"
      size="lg"
      @close="showCreateTaskDialog = false"
    >
      <div class="space-y-4 px-2 py-1">
        <section class="p-2">
          <div class="mb-3">
            <h3 class="text-base text-app-text">任务设置</h3>
          </div>

          <div class="space-y-4 border-t border-app-border pt-4">
            <!-- 项目名称和建模画布在同一行 -->
            <div class="property-row-double">
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">项目名称</label>
                <input
                  type="text"
                  :value="schema?.projectName || project?.name || ''"
                  disabled
                  class="flex-1 rounded-md border border-app-border bg-app-panel-soft px-3 py-2 text-sm text-app-muted"
                />
              </div>
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">建模画布</label>
                <select
                  v-model="newTaskForm.canvasId"
                  class="flex-1 rounded-md border border-app-border px-3 py-2 text-sm focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary"
                >
                  <option v-for="canvas in canvasOptions" :key="canvas.value" :value="canvas.value">
                    {{ canvas.label }}
                  </option>
                </select>
              </div>
            </div>
            <!-- 任务名称 -->
            <div class="property-row-double">
              <div class="flex items-center gap-2 flex-1">
                <label class="property-label">任务名称</label>
                <input
                  v-model="newTaskForm.name"
                  type="text"
                  :placeholder="defaultTaskName"
                  class="flex-1 rounded-md border border-app-border px-3 py-2 text-sm focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary"
                />
              </div>
            </div>
          </div>
        </section>
      </div>
      <template #footer>
        <AppButton label="取消" tone="neutral" @click="showCreateTaskDialog = false" />
        <AppButton label="创建" tone="primary" :disabled="creatingTask" @click="createTask" />
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

.property-label {
  font-size: 14px;
  font-weight: 500;
  color: #1d2129;
}

.variable-slider {
  display: flex;
  align-items: center;
  gap: 8px;
}

.variable-slider__track {
  position: relative;
  flex: 1;
  height: 4px;
  border-radius: 999px;
  background: #c9d8ec;
}

.variable-slider__fill {
  position: absolute;
  top: 0;
  left: 0;
  height: 100%;
  border-radius: 999px;
  background: #0A4DA2;
  pointer-events: none;
}

.variable-slider__range {
  position: absolute;
  top: -8px;
  left: 0;
  width: 100%;
  height: 20px;
  margin: 0;
  background: transparent;
  cursor: pointer;
  appearance: none;
}

.variable-slider__range::-webkit-slider-thumb {
  width: 14px;
  height: 14px;
  border: 2px solid #0A4DA2;
  border-radius: 50%;
  background: #fff;
  cursor: grab;
  appearance: none;
}

.variable-slider__range::-moz-range-thumb {
  width: 14px;
  height: 14px;
  border: 2px solid #0A4DA2;
  border-radius: 50%;
  background: #fff;
  cursor: grab;
}

.variable-slider__unit {
  flex: none;
  min-width: 24px;
  text-align: right;
}

.planning-log-surface {
  position: relative;
  isolation: isolate;
  background:
    radial-gradient(circle at 12% 0%, rgb(22 93 255 / 10%), transparent 34%),
    linear-gradient(180deg, #f8fafc 0%, #eef2f7 100%);
}

.planning-log-line {
  transition: background-color 180ms ease;
}

.planning-log-line:hover {
  background-color: rgb(255 255 255 / 55%);
}

.planning-thinking {
  overflow: hidden;
}

.planning-thinking-dot {
  z-index: 1;
  width: 5px;
  height: 5px;
  flex: none;
  border-radius: 999px;
  background: #165dff;
  animation: planning-thinking-bounce 1.2s ease-in-out infinite;
}

.planning-thinking-dot:nth-child(2) {
  animation-delay: 160ms;
}

.planning-thinking-dot:nth-child(3) {
  animation-delay: 320ms;
}

@keyframes planning-thinking-bounce {
  0%,
  60%,
  100% {
    opacity: 0.35;
    transform: translateY(0);
  }

  30% {
    opacity: 1;
    transform: translateY(-3px);
  }
}

@media (prefers-reduced-motion: reduce) {
  .planning-thinking-dot {
    animation: none;
  }
}
</style>
