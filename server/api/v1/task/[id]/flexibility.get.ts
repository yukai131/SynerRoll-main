import { apiSuccess } from '#server/utils/response'
import { readTaskFlexibility, timeLabelToMinutes } from '#server/utils/sqlite-reader'

export default defineEventHandler((event) => {
  const id = getRouterParam(event, 'id')
  if (!id) throw createError({ statusCode: 400, message: '缺少 task id' })
  const query = getQuery(event)
  const afterRevision = query.afterRevision === undefined ? undefined : Number(query.afterRevision)
  if (afterRevision !== undefined && (!Number.isSafeInteger(afterRevision) || afterRevision < 0)) {
    throw createError({ statusCode: 400, message: 'afterRevision 无效' })
  }
  const minMinutes = query.minMinutes === undefined
    ? (typeof query.minTs === 'string' ? timeLabelToMinutes(query.minTs) ?? 0 : undefined)
    : Number(query.minMinutes)
  if (minMinutes !== undefined && (!Number.isFinite(minMinutes) || minMinutes < 0)) {
    throw createError({ statusCode: 400, message: 'minMinutes 无效' })
  }
  const result = readTaskFlexibility(id, {
    layerId: typeof query.layerId === 'string' ? query.layerId : undefined,
    minMinutes, afterRevision,
  })
  if (!result) throw createError({ statusCode: 404, message: '任务不存在' })
  return apiSuccess(result)
})
