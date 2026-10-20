<script setup lang="ts">
import { nextTick, watch } from 'vue'
import type { Ref } from 'vue'
import type { Project } from '~~/types/project'
import type {
  BoundaryItem,
  BoundaryMeaning,
  BoundaryMetadata,
  BoundaryRawData,
  BoundaryTimeMode,
  BoundaryTransformedData
} from '~~/types/boundary'
// 2026-07-07: BOUNDARY_COMPONENT_MAPPINGS 已注释（见 types/boundary.ts 顶部说明），先从 import 里去掉
// import { BOUNDARY_MEANING_LABELS, BOUNDARY_COMPONENT_MAPPINGS, INTERPOLATE_OPTIONS, DISTRIBUTION_OPTIONS, TIME_STEP_OPTIONS } from '~~/types/boundary'
import {
  BOUNDARY_MEANING_LABELS,
  BOUNDARY_MEANING_UNITS,
  BOUNDARY_MEANING_UNIT_OPTIONS,
  BOUNDARY_MODULE_OPTIONS,
  BOUNDARY_MODULE_LABELS,
  INTERPOLATE_OPTIONS,
  DISTRIBUTION_OPTIONS,
  TIME_STEP_OPTIONS,
  boundaryAxisName,
  meaningMatchesBoundaryKey,
  meaningsForModule,
  resolveBoundaryModuleKey,
  type BoundaryModuleKey
} from '~~/types/boundary'
import type { FittingModel, FittingType } from '~~/types/fitting'
import { FITTING_TYPE_LABELS, FITTING_TYPE_OPTIONS, createEmptyFittingModel } from '~~/types/fitting'
import { componentDefinitionMap } from '~~/config/component-meta'
import { useProjectApi } from '~~/composables/api/useProjectApi'
import { useToastCenter } from '~~/state/ui'
import {
  DEFAULT_BOUNDARY_START_DATE,
  deriveCalendarEndDate,
  formatCalendarMinute,
  isDateOnly
} from '~~/utils/calendarTime'
import { timeLabelToMinutes } from '~~/utils/timeLabel'
import { downsampleTimeSeries } from '~~/utils/chart-downsample'
import {
  getBoundaryRelatedComponentsForActiveCanvas,
  reconcileBoundaryBindings,
  setBoundaryRelatedComponentsForActiveCanvas,
  syncBoundaryStateFromBoundaries
} from '~~/utils/boundary-sync'
import {
  getFittingRelatedComponentsForActiveCanvas,
  setFittingRelatedComponentsForActiveCanvas,
  syncFittingModelsFromWorkspace,
  syncWorkspaceFromFittingModels
} from '~~/utils/fitting-sync'
import PropertySelect from '../../components/PropertySelect.vue'
import PropertyText from '../../components/PropertyText.vue'
import PropertyMultiSelect from '../../components/PropertyMultiSelect.vue'
import AppButton from '../../components/AppButton.vue'
import AppModal from '../../components/AppModal.vue'
import DeviceFittingPanel from '../../components/fitting/DeviceFittingPanel.vue'
import * as echarts from 'echarts'

// 提取可展示的接口错误文案（兼容 H3Error / FetchError）
function formatApiError(err: unknown): string {
  if (err && typeof err === 'object') {
    const e = err as {
      message?: string
      statusMessage?: string
      data?: { message?: string; statusMessage?: string }
    }
    const raw =
      e.data?.message ||
      e.data?.statusMessage ||
      e.message ||
      e.statusMessage ||
      ''
    return String(raw)
      .replace(/^Julia backend error:\s*/i, '')
      .replace(/^\[.*?\]\s*/g, '')
      .trim() || '未知错误'
  }
  return String(err)
}

const route = useRoute()
const router = useRouter()
const projectId = computed(() => String(route.params.projectId ?? ''))
const projectApi = useProjectApi()
const { push } = useToastCenter()

const projectState = useState<Project | null>(`boundary-project-${projectId.value}`, () => null)
const { data, pending } = await useAsyncData(`boundary-page-${projectId.value}`, () => projectApi.getProject(projectId.value))

// 活动标签 - 需要在 initBoundaries 之前定义
const activeTab = ref<string>('')
const tabs = ref<{ key: string; label: string }[]>([])

// 当前编辑的边界
const currentBoundary = ref<BoundaryItem | null>(null)

// 边界名称编辑状态
const editingBoundaryId = ref<string | null>(null)
const editingBoundaryName = ref('')
const renameInputEl = ref<HTMLInputElement | null>(null)

// ============================================================
// 修复问题四：统一数据流
// rawData/transformedData 不再使用独立 ref，全部通过 currentBoundary 访问
// 仅在图表渲染时使用本地临时 ref 做渲染数据源
// =========================================================
const rawData = ref<BoundaryRawData | null>(null)
const transformedData = ref<BoundaryTransformedData | null>(null)

// boundary 元信息（长度和尺度）
const boundaryMeta = ref<BoundaryMetadata | null>(null)

// 原始数据图表
const rawChartRef = ref<HTMLDivElement | null>(null)
let rawChartInstance: echarts.ECharts | null = null
// 转换后图表（每层一个）
const transformedChartRefs = ref<HTMLDivElement[]>([])
const transformedChartInstances: Record<string, echarts.ECharts> = {}

// ============================================================
// 视窗（日期 + 双端滑块）
// 同一页面上原始图 / 转换后各图共用一套，保证视窗一致便于对比；
// 日期控件与滑杆双向绑定同一 (start, end) 分钟区间
// ============================================================
const DAY_MINUTES = 24 * 60

interface DisplayWindow {
  start: number
  end: number
}

/** 全页共享视窗 */
const displayWindow = ref<DisplayWindow>({ start: 0, end: DAY_MINUTES })
/** 数据全长末端（分钟） */
const timelineEndMinute = ref(DAY_MINUTES)

const minutesFromTimestamps = (timestamps: string[] | undefined): number[] => {
  if (!timestamps?.length) return []
  return [...new Set(timestamps.map(ts => timeLabelToMinutes(ts)).filter(Number.isFinite))]
    .sort((a, b) => a - b)
}

const resetDisplayWindows = () => {
  const ends: number[] = []
  const rawMins = minutesFromTimestamps(rawData.value?.timestamps)
  if (rawMins.length) ends.push(rawMins[rawMins.length - 1]! + 60)
  for (const layer of transformedData.value?.layers ?? []) {
    const mins = minutesFromTimestamps(layer.timestamps)
    if (mins.length) ends.push(mins[mins.length - 1]! + 60)
  }
  const endMinute = Math.max(DAY_MINUTES, ...ends, 0)
  timelineEndMinute.value = endMinute
  displayWindow.value = { start: 0, end: endMinute }
}

const formatWindowLabel = (minute: number): string =>
  formatCalendarMinute(form.calendarStartDate || DEFAULT_BOUNDARY_START_DATE, minute)

/** 日期控件与滑杆共用；改完统一刷新所有图 */
const applyDisplayWindow = (partial: Partial<DisplayWindow>) => {
  const fullMax = timelineEndMinute.value
  let start = partial.start ?? displayWindow.value.start
  let end = partial.end ?? displayWindow.value.end
  start = Math.max(0, Math.min(start, end - 1))
  end = Math.min(fullMax, Math.max(end, start + 1))
  displayWindow.value = { start, end }
  updateRawChart()
  updateTransformedChart()
}

/** 日期变更：吸附到整天，与滑杆保持同一区间 */
const onDateStartUpdate = (value: number) => {
  const start = Math.max(0, Math.min(value, displayWindow.value.end - 1))
  applyDisplayWindow({ start })
}
const onDateEndUpdate = (value: number) => {
  const end = Math.min(timelineEndMinute.value, Math.max(value, displayWindow.value.start + 1))
  applyDisplayWindow({ end })
}
const onRangeStartUpdate = (value: number) => applyDisplayWindow({ start: value })
const onRangeEndUpdate = (value: number) => applyDisplayWindow({ end: value })

const filterByWindow = (timestamps: string[], values: number[], win: DisplayWindow) => {
  const points: Array<[number, number]> = []
  for (let i = 0; i < timestamps.length; i++) {
    const m = timeLabelToMinutes(timestamps[i]!)
    if (m >= win.start && m <= win.end) {
      points.push([m, Number(values[i])])
    }
  }
  return downsampleTimeSeries(points, win.start, win.end)
}


// 加载状态
const loading = ref(false)
const importingData = ref(false)
const transformingData = ref(false)
const submittingBoundary = ref(false)
const loadingBoundaryId = ref<string | null>(null)

// ============================================================
// 修复问题二 & 文件路径共享缓存
// 共享缓存：存储当前最新的非空 filePath，供所有空 filePath 的边界同步使用
// =========================================================
const sharedFilePathCache = ref<string>('')

// 同步 filePath 到所有空 filePath 的边界（不覆盖已有值的边界）
const syncFilePathToOtherBoundaries = (sourceBoundaryId: string, filePath: string) => {
  if (!project.value || !filePath.trim()) return

  let changed = false
  for (const boundary of project.value.boundaries) {
    if (boundary.id !== sourceBoundaryId && !boundary.filePath.trim()) {
      boundary.filePath = filePath
      changed = true
    }
  }
  if (changed) {
    projectState.value = { ...project.value }
  }
}

// 更新共享缓存并同步其他边界
const updateSharedFilePathCache = (boundaryId: string, filePath: string) => {
  if (!project.value) return

  // 更新缓存
  if (filePath.trim()) {
    sharedFilePathCache.value = filePath
  }

  // 同步到其他空 filePath 的边界
  syncFilePathToOtherBoundaries(boundaryId, filePath)
}

// ============================================================
// 表单字段
// =========================================================
const form = reactive({
  name: '',
  filePath: '',
  columnName: '',
  timeStep: '1h',
  meaning: 'wind_speed' as BoundaryMeaning,
  /** 显式单位（负荷等多单位含义）；空则用含义默认 */
  unit: '' as string,
  relatedComponents: [] as string[],
  interpolateType: 'copy' as const,
  randomDistribution: 'normal' as const,
  noiseLevel: 0,
  timeMode: 'calendar' as BoundaryTimeMode,
  calendarStartDate: DEFAULT_BOUNDARY_START_DATE
})

/** 当前含义可选单位；无多单位选项时只读展示默认单位 */
const unitOptions = computed(() => {
  const options = BOUNDARY_MEANING_UNIT_OPTIONS[form.meaning as BoundaryMeaning]
  if (options && options.length > 0) return options
  const fallback = BOUNDARY_MEANING_UNITS[form.meaning as BoundaryMeaning] ?? ''
  return [fallback].filter(Boolean)
})

const unitOptionsForSelect = computed(() =>
  unitOptions.value.map(u => ({ label: u || '(无单位)', value: u }))
)

const calendarEndDate = computed(() => {
  if (!isDateOnly(form.calendarStartDate)) return ''
  return deriveCalendarEndDate(form.calendarStartDate, boundaryMeta.value?.dayCount ?? 0)
})

// 导入按钮是否可用
/** 噪声强度：1%~100% 模糊滑杆（后端 0~1 / 0~100 均可） */
/** 噪声强度：0%~100% 模糊滑杆。form.noiseLevel 统一存百分比整数 */
const noisePercent = computed({
  get: () => {
    const v = Number(form.noiseLevel ?? 0)
    if (!Number.isFinite(v) || v <= 0) return 0
    // 兼容历史 0~1 小数（0.25 → 25）；整数一律按百分比，避免 1 被当成 100%
    if (v > 0 && v < 1) return Math.min(100, Math.round(v * 100))
    return Math.min(100, Math.round(v))
  },
  set: (pct: number) => {
    const n = Number(pct)
    form.noiseLevel = Math.min(100, Math.max(0, Number.isFinite(n) ? Math.round(n) : 0))
  }
})

const canImport = computed(() => {
  return form.filePath.trim() !== '' &&
    form.columnName.trim() !== '' &&
    form.timeStep !== '' &&
    form.meaning !== '' &&
    isDateOnly(form.calendarStartDate)
})

watch(() => form.calendarStartDate, () => {
  if (!boundaryMeta.value) return
  boundaryMeta.value = {
    ...boundaryMeta.value,
    timeMode: 'calendar',
    calendarStartDate: form.calendarStartDate,
    calendarEndDate: calendarEndDate.value
  }
})

const project = computed(() => projectState.value)

// 左侧子栏目：点击标题展开/收起，收纳各类边界
const expandedModules = ref<Set<BoundaryModuleKey>>(new Set(['weather']))
const toggleModule = (key: BoundaryModuleKey) => {
  const next = new Set(expandedModules.value)
  if (next.has(key)) next.delete(key)
  else next.add(key)
  expandedModules.value = next
}

const moduleGroups = computed(() => {
  const groups: Record<BoundaryModuleKey, { key: string; label: string; module: BoundaryModuleKey; kind: 'fitting' | 'boundary' }[]> = {
    'device-fitting': [],
    weather: [],
    load: [],
    price: [],
    agc: []
  }

  // 设备参数拟合：机型列表
  for (const model of project.value?.fittingModels ?? []) {
    groups['device-fitting'].push({
      key: model.id,
      label: model.name,
      module: 'device-fitting',
      kind: 'fitting'
    })
  }

  // 其余模块：边界列表（device-fitting 保留给机型，历史边界启发归类到 weather）
  for (const tab of tabs.value) {
    const item = project.value?.boundaries.find(b => b.id === tab.key)
    const module = resolveBoundaryModuleKey(item ?? { name: tab.label })
    const target: BoundaryModuleKey = module === 'device-fitting' ? 'weather' : module
    groups[target].push({ ...tab, module: target, kind: 'boundary' })
  }

  return BOUNDARY_MODULE_OPTIONS.map(option => ({
    ...option,
    items: groups[option.key]
  }))
})

const activeModuleKey = computed<BoundaryModuleKey | null>(() => {
  if (!activeTab.value) return null
  if (project.value?.fittingModels?.some(m => m.id === activeTab.value)) return 'device-fitting'
  const item = project.value?.boundaries.find(b => b.id === activeTab.value)
  return item ? resolveBoundaryModuleKey(item) : null
})

// 选中边界时自动展开所在子栏目
watch(activeModuleKey, (key) => {
  if (!key) return
  if (!expandedModules.value.has(key)) {
    const next = new Set(expandedModules.value)
    next.add(key)
    expandedModules.value = next
  }
})

// 物理含义选项：按当前所在子栏目约束（power 允许气象/AGC 双归属）
const formModuleKey = computed<BoundaryModuleKey>(() => {
  if (currentBoundary.value) {
    return resolveBoundaryModuleKey(currentBoundary.value)
  }
  return activeModuleKey.value ?? 'weather'
})

const meaningOptions = computed(() => {
  const allowed = meaningsForModule(formModuleKey.value, form.meaning)
  return allowed.map(value => ({
    value,
    label: BOUNDARY_MEANING_LABELS[value] ?? value
  }))
})

// 单一含义栏目自动对齐（负荷/价格等）
watch(formModuleKey, (module) => {
  const allowed = meaningsForModule(module, form.meaning)
  if (allowed.length === 1 && form.meaning !== allowed[0]) {
    form.meaning = allowed[0]!
  }
})

// ============================================================
// 设备参数拟合（机型）
// ============================================================
const activeFitting = computed<FittingModel | null>(() => {
  if (!activeTab.value || !project.value) return null
  return project.value.fittingModels?.find(m => m.id === activeTab.value) ?? null
})

const isActiveFitting = computed(() => activeFitting.value !== null)

const activeFittingNodes = computed(() => {
  if (!project.value || !activeFitting.value) return []
  const canvas = project.value.workspace.canvases.find(c => c.id === project.value!.workspace.activeCanvasId)
    || project.value.workspace.canvases[0]
  if (!canvas) return []
  const key = activeFitting.value.type === 'wind' ? 'WT' : 'PV'
  return canvas.nodes
    .filter(n => n.data?.componentKey === key)
    .map(n => ({ id: n.id, label: n.data?.label || n.id }))
})

function initFittingModels() {
  const proj = projectState.value
  if (!proj) return
  if (!proj.fittingModels) proj.fittingModels = []

  // 已有机型则不自动补，避免用户删除后被反复重建
  if (proj.fittingModels.length > 0) return

  const workspace = proj.workspace
  const canvas = workspace?.canvases?.find(c => c.id === workspace.activeCanvasId) || workspace?.canvases?.[0]
  if (!canvas) return

  const hasWT = canvas.nodes.some(n => n.data?.componentKey === 'WT')
  const hasPV = canvas.nodes.some(n => n.data?.componentKey === 'PV')
  const created: FittingModel[] = []

  if (hasWT) {
    created.push(createEmptyFittingModel('wind', generateId(), FITTING_TYPE_LABELS.wind))
  }
  if (hasPV) {
    created.push(createEmptyFittingModel('pv', generateId(), FITTING_TYPE_LABELS.pv))
  }

  if (created.length > 0) {
    proj.fittingModels = [...proj.fittingModels, ...created]
    projectState.value = { ...proj }
    scheduleProjectSyncPersist()
    if (!activeTab.value && created[0]) {
      activeTab.value = created[0].id
    }
  }
}

const showCreateFitting = ref(false)
const pendingFittingType = ref<FittingType>('wind')

function openCreateFitting(type?: FittingType) {
  pendingFittingType.value = type ?? 'wind'
  showCreateFitting.value = true
}

function confirmCreateFitting() {
  if (!project.value) return
  const type = pendingFittingType.value
  const count = (project.value.fittingModels ?? []).filter(m => m.type === type).length
  const model = createEmptyFittingModel(type, generateId(), `${FITTING_TYPE_LABELS[type]}${count + 1}`)

  if (!project.value.fittingModels) project.value.fittingModels = []
  project.value.fittingModels.push(model)
  projectState.value = { ...project.value }

  showCreateFitting.value = false
  const next = new Set(expandedModules.value)
  next.add('device-fitting')
  expandedModules.value = next
  activeTab.value = model.id
  scheduleProjectSyncPersist()
}

function updateActiveFitting(next: FittingModel) {
  if (!project.value) return
  const idx = project.value.fittingModels?.findIndex(m => m.id === next.id) ?? -1
  if (idx < 0 || !project.value.fittingModels) return

  // 双向同步：机型 relatedComponents ↔ 节点.fittingModelId
  const related = setFittingRelatedComponentsForActiveCanvas(
    next,
    project.value.workspace,
    next.relatedComponents
  )
  const model: FittingModel = { ...next, relatedComponents: related }
  project.value.fittingModels.splice(idx, 1, model)

  let workspace = syncWorkspaceFromFittingModels(project.value.workspace, project.value.fittingModels)
  project.value.workspace = workspace
  project.value.fittingModels = syncFittingModelsFromWorkspace(project.value.fittingModels, workspace)

  projectState.value = { ...project.value }
  scheduleProjectSyncPersist()
}

function deleteFitting(id: string) {
  if (!project.value?.fittingModels) return
  project.value.fittingModels = project.value.fittingModels.filter(m => m.id !== id)

  // 清除节点关联
  project.value.workspace = syncWorkspaceFromFittingModels(project.value.workspace, project.value.fittingModels)
  projectState.value = { ...project.value }

  if (activeTab.value === id) {
    const next = moduleGroups.value.flatMap(g => g.items)[0]
    activeTab.value = next?.key ?? ''
    if (!activeTab.value) {
      currentBoundary.value = null
    }
  }
  scheduleProjectSyncPersist()
}

function submitActiveFitting() {
  if (!activeFitting.value) return
  updateActiveFitting({ ...activeFitting.value })
  push({ tone: 'success', title: '机型已提交', description: '拟合公式已写入设备参数' })
}
const syncBoundaryFormSilently = ref(false)
let projectSyncTimer: ReturnType<typeof setTimeout> | null = null

const sameStringArray = (left: string[], right: string[]) =>
  left.length === right.length && left.every((value, index) => value === right[index])

const refreshCurrentBoundaryReference = () => {
  if (!project.value || !currentBoundary.value) {
    return
  }

  currentBoundary.value = project.value.boundaries.find(boundary => boundary.id === currentBoundary.value?.id) ?? null
}

const syncProjectFromBoundaries = () => {
  if (!project.value) {
    return
  }

  const synced = syncBoundaryStateFromBoundaries(project.value.workspace, project.value.boundaries)

  project.value.workspace = synced.workspace
  project.value.boundaries = synced.boundaries
  refreshCurrentBoundaryReference()

  if (currentBoundary.value) {
    const nextRelatedComponents = getBoundaryRelatedComponentsForActiveCanvas(
      currentBoundary.value,
      project.value.workspace
    )

    if (!sameStringArray(form.relatedComponents, nextRelatedComponents)) {
      syncBoundaryFormSilently.value = true
      form.relatedComponents = nextRelatedComponents
      syncBoundaryFormSilently.value = false
    }
  }

  projectState.value = { ...project.value }
}

const persistProjectSync = async () => {
  if (!project.value || !projectId.value) {
    return
  }

  if (!projectId.value.startsWith('project-')) {
    console.warn('[Boundary] 无效的 projectId，跳过实时同步保存:', projectId.value)
    return
  }

  try {
    await projectApi.saveCanvas(projectId.value, {
      workspace: project.value.workspace
    })
    await projectApi.saveBoundaries(projectId.value, project.value.boundaries, project.value.fittingModels)
  }
  catch (err) {
    console.error('[Boundary] 实时同步保存失败:', err)
    throw err
  }
}

const scheduleProjectSyncPersist = () => {
  if (projectSyncTimer) {
    clearTimeout(projectSyncTimer)
  }

  projectSyncTimer = setTimeout(() => {
    projectSyncTimer = null
    void persistProjectSync()
  }, 300)
}

const flushProjectSyncPersist = async () => {
  if (projectSyncTimer) {
    clearTimeout(projectSyncTimer)
    projectSyncTimer = null
  }

  await persistProjectSync()
}

// 根据物理含义获取可用的组件节点
// 2026-07-07: 从 componentDefinitionMap.boundaryKey?.includes(meaning) 反查节点类型
// 使用 meaningMatchesBoundaryKey（含旧版 other/heat/hydrogen/power 词表兼容）

const availableRelatedNodes = computed((): Array<{ id: string; data?: { label?: string } }> => {
  if (!project.value) return []
  const canvas = project.value.workspace.canvases.find(c => c.id === project.value!.workspace.activeCanvasId) || project.value.workspace.canvases[0]
  if (!canvas) return []

  // 收集所有「def.boundaryKey 接受当前 meaning」的组件 key，画布上属于这些类型的节点都是候选
  const acceptedComponentKeys = new Set<string>()
  for (const def of Object.values(componentDefinitionMap)) {
    if (meaningMatchesBoundaryKey(def.boundaryKey, form.meaning)) {
      acceptedComponentKeys.add(def.key)
    }
  }
  return canvas.nodes.filter(n => acceptedComponentKeys.has(n.data?.componentKey ?? ''))
})

// 初始化边界
async function initBoundaries() {
  const proj = projectState.value
  if (!proj) {
    return
  }

  // 确保 boundaries 数组存在
  if (!proj.boundaries) {
    proj.boundaries = []
  }

  // 如果已经有边界数据，跳过自动创建
  if (proj.boundaries.length > 0) {
    // 初始化共享文件路径缓存（取最后一个非空值）
    for (let i = proj.boundaries.length - 1; i >= 0; i--) {
      if (proj.boundaries[i]!.filePath.trim()) {
        sharedFilePathCache.value = proj.boundaries[i]!.filePath
        break
      }
    }
    // 更新标签页（侧边栏按子栏目分组展示）
    tabs.value = proj.boundaries.map((b, i) => ({
      key: b.id,
      label: b.name || `边界 ${i + 1}`
    }))
    // 默认展开当前选中项所在栏目，便于定位
    if (tabs.value.length > 0) {
      activeTab.value = tabs.value[0].key
      const first = proj.boundaries[0]
      if (first) {
        expandedModules.value = new Set([resolveBoundaryModuleKey(first)])
      }
      loadBoundary(tabs.value[0].key)
    }
    // 已有边界时也要补齐设备参数拟合默认标签
    initFittingModels()
    return
  }

  const workspace = proj.workspace
  if (!workspace?.canvases?.length) return

  const canvas = workspace.canvases.find(c => c.id === workspace.activeCanvasId) || workspace.canvases[0]
  if (!canvas) return

  // 2026-07-07: 用 componentDefinitionMap[def.key].boundaryKey[0] 作为默认 meaning，
  // 每个组件自动建一个边界（WT→wind_speed, PV→irradiance, COAL→other）。
  // 同 meaning 的多个组件合并到同一个边界（追加 relatedComponents）。
  const nodes = canvas.nodes

  const newBoundaries: BoundaryItem[] = []

  for (const node of nodes) {
    const componentKey = node.data?.componentKey
    if (!componentKey) continue
    const def = componentDefinitionMap[componentKey]
    if (!def?.boundaryKey?.length) continue

    // 语义拆分后：buy_price+sell_price / h2_buy_price+h2_sell_price 是互补语义槽（各建一条）；
    // 其余（wind_speed/factor/power 等）是可选替代含义，只建 boundaryKey[0]。
    const meanings: string[] = (() => {
      const bk = def.boundaryKey
      if (bk.includes('buy_price') && bk.includes('sell_price')) return ['buy_price', 'sell_price']
      if (bk.includes('h2_buy_price') && bk.includes('h2_sell_price')) return ['h2_buy_price', 'h2_sell_price']
      return [bk[0]!]
    })()

    for (const meaning of meanings) {
      const existing = newBoundaries.find(b => b.meaning === meaning)
      if (existing) {
        if (!existing.relatedComponents.includes(node.id)) {
          existing.relatedComponents.push(node.id)
        }
      } else {
        const id = generateId()
        const cnName = BOUNDARY_MEANING_LABELS[meaning as keyof typeof BOUNDARY_MEANING_LABELS] ?? meaning
        newBoundaries.push({
          id,
          category: resolveBoundaryModuleKey({ meaning, name: cnName }),
          name: `${cnName}`,
          filePath: '',
          columnName: '',
          timeStep: '1h',
          meaning: meaning as BoundaryItem['meaning'],
          relatedComponents: [node.id],
          interpolateType: 'copy',
          randomDistribution: 'normal',
          noiseLevel: 0
        })
      }
    }
  }

  if (newBoundaries.length > 0) {
    projectState.value = {
      ...proj,
      boundaries: [...proj.boundaries, ...newBoundaries]
    }
    syncProjectFromBoundaries()

    tabs.value = newBoundaries.map((b, i) => ({
      key: b.id,
      label: b.name || `边界 ${i + 1}`
    }))

    if (tabs.value.length > 0 && !activeTab.value) {
      activeTab.value = tabs.value[0].key
      loadBoundary(tabs.value[0].key)
    }

    scheduleProjectSyncPersist()
  }

  // 自动补齐设备参数拟合默认标签（风机拟合 / 光伏拟合）
  initFittingModels()
}

function generateId(): string {
  return 'b_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
}

// 将当前表单数据保存到边界对象
function saveCurrentFormToBoundary() {
  if (!project.value || !currentBoundary.value) return

  const boundary = project.value.boundaries.find(b => b.id === currentBoundary.value!.id)
  if (!boundary) return

  boundary.name = form.name
  boundary.filePath = form.filePath
  boundary.columnName = form.columnName
  boundary.timeStep = form.timeStep
  boundary.meaning = form.meaning
  boundary.unit = form.unit || undefined
  boundary.relatedComponents = setBoundaryRelatedComponentsForActiveCanvas(
    boundary,
    project.value.workspace,
    form.relatedComponents
  )
  boundary.interpolateType = form.interpolateType
  boundary.randomDistribution = form.randomDistribution
  boundary.noiseLevel = form.noiseLevel
  boundary.boundaryMeta = boundaryMeta.value ? { ...boundaryMeta.value } : undefined

  // 持久化原始数据和转换数据，避免页面重载后丢失
  if (rawData.value) {
    boundary.rawData = {
      values: rawData.value.values,
      timestamps: rawData.value.timestamps,
      xAxisLabel: rawData.value.xAxisLabel,
      yAxisLabel: rawData.value.yAxisLabel
    }
  }
  if (transformedData.value) {
    boundary.transformedData = {
      layers: transformedData.value.layers.map(l => ({
        layerId: l.layerId,
        layerName: l.layerName,
        values: l.values,
        timestamps: l.timestamps
      }))
    }
  }

  // 文件路径变化时更新共享缓存并同步到其他边界
  if (boundary.filePath.trim()) {
    updateSharedFilePathCache(boundary.id, boundary.filePath)
  }

  currentBoundary.value = boundary
  projectState.value = { ...project.value }
}

// 开始重命名边界
function startRename(id: string, currentName: string) {
  editingBoundaryId.value = id
  editingBoundaryName.value = currentName
  nextTick(() => {
    renameInputEl.value?.focus()
    renameInputEl.value?.select()
  })
}

// 确认重命名
function confirmRename() {
  if (!editingBoundaryId.value) return

  const id = editingBoundaryId.value
  const newName = editingBoundaryName.value.trim()

  if (newName !== '' && project.value) {
    const boundary = project.value.boundaries.find(b => b.id === id)
    const fitting = project.value.fittingModels?.find(m => m.id === id)
    if (boundary && boundary.name !== newName) {
      boundary.name = newName
      // 同步更新 form.name，防止 watch 触发后 saveCurrentFormToBoundary 用旧 form.name 覆盖
      form.name = newName
      projectState.value = { ...project.value }
      persistBoundaries()

      // 更新标签
      const tabIdx = tabs.value.findIndex(t => t.key === id)
      if (tabIdx !== -1 && tabs.value[tabIdx]) {
        tabs.value[tabIdx].label = newName
      }
    }
    else if (fitting && fitting.name !== newName) {
      fitting.name = newName
      projectState.value = { ...project.value }
      scheduleProjectSyncPersist()
    }
  }

  editingBoundaryId.value = null
  editingBoundaryName.value = ''
}

// 取消重命名
function cancelRename() {
  editingBoundaryId.value = null
  editingBoundaryName.value = ''
}

// 加载边界数据到表单
async function loadBoundary(id: string) {
  loadingBoundaryId.value = id
  try {
    await loadBoundaryInternal(id)
  } finally {
    if (loadingBoundaryId.value === id) {
      loadingBoundaryId.value = null
    }
  }
}

async function loadBoundaryInternal(id: string) {

  const boundary = project.value?.boundaries.find(b => b.id === id)
  if (!boundary) {
    return
  }

  // 直接更新 currentBoundary 和 form
  currentBoundary.value = boundary
  Object.assign(form, {
    name: boundary.name,
    filePath: boundary.filePath,
    columnName: boundary.columnName,
    timeStep: boundary.timeStep,
    meaning: boundary.meaning,
    unit: boundary.unit ?? '',
    relatedComponents: getBoundaryRelatedComponentsForActiveCanvas(boundary, project.value.workspace),
    interpolateType: boundary.interpolateType,
    randomDistribution: boundary.randomDistribution,
    noiseLevel: boundary.noiseLevel,
    timeMode: 'calendar',
    calendarStartDate: isDateOnly(boundary.boundaryMeta?.calendarStartDate)
      ? boundary.boundaryMeta.calendarStartDate
      : DEFAULT_BOUNDARY_START_DATE
  })
  boundaryMeta.value = boundary.boundaryMeta
    ? {
        ...boundary.boundaryMeta,
        timeMode: 'calendar',
        calendarStartDate: isDateOnly(boundary.boundaryMeta.calendarStartDate)
          ? boundary.boundaryMeta.calendarStartDate
          : DEFAULT_BOUNDARY_START_DATE,
        calendarEndDate: isDateOnly(boundary.boundaryMeta.calendarEndDate)
          ? boundary.boundaryMeta.calendarEndDate
          : deriveCalendarEndDate(DEFAULT_BOUNDARY_START_DATE, boundary.boundaryMeta.dayCount)
      }
    : null

  // 恢复持久化的数据
  if (boundary.rawData) {
    rawData.value = {
      boundaryId: boundary.id,
      values: boundary.rawData.values,
      timestamps: boundary.rawData.timestamps,
      xAxisLabel: boundary.rawData.xAxisLabel,
      yAxisLabel: boundary.rawData.yAxisLabel
    }
  } else {
    rawData.value = null
  }

  if (boundary.transformedData) {
    transformedData.value = {
      boundaryId: boundary.id,
      layers: boundary.transformedData.layers
    }
  } else {
    transformedData.value = null
  }

  // 尝试从 TS 库加载已存储的转换数据
  if (form.meaning && project.value?.layerConfig?.layers) {
    try {
      const loadRes = await $fetch<{
        success: boolean
        data?: {
          allFound: boolean
          boundaries: {
            layerId: string
            found: boolean
            values?: number[]
            timestamps?: string[]
            config?: BoundaryMetadata
          }[]
        }
      }>('/api/v1/boundary/load', {
        method: 'POST',
        body: {
          projectId: projectId.value,
          boundaries: project.value.layerConfig.layers.map((layer: any) => ({
            layerId: layer.id,
            meaning: form.meaning,
            boundaryId: boundary.id
            // 后端按 boundaryId 作为 source_id 查 TS 库，独立定位该边界的数据
          }))
        }
      })

      // BFF 把 allFound/boundaries 放在了 loadRes.data 下（apiSuccess 包装层）
      const payload = loadRes.data
      if (loadRes.success && payload) {
        const storedConfig = payload.boundaries.find(item => item.config)?.config
        if (storedConfig) {
          boundaryMeta.value = {
            ...storedConfig,
            timeMode: 'calendar',
            calendarStartDate: isDateOnly(storedConfig.calendarStartDate)
              ? storedConfig.calendarStartDate
              : DEFAULT_BOUNDARY_START_DATE,
            calendarEndDate: isDateOnly(storedConfig.calendarEndDate)
              ? storedConfig.calendarEndDate
              : deriveCalendarEndDate(DEFAULT_BOUNDARY_START_DATE, storedConfig.dayCount)
          }
          form.timeMode = 'calendar'
          form.calendarStartDate = boundaryMeta.value.calendarStartDate ?? DEFAULT_BOUNDARY_START_DATE
          boundary.boundaryMeta = { ...boundaryMeta.value }
        }
        const foundLayers = (payload.boundaries || []).filter((b: any) => b.found)
        if (foundLayers.length > 0) {
          // 用项目里 layerConfig 的 name 做更友好的标题
          const layerNameMap = new Map<string, string>(
            project.value.layerConfig.layers.map((l: any) => [String(l.id), l.name || `时层${l.id}`])
          )
          const storedLayers = foundLayers.map((b: any) => ({
            layerId: b.layerId,
            layerName: layerNameMap.get(String(b.layerId)) || `Layer ${b.layerId}`,
            values: b.values ?? [],
            timestamps: b.timestamps ?? []
          }))
          transformedData.value = {
            boundaryId: boundary.id,
            layers: storedLayers
          }
        } else {
        }
      } else {
        console.warn('[Boundary] TS 库返回结构异常:', loadRes)
      }
    } catch (err) {
      console.warn('[Boundary] 从 TS 库加载转换数据失败:', err)
    }
  }

  // 如果 rawData 缺失但有 filePath/columnName，重新从文件读一份（让原始数据图也回填）
  if (!rawData.value && form.filePath.trim() && form.columnName.trim()) {
    try {
      const importRes = await $fetch<{
        success: boolean
        data?: { values: number[]; timestamps: string[]; xAxisLabel: string; yAxisLabel: string }
        message?: string
      }>('/api/v1/boundary/import', {
        method: 'POST',
        body: {
          filePath: form.filePath,
          columnName: form.columnName,
          timeStep: form.timeStep,
          timeMode: 'calendar',
          calendarStartDate: form.calendarStartDate || DEFAULT_BOUNDARY_START_DATE,
          projectId: projectId.value
        }
      })
      if (importRes.success && importRes.data) {
        rawData.value = {
          boundaryId: boundary.id,
          values: importRes.data.values,
          timestamps: importRes.data.timestamps,
          xAxisLabel: importRes.data.xAxisLabel,
          yAxisLabel: importRes.data.yAxisLabel
        }
      } else {
        console.warn('[Boundary] 从文件重读原始数据失败:', importRes.message)
      }
    } catch (err) {
      console.warn('[Boundary] 从文件重读原始数据异常:', err)
    }
  }

  // 恢复图表数据
  nextTick(() => {
    resetDisplayWindows()
    if (rawData.value) {
      updateRawChart()
    }
    if (transformedData.value) {
      updateTransformedChart()
    }
  })
}

// 监听活动标签变化，切换前保存当前表单
watch(activeTab, (newId, oldId) => {
  const isOldFitting = !!project.value?.fittingModels?.some(m => m.id === oldId)
  const isNewFitting = !!project.value?.fittingModels?.some(m => m.id === newId)

  if (oldId && oldId !== newId && !isOldFitting) {
    // 如果正在重命名，跳过保存（blur 会处理）
    if (!editingBoundaryId.value) {
      saveCurrentFormToBoundary()
      scheduleProjectSyncPersist()
    }
  }
  if (newId && !isNewFitting) {
    loadBoundary(newId)
  }
  else if (isNewFitting) {
    currentBoundary.value = null
    rawData.value = null
    transformedData.value = null
  }
})

// 创建新边界（module 缺省时放入当前展开的子栏目，否则默认气象配置）
function createBoundary(moduleKey?: BoundaryModuleKey) {
  const id = generateId()
  const module = moduleKey
    ?? [...expandedModules.value][0]
    ?? activeModuleKey.value
    ?? 'weather'
  const moduleLabel = BOUNDARY_MODULE_LABELS[module]
  const moduleCount = project.value?.boundaries.filter(b => resolveBoundaryModuleKey(b) === module).length ?? 0
  const defaultMeaning = meaningsForModule(module)[0] ?? 'wind_speed'
  // 新建边界时使用共享缓存的 filePath
  const newBoundary: BoundaryItem = {
    id,
    category: module,
    name: `${moduleLabel}${moduleCount + 1}`,
    filePath: sharedFilePathCache.value,
    columnName: '',
    timeStep: '1h',
    meaning: defaultMeaning,
    unit: BOUNDARY_MEANING_UNITS[defaultMeaning] ?? '',
    relatedComponents: [],
    interpolateType: 'copy',
    randomDistribution: 'normal',
    noiseLevel: 0
  }

  if (!project.value) return

  project.value.boundaries.push(newBoundary)
  projectState.value = { ...project.value }

  const next = new Set(expandedModules.value)
  next.add(module)
  expandedModules.value = next

  tabs.value.push({ key: id, label: newBoundary.name })
  activeTab.value = id
  loadBoundary(id)

  scheduleProjectSyncPersist()
}

// 删除边界相关状态
const showDeleteConfirm = ref(false)
const pendingDeleteBoundary = ref<BoundaryItem | null>(null)
const deletingBoundary = ref(false)

// 弹出确认弹窗
function deleteBoundary(id: string) {
  if (!project.value) return
  const boundary = project.value.boundaries.find(b => b.id === id)
  if (!boundary) return
  pendingDeleteBoundary.value = boundary
  showDeleteConfirm.value = true
}

// 取消删除
function cancelDeleteBoundary() {
  if (deletingBoundary.value) return
  showDeleteConfirm.value = false
  pendingDeleteBoundary.value = null
}

// 确认删除：先调后端，再做本地清理与持久化
async function confirmDeleteBoundary() {
  const boundary = pendingDeleteBoundary.value
  if (!boundary || !project.value) return

  deletingBoundary.value = true
  try {
    const res = await $fetch<{
      success: boolean
      data?: { deletedLayers?: number }
      message?: string
    }>('/api/v1/boundary/delete', {
      method: 'POST',
      body: {
        projectId: projectId.value,
        boundaryId: boundary.id
      }
    })

    if (!res.success) {
      push({ tone: 'danger', title: '删除失败', description: formatApiError(res.message || '删除失败') })
      return
    }

    const layers = res.data?.deletedLayers ?? 0
    push({
      tone: 'success',
      title: '边界已删除',
      description: layers > 0 ? `时序库中共删除 ${layers} 层数据` : '时序库中无该边界的数据'
    })
  }
  catch (err) {
    push({ tone: 'danger', title: '删除失败', description: formatApiError(err) })
    return
  }
  finally {
    deletingBoundary.value = false
    showDeleteConfirm.value = false
    pendingDeleteBoundary.value = null
  }

  // 本地清理
  const idx = project.value.boundaries.findIndex(b => b.id === boundary.id)
  if (idx !== -1) {
    project.value.boundaries.splice(idx, 1)
    projectState.value = { ...project.value }
    syncProjectFromBoundaries()
  }

  tabs.value = tabs.value.filter(t => t.key !== boundary.id)
  if (activeTab.value === boundary.id) {
    const nextTab = tabs.value[0]
    if (nextTab) {
      activeTab.value = nextTab.key
      loadBoundary(nextTab.key)
    }
    else {
      currentBoundary.value = null
      rawData.value = null
      transformedData.value = null
    }
  }

  scheduleProjectSyncPersist()
}

// 持久化边界到后端
async function persistBoundaries() {
  if (!project.value || !projectId.value) return
  // 防止无效 projectId
  if (!projectId.value.startsWith('project-')) {
    console.warn('[Boundary] 无效的 projectId，跳过保存:', projectId.value)
    return
  }
  try {
    await projectApi.saveBoundaries(projectId.value, project.value.boundaries)
  } catch (err) {
    console.error('[Boundary] 保存边界失败:', err)
  }
}

const handleRelatedComponentsChange = (value: string[]) => {
  form.relatedComponents = value

  if (syncBoundaryFormSilently.value || !currentBoundary.value) {
    return
  }

  saveCurrentFormToBoundary()
  syncProjectFromBoundaries()
  scheduleProjectSyncPersist()
}

// 保存边界
function saveBoundary() {
  if (!project.value || !currentBoundary.value) return

  const idx = project.value.boundaries.findIndex(b => b.id === currentBoundary.value!.id)
  if (idx !== -1) {
    Object.assign(project.value.boundaries[idx], {
      name: form.name,
      filePath: form.filePath,
      columnName: form.columnName,
      timeStep: form.timeStep,
      meaning: form.meaning,
      relatedComponents: setBoundaryRelatedComponentsForActiveCanvas(
        project.value.boundaries[idx],
        project.value.workspace,
        form.relatedComponents
      ),
      interpolateType: form.interpolateType,
      randomDistribution: form.randomDistribution,
      noiseLevel: form.noiseLevel,
      boundaryMeta: boundaryMeta.value ? { ...boundaryMeta.value } : undefined
    })
    syncProjectFromBoundaries()
    scheduleProjectSyncPersist()

    // 更新标签
    const tabIdx = tabs.value.findIndex(t => t.key === currentBoundary.value!.id)
    if (tabIdx !== -1) {
      tabs.value[tabIdx].label = form.name
    }

    push({ tone: 'success', title: '边界已保存' })
  }
}

// 导入原始数据
async function importData() {
  if (!canImport.value || importingData.value) return

  importingData.value = true
  try {
    const response = await $fetch<{
      success: boolean
      data: {
        values: number[]
        timestamps: string[]
        xAxisLabel: string
        yAxisLabel: string
        pointCount: number
        totalHours: number
        dayCount: number
        timeStep: string
        timeMode: BoundaryTimeMode
        calendarStartDate?: string
        calendarEndDate?: string
      }
      message?: string
    }>('/api/v1/boundary/import', {
      method: 'POST',
      body: {
        filePath: form.filePath,
        columnName: form.columnName,
        timeStep: form.timeStep,
        timeMode: 'calendar',
        calendarStartDate: form.calendarStartDate || DEFAULT_BOUNDARY_START_DATE,
        projectId: projectId.value
      }
    })

    rawData.value = {
      boundaryId: currentBoundary.value?.id ?? '',
      values: response.data.values,
      timestamps: response.data.timestamps,
      xAxisLabel: response.data.xAxisLabel,
      yAxisLabel: response.data.yAxisLabel
    }

    // 保存 boundary 元信息
    boundaryMeta.value = {
      boundaryLength: `${response.data.totalHours}h`,
      boundaryStep: response.data.timeStep,
      dayCount: response.data.dayCount,
      pointCount: response.data.pointCount,
      timeMode: response.data.timeMode,
      calendarStartDate: response.data.calendarStartDate,
      calendarEndDate: response.data.calendarEndDate,
    }

    await nextTick()
    resetDisplayWindows()
    updateRawChart()
    push({ tone: 'success', title: '数据导入成功' })
  } catch (err) {
    console.error('[Boundary] 数据导入失败:', err)
    push({ tone: 'danger', title: '数据导入失败', description: formatApiError(err) })
  } finally {
    importingData.value = false
  }
}

// 转换数据
async function transformData() {
  if (!form.filePath || !form.columnName || !project.value || transformingData.value) return

  transformingData.value = true
  try {
    const response = await $fetch<{
      success: boolean
      data: {
        layers: { layerId: string; layerName: string; values: number[]; timestamps: string[] }[]
      }
      source?: string
    }>('/api/v1/boundary/transform', {
      method: 'POST',
      body: {
        filePath: form.filePath,
        columnName: form.columnName,
        timeStep: form.timeStep,
        interpolateType: form.interpolateType,
        noiseLevel: form.noiseLevel,
        randomDistribution: form.randomDistribution,
        meaning: form.meaning,
        allowNegative: form.meaning === 'temperature',
        layerConfig: project.value.layerConfig,
        projectId: projectId.value,
        // 传递 boundary 元信息，用于确定转换长度
        boundaryLength: boundaryMeta.value?.boundaryLength ?? '',
      }
    })

    transformedData.value = {
      boundaryId: currentBoundary.value?.id ?? '',
      layers: response.data.layers
    }

    await nextTick()
    resetDisplayWindows()
    updateTransformedChart()
    push({ tone: 'success', title: '数据转换成功' })
  } catch (err) {
    console.error('[Boundary] 数据转换失败:', err)
    push({ tone: 'danger', title: '数据转换失败', description: formatApiError(err) })
  } finally {
    transformingData.value = false
  }
}

// 导出转换后数据
function exportData() {
  if (!transformedData.value) return

  downloadJson(transformedData.value, `boundary_${currentBoundary.value?.id}_transformed.json`)
}

// 提交边界数据
async function submitBoundary() {
  if (!project.value || !currentBoundary.value || submittingBoundary.value) return
  if (!transformedData.value || transformedData.value.layers.length === 0) {
    push({ tone: 'warning', title: '请先进行数据转换' })
    return
  }

  submittingBoundary.value = true
  try {
    await $fetch('/api/v1/boundary/submit', {
      method: 'POST',
      body: {
        projectId: projectId.value,
        boundaries: transformedData.value.layers.map(layer => ({
          layerId: layer.layerId,
          values: layer.values,
          timestamps: layer.timestamps,
          meaning: form.meaning,
          boundaryId: currentBoundary.value!.id,
          // boundary 元信息（所有 layer 共用）
          boundaryLength: boundaryMeta.value?.boundaryLength ?? '',
          boundaryStep: boundaryMeta.value?.boundaryStep ?? '',
          dayCount: boundaryMeta.value?.dayCount ?? 0,
          pointCount: boundaryMeta.value?.pointCount ?? 0,
          timeMode: 'calendar',
          calendarStartDate: boundaryMeta.value?.calendarStartDate ?? DEFAULT_BOUNDARY_START_DATE,
          calendarEndDate: boundaryMeta.value?.calendarEndDate
            ?? deriveCalendarEndDate(DEFAULT_BOUNDARY_START_DATE, boundaryMeta.value?.dayCount ?? 0),
        }))
      }
    })

    saveCurrentFormToBoundary()
    syncProjectFromBoundaries()
    await flushProjectSyncPersist()

    push({ tone: 'success', title: '边界配置已提交' })
  } catch (err) {
    push({ tone: 'danger', title: '提交失败', description: formatApiError(err) })
  } finally {
    submittingBoundary.value = false
  }
}

// 同步边界到节点（双向同步）
async function syncBoundariesToNodes() {
  saveCurrentFormToBoundary()
  syncProjectFromBoundaries()
}

// 计算原始数据图表标题
const rawChartTitle = computed(() => {
  if (!rawData.value) return ''
  const pointCount = rawData.value.values.length
  // 从 timeStep 解析小时数，如 "1h" -> 1, "15m" -> 0.25
  const stepMatch = /^(\d+)(h|m)$/.exec(form.timeStep.trim())
  let stepHours = 1
  if (stepMatch) {
    const val = parseInt(stepMatch[1], 10)
    stepHours = stepMatch[2] === 'h' ? val : val / 60
  }
  const totalHours = Math.round(pointCount * stepHours)
  const days = Math.round(totalHours / 24)
  return `时间尺度：${form.timeStep}，数据点：${pointCount}个（${days}天）`
})

// 更新原始数据图表
function updateRawChart() {
  if (!rawChartRef.value || !rawData.value) {
    console.warn('updateRawChart: ref or data is missing', rawChartRef.value, rawData.value)
    return
  }

  // 销毁旧实例（如果存在）
  if (rawChartInstance) {
    rawChartInstance.dispose()
    rawChartInstance = null
  }

  // 等待 DOM 更新完成
  nextTick(() => {
    if (!rawChartRef.value) return

    // 确保容器有尺寸
    const container = rawChartRef.value

    rawChartInstance = echarts.init(container)

    // 使用中文label作为纵坐标名称
    const yAxisName = boundaryAxisName(form.meaning, form.unit)
    // X 为时间轴；Y 带物理单位，如「风速 (m/s)」

    const win = displayWindow.value
    const points = filterByWindow(rawData.value!.timestamps, rawData.value!.values, win)

    const option = {
      animation: false,
      title: {
        text: rawChartTitle.value,
        textStyle: { fontSize: 13, fontWeight: 'normal' },
        left: 'center',
        top: 5
      },
      tooltip: { trigger: 'axis' },
      grid: {
        left: '3%',
        right: '3%',
        top: 35,
        bottom: '8%',
        containLabel: true
      },
      xAxis: {
        type: 'value' as const,
        min: win.start,
        max: win.end,
        name: '时间',
        nameLocation: 'middle' as const,
        nameGap: 30,
        nameTextStyle: { color: '#1D2939', fontSize: 12 },
        axisLabel: {
          color: '#1D2939',
          fontSize: 11,
          formatter: (v: number) => formatCalendarMinute(form.calendarStartDate || boundaryMeta.value?.calendarStartDate, v)
        },
        splitLine: { lineStyle: { color: '#E5E6EB', type: 'dashed' } }
      },
      yAxis: {
        type: 'value' as const,
        name: yAxisName,
        nameLocation: 'middle' as const,
        nameGap: 48,
        nameTextStyle: { color: '#1D2939', fontSize: 12 },
        axisLabel: { color: '#1D2939', fontSize: 11 },
        splitLine: { lineStyle: { color: '#E5E6EB', type: 'dashed' } },
        scale: true
      },
      series: [{
        data: points,
        type: 'line' as const,
        smooth: false,
        symbol: 'none',
        lineStyle: { width: 2 },
        itemStyle: { color: '#165DFF' },
        animation: false
      }]
    }

    rawChartInstance.setOption(option)
    rawChartInstance.resize()
  })
}

// 更新转换后数据图表（每层单独一个图）
function updateTransformedChart() {
  if (!transformedData.value) return

  nextTick(() => {
    // SSR 环境下 document 不存在，跳过
    if (typeof document === 'undefined') return

    // 使用中文label作为纵坐标名称
    // yAxisName 在每层图内通过 boundaryAxisName(form.meaning, form.unit) 计算

    // 为每一层渲染独立的图表
    for (const layer of transformedData.value!.layers) {
      const el = document.getElementById(`layer-chart-${layer.layerId}`)
      if (!el) continue

      let instance = transformedChartInstances[layer.layerId]
      if (instance) {
        instance.dispose()
      }

      instance = echarts.init(el)
      transformedChartInstances[layer.layerId] = instance

      const win = displayWindow.value
      const points = filterByWindow(layer.timestamps, layer.values, win)
      const yName = boundaryAxisName(form.meaning, form.unit)

      instance.setOption({
        animation: false,
        title: {
          text: layer.layerName,
          textStyle: { fontSize: 13, fontWeight: 'normal' },
          left: 'center',
          top: 5
        },
        tooltip: { trigger: 'axis' },
        grid: {
          left: '3%', right: '3%', top: 35, bottom: '8%', containLabel: true
        },
        xAxis: {
          type: 'value',
          min: win.start,
          max: win.end,
          name: '时间',
          nameLocation: 'middle',
          nameGap: 30,
          nameTextStyle: { color: '#1D2939', fontSize: 12 },
          axisLabel: {
            color: '#1D2939',
            fontSize: 11,
            formatter: (v: number) => formatCalendarMinute(form.calendarStartDate || boundaryMeta.value?.calendarStartDate, v)
          },
          splitLine: { lineStyle: { color: '#E5E6EB', type: 'dashed' } }
        },
        yAxis: {
          type: 'value',
          name: yName,
          nameLocation: 'middle',
          nameGap: 48,
          nameTextStyle: { color: '#1D2939', fontSize: 12 },
          axisLabel: { color: '#1D2939', fontSize: 11 },
          splitLine: { lineStyle: { color: '#E5E6EB', type: 'dashed' } },
          scale: true
        },
        series: [{
          data: points,
          type: 'line',
          smooth: false,
          symbol: 'none',
          lineStyle: { width: 2 },
          itemStyle: { color: '#165DFF' },
          animation: false
        }]
      })
    }
  })
}

// 清理图表
onBeforeUnmount(() => {
  rawChartInstance?.dispose()
  Object.values(transformedChartInstances).forEach(inst => inst.dispose())
})

// 窗口调整时重新绘制图表
onMounted(() => {
  window.addEventListener('resize', () => {
    rawChartInstance?.resize()
    Object.values(transformedChartInstances).forEach(inst => inst.resize())
  })
})

useHead(() => ({
  title: project.value ? `${project.value.name} - 边界配置` : '边界配置 - SynerRoll'
}))

// 返回编辑页
async function goBack() {
  if (project.value) {
    try {
      // 保存当前表单
      saveCurrentFormToBoundary()
      syncProjectFromBoundaries()
      await flushProjectSyncPersist()
      // 导航前刷新画布页数据
      await refreshNuxtData(`editor-project-${projectId.value}`)
    } catch (err) {
      console.error('[Boundary] goBack 中出错:', err)
    }
  }
  router.push(`/editor/${projectId.value}`)
}

function downloadJson(data: any, filename: string) {
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

// 监听数据加载完成，初始化边界
watch(() => data.value?.project, (proj) => {
  if (proj) {
    // 加载时双向校准 relatedComponents ↔ boundaryIds，避免单侧脏数据导致关联丢失
    if (proj.workspace && proj.boundaries) {
      const reconciled = reconcileBoundaryBindings(proj.workspace, proj.boundaries)
      proj.workspace = reconciled.workspace
      proj.boundaries = reconciled.boundaries
    }
    projectState.value = proj
    initBoundaries()
  }
}, { immediate: true })

// 监听 projectState 变化，加载边界数据
watch(projectState, () => {
  if (projectState.value && tabs.value.length > 0 && !currentBoundary.value) {
    const firstTab = tabs.value[0]
    if (firstTab) {
      loadBoundary(firstTab.key)
    }
  }
}, { immediate: true })

watch(
  () => availableRelatedNodes.value.map(node => node.id).join('|'),
  () => {
    if (!currentBoundary.value || syncBoundaryFormSilently.value) {
      return
    }

    // 候选列表为空时不做自动清理：多半是 meaning/boundaryKey 过滤失配，
    // 此时清空会把用户已建立的关联（和节点 boundaryIds）一起抹掉并持久化
    if (availableRelatedNodes.value.length === 0 && form.relatedComponents.length > 0) {
      return
    }

    const allowedNodeIds = new Set(availableRelatedNodes.value.map(node => node.id))
    const filteredRelatedComponents = form.relatedComponents.filter(nodeId => allowedNodeIds.has(nodeId))

    if (sameStringArray(filteredRelatedComponents, form.relatedComponents)) {
      return
    }

    syncBoundaryFormSilently.value = true
    form.relatedComponents = filteredRelatedComponents
    syncBoundaryFormSilently.value = false

    saveCurrentFormToBoundary()
    syncProjectFromBoundaries()
    scheduleProjectSyncPersist()
  }
)

// ============================================================
// 修复问题一：为所有表单字段添加实时保存 watch
// ============================================================

// name 字段实时保存
watch(() => form.name, (newName) => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  if (newName === currentBoundary.value.name) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})

// filePath 字段实时保存（同时更新共享缓存）
watch(() => form.filePath, (newFilePath) => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  if (newFilePath === currentBoundary.value.filePath) return
  saveCurrentFormToBoundary()
  if (newFilePath.trim()) {
    updateSharedFilePathCache(currentBoundary.value.id, newFilePath)
  }
  scheduleProjectSyncPersist()
})

// columnName 字段实时保存
watch(() => form.columnName, (newColumnName) => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  if (newColumnName === currentBoundary.value.columnName) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})

// timeStep 字段实时保存
watch(() => form.timeStep, (newTimeStep) => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  if (newTimeStep === currentBoundary.value.timeStep) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})

// meaning 字段实时保存；切换含义时重置为该含义默认单位
watch(() => form.meaning, (newMeaning) => {
  const options = BOUNDARY_MEANING_UNIT_OPTIONS[newMeaning as BoundaryMeaning]
  form.unit = options?.[0] ?? BOUNDARY_MEANING_UNITS[newMeaning as BoundaryMeaning] ?? ''
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})

// unit 字段实时保存（负荷 kW / kg/h 等）
watch(() => form.unit, () => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})

// interpolateType 字段实时保存
watch(() => form.interpolateType, (newVal) => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  if (newVal === currentBoundary.value.interpolateType) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})

// randomDistribution 字段实时保存
watch(() => form.randomDistribution, (newVal) => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  if (newVal === currentBoundary.value.randomDistribution) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})

// noiseLevel 字段实时保存
watch(() => form.noiseLevel, (newVal) => {
  if (!currentBoundary.value || syncBoundaryFormSilently.value) return
  if (newVal === currentBoundary.value.noiseLevel) return
  saveCurrentFormToBoundary()
  scheduleProjectSyncPersist()
})
</script>

<template>
  <div class="h-screen flex flex-col bg-app-bg">
    <!-- 头部 -->
    <header class="flex items-center h-14 px-4 bg-primary border-b border-app-border">
      <button
        class="inline-flex items-center gap-1 px-3 h-8 rounded text-sm text-white hover:bg-white/10"
        @click="goBack"
      >
        <svg class="w-4 h-4" viewBox="0 0 16 16" fill="none">
          <path d="M10 12L6 8L10 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        返回
      </button>
      <div class="ml-4 text-sm text-white">
        {{ project?.name }} - 边界配置
      </div>
    </header>

    <div class="flex-1 min-h-0 flex gap-2 p-2">
      <!-- 左侧：边界列表（按子栏目折叠收纳） -->
      <aside class="panel-card w-60 flex flex-col">
        <div class="flex items-center justify-between px-3 h-12 border-b border-app-border">
          <span class="text-sm font-medium">边界列表</span>
          <button
            class="inline-flex items-center justify-center w-6 h-6 rounded hover:bg-white/10"
            title="在当前子栏目新建边界"
            @click="createBoundary()"
          >
            <svg class="w-4 h-4" viewBox="0 0 16 16" fill="none">
              <path d="M8 3V13M3 8H13" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
        </div>

        <div class="flex-1 overflow-y-auto">
          <section
            v-for="group in moduleGroups"
            :key="group.key"
            class="border-b border-app-border/60 last:border-b-0"
          >
            <div class="flex items-center px-2 h-10">
              <button
                type="button"
                class="flex-1 min-w-0 flex items-center gap-2 h-full text-left hover:bg-app-panel-soft transition-colors rounded px-1"
                :class="activeModuleKey === group.key ? 'text-primary' : 'text-app-text'"
                @click="toggleModule(group.key)"
              >
                <svg
                  class="w-3 h-3 shrink-0 transition-transform"
                  :class="expandedModules.has(group.key) ? 'rotate-90' : ''"
                  viewBox="0 0 16 16"
                  fill="none"
                >
                  <path d="M6 4L10 8L6 12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
                <span class="flex-1 text-sm font-medium truncate">{{ group.label }}</span>
                <span class="text-[11px] text-app-muted">{{ group.items.length }}</span>
              </button>
              <button
                type="button"
                class="inline-flex items-center justify-center w-6 h-6 rounded hover:bg-white/20 shrink-0"
                :title="group.key === 'device-fitting' ? '新建机型' : '在此栏目新建'"
                @click="group.key === 'device-fitting' ? openCreateFitting() : createBoundary(group.key)"
              >
                <svg class="w-3 h-3" viewBox="0 0 16 16" fill="none">
                  <path d="M8 3V13M3 8H13" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                </svg>
              </button>
            </div>

            <div v-if="expandedModules.has(group.key)" class="pb-1">
              <div
                v-for="tab in group.items"
                :key="tab.key"
                class="flex items-center pr-2 pl-8 h-10 cursor-pointer transition-colors"
                :class="activeTab === tab.key ? 'bg-primary-soft' : 'hover:bg-app-panel-soft'"
                @click="activeTab = tab.key"
                @dblclick="startRename(tab.key, tab.label)"
              >
                <input
                  v-if="editingBoundaryId === tab.key"
                  v-model="editingBoundaryName"
                  class="flex-1 h-7 px-2 text-sm border border-primary rounded bg-app-input focus:outline-none"
                  @blur="confirmRename"
                  @keydown.enter="confirmRename"
                  @keydown.esc="cancelRename"
                  @click.stop
                  :ref="el => { if (el) renameInputEl = el as HTMLInputElement }"
                />
                <span v-else class="flex-1 min-w-0 flex items-center gap-1.5 text-sm">
                  <svg
                    v-if="loadingBoundaryId === tab.key"
                    class="h-3 w-3 shrink-0 animate-spin text-primary"
                    viewBox="0 0 24 24"
                    fill="none"
                    aria-hidden="true"
                  >
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="3" />
                    <path class="opacity-90" fill="currentColor" d="M4 12a8 8 0 018-8v3a5 5 0 00-5 5H4z" />
                  </svg>
                  <span class="truncate">{{ tab.label }}</span>
                </span>
                <button
                  v-if="editingBoundaryId !== tab.key"
                  class="w-5 h-5 flex items-center justify-center rounded hover:bg-white/20"
                  @click.stop="tab.kind === 'fitting' ? deleteFitting(tab.key) : deleteBoundary(tab.key)"
                >
                  <svg class="w-3 h-3" viewBox="0 0 16 16" fill="none">
                    <path d="M12 4L4 12M4 4L12 12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                  </svg>
                </button>
              </div>
              <p
                v-if="!group.items.length"
                class="px-8 py-2 text-xs text-app-muted"
              >
                {{ group.key === 'device-fitting' ? '暂无机型，点右侧 + 添加' : '暂无边界，点右侧 + 添加' }}
              </p>
            </div>
          </section>
        </div>
      </aside>

      <!-- 右侧：设备参数拟合 -->
      <DeviceFittingPanel
        v-if="isActiveFitting && activeFitting"
        :fitting="activeFitting"
        :available-nodes="activeFittingNodes"
        @update:fitting="updateActiveFitting"
        @submit="submitActiveFitting"
      />

      <!-- 右侧：边界配置（整页统一滚动） -->
      <main v-else-if="currentBoundary" class="flex-1 min-h-0 flex flex-col gap-2 overflow-y-auto">
        <!-- 第一个面板：基本配置 + 原始数据图表 -->
        <div class="panel-card px-8 py-4 shrink-0 space-y-4">
          <!-- 第一行：导入配置 -->
          <div class="flex items-center gap-6">
            <div class="flex items-center gap-2 w-1/3">
              <label class="w-16 text-sm text-app shrink-0">导入文件</label>
              <PropertyText
                v-model="form.filePath"
                placeholder="C:\Users\...\data.csv"
              />
            </div>
            <div class="flex items-center gap-2 w-1/6">
              <label class="w-16 text-sm text-app shrink-0 text-center">列名</label>
              <PropertyText
                v-model="form.columnName"
                placeholder="wind_speed"
              />
            </div>
            <div class="flex items-center gap-2 w-1/6">
              <label class="w-16 text-sm text-app shrink-0">时间尺度</label>
              <PropertySelect
                v-model="form.timeStep"
                :options="TIME_STEP_OPTIONS"
              />
            </div>
            <div class="flex items-center gap-2 w-1/6">
              <label class="w-16 text-sm text-app shrink-0">物理含义</label>
              <PropertySelect
                v-model="form.meaning"
                :options="meaningOptions"
              />
            </div>
            <div class="flex items-center gap-2 w-1/8 min-w-[120px]">
              <label class="w-12 text-sm text-app shrink-0">单位</label>
              <PropertySelect
                v-model="form.unit"
                :options="unitOptionsForSelect"
              />
            </div>
            <div class="flex items-center gap-2 w-1/6 justify-end">
              <AppButton
                label="导入"
                tone="primary"
                :disabled="!canImport"
                :loading="importingData"
                loading-label="导入中..."
                @click="importData"
              />
              <AppButton
                label="清除"
                tone="danger"
                :disabled="importingData"
                @click="rawData = null"
              />
            </div>
          </div>

          <!-- 第二行：日期范围 -->
          <div class="flex flex-wrap items-center gap-6">
            <div class="flex items-center gap-2 w-1/4 min-w-[280px]">
              <label class="w-16 text-sm text-app shrink-0">起始日期</label>
              <AppDateInput
                v-model="form.calendarStartDate"
                class="flex-1"
              />
            </div>
            <div class="flex items-center gap-2 w-1/4 min-w-[280px]">
              <label class="w-16 text-sm text-app shrink-0">终止日期</label>
              <AppDateInput
                :model-value="calendarEndDate"
                :disabled="true"
                class="flex-1"
              />
            </div>
          </div>

          <!-- 第三行：关联组件 -->
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2 flex-1 ">
              <label class="w-16 text-sm text-app shrink-0">关联组件</label>
              <div class="flex-1 relative">
                <PropertyMultiSelect
                  v-model="form.relatedComponents"
                  @update:model-value="handleRelatedComponentsChange"
                  :options="availableRelatedNodes.map(n => ({ label: n.data?.label || n.id, value: n.id }))"
                  placeholder="请选择组件..."
                />
              </div>
            </div>
          </div>

          <!-- 原始数据图表 -->
          <div class="relative h-72 shrink-0">
            <div v-if="!rawData" class="absolute inset-0 flex flex-col items-center justify-center text-app-muted border border-dashed border-app-border rounded">
              <svg class="w-10 h-10 mb-2" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                <path d="M3 3v18h18M7 16l4-4 4 4 5-6" stroke-linecap="round" stroke-linejoin="round"/>
              </svg>
              <span class="text-sm">尚未导入数据</span>
            </div>
            <div ref="rawChartRef" class="absolute inset-0" :class="{ 'invisible': !rawData }"></div>
          </div>

          <!-- 视窗（与转换后图同步） -->
          <div class="px-2 shrink-0">
            <CalendarRangeInputs
              :base-date="form.calendarStartDate || DEFAULT_BOUNDARY_START_DATE"
              :start="displayWindow.start"
              :end="displayWindow.end"
              :min="0"
              :max="timelineEndMinute"
              @update:start="onDateStartUpdate"
              @update:end="onDateEndUpdate"
            />
            <PrimaryDualRangeSlider
              :start="displayWindow.start"
              :end="displayWindow.end"
              :min="0"
              :max="timelineEndMinute"
              :step="1"
              :format-label="formatWindowLabel"
              @update:start="onRangeStartUpdate"
              @update:end="onRangeEndUpdate"
            />
          </div>
        </div>

        <!-- 第二个面板：转换配置 + 转换后数据图表 -->
        <div class="panel-card px-8 py-4 shrink-0 space-y-4">
          <!-- 转换配置 -->
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2 w-1/6">
              <label class="w-16 text-sm text-app shrink-0">插值方式</label>
              <PropertySelect
                v-model="form.interpolateType"
                :options="INTERPOLATE_OPTIONS"
              />
            </div>
            <div class="flex items-center gap-2 w-1/6">
              <label class="w-16 text-sm text-app shrink-0">随机分布</label>
              <PropertySelect
                v-model="form.randomDistribution"
                :options="DISTRIBUTION_OPTIONS"
              />
            </div>
            <div class="flex items-center gap-2 w-1/4 min-w-[200px]">
              <label class="w-16 text-sm text-app shrink-0" title="模糊噪声强度：越大扰动越明显；仅扰动插值点，原始采样点保持精确值">噪声强度</label>
              <div class="variable-slider flex-1">
                <div class="variable-slider__track">
                  <div class="variable-slider__fill" :style="{ width: noisePercent + '%' }" />
                  <input
                    v-model.number="noisePercent"
                    class="variable-slider__range"
                    type="range"
                    min="0"
                    max="100"
                    step="1"
                    aria-label="噪声强度"
                  >
                </div>
                <span class="variable-slider__unit text-xs text-app-muted">{{ noisePercent }}%</span>
              </div>
            </div>
            <div class="flex items-center gap-2 flex-1 justify-end">
              <AppButton
                label="转换"
                tone="primary"
                :disabled="!form.filePath || !form.columnName"
                :loading="transformingData"
                loading-label="转换中..."
                @click="transformData"
              />
              <AppButton
                label="导出"
                tone="primary"
                :disabled="!transformedData"
                @click="exportData"
              />
              <AppButton
                label="提交"
                tone="green"
                :disabled="!transformedData"
                :loading="submittingBoundary"
                loading-label="提交中..."
                @click="submitBoundary"
              />
            </div>
          </div>

          <div class="relative w-full shrink-0">
            <div v-if="!transformedData" class="flex flex-col items-center justify-center text-app-muted border border-dashed border-app-border rounded h-40">
              <svg class="w-10 h-10 mb-2" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                <path d="M3 3v18h18M7 16l4-4 4 4 5-6" stroke-linecap="round" stroke-linejoin="round"/>
              </svg>
              <span class="text-sm">点击转换后显示数据</span>
            </div>
            <div v-else class="grid grid-cols-1 gap-3">
              <div
                v-for="layer in transformedData.layers"
                :key="layer.layerId"
                :id="`layer-chart-${layer.layerId}`"
                class="w-full h-72"
              ></div>
            </div>
          </div>

          <!-- 视窗（与原始数据图同步） -->
          <div class="px-2 shrink-0">
            <CalendarRangeInputs
              :base-date="form.calendarStartDate || DEFAULT_BOUNDARY_START_DATE"
              :start="displayWindow.start"
              :end="displayWindow.end"
              :min="0"
              :max="timelineEndMinute"
              @update:start="onDateStartUpdate"
              @update:end="onDateEndUpdate"
            />
            <PrimaryDualRangeSlider
              :start="displayWindow.start"
              :end="displayWindow.end"
              :min="0"
              :max="timelineEndMinute"
              :step="1"
              :format-label="formatWindowLabel"
              @update:start="onRangeStartUpdate"
              @update:end="onRangeEndUpdate"
            />
          </div>
        </div>

      </main>

      <!-- 无边界/机型时的提示 -->
      <main v-else class="flex-1 flex items-center justify-center text-app-muted">
        <div class="text-center">
          <p class="text-lg mb-2">暂无配置</p>
          <p class="text-sm">请在画布中添加需要边界或拟合的组件</p>
          <AppButton
            label="创建边界"
            tone="primary"
            class="mt-4"
            @click="createBoundary"
          />
          <AppButton
            label="新建机型"
            tone="green"
            class="mt-2 ml-2"
            @click="openCreateFitting()"
          />
        </div>
      </main>
    </div>

    <!-- 新建机型弹窗 -->
    <AppModal
      :open="showCreateFitting"
      title="新建设备参数拟合"
      size="sm"
      @close="showCreateFitting = false"
    >
      <div class="px-4 py-2 space-y-3">
        <p class="text-sm text-app">选择拟合类型：</p>
        <div class="flex gap-2">
          <button
            v-for="opt in FITTING_TYPE_OPTIONS"
            :key="opt.value"
            type="button"
            class="flex-1 px-3 py-2 rounded border text-sm transition-colors"
            :class="pendingFittingType === opt.value
              ? 'border-primary bg-primary-soft text-primary'
              : 'border-app-border hover:bg-app-panel-soft'"
            @click="pendingFittingType = opt.value"
          >
            {{ opt.label }}
          </button>
        </div>
      </div>
      <template #footer>
        <AppButton label="取消" tone="neutral" @click="showCreateFitting = false" />
        <AppButton label="创建" tone="primary" @click="confirmCreateFitting" />
      </template>
    </AppModal>

    <!-- 删除确认弹窗 -->
    <AppModal
      :open="showDeleteConfirm"
      title="删除边界"
      size="sm"
      @close="cancelDeleteBoundary"
    >
      <div class="px-4 py-2">
        <p class="text-sm text-app">
          确定要删除边界「<span class="font-medium">{{ pendingDeleteBoundary?.name }}</span>」吗？
        </p>
      </div>
      <template #footer>
        <AppButton label="取消" tone="neutral" :disabled="deletingBoundary" @click="cancelDeleteBoundary" />
        <AppButton
          :label="deletingBoundary ? '删除中...' : '确认删除'"
          tone="danger"
          :disabled="deletingBoundary"
          @click="confirmDeleteBoundary"
        />
      </template>
    </AppModal>

    <!-- 加载遮罩 -->
    <div
      v-if="loading"
      class="fixed inset-0 bg-black/20 flex items-center justify-center z-50"
    >
      <div class="bg-app-panel rounded-lg px-6 py-4 text-sm">处理中...</div>
    </div>
  </div>
</template>

<style scoped>
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
  min-width: 36px;
  text-align: right;
}
</style>
