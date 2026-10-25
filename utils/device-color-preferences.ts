/**
 * 设备主色 / 能流方向色的用户覆盖持久化。
 * 读取后写入 config/device-colors 的覆盖层；默认表始终保留，可一键恢复。
 */

import {
  DEVICE_COLOR_BY_TYPE,
  ENERGY_FLOW_COLOR_BY_ROLE,
  getDeviceColorOverrides,
  getEnergyFlowColorOverrides,
  setDeviceColorOverrides,
  setEnergyFlowColorOverrides,
} from '~~/config/device-colors'

export interface DeviceColorPreferences {
  device: Record<string, string>
  energyFlow: Record<string, string>
}

const STORAGE_KEY = 'synerroll-device-color-preferences'

function isHexColor(value: unknown): value is string {
  return typeof value === 'string' && /^#[0-9A-Fa-f]{6}$/.test(value)
}

export function loadDeviceColorPreferences(): DeviceColorPreferences {
  const empty: DeviceColorPreferences = { device: {}, energyFlow: {} }
  if (!import.meta.client) return empty
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return empty
    const parsed = JSON.parse(raw) as Partial<DeviceColorPreferences> | null
    if (!parsed || typeof parsed !== 'object') return empty
    const device: Record<string, string> = {}
    const energyFlow: Record<string, string> = {}
    for (const [key, value] of Object.entries(parsed.device ?? {})) {
      if (isHexColor(value) && key in DEVICE_COLOR_BY_TYPE) device[key] = value
    }
    for (const [key, value] of Object.entries(parsed.energyFlow ?? {})) {
      if (isHexColor(value) && key in ENERGY_FLOW_COLOR_BY_ROLE) energyFlow[key] = value
    }
    return { device, energyFlow }
  }
  catch {
    return empty
  }
}

export function saveDeviceColorPreferences(prefs: DeviceColorPreferences): void {
  if (!import.meta.client) return
  const device: Record<string, string> = {}
  const energyFlow: Record<string, string> = {}
  for (const [key, value] of Object.entries(prefs.device)) {
    if (isHexColor(value) && key in DEVICE_COLOR_BY_TYPE && value !== DEVICE_COLOR_BY_TYPE[key]) {
      device[key] = value
    }
  }
  for (const [key, value] of Object.entries(prefs.energyFlow)) {
    if (isHexColor(value) && key in ENERGY_FLOW_COLOR_BY_ROLE && value !== ENERGY_FLOW_COLOR_BY_ROLE[key]) {
      energyFlow[key] = value
    }
  }
  const payload: DeviceColorPreferences = { device, energyFlow }
  localStorage.setItem(STORAGE_KEY, JSON.stringify(payload))
  setDeviceColorOverrides(device)
  setEnergyFlowColorOverrides(energyFlow)
}

export function clearDeviceColorPreferences(): void {
  if (!import.meta.client) return
  localStorage.removeItem(STORAGE_KEY)
  setDeviceColorOverrides({})
  setEnergyFlowColorOverrides({})
}

/** 当前解析色（覆盖优先，否则默认） */
export function resolveDeviceColorMap(): Record<string, string> {
  const overrides = getDeviceColorOverrides()
  return Object.fromEntries(
    Object.keys(DEVICE_COLOR_BY_TYPE).map(key => [
      key,
      overrides[key] ?? DEVICE_COLOR_BY_TYPE[key]!,
    ]),
  )
}

export function resolveEnergyFlowColorMap(): Record<string, string> {
  const overrides = getEnergyFlowColorOverrides()
  return Object.fromEntries(
    Object.keys(ENERGY_FLOW_COLOR_BY_ROLE).map(key => [
      key,
      overrides[key] ?? ENERGY_FLOW_COLOR_BY_ROLE[key]!,
    ]),
  )
}

/** 模块加载时应用已保存覆盖（客户端） */
export function applySavedDeviceColorPreferences(): DeviceColorPreferences {
  const prefs = loadDeviceColorPreferences()
  setDeviceColorOverrides(prefs.device)
  setEnergyFlowColorOverrides(prefs.energyFlow)
  return prefs
}

if (import.meta.client) {
  applySavedDeviceColorPreferences()
}
