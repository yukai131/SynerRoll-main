import { apiSuccess, throwBackendBizError, rethrowAsApiError } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'
import type { BoundaryMetadata } from '~~/types/boundary'

const JULIA_BACKEND_URL = JULIA.boundaryLoad()

/**
 * 从 TS 库加载边界转换数据
 * 请求体:
 * - boundaries: Array<{layerId, relatedComponent, meaning}>
 */
export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  try {
    const response = await $fetch<{
      success: boolean
      message?: string
      data?: {
        allFound: boolean
        boundaries: Array<{
          boundaryId?: string
          layerId: string
          found: boolean
          values?: number[]
          timestamps?: string[]
          config?: BoundaryMetadata
        }>
      }
    }>(JULIA_BACKEND_URL, {
      method: 'POST',
      body
    })

    if (response.success && response.data) {
      return apiSuccess(response.data)
    }
    throwBackendBizError(response.message, '加载失败')
  }
  catch (error) {
    rethrowAsApiError(error, '加载失败')
  }
})
