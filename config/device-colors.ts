/**
 * 设备颜色的唯一来源。
 *
 * 各结果图复用设备基础色；能流中的双向设备使用下方单独定义的方向色。
 * 未登记类型使用稳定哈希选择兜底色，避免因数组顺序变化而漂移。
 *
 * 取色优先级：用户覆盖（系统设置）→ 本文件默认表 → 稳定哈希兜底。
 * 覆盖层只影响展示，不改写默认表本身，便于一键恢复。
 */

export const DEVICE_COLOR_BY_TYPE: Readonly<Record<string, string>> = Object.freeze({
  WT: '#3B82F6',
  PV: '#22C55E',
  CP: '#F59E0B',
  GP: '#F97316',
  CHP: '#EF4444',
  ES: '#E11D48',
  HS: '#14B8A6',
  FS: '#A855F7',
  PS: '#0284C7',
  CS: '#06B6D4',
  ET: '#84CC16',
  ELOAD: '#0EA5E9',
  HLOAD: '#10B981',
  QLOAD: '#FB923C',
  GRID: '#8B5CF6',
  HGRID: '#2DD4BF',
  HYDRO: '#2563EB',
  BUS: '#64748B',
  SHORTAGE: '#DC2626',
  EXCESS: '#7C3AED'
})

/** 双向设备在能流图中的方向色；同一运行方向在主图、图例和明细中保持一致。 */
export const ENERGY_FLOW_COLOR_BY_ROLE: Readonly<Record<string, string>> = Object.freeze({
  ES_CHARGE: '#92400E',
  ES_DISCHARGE: '#E11D48',
  HS_CHARGE: '#475569',
  HS_DISCHARGE: '#14B8A6',
  PS_CHARGE: '#0891B2',
  PS_DISCHARGE: '#0284C7',
  FS_CHARGE: '#D946EF',
  FS_DISCHARGE: '#A855F7',
  CS_CHARGE: '#0D9488',
  CS_DISCHARGE: '#06B6D4',
  GRID_PURCHASE: '#8B5CF6',
  GRID_SALE: '#1D4ED8',
  HGRID_PURCHASE: '#2DD4BF',
  HGRID_SALE: '#0F766E'
})

/** 设备主色中文名（设置页展示） */
export const DEVICE_TYPE_COLOR_LABELS: Readonly<Record<string, string>> = Object.freeze({
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
  ELOAD: '电负荷',
  HLOAD: '氢负荷',
  QLOAD: '热负荷',
  GRID: '电网',
  HGRID: '氢网',
  HYDRO: '水电',
  BUS: '总线',
  SHORTAGE: '缺额',
  EXCESS: '过剩',
})

/** 能流方向色中文名（设置页展示） */
export const ENERGY_FLOW_ROLE_LABELS: Readonly<Record<string, string>> = Object.freeze({
  ES_CHARGE: '电储能充电',
  ES_DISCHARGE: '电储能放电',
  HS_CHARGE: '储氢充氢',
  HS_DISCHARGE: '储氢放氢',
  PS_CHARGE: '抽水蓄能充电',
  PS_DISCHARGE: '抽水蓄能放电',
  FS_CHARGE: '飞轮充电',
  FS_DISCHARGE: '飞轮放电',
  CS_CHARGE: '压缩空气充气',
  CS_DISCHARGE: '压缩空气放气',
  GRID_PURCHASE: '电网购入',
  GRID_SALE: '电网上送',
  HGRID_PURCHASE: '氢网购入',
  HGRID_SALE: '氢网上送',
})

// ─── 用户覆盖层（系统设置写入；不改默认表） ───

const COLOR_PREF_STORAGE_KEY = 'synerroll-device-color-preferences'
let overridesHydrated = false
let deviceColorOverrides: Readonly<Record<string, string>> = Object.freeze({})
let energyFlowColorOverrides: Readonly<Record<string, string>> = Object.freeze({})

function isHexColor(value: unknown): value is string {
  return typeof value === 'string' && /^#[0-9A-Fa-f]{6}$/.test(value)
}

/** 首次取色前从 localStorage 水合覆盖层，保证任意入口一致。 */
function hydrateColorOverrides(): void {
  if (overridesHydrated) return
  overridesHydrated = true
  if (typeof localStorage === 'undefined') return
  try {
    const raw = localStorage.getItem(COLOR_PREF_STORAGE_KEY)
    if (!raw) return
    const parsed = JSON.parse(raw) as { device?: Record<string, unknown>, energyFlow?: Record<string, unknown> } | null
    if (!parsed || typeof parsed !== 'object') return
    const device: Record<string, string> = {}
    const energyFlow: Record<string, string> = {}
    for (const [key, value] of Object.entries(parsed.device ?? {})) {
      if (isHexColor(value) && key in DEVICE_COLOR_BY_TYPE) device[key] = value
    }
    for (const [key, value] of Object.entries(parsed.energyFlow ?? {})) {
      if (isHexColor(value) && key in ENERGY_FLOW_COLOR_BY_ROLE) energyFlow[key] = value
    }
    deviceColorOverrides = Object.freeze(device)
    energyFlowColorOverrides = Object.freeze(energyFlow)
  }
  catch {
    // 覆盖层损坏时回落默认表
  }
}

export function setDeviceColorOverrides(overrides: Record<string, string>): void {
  deviceColorOverrides = Object.freeze({ ...overrides })
  overridesHydrated = true
}

export function setEnergyFlowColorOverrides(overrides: Record<string, string>): void {
  energyFlowColorOverrides = Object.freeze({ ...overrides })
  overridesHydrated = true
}

export function getDeviceColorOverrides(): Readonly<Record<string, string>> {
  hydrateColorOverrides()
  return deviceColorOverrides
}

export function getEnergyFlowColorOverrides(): Readonly<Record<string, string>> {
  hydrateColorOverrides()
  return energyFlowColorOverrides
}

/** 解析后的设备主色（覆盖 → 默认） */
export function resolveDeviceColor(deviceType: string): string {
  hydrateColorOverrides()
  return deviceColorOverrides[deviceType] ?? DEVICE_COLOR_BY_TYPE[deviceType] ?? ''
}

/** 解析后的能流方向色（覆盖 → 默认） */
export function resolveEnergyFlowRoleColor(role: string): string {
  hydrateColorOverrides()
  return energyFlowColorOverrides[role] ?? ENERGY_FLOW_COLOR_BY_ROLE[role] ?? ''
}

const DEVICE_TYPE_KEYS = Object.keys(DEVICE_COLOR_BY_TYPE)
  .sort((left, right) => right.length - left.length)

const FALLBACK_DEVICE_COLORS = [
  '#475569',
  '#0F766E',
  '#7C3AED',
  '#BE123C',
  '#A16207',
  '#0369A1'
] as const

export function inferDeviceType(value: string | null | undefined): string {
  const normalized = String(value ?? '').trim().toUpperCase()
  if (!normalized) return ''
  if (normalized in DEVICE_COLOR_BY_TYPE) return normalized

  for (const key of DEVICE_TYPE_KEYS) {
    if (new RegExp(`(?:^|_)${key}(?:_|$)`).test(normalized)) return key
  }
  return ''
}

function stableHash(value: string): number {
  let hash = 0
  for (let index = 0; index < value.length; index += 1) {
    hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0
  }
  return Math.abs(hash)
}

export function getDeviceColor(
  deviceTypeOrVariable: string | null | undefined,
  stableKey = String(deviceTypeOrVariable ?? '')
): string {
  const deviceType = inferDeviceType(deviceTypeOrVariable)
  if (deviceType) return resolveDeviceColor(deviceType) || DEVICE_COLOR_BY_TYPE[deviceType]!
  return FALLBACK_DEVICE_COLORS[stableHash(stableKey) % FALLBACK_DEVICE_COLORS.length]!
}

/**
 * 同一设备在不同时层中的递进色。
 * 保持设备基础色相不变，按时层顺序由浅到深调整透明度。
 */
export function getLayerColor(baseColor: string, layerIndex: number, layerCount: number): string {
  const normalized = baseColor.replace('#', '')
  const value = Number.parseInt(normalized, 16)
  const red = (value >> 16) & 255
  const green = (value >> 8) & 255
  const blue = value & 255
  const opacity = layerCount <= 1 ? 1 : 0.35 + 0.65 * (layerIndex / (layerCount - 1))
  return `rgba(${red},${green},${blue},${opacity.toFixed(2)})`
}

export function getEnergyFlowColor(varName: string): string {
  const normalized = String(varName).trim().toUpperCase()
  if (/^E_GRID_IN(?:_|$)/.test(normalized)) return resolveEnergyFlowRoleColor('GRID_SALE') || ENERGY_FLOW_COLOR_BY_ROLE.GRID_SALE!
  if (/^E_GRID_OUT(?:_|$)/.test(normalized)) return resolveEnergyFlowRoleColor('GRID_PURCHASE') || ENERGY_FLOW_COLOR_BY_ROLE.GRID_PURCHASE!
  if (/^H_HGRID_IN(?:_|$)/.test(normalized)) return resolveEnergyFlowRoleColor('HGRID_SALE') || ENERGY_FLOW_COLOR_BY_ROLE.HGRID_SALE!
  if (/^H_HGRID_OUT(?:_|$)/.test(normalized)) return resolveEnergyFlowRoleColor('HGRID_PURCHASE') || ENERGY_FLOW_COLOR_BY_ROLE.HGRID_PURCHASE!
  if (/^H_HS_IN(?:_|$)/.test(normalized)) return resolveEnergyFlowRoleColor('HS_CHARGE') || ENERGY_FLOW_COLOR_BY_ROLE.HS_CHARGE!
  if (/^H_HS_OUT(?:_|$)/.test(normalized)) return resolveEnergyFlowRoleColor('HS_DISCHARGE') || ENERGY_FLOW_COLOR_BY_ROLE.HS_DISCHARGE!

  const storageMatch = normalized.match(/^E_(ES|PS|FS|CS)_(IN|OUT)(?:_|$)/)
  if (storageMatch) {
    const [, deviceType, direction] = storageMatch
    const role = direction === 'IN' ? 'CHARGE' : 'DISCHARGE'
    return resolveEnergyFlowRoleColor(`${deviceType}_${role}`) || ENERGY_FLOW_COLOR_BY_ROLE[`${deviceType}_${role}`]!
  }

  return getDeviceColor(normalized, normalized)
}
