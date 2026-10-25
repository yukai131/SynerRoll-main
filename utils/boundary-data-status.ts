/** 边界标签状态：未关联 / 空数据 / 已关联（有关联且 boundary.db 有数据） */
export type BoundaryDataStatus = 'unlinked' | 'empty' | 'ready'

export const BOUNDARY_DATA_STATUS_LABELS: Record<BoundaryDataStatus, string> = {
  unlinked: '未关联',
  empty: '空数据',
  ready: '已关联'
}

/**
 * 判定规则：
 * - 未关联组件 → 未关联（即使也没有数据）
 * - 有关联但 boundary.db 无数据 → 空数据
 * - 有关联且 boundary.db 有数据 → 已关联
 */
export function resolveBoundaryDataStatus(
  item: { relatedComponents?: string[] | null },
  dbHasData: boolean
): BoundaryDataStatus {
  const linked = (item.relatedComponents?.length ?? 0) > 0
  if (!linked) return 'unlinked'
  return dbHasData ? 'ready' : 'empty'
}
