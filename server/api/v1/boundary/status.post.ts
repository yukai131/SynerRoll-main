import { apiSuccess, throwBackendBizError, rethrowAsApiError } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'

const JULIA_BACKEND_URL = JULIA.boundaryStatus()

/**
 * 查询项目 boundary.db 中已提交数据的边界 ID 列表
 * 请求体: { projectId: string }
 */
export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  try {
    const response = await $fetch<{
      success: boolean
      message?: string
      data?: { boundaryIds: string[] }
    }>(JULIA_BACKEND_URL, {
      method: 'POST',
      body
    })

    if (response.success && response.data) {
      return apiSuccess(response.data)
    }
    throwBackendBizError(response.message, '查询边界状态失败')
  }
  catch (error) {
    rethrowAsApiError(error, '查询边界状态失败')
  }
})
