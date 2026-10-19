import { apiSuccess, throwBackendBizError, rethrowAsApiError } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'
import type { BoundaryTimeMode } from '~~/types/boundary'

const JULIA_BACKEND_URL = JULIA.boundaryImport()

/**
 * 导入边界原始数据
 * 请求体:
 * - filePath: string - CSV文件路径
 * - columnName: string - 列名
 * - timeStep: string - 时间尺度
 * - projectId: string - 项目ID
 *
 * 返回:
 * - values: number[] - 数据数组
 * - timestamps: string[] - 时间戳数组
 * - xAxisLabel: string - X轴标签
 * - yAxisLabel: string - Y轴标签
 */
export default defineEventHandler(async (event) => {
  const body = await readBody(event)

  try {
    const response = await $fetch<{
      success: boolean
      data?: {
        values: number[]
        timestamps: string[]
        xAxisLabel: string
        yAxisLabel: string
        pointCount: number
        totalHours: number
        dayCount: number
        timeStep: string
        timeMode: BoundaryTimeMode
        calendarStartDate?: string
        calendarEndDate?: string
      }
      message?: string
    }>(JULIA_BACKEND_URL, {
      method: 'POST',
      body
    })

    if (response.success && response.data) {
      return apiSuccess(response.data)
    }
    throwBackendBizError(response.message, '导入失败')
  }
  catch (error) {
    rethrowAsApiError(error, '导入失败')
  }
})
