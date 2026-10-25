import { apiSuccess, throwBackendBizError, rethrowAsApiError } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'
import { readProjectById } from '#server/utils/project-store'

const JULIA_BACKEND_URL = JULIA.taskCreate()

/**
 * 创建计算任务
 * 请求体:
 * - projectId, canvasId, layerId, mode, simStartTime, simEndTime?
 * - simStartDate?, simEndDate?（日历绑定任务必须成对提供）
 * BFF 自动从项目存储读取 projectJson 传给 Julia 后端
 */
export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  // 从项目存储读取完整项目数据（含画布、时层配置等）
  const project = await readProjectById(body.projectId)
  try {
    const response = await $fetch<{
      success: boolean
      data?: { task?: Record<string, unknown> }
      message?: string
    }>(JULIA_BACKEND_URL, {
      method: 'POST',
      body: {
        ...body,
        projectJson: project
      }
    })

    if (response.success) {
      return apiSuccess(response.data ?? {}, response.message)
    }
    throwBackendBizError(response.message, '创建任务失败')
  }
  catch (error) {
    rethrowAsApiError(error, '创建任务失败')
  }
})
