import type { CanvasData } from '~~/types/canvas'

import { apiSuccess } from '#server/utils/response'
import { getApply, updateApply } from '#server/utils/apply-store'
import { updateProject } from '#server/utils/project-store'
import { canvasMatchesApplySnapshot } from '#server/utils/capacity-apply-guard'

// C-406 撤销：按应用记录把目标画布恢复到应用前快照（current-canvas）或移除新画布。
// 安全校验：目标画布在应用后被再编辑过（updatedAt 变化）则拒绝撤销，避免覆盖用户改动。
export default defineEventHandler(async (event) => {
  const applyId = getRouterParam(event, 'applyId') ?? ''
  const record = await getApply(applyId)
  if (record.status !== 'applied') {
    throw createError({ statusCode: 409, message: '该应用已撤销，可用恢复操作还原' })
  }

  const now = new Date().toISOString()
  const updatedProject = await updateProject(record.projectId, (current) => {
    const next = structuredClone(current)
    const canvas = next.workspace.canvases.find(item => item.id === record.targetCanvasId)

    if (record.target === 'new-canvas') {
      if (!canvas) {
        throw createError({ statusCode: 409, message: '目标画布已不存在，无法撤销' })
      }
      if (canvas.updatedAt !== record.canvasUpdatedAtApplied || !canvasMatchesApplySnapshot(canvas, record.canvasSnapshotAfter)) {
        throw createError({ statusCode: 409, message: '目标画布在应用后被编辑过，拒绝撤销以免覆盖改动' })
      }
      next.workspace.canvases = next.workspace.canvases.filter(item => item.id !== record.targetCanvasId)
      if (next.workspace.activeCanvasId === record.targetCanvasId) {
        next.workspace.activeCanvasId = record.sourceCanvasId
      }
      return next
    }

    if (!canvas) {
      throw createError({ statusCode: 409, message: '目标画布已不存在，无法撤销' })
    }
    if (canvas.updatedAt !== record.canvasUpdatedAtApplied || !canvasMatchesApplySnapshot(canvas, record.canvasSnapshotAfter)) {
      throw createError({ statusCode: 409, message: '目标画布在应用后被编辑过，拒绝撤销以免覆盖改动' })
    }
    const snapshot = structuredClone(record.canvasSnapshotBefore) as CanvasData
    snapshot.id = record.targetCanvasId
    snapshot.updatedAt = now
    const index = next.workspace.canvases.findIndex(item => item.id === record.targetCanvasId)
    next.workspace.canvases[index] = snapshot
    return next
  })

  // 撤销后回写记录状态（恢复校验用 updatedAt）
  const canvasUpdatedAtUndone = record.target === 'new-canvas'
    ? null
    : (updatedProject.workspace.canvases.find(item => item.id === record.targetCanvasId)?.updatedAt ?? null)
  await updateApply(applyId, item => ({
    ...item,
    status: 'undone',
    undoneAt: now,
    projectUpdatedAtUndone: updatedProject.updateTime,
    canvasUpdatedAtUndone
  }))

  return apiSuccess({
    applyId,
    status: 'undone',
    projectUpdatedAt: updatedProject.updateTime
  })
})
