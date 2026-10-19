import { juliaUrl } from '#server/utils/julia'
import type { ClusteringConfig, ScenarioPreviewResult } from '~~/types/capacity-planning'

import { apiSuccess } from '#server/utils/response'
import { readProjectById } from '#server/utils/project-store'

const JULIA_BACKEND_URL = juliaUrl('/api/capacity-planning/scenarios/preview')

export default defineEventHandler(async (event) => {
  const body = await readBody<ClusteringConfig>(event)
  const projectId = body.projectId?.trim()
  const canvasId = body.canvasId?.trim()

  if (!projectId || !canvasId) {
    throw createError({ statusCode: 400, message: 'projectId 和 canvasId 不能为空' })
  }

  const project = await readProjectById(projectId)

  try {
    const response = await $fetch<{
      success: boolean
      data?: ScenarioPreviewResult
      message?: string
    }>(JULIA_BACKEND_URL, {
      method: 'POST',
      // Julia 需要项目快照来计算"画布节点引用的边界并集"（C-101/BUG-003）
      body: { ...body, canvasId, projectJson: project }
    })
    if (!response.success || !response.data) {
      throw createError({ statusCode: 400, message: response.message || '典型日聚类失败' })
    }
    return apiSuccess(response.data)
  }
  catch (error) {
    if (error && typeof error === 'object' && 'statusCode' in error) throw error
    throw createError({
      statusCode: 502,
      message: `Julia 后端不可用: ${error instanceof Error ? error.message : String(error)}`
    })
  }
})
