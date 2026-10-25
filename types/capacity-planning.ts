export type CapacityVariableMode = 'optimize' | 'fixed'

/** C-401 变量形态：连续容量 / 整数台数 / 离散档位 */
export type CapacityVariableValueKind = 'continuous' | 'integer' | 'tier'

/** C-401 第二增量：容量变更方式（四分类：已有之外的 新增/替换/退役） */
export type CapacityVariableChangeKind = 'new' | 'replace' | 'retire'

export interface CapacityVariableDraft {
  componentId: string
  componentKey: string
  componentName: string
  parameterPath: 'data.business.commonTechParams.capacity'
  unit: string
  currentValue: number
  mode: CapacityVariableMode
  fixedValue: number
  lowerBound: number
  upperBound: number
  suggestedValue: number
  step?: number | null
  schemaMin?: number | null
  schemaMax?: number | null
  needsUserInput: boolean
  /** C-401：变量形态（缺省 continuous） */
  valueKind?: CapacityVariableValueKind
  /** C-401 第二增量：容量变更方式（缺省 new；retire 时候选值即退役后保留容量） */
  changeKind?: CapacityVariableChangeKind
  /** C-401：离散档位值集合（valueKind=tier 时存在，严格递增） */
  tiers?: number[] | null
  /** C-401：新增容量上下界（相对现有容量） */
  minAdded?: number | null
  maxAdded?: number | null
  /** C-401：成组比例约束 */
  groupId?: string | null
  groupRatio?: number | null
  /** C-401：互斥组（同组至多一个变量偏离现有容量） */
  mutexGroup?: string | null
}

export interface CapacityPlanningFormSchema {
  schemaVersion: 'capacity-variable-form-v2'
  projectId: string
  projectName: string
  projectUpdatedAt: string
  canvasId: string
  canvasName: string
  variables: CapacityVariableDraft[]
  warnings: string[]
}

export interface CapacityVariableValidationResult {
  canvasId: string
  projectUpdatedAt: string
  variables: CapacityVariableDraft[]
}

export interface CapacityVariableValidationRequest {
  projectId: string
  canvasId: string
  variables: CapacityVariableDraft[]
}

export interface BoundaryDatasetSeriesInput {
  boundaryId: string
  columnName: string
  unit: string
}

export interface BoundaryDatasetSeries extends BoundaryDatasetSeriesInput {
  name: string
  meaning: string
  componentId: string
}

export interface BoundaryDatasetSummary {
  id: string
  projectId: string
  name: string
  timezone: string
  resolutionMinutes: number
  startAt: string
  endAt: string
  createdAt: string
  contentHash: string
  pointCount: number
  seriesCount: number
}

export interface BoundaryDataset extends BoundaryDatasetSummary {
  series: BoundaryDatasetSeries[]
}

export interface ImportBoundaryDatasetRequest {
  projectId: string
  name: string
  filePath: string
  timezone: string
  resolutionMinutes: number
  timestampColumn?: string
  startAt?: string
  series: BoundaryDatasetSeriesInput[]
}

export interface ClusteringConfig {
  projectId: string
  // 聚类必须绑定目标画布：候选特征与聚类输入只取该画布节点引用的边界（C-101/BUG-003）
  canvasId: string
  datasetId?: string
  featureIds: string[]
  clusterCount: number
  algorithm: 'kmeans' | 'kmedoids'
  normalize: 'zscore' | 'minmax' | 'none'
  missingDayThreshold: number
  seed: number
  representative: 'nearest-observation'
  /** C-402：极端日保留（峰荷日/低可再生日独立成场景，默认 true） */
  preserveExtremes?: boolean
  /** C-402：预览后回写的场景集 hash，运行时校验边界数据是否变更 */
  scenarioPreviewHash?: string | null
  /** 生成场景时的 project.boundariesUpdatedAt，用于打开任务时提示边界已更新 */
  boundariesVersion?: string | null
  /** 已保存的场景预览（回显用，打开任务不再自动重算） */
  savedScenarioPreview?: ScenarioPreviewResult | null
}

export interface TypicalDayScenario {
  scenarioId: string
  representativeDate: string
  weightDays: number
  probability: number
  memberDates: string[]
  distanceToCenter: number
  /** C-402：是否为保留极端日（峰荷/低可再生），权重固定 1 天 */
  preserved?: boolean
  series: Record<string, number[]>
}

export interface ScenarioPreviewResult {
  scenarioSetHash: string
  dataset: BoundaryDataset
  config: Omit<ClusteringConfig, 'projectId' | 'datasetId'> & { resolutionMinutes: number }
  scenarios: TypicalDayScenario[]
  quality: {
    validDayCount: number
    excludedDayCount: number
    excludedDays: Record<string, string>
    /** C-402：完全重复的边界日数量（仅告警不排除） */
    duplicateDayCount?: number
    /** C-402：异常日告警数量（|z|>6，保留参与聚类） */
    anomalyDayCount?: number
    /** C-402：按边界均值填充的缺失点数量 */
    nanFilledPoints?: number
    /** C-402：保留的极端日（峰荷/低可再生） */
    preservedDays?: string[]
    sse: number
    iterations: number
    converged: boolean
    normalization: Record<string, Record<string, number | string>>
    alignment: {
      originallyAligned: boolean
      originalLengthsConsistent: boolean
      originalPointCounts: Record<string, number>
      alignedPointCount: number
      truncatedPointCount: number
      truncatedPointCounts: Record<string, number>
      commonStartAt: string
      commonEndAt: string
    }
    weightedMeanError: Record<string, {
      originalMean: number
      representativeMean: number
      relativeError: number
    }>
    warnings: string[]
  }
}

export type CapacityPlanningStatus =
  | 'draft'
  | 'queued'
  | 'validating'
  | 'clustering'
  | 'optimizing'
  | 'completed'
  | 'failed'
  | 'cancelled'

export interface CapacityOptimizerConfig {
  /** BlackBoxOptim Method 名；前端可用业务展示名映射 */
  method: string
  maxFuncEvals: number
  populationSize: number
  maxTimeSeconds?: number
  seed: number
  failurePenalty: number
  /** 技术约束软惩罚系数（元/百分点）：消纳率/绿电占比/购电占比/稳定性 */
  technicalPenalty: number
}

export type CapacityPlanObjective =
  | 'total-cost-min'
  | 'operating-cost-min'
  | 'initial-investment-min'
  | 'npv-max'
  | 'lcoe-min'
  | 'payback-period-min'
  | 'irr-max'

export interface CapacityConstraint {
  enabled: boolean
  operator: 'gte' | 'lte'
  threshold: number
  unit: '%' | '年'
}

export interface CapacityTechnicalConstraintsConfig {
  renewableConsumptionRate: CapacityConstraint
  greenPowerShare: CapacityConstraint
  purchasedPowerShare: CapacityConstraint
  stability: CapacityConstraint
}

export interface CapacityEconomicConstraintsConfig {
  lifecycleYears: CapacityConstraint
  interestRatePercent: CapacityConstraint
  taxRatePercent: CapacityConstraint
  targetIrrPercent: CapacityConstraint
}

/**
 * 生命周期经济参数（与 backend lifecycle_economics.jl 字段对齐，snake_case）。
 *
 * 单位约定（必须遵守，否则投资/税负会差 100 倍）：
 * - 税率/比例类（output_vat_rate / input_vat_rate / construction_vat_rate /
 *   surcharge_rate / salvage_rate_default / fixed_om_ratio / income_tax_rate /
 *   discount_rate）在 **config 与 API 中一律为小数**（0.10 = 10%）。
 *   UI 表单可按百分数展示，提交前需 ÷100。后端 lifecycle_params_from_config
 *   对 >1 的值会再做一次 /100 兜底，并把 salvage_rate_default 夹紧到 [0,1]。
 * - working_capital_rate 是「元/容量单位」，不是百分比。
 * - staff_salary_wan 为万元/人·年；fixed_om_wan 为万元/年。
 */
export interface CapacityLifecycleParams {
  tax_holiday_years?: number
  tax_half_years?: number
  /** 小数，0.13 = 13% */
  output_vat_rate?: number
  /** 小数，0.13 = 13% */
  input_vat_rate?: number
  /** 小数，0.10 = 10% */
  construction_vat_rate?: number
  /** 小数，0.12 = 12% */
  surcharge_rate?: number
  /** 元/容量单位（非百分比） */
  working_capital_rate?: number
  /** 小数，0.05 = 5%；将被夹紧到 [0,1] */
  salvage_rate_default?: number
  staff_salary_wan?: number
  /** 小数，0.015 = 1.5%/年 */
  fixed_om_ratio?: number
  fixed_om_wan?: number
  subsidy_yuan_per_kwh?: number
  capacity_compensation_yuan_per_kw_year?: number
  replace_cycle_years?: number
  irr_penalty_weight?: number
  /** 覆盖默认 operation_years / discount_rate / income_tax_rate 时也可写在此处 */
  operation_years?: number
  /** 小数，0.08 = 8% */
  discount_rate?: number
  /** 小数，0.25 = 25% */
  income_tax_rate?: number
}

export interface CapacityEconomicsConfig {
  // 后验运行成本口径为默认（timeseries-operating-cost-v1）；
  // operating-objective-v1 保留为 JuMP 目标函数参照/调试模式
  evaluator: 'operating-objective-v1' | 'timeseries-operating-cost-v1'
  currency: string
  schemaVersion: 'capacity-objective-config-v2'
  objective: CapacityPlanObjective
  technicalConstraints: CapacityTechnicalConstraintsConfig
  economicConstraints: CapacityEconomicConstraintsConfig
  extensions: Record<string, unknown>
  /** 生命周期经济参数；新建任务始终写入，旧任务可缺省 */
  lifecycle: CapacityLifecycleParams
}

export interface CreateCapacityPlanningRequest {
  projectId: string
  canvasId: string
  name: string
  variables: CapacityVariableDraft[]
  planningLayerId: string
  clustering: Omit<ClusteringConfig, 'projectId' | 'canvasId'>
  optimizer: CapacityOptimizerConfig
  economics: CapacityEconomicsConfig
}

export interface CapacityPlanningConvergencePoint {
  ordinal: number
  fitness: number
  feasible: boolean
  bestSoFar: number | null
  /** 单次评价的图表指标摘要（技术指标 / 经济指标 / 是否带惩罚） */
  metrics?: CapacityPlanningEvaluationMetrics | null
}

/** 收敛曲线与指标卡用的单次评价指标 */
export interface CapacityPlanningEvaluationMetrics {
  feasible?: boolean
  /** 当前单次评价的适应度；旧任务可能缺失，前端回退到收敛点外层 fitness */
  fitness?: number | null
  /** 存在约束/技术惩罚时为 true，前端将该点标红 */
  hasPenalty?: boolean
  renewableConsumptionRate?: number | null
  greenPowerShare?: number | null
  purchasedPowerShare?: number | null
  stability?: number | null
  /** 稳定性拆分：过剩时段占比 % */
  stabilityExcessShare?: number | null
  /** 稳定性拆分：缺额时段占比 % */
  stabilityShortageShare?: number | null
  objectiveFitness?: number | null
  weightedOperatingCost?: number | null
  lifecycleCapexWan?: number | null
  irr?: number | null
  lcoe?: number | null
  npv?: number | null
  constraintPenalty?: number | null
}

export interface CapacityPlanningProgress {
  phase: CapacityPlanningStatus
  completedEvaluations: number
  failedEvaluations: number
  maxFuncEvals?: number
  bestFitness: number | null
  bestCandidate: Record<string, { value: number; unit: string; mode: CapacityVariableMode }> | null
  /** 当前最优候选的 fitness 拆解摘要（目标 + 约束/技术惩罚），供 Step5 展示 */
  bestBreakdown?: CapacityPlanningBestBreakdownSummary | null
  convergence?: CapacityPlanningConvergencePoint[]
  elapsedMs: number
  /** 自规划任务启动以来的墙钟耗时；用于界面展示，保持单调递增 */
  wallElapsedMs?: number
  cancellationRequested?: boolean
  currentEvaluation?: number
  currentScenario?: {
    index: number
    count: number
    id: string
    stage: 'building' | 'solving' | 'completed'
    startedAt: string
    elapsedMs: number
  } | null
  stopReason?: string | null
}

/** 最优 fitness 拆解摘要（后端 progress / result 共用口径） */
export interface CapacityPlanningBestBreakdownSummary {
  objectiveFitness?: number | null
  weightedOperatingCost?: number | null
  constraintPenalty?: number | null
  constraintPenaltyInObjectiveUnit?: number | null
  technicalConstraintPenalty?: number | null
  fitnessPenaltyMode?: string | null
  technicalMetrics?: Record<string, number> | null
  technicalConstraintDetails?: Array<{
    key: string
    value: number
    operator: string
    threshold: number
    shortfall: number
    penalty: number
  }> | null
  indicators?: {
    npv?: number | null
    irr?: number | null
    lcoe?: number | null
  } | null
}

export interface CapacityPlanningTask {
  id: string
  projectId: string
  canvasId: string
  name: string | null
  status: CapacityPlanningStatus
  projectUpdatedAt: string
  projectSnapshotHash: string
  scenarioSetHash: string | null
  config: {
    variables: CapacityVariableDraft[]
    clustering: ClusteringConfig
    optimizer: CapacityOptimizerConfig
    economics: CapacityEconomicsConfig
    planningLayerId: string
  }
  progress: CapacityPlanningProgress
  bestEvaluationId: number | null
  createdAt: string
  updatedAt: string
  startedAt: string | null
  finishedAt: string | null
  errorCode: string | null
  errorMessage: string | null
}

export interface CapacityPlanningResultVariable {
  componentId: string
  componentKey: string
  componentName: string
  mode: CapacityVariableMode
  unit: string
  currentValue: number
  optimalValue: number
  changeRate: number | null
}

export interface CapacityPlanningResult {
  planningId: string
  projectId: string
  canvasId: string
  projectUpdatedAt: string
  scenarioSetHash: string
  fitness: number
  breakdown: Record<string, unknown>
  warnings: string[]
  economicEvaluatorVersion: string
  simulationEvaluatorVersion: string
  variables: CapacityPlanningResultVariable[]
  bestCandidate: Record<string, { value: number; unit: string; mode: CapacityVariableMode }>
  evaluationCount: number
  failedEvaluationCount: number
  convergence: CapacityPlanningConvergencePoint[]
  scenarioSummary: {
    config: ScenarioPreviewResult['config']
    quality: ScenarioPreviewResult['quality']
    scenarios: Array<Pick<TypicalDayScenario, 'scenarioId' | 'representativeDate' | 'weightDays' | 'probability'>>
  }
}

/** C-403 生命周期经济指标（全投资口径，单位见字段注释；null 表示未计算） */
export interface CapacityPlanningLifecycleIndicators {
  /** 税后 NPV，元 */
  npv: number | null
  /** 税后 IRR，小数（0.08 = 8%） */
  irr: number | null
  /** LCOE，元/kWh */
  lcoe: number | null
}

/** C-401 第二增量：生命周期经济明细补充（金额均为万元） */
export interface CapacityPlanningLifecycleBreakdown {
  lifecycleCapexWan?: number
  lifecycleConstructionVatWan?: number
  lifecycleWorkingCapitalWan?: number
  /** 替换/退役旧设备残值处置回收（第 0 年流入） */
  lifecycleDisposalRecoveryWan?: number
  lifecycleAnnualDepreciationWan?: number
  lifecycleAnnualAdjustedTaxWan?: number
  lifecycleNpvAfterTaxWan?: number
  lifecyclePaybackYears?: number
  lifecycleDiscountedPaybackYears?: number
  /** 生命周期折现总成本（万元） */
  lifecycleDiscountedCostWan?: number
  /** 重置投资合计（万元） */
  lifecycleReplaceCapexTotalWan?: number
  lifecycleAnnualFixedOmWan?: number
  lifecycleAnnualSubsidyWan?: number
  indicators?: CapacityPlanningLifecycleIndicators
}

export interface ApplyCapacityPlanningRequest {
  expectedProjectUpdatedAt: string
  mode: 'offline'
  name: string
  /** C-406：应用目标——更新当前画布 or 保存为新画布（默认当前画布） */
  target?: 'current-canvas' | 'new-canvas'
  /** C-406：target = new-canvas 时的画布名（缺省由服务端生成） */
  newCanvasName?: string
}

// 应用前预览：服务端按当前任务/结果生成的容量差异（C-101：应用前展示节点容量差异）
export interface ApplyCapacityPlanningPreview {
  planningId: string
  projectId: string
  canvasId: string
  projectUpdatedAt: string
  variables: CapacityPlanningResultVariable[]
  /** C-406：来源最优候选的评价 id（planning_evaluations.id） */
  candidateId?: number | null
}

export interface ApplyCapacityPlanningResult {
  projectApplied: boolean
  projectUpdatedAt: string
  taskCreated: boolean
  taskId: string | null
  boundarySource: 'full-history'
  datasetId: string | null
  simStartTime: string
  simEndTime: string
  simStartDate?: string
  simEndDate?: string
  boundaryTailPolicy: 'wrap-first-day-lookahead' | 'cycle-window-lookahead'
  message?: string
  /** C-406：应用记录与溯源 */
  applyId?: string
  targetCanvasId?: string
  target?: 'current-canvas' | 'new-canvas'
  /** 来源最优候选的评价 id（planning_evaluations.id） */
  sourceCandidateId?: number | null
}

// ───── C-406 安全应用：应用记录 / 撤销恢复 ─────

export interface CapacityApplyVariableChange {
  componentId: string
  componentName: string
  unit: string
  previousValue: number
  appliedValue: number
}

/**
 * 一次容量应用的完整记录。
 * canvasSnapshotBefore/After 为撤销/恢复所需的应用前后画布快照，
 * 并记录来源 planningTaskId/candidateId 供追溯。
 */
export interface CapacityApplyRecord {
  applyId: string
  planningId: string
  planningTaskId: string
  /** 来源最优候选的评价 id（planning_evaluations.id，任务记录缺失时为 null） */
  candidateId: number | null
  projectId: string
  sourceCanvasId: string
  targetCanvasId: string
  target: 'current-canvas' | 'new-canvas'
  newCanvasName?: string
  changes: CapacityApplyVariableChange[]
  status: 'applied' | 'undone'
  projectUpdatedAtBefore: string
  projectUpdatedAtApplied: string
  projectUpdatedAtUndone: string | null
  /** 应用后目标画布 updatedAt（撤销校验：画布被再编辑后拒绝撤销） */
  canvasUpdatedAtApplied: string
  /** 撤销后目标画布 updatedAt（恢复校验用） */
  canvasUpdatedAtUndone: string | null
  canvasSnapshotBefore: unknown
  canvasSnapshotAfter: unknown
  taskId: string | null
  datasetId: string | null
  simStartTime: string
  simEndTime: string
  simStartDate?: string
  simEndDate?: string
  message?: string
  createdAt: string
  undoneAt: string | null
}

// ───── C-405 方案比较 ─────

/** 候选容量项（evaluation candidate payload） */
export interface CapacityComparisonCapacityItem {
  value: number
  unit: string
  mode: CapacityVariableMode
}

/** 统一指标 key（与后端 COMPARISON_METRICS 对齐） */
export type CapacityComparisonMetricKey =
  | 'fitness'
  | 'objectiveFitness'
  | 'constraintPenalty'
  | 'operatingCostYuan'
  | 'investmentYuan'
  | 'npvYuan'
  | 'irr'
  | 'lcoe'
  | 'paybackYears'
  | 'discountedPaybackYears'
  | 'renewableConsumptionRate'
  | 'greenPowerShare'
  | 'purchasedPowerShare'
  | 'stability'

export interface CapacityComparisonMetricSource {
  key: CapacityComparisonMetricKey
  label: string
  /** asc=越小越好，desc=越大越好（多指标敏感性排名用） */
  direction: 'asc' | 'desc'
  /** 指标来源：breakdown 明细键 + 公式版本说明 */
  source: string
}

export interface CapacityComparisonScenarioContribution {
  scenarioId: string
  /** 该典型场景按代表天数加权后的净运行成本；负数表示净收益 */
  weightedCostYuan: number
  /** 占全部场景成本绝对值之和的比重 0-1；所有场景均为 0 时为 null */
  share: number | null
}

export interface CapacityComparisonCandidate {
  evaluationId: number
  /** 评价次序 */
  ordinal: number
  /** 可行候选内排名（1 起）；不可行为 null */
  rank: number | null
  isBest: boolean
  feasible: boolean
  fitness: number
  failureReason: string | null
  durationMs: number
  capacities: Record<string, CapacityComparisonCapacityItem>
  metrics: {
    /** 统一指标值；未接线/不可算为 null */
    values: Record<CapacityComparisonMetricKey, number | null>
    /** 相对基准（排名第 1）的逐项差值；无基准或无值时缺键 */
    diffBaseline: Partial<Record<CapacityComparisonMetricKey, number>>
    /** 各指标下的敏感性排名（可行候选内，1 起；无值 null） */
    ranksByMetric: Record<CapacityComparisonMetricKey, number | null>
    detail: {
      lifecycleCapexWan?: number | null
      lifecycleConstructionVatWan?: number | null
      lifecycleWorkingCapitalWan?: number | null
      lifecycleDisposalRecoveryWan?: number | null
      lifecycleAnnualDepreciationWan?: number | null
      lifecycleAnnualAdjustedTaxWan?: number | null
      lifecycleNpvAfterTaxWan?: number | null
      lifecycleDiscountedCostWan?: number | null
      /** 逐年税后净现金流（万元，下标 0=建设年），C-405 起留痕 */
      cashflowWan?: Array<number | null> | null
    }
    scenarioContributions: CapacityComparisonScenarioContribution[]
  }
}

export interface CapacityPlanningComparison {
  planningId: string
  projectId: string
  canvasId: string
  objective: CapacityPlanObjective
  inputVersion: {
    projectSnapshotHash: string
    scenarioSetHash: string | null
    economicEvaluatorVersion: string
    simulationEvaluatorVersion: string
  }
  /** 可解释排名规则文案 */
  rankingRule: string
  baselineEvaluationId: number | null
  candidates: CapacityComparisonCandidate[]
  /** componentId → 名称/单位/现有容量 */
  variableLabels: Record<string, {
    componentName: string
    componentKey: string
    unit: string
    currentValue: number | null
  }>
  metricSources: CapacityComparisonMetricSource[]
}
