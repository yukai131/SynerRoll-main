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
  if (
    meaning === 'fuel_price' ||
    meaning === 'buy_price' ||
    meaning === 'sell_price' ||
    meaning === 'h2_buy_price' ||
    meaning === 'h2_sell_price' ||
    meaning === 'price' ||
    /价格|电价|氢价|燃.*价|购.*价|售.*价|price/i.test(name)
  ) return 'price'
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
  | 'fuel_price'     // 燃料价格（CP/GP/CHP）
  | 'buy_price'      // 购电价格（GRID）
  | 'sell_price'     // 售电价格（GRID）
  | 'h2_buy_price'   // 购氢价格（HGRID）
  | 'h2_sell_price'  // 售氢价格（HGRID）
  | 'price'          // 价格（历史兼容，新数据请用 fuel/buy/sell/h2_buy/h2_sell_price）
  | 'load'           // 负荷

// 中英文映射
export const BOUNDARY_MEANING_LABELS: Record<BoundaryMeaning, string> = {
  wind_speed: '风速',
  irradiance: '辐照度',
  temperature: '温度',
  factor: '转化因子',
  power: '输出功率',
  fuel_price: '燃料价格',
  buy_price: '购电价格',
  sell_price: '售电价格',
  h2_buy_price: '购氢价格',
  h2_sell_price: '售氢价格',
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
  price: ['fuel_price', 'buy_price', 'sell_price', 'h2_buy_price', 'h2_sell_price'],
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

/**
 * 历史 meaning 兼容（旧版词表 → 新 boundaryKey）
 * 旧版: other / heat / hydrogen / power(负荷) 等；新版: fuel_price / buy_price / sell_price / load ...
 * 做双向匹配时必须带上这层，否则旧项目数据会被过滤成「无关联」。
 */
const LEGACY_MEANING_ALIASES: Record<string, string[]> = {
  // 旧「其他」是燃料/价格/转换类的兜底语义（CP/GP/CHP/ET 都用过）
  other: ['fuel_price', 'buy_price', 'sell_price', 'h2_buy_price', 'h2_sell_price', 'price', 'factor', 'power'],
  // 旧「热/氢」负荷现归 load；CHP 的 heat 也曾挂在燃料侧
  heat: ['load', 'fuel_price'],
  hydrogen: ['load'],
  // 旧「功率」既可是机组出力也可是负荷，按对方 key 分别放行
  power: ['power', 'load', 'factor'],
  price: ['fuel_price', 'buy_price', 'sell_price', 'h2_buy_price', 'h2_sell_price', 'price']
}

/** 判断组件的 boundaryKey 是否接受某条边界的 meaning（含旧版词表兼容） */
export function meaningMatchesBoundaryKey(
  boundaryKey: readonly string[] | undefined,
  meaning: string
): boolean {
  if (!boundaryKey?.length) return false
  if (boundaryKey.includes(meaning)) return true
  const aliases = LEGACY_MEANING_ALIASES[meaning]
  if (aliases && boundaryKey.some(key => aliases.includes(key))) return true
  // 反向：boundaryKey 里是旧词、meaning 是新词
  for (const [legacy, modern] of Object.entries(LEGACY_MEANING_ALIASES)) {
    if (boundaryKey.includes(legacy) && (modern.includes(meaning) || meaning === legacy)) {
      return true
    }
  }
  return false
}

/** 物理含义对应的坐标轴单位（空字符串表示无单位） */
export const BOUNDARY_MEANING_UNITS: Record<BoundaryMeaning, string> = {
  wind_speed: 'm/s',
  irradiance: 'W/m²',
  temperature: '℃',
  factor: '',
  power: 'kW',
  fuel_price: '元/kWh',
  buy_price: '元/kWh',
  sell_price: '元/kWh',
  h2_buy_price: '元/kg',
  h2_sell_price: '元/kg',
  price: '元/kWh',
  load: 'kW'
}

/**
 * 含义允许的单位选项。负荷需兼容电/热（kW）与氢（kg/h），
 * 由边界条目上的 `unit` 字段覆盖默认单位。
 */
export const BOUNDARY_MEANING_UNIT_OPTIONS: Partial<Record<BoundaryMeaning, string[]>> = {
  load: ['kW', 'kg/h'],
  power: ['kW'],
  factor: ['', '%', 'p.u.']
}

/** 读取边界单位：优先条目上的 unit，否则用含义默认单位 */
export function resolveBoundaryUnit(
  item: { meaning?: string; unit?: string | null },
  fallbackMeaning?: BoundaryMeaning | string
): string {
  const explicit = (item.unit ?? '').trim()
  if (explicit) return explicit
  const key = (item.meaning ?? fallbackMeaning ?? '') as BoundaryMeaning
  return BOUNDARY_MEANING_UNITS[key] ?? ''
}

/** 组合展示名：风速 (m/s)；无单位时只返回名称 */
export function boundaryAxisName(
  meaning: BoundaryMeaning | string,
  unitOverride?: string | null
): string {
  const key = meaning as BoundaryMeaning
  const label = BOUNDARY_MEANING_LABELS[key] ?? String(meaning)
  const unit = (unitOverride ?? '').trim() || BOUNDARY_MEANING_UNITS[key]
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
  /** 显式单位覆盖；负荷等多单位含义必填或按此展示（如 load: kW / kg/h） */
  unit?: string
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
