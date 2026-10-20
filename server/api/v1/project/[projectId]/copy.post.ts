import { apiSuccess } from '#server/utils/response'
import { copyProjectRecord } from '#server/utils/project-store'

export default defineEventHandler(async event => {
  const projectId = getRouterParam(event, 'projectId') ?? ''
  const body = await readBody<{ name?: string }>(event).catch(() => ({} as { name?: string }))
  const project = await copyProjectRecord(projectId, body?.name)

  return apiSuccess({ project }, '项目已复制')
})
