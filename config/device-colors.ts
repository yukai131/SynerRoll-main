/**
 * 设备颜色的唯一来源。
 *
 * 同一设备类型在画布、能流、设备出力和灵活性图表中始终使用同一颜色；
 * 未登记类型使用稳定哈希选择兜底色，避免因数组顺序变化而漂移。
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
  HYDRO: '#2563EB',
  BUS: '#64748B',
  SHORTAGE: '#DC2626',
  EXCESS: '#7C3AED'
})

/** 双向设备在能流图中的方向色；同一运行方向在主图、图例和明细中保持一致。 */
export const ENERGY_FLOW_COLOR_BY_ROLE: Readonly<Record<string, string>> = Object.freeze({
  ES_CHARGE: '#F97316',
  ES_DISCHARGE: '#E11D48',
  PS_CHARGE: '#0891B2',
  PS_DISCHARGE: '#0284C7',
  FS_CHARGE: '#D946EF',
  FS_DISCHARGE: '#A855F7',
  CS_CHARGE: '#0D9488',
  CS_DISCHARGE: '#06B6D4',
  GRID_PURCHASE: '#8B5CF6',
  GRID_SALE: '#1D4ED8'
})

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
  if (DEVICE_COLOR_BY_TYPE[normalized]) return normalized

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
  if (deviceType) return DEVICE_COLOR_BY_TYPE[deviceType]!
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
  if (/^E_GRID_IN(?:_|$)/.test(normalized)) return ENERGY_FLOW_COLOR_BY_ROLE.GRID_SALE!
  if (/^E_GRID_OUT(?:_|$)/.test(normalized)) return ENERGY_FLOW_COLOR_BY_ROLE.GRID_PURCHASE!

  const storageMatch = normalized.match(/^E_(ES|PS|FS|CS)_(IN|OUT)(?:_|$)/)
  if (storageMatch) {
    const [, deviceType, direction] = storageMatch
    const role = direction === 'IN' ? 'CHARGE' : 'DISCHARGE'
    return ENERGY_FLOW_COLOR_BY_ROLE[`${deviceType}_${role}`]!
  }

  return getDeviceColor(normalized, normalized)
}
