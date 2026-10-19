import { apiSuccess, throwBackendBizError, rethrowAsApiError } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'

const JULIA_BACKEND_URL = JULIA.boundarySubmit()

/**
 * 提交边界转换数据到 TS 库
 * 请求体:
 * - boundaries: Array<{layerId, values, timestamps, relatedComponent, meaning}>
 */
export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  try {
    const response = await $fetch<{
      success: boolean
      message?: string
      storedKeys?: string[]
    }>(JULIA_BACKEND_URL, {
      method: 'POST',
      body
    })

    if (response.success) {
      return apiSuccess({ storedKeys: response.storedKeys }, response.message)
    }
    throwBackendBizError(response.message, '提交失败')
  }
  catch (error) {
    rethrowAsApiError(error, '提交失败')
  }
})