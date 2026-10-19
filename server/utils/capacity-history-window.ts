import type { Project } from '~~/types/project'
import {
  DEFAULT_BOUNDARY_START_DATE, deriveCalendarEndDate, inclusiveCalendarDayCount, isDateOnly
} from '~~/utils/calendarTime'

/** Use the full common calendar coverage of the target canvas's boundaries. */
export const resolveCapacityHistoryWindow = (project: Project, canvasId: string) => {
  const canvas = project.workspace.canvases.find(item => item.id === canvasId)
  if (!canvas) throw createError({ statusCode: 409, message: '规划画布已不存在' })
  const ids = new Set(canvas.nodes.flatMap(node => node.data?.business.boundaryIds ?? []))
  if (!ids.size) throw createError({ statusCode: 400, message: '规划画布没有关联边界，无法创建全历史仿真' })
  const ranges = [...ids].map(id => {
    const boundary = project.boundaries.find(item => item.id === id)
    const metadata = boundary?.boundaryMeta
    if (!metadata || !(metadata.dayCount > 0)) {
      throw createError({ statusCode: 400, message: `边界 ${boundary?.name ?? id} 缺少日期覆盖信息，请重新导入并提交` })
    }
    const start = isDateOnly(metadata.calendarStartDate) ? metadata.calendarStartDate : DEFAULT_BOUNDARY_START_DATE
    const end = isDateOnly(metadata.calendarEndDate) ? metadata.calendarEndDate : deriveCalendarEndDate(start, metadata.dayCount)
    if (!isDateOnly(end) || end < start) throw createError({ statusCode: 400, message: `边界 ${boundary?.name ?? id} 的日期范围无效` })
    return { start, end }
  })
  const simStartDate = ranges.map(range => range.start).sort().at(-1)!
  const simEndDate = ranges.map(range => range.end).sort()[0]!
  const days = inclusiveCalendarDayCount(simStartDate, simEndDate)
  if (!days) throw createError({ statusCode: 400, message: '画布关联边界的日期覆盖范围没有交集' })
  return { simStartDate, simEndDate, simStartTime: '0:00', simEndTime: `${days * 24}:00` }
}
