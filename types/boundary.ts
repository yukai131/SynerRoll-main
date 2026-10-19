// ============================================================
// 边界类 (Boundary) 相关类型
// 边界类是一组时序数据，用于综合能源系统运行优化计算
// ============================================================

export type InterpolateType = 'copy' | 'linear' | 'cubic' | 'spline'
export type RandomDistribution = 'normal' | 'uniform' | 'exponential' | 'lognormal'
export type BoundaryTimeMode = 'calendar'

// 边界配置页左侧子栏目（模块）分区
// 历史数据未写 category 时，按 meaning / 名称启发归类；仍无法判定则归入 weather
export type BoundaryModuleKey = 'device-fitting' | 'weather' | 'load' | 'price' | 'agc'

export const BOUNDARY_MODULE_OPTIONS: { key: BoundaryModuleKey; label: string }[] = [
  { key: 'device-fitting', label: '设备参数拟合' },
  { key: 'weather', label: '气象配置' },
  { key: 'load', label: '负荷配置' },
  { key: 'price', label: '价格配置' },
  { key: 'agc', label: 'AGC配置' }
]

export const BOUNDARY_MODULE_LABELS: Record<BoundaryModuleKey, string> = {
  'device-fitting': '设备参数拟合',
  weather: '气象配置',
  load: '负荷配置',
  price: '价格配置',
  agc: 'AGC配置'
}

export function normalizeBoundaryModuleKey(category?: string | null): BoundaryModuleKey {
  if (
    category === 'device-fitting' ||
    category === 'weather' ||
    category === 'load' ||
    category === 'price' ||
    category === 'agc'
  ) {
    return category
  }
  // 兼容上一轮临时 category 值
  if (category === 'boundary') return 'weather'
  return 'weather'
}

/** 启发式归类：优先 category，其次 meaning / 名称关键词 */
export function resolveBoundaryModuleKey(item: {
  category?: string | null
  meaning?: string
  name?: string
}): BoundaryModuleKey {
  if (item.category && item.category !== 'boundary') {
    return normalizeBoundaryModuleKey(item.category)
  }

  const meaning = item.meaning ?? ''
  const name = item.name ?? ''

  if (meaning === 'load' || /负荷|load/i.test(name)) return 'load'
  if (meaning === 'price' || /价格|电价|price/i.test(name)) return 'price'
  if (/agc/i.test(name) || meaning === 'power') return 'agc'
  if (meaning === 'factor' || /拟合|参数/i.test(name)) return 'device-fitting'
  if (
    meaning === 'wind_speed' ||
    meaning === 'irradiance' ||
    meaning === 'temperature' ||
    meaning === 'humidity' ||
    meaning === 'pressure' ||
    meaning === 'wind_direction' ||
    meaning === 'cloud_cover' ||
    /气象|风|光|温|辐照|气象/i.test(name)
  ) {
    return 'weather'
  }

  return 'weather'
}

export interface BoundaryMetadata {
  boundaryLength: string
  boundaryStep: string
  dayCount: number
  pointCount: number
  timeMode: BoundaryTimeMode
  calendarStartDate?: string
  calendarEndDate?: string
}

// 物理含义类型
export type BoundaryMeaning =
  | 'wind_speed'     // 风速
  | 'irradiance'     // 辐照度
  | 'temperature'    // 温度
  | 'factor'         // 转化因子
  | 'power'          // 输出功率
  | 'price'          // 价格
  | 'load'           // 负荷

// 中英文映射
export const BOUNDARY_MEANING_LABELS: Record<BoundaryMeaning, string> = {
  wind_speed: '风速',
  irradiance: '辐照度',
  temperature: '温度',
  factor: '转化因子',
  power: '输出功率',
  price: '价格',
  load: '负荷'
}

/**
 * 各子栏目允许的物理含义。
 * power 双归属：气象配置与 AGC 配置都允许「输出功率」。
 */
export const BOUNDARY_MODULE_MEANINGS: Record<BoundaryModuleKey, BoundaryMeaning[]> = {
  'device-fitting': ['factor'],
  weather: ['wind_speed', 'irradiance', 'temperature', 'factor', 'power'],
  load: ['load'],
  price: ['price'],
  agc: ['power']
}

/** 某栏目下可选物理含义；若 current 不在白名单（历史数据），会追加保留 */
export function meaningsForModule(
  module: BoundaryModuleKey,
  current?: BoundaryMeaning | string | null
): BoundaryMeaning[] {
  const allowed = BOUNDARY_MODULE_MEANINGS[module] ?? []
  if (current && (allowed as string[]).includes(current)) return allowed
  if (current && (Object.keys(BOUNDARY_MEANING_LABELS) as string[]).includes(current)) {
    return [...allowed, current as BoundaryMeaning]
  }
  return allowed
}

/** 物理含义对应的坐标轴单位（空字符串表示无单位） */
export const BOUNDARY_MEANING_UNITS: Record<BoundaryMeaning, string> = {
  wind_speed: 'm/s',
  irradiance: 'W/m²',
  temperature: '℃',
  factor: '',
  power: 'kW',
  price: '元/kWh',
  load: 'kW'
}

/** 组合展示名：风速 (m/s)；无单位时只返回名称 */
export function boundaryAxisName(meaning: BoundaryMeaning | string): string {
  const key = meaning as BoundaryMeaning
  const label = BOUNDARY_MEANING_LABELS[key] ?? String(meaning)
  const unit = BOUNDARY_MEANING_UNITS[key]
  return unit ? `${label} (${unit})` : label
}

// 边界类对象定义
export interface BoundaryItem {
  id: string
  name: string
  /** 侧边栏子栏目分区；缺省由 meaning/名称启发归类 */
  category?: BoundaryModuleKey
  filePath: string
  columnName: string
  timeStep: string
  meaning: BoundaryMeaning
  relatedComponents: string[]
  interpolateType: InterpolateType
  randomDistribution: RandomDistribution
  noiseLevel: number
  // 持久化的数据
  rawData?: {
    values: number[]
    timestamps: string[]
    xAxisLabel: string
    yAxisLabel: string
  }
  transformedData?: {
    layers: { layerId: string; layerName: string; values: number[]; timestamps: string[] }[]
  }
  // boundary 元信息（长度和尺度）
  boundaryMeta?: BoundaryMetadata
}

// 边界数据（原始导入数据）
export interface BoundaryRawData {
  boundaryId: string
  values: number[]
  timestamps: string[]
  xAxisLabel: string
  yAxisLabel: string
}

// 转换后的数据（多时间尺度）
export interface BoundaryTransformedData {
  boundaryId: string
  layers: {
    layerId: string
    layerName: string
    values: number[]
    timestamps: string[]
  }[]
}

// NOTE: 2026-07-07 — 与 boundaryKey 重构配套保留
// BOUNDARY_COMPONENT_MAPPINGS 现在跟 ComponentDefinition.boundaryKey (types/component.ts)
// 重复且发散（前者固定 WT/PV → 1~2 个 meaning，后者每个组件各自声明 3~4 个）。
// 下一步清理应迁移到 componentDefinitionMap[def.key].boundaryKey?.includes(meaning) 的查询。
// 暂时注释保留，避免回归时丢失原始逻辑。

/*
// 边界与组件的映射关系（用于自动创建边界）
export interface BoundaryComponentMapping {
  componentKey: string
  defaultMeanings: BoundaryMeaning[]
}

// WT组件需要的边界：风速
// PV组件需要的边界：辐照度、温度
export const BOUNDARY_COMPONENT_MAPPINGS: BoundaryComponentMapping[] = [
  { componentKey: 'WT', defaultMeanings: ['wind_speed'] },
  { componentKey: 'PV', defaultMeanings: ['irradiance', 'temperature'] }
]
*/

// 边界相关配置的可编辑字段
export interface BoundaryConfigFields {
  interpolateType: InterpolateType
  randomDistribution: RandomDistribution
  noiseLevel: number
}

// 时间步长选项
export const TIME_STEP_OPTIONS = [
  { label: '15分钟', value: '15m' },
  { label: '30分钟', value: '30m' },
  { label: '1小时', value: '1h' },
  { label: '2小时', value: '2h' },
  { label: '4小时', value: '4h' },
  { label: '6小时', value: '6h' },
  { label: '12小时', value: '12h' },
  { label: '1天', value: '24h' }
]

// 插值方式选项
export const INTERPOLATE_OPTIONS: { label: string; value: InterpolateType }[] = [
  { label: '复制', value: 'copy' },
  { label: '线性', value: 'linear' },
  { label: '三次样条', value: 'cubic' },
]

// 随机分布选项
export const DISTRIBUTION_OPTIONS: { label: string; value: RandomDistribution }[] = [
  { label: '正态分布', value: 'normal' },
  { label: '均匀分布', value: 'uniform' },
]

/**
 * 噪声水平：0%~100% 模糊强度（0~1 或 0~100 均可）。
 * 仅扰动插值生成的点；原始采样点保持精确值。0=不加噪，100=很明显。
 */
export const NOISE_LEVEL_HINT = '0%~100% 模糊强度；仅扰动插值点，原始采样点不变'
