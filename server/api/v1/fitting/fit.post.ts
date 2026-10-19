import { apiSuccess } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'

const JULIA_BACKEND_URL = JULIA.fittingFit()

/**
 * 设备参数拟合 - 从本地 CSV 拟合气象条件与最大出力关系
 *
 * 请求体:
 * - type: 'wind' | 'pv'
 * - filePath: string
 * - powerColumn: string
 * - inputColumns: string[]  wind: [风速列] / pv: [辐照度列, 温度列]
 */
export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  try {
    const response = await $fetch<{
      success: boolean
      data?: {
        type: string
        params: Record<string, number>
        formulaText: string
        scatter: Array<{ x: number; y: number; t?: number }>
        curve: Array<{ x: number; y: number }>
        stats: { n: number; r2?: number; rmse?: number }
      }
      message?: string
    }>(JULIA_BACKEND_URL, {
      method: 'POST',
      body
    })

    if (response.success && response.data) {
      return apiSuccess(response.data, response.message)
    }
    else {
      throw createError({
        statusCode: 400,
        message: response.message || '拟合失败'
      })
    }
  }
  catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error'
    throw createError({
      statusCode: 500,
      message: `Julia backend error: ${message}`
    })
  }
})
