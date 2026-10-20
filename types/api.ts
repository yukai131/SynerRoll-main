import type { CanvasWorkspace } from './canvas'
import type { Project, ProjectSummary } from './project'
import type { AlgorithmConfig, LayerConfigSet, SimulationProgress, SimulationResult } from './simulation'

export interface ApiResponse<T> {
  success: boolean
  data: T
  message?: string
}

export interface ProjectListResponse {
  projects: ProjectSummary[]
}

export interface ProjectDetailResponse {
  project: Project
}

export interface CreateProjectRequest {
  name: string
  description?: string
  template?: 'blank' | 'demo'
}

export interface CopyProjectRequest {
  name?: string
}

export interface UpdateProjectRequest {
  name?: string
  description?: string
  favorite?: boolean
  tags?: string[]
}

export interface SaveCanvasRequest {
  workspace: CanvasWorkspace
}

export interface SaveLayerConfigRequest {
  layerConfig: LayerConfigSet
}

export interface UpdateAlgorithmConfigRequest {
  algorithm: AlgorithmConfig
  solverConfig: import('./simulation').SolverConfig
}

export interface SimulationResponse {
  progress: SimulationProgress
  result: SimulationResult | null
}

export interface ResultExportResponse {
  payload: import('./simulation').BackendExportPayload
  csv: string
}

// ───── 计算任务（task）相关 ─────
export type TaskMode = 'online' | 'offline'
export type TaskStatus =
  | 'pending'
  | 'parsing'
  | 'building'
  | 'solving'
  | 'completed'
  | 'failed'
  | 'cancelled'

export interface ComputeTask {
  id: string
  project_id: string
  canvas_id: string
  layer_id: string
  mode: TaskMode
  name: string | null
  status: TaskStatus
  params_hash: string
  sim_start_time: string
  sim_end_time: string | null
  sim_start_date: string | null
  sim_end_date: string | null
  cur_time: string | null
  created_at: string
  updated_at: string
  started_at: string | null
  finished_at: string | null
  error_message: string | null
  extra_json: string | null
}

export interface ComputeTaskListResponse {
  tasks: ComputeTask[]
}

export interface ComputeTaskStateResponse {
  task: ComputeTask
}

export interface CreateTaskRequest {
  projectId: string
  canvasId: string
  layerId: string
  mode: TaskMode
  simMode?: 'multi_layer' | 'single_layer'
  targetLayerId?: string
  simStartTime: string
  simEndTime?: string | null
  simStartDate?: string | null
  simEndDate?: string | null
  name?: string | null
}

export interface TaskDataRow {
  sourceId: string
  varName: string
  remark?: string
  layerId: string
  ts: string
  value: number
}

export interface TaskDataResponse {
  label: string
  rows: TaskDataRow[]
}

export interface TaskTraceStep {
  step: number
  layerId: string
  simTime: string
}

export interface TaskTraceStepsResponse {
  steps: TaskTraceStep[]
}

export interface TaskTraceDataResponse {
  rows: TaskDataRow[]
}

// ───── 经济性评价相关 ─────
export interface CostItem {
  componentId: string
  componentType: string
  componentName: string
  costType: string
  costLabel: string
  layerId: string
  value: number
  /** 是否进入目标函数（与 optimization objectives 开关一致） */
  inObjective: boolean
  isSlack: boolean
  isRevenue: boolean
  /** 计算公式说明 */
  formula?: string
  /** 目标函数开关名，如 om_objective_on；松弛项为空 */
  objectiveFlag?: string
}

export interface LayerEconomySummary {
  layerId: string
  layerName: string
  totalCost: number
  costBreakdown: Record<string, number>
  componentBreakdown: Record<string, number>
  objectiveComponents: string[]
  objectiveValue: number
  slackPenalty: number
  hasSlack: boolean
  revenueItems: Record<string, number>
}

export interface EconomyCostTypeMetric {
  total: number
  daily: number
  monthly: number
  annual: number
}

/** 日均 / 月均 / 年化派生指标 */
export interface EconomyMetrics {
  coveredStart: string
  coveredEnd: string
  elapsedHours: number
  elapsedDays: number
  /** hours=按时钟小时折算 | calendar=按日历天 */
  dayBasis: 'hours' | 'calendar' | string
  isPartial: boolean
  progressRatio: number
  netCost: number
  objectiveValue: number
  slackPenalty: number
  revenueTotal: number
  dailyAvgCost: number
  monthlyEstimateCost: number
  annualEstimateCost: number
  dailyAvgObjective: number
  annualEstimateObjective: number
  byCostType: Record<string, EconomyCostTypeMetric>
  /** 参与总览平均的有效时层数（空层不计入） */
  layerCount?: number
  /** 跨层聚合方式，当前固定 mean */
  aggregation?: string
  note?: string
}

export interface EconomyEvaluationResult {
  taskId: string
  evaluationTime: string
  /** true=仿真未完成，按已覆盖时段统计 */
  isPartial?: boolean
  taskStatus?: string
  coveredEnd?: string
  progressRatio?: number
  layers: LayerEconomySummary[]
  allCostItems: CostItem[]
  objectiveComposition: Record<string, Record<string, number>>
  metrics?: EconomyMetrics | null
  message?: string
}


// ───── 灵活性评估 ─────
export interface FlexibilityPeriodResult {
  timestamp: string
  timestamp_minutes?: number
  direction: 'up' | 'down'
  requirement_source?: string
  device_results?: DeviceFlexibilityResult[]
  boundary_result?: DeviceFlexibilityResult | null
  [key: string]: unknown
}

export interface DeviceFlexibilityResult {
  device_id: string
  device_type: string
  timestamp: string
  direction: 'up' | 'down'
  [key: string]: unknown
}

export interface FlexibilitySummaryResult {
  direction: 'up' | 'down'
  [key: string]: unknown
}

export interface FlexibilityTaskConfig {
  enabled: boolean
  layerId?: string
  requirementSource?: string
  networkMode?: string
  [key: string]: unknown
}

export interface TaskFlexibilityResponse {
  config?: FlexibilityTaskConfig | { enabled: boolean }
  periods: FlexibilityPeriodResult[]
  summaries: FlexibilitySummaryResult[]
  probe?: Record<string, number | string | boolean>
}
