import type { UpdateAlgorithmConfigRequest } from '~~/types/api'
import { isSolverName } from '~~/config/solver'

import { apiSuccess } from '#server/utils/response'
import { updateProject } from '#server/utils/project-store'

export default defineEventHandler(async event => {
  const projectId = getRouterParam(event, 'projectId') ?? ''
  const body = await readBody<UpdateAlgorithmConfigRequest>(event)

  if (!body.algorithm || !isSolverName(body.algorithm.solver)) {
    throw createError({ statusCode: 400, statusMessage: '求解器只能选择 HiGHS 或 COPT' })
  }

  const project = await updateProject(projectId, current => ({
    ...current,
    algorithm: body.algorithm,
    solverConfig: body.solverConfig ?? current.solverConfig,
    status: 'configured'
  }))

  return apiSuccess({ project }, '算法配置已保存')
})
