import type {
  AppearancePreset,
  ComponentCategory,
  ComponentDefinition,
  ComponentGroup,
  ComponentGroupKey,
  ConfigField,
  LayerConfig,
  LayerStatus,
  MediumType,
  PortDefinition,
  PortDirection,
  PrimitiveValue
} from '~~/types/component'
import type { BoundaryMeaning } from '~~/types/boundary'

import componentLibraryData from './component-library.json'
import { componentUIConfigs } from './component-ui-config'
import { getDeviceColor } from './device-colors'
import {
  BASE_VAR_DISPLAY_NAMES,
  parseResultSeriesKey,
  type ResultSeriesMeta,
} from './result-variables'

// ============================================================
// 组件分组定义
// ============================================================

export const componentGroups: ComponentGroup[] = [
  { key: 'bus', label: '总线', description: '能源总线' },
  { key: 'power-external-source', label: '外部源', description: '外部能源来源' },
  { key: 'power-converter', label: '转换设备', description: '能源转换设备' },
  { key: 'hydrogen-external-source', label: '外部源', description: '外部氢源' },
  { key: 'hydrogen-converter', label: '转换设备', description: '氢能转换设备' },
  { key: 'hydrogen-storage', label: '氢储能', description: '氢气储能设备' },
  { key: 'electric-storage', label: '电储能', description: '电力储能设备' },
  { key: 'time-shift-load', label: '分时负荷', description: '分时电价负荷' }
]

export const componentCategories: ComponentCategory[] = [
  { key: 'bus', label: '总线', description: '能源总线', icon: 'bus', groups: ['bus'] },
  { key: 'power', label: '电力系统', description: '电力生产与传输', icon: 'power', groups: ['power-external-source', 'power-converter'] },
  { key: 'hydrogen', label: '氢能系统', description: '氢能系统', icon: 'hydrogen', groups: ['hydrogen-external-source', 'hydrogen-converter', 'hydrogen-storage'] },
  { key: 'storage', label: '储能', description: '储能系统', icon: 'storage', groups: ['electric-storage'] },
  { key: 'load', label: '负荷', description: '能源负荷', icon: 'load', groups: ['time-shift-load'] }
]

export const componentGroupMap = Object.fromEntries(
  componentGroups.map(group => [group.key, group])
) as Record<ComponentGroupKey, ComponentGroup>

// ============================================================
// 结果变量中文名与解析规则的唯一来源见 config/result-variables.ts（与 ResultBinding 闭环对齐）。
// 此处仅保留兼容导出，内部一律委托 result-variables，不再维护第二套映射。
// ============================================================

export { BASE_VAR_DISPLAY_NAMES } from './result-variables'
export { BASE_VAR_DISPLAY_NAMES as VARIABLE_DISPLAY_NAMES_FLAT } from './result-variables'

/** @deprecated 请改用 result-variables 的 BASE_VAR_DISPLAY_NAMES / parseResultSeries */
export const VARIABLE_DISPLAY_NAMES: Record<string, Record<string, string>> = (() => {
  const nested: Record<string, Record<string, string>> = {}
  for (const [base, name] of Object.entries(BASE_VAR_DISPLAY_NAMES)) {
    // 兼容旧调用方的类型键（ELOAD/HLOAD/QLOAD）与 ResultBinding 标签（E_ELOAD/…）
    const typeKeys = base.startsWith('E_ELOAD') || base === 'E_ELOAD'
      ? ['E_ELOAD', 'ELOAD']
      : base.startsWith('H_HLOAD') || base === 'H_HLOAD'
        ? ['H_HLOAD', 'HLOAD']
        : base.startsWith('Q_QLOAD') || base === 'Q_QLOAD'
          ? ['Q_QLOAD', 'QLOAD']
          : [base.split('_').slice(0, 2).join('_'), base.split('_')[0]!]
    for (const typeKey of typeKeys) {
      if (!typeKey) continue
      nested[typeKey] ??= {}
      nested[typeKey][base] = name
    }
  }
  return nested
})()

/**
 * @deprecated 请使用 parseResultSeries / parseResultSeriesKey（闭环目录解析）
 */
export function parseVariableKey(key: string, knownCodes?: string[]): { componentType: string; baseVarName: string } {
  const meta = parseResultSeriesKey(key)
  return { componentType: meta.label, baseVarName: meta.base }
}

/**
 * @deprecated 请使用 parseResultSeries(...).variableName 或 BASE_VAR_DISPLAY_NAMES
 */
export function getVariableDisplayName(componentType: string, baseVarName: string): string {
  return BASE_VAR_DISPLAY_NAMES[baseVarName] ?? baseVarName
}

export type { ResultSeriesMeta }

// ============================================================
// 解析器：从 JSON + UI config 生成 ComponentDefinition
// ============================================================

interface LibraryComponent {
  label: string
  description: string
  category: string
  group: ComponentGroupKey
  tags: string[]
  // 该组件可关联的边界物理含义集合（可选项范围）。
  // 选择 0/1/多个边界对象由用户在实例侧（boundaryIds[]）决定，
  // schema 不做任何选择约束，由后端计算模块校验合理性。
  boundaryKey?: BoundaryMeaning[]
  ports: Array<{ id: string; side: string; direction: string; medium: string; offset: number; label?: string }>
  layerStatuses: Record<string, string[]>
  commonTechFields: Array<Record<string, unknown>>
  commonEconomicFields: Array<Record<string, unknown>>
  layerTechFields: Array<Record<string, unknown>>
  layerEconomicFields: Array<Record<string, unknown>>
  constraintFields: Array<Record<string, unknown>>
  objectiveFields: Array<Record<string, unknown>>
}

const extractDefaults = (fields: Array<Record<string, unknown>>): Record<string, PrimitiveValue> => {
  const result: Record<string, PrimitiveValue> = {}
  for (const field of fields) {
    if ('defaultValue' in field && field.defaultValue !== undefined) {
      result[field.key as string] = field.defaultValue as PrimitiveValue
    }
  }
  return result
}

// 从约束/目标字段提取默认值，包装为 { enabled: value } 结构
const extractToggleDefaults = (fields: Array<Record<string, unknown>>): Record<string, { enabled: boolean }> => {
  const result: Record<string, { enabled: boolean }> = {}
  for (const field of fields) {
    if ('defaultValue' in field && field.defaultValue !== undefined) {
      result[field.key as string] = { enabled: Boolean(field.defaultValue) }
    }
  }
  return result
}

const parseLayerConfigs = (
  layerStatuses: Record<string, string[]>,
  constraintFields: Array<Record<string, unknown>> = [],
  objectiveFields: Array<Record<string, unknown>> = []
): Record<string, LayerConfig> => {
  const constraintDefaults = extractToggleDefaults(constraintFields)
  const objectiveDefaults = extractToggleDefaults(objectiveFields)
  const configs: Record<string, LayerConfig> = {}
  for (const [layerId, statuses] of Object.entries(layerStatuses)) {
    configs[layerId] = {
      layerId,
      status: (statuses.includes('stand_alone') ? 'stand_alone' : statuses[0]) as LayerStatus,
      techParams: {},
      economicParams: {},
      constraints: { ...constraintDefaults },
      objectives: { ...objectiveDefaults }
    }
  }
  return configs
}

const parseComponentDefinition = (key: string, data: LibraryComponent): ComponentDefinition => {
  const ui = componentUIConfigs[key]

  const commonTechDefaults = extractDefaults(data.commonTechFields)
  const commonEconomicDefaults = extractDefaults(data.commonEconomicFields)

  return {
    key,
    label: data.label,
    category: data.category as ComponentDefinition['category'],
    group: data.group,
    icon: ui?.icon ?? 'default',
    iconSrc: ui?.iconSrc,
    description: data.description,
    canvasType: ui?.canvasType ?? 'energy',
    defaultSize: ui?.defaultSize ?? { width: 150, height: 150 },
    appearance: ui?.appearance ?? {
      fillColor: '#F8FAFC', strokeColor: getDeviceColor(key), strokeWidth: 1.5,
      fontSize: 13, textColor: '#1D2939', borderRadius: 10, rotation: 0, opacity: 1
    },
    ports: data.ports.map(p => ({
      id: p.id,
      label: p.label,
      direction: p.direction as PortDirection,
      side: p.side as PortDefinition['side'],
      offset: p.offset,
      medium: p.medium as MediumType
    })),
    defaultMeta: {
      componentKey: key,
      componentType: data.group,
      componentName: data.label,
      description: data.description,
      deviceCount: 1,
      commonTechParams: commonTechDefaults,
      commonEconomicParams: commonEconomicDefaults,
      layerConfigs: parseLayerConfigs(data.layerStatuses, data.constraintFields, data.objectiveFields),
      // 不再根据 boundaryKey 自动填充边界 id —— 用户手动从可用范围里选
      boundaryIds: []
    },
    commonTechParamFields: data.commonTechFields as unknown as ConfigField[],
    commonEconomicParamFields: data.commonEconomicFields as unknown as ConfigField[],
    layerTechParamFields: data.layerTechFields as unknown as ConfigField[],
    layerEconomicParamFields: data.layerEconomicFields as unknown as ConfigField[],
    layerConstraintFields: data.constraintFields.length > 0
      ? data.constraintFields as unknown as ConfigField[]
      : [
        { key: 'minLoadRatio', label: '最小出力', type: 'number', defaultValue: 0.1, min: 0, max: 1, step: 0.05 },
        { key: 'maxLoadRatio', label: '最大出力', type: 'number', defaultValue: 1, min: 0, max: 1, step: 0.05 },
        { key: 'rampRate', label: '爬坡率', type: 'number', defaultValue: 0, unit: '%/min', step: 1 }
      ],
    layerObjectiveFields: data.objectiveFields.length > 0
      ? data.objectiveFields as unknown as ConfigField[]
      : [
        { key: 'dispatchPriority', label: '调度优先级', type: 'select', defaultValue: 'balanced', options: [{ label: '平衡', value: 'balanced' }, { label: '经济优先', value: 'economic' }, { label: '低碳优先', value: 'low-carbon' }] },
        { key: 'participateOptimization', label: '参与优化', type: 'boolean', defaultValue: true }
      ],
    tags: data.tags,
    boundaryKey: data.boundaryKey
  }
}

// ============================================================
// 导出的组件定义
// ============================================================

export const componentDefinitions: ComponentDefinition[] = Object.entries(
  componentLibraryData.components as unknown as Record<string, LibraryComponent>
).map(([key, data]) => parseComponentDefinition(key, data))

export const componentDefinitionMap = Object.fromEntries(
  componentDefinitions.map(def => [def.key, def])
) as Record<string, ComponentDefinition>

// ============================================================
// 组件库层级结构
// ============================================================

export const componentLibrary = componentCategories.map(category => ({
  ...category,
  groups: category.groups.map(groupKey => ({
    ...componentGroupMap[groupKey],
    items: componentDefinitions.filter(def => def.group === groupKey)
  }))
}))
