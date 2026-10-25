/**
 * 结果变量展示偏好（优先级 / 默认显隐）。
 *
 * 读取顺序（后者覆盖前者）：
 * 1. config/result-variables.ts 目录内建默认
 * 2. config/result-display.json —— 全局后台配置（改这里即可，推荐）
 * 3. localStorage —— 设置页「保存偏好」写入的本机覆盖
 */

import globalDisplayPrefs from '~~/config/result-display.json'
import {
  listResultCatalog,
  type ResultCatalogItem,
} from '~~/config/result-variables'

export interface ResultDisplayPreference {
  /** 目录键：`${label}|${base}` */
  key: string
  order: number
  visible: boolean
}

const STORAGE_KEY = 'synerroll-result-display-preferences'

type PrefMap = Record<string, ResultDisplayPreference>

function normalizePrefs(raw: unknown): PrefMap {
  if (!raw || typeof raw !== 'object') return {}
  const result: PrefMap = {}
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    const item = value as Partial<ResultDisplayPreference> | null
    if (!item || typeof item !== 'object') continue
    const order = Number(item.order)
    if (!Number.isFinite(order)) continue
    result[key] = {
      key,
      order,
      visible: item.visible !== false,
    }
  }
  return result
}

/** config/result-display.json 的全局默认（后台配置） */
export function loadGlobalResultDisplayPreferences(): PrefMap {
  return normalizePrefs((globalDisplayPrefs as { preferences?: unknown })?.preferences)
}

/** 本机 localStorage 覆盖（设置页保存） */
export function loadResultDisplayPreferences(): PrefMap {
  if (!import.meta.client) return {}
  try {
    return normalizePrefs(JSON.parse(localStorage.getItem(STORAGE_KEY) ?? 'null'))
  }
  catch {
    return {}
  }
}

export function saveResultDisplayPreferences(prefs: PrefMap): void {
  if (!import.meta.client) return
  localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs))
}

export function clearResultDisplayPreferences(): void {
  if (!import.meta.client) return
  localStorage.removeItem(STORAGE_KEY)
}

/** 内建默认 → 后台 JSON → 本机覆盖 */
export function resolveResultDisplayPreferences(
  localOverrides: PrefMap | null = null,
): PrefMap {
  return {
    ...loadGlobalResultDisplayPreferences(),
    ...(localOverrides ?? loadResultDisplayPreferences()),
  }
}

/** 目录默认 + 偏好合并后的完整列表（已按 order 排序） */
export function resolveResultCatalog(
  overrides: PrefMap | null = null,
): ResultCatalogItem[] {
  const prefs = overrides ?? resolveResultDisplayPreferences()
  return listResultCatalog()
    .map((item) => {
      const override = prefs[item.key]
      if (!override) return item
      return { ...item, order: override.order, visible: override.visible }
    })
    .sort((a, b) => a.order - b.order || a.key.localeCompare(b.key))
}

export function resolveResultPreference(
  catalogKey: string,
  overrides: PrefMap | null = null,
): { order: number; visible: boolean } {
  const prefs = overrides ?? resolveResultDisplayPreferences()
  const override = prefs[catalogKey]
  if (override) return { order: override.order, visible: override.visible }
  const fallback = listResultCatalog().find(item => item.key === catalogKey)
  return {
    order: fallback?.order ?? 1000,
    visible: fallback?.visible ?? true,
  }
}
