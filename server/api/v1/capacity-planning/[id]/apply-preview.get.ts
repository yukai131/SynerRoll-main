import { juliaUrl } from '#server/utils/julia'
import type {
  ApplyCapacityPlanningPreview,
  CapacityPlanningResult,
  CapacityPlanningTask
} from '~~/types/capacity-planning'

import { apiSuccess } from '#server/utils/response'

const JULIA_CAPACITY_URL = juliaUrl('/api/capacity-planning')

// C-101：应用方案前展示节点容量差异，供用户确认后再调用 apply-and-simulate
export default defineEventHandler(async (event) => {
  const planningId = getRouterParam(event, 'id') ?? ''

  const [taskResponse, resultResponse] = await Promise.all([
    $fetch<{ success: boolean; data?: CapacityPlanningTask; message?: string }>(
      `${JULIA_CAPACITY_URL}/${encodeURIComponent(planningId)}`
    ),
    $fetch<{ success: boolean; data?: CapacityPlanningResult; message?: string }>(
      `${JULIA_CAPACITY_URL}/${encodeURIComponent(planningId)}/result`
    )
  ])
  if (!taskResponse.success || !taskResponse.data) {
    throw createError({ statusCode: 400, message: taskResponse.message || '容量规划任务不存在' })
  }
  if (taskResponse.data.status !== 'completed') {
    throw createError({ statusCode: 400, message: '容量规划任务尚未完成，无法预览应用差异' })
  }
  if (!resultResponse.success || !resultResponse.data) {
    throw createError({ statusCode: 400, message: resultResponse.message || '容量规划结果不存在' })
  }

  const planningTask = taskResponse.data
  const planningResult = resultResponse.data
  return apiSuccess<ApplyCapacityPlanningPreview>({
    planningId: planningTask.id,
    projectId: planningTask.projectId,
    canvasId: planningTask.canvasId,
    projectUpdatedAt: planningResult.projectUpdatedAt,
    variables: planningResult.variables,
    // C-406：来源最优候选的评价 id，确认弹窗展示溯源信息
    candidateId: typeof planningTask.bestEvaluationId === 'number' ? planningTask.bestEvaluationId : null
  })
})
