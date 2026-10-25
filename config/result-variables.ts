/**
 * 结果时序变量闭环目录。
 *
 * 与 backend 各组件 component.jl 中的 ResultBinding 一一对应，是结果展示的唯一真源：
 *   sourceId = ResultBinding.component_label
 *   varName  = `${base}_${instanceCode}`，instanceCode 为节点 ID（node- 前缀去掉后）前 4 位十六进制
 *   松弛变量  sourceId = "BUS"，varName = `${base}_${busCode}`
 *   边界序列  sourceId = "b_…"，varName = boundary meaning
 *
 * 解析只用「标签精确查表 + base 前缀精确剥离」，不做正则模糊识别、不做历史别名兼容。
 */

import { BOUNDARY_MEANING_LABELS } from '~~/types/boundary'

// ─── 目录条目 ───

export interface ResultVariableDef {
  /** 基础变量名（不含实例 code） */
  base: string
  /** 中文显示名 */
  name: string
  /** 落库 remark */
  remark: string
  /** 默认展示顺序，越小越靠前 */
  order: number
  /** 默认是否在运行总览显示 */
  visible: boolean
}

export type ResultSeriesKind = 'runtime' | 'slack' | 'boundary' | 'unknown'

export interface ResultSeriesMeta {
  kind: ResultSeriesKind
  sourceId: string
  varName: string
  /** ResultBinding.component_label；边界为 'boundary' */
  label: string
  base: string
  /** 实例 code（节点短码）；无后缀时为空 */
  code: string
  /** 变量中文名 */
  variableName: string
  /** 来源中文名（设备类型 / 总线 / 边界） */
  labelName: string
  /** 目录键，用于优先级配置：`${label}|${base}` */
  catalogKey: string
}

// ─── 组件类型中文 ───

export const RESULT_LABEL_NAMES: Readonly<Record<string, string>> = Object.freeze({
  WT: '风机',
  PV: '光伏',
  CP: '燃煤机组',
  GP: '燃气机组',
  CHP: '热电联产',
  ES: '电储能',
  HS: '储氢',
  FS: '飞轮储能',
  PS: '抽水蓄能',
  CS: '压缩空气储能',
  ET: '电解槽',
  GRID: '电网',
  HGRID: '氢网',
  HYDRO: '水电',
  E_ELOAD: '电负荷',
  H_HLOAD: '氢负荷',
  Q_QLOAD: '热负荷',
  BUS: '总线',
  boundary: '边界',
})

// ─── 变量目录（与 ResultBinding 对齐） ───

export const RESULT_VARIABLES: Readonly<Record<string, readonly ResultVariableDef[]>> = Object.freeze({
  WT: [
    { base: 'E_WT', name: '输出功率', remark: 'power', order: 10, visible: true },
    { base: 'E_WT_cut', name: '弃风功率', remark: 'power', order: 80, visible: true },
    { base: 'AVAILABLE_WT', name: '可用功率', remark: 'power', order: 81, visible: true },
  ],
  PV: [
    { base: 'E_PV', name: '输出功率', remark: 'power', order: 11, visible: true },
    { base: 'E_PV_cut', name: '弃光功率', remark: 'power', order: 82, visible: true },
  ],
  CP: [
    { base: 'E_CP', name: '输出功率', remark: 'power', order: 12, visible: true },
    { base: 'F_CP', name: '消耗燃料', remark: 'power', order: 70, visible: true },
  ],
  GP: [
    { base: 'E_GP', name: '输出功率', remark: 'power', order: 13, visible: true },
    { base: 'F_GP', name: '消耗燃料', remark: 'power', order: 71, visible: true },
  ],
  CHP: [
    { base: 'E_CHP', name: '发电功率', remark: 'power', order: 14, visible: true },
    { base: 'Q_CHP', name: '供热功率', remark: 'heat', order: 24, visible: true },
    { base: 'F_CHP', name: '消耗燃料', remark: 'power', order: 72, visible: true },
  ],
  ES: [
    { base: 'E_ES', name: '储量', remark: 'energy', order: 40, visible: true },
    { base: 'E_ES_in', name: '充电功率', remark: 'power', order: 30, visible: true },
    { base: 'E_ES_out', name: '放电功率', remark: 'power', order: 31, visible: true },
  ],
  HS: [
    { base: 'H_HS', name: '储氢量', remark: 'energy', order: 41, visible: true },
    { base: 'H_HS_in', name: '充氢流量', remark: 'power', order: 32, visible: true },
    { base: 'H_HS_out', name: '放氢流量', remark: 'power', order: 33, visible: true },
  ],
  PS: [
    { base: 'E_PS', name: '储量', remark: 'energy', order: 42, visible: true },
    { base: 'E_PS_in', name: '充电功率', remark: 'power', order: 34, visible: true },
    { base: 'E_PS_out', name: '放电功率', remark: 'power', order: 35, visible: true },
  ],
  FS: [
    { base: 'E_FS', name: '储量', remark: 'energy', order: 43, visible: true },
    { base: 'E_FS_in', name: '充电功率', remark: 'power', order: 36, visible: true },
    { base: 'E_FS_out', name: '放电功率', remark: 'power', order: 37, visible: true },
  ],
  CS: [
    { base: 'E_CS', name: '储量', remark: 'energy', order: 44, visible: true },
    { base: 'E_CS_in', name: '充气功率', remark: 'power', order: 38, visible: true },
    { base: 'E_CS_out', name: '放气功率', remark: 'power', order: 39, visible: true },
  ],
  ET: [
    { base: 'E_ET', name: '耗电功率', remark: 'power', order: 50, visible: true },
    { base: 'H_ET', name: '产氢流量', remark: 'power', order: 51, visible: true },
  ],
  GRID: [
    { base: 'E_GRID_in', name: '上送功率', remark: 'power', order: 20, visible: true },
    { base: 'E_GRID_out', name: '购入功率', remark: 'power', order: 21, visible: true },
  ],
  HGRID: [
    { base: 'H_HGRID_in', name: '上送流量', remark: 'power', order: 22, visible: true },
    { base: 'H_HGRID_out', name: '购入流量', remark: 'power', order: 23, visible: true },
  ],
  HYDRO: [
    { base: 'E_HYDRO', name: '输出功率', remark: 'power', order: 15, visible: true },
    { base: 'AVAILABLE_HYDRO', name: '可用功率', remark: 'power', order: 83, visible: true },
    { base: 'MINIMUM_HYDRO', name: '最小出力', remark: 'power', order: 84, visible: true },
  ],
  E_ELOAD: [
    { base: 'E_ELOAD', name: '电负荷', remark: 'power', order: 5, visible: true },
  ],
  H_HLOAD: [
    { base: 'H_HLOAD', name: '氢负荷', remark: 'hydrogen', order: 6, visible: true },
  ],
  Q_QLOAD: [
    { base: 'Q_QLOAD', name: '热负荷', remark: 'power', order: 7, visible: true },
  ],
  BUS: [
    { base: 'E_SHORTAGE', name: '缺额功率', remark: 'slack', order: 90, visible: true },
    { base: 'E_EXCESS', name: '过剩功率', remark: 'slack', order: 91, visible: true },
    { base: 'H_SHORTAGE', name: '缺额氢流量', remark: 'slack', order: 92, visible: true },
    { base: 'H_EXCESS', name: '过剩氢流量', remark: 'slack', order: 93, visible: true },
    { base: 'Q_SHORTAGE', name: '缺额热功率', remark: 'slack', order: 94, visible: true },
    { base: 'Q_EXCESS', name: '过剩热功率', remark: 'slack', order: 95, visible: true },
  ],
})

/** 扁平表：base → 中文名（各 base 在闭环内唯一） */
export const BASE_VAR_DISPLAY_NAMES: Readonly<Record<string, string>> = Object.freeze(
  Object.fromEntries(
    Object.values(RESULT_VARIABLES)
      .flat()
      .map(def => [def.base, def.name]),
  ),
)

/** 目录全表（含 label/base），供设置页录入优先级 */
export interface ResultCatalogItem {
  key: string
  label: string
  labelName: string
  base: string
  name: string
  order: number
  visible: boolean
}

export function listResultCatalog(): ResultCatalogItem[] {
  const items: ResultCatalogItem[] = []
  for (const [label, defs] of Object.entries(RESULT_VARIABLES)) {
    const labelName = RESULT_LABEL_NAMES[label] ?? label
    for (const def of defs) {
      items.push({
        key: `${label}|${def.base}`,
        label,
        labelName,
        base: def.base,
        name: def.name,
        order: def.order,
        visible: def.visible,
      })
    }
  }
  items.sort((a, b) => a.order - b.order || a.key.localeCompare(b.key))
  return items
}

// ─── 解析（闭环规则，无模糊匹配） ───

const BASES_BY_LABEL: Record<string, ResultVariableDef[]> = Object.fromEntries(
  Object.entries(RESULT_VARIABLES).map(([label, defs]) => [
    label,
    // 长 base 优先，保证 E_WT_cut 先于 E_WT 命中
    [...defs].sort((a, b) => b.base.length - a.base.length),
  ]),
)

function boundaryVariableName(meaning: string): string {
  return BOUNDARY_MEANING_LABELS[meaning as keyof typeof BOUNDARY_MEANING_LABELS] ?? meaning
}

/**
 * 解析结果序列 key（`sourceId|varName` 或分字段传入）。
 * 规则：
 * 1. sourceId 以 `b_` 开头 → 边界，varName 即 meaning；
 * 2. sourceId 必须是目录中的 ResultBinding 标签；
 * 3. varName 必须等于某个 base，或等于 `base + '_' + code`（code 为剩余后缀）。
 */
export function parseResultSeries(sourceId: string, varName: string): ResultSeriesMeta {
  const isBoundary = sourceId.startsWith('b_')
  if (isBoundary) {
    return {
      kind: 'boundary',
      sourceId,
      varName,
      label: 'boundary',
      base: varName,
      code: '',
      variableName: boundaryVariableName(varName),
      labelName: RESULT_LABEL_NAMES.boundary ?? '边界',
      catalogKey: `boundary|${varName}`,
    }
  }

  const defs = BASES_BY_LABEL[sourceId]
  if (defs) {
    for (const def of defs) {
      if (varName === def.base) {
        return {
          kind: sourceId === 'BUS' ? 'slack' : 'runtime',
          sourceId,
          varName,
          label: sourceId,
          base: def.base,
          code: '',
          variableName: def.name,
          labelName: RESULT_LABEL_NAMES[sourceId] ?? sourceId,
          catalogKey: `${sourceId}|${def.base}`,
        }
      }
      const prefix = `${def.base}_`
      if (varName.startsWith(prefix) && varName.length > prefix.length) {
        return {
          kind: sourceId === 'BUS' ? 'slack' : 'runtime',
          sourceId,
          varName,
          label: sourceId,
          base: def.base,
          code: varName.slice(prefix.length),
          variableName: def.name,
          labelName: RESULT_LABEL_NAMES[sourceId] ?? sourceId,
          catalogKey: `${sourceId}|${def.base}`,
        }
      }
    }
  }

  return {
    kind: 'unknown',
    sourceId,
    varName,
    label: sourceId,
    base: varName,
    code: '',
    variableName: varName,
    labelName: sourceId,
    catalogKey: `${sourceId}|${varName}`,
  }
}

/** 兼容旧签名：`sourceId|varName` */
export function parseResultSeriesKey(key: string): ResultSeriesMeta {
  const sep = key.indexOf('|')
  const sourceId = sep >= 0 ? key.slice(0, sep) : key
  const varName = sep >= 0 ? key.slice(sep + 1) : ''
  return parseResultSeries(sourceId, varName)
}

/**
 * 总览标题：`节点名 · 变量中文名`；无节点名时用 `来源中文 · 变量中文名`。
 * 闭环内不再回落到原始 key。
 */
export function formatResultSeriesTitle(
  meta: ResultSeriesMeta,
  codeToLabel: Readonly<Record<string, string>>,
): string {
  const nodeName = meta.code ? codeToLabel[meta.code] : ''
  if (nodeName) return `${nodeName} · ${meta.variableName}`
  if (meta.kind === 'unknown') return meta.variableName
  return `${meta.labelName} · ${meta.variableName}`
}

/** 设备配色 key：与 getDeviceColor 的类型推断兼容 */
export function resultSeriesColorKey(meta: ResultSeriesMeta): string {
  return `${meta.label}_${meta.base}`
}
