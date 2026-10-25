import type { BoundaryItem } from '~~/types/boundary'
import type { FittingModel } from '~~/types/fitting'

import { apiSuccess } from '#server/utils/response'
import { updateProject } from '#server/utils/project-store'

/**
 * 保存项目边界配置 + 设备参数拟合机型
 *
 * rawData / transformedData 已提交到 boundary.db，不再存入 projects.json，
 * 避免 8760+ 点的大数组导致 JSON 膨胀（单个 8760 边界约 2.6 MB）。
 * 前端通过 /api/boundary/load 从 SQLite 按需加载时序数据。
 */
export default defineEventHandler(async (event) => {
  const projectId = getRouterParam(event, 'projectId') ?? ''
  const body = await readBody<{ boundaries: BoundaryItem[]; fittingModels?: FittingModel[] }>(event)

  // 只保留配置元数据，剥离大数组
  const lightBoundaries = body.boundaries.map(b => {
    const { rawData, transformedData, ...rest } = b as any
    return rest
  })

  const project = await updateProject(projectId, current => ({
    ...current,
    boundaries: lightBoundaries,
    boundariesUpdatedAt: new Date().toISOString(),
    ...(body.fittingModels ? { fittingModels: body.fittingModels } : {})
  }))

  return apiSuccess({ project }, '边界配置已保存')
})
