// ============================================================
// 设备参数拟合（机型）类型
// 从实际运行数据拟合气象条件 → 最大新能源出力的分段/多项式关系
// ============================================================

export type FittingType = 'wind' | 'pv'

export const FITTING_TYPE_OPTIONS: { label: string; value: FittingType }[] = [
  { label: '风机拟合', value: 'wind' },
  { label: '光伏拟合', value: 'pv' }
]

export const FITTING_TYPE_LABELS: Record<FittingType, string> = {
  wind: '风机拟合',
  pv: '光伏拟合'
}

/** 风机四段功率曲线：0 / 三次多项式 / 额定平台 / 0 */
export interface WindFittingParams {
  /** 切入风速 m/s */
  v_in: number
  /** 额定风速 m/s（三次段与额定平台分界） */
  v_r: number
  /** 切出风速 m/s */
  v_out: number
  /** 三次项系数，P = a3·v³ + a2·v² + a1·v + a0 */
  a3: number
  a2: number
  a1: number
  a0: number
  /** 额定平台功率（整场） */
  p_rated: number
}

/** 光伏二元二次关系：P = a·G² + b·G + c·T + d·G·T + e */
export interface PvFittingParams {
  a: number
  b: number
  c: number
  d: number
  e: number
}

export interface FittingScatterPoint {
  /** 风速 或 辐照度 */
  x: number
  /** 功率 */
  y: number
  /** 温度（光伏） */
  t?: number
}

export interface FittingCurvePoint {
  x: number
  y: number
}

export interface FittingStats {
  n: number
  r2?: number
  rmse?: number
}

export interface FittingModel {
  id: string
  name: string
  type: FittingType
  /** 本地 CSV 路径 */
  filePath: string
  /** 输出功率列名 */
  powerColumn: string
  /** 风机: [风速列]；光伏: [辐照度列, 温度列] */
  inputColumns: string[]
  /** 关联的画布节点 ID（一个节点最多关联一个机型） */
  relatedComponents: string[]
  /** 拟合结果 */
  params?: WindFittingParams | PvFittingParams
  /** 分段/多项式文本展示 */
  formulaText?: string
  /** 降采样后的散点（图表用） */
  scatter?: FittingScatterPoint[]
  /** 拟合曲线采样点（图表用） */
  curve?: FittingCurvePoint[]
  stats?: FittingStats
}

export function isWindFittingParams(params: unknown): params is WindFittingParams {
  return !!params && typeof params === 'object' && 'v_in' in params && 'p_rated' in params
}

export function isPvFittingParams(params: unknown): params is PvFittingParams {
  return !!params && typeof params === 'object' && 'a' in params && 'e' in params && !('v_in' in params)
}

export function createEmptyFittingModel(type: FittingType, id: string, name: string): FittingModel {
  return {
    id,
    name,
    type,
    filePath: '',
    powerColumn: '',
    inputColumns: type === 'wind' ? [''] : ['', ''],
    relatedComponents: []
  }
}
