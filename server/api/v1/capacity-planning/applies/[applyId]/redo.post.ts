import type { CanvasData } from '~~/types/canvas'

import { apiSuccess } from '#server/utils/response'
import { getApply, updateApply } from '#server/utils/apply-store'
import { updateProject } from '#server/utils/project-store'
import { canvasMatchesApplySnapshot } from '#server/utils/capacity-apply-guard'

// C-406 恢复：把已撤销的应用重新生效——current-canvas 还原到应用后快照，
// new-canvas 重新加入应用时的新画布。校验目标画布自撤销后未被再编辑。
export default defineEventHandler(async (event) => {
  const applyId = getRouterParam(event, 'applyId') ?? ''
  const record = await getApply(applyId)
  if (record.status !== 'undone') {
    throw createError({ statusCode: 409, message: '该应用不在已撤销状态，无法恢复' })
  }

  const now = new Date().toISOString()
  const updatedProject = await updateProject(record.projectId, (current) => {
    const next = structuredClone(current)
    const canvas = next.workspace.canvases.find(item => item.id === record.targetCanvasId)

    if (record.target === 'new-canvas') {
      if (canvas) {
        throw createError({ statusCode: 409, message: '目标画布已存在，无法重复恢复' })
      }
      const snapshot = structuredClone(record.canvasSnapshotAfter) as CanvasData
      snapshot.updatedAt = now
      next.workspace.canvases.push(snapshot)
      return next
    }

    if (!canvas) {
      throw createError({ statusCode: 409, message: '目标画布已不存在，无法恢复' })
    }
    if (canvas.updatedAt !== record.canvasUpdatedAtUndone || !canvasMatchesApplySnapshot(canvas, record.canvasSnapshotBefore)) {
      throw createError({ statusCode: 409, message: '目标画布在撤销后被编辑过，拒绝恢复以免覆盖改动' })
    }
    const snapshot = structuredClone(record.canvasSnapshotAfter) as CanvasData
    snapshot.id = record.targetCanvasId
    snapshot.updatedAt = now
    const index = next.workspace.canvases.findIndex(item => item.id === record.targetCanvasId)
    next.workspace.canvases[index] = snapshot
    return next
  })

  const canvasUpdatedAtApplied = updatedProject.workspace.canvases.find(
    item => item.id === record.targetCanvasId
  )?.updatedAt ?? null
  await updateApply(applyId, item => ({
    ...item,
    status: 'applied',
    projectUpdatedAtUndone: null,
    canvasUpdatedAtUndone: null,
    canvasUpdatedAtApplied: canvasUpdatedAtApplied ?? item.canvasUpdatedAtApplied
  }))

  return apiSuccess({
    applyId,
    status: 'applied',
    projectUpdatedAt: updatedProject.updateTime
  })
})
