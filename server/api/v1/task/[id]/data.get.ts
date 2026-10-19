import { apiSuccess } from '#server/utils/response'
import { readTaskSeriesData, timeLabelToMinutes } from '#server/utils/sqlite-reader'

/** 按已提交 rowid 拉变化点；边界按显示窗口加载。 */
export default defineEventHandler((event) => {
  const id = getRouterParam(event, 'id')
  if (!id) throw createError({ statusCode: 400, message: '缺少 task id' })
  const query = getQuery(event)
  const numberParam = (name: string): number | undefined => {
    const value = query[name]
    if (value === undefined) return undefined
    const number = Number(value)
    if (!Number.isSafeInteger(number) || number < 0) throw createError({ statusCode: 400, message: name + ' 无效' })
    return number
  }
  const minMinutes = numberParam('minMinutes') ?? (typeof query.minTs === 'string' ? timeLabelToMinutes(query.minTs) ?? 0 : 0)
  const started = performance.now()
  const result = readTaskSeriesData(id, {
    minMinutes, maxMinutes: numberParam('maxMinutes'), afterId: numberParam('afterId'), limit: numberParam('limit'),
    skipBoundary: query.skipBoundary === '1' || query.skipBoundary === 'true',
    boundaryOnly: query.boundaryOnly === '1' || query.boundaryOnly === 'true',
    layerId: typeof query.layerId === 'string' ? query.layerId : undefined,
    sourceId: typeof query.sourceId === 'string' ? query.sourceId : undefined,
    varName: typeof query.varName === 'string' ? query.varName : undefined,
    remark: typeof query.remark === 'string' ? query.remark : undefined,
  })
  return apiSuccess({
    label: '', rows: result?.rows ?? [], cursor: result?.cursor ?? 0,
    latestCursor: result?.latest_cursor ?? 0, hasMore: result?.has_more ?? false,
    probe: { from_bff_sqlite: true, row_count: result?.rows.length ?? 0,
      total_ms: performance.now() - started, series_count: result?.series_count ?? 0,
      raw_point_count: result?.raw_point_count ?? 0,
      query_ms: result?.query_ms ?? 0, build_ms: result?.build_ms ?? 0,
      max_device_ts: result?.max_device_ts ?? '', min_minutes: minMinutes,
      cursor: result?.cursor ?? 0, read_at_ms: Date.now() },
  })
})
