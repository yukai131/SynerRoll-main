import type { CapacityApplyRecord } from '~~/types/capacity-planning'

import { apiSuccess } from '#server/utils/response'
import { listApplies } from '#server/utils/apply-store'

// C-406：列出某规划任务的应用记录（来源溯源 + 撤销/恢复入口）
export default defineEventHandler(async (event) => {
  const planningId = getRouterParam(event, 'id') ?? ''
  const records = await listApplies(planningId)
  return apiSuccess<{ applies: CapacityApplyRecord[] }>({ applies: records })
})
